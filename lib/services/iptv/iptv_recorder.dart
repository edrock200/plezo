import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';
import 'iptv_store.dart';

/// What the recorder needs to record one channel: its live address and
/// headers, resolved when the recording starts (an Xtream address carries the
/// login, so it is never stored).
typedef IptvRecordingTarget = ({String url, Map<String, String> headers});

/// Resolves a channel of a source to what the recorder fetches, or null when
/// the source or channel is gone.
typedef IptvRecordingResolver = Future<IptvRecordingTarget?> Function(String sourceId, String channelId);

/// Records IPTV channels to files on the device.
///
/// A recording copies the provider's stream as it arrives: an MPEG-TS stream
/// byte for byte, an HLS stream by following its media playlist and appending
/// its segments. Nothing is converted. Recordings run while Plezilo runs: a
/// scheduled recording whose start passes while the app is closed starts when
/// it opens again (if the programme is still on), and one cut off by the app
/// closing keeps what it recorded and is marked failed.
class IptvRecorder {
  IptvRecorder({
    required this.store,
    http.Client? client,
    Future<Directory> Function()? directory,
    this.backgroundChannel,
  }) : _client = client ?? http.Client(),
       _directory = directory ?? _defaultDirectory;

  /// Android: keeps the process alive in the background while recording
  /// (`IptvRecordingService`). Null elsewhere and in tests.
  final MethodChannel? backgroundChannel;

  static IptvRecorder _create() => IptvRecorder(
    store: IptvStore.instance,
    backgroundChannel: !kIsWeb && Platform.isAndroid ? const MethodChannel('com.plezy/iptv_recording') : null,
  );

  /// What the Android service shows: what records now and what is next.
  Future<void> _reportBackgroundState() async {
    final channel = backgroundChannel;
    if (channel == null) return;
    try {
      final now = _nowSeconds();
      final next = (await store.recordings())
          .where((r) => r.state == IptvRecordingState.scheduled && r.start > now)
          .fold<IptvRecordingRow?>(null, (best, r) => best == null || r.start < best.start ? r : best);
      await channel.invokeMethod<bool>('setState', {
        'active': [for (final a in _active.values) a.title],
        'nextAtMs': next == null ? null : next.start * 1000,
        'nextTitle': next?.title,
      });
    } catch (e) {
      appLogger.d('[iptv] recording service state not sent (${e.runtimeType})');
    }
  }

  static IptvRecorder? _instance;
  static IptvRecorder get instance => _instance ??= _create();
  static set testInstance(IptvRecorder? recorder) => _instance = recorder;

  final IptvStore store;
  final http.Client _client;
  final Future<Directory> Function() _directory;

  /// How the recorder reaches a channel; set by the app (the server manager).
  IptvRecordingResolver? resolver;

  /// Bumped on every recording state change.
  final ValueNotifier<int> changes = ValueNotifier(0);

  final Map<String, Timer> _timers = {};
  final Map<String, _ActiveRecording> _active = {};

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'iptv_recordings'));
    await dir.create(recursive: true);
    return dir;
  }

  static String newId() {
    final r = Random.secure();
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${r.nextInt(1 << 30).toRadixString(36)}';
  }

  bool isRecording(String recordingId) => _active.containsKey(recordingId);

  /// Set timers for every scheduled recording, start the ones on air, and
  /// mark recordings cut off by a previous exit as failed.
  Future<void> restore() async {
    final now = _nowSeconds();
    for (final r in await store.recordings()) {
      if (r.state == IptvRecordingState.recording && !_active.containsKey(r.id)) {
        await _update(r, state: IptvRecordingState.failed, error: 'interrupted');
      } else if (r.state == IptvRecordingState.scheduled) {
        if (r.stop <= now) {
          await _update(r, state: IptvRecordingState.failed, error: 'missed');
        } else {
          _arm(r);
        }
      }
    }
  }

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Schedule (or, when [start] has passed, begin) a recording.
  Future<IptvRecordingRow> schedule({
    required String sourceId,
    required String channelId,
    String? channelName,
    required String title,
    required int start,
    required int stop,
    String? ruleId,
    String? episode,
  }) async {
    final existing = (await store.recordings(sourceId: sourceId)).where(
      (r) =>
          r.channelId == channelId &&
          r.start == start &&
          (r.state == IptvRecordingState.scheduled || r.state == IptvRecordingState.recording),
    );
    if (existing.isNotEmpty) throw const IptvRecordingExistsException();
    final row = IptvRecordingRow(
      id: newId(),
      sourceId: sourceId,
      channelId: channelId,
      channelName: channelName,
      title: title,
      start: start,
      stop: stop,
      state: IptvRecordingState.scheduled,
      ruleId: ruleId,
      episode: episode,
    );
    await store.putRecording(row);
    _arm(row);
    changes.value++;
    unawaited(_reportBackgroundState());
    appLogger.i(
      '[iptv] recording scheduled in ${max(0, start - _nowSeconds()) ~/ 60} min for ${(stop - start) ~/ 60} min',
    );
    return row;
  }

  void _arm(IptvRecordingRow row) {
    _timers.remove(row.id)?.cancel();
    final wait = row.start - _nowSeconds();
    if (wait <= 0) {
      unawaited(_record(row));
      return;
    }
    _timers[row.id] = Timer(Duration(seconds: wait), () {
      _timers.remove(row.id);
      unawaited(_record(row));
    });
  }

  /// Cancel a scheduled or running recording. A running one keeps what it
  /// recorded (marked completed).
  Future<void> cancel(String recordingId) async {
    _timers.remove(recordingId)?.cancel();
    final active = _active[recordingId];
    if (active != null) {
      active.stop();
      return;
    }
    final row = (await store.recordings()).where((r) => r.id == recordingId).firstOrNull;
    if (row != null && row.state == IptvRecordingState.scheduled) {
      await _update(row, state: IptvRecordingState.cancelled);
    }
  }

  /// Recordings deleted while still running: their last state write is
  /// skipped so the row does not come back.
  final Set<String> _deleted = {};

  /// Delete a recording and its file.
  Future<void> deleteRecording(String recordingId) async {
    _deleted.add(recordingId);
    final active = _active[recordingId];
    await cancel(recordingId);
    if (active != null) await active.finished.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    final row = (await store.recordings()).where((r) => r.id == recordingId).firstOrNull;
    if (row?.path case final path?) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (e) {
        appLogger.w('[iptv] recording file not deleted (${e.runtimeType})');
      }
    }
    await store.deleteRecording(recordingId);
    changes.value++;
    unawaited(_reportBackgroundState());
  }

  /// Delete every recording of a removed source.
  Future<void> deleteSource(String sourceId) async {
    for (final r in await store.recordings(sourceId: sourceId)) {
      await deleteRecording(r.id);
    }
  }

  Future<void> _update(IptvRecordingRow r, {IptvRecordingState? state, String? path, int? bytes, String? error}) async {
    await store.putRecording(
      IptvRecordingRow(
        id: r.id,
        sourceId: r.sourceId,
        channelId: r.channelId,
        channelName: r.channelName,
        title: r.title,
        start: r.start,
        stop: r.stop,
        state: state ?? r.state,
        path: path ?? r.path,
        bytes: bytes ?? r.bytes,
        error: error ?? r.error,
        ruleId: r.ruleId,
        episode: r.episode,
      ),
    );
    changes.value++;
    unawaited(_reportBackgroundState());
  }

  Future<void> _record(IptvRecordingRow row) async {
    if (_active.containsKey(row.id)) return;
    final active = _ActiveRecording(row.title);
    _active[row.id] = active;
    unawaited(_reportBackgroundState());
    final target = await resolver?.call(row.sourceId, row.channelId);
    if (target == null || active.stopped) {
      _active.remove(row.id);
      appLogger.w('[iptv] recording could not start: ${active.stopped ? 'cancelled' : 'channel unavailable'}');
      if (!_deleted.contains(row.id)) {
        await _update(
          row,
          state: active.stopped ? IptvRecordingState.cancelled : IptvRecordingState.failed,
          error: active.stopped ? null : 'channel unavailable',
        );
      }
      if (!active.finished.isCompleted) active.finished.complete();
      return;
    }
    final dir = await _directory();
    final isHls = Uri.tryParse(target.url)?.path.toLowerCase().endsWith('.m3u8') ?? false;
    final file = File(p.join(dir.path, '${row.id}.ts'));
    await _update(row, state: IptvRecordingState.recording, path: file.path);
    final until = DateTime.fromMillisecondsSinceEpoch(row.stop * 1000);
    final stopTimer = Timer(until.difference(DateTime.now()), active.stop);
    appLogger.i('[iptv] recording started (${isHls ? 'hls' : 'stream'})');
    var bytes = 0;
    String? error;
    final sink = file.openWrite(mode: FileMode.append);
    try {
      bytes = isHls ? await _recordHls(target, sink, active, until) : await _recordStream(target, sink, active, until);
    } catch (e) {
      error = 'stream failed (${e.runtimeType})';
      appLogger.w('[iptv] recording stream failed (${e.runtimeType})');
    } finally {
      stopTimer.cancel();
      await sink.flush();
      await sink.close();
      _active.remove(row.id);
    }
    if (_deleted.contains(row.id)) {
      if (!active.finished.isCompleted) active.finished.complete();
      unawaited(_reportBackgroundState());
      return;
    }
    final ok = bytes > 0;
    await _update(
      row,
      state: ok ? IptvRecordingState.completed : IptvRecordingState.failed,
      path: file.path,
      bytes: bytes,
      error: ok ? null : error ?? 'nothing recorded',
    );
    appLogger.i('[iptv] recording ${ok ? 'finished' : 'failed'} bytes=$bytes');
    if (!active.finished.isCompleted) active.finished.complete();
    final ruleId = row.ruleId;
    if (ok && ruleId != null) {
      final rule = (await store.rules(sourceId: row.sourceId)).where((r) => r.id == ruleId).firstOrNull;
      if (rule != null) await enforceKeepLast(rule);
    }
  }

  /// Keep only the latest [IptvRecordingRule.keepLast] finished recordings
  /// of a series rule (0 keeps every one); older ones and their files go.
  Future<int> enforceKeepLast(IptvRecordingRule rule) async {
    if (rule.keepLast <= 0) return 0;
    final done = [
      for (final r in await store.recordings(sourceId: rule.sourceId))
        if (r.ruleId == rule.id && r.state == IptvRecordingState.completed) r,
    ]..sort((a, b) => b.start.compareTo(a.start));
    if (done.length <= rule.keepLast) return 0;
    final old = done.sublist(rule.keepLast);
    for (final r in old) {
      await deleteRecording(r.id);
    }
    appLogger.i('[iptv] series rule kept ${rule.keepLast}; ${old.length} older recording(s) deleted');
    return old.length;
  }

  /// A continuous stream (MPEG-TS): reconnects (with back-off) until [until]
  /// when the provider drops the connection.
  Future<int> _recordStream(IptvRecordingTarget target, IOSink sink, _ActiveRecording active, DateTime until) async {
    var bytes = 0;
    var failures = 0;
    while (!active.stopped && DateTime.now().isBefore(until)) {
      try {
        final request = http.Request('GET', Uri.parse(target.url))..headers.addAll(target.headers);
        final response = await _client.send(request).timeout(const Duration(seconds: 20));
        if (response.statusCode >= 400) throw HttpException('HTTP ${response.statusCode}');
        final done = Completer<void>();
        late final StreamSubscription<List<int>> sub;
        sub = response.stream.listen(
          (chunk) {
            sink.add(chunk);
            bytes += chunk.length;
            failures = 0;
          },
          onError: (Object e) {
            if (!done.isCompleted) done.complete();
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
        active.onStop = () {
          unawaited(sub.cancel());
          if (!done.isCompleted) done.complete();
        };
        await done.future;
      } catch (e) {
        failures++;
        if (failures > 6) rethrow;
      }
      if (active.stopped || !DateTime.now().isBefore(until)) break;
      await Future<void>.delayed(Duration(seconds: min(30, 1 << failures)));
    }
    return bytes;
  }

  /// An HLS stream: poll the media playlist and append new segments.
  Future<int> _recordHls(IptvRecordingTarget target, IOSink sink, _ActiveRecording active, DateTime until) async {
    var bytes = 0;
    var playlistUri = Uri.parse(target.url);
    final seen = <String>{};
    var failures = 0;
    while (!active.stopped && DateTime.now().isBefore(until)) {
      try {
        final response = await _client.get(playlistUri, headers: target.headers).timeout(const Duration(seconds: 15));
        if (response.statusCode >= 400) throw HttpException('HTTP ${response.statusCode}');
        final parsed = parseHlsPlaylist(response.body, playlistUri);
        if (parsed.variant != null) {
          playlistUri = parsed.variant!;
          continue;
        }
        for (final segment in parsed.segments) {
          if (active.stopped) break;
          if (!seen.add(segment.toString())) continue;
          final data = await _client.get(segment, headers: target.headers).timeout(const Duration(seconds: 30));
          if (data.statusCode >= 400) continue;
          sink.add(data.bodyBytes);
          bytes += data.bodyBytes.length;
        }
        failures = 0;
        if (parsed.ended) break;
        await Future<void>.delayed(Duration(seconds: parsed.targetDuration.clamp(2, 10)));
      } catch (e) {
        failures++;
        if (failures > 6) rethrow;
        await Future<void>.delayed(Duration(seconds: min(30, 1 << failures)));
      }
    }
    return bytes;
  }

  /// A master playlist's first (highest listed) variant, or a media
  /// playlist's segments.
  @visibleForTesting
  static ({Uri? variant, List<Uri> segments, int targetDuration, bool ended}) parseHlsPlaylist(String body, Uri base) {
    final lines = body.split(RegExp(r'\r?\n')).map((l) => l.trim()).toList();
    Uri? variant;
    var bestBandwidth = -1;
    final segments = <Uri>[];
    var targetDuration = 6;
    var ended = false;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        final bw = int.tryParse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ?? '') ?? 0;
        final next = i + 1 < lines.length ? lines[i + 1] : '';
        if (next.isNotEmpty && !next.startsWith('#') && bw > bestBandwidth) {
          bestBandwidth = bw;
          variant = base.resolve(next);
        }
      } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        targetDuration = int.tryParse(line.substring(22)) ?? targetDuration;
      } else if (line.startsWith('#EXT-X-ENDLIST')) {
        ended = true;
      } else if (line.isNotEmpty && !line.startsWith('#') && variant == null) {
        segments.add(base.resolve(line));
      }
    }
    return (
      variant: variant,
      segments: variant == null ? segments : const [],
      targetDuration: targetDuration,
      ended: ended,
    );
  }
}

class IptvRecordingExistsException implements Exception {
  const IptvRecordingExistsException();
}

class _ActiveRecording {
  _ActiveRecording(this.title);
  final String title;
  bool stopped = false;
  final Completer<void> finished = Completer<void>();
  void Function()? onStop;
  void stop() {
    stopped = true;
    onStop?.call();
  }
}
