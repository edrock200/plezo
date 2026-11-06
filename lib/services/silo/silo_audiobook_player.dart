import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:os_media_controls/os_media_controls.dart';

import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../mpv/mpv.dart';
import '../../utils/app_logger.dart';
import '../media_control_router.dart';
import '../media_controls_manager.dart';
import '../playback_initialization_types.dart';
import '../playback_coordinator.dart';
import 'silo_audiobook.dart';

/// The audio engine the audiobook player drives (mpv in the app, a fake in
/// tests). Positions are part-local.
abstract class SiloAudiobookEngine {
  Stream<Duration> get position;
  Stream<bool> get playing;
  Stream<bool> get completed;
  Stream<String> get errors;

  Future<void> open(String url, {required Map<String, String> headers, required Duration start, required bool play});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
  Future<void> stop();
  Future<void> dispose();
}

/// [SiloAudiobookEngine] over Plezy's audio [Player] (`Player.audio`).
class MpvSiloAudiobookEngine implements SiloAudiobookEngine {
  MpvSiloAudiobookEngine([Player? player]) : _player = player ?? Player.audio();

  final Player _player;

  @override
  Stream<Duration> get position => _player.streams.position;
  @override
  Stream<bool> get playing => _player.streams.playing;
  @override
  Stream<bool> get completed => _player.streams.completed;
  @override
  Stream<String> get errors => _player.streams.error.map((e) => e.message);

  @override
  Future<void> open(
    String url, {
    required Map<String, String> headers,
    required Duration start,
    required bool play,
  }) async {
    try {
      await _player.requestAudioFocus();
    } catch (e) {
      appLogger.d('Audiobook audio focus request failed', error: e);
    }
    await _player.open(
      Media(url, headers: headers, start: start),
      play: play,
    );
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setRate(double rate) => _player.setRate(rate);
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> dispose() => _player.dispose();
}

/// Plays one Silo audiobook (Silo Android `AudiobookPlayerViewModel`, Siku
/// `AudioPlayerScreen`): one playback session per part with client-owned
/// progress, the whole-book position written with `/sync/progress`, chapter
/// navigation, speed, and #708's session rules:
/// - progress answering "session not found" while playing starts a fresh
///   session at the position; while paused, the fresh one starts on Play; at
///   most [SiloAudiobookSessionRules.maxRenewals] in a row;
/// - `410 playback_session_ended` (an administrator) stops playback, says so,
///   and neither Play nor Try again starts another session;
/// - after any other error Play starts again where playback was.
///
/// Positions in its API are whole-book seconds.
class SiloAudiobookPlayer extends ChangeNotifier {
  SiloAudiobookPlayer({
    required this.backend,
    required this.detail,
    required this.engineFactory,
    this.mediaItem,
    this.client,
    this.mediaControlsFactory,
    this.progressInterval = const Duration(seconds: 10),
    @visibleForTesting this.claimAudio,
  }) : _bookSeconds = ValueNotifier(detail.resumeSeconds);

  final SiloAudiobookBackend backend;
  final SiloAudiobookDetail detail;

  /// The book's card, for the OS media session's metadata.
  final MediaItem? mediaItem;
  final MediaServerClient? client;
  final Duration progressInterval;

  /// Stops other playback before this one takes the audio. Defaults to
  /// [PlaybackCoordinator.claimVideo], which stops a music session.
  final Future<void> Function()? claimAudio;

  final SiloAudiobookEngine Function() engineFactory;

  /// The OS media session (null in tests: none).
  final MediaControlsManager Function()? mediaControlsFactory;

  SiloAudiobookEngine? _engine;
  final List<StreamSubscription<Object?>> _subs = [];
  MediaControlsManager? _controls;
  StreamSubscription<MediaControlEvent>? _controlSub;
  Timer? _progressTimer;

  SiloAudiobookTimeline get timeline => detail.timeline!;

  final ValueNotifier<double> _bookSeconds;

  /// Whole-book position, updated with every engine tick.
  ValueListenable<double> get position => _bookSeconds;
  double get bookSeconds => _bookSeconds.value;

  SiloAudiobookStream? _stream;
  SiloAudiobookPart? _part;
  int _generation = 0;
  bool _playing = false;
  bool _loading = false;
  bool _finished = false;
  bool _closing = false;
  bool _endedByServer = false;
  bool _sessionExpired = false;
  int _renewals = 0;
  bool _reportingStopped = false;
  String? _error;
  double _speed = 1.0;

  bool get isPlaying => _playing;
  bool get isLoading => _loading;
  bool get isFinished => _finished;
  bool get endedByServer => _endedByServer;

  /// The session expired while paused: Play starts a fresh one.
  bool get sessionExpired => _sessionExpired;
  int get renewals => _renewals;
  String? get error => _error;
  double get speed => _speed;
  SiloAudiobookPart? get currentPart => _part;
  SiloAudiobookStream? get currentStream => _stream;

  bool get canRetry =>
      SiloAudiobookSessionRules.canRetry(hasError: _error != null, endedByServer: _endedByServer, closing: _closing) &&
      _stream == null &&
      !_loading;

  int get chapterIndex => timeline.chapterIndexAt(bookSeconds);
  SiloAudiobookChapter? get currentChapter => chapterIndex < 0 ? null : timeline.chapters[chapterIndex];

  static const speeds = <double>[0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static const minSpeed = 0.5;
  static const maxSpeed = 3.0;

  /// Start playback at [atSeconds] (default: the resume point).
  Future<void> start({double? atSeconds}) async {
    if (_closing || detail.timeline == null) return;
    await (claimAudio ?? PlaybackCoordinator.instance.claimVideo)();
    if (_closing) return;
    _ensureControls();
    await _loadAt(timeline.clamp(atSeconds ?? detail.resumeSeconds), play: true);
  }

  SiloAudiobookEngine _ensureEngine() {
    final existing = _engine;
    if (existing != null) return existing;
    final engine = engineFactory();
    _engine = engine;
    _subs
      ..add(engine.position.listen(_onEnginePosition))
      ..add(engine.playing.listen(_onEnginePlaying))
      ..add(
        engine.completed.listen((done) {
          if (done) unawaited(_onPartCompleted());
        }),
      )
      ..add(engine.errors.listen(_onEngineError));
    return engine;
  }

  /// Retire the current session and open the part holding [seconds].
  Future<void> _loadAt(double seconds, {required bool play}) async {
    if (_closing || _endedByServer) return;
    final generation = ++_generation;
    final previous = _stream;
    final previousPart = _part;
    _stream = null;
    _stopProgressTimer();
    if (previous != null && previousPart != null) {
      unawaited(backend.stopPart(previous, SiloAudiobookTimeline.localTime(previousPart, bookSeconds)));
    }
    final part = timeline.partAt(seconds);
    final local = SiloAudiobookTimeline.localTime(part, seconds);
    _part = part;
    _bookSeconds.value = seconds;
    _finished = false;
    _sessionExpired = false;
    _reportingStopped = false;
    _error = null;
    _loading = true;
    notifyListeners();
    final engine = _ensureEngine();
    SiloAudiobookStream stream;
    try {
      stream = await backend.startPart(part.fileId, localStartSeconds: local);
    } catch (error) {
      if (generation != _generation || _closing) return;
      _fail(_message(error));
      return;
    }
    if (generation != _generation || _closing || _endedByServer) {
      unawaited(backend.stopPart(stream, local));
      return;
    }
    try {
      await engine.open(stream.url, headers: stream.headers, start: _duration(local), play: play);
      if (_speed != 1.0) await engine.setRate(_speed);
    } catch (error) {
      if (generation != _generation || _closing) return;
      unawaited(backend.stopPart(stream, local));
      _fail(_message(error));
      return;
    }
    if (generation != _generation || _closing) {
      unawaited(backend.stopPart(stream, local));
      return;
    }
    _stream = stream;
    _loading = false;
    _playing = play;
    _startProgressTimer();
    notifyListeners();
    _publishState(force: true);
  }

  void _fail(String message) {
    _loading = false;
    _playing = false;
    _error = message;
    _stopProgressTimer();
    notifyListeners();
    _publishState(force: true);
  }

  String _message(Object error) {
    if (error is PlaybackException) return error.message;
    return t.siloAudio.playbackFailed;
  }

  void _onEnginePosition(Duration local) {
    final part = _part;
    if (_closing || part == null || _stream == null || _loading) return;
    _bookSeconds.value = timeline.clamp(part.offsetSeconds + local.inMilliseconds / 1000.0);
  }

  void _onEnginePlaying(bool playing) {
    if (_closing || _stream == null || _loading || playing == _playing) return;
    _playing = playing;
    notifyListeners();
    _publishState(force: true);
  }

  void _onEngineError(String message) {
    if (_closing || _loading || _stream == null) return;
    appLogger.w('Silo audiobook playback error: $message');
    final stream = _stream!;
    _stream = null;
    unawaited(backend.stopPart(stream, _localSeconds()));
    unawaited(backend.syncBookProgress(detail.id, bookSeconds, timeline.totalSeconds));
    _fail(t.siloAudio.playbackFailed);
  }

  Future<void> _onPartCompleted() async {
    final part = _part;
    final stream = _stream;
    if (part == null || stream == null || _loading || _closing) return;
    if (part.index + 1 < timeline.parts.length) {
      await _loadAt(timeline.parts[part.index + 1].offsetSeconds, play: true);
      return;
    }
    // The end of the book.
    _stream = null;
    _stopProgressTimer();
    _bookSeconds.value = timeline.totalSeconds;
    unawaited(backend.stopPart(stream, part.durationSeconds));
    unawaited(backend.syncBookProgress(detail.id, timeline.totalSeconds, timeline.totalSeconds));
    _playing = false;
    _finished = true;
    notifyListeners();
    _publishState(force: true);
  }

  double _localSeconds() {
    final part = _part;
    return part == null ? 0 : SiloAudiobookTimeline.localTime(part, bookSeconds);
  }

  // -------------------------------------------------------------------------
  // Progress and #708
  // -------------------------------------------------------------------------

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(progressInterval, (_) {
      if (_playing) unawaited(reportProgress());
    });
  }

  void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  /// One progress report for the session playing now (part-local) and the
  /// whole-book position; the answer decides what happens to the session.
  @visibleForTesting
  Future<void> reportProgress() async {
    final stream = _stream;
    if (stream == null || _closing || _reportingStopped) return;
    final paused = !_playing;
    final local = _localSeconds();
    final book = bookSeconds;
    unawaited(backend.syncBookProgress(detail.id, book, timeline.totalSeconds));
    final answer = await backend.sendProgress(stream, local, paused: paused);
    // Only answers about the session playing now count: a late one for the
    // previous part's session must not end or renew this one.
    if (!identical(stream, _stream) || _closing) return;
    if (answer.ok) {
      _renewals = 0;
      return;
    }
    final action = SiloAudiobookSessionRules.progressAction(
      status: answer.status,
      problem: answer.problem,
      paused: !_playing,
      renewals: _renewals,
    );
    switch (action) {
      case SiloAudiobookSessionAction.none:
        return;
      case SiloAudiobookSessionAction.ended:
        await _leaveServerEndedSession();
      case SiloAudiobookSessionAction.renew:
        _renewals++;
        appLogger.i('Silo audiobook session expired on the server; starting a fresh one (renewal $_renewals)');
        // The expired session is not stopped: the server has forgotten it.
        _stream = null;
        await _loadAt(bookSeconds, play: true);
      case SiloAudiobookSessionAction.renewOnPlay:
        appLogger.i('Silo audiobook session expired while paused; a fresh one starts on Play');
        _stream = null;
        _sessionExpired = true;
        _stopProgressTimer();
        notifyListeners();
      case SiloAudiobookSessionAction.stopReporting:
        if (_renewals >= SiloAudiobookSessionRules.maxRenewals) {
          appLogger.w('Silo audiobook session expired again; not renewing after $_renewals renewals');
        }
        _reportingStopped = true;
        _stopProgressTimer();
    }
  }

  /// `410 playback_session_ended`: stop and say so. No DELETE (it is over),
  /// and nothing starts another session.
  Future<void> _leaveServerEndedSession() async {
    if (_closing || _endedByServer) return;
    appLogger.i('Silo audiobook: the server ended this playback session; not starting another');
    unawaited(backend.syncBookProgress(detail.id, bookSeconds, timeline.totalSeconds));
    _endedByServer = true;
    _stream = null;
    _generation++;
    _stopProgressTimer();
    try {
      await _engine?.stop();
    } catch (e) {
      appLogger.d('Audiobook engine stop failed', error: e);
    }
    _fail(t.siloAudio.sessionEnded);
  }

  // -------------------------------------------------------------------------
  // Transport
  // -------------------------------------------------------------------------

  Future<void> togglePlay() => _playing ? pause() : play();

  Future<void> play() async {
    if (_closing || _endedByServer || _loading) return;
    if (_finished) {
      // Replay from the start.
      await _loadAt(0, play: true);
      return;
    }
    if (canRetry || _stream == null) {
      if (_sessionExpired) {
        _renewals++;
        appLogger.i('Silo audiobook: starting a fresh session on Play (renewal $_renewals)');
      }
      await (claimAudio ?? PlaybackCoordinator.instance.claimVideo)();
      _ensureControls();
      await _loadAt(bookSeconds, play: true);
      return;
    }
    await _engine?.play();
    _playing = true;
    notifyListeners();
    _publishState(force: true);
  }

  Future<void> pause() async {
    if (_closing || !_playing) return;
    await _engine?.pause();
    _playing = false;
    notifyListeners();
    _publishState(force: true);
    // Tell the server at once, as Silo's player does on pause.
    await reportProgress();
  }

  /// Seek to a whole-book time: inside the loaded part, or a new part session.
  Future<void> seekTo(double seconds) async {
    if (_closing) return;
    final target = timeline.clamp(seconds);
    final part = timeline.partAt(target);
    final stream = _stream;
    if (stream != null && !_loading && part.index == _part?.index) {
      _finished = false;
      _bookSeconds.value = target;
      await _engine?.seek(_duration(SiloAudiobookTimeline.localTime(part, target)));
      _publishState(force: true);
      return;
    }
    if (_endedByServer || _error != null || _sessionExpired || (stream == null && !_loading && !_finished)) {
      // Nothing is playing: move the position Play starts from.
      _part = part;
      _finished = false;
      _bookSeconds.value = target;
      notifyListeners();
      return;
    }
    await _loadAt(target, play: _playing || _loading || _finished);
  }

  Future<void> skip(double deltaSeconds) => seekTo(bookSeconds + deltaSeconds);

  Future<void> nextChapter() => seekTo(timeline.nextChapterTarget(bookSeconds));

  Future<void> previousChapter() => seekTo(timeline.previousChapterTarget(bookSeconds));

  Future<void> jumpToChapter(int index) async {
    if (index < 0 || index >= timeline.chapters.length) return;
    await seekTo(timeline.chapters[index].startSeconds);
  }

  Future<void> setSpeed(double speed) async {
    final clamped = speed.clamp(minSpeed, maxSpeed).toDouble();
    if (clamped == _speed) return;
    _speed = clamped;
    notifyListeners();
    if (_stream != null) await _engine?.setRate(clamped);
    _publishState(force: true);
  }

  /// Stop playback, report where it stopped and release the engine.
  Future<void> close() async {
    if (_closing) return;
    final stream = _stream;
    final local = _localSeconds();
    final book = bookSeconds;
    _closing = true;
    _generation++;
    _stream = null;
    _stopProgressTimer();
    // Not awaited: nothing below depends on the cancels landing.
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    unawaited(_controlSub?.cancel());
    _controlSub = null;
    final controls = _controls;
    _controls = null;
    if (controls != null) {
      unawaited(controls.setBackgroundMode(false));
      unawaited(controls.clear());
    }
    final engine = _engine;
    _engine = null;
    await Future.wait<void>([
      if (stream != null) backend.stopPart(stream, local),
      if (book > 0 && !_finished) backend.syncBookProgress(detail.id, book, timeline.totalSeconds),
      if (engine != null)
        () async {
          try {
            await engine.stop();
            await engine.dispose();
          } catch (e) {
            appLogger.d('Audiobook engine dispose failed', error: e);
          }
        }(),
    ]);
  }

  @override
  void dispose() {
    unawaited(close());
    _bookSeconds.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // OS media session (lock screen, notification, headset keys)
  // -------------------------------------------------------------------------

  void _ensureControls() {
    final factory = mediaControlsFactory;
    if (factory == null || _controls != null) return;
    final controls = factory();
    _controls = controls;
    final router = MediaControlRouter(
      canControlPlayback: () => !_closing,
      canNavigateMediaItems: () => timeline.chapters.length > 1,
      onPlay: () => unawaited(play()),
      onPause: () => unawaited(pause()),
      onTogglePlayPause: () => unawaited(togglePlay()),
      onSeek: (position) => unawaited(seekTo(position.inMilliseconds / 1000.0)),
      onNext: () => unawaited(nextChapter()),
      onPrevious: () => unawaited(previousChapter()),
      onStop: () => unawaited(pause()),
      onSkipForward: (interval) => unawaited(skip((interval ?? const Duration(seconds: 30)).inSeconds.toDouble())),
      onSkipBackward: (interval) => unawaited(skip(-(interval ?? const Duration(seconds: 30)).inSeconds.toDouble())),
      onSetSpeed: (speed) => unawaited(setSpeed(speed)),
    );
    _controlSub = controls.controlEvents.listen((event) {
      if (router.route(event)) return;
      if (event is AudioInterruptionBeganEvent || event is AudioRouteOldDeviceUnavailableEvent) {
        unawaited(pause());
      }
    });
    unawaited(controls.setBackgroundMode(true));
    unawaited(
      controls.setControlsEnabled(
        canPlayPause: true,
        canGoNext: timeline.chapters.length > 1,
        canGoPrevious: timeline.chapters.length > 1,
        canSeek: true,
        canSkip: true,
        canSetSpeed: true,
        skipInterval: const Duration(seconds: 30),
      ),
    );
    final item = mediaItem;
    if (item != null) {
      unawaited(controls.updateMetadata(metadata: item, client: client, duration: _duration(timeline.totalSeconds)));
    }
  }

  void _publishState({bool force = false}) {
    unawaited(
      _controls?.updatePlaybackState(
        isPlaying: _playing,
        position: _duration(bookSeconds),
        speed: _speed,
        force: force,
      ),
    );
  }

  static Duration _duration(double seconds) => Duration(milliseconds: (seconds * 1000).round());
}
