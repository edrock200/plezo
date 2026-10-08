part of 'silo_client.dart';

/// One live Silo playback session (`POST /api/v2/playback/start`).
class _SiloPlaybackSession {
  _SiloPlaybackSession({required this.sessionId, required this.installationId, required this.itemId});

  final String sessionId;
  final String installationId;
  final String itemId;

  /// Strictly increasing per session; the server rejects lower values.
  int sequence = 0;

  /// Minted once and reused on retries so a repeated stop is idempotent.
  final String stopId = const Uuid().v4();
  bool stopped = false;
}

mixin _SiloPlaybackMethods on MediaServerCacheMixin {
  SiloApi get _api;
  SiloMappingContext get _ctx;
  SiloConnection get connection;

  /// `installation_id` from `GET /api/v2/playback/capabilities`. Every
  /// playback mutation echoes it; a 409 `installation_changed` drops it.
  String? _installationId;

  final Map<String, _SiloPlaybackSession> _sessions = {};

  static String _watchPath(String id) => SiloApiCache.watchEndpoint(id);

  Future<String> _ensureInstallationId({bool refresh = false}) async {
    final cached = _installationId;
    if (cached != null && !refresh) return cached;
    final data = await _api.getJson('/api/v2/playback/capabilities');
    final protocols = data['protocol_versions'];
    final installation = data['installation_id']?.toString() ?? '';
    final ok =
        data['state'] == 'available' &&
        data['allowed'] != false &&
        protocols is List &&
        protocols.contains(3) &&
        installation.isNotEmpty;
    if (!ok) {
      throw PlaybackException(t.messages.playbackNotAllowedBody, reason: PlaybackFailureReason.playbackNotAllowed);
    }
    return _installationId = installation;
  }

  /// Watch detail for [itemId], through the cache so markers and versions
  /// stay readable offline.
  Future<Map<String, dynamic>?> _watchDetail(String itemId, {bool forceRefresh = false}) async {
    final path = _watchPath(itemId);
    if (!forceRefresh) {
      final fresh = await cache.getIfFresh(ServerId(cacheServerId), path, maxAge: playbackMetadataCacheFreshness);
      if (fresh != null) return fresh;
    }
    return fetchWithCacheFallback<Map<String, dynamic>>(
      cacheKey: path,
      networkCall: () => _api.request('GET', path),
      parseCache: (data) => data is Map<String, dynamic> ? data : null,
      parseResponse: (response) => response.data is Map<String, dynamic> ? response.data as Map<String, dynamic> : null,
      shouldFallback: (error) => error is MediaServerHttpException && error.isTransient,
    );
  }

  Future<String> _appVersion() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      if (pkg.version.isNotEmpty) return pkg.version;
    } catch (_) {}
    return '1.0';
  }

  /// Stop any session this client still holds for [itemId] — a reload for a
  /// new track or quality replaces it with a fresh one.
  Future<void> _stopStaleSessions(String itemId) async {
    final stale = _sessions.values.where((s) => s.itemId == itemId && !s.stopped).toList();
    for (final session in stale) {
      await _stopSession(session, position: null, isPaused: true);
    }
  }

  Future<Map<String, dynamic>> _startPlayback({
    required String fileId,
    required TranscodeQualityPreset preset,
    int? audioIndex,
    bool originalOnly = false,
  }) async {
    final appVersion = await _appVersion();
    final formFactor = _api.device.formFactor.playbackFormFactor;
    final metered = await _isMetered();
    Map<String, Object?> body(String installationId) => {
      'protocol_version': SiloPlaybackCaps.protocolVersion,
      'installation_id': installationId,
      'file_id': fileId,
      'profile_id': connection.profileId,
      'playback_attempt_id': const Uuid().v4(),
      'client_features': SiloPlaybackCaps.clientFeatures,
      'quality_preference': SiloPlaybackCaps.qualityPreference(preset),
      'bandwidth_cap_kbps': ?preset.videoBitrateKbps,
      'subtitle_fidelity_preference': 'preserve',
      'metered': metered,
      // Plezy seeks to the resume point itself, as it does on every backend,
      // so the stream always starts at the beginning of the source.
      'start_position': 0,
      'audio_track_index': ?audioIndex,
      'client_capabilities': SiloPlaybackCaps.clientCapabilities(),
      'client_playback_context': () {
        final context = SiloPlaybackCaps.playbackContext(appVersion: appVersion, formFactor: formFactor);
        if (originalOnly) {
          final deliveries = Map<String, Object?>.from(context['deliveries']! as Map);
          deliveries.removeWhere((key, _) => key != 'original_http');
          context['deliveries'] = deliveries;
        }
        return context;
      }(),
    };

    var installationId = await _ensureInstallationId();
    var response = await _api.request('POST', '/api/v2/playback/start', body: body(installationId));
    if (response.statusCode == 409 && siloProblemCode(response.data) == 'installation_changed') {
      installationId = await _ensureInstallationId(refresh: true);
      response = await _api.request('POST', '/api/v2/playback/start', body: body(installationId));
    }
    if (response.statusCode == 404) {
      throw PlaybackException(t.messages.playbackNoMediaSources, reason: PlaybackFailureReason.noPlayableSource);
    }
    throwIfHttpError(response);
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw PlaybackException(t.messages.playbackDataInvalid, reason: PlaybackFailureReason.invalidPlaybackData);
    }
    return {...data, '_installation_id': installationId};
  }

  /// Whether the active link is metered. Like the rest of Plezy, cellular
  /// alone counts as metered and Wi-Fi or Ethernet as not; an unknown link
  /// reads as unmetered.
  Future<bool> _isMetered() async {
    try {
      return (await ConnectivityProbe.check(timeout: const Duration(seconds: 1))).isCellularOnly;
    } catch (_) {
      return false;
    }
  }

  /// Make a server stream or subtitle URL absolute without touching its query.
  String _streamUrl(String url) => _api.resolveUrl(url);

  /// Subtitle routes carry no signed `st` query, so they need account auth.
  /// mpv sends the stream headers on them too; `token=` (which the server
  /// also accepts) covers players and paths that drop headers.
  String _subtitleUrl(String url) {
    final absolute = _streamUrl(url);
    final token = _api.accessToken;
    if (token == null || token.isEmpty) return absolute;
    final separator = absolute.contains('?') ? '&' : '?';
    return '$absolute${separator}token=${Uri.encodeQueryComponent(token)}';
  }

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final metadata = options.metadata;
    final Map<String, dynamic>? watch;
    try {
      // Refresh the access token before handing it to the player: the
      // stream URL and its headers are fixed for the session.
      await _api.refreshTokensIfHalfSpent();
      watch = await _watchDetail(metadata.id, forceRefresh: true);
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(classifyPlaybackFailure(error), stackTrace);
    }
    final versions = SiloMappers.watchVersions(watch);
    if (watch == null || versions.isEmpty) {
      throw PlaybackException(t.messages.playbackNoMediaSources, reason: PlaybackFailureReason.noPlayableSource);
    }
    final versionIndex = SiloMappers.selectVersionIndex(
      versions,
      watch,
      requestedIndex: options.selectedMediaIndex,
      requestedFileId: options.selectedMediaSourceId,
      preferredSignature: options.preferredVersionSignature,
    );
    final version = versions[versionIndex];
    final fileId = version['file_id']?.toString();
    if (fileId == null || fileId.isEmpty) {
      throw PlaybackException(t.messages.playbackNoMediaSources, reason: PlaybackFailureReason.noPlayableSource);
    }
    final availableVersions = versions.map(SiloMappers.version).nonNulls.toList();

    final audioIndex = switch (options.selectedAudioStreamId) {
      final id? when id > 0 => id - 1,
      _ => null,
    };

    await _stopStaleSessions(metadata.id);
    final Map<String, dynamic> decision;
    try {
      decision = await _startPlayback(fileId: fileId, preset: options.qualityPreset, audioIndex: audioIndex);
    } catch (error, stackTrace) {
      if (error is PlaybackException) rethrow;
      Error.throwWithStackTrace(classifyPlaybackFailure(error), stackTrace);
    }

    if (decision['outcome'] != 'playable') {
      final terminal = decision['terminal'];
      final message = terminal is Map ? terminal['message']?.toString() : null;
      throw PlaybackException(
        message == null || message.isEmpty ? t.messages.playbackFailed : message,
        reason: PlaybackFailureReason.noPlayableSource,
      );
    }
    final plan = decision['playback_plan'];
    final stream = plan is Map ? plan['stream'] : null;
    final rawUrl = stream is Map ? stream['url']?.toString() : null;
    final sessionId = (decision['session_id'] ?? (plan is Map ? plan['session_id'] : null))?.toString();
    if (plan is! Map || rawUrl == null || rawUrl.isEmpty || sessionId == null) {
      throw PlaybackException(t.messages.playbackDataInvalid, reason: PlaybackFailureReason.invalidPlaybackData);
    }
    final delivery = plan['delivery']?.toString() ?? 'original_http';
    final isOriginal = delivery == 'original_http';
    _sessions[sessionId] = _SiloPlaybackSession(
      sessionId: sessionId,
      installationId: decision['_installation_id'].toString(),
      itemId: metadata.id,
    );

    // Sidecars: the original file already carries its embedded subtitles,
    // so only external files are added there. A remux or transcode carries
    // none, so every text track the server can deliver is added.
    final sidecars = <PlaybackSubtitleSidecar>[];
    final sidecarIndexes = <int>{};
    final subtitle = plan['subtitle'];
    final inventory = subtitle is Map ? subtitle['inventory'] : null;
    if (inventory is List) {
      for (final entry in inventory.whereType<Map>()) {
        final url = entry['url']?.toString();
        if (entry['delivery'] != 'sidecar' || url == null || url.isEmpty) continue;
        final codec = entry['codec']?.toString().toLowerCase();
        if (codec == 'pgs' || codec == 'hdmv_pgs_subtitle' || codec == 'dvd_subtitle' || codec == 'vobsub') continue;
        if (isOriginal && entry['source'] != 'external') continue;
        final index = (entry['combined_index'] as num?)?.toInt();
        if (index != null) sidecarIndexes.add(index);
        sidecars.add(
          PlaybackSubtitleSidecar(
            sourceStreamId: index == null ? null : SiloMappers.trackId(index),
            track: SubtitleTrack.uri(
              _subtitleUrl(url),
              title: entry['label']?.toString(),
              language: entry['language']?.toString(),
              codec: codec,
              isDefault: entry['default'] == true,
              isForced: entry['forced'] == true,
            ),
          ),
        );
      }
    }

    final selected = plan['selected_tracks'];
    final selectedAudio = selected is Map && selected['audio'] is Map
        ? ((selected['audio'] as Map)['index'] as num?)?.toInt()
        : audioIndex;
    final videoUrl = _streamUrl(rawUrl);
    final mediaInfo = SiloMappers.sourceInfo(
      version,
      videoUrl: videoUrl,
      mediaIndex: versionIndex,
      ctx: _ctx,
      selectedAudioIndex: selectedAudio,
      sidecarSubtitleIndexes: sidecarIndexes,
    );

    appLogger.i(
      'Silo playback plan: delivery=$delivery reason=${plan['decision_reason']} '
      'quality=${SiloPlaybackCaps.qualityPreference(options.qualityPreset)}',
    );

    return PlaybackInitializationResult(
      availableVersions: availableVersions,
      videoUrl: videoUrl,
      mediaInfo: mediaInfo,
      subtitleSidecars: sidecars,
      isTranscoding: !isOriginal,
      fallbackReason: !options.qualityPreset.isOriginal && isOriginal ? TranscodeFallbackReason.directPlayOnly : null,
      activeAudioStreamId: selectedAudio == null ? null : SiloMappers.trackId(selectedAudio),
      playSessionId: sessionId,
      playMethod: isOriginal ? 'DirectPlay' : (delivery.contains('transcode') ? 'Transcode' : 'DirectStream'),
      selectedMediaIndex: versionIndex,
      selectedMediaSourceId: fileId,
    );
  }

  // ---------------------------------------------------------------------------
  // Downloads
  // ---------------------------------------------------------------------------

  static const _bitmapSubtitleCodecs = {'pgs', 'hdmv_pgs_subtitle', 'dvd_subtitle', 'vobsub', 'dvb_subtitle'};

  /// Download the original file of the chosen version.
  ///
  /// Plezy's downloader sends no headers, so the URL must authorise itself:
  /// `POST /api/v2/direct-download/links` mints exactly that (a short-lived,
  /// header-free link to the original file with Range support). The URL is
  /// signed, so the container rides in the fragment, where
  /// `downloadExtensionFromUrl` reads it and no request ever carries it.
  ///
  /// Embedded subtitles travel inside the original file. External subtitle
  /// files exist only as playback-session sidecars, so when the version has
  /// any, a direct-play session is opened just to list them; it is left to
  /// expire on the server because the sidecars are fetched after the video.
  /// That leg is best-effort: a failure reports
  /// [DownloadResolution.externalSubtitlesResolved] false so the manager
  /// retries subtitles later.
  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    final watch = await _watchDetail(item.id, forceRefresh: true);
    final versions = SiloMappers.watchVersions(watch);
    if (watch == null || versions.isEmpty) return const DownloadResolution(videoUrl: null);
    // Keep the watch detail for offline playback (markers, chapters, tracks).
    try {
      await cache.pin(ServerId(cacheServerId), _watchPath(item.id));
    } catch (_) {}
    final index = SiloMappers.selectVersionIndex(
      versions,
      watch,
      requestedIndex: mediaIndex,
      requestedFileId: mediaSourceId,
    );
    final version = versions[index];
    final fileId = version['file_id']?.toString();
    if (fileId == null || fileId.isEmpty) return const DownloadResolution(videoUrl: null);

    var url = await _directDownloadUrl(fileId);
    final container = version['container']?.toString().trim().toLowerCase();
    if (container != null && container.isNotEmpty && !url.contains('#')) url = '$url#container=$container';

    var subtitles = const <DownloadSubtitleSpec>[];
    var subtitlesResolved = true;
    final rawSubs = version['subtitle_tracks'];
    final hasExternal = rawSubs is List && rawSubs.whereType<Map>().any((track) => track['external'] == true);
    if (hasExternal) {
      try {
        subtitles = await _externalSubtitleSpecs(fileId);
      } catch (e) {
        appLogger.d('SiloClient: external subtitles for a download unavailable', error: e.runtimeType);
        subtitlesResolved = false;
      }
    }
    return DownloadResolution(
      videoUrl: url,
      mediaSourceId: fileId,
      externalSubtitles: subtitles,
      externalSubtitlesResolved: subtitlesResolved,
    );
  }

  /// A signed, header-free link to the original file. The account token is
  /// never put in a download URL: the downloader persists task URLs.
  Future<String> _directDownloadUrl(String fileId) async {
    final response = await _api.request('POST', '/api/v2/direct-download/links', body: {'file_id': fileId});
    if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501) {
      throw UnsupportedError('This Silo server does not offer direct downloads; update the server.');
    }
    throwIfHttpError(response);
    final url = response.data is Map ? (response.data as Map)['url']?.toString() : null;
    if (url == null || url.isEmpty) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: response.statusCode,
        message: 'Direct-download link missing from the response',
      );
    }
    return _api.resolveUrl(url);
  }

  Future<List<DownloadSubtitleSpec>> _externalSubtitleSpecs(String fileId) async {
    final decision = await _startPlayback(fileId: fileId, preset: TranscodeQualityPreset.original, originalOnly: true);
    final plan = decision['playback_plan'];
    final subtitle = plan is Map ? plan['subtitle'] : null;
    final inventory = subtitle is Map ? subtitle['inventory'] : null;
    if (decision['outcome'] != 'playable' || inventory is! List) return const [];
    return [
      for (final entry in inventory.whereType<Map>())
        if (entry['source'] == 'external' &&
            entry['delivery'] == 'sidecar' &&
            (entry['url']?.toString() ?? '').isNotEmpty &&
            !_bitmapSubtitleCodecs.contains(entry['codec']?.toString().toLowerCase()))
          DownloadSubtitleSpec(
            id: SiloMappers.trackId((entry['combined_index'] as num?)?.toInt() ?? 0),
            url: _subtitleUrl(entry['url'].toString()),
            // Sidecar URLs name the delivered format (`.vtt` for external SRT).
            codec: _sidecarCodec(entry['url'].toString()) ?? entry['codec']?.toString(),
            language: entry['language']?.toString(),
            languageCode: entry['language']?.toString(),
            forced: entry['forced'] == true,
            displayTitle: entry['label']?.toString(),
          ),
    ];
  }

  static String? _sidecarCodec(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return null;
    final ext = path.substring(dot + 1).toLowerCase();
    return const {'vtt': 'webvtt', 'srt': 'srt', 'ass': 'ass', 'ssa': 'ssa'}[ext];
  }

  /// External players cannot send headers, so the URL carries `token=`.
  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async {
    final watch = await _watchDetail(item.id, forceRefresh: true);
    final versions = SiloMappers.watchVersions(watch);
    if (versions.isEmpty) return null;
    final index = SiloMappers.selectVersionIndex(
      versions,
      watch,
      requestedIndex: mediaIndex,
      requestedFileId: mediaSourceId,
    );
    final fileId = versions[index]['file_id']?.toString();
    if (fileId == null) return null;
    final decision = await _startPlayback(fileId: fileId, preset: TranscodeQualityPreset.original, originalOnly: true);
    final plan = decision['playback_plan'];
    final stream = plan is Map ? plan['stream'] : null;
    final url = stream is Map ? stream['url']?.toString() : null;
    if (url == null || url.isEmpty) return null;
    final sessionId = decision['session_id']?.toString();
    if (sessionId != null) {
      _sessions[sessionId] = _SiloPlaybackSession(
        sessionId: sessionId,
        installationId: decision['_installation_id'].toString(),
        itemId: item.id,
      );
    }
    return ExternalPlaybackTarget(url: _subtitleUrl(url));
  }

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async {
    Map<String, dynamic>? watch;
    try {
      watch = await _watchDetail(itemId, forceRefresh: forceRefresh);
    } catch (e) {
      appLogger.d('SiloClient: watch detail unavailable for markers', error: e.runtimeType);
    }
    return _extrasFrom(
      watch,
      introPattern: introPattern,
      creditsPattern: creditsPattern,
      forceChapterFallback: forceChapterFallback,
    );
  }

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async {
    final watch = await cache.get(ServerId(cacheServerId), _watchPath(itemId));
    if (watch == null) return null;
    return _extrasFrom(
      watch,
      introPattern: introPattern,
      creditsPattern: creditsPattern,
      forceChapterFallback: forceChapterFallback,
    );
  }

  PlaybackExtras _extrasFrom(
    Map<String, dynamic>? watch, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) => SiloMappers.playbackExtras(
    watch,
    _ctx,
    introPattern: introPattern,
    creditsPattern: creditsPattern,
    forceChapterFallback: forceChapterFallback,
  );

  @override
  Future<MediaSourceInfo?> fetchCachedMediaSourceInfo(
    String itemId, {
    int mediaIndex = 0,
    String? mediaSourceId,
    String? preferredVersionSignature,
  }) async {
    final watch = await cache.get(ServerId(cacheServerId), _watchPath(itemId));
    final versions = SiloMappers.watchVersions(watch);
    if (versions.isEmpty) return null;
    final index = SiloMappers.selectVersionIndex(
      versions,
      watch,
      requestedIndex: mediaIndex,
      requestedFileId: mediaSourceId,
      preferredSignature: preferredVersionSignature,
    );
    return SiloMappers.sourceInfo(versions[index], videoUrl: '', mediaIndex: index, ctx: _ctx);
  }

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({
    required MediaItem item,
    required MediaSourceInfo mediaSource,
  }) async => null;

  @override
  double get watchedThreshold => 0.9;

  /// Session progress persists the resume point and scrobbles on the server
  /// (`progress_persistence: server`), so stopping marks the item played.
  @override
  bool get marksWatchedOnPlaybackStopped => true;

  // ---------------------------------------------------------------------------
  // Progress reporting
  // ---------------------------------------------------------------------------

  static double _seconds(Duration position) => position.inMilliseconds / 1000.0;

  Future<void> _sendProgress(_SiloPlaybackSession session, Duration position, bool isPaused) async {
    if (session.stopped) return;
    session.sequence++;
    final response = await _api.request(
      'POST',
      '/api/v2/playback/${Uri.encodeComponent(session.sessionId)}/progress',
      body: {
        'installation_id': session.installationId,
        'sequence': session.sequence,
        'position': _seconds(position),
        'is_paused': isPaused,
      },
    );
    if (response.statusCode == 404 || response.statusCode == 410) {
      // The server ended or forgot the session; nothing more to report.
      session.stopped = true;
      return;
    }
    throwIfHttpError(response);
  }

  Future<void> _stopSession(_SiloPlaybackSession session, {required Duration? position, required bool isPaused}) async {
    if (session.stopped) return;
    session.stopped = true;
    try {
      final response = await _api.request(
        'DELETE',
        '/api/v2/playback/${Uri.encodeComponent(session.sessionId)}',
        body: {
          'installation_id': session.installationId,
          'stop_id': session.stopId,
          if (position != null) ...{
            'sequence': ++session.sequence,
            'position': _seconds(position),
            'is_paused': isPaused,
          },
        },
      );
      if (response.statusCode != 404 && response.statusCode != 410) throwIfHttpError(response);
    } finally {
      _sessions.remove(session.sessionId);
    }
  }

  @override
  Future<void> reportPlaybackStarted({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    final session = playSessionId == null ? null : _sessions[playSessionId];
    if (session == null) return;
    await _sendProgress(session, position, false);
  }

  @override
  Future<void> reportPlaybackProgress({
    required String itemId,
    required Duration position,
    required Duration duration,
    bool isPaused = false,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    final session = playSessionId == null ? null : _sessions[playSessionId];
    if (session == null) {
      // A downloaded file plays without a server session.
      await _syncProgress(itemId, position: position, duration: duration);
      return;
    }
    await _sendProgress(session, position, isPaused);
  }

  @override
  Future<void> reportPlaybackStopped({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    PlaybackReportMetadata report = const PlaybackReportMetadata.live(),
  }) async {
    final session = playSessionId == null ? null : _sessions[playSessionId];
    if (session == null) {
      // A downloaded file, or progress queued offline: no session to stop.
      // Past the watched threshold the item is marked played, as a session
      // stop would have done; otherwise the resume point is written.
      final total = duration;
      if (total != null &&
          total > Duration.zero &&
          position.inMilliseconds >= total.inMilliseconds * watchedThreshold) {
        await _api.send('POST', '/api/v2/watched/${Uri.encodeComponent(itemId)}');
      } else {
        await _syncProgress(itemId, position: position, duration: total);
      }
      return;
    }
    await _stopSession(session, position: position, isPaused: true);
  }

  /// `POST /api/v2/sync/progress`: a resume point written without a playback
  /// session, stamped with the event time so an offline write merges
  /// last-write-wins.
  Future<void> _syncProgress(String itemId, {required Duration position, Duration? duration}) async {
    final response = await _api.send(
      'POST',
      '/api/v2/sync/progress',
      body: {
        'items': [
          {
            'media_item_id': itemId,
            'position_ms': position.inMilliseconds < 0 ? 0 : position.inMilliseconds,
            'duration_ms': duration == null || duration.isNegative ? 0 : duration.inMilliseconds,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
        ],
      },
    );
    final data = response.data;
    final items = data is Map ? data['items'] : null;
    final first = items is List && items.isNotEmpty ? items.first : null;
    if (first is Map && first['status'] == 'failure') {
      final failure = first['failure'];
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: failure is Map ? (failure['status'] as num?)?.toInt() : null,
        message: 'Silo progress sync failed',
      );
    }
  }
}
