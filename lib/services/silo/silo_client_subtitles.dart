part of 'silo_client.dart';

/// A refused or failed subtitle request, with the server's own explanation
/// when it gave one (the problem `detail`).
class SiloSubtitleException implements Exception {
  const SiloSubtitleException(this.message, {this.statusCode, this.code});

  final String? message;
  final int? statusCode;
  final String? code;

  @override
  String toString() => 'SiloSubtitleException($statusCode, $code)';
}

/// Subtitle search, download and "Translate with AI" for the playing file,
/// as Silo's TV player offers them (TvSubtitleSearchDialog,
/// TvAiTranslateDialog). The result is stored on the server; the player
/// reloads to list it.
mixin _SiloSubtitleMethods on MediaServerCacheMixin, _SiloPlaybackMethods {
  Future<SiloAiStatus>? _aiStatus;
  SiloAiStatus? _aiStatusValue;

  /// The AI status read so far (null until [aiStatus] answers).
  SiloAiStatus? get cachedAiStatus => _aiStatusValue;

  /// `GET /subtitles/ai/status`, read once per client and shared. A failed
  /// read counts as "off" and is asked again next time.
  Future<SiloAiStatus> aiStatus() {
    return _aiStatus ??= () async {
      try {
        final data = await _api.getJson('/api/v2/subtitles/ai/status', timeout: const Duration(seconds: 10));
        return _aiStatusValue = SiloAiStatus.fromJson(data);
      } catch (e) {
        appLogger.d('SiloClient: AI subtitle status unavailable', error: e.runtimeType);
        _aiStatus = null;
        return SiloAiStatus.off;
      }
    }();
  }

  /// `GET /subtitles/ai/quota`, read when the sheet opens. Null when the
  /// server does not say.
  Future<SiloAiQuota?> aiQuota() async {
    try {
      return SiloAiQuota.fromJson(await _api.getJson('/api/v2/subtitles/ai/quota'));
    } catch (e) {
      appLogger.d('SiloClient: AI subtitle quota unavailable', error: e.runtimeType);
      return null;
    }
  }

  /// The playing session of [itemId] and the tracks its file offers, or null
  /// when nothing of it is playing.
  SiloAiPlaybackContext? aiPlaybackContext(String itemId) {
    _SiloPlaybackSession? session;
    for (final s in _sessions.values) {
      if (s.itemId == itemId && !s.stopped) session = s;
    }
    final fileId = session?.fileId;
    if (session == null || fileId == null) return null;
    final subtitles = <SiloAiSubtitleSource>[];
    for (final entry in session.subtitleInventory) {
      final index = (entry['combined_index'] as num?)?.toInt();
      if (index == null || !SiloSubtitleRules.isTranslatable(entry)) continue;
      subtitles.add(
        SiloAiSubtitleSource(
          combinedIndex: index,
          source: entry['source']?.toString() ?? '',
          language: entry['language']?.toString(),
          label: entry['label']?.toString(),
          codec: entry['codec']?.toString(),
        ),
      );
    }
    final audio = <SiloAiAudioSource>[];
    var position = 0;
    for (final track in session.audioTracks) {
      audio.add(
        SiloAiAudioSource(
          index: (track['index'] as num?)?.toInt() ?? position,
          language: track['language']?.toString(),
          title: track['title']?.toString(),
          codec: track['codec']?.toString(),
          channels: (track['channels'] as num?)?.toInt(),
        ),
      );
      position++;
    }
    return SiloAiPlaybackContext(
      itemId: itemId,
      fileId: fileId,
      sessionId: session.sessionId,
      subtitleSources: subtitles,
      audioSources: audio,
      selectedAudioIndex: session.selectedAudioIndex,
    );
  }

  /// `POST /subtitles/ai/translate`. The request names the playback session
  /// (Silo Android #726): the server then runs the job in the foreground,
  /// transcribing from the playhead in short chunks, so progress moves within
  /// seconds; without it the whole file is extracted first. The server binds
  /// the session before it creates a job, so a 404 created nothing (the
  /// session ended, or another replica holds it): the request is sent once
  /// more without it and runs as a background job. Plezy polls the job and
  /// ignores the live cues the server streams to the session.
  Future<SiloAiJob> startAiJob({
    required SiloAiPlaybackContext context,
    required SiloAiJobKind kind,
    required int sourceIndex,
    required String sourceLanguage,
    required String targetLanguage,
    required double startPositionSeconds,
  }) async {
    Map<String, Object?> body({required bool withSession}) => {
      'media_file_id': context.fileId,
      'kind': kind.wire,
      'source_index': sourceIndex,
      'source_language': sourceLanguage,
      'target_language': targetLanguage,
      'start_position': startPositionSeconds,
      if (withSession && context.sessionId.isNotEmpty) 'session_id': context.sessionId,
    };

    var withSession = context.sessionId.isNotEmpty;
    var response = await _api.request('POST', '/api/v2/subtitles/ai/translate', body: body(withSession: withSession));
    if (withSession && response.statusCode == 404) {
      appLogger.i('SiloClient: AI subtitle session not found (404); sending again without it');
      withSession = false;
      response = await _api.request('POST', '/api/v2/subtitles/ai/translate', body: body(withSession: false));
    }
    _throwSubtitleError(response);
    final data = response.data;
    final job = SiloAiJob.fromJson(data is Map ? data['job'] : null);
    if (job == null) throw const SiloSubtitleException(null);
    return job;
  }

  /// `GET /subtitles/ai/jobs/{id}`; null when the job is gone (404).
  Future<SiloAiJob?> fetchAiJob(String jobId) async {
    final response = await _api.request('GET', '/api/v2/subtitles/ai/jobs/${Uri.encodeComponent(jobId)}');
    if (response.statusCode == 404) return null;
    _throwSubtitleError(response);
    final data = response.data;
    return SiloAiJob.fromJson(data is Map ? data['job'] : null);
  }

  /// `POST /subtitles/ai/jobs/{id}/cancel`, best effort.
  Future<void> cancelAiJob(String jobId) async {
    try {
      await _api.request(
        'POST',
        '/api/v2/subtitles/ai/jobs/${Uri.encodeComponent(jobId)}/cancel',
        timeout: const Duration(seconds: 10),
      );
    } catch (e) {
      appLogger.d('SiloClient: AI subtitle cancel failed', error: e.runtimeType);
    }
  }

  /// `POST /subtitles/search` for the playing file. There is no capability
  /// probe: "no providers configured" arrives as an error or a warning.
  Future<SiloSubtitleSearchResults> searchServerSubtitles({
    required String fileId,
    required List<String> languages,
  }) async {
    final response = await _api.request(
      'POST',
      '/api/v2/subtitles/search',
      body: {'media_file_id': fileId, 'languages': languages},
    );
    _throwSubtitleError(response);
    final data = response.data;
    final results = data is Map ? data['results'] : null;
    final warnings = data is Map ? data['warnings'] : null;
    return SiloSubtitleSearchResults(
      hits: results is List ? results.map(SiloSubtitleSearchHit.fromJson).nonNulls.toList() : const [],
      warnings: warnings is List
          ? warnings
                .map((w) => w is Map ? (siloProblemDetail(w) ?? w['message']?.toString()) : w?.toString())
                .nonNulls
                .toList()
          : const [],
    );
  }

  /// `POST /subtitles/download`: the server fetches [hit] and stores it for
  /// the file (never on the device). Returns the stored subtitle's id.
  Future<String> downloadServerSubtitle({required String fileId, required SiloSubtitleSearchHit hit}) async {
    final response = await _api.request(
      'POST',
      '/api/v2/subtitles/download',
      body: {
        'media_file_id': fileId,
        'provider': hit.provider,
        'subtitle_id': hit.id,
        'language': hit.language,
        'release_name': hit.releaseName,
        'score': hit.score ?? 0.0,
        'hearing_impaired': hit.hearingImpaired,
      },
    );
    _throwSubtitleError(response);
    final data = response.data;
    final subtitle = data is Map ? data['subtitle'] : null;
    final id = subtitle is Map ? subtitle['id']?.toString() ?? '' : '';
    if (id.isEmpty) throw const SiloSubtitleException(null);
    return id;
  }

  static void _throwSubtitleError(MediaServerResponse response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    throw SiloSubtitleException(
      siloProblemDetail(response.data),
      statusCode: status,
      code: siloProblemCode(response.data),
    );
  }
}
