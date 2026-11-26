import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../media/home_watch_state.dart';
import '../../utils/app_logger.dart';
import '../../utils/certificate_trust.dart';

/// Tofa's live events socket for Home's watch state (the spec's `WsEvent`,
/// the "Live events API" guide).
///
/// One socket per server at `/api/v1/ws` (`ws://` / `wss://` on the API's
/// address, the relay's included). Sign-in happens inside it: the first
/// frame is `{"type": "auth", "token": "<account token>"}`, and the server
/// answers `{"type": "auth_ok"}` (or `{"error": …}` and closes). Then it
/// pushes events; Home cares about `WatchStateChanged` (sent to sockets
/// acting as that profile, servers with the `ws.watch_state_changed`
/// capability) and `EventsMissed` (events dropped: read again). Events are
/// not replayed, so a reconnect reads Home again. Reconnects back off 1 s
/// doubling to 30 s.
///
/// Unverified: which profile a socket acts as. The upgrade request carries
/// the profile headers the REST calls send, and changes of other profiles
/// are ignored by `profile_id`.
abstract final class TofaEvents {
  static const socketPath = '/api/v1/ws';
  static const watchStateCapability = 'ws.watch_state_changed';

  static Uri socketUrl(String baseUrl) {
    final base = Uri.parse(baseUrl);
    final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '$prefix$socketPath',
    );
  }

  static String authFrame(String token) => jsonEncode({'type': 'auth', 'token': token});
}

/// One open socket: its text frames, a way to send, and close.
abstract interface class TofaEventsConnection {
  Stream<String> get frames;
  void send(String text);
  Future<void> close();
}

typedef TofaEventsConnector = Future<TofaEventsConnection?> Function(Uri url, Map<String, String> headers);

/// Opens the socket over `dart:io`. Null when it does not open in [timeout].
Future<TofaEventsConnection?> connectTofaEventsSocket(
  Uri url,
  Map<String, String> headers, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  WebSocket? socket;
  try {
    final client = HttpClient(context: url.scheme == 'wss' ? CertificateTrust.contextFor(url.host) : null)
      ..connectionTimeout = timeout;
    socket = await WebSocket.connect(url.toString(), headers: headers, customClient: client).timeout(timeout);
    return _IoTofaEventsConnection(socket);
  } catch (e) {
    appLogger.d('[tofa] events socket did not open (${e.runtimeType})');
    if (socket != null) unawaited(socket.close(WebSocketStatus.normalClosure));
    return null;
  }
}

class _IoTofaEventsConnection implements TofaEventsConnection {
  _IoTofaEventsConnection(this._socket);

  final WebSocket _socket;

  @override
  Stream<String> get frames => _socket.where((frame) => frame is String).cast<String>();

  @override
  void send(String text) => _socket.add(text);

  @override
  Future<void> close() async {
    try {
      await _socket.close(WebSocketStatus.normalClosure).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}

/// Watches one Tofa connection's watch state while Home shows: signs in on
/// the socket, reports this profile's changes, reconnects after a close. A
/// server whose capabilities leave the event out, or that refuses the
/// sign-in, gets only a check every [pollInterval] (as for Silo).
class TofaHomeEventsWatcher implements HomeWatchStateWatch {
  TofaHomeEventsWatcher({
    required this._url,
    required this.profileId,
    required this._token,
    required this._headers,
    required this._connect,
    required this._onSignal,
    required this._supported,
    bool Function()? isClientUsable,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.authTimeout = const Duration(seconds: 15),
    this.pollInterval = const Duration(minutes: 2),
  }) : _isClientUsable = isClientUsable ?? _always;

  static bool _always() => true;

  final Uri _url;
  final String? profileId;
  final String? Function() _token;
  final Map<String, String> Function() _headers;
  final TofaEventsConnector _connect;
  final void Function(HomeWatchStateSignal signal) _onSignal;

  /// Whether the server lists the event (null: unknown, try the socket).
  final Future<bool?> Function() _supported;
  final bool Function() _isClientUsable;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final Duration authTimeout;
  final Duration pollInterval;

  bool _started = false;
  bool _stopped = false;
  bool _live = false;
  bool _pollOnly = false;
  TofaEventsConnection? _connection;
  Timer? _pollTimer;
  Completer<void>? _wait;
  Timer? _waitTimer;

  bool get isLive => _live;
  bool get isPollOnly => _pollOnly;

  void start() {
    if (_started || _stopped) return;
    _started = true;
    _pollTimer = Timer.periodic(pollInterval, (_) {
      if (_stopped || _live || !_isClientUsable()) return;
      _onSignal(HomeWatchStateSignal.poll);
    });
    unawaited(_run());
  }

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _live = false;
    _pollTimer?.cancel();
    _waitTimer?.cancel();
    final wait = _wait;
    if (wait != null && !wait.isCompleted) wait.complete();
    final connection = _connection;
    _connection = null;
    if (connection != null) unawaited(connection.close());
  }

  Future<void> _run() async {
    bool? supported;
    try {
      supported = await _supported();
    } catch (_) {}
    if (supported == false) {
      _pollOnly = true;
      appLogger.i('[tofa] watch-state events not offered by the server; checking every ${pollInterval.inMinutes} min');
      return;
    }
    var backoff = initialBackoff;
    var everSignedIn = false;
    while (!_stopped && _isClientUsable()) {
      var signedIn = false;
      var refused = false;
      try {
        final token = _token();
        if (token == null || token.isEmpty) return;
        final connection = await _connect(_url, _headers());
        if (connection == null) throw const SocketException('events socket did not open');
        if (_stopped) {
          unawaited(connection.close());
          return;
        }
        _connection = connection;
        final deadline = Timer(authTimeout, () {
          if (!signedIn) unawaited(connection.close());
        });
        try {
          connection.send(TofaEvents.authFrame(token));
          await for (final raw in connection.frames) {
            if (_stopped) break;
            final Object? frame;
            try {
              frame = jsonDecode(raw);
            } catch (_) {
              continue;
            }
            if (frame is! Map) continue;
            if (!signedIn) {
              if (frame['type'] == 'auth_ok') {
                signedIn = true;
                _live = true;
                backoff = initialBackoff;
                appLogger.d('[tofa] watch-state events signed in');
                if (everSignedIn) _onSignal(HomeWatchStateSignal.reconnected);
                everSignedIn = true;
              } else if (frame['error'] != null) {
                refused = true;
                appLogger.i('[tofa] events socket refused the sign-in (${frame['error']})');
                break;
              }
              continue;
            }
            switch (frame['type']) {
              case 'WatchStateChanged':
                final profile = frame['profile_id'];
                if (profileId == null || profile == null || profile == profileId) {
                  _onSignal(HomeWatchStateSignal.changed);
                }
              case 'EventsMissed':
                _onSignal(HomeWatchStateSignal.changed);
            }
          }
        } finally {
          deadline.cancel();
          if (identical(_connection, connection)) _connection = null;
          unawaited(connection.close());
        }
      } catch (e) {
        appLogger.d('[tofa] events socket ended (${e.runtimeType})');
      }
      _live = false;
      if (_stopped) return;
      if (refused && !everSignedIn) {
        // A server that never let this sign-in onto the socket: checks only.
        _pollOnly = true;
        return;
      }
      await _sleep(backoff);
      final doubled = backoff * 2;
      backoff = doubled > maxBackoff ? maxBackoff : doubled;
    }
  }

  Future<void> _sleep(Duration duration) {
    final wait = _wait = Completer<void>();
    _waitTimer = Timer(duration, () {
      if (!wait.isCompleted) wait.complete();
    });
    return wait.future;
  }

  @visibleForTesting
  TofaEventsConnection? get debugConnection => _connection;
}
