import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import '../../utils/certificate_trust.dart';

/// Live AI subtitle cues (Silo's web player behaviour).
///
/// When an AI job names its playback session, Silo translates from the
/// playhead forward and pushes each finished batch of lines to that session's
/// playback control socket (`silo.playback-control.v2`): the events
/// `subtitle_translation_started`, `_cues`, `_completed` and `_failed`. The
/// stored track still appears only when the whole job is done, minutes later;
/// the live cues let the player show the lines of the scene being watched
/// within seconds. Delivery is best effort and a reconnect replays nothing, so
/// the job read stays the authority.

/// One translated line, in source-file seconds.
class SiloLiveCue {
  const SiloLiveCue({required this.start, required this.end, required this.text});

  final double start;
  final double end;
  final String text;

  static const maxTextLength = 500;

  static SiloLiveCue? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawStart = json['start'], rawEnd = json['end'];
    final start = rawStart is num ? rawStart.toDouble() : null;
    final end = rawEnd is num ? rawEnd.toDouble() : null;
    var text = json['text']?.toString().trim() ?? '';
    if (start == null || end == null || !start.isFinite || !end.isFinite || end <= start || start < 0) return null;
    if (text.isEmpty) return null;
    if (text.length > maxTextLength) text = text.substring(0, maxTextLength);
    return SiloLiveCue(start: start, end: end, text: text);
  }
}

/// The cues received so far, sorted by start. Batches arrive playhead-first and
/// then wrap to the start of the file, so inserts land anywhere.
class SiloLiveCueTrack {
  static const maxCues = 20000;

  final List<SiloLiveCue> _cues = [];

  int get length => _cues.length;
  bool get isEmpty => _cues.isEmpty;

  /// Adds [cues]; returns how many were new. A cue already held (same start
  /// and text) is skipped, so a repeated batch changes nothing.
  int addAll(Iterable<SiloLiveCue> cues) {
    var added = 0;
    for (final cue in cues) {
      if (_cues.length >= maxCues) break;
      final at = _firstStartAtOrAfter(cue.start);
      var duplicate = false;
      for (var i = at; i < _cues.length && _cues[i].start == cue.start; i++) {
        if (_cues[i].text == cue.text) {
          duplicate = true;
          break;
        }
      }
      if (duplicate) continue;
      _cues.insert(at, cue);
      added++;
    }
    return added;
  }

  /// The text shown at [seconds] (source time): every cue covering it, in
  /// start order, one per line. Null when none does.
  String? textAt(double seconds) {
    if (_cues.isEmpty || !seconds.isFinite) return null;
    // Cues start at or before [seconds] up to this index (exclusive).
    final upper = _firstStartAfter(seconds);
    final lines = <String>[];
    // Overlapping cues are rare and short; looking back a few is enough.
    for (var i = upper - 1; i >= 0 && i >= upper - 8; i--) {
      final cue = _cues[i];
      if (cue.end > seconds) lines.insert(0, cue.text);
    }
    return lines.isEmpty ? null : lines.join('\n');
  }

  int _firstStartAtOrAfter(double start) {
    var lo = 0, hi = _cues.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_cues[mid].start < start) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int _firstStartAfter(double seconds) {
    var lo = 0, hi = _cues.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_cues[mid].start <= seconds) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

/// A live translation event for one job, from the control socket.
sealed class SiloLiveSubtitleEvent {
  const SiloLiveSubtitleEvent({required this.jobId, required this.fileId, required this.trackKey});

  final String jobId;
  final String fileId;
  final String trackKey;

  static const _started = 'subtitle_translation_started';
  static const _cues = 'subtitle_translation_cues';
  static const _completed = 'subtitle_translation_completed';
  static const _failed = 'subtitle_translation_failed';

  static int _int(Object? value) => value is num ? value.toInt() : 0;

  /// Parses one socket frame; null for anything that is not a live
  /// translation event (commands, other events, malformed frames).
  static SiloLiveSubtitleEvent? parse(String frame) {
    Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } catch (_) {
      return null;
    }
    if (decoded is! Map || decoded['type'] != 'event') return null;
    final payload = decoded['payload'];
    if (payload is! Map) return null;
    final jobId = payload['job_id']?.toString() ?? '';
    final fileId = payload['file_id']?.toString() ?? '';
    final trackKey = payload['track_key']?.toString() ?? '';
    if (jobId.isEmpty || fileId.isEmpty) return null;
    switch (decoded['name']) {
      case _started:
        return SiloLiveStarted(
          jobId: jobId,
          fileId: fileId,
          trackKey: trackKey,
          totalCues: _int(payload['total_cues']),
        );
      case _cues:
        final raw = payload['cues'];
        final cues = <SiloLiveCue>[
          if (raw is List)
            for (final c in raw) ?SiloLiveCue.fromJson(c),
        ];
        return SiloLiveCues(
          jobId: jobId,
          fileId: fileId,
          trackKey: trackKey,
          cues: cues,
          done: _int(payload['done']),
          total: _int(payload['total']),
        );
      case _completed:
        return SiloLiveCompleted(
          jobId: jobId,
          fileId: fileId,
          trackKey: trackKey,
          subtitleId: payload['subtitle_id']?.toString(),
        );
      case _failed:
        final message = payload['message']?.toString().trim();
        return SiloLiveFailed(
          jobId: jobId,
          fileId: fileId,
          trackKey: trackKey,
          message: message == null || message.isEmpty ? null : message,
        );
    }
    return null;
  }
}

class SiloLiveStarted extends SiloLiveSubtitleEvent {
  const SiloLiveStarted({
    required super.jobId,
    required super.fileId,
    required super.trackKey,
    required this.totalCues,
  });
  final int totalCues;
}

class SiloLiveCues extends SiloLiveSubtitleEvent {
  const SiloLiveCues({
    required super.jobId,
    required super.fileId,
    required super.trackKey,
    required this.cues,
    required this.done,
    required this.total,
  });
  final List<SiloLiveCue> cues;
  final int done;
  final int total;
}

class SiloLiveCompleted extends SiloLiveSubtitleEvent {
  const SiloLiveCompleted({required super.jobId, required super.fileId, required super.trackKey, this.subtitleId});
  final String? subtitleId;
}

class SiloLiveFailed extends SiloLiveSubtitleEvent {
  const SiloLiveFailed({required super.jobId, required super.fileId, required super.trackKey, this.message});
  final String? message;
}

/// One playback session's control socket, held only while a live AI job runs.
/// Plezilo advertises no commands in its hello and never answers command
/// frames, so the server's deadline fallbacks handle them as they do for a
/// player without a socket.
class SiloLiveSubtitleSocket {
  SiloLiveSubtitleSocket._(Stream<dynamic> frames, this._closeTransport) {
    _subscription = frames.listen(
      (frame) {
        if (frame is! String) return;
        final event = SiloLiveSubtitleEvent.parse(frame);
        if (event != null && !_events.isClosed) _events.add(event);
      },
      onDone: _finish,
      onError: (Object e) {
        appLogger.d('Silo live subtitles: socket error', error: e.runtimeType);
        _finish();
      },
      cancelOnError: true,
    );
  }

  static const protocol = 'silo.playback-control.v2';

  /// A socket over [frames], for tests; [onClose] runs when it is closed.
  @visibleForTesting
  factory SiloLiveSubtitleSocket.fromFrames(Stream<String> frames, {Future<void> Function()? onClose}) =>
      SiloLiveSubtitleSocket._(frames, onClose ?? () async {});

  final Future<void> Function() _closeTransport;
  late final StreamSubscription<dynamic> _subscription;
  final _events = StreamController<SiloLiveSubtitleEvent>.broadcast();
  final _closed = Completer<void>();

  Stream<SiloLiveSubtitleEvent> get events => _events.stream;

  /// Completes when the socket closes, from either side.
  Future<void> get done => _closed.future;
  bool get isClosed => _closed.isCompleted;

  /// The socket URL for [path] on [baseUrl] (`http(s)` becomes `ws(s)`; a
  /// path prefix on the base is kept).
  static Uri socketUrl(String baseUrl, String path) {
    final base = Uri.parse(baseUrl);
    final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '$prefix$path', query: null);
  }

  /// Opens the socket with the ticket in the subprotocol list (never in the
  /// URL) and sends the hello. Null when it does not open within [timeout] or
  /// the server selects another protocol.
  static Future<SiloLiveSubtitleSocket?> connect({
    required Uri url,
    required String ticket,
    required String sessionId,
    required String clientVersion,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 5),
  }) async {
    WebSocket? socket;
    try {
      final client = HttpClient(context: url.scheme == 'wss' ? CertificateTrust.contextFor(url.host) : null)
        ..connectionTimeout = timeout;
      socket = await WebSocket.connect(
        url.toString(),
        protocols: [protocol, 'silo.ticket.$ticket'],
        headers: headers,
        customClient: client,
      ).timeout(timeout);
      if (socket.protocol != protocol) {
        appLogger.w('Silo live subtitles: the server chose another protocol; not using it');
        unawaited(socket.close(WebSocketStatus.normalClosure));
        return null;
      }
      socket.add(
        jsonEncode({
          'type': 'hello',
          'session_id': sessionId,
          'client': {'name': 'Plezilo', 'version': clientVersion},
          'capabilities': {'commands': <String>[]},
        }),
      );
      final opened = socket;
      return SiloLiveSubtitleSocket._(
        opened,
        () => opened.close(WebSocketStatus.normalClosure).timeout(const Duration(seconds: 2)),
      );
    } catch (e) {
      appLogger.i('Silo live subtitles: socket did not open (${e.runtimeType}); following the job instead');
      if (socket != null) unawaited(socket.close(WebSocketStatus.normalClosure));
      return null;
    }
  }

  void _finish() {
    if (!_closed.isCompleted) _closed.complete();
    if (!_events.isClosed) unawaited(_events.close());
  }

  Future<void> close() async {
    if (_closed.isCompleted) return;
    _finish();
    // Closing the transport ends the stream; waiting on the cancel first can
    // stall until the peer answers.
    unawaited(_subscription.cancel());
    try {
      await _closeTransport();
    } catch (_) {}
  }
}
