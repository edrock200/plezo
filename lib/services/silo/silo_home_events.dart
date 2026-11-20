import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../media/home_watch_state.dart';
import '../../utils/app_logger.dart';
import '../../utils/certificate_trust.dart';

/// Silo's events socket for Home's watch state (silo-server
/// `docs/realtime-api.md`; Silo Android `EventsSocketV2Api` /
/// `HomeRealtimeCoordinator`, Silo's Roku app `HomeEventsTask` #102).
///
/// `POST /api/v2/events/ws-ticket` (bearer + profile headers) mints a
/// single-use ticket `{ticket, expires_in ≤ 30, max_connection_seconds ≤ 300,
/// protocol: "silo.events.v2"}`; `GET /api/v2/events/ws?channels=user_state`
/// is opened offering exactly `silo.events.v2`, `silo.ticket.<ticket>` (never
/// in the URL, no bearer). The client sends `{"type":"subscribe","channels":
/// ["user_state"]}`; the server answers `subscribed`, then `event` frames.
/// `user_state.changed` carries `{profile_id, content_id?, series_id?,
/// change}` (progress, favorite, watchlist, history, watched,
/// home_dismissal); the socket carries no authoritative data, so Home reads
/// its rows again over REST. The server ends every connection after
/// `max_connection_seconds` (or at access-token expiry) and on an access
/// change sends `{"type":"access_changed"}` then closes with 4001.
abstract final class SiloHomeEvents {
  static const protocol = 'silo.events.v2';
  static const ticketPath = '/api/v2/events/ws-ticket';
  static const socketPath = '/api/v2/events/ws';
  static const userStateChannel = 'user_state';
  static const ticketPrefix = 'silo.ticket.';

  /// The socket URL on [baseUrl] (`http(s)` becomes `ws(s)`, a path prefix on
  /// the base is kept), selecting the user_state channel.
  static Uri socketUrl(String baseUrl) {
    final base = Uri.parse(baseUrl);
    final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '$prefix$socketPath',
      queryParameters: const {'channels': userStateChannel},
    );
  }

  /// The subscribe frame the client sends once the socket is open.
  static String subscribeFrame() => jsonEncode({
    'type': 'subscribe',
    'channels': const [userStateChannel],
  });
}

/// A minted events ticket, validated as Silo's Android app does
/// (`validTicket`): the events protocol, `expires_in` 1–30 s,
/// `max_connection_seconds` 1–300, and a ticket made only of header token
/// characters (it travels in `Sec-WebSocket-Protocol` unchanged).
class SiloEventsTicket {
  const SiloEventsTicket({required this.ticket, required this.expiresIn, required this.maxConnectionSeconds});

  final String ticket;
  final int expiresIn;
  final int maxConnectionSeconds;

  static final _tokenChars = RegExp(r"^[A-Za-z0-9!#$%&'*+\-.^_`|~]+$");

  static SiloEventsTicket? parse(Object? data) {
    if (data is! Map) return null;
    final ticket = data['ticket'];
    final expires = data['expires_in'];
    final lifetime = data['max_connection_seconds'];
    if (ticket is! String || !_tokenChars.hasMatch(ticket)) return null;
    if (data['protocol'] != SiloHomeEvents.protocol) return null;
    if (expires is! num || expires < 1 || expires > 30) return null;
    if (lifetime is! num || lifetime < 1 || lifetime > 300) return null;
    return SiloEventsTicket(ticket: ticket, expiresIn: expires.toInt(), maxConnectionSeconds: lifetime.toInt());
  }

  @override
  String toString() => 'SiloEventsTicket(expiresIn: $expiresIn, maxConnectionSeconds: $maxConnectionSeconds)';
}

/// The server has no events socket (the ticket route answered 404/405/501):
/// not asked again while this watch runs.
class SiloEventsUnsupported implements Exception {
  const SiloEventsUnsupported(this.statusCode);
  final int statusCode;

  @override
  String toString() => 'SiloEventsUnsupported($statusCode)';
}

enum SiloHomeEventKind { subscribed, userStateChanged, accessChanged }

/// One server frame Home acts on; [parse] returns null for everything else
/// (hello, snapshots, other channels, errors, malformed JSON). Never throws.
class SiloHomeEvent {
  const SiloHomeEvent._(this.kind, {this.profileId, this.change, this.channels = const []});

  final SiloHomeEventKind kind;

  /// `user_state.changed`: the profile whose state changed, and what.
  final String? profileId;
  final String? change;

  /// `subscribed`: the channels the server accepted.
  final List<String> channels;

  bool get subscribedToUserState => kind == SiloHomeEventKind.subscribed && channels.contains('user_state');

  static SiloHomeEvent? parse(String raw) {
    final Object? frame;
    try {
      frame = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (frame is! Map) return null;
    switch (frame['type']) {
      case 'subscribed':
        final channels = frame['channels'];
        return SiloHomeEvent._(
          SiloHomeEventKind.subscribed,
          channels: channels is List ? channels.whereType<String>().toList() : const [],
        );
      case 'access_changed':
        return const SiloHomeEvent._(SiloHomeEventKind.accessChanged);
      case 'event':
        if (frame['channel'] != SiloHomeEvents.userStateChannel || frame['event'] != 'user_state.changed') return null;
        final data = frame['data'];
        if (data is! Map) return null;
        final profileId = data['profile_id'];
        if (profileId is! String || profileId.isEmpty) return null;
        return SiloHomeEvent._(
          SiloHomeEventKind.userStateChanged,
          profileId: profileId,
          change: data['change']?.toString(),
        );
    }
    return null;
  }
}

/// One open events socket: its text frames, a way to send, and close.
abstract interface class SiloEventsConnection {
  Stream<String> get frames;
  void send(String text);
  Future<void> close();

  /// The server's close code once the socket closed (4001 = access changed).
  int? get closeCode;
}

typedef SiloEventsConnector = Future<SiloEventsConnection?> Function(Uri url, SiloEventsTicket ticket);

/// Opens the events socket over `dart:io` with the ticket in the subprotocol
/// list. Null when it does not open within [timeout] or the server selects
/// another protocol (the ticket is spent either way; the next try mints anew).
Future<SiloEventsConnection?> connectSiloEventsSocket(
  Uri url,
  SiloEventsTicket ticket, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 10),
}) async {
  WebSocket? socket;
  try {
    final client = HttpClient(context: url.scheme == 'wss' ? CertificateTrust.contextFor(url.host) : null)
      ..connectionTimeout = timeout;
    socket = await WebSocket.connect(
      url.toString(),
      protocols: [SiloHomeEvents.protocol, '${SiloHomeEvents.ticketPrefix}${ticket.ticket}'],
      headers: headers,
      customClient: client,
    ).timeout(timeout);
    if (socket.protocol != SiloHomeEvents.protocol) {
      appLogger.w('Silo watch-state events: the server chose another protocol; not using it');
      unawaited(socket.close(WebSocketStatus.normalClosure));
      return null;
    }
    return _IoEventsConnection(socket);
  } catch (e) {
    appLogger.d('Silo watch-state events: socket did not open (${e.runtimeType})');
    if (socket != null) unawaited(socket.close(WebSocketStatus.normalClosure));
    return null;
  }
}

class _IoEventsConnection implements SiloEventsConnection {
  _IoEventsConnection(this._socket);

  final WebSocket _socket;

  @override
  Stream<String> get frames => _socket.where((frame) => frame is String).cast<String>();

  @override
  void send(String text) => _socket.add(text);

  @override
  int? get closeCode => _socket.closeCode;

  @override
  Future<void> close() async {
    try {
      await _socket.close(WebSocketStatus.normalClosure).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}

/// Watches one Silo connection's watch state while Home is visible: mints a
/// ticket, opens the socket, subscribes to `user_state`, reports changes for
/// [profileId], and reconnects after each close with a fresh ticket (1 s
/// doubling to 30 s; at once after an access change; the backoff starts over
/// once a connection subscribed). A server without the socket stops trying
/// for this watch. While no socket is subscribed, a check every
/// [pollInterval] stands in for it (Silo's Roku app does the same).
class SiloHomeEventsWatcher implements HomeWatchStateWatch {
  SiloHomeEventsWatcher({
    required this._url,
    required this.profileId,
    required this._mintTicket,
    required this._connect,
    required this._onSignal,
    bool Function()? isClientUsable,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.subscribeTimeout = const Duration(seconds: 15),
    this.pollInterval = const Duration(minutes: 2),
  }) : _isClientUsable = isClientUsable ?? _always;

  static bool _always() => true;

  final Uri _url;
  final String? profileId;
  final Future<SiloEventsTicket> Function() _mintTicket;
  final SiloEventsConnector _connect;
  final void Function(HomeWatchStateSignal signal) _onSignal;
  final bool Function() _isClientUsable;
  final Duration initialBackoff;
  final Duration maxBackoff;
  final Duration subscribeTimeout;
  final Duration pollInterval;

  bool _started = false;
  bool _stopped = false;
  bool _live = false;
  bool _unsupported = false;
  SiloEventsConnection? _connection;
  Timer? _pollTimer;
  Completer<void>? _wait;
  Timer? _waitTimer;

  /// A socket is open and subscribed to `user_state`.
  bool get isLive => _live;

  /// The server has no events socket; only the periodic check runs.
  bool get isUnsupported => _unsupported;

  bool get isStopped => _stopped;

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
    var backoff = initialBackoff;
    var everSubscribed = false;
    while (!_stopped && _isClientUsable()) {
      var subscribed = false;
      var accessChanged = false;
      try {
        final ticket = await _mintTicket();
        if (_stopped) return;
        final connection = await _connect(_url, ticket);
        if (connection == null) throw const SocketException('events socket did not open');
        if (_stopped) {
          unawaited(connection.close());
          return;
        }
        _connection = connection;
        final closeAt = Timer(Duration(seconds: ticket.maxConnectionSeconds), () => unawaited(connection.close()));
        final subscribeDeadline = Timer(subscribeTimeout, () {
          if (!subscribed) unawaited(connection.close());
        });
        try {
          connection.send(SiloHomeEvents.subscribeFrame());
          await for (final raw in connection.frames) {
            if (_stopped) break;
            final event = SiloHomeEvent.parse(raw);
            if (event == null) continue;
            switch (event.kind) {
              case SiloHomeEventKind.subscribed:
                if (subscribed || !event.subscribedToUserState) break;
                subscribed = true;
                _live = true;
                backoff = initialBackoff;
                appLogger.d('Silo watch-state events: subscribed');
                // The first subscription follows a Home read that just ran;
                // a later one catches up with what the gap missed.
                if (everSubscribed) _onSignal(HomeWatchStateSignal.reconnected);
                everSubscribed = true;
              case SiloHomeEventKind.userStateChanged:
                // user_state is account-scoped: other profiles' changes are
                // not this Home's (the server filters too).
                if (subscribed && (profileId == null || event.profileId == profileId)) {
                  _onSignal(HomeWatchStateSignal.changed);
                }
              case SiloHomeEventKind.accessChanged:
                if (!accessChanged) _onSignal(HomeWatchStateSignal.changed);
                accessChanged = true;
            }
          }
          if (connection.closeCode == 4001 && !accessChanged) {
            accessChanged = true;
            _onSignal(HomeWatchStateSignal.changed);
          }
        } finally {
          closeAt.cancel();
          subscribeDeadline.cancel();
          if (identical(_connection, connection)) _connection = null;
          unawaited(connection.close());
        }
      } on SiloEventsUnsupported catch (e) {
        _unsupported = true;
        appLogger.i(
          'Silo watch-state events: the server has none (status ${e.statusCode}); checking every '
          '${pollInterval.inMinutes} min while Home is shown',
        );
        _live = false;
        return;
      } catch (e) {
        appLogger.d('Silo watch-state events: connection ended (${e.runtimeType})');
      }
      _live = false;
      if (_stopped) return;
      // An access change asks for a fresh ticket at once (realtime-api.md).
      if (accessChanged) continue;
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
  SiloEventsConnection? get debugConnection => _connection;
}
