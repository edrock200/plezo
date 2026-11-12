import 'dart:async';

import 'package:clock/clock.dart';

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import 'silo_track_prefs.dart';

/// Sends one series choice: `PUT <path>` with [body]. Throws on failure
/// (a [MediaServerHttpException] carrying the status when the server refused).
typedef SiloTrackChoiceSend = Future<void> Function(String path, Map<String, Object?> body);

/// The queue that writes a viewer's audio and subtitle picks to Silo's series
/// preferences (a lighter port of Silo Android's
/// `DefaultSeriesTrackChoiceWriter` and Siku's `SeriesChoice.brs`).
///
/// One per client, so a write can only land on the connection's own Silo
/// profile. Best effort and never in the way of playback:
/// * a pick waits [debounce] before it is sent, and a newer pick for the same
///   series and kind replaces it (track cycling sends only the last one);
/// * one request per series and kind is in flight; a pick made meanwhile goes
///   out once it returns;
/// * a transient failure (network, timeout, 5xx, 408, 429) stays queued: it
///   is retried once after [retryDelay] and again by the next [flush] (each
///   playback start); a refusal (other 4xx) is dropped;
/// * a pick that has not landed within [maxAge] is dropped, so a late retry
///   never overwrites a newer choice made on another device.
class SiloSeriesTrackChoices {
  SiloSeriesTrackChoices({
    required this.send,
    this.debounce = const Duration(milliseconds: 1500),
    this.retryDelay = const Duration(seconds: 15),
    this.maxAge = const Duration(minutes: 10),
  });

  final SiloTrackChoiceSend send;
  final Duration debounce;
  final Duration retryDelay;
  final Duration maxAge;

  final Map<String, _PendingChoice> _pending = {};
  bool _closed = false;

  static String _key(String kind, String seriesKey) => '$kind|$seriesKey';

  /// Remember an audio pick ([body] from [SiloTrackPrefs.audioBody]).
  void saveAudio(String seriesKey, Map<String, Object?> body) => _save('audio', seriesKey, body);

  /// Remember a subtitle pick ([body] from [SiloTrackPrefs.subtitleBody] or
  /// [SiloTrackPrefs.subtitleOffBody]).
  void saveSubtitle(String seriesKey, Map<String, Object?> body) => _save('subtitle', seriesKey, body);

  void _save(String kind, String seriesKey, Map<String, Object?> body) {
    if (_closed || seriesKey.isEmpty) return;
    final key = _key(kind, seriesKey);
    final entry = _pending.putIfAbsent(key, () => _PendingChoice(kind, seriesKey));
    entry
      ..body = body
      ..generation += 1
      ..madeAt = clock.now()
      ..retried = false;
    entry.timer?.cancel();
    entry.timer = Timer(debounce, () => unawaited(_send(key)));
    appLogger.d('Silo series $kind choice queued: ${_describe(kind, body)}');
  }

  /// The pick for [seriesKey] that has not landed yet, or null.
  Map<String, Object?>? pendingAudio(String seriesKey) => _pendingBody('audio', seriesKey);

  /// [pendingAudio] for the subtitle choice.
  Map<String, Object?>? pendingSubtitle(String seriesKey) => _pendingBody('subtitle', seriesKey);

  Map<String, Object?>? _pendingBody(String kind, String seriesKey) {
    final entry = _pending[_key(kind, seriesKey)];
    if (entry == null) return null;
    if (_expired(entry)) {
      _drop(_key(kind, seriesKey));
      return null;
    }
    return entry.body;
  }

  bool get hasPending => _pending.isNotEmpty;

  /// Send every queued pick now and wait for them, at most [timeout]. Called
  /// before a playback start reads the watch detail, so a pick made on the
  /// previous episode is already in the server's answer.
  Future<void> flush({Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (_pending.isEmpty) return;
    final sends = [for (final key in _pending.keys.toList()) _send(key)];
    try {
      await Future.wait(sends).timeout(timeout);
    } on TimeoutException {
      appLogger.d('Silo series choices: flush still in flight after ${timeout.inMilliseconds} ms');
    }
  }

  bool _expired(_PendingChoice entry) => clock.now().difference(entry.madeAt) > maxAge;

  void _drop(String key) {
    _pending.remove(key)?.timer?.cancel();
  }

  Future<void> _send(String key) async {
    final entry = _pending[key];
    if (entry == null || _closed) return;
    entry.timer?.cancel();
    entry.timer = null;
    if (_expired(entry)) {
      appLogger.d('Silo series ${entry.kind} choice expired before it landed');
      _drop(key);
      return;
    }
    final inFlight = entry.inFlight;
    if (inFlight != null) {
      // The newer pick goes out once the one on the wire returns.
      await inFlight;
      return;
    }
    final generation = entry.generation;
    final body = entry.body;
    final path = entry.kind == 'audio'
        ? SiloTrackPrefs.audioPath(entry.seriesKey)
        : SiloTrackPrefs.subtitlePath(entry.seriesKey);
    final completer = Completer<void>();
    entry.inFlight = completer.future;
    var landed = false;
    var refused = false;
    try {
      await send(path, body);
      landed = true;
      appLogger.d('Silo series ${entry.kind} choice saved: ${_describe(entry.kind, body)}');
    } catch (error) {
      refused = _isRefusal(error);
      appLogger.w(
        'Silo series ${entry.kind} choice ${refused ? 'refused' : 'not saved'}'
        '${error is MediaServerHttpException && error.statusCode != null ? ' (status ${error.statusCode})' : ''}',
      );
    } finally {
      entry.inFlight = null;
      completer.complete();
    }
    if (!identical(_pending[key], entry) || _closed) return;
    if (entry.generation != generation) {
      // A newer pick arrived while this one was in flight.
      if (entry.timer == null) unawaited(_send(key));
      return;
    }
    if (landed || refused) {
      _drop(key);
      return;
    }
    if (!entry.retried) {
      entry.retried = true;
      entry.timer = Timer(retryDelay, () => unawaited(_send(key)));
    }
  }

  static bool _isRefusal(Object error) {
    if (error is! MediaServerHttpException) return false;
    final status = error.statusCode;
    if (status == null) return false;
    return status >= 400 && status < 500 && status != 408 && status != 429;
  }

  static String _describe(String kind, Map<String, Object?> body) {
    if (kind == 'subtitle') {
      if (body['subtitle_mode'] == 'off') return 'off';
      return 'track=${body['subtitle_track_index']} lang=${body['subtitle_language']}';
    }
    return 'track=${body['audio_track_index']} lang=${body['audio_language'] ?? ''}';
  }

  /// Remove and return every queued pick, for the client that replaces this
  /// one on the same login session ([adopt]). Timers stop; a request already
  /// on the wire still finishes (the new client may send the pick again,
  /// which writes the same preference).
  List<SiloPendingTrackChoice> takePending() {
    final taken = <SiloPendingTrackChoice>[
      for (final entry in _pending.values)
        if (!_expired(entry))
          SiloPendingTrackChoice(kind: entry.kind, seriesKey: entry.seriesKey, body: entry.body, madeAt: entry.madeAt),
    ];
    for (final entry in _pending.values) {
      entry.timer?.cancel();
    }
    _pending.clear();
    return taken;
  }

  /// Queue picks another client of this login session had not sent yet
  /// ([takePending]). A pick already queued here is newer and wins. Each
  /// keeps its age, so [maxAge] still counts from when the viewer made it.
  void adopt(Iterable<SiloPendingTrackChoice> choices) {
    if (_closed) return;
    for (final choice in choices) {
      final key = _key(choice.kind, choice.seriesKey);
      if (_pending.containsKey(key)) continue;
      final entry = _PendingChoice(choice.kind, choice.seriesKey)
        ..body = choice.body
        ..generation = 1
        ..madeAt = choice.madeAt;
      _pending[key] = entry;
      entry.timer = Timer(debounce, () => unawaited(_send(key)));
    }
  }

  /// Send what is still queued (at most [timeout]), then [close]. For a
  /// client that closes without a successor taking its picks.
  Future<void> closeGracefully({Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (!_closed) await flush(timeout: timeout);
    close();
  }

  /// Stop every timer; queued picks are dropped (the client is closing).
  void close() {
    _closed = true;
    for (final entry in _pending.values) {
      entry.timer?.cancel();
    }
    _pending.clear();
  }
}

/// A queued pick moved between clients of one login session.
class SiloPendingTrackChoice {
  const SiloPendingTrackChoice({required this.kind, required this.seriesKey, required this.body, required this.madeAt});

  final String kind;
  final String seriesKey;
  final Map<String, Object?> body;
  final DateTime madeAt;
}

class _PendingChoice {
  _PendingChoice(this.kind, this.seriesKey);

  final String kind;
  final String seriesKey;
  Map<String, Object?> body = const {};
  int generation = 0;
  DateTime madeAt = clock.now();
  bool retried = false;
  Timer? timer;
  Future<void>? inFlight;
}
