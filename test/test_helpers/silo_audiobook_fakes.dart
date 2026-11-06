import 'dart:async';

import 'package:plezy/services/silo/silo_audiobook.dart';
import 'package:plezy/services/silo/silo_audiobook_player.dart';

/// Scripted Silo audiobook calls: records starts, progress, stops and syncs.
class FakeSiloAudiobookBackend implements SiloAudiobookBackend {
  FakeSiloAudiobookBackend(this.detail);

  final SiloAudiobookDetail detail;
  final starts = <(String, double)>[];
  final progress = <(String, double, bool)>[];
  final stops = <(String, double)>[];
  final syncs = <(double, double)>[];
  SiloAudiobookProgressAnswer? nextProgress;
  SiloAudiobookProgressAnswer? alwaysProgress;
  bool failNextStart = false;
  int _sessions = 0;

  @override
  Future<SiloAudiobookDetail> fetchAudiobook(String id) async => detail;

  @override
  Future<SiloAudiobookStream> startPart(String fileId, {required double localStartSeconds}) async {
    starts.add((fileId, localStartSeconds));
    if (failNextStart) {
      failNextStart = false;
      throw StateError('start failed');
    }
    _sessions++;
    return SiloAudiobookStream(
      sessionId: 'sess-$_sessions',
      installationId: 'inst',
      fileId: fileId,
      url: 'https://silo/$fileId/$_sessions',
    );
  }

  @override
  Future<SiloAudiobookProgressAnswer> sendProgress(
    SiloAudiobookStream stream,
    double localSeconds, {
    required bool paused,
  }) async {
    progress.add((stream.sessionId, localSeconds, paused));
    final answer = nextProgress ?? alwaysProgress ?? const SiloAudiobookProgressAnswer(204);
    nextProgress = null;
    return answer;
  }

  @override
  Future<void> stopPart(SiloAudiobookStream stream, double localSeconds) async =>
      stops.add((stream.sessionId, localSeconds));

  @override
  Future<void> syncBookProgress(String bookId, double bookSeconds, double totalSeconds) async =>
      syncs.add((bookSeconds, totalSeconds));
}

/// An audio engine driven by the test.
class FakeSiloAudiobookEngine implements SiloAudiobookEngine {
  final _position = StreamController<Duration>.broadcast(sync: true);
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _completed = StreamController<bool>.broadcast(sync: true);
  final _errors = StreamController<String>.broadcast(sync: true);

  final opened = <(String, Duration, bool)>[];
  final seeks = <Duration>[];
  double rate = 1.0;
  bool stopped = false;

  void positionTo(Duration local) => _position.add(local);
  void complete() => _completed.add(true);
  void fail(String message) => _errors.add(message);

  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Stream<String> get errors => _errors.stream;

  @override
  Future<void> open(
    String url, {
    required Map<String, String> headers,
    required Duration start,
    required bool play,
  }) async {
    opened.add((url, start, play));
    stopped = false;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async => seeks.add(position);
  @override
  Future<void> setRate(double rate) async => this.rate = rate;
  @override
  Future<void> stop() async => stopped = true;
  @override
  Future<void> dispose() async {
    await _position.close();
    await _playing.close();
    await _completed.close();
    await _errors.close();
  }
}
