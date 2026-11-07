import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/silo/silo_client.dart';
import '../../../services/silo/silo_live_subtitles.dart';
import '../../../services/silo/silo_subtitles.dart';
import '../../../utils/app_logger.dart';
import '../models/silo_subtitle_tools.dart';
import '../models/track_controls_state.dart';

enum SiloAiPhase { idle, submitting, running, applying, failed }

/// One "Translate with AI" request for a playing item, as Silo's TV player runs
/// it (TvAiTranslateDialog): the form, the job and its progress. It lives as
/// long as its client, keyed by item, so closing the sheet neither loses the
/// form nor stops a running job: the job is followed while the item plays and
/// its subtitles are loaded when it completes.
class SiloAiSubtitleController extends ChangeNotifier {
  SiloAiSubtitleController._(this._tools);

  static final _byClient = Expando<Map<String, SiloAiSubtitleController>>();

  /// The controller of [tools]' item, taking the latest [tools] (the controls
  /// rebuild them; the newest knows how to reach the player).
  static SiloAiSubtitleController of(SiloSubtitleTools tools) {
    final map = _byClient[tools.client] ??= {};
    final controller = map[tools.itemId] ??= SiloAiSubtitleController._(tools);
    controller._tools = tools;
    return controller;
  }

  @visibleForTesting
  static Duration pollInterval = const Duration(seconds: 2);

  SiloSubtitleTools _tools;
  SiloClient get _client => _tools.client;

  SiloAiPhase phase = SiloAiPhase.idle;
  SiloAiJob? job;
  String? error;
  SiloAiStatus status = SiloAiStatus.off;
  SiloAiQuota? quota;
  SiloAiPlaybackContext? playback;

  /// Form: work from subtitles (else audio), the chosen tracks and the target.
  bool fromSubtitles = true;
  int subtitlePos = 0;
  int audioPos = 0;
  String? targetCode;

  Timer? _poll;
  bool _polling = false;

  /// Live cues of the running job (Silo's web player behaviour): the lines
  /// the server streams to this session while it translates, playhead-first.
  /// Null when no live delivery is attached.
  SiloLiveCueTrack? liveCues;

  /// Bumped with every batch so the overlay repaints.
  final liveRevision = ValueNotifier<int>(0);

  SiloLiveSubtitleSocket? _live;
  StreamSubscription<SiloLiveSubtitleEvent>? _liveEvents;
  final List<SiloLiveSubtitleEvent> _earlyLive = [];
  bool _liveShowing = false;

  @visibleForTesting
  static Duration liveOpenTimeout = const Duration(seconds: 6);

  /// Replaces [SiloClient.openAiLiveSocket] in tests.
  @visibleForTesting
  static Future<SiloLiveSubtitleSocket?> Function(SiloAiPlaybackContext context)? debugOpenLive;

  /// Whether live cues are on screen in place of the player's own subtitle.
  bool get showsLiveCues => _liveShowing;

  /// The live line(s) at [position] of the player, or null.
  String? liveTextAt(Duration position) => _liveShowing ? liveCues?.textAt(position.inMilliseconds / 1000) : null;

  List<SiloAiSubtitleSource> get subtitleSources => playback?.subtitleSources ?? const [];
  List<SiloAiAudioSource> get audioSources => playback?.audioSources ?? const [];
  bool get canUseSubtitles => status.translate && subtitleSources.isNotEmpty;
  bool get canUseAudio => status.transcribe && audioSources.isNotEmpty;

  /// Translating a transcript needs AI translation too.
  bool get canTranslateTranscript => status.translate;
  bool get showsTarget => fromSubtitles || canTranslateTranscript;
  bool get quotaExhausted => !fromSubtitles && (quota?.exhausted ?? false);
  bool get busy => phase == SiloAiPhase.submitting || phase == SiloAiPhase.running || phase == SiloAiPhase.applying;

  /// Re-reads the status, quota and the playing file's tracks when the sheet
  /// opens; a running job keeps its progress, a failure its reason.
  Future<void> open({String? preferredTarget}) async {
    status = await _client.aiStatus();
    playback = _client.aiPlaybackContext(_tools.itemId);
    if (!canUseSubtitles) {
      fromSubtitles = false;
    } else if (!canUseAudio) {
      fromSubtitles = true;
    }
    final selectedAudio = playback?.selectedAudioIndex;
    if (selectedAudio != null) {
      final pos = audioSources.indexWhere((a) => a.index == selectedAudio);
      if (pos >= 0 && !busy) audioPos = pos;
    }
    if (subtitlePos >= subtitleSources.length) subtitlePos = 0;
    if (audioPos >= audioSources.length) audioPos = 0;
    targetCode ??= _initialTarget(preferredTarget);
    notifyListeners();
    final q = await _client.aiQuota();
    quota = q;
    notifyListeners();
  }

  static String _initialTarget(String? preferred) {
    final code = SiloSubtitleRules.twoLetter(preferred);
    return code != null && SiloSubtitleRules.aiLanguageCodes.contains(code) ? code : 'en';
  }

  void setFromSubtitles(bool value) {
    if (busy) return;
    fromSubtitles = value;
    notifyListeners();
  }

  void setSubtitlePos(int pos) {
    if (busy) return;
    subtitlePos = pos;
    notifyListeners();
  }

  void setAudioPos(int pos) {
    if (busy) return;
    audioPos = pos;
    notifyListeners();
  }

  void setTarget(String code) {
    if (busy) return;
    targetCode = code;
    notifyListeners();
  }

  Future<void> submit() async {
    final context = playback;
    if (busy || context == null || quotaExhausted) return;
    var target = targetCode ?? 'en';
    final SiloAiJobKind kind;
    final int sourceIndex;
    final String sourceLanguage;
    if (fromSubtitles) {
      if (subtitleSources.isEmpty) return;
      final source = subtitleSources[subtitlePos.clamp(0, subtitleSources.length - 1)];
      kind = SiloAiJobKind.translate;
      sourceIndex = source.combinedIndex;
      sourceLanguage = source.language ?? '';
    } else {
      if (audioSources.isEmpty) return;
      final source = audioSources[audioPos.clamp(0, audioSources.length - 1)];
      kind = SiloSubtitleRules.transcribeKind(
        audioLanguage: source.language,
        target: target,
        canTranslate: canTranslateTranscript,
      );
      // Without AI translation a transcribe_translate job is refused.
      if (!canTranslateTranscript) target = '';
      sourceIndex = source.index;
      sourceLanguage = source.language ?? '';
    }
    phase = SiloAiPhase.submitting;
    error = null;
    notifyListeners();
    try {
      await _openLive(context);
      if (phase != SiloAiPhase.submitting) {
        _endLive();
        return;
      }
      final started = await _client.startAiJob(
        context: context,
        kind: kind,
        sourceIndex: sourceIndex,
        sourceLanguage: sourceLanguage,
        targetLanguage: target,
        startPositionSeconds: _tools.position().inMilliseconds / 1000,
      );
      if (phase != SiloAiPhase.submitting) {
        // Cancelled while the request was out: cancel the job it made.
        _endLive();
        unawaited(_client.cancelAiJob(started.id));
        return;
      }
      job = started;
      phase = SiloAiPhase.running;
      if (started.liveDeliveryAttached && _live != null) {
        appLogger.i('Silo AI subtitles: live cues attached to the job');
        liveCues = SiloLiveCueTrack();
        final early = List.of(_earlyLive);
        _earlyLive.clear();
        early.forEach(_onLive);
      } else {
        // An already running or reused job streams to its own session only.
        _endLive();
      }
      notifyListeners();
      await _apply(started);
      if (phase == SiloAiPhase.running) _startPolling();
    } on SiloSubtitleException catch (e) {
      _endLive();
      if (e.statusCode == 429) quota = await _client.aiQuota();
      _fail(e.message ?? t.videoControls.siloSubtitles.failed);
    } catch (e) {
      _endLive();
      appLogger.w('Silo AI subtitles: request failed', error: e);
      _fail(t.videoControls.siloSubtitles.failed);
    }
  }

  /// Opens the control socket before the job exists (the server replays
  /// nothing); events that land before the creation answer are held.
  Future<void> _openLive(SiloAiPlaybackContext context) async {
    _endLive();
    SiloLiveSubtitleSocket? socket;
    final opening = (debugOpenLive ?? _client.openAiLiveSocket)(context);
    try {
      socket = await opening.timeout(liveOpenTimeout);
    } on TimeoutException {
      appLogger.i('Silo AI subtitles: live socket took too long; following the job instead');
      // A socket that opens after all must not stay open.
      unawaited(opening.then((opened) => opened?.close(), onError: (_) {}));
    } catch (e) {
      appLogger.d('Silo AI subtitles: live socket not opened', error: e.runtimeType);
    }
    if (socket == null) return;
    if (phase != SiloAiPhase.submitting) {
      unawaited(socket.close());
      return;
    }
    _live = socket;
    _liveEvents = socket.events.listen((event) {
      if (event.fileId != context.fileId) return;
      if (job == null) {
        if (_earlyLive.length < 200) _earlyLive.add(event);
        return;
      }
      _onLive(event);
    });
    unawaited(
      socket.done.then((_) {
        if (_live == socket) {
          appLogger.d('Silo AI subtitles: live socket closed; following the job');
          _live = null;
        }
      }),
    );
  }

  void _onLive(SiloLiveSubtitleEvent event) {
    final current = job;
    final track = liveCues;
    if (current == null || track == null || event.jobId != current.id || phase != SiloAiPhase.running) return;
    switch (event) {
      case SiloLiveStarted():
        break;
      case SiloLiveCues(:final cues, :final done, :final total):
        if (track.addAll(cues) == 0) return;
        if (!_liveShowing) {
          _liveShowing = true;
          appLogger.i('Silo AI subtitles: showing live cues ($done/$total)');
          _tools.setLiveCuesShowing?.call(true);
          notifyListeners();
        }
        liveRevision.value++;
      case SiloLiveCompleted() || SiloLiveFailed():
        // The job read decides (and loads the stored track).
        unawaited(_pollOnce());
    }
  }

  /// The user picked a subtitle track: show it, not the live cues. The job
  /// keeps running and its stored track is still offered when it completes.
  void stopLiveCues() {
    if (_live == null && liveCues == null) return;
    _endLive();
    notifyListeners();
  }

  /// Closes the socket and takes the live cues off screen.
  void _endLive() {
    _earlyLive.clear();
    unawaited(_liveEvents?.cancel());
    _liveEvents = null;
    final socket = _live;
    _live = null;
    if (socket != null) unawaited(socket.close());
    liveCues = null;
    if (_liveShowing) {
      _liveShowing = false;
      _tools.setLiveCuesShowing?.call(false);
      liveRevision.value++;
    }
  }

  void cancel() {
    final current = job;
    _endLive();
    _stopPolling();
    if (current != null) unawaited(_client.cancelAiJob(current.id));
    job = null;
    phase = SiloAiPhase.idle;
    error = null;
    notifyListeners();
  }

  void _startPolling() {
    _stopPolling();
    _poll = Timer.periodic(pollInterval, (_) => unawaited(_pollOnce()));
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> _pollOnce() async {
    final current = job;
    if (phase != SiloAiPhase.running || current == null) return _stopPolling();
    if (!_tools.isCurrent()) {
      // The item is no longer playing here; the job finishes on the server.
      _stopPolling();
      _endLive();
      job = null;
      phase = SiloAiPhase.idle;
      return;
    }
    if (_polling) return;
    _polling = true;
    try {
      final read = await _client.fetchAiJob(current.id);
      // A read answered after the job finished or was cancelled must not
      // apply it again.
      if (phase != SiloAiPhase.running || job?.id != current.id) return;
      if (read == null) {
        _stopPolling();
        _fail(t.videoControls.siloSubtitles.jobGone, announce: true);
        return;
      }
      job = read;
      notifyListeners();
      await _apply(read);
    } catch (e) {
      // Transport failures keep polling.
      appLogger.d('Silo AI subtitles: poll failed', error: e.runtimeType);
    } finally {
      _polling = false;
    }
  }

  Future<void> _apply(SiloAiJob read) async {
    final s = t.videoControls.siloSubtitles;
    if (read.isCancelled) {
      _stopPolling();
      _endLive();
      job = null;
      phase = SiloAiPhase.idle;
      notifyListeners();
    } else if (read.isFailed) {
      _stopPolling();
      _endLive();
      _fail(read.errorMessage ?? s.failed, announce: true);
    } else if (read.isCompleted) {
      _stopPolling();
      final resultId = read.resultSubtitleId;
      if (resultId == null) {
        _endLive();
        _fail(s.noResult, announce: true);
        return;
      }
      phase = SiloAiPhase.applying;
      notifyListeners();
      // Live cues stay on screen until the stored track is loaded.
      final outcome = await _tools.applyStored(resultId);
      _endLive();
      job = null;
      if (outcome == SubtitleDownloadApplyOutcome.applied) {
        phase = SiloAiPhase.idle;
        _tools.notify(s.ready);
      } else if (outcome == SubtitleDownloadApplyOutcome.superseded) {
        phase = SiloAiPhase.idle;
      } else {
        phase = SiloAiPhase.failed;
        error = s.readyNotApplied;
        _tools.notify(s.readyNotApplied, error: true);
      }
      notifyListeners();
    }
  }

  void _fail(String message, {bool announce = false}) {
    _endLive();
    phase = SiloAiPhase.failed;
    error = message;
    job = null;
    notifyListeners();
    // The sheet may be closed while the job ran (Silo Android #545): say why
    // over the player. Reopening the sheet shows it too.
    if (announce) _tools.notify(t.videoControls.siloSubtitles.failedWithReason(reason: message), error: true);
  }

  @override
  void dispose() {
    _stopPolling();
    _endLive();
    liveRevision.dispose();
    super.dispose();
  }
}
