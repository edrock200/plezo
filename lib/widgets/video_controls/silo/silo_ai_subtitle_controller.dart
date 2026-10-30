import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/silo/silo_client.dart';
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
        unawaited(_client.cancelAiJob(started.id));
        return;
      }
      job = started;
      phase = SiloAiPhase.running;
      notifyListeners();
      await _apply(started);
      if (phase == SiloAiPhase.running) _startPolling();
    } on SiloSubtitleException catch (e) {
      if (e.statusCode == 429) quota = await _client.aiQuota();
      _fail(e.message ?? t.videoControls.siloSubtitles.failed);
    } catch (e) {
      appLogger.w('Silo AI subtitles: request failed', error: e);
      _fail(t.videoControls.siloSubtitles.failed);
    }
  }

  void cancel() {
    final current = job;
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
      job = null;
      phase = SiloAiPhase.idle;
      notifyListeners();
    } else if (read.isFailed) {
      _stopPolling();
      _fail(read.errorMessage ?? s.failed, announce: true);
    } else if (read.isCompleted) {
      _stopPolling();
      final resultId = read.resultSubtitleId;
      if (resultId == null) {
        _fail(s.noResult, announce: true);
        return;
      }
      phase = SiloAiPhase.applying;
      notifyListeners();
      final outcome = await _tools.applyStored(resultId);
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
    super.dispose();
  }
}
