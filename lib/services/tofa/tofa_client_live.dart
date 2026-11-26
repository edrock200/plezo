part of 'tofa_client.dart';

/// Live TV on Tofa: channels (`GET /live/channels`), the guide
/// (`GET /live/guide`), playing a channel, and recording
/// (`GET /live/recordings`, `POST /live/recordings/scheduled`, the
/// `/live/recording-rules` routes).
///
/// Facts observed in Tofa's web app (2026-11-26), which the spec lacks:
/// - Every `/live/*` call carries `X-Tofa-Live-Capabilities: live_session`;
///   without it the server lists no channels for this client. The Live tab
///   needs the `live_tv` capability in `GET /system/info` and a channel.
/// - Playing a channel: `GET /live/channels/{id}/tune` (`viewer_id` to reuse
///   one) answers `viewer_id`, `tune_generation`, `mode` and `current`.
///   `mode: live_session` (provider and tuner channels): `POST
///   /live/viewers/{viewer}/session` with the playback profile, polled each
///   second until `live_edge_at` (15 s, 90 s while `ingest.state` is
///   connecting or buffering), then its `playlist_url`. Otherwise (library
///   channels) `current` is the row on air (`kind: media`, `media_file_id`,
///   `playout_id`, `in_ms`, `out_ms`, `start_at`, `end_at`): played through
///   `/stream/{file}/info` with `live_viewer_id`, `live_playout_id`,
///   `live_revision` and the resume point the row gives. `POST
///   /live/viewers/{viewer}/renew {current_session_id, current_playout_id}`
///   every `max(5, renew_after_seconds)` s; `DELETE
///   /live/viewers/{viewer}?tune_generation=&grace=skip` when it stops.
/// - `DELETE /live/recordings/{id}` cancels a recording; `PUT`/`DELETE
///   /live/favorites/{channel}` and the builtin tab of `GET /live/tabs`
///   (`GET /live/channels?tab_id=`) are the server-side favourites.
/// - The stream plays on the player's live path, never with the VOD
///   `live_start_index=0` start.
extension _TofaLive on TofaClient {
  /// Channels read per page and the most pages followed.
  static const channelPageSize = 100;

  /// What every `/live/*` call sends (Tofa's web app's `Ks`).
  static const liveHeaders = {'X-Tofa-Live-Capabilities': 'live_session'};
  static const maxChannelPages = 40;

  /// The guide's limits per call: 24 hours.
  static const guideWindow = Duration(hours: 24);
  static const maxGuidePages = 40;

  Future<Object> _liveGet(String path, {Map<String, dynamic>? query}) =>
      _api.getJson(path, query: query, headers: liveHeaders);

  Future<MediaServerResponse> _liveRequest(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    Duration? timeout,
  }) => _api.request(method, path, query: query, body: body, headers: liveHeaders, timeout: timeout);

  Future<MediaServerResponse> _liveSend(String method, String path, {Map<String, dynamic>? query, Object? body}) =>
      _api.send(method, path, query: query, body: body, headers: liveHeaders);

  /// The Live TV check, logged at info level (no tokens): `live_tv` in
  /// `GET /system/info`'s capabilities (when it lists any), then a channel.
  Future<bool> _liveAvailable() async {
    try {
      final info = await _api.getJson('/api/v1/system/info');
      final caps = info is Map ? info['capabilities'] : null;
      if (caps is List && !caps.contains('live_tv')) {
        appLogger.i('[tofa] live tv: the server does not offer it (no live_tv capability)');
        return false;
      }
    } catch (e) {
      appLogger.i('[tofa] live tv: system info unreadable (${e.runtimeType}); checking channels');
    }
    try {
      final data = await _liveGet('/api/v1/live/channels', query: {'limit': '1'});
      final rows = data is Map && data['channels'] is List ? data['channels'] as List : const [];
      appLogger.i('[tofa] live tv: ${rows.isEmpty ? 'no channel for this profile' : 'available'}');
      return rows.isNotEmpty;
    } on MediaServerHttpException catch (e) {
      // No Live access (403) or a server without Live (404): no Live TV.
      appLogger.i('[tofa] live tv check answered HTTP ${e.statusCode}');
      if (e.statusCode == 403 || e.statusCode == 404) return false;
      rethrow;
    }
  }

  Future<List<LiveTvChannel>> _liveChannels() async {
    final out = <LiveTvChannel>[];
    String? cursor;
    for (var page = 0; page < maxChannelPages; page++) {
      final data = await _liveGet('/api/v1/live/channels', query: {'limit': '$channelPageSize', 'cursor': ?cursor});
      if (data is! Map) break;
      for (final row in (data['channels'] is List ? data['channels'] as List : const []).whereType<Map>()) {
        final channel = _channel(row.cast<String, dynamic>());
        if (channel != null) out.add(channel);
      }
      final next = data['next_cursor'];
      if (next is! String || next.isEmpty || next == cursor) break;
      cursor = next;
    }
    appLogger.d('[tofa] live channels=${out.length}');
    return out;
  }

  LiveTvChannel? _channel(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final revision = flexibleInt(json['revision']);
    if (revision != null) _liveRevisions[id] = revision;
    final number = json['number'];
    return LiveTvChannel(
      key: id,
      identifier: id,
      title: name,
      thumb: TofaMappers.art(json['logo_image_url']),
      number: number is Map && number['display'] is String ? number['display'] as String : null,
      serverId: serverId.value,
      serverName: serverName,
    );
  }

  Future<List<LiveTvProgram>> _liveGuide(DateTime? from, DateTime? to) async {
    final start = (from ?? DateTime.now()).toUtc();
    final end = (to ?? start.add(const Duration(hours: 6))).toUtc();
    final out = <LiveTvProgram>[];
    for (var windowStart = start; windowStart.isBefore(end); windowStart = windowStart.add(guideWindow)) {
      final windowEnd = windowStart.add(guideWindow).isBefore(end) ? windowStart.add(guideWindow) : end;
      String? cursor;
      for (var page = 0; page < maxGuidePages; page++) {
        final data = await _liveGet(
          '/api/v1/live/guide',
          query: {
            'from': '${windowStart.millisecondsSinceEpoch}',
            'to': '${windowEnd.millisecondsSinceEpoch}',
            'cursor': ?cursor,
          },
        );
        if (data is! Map) break;
        for (final channel in (data['channels'] is List ? data['channels'] as List : const []).whereType<Map>()) {
          final channelId = channel['channel_id'];
          if (channelId is! String) continue;
          final revision = flexibleInt(channel['revision']);
          if (revision != null) _liveRevisions[channelId] = revision;
          for (final entry in (channel['entries'] is List ? channel['entries'] as List : const []).whereType<Map>()) {
            final program = _program(channelId, entry.cast<String, dynamic>());
            if (program != null) out.add(program);
          }
        }
        final next = data['next_cursor'];
        if (next is! String || next.isEmpty || next == cursor) break;
        cursor = next;
      }
    }
    // A programme spanning two windows comes in both.
    final seen = <String>{};
    return [
      for (final p in out)
        if (seen.add('${p.channelIdentifier}\u0000${p.key}\u0000${p.beginsAt}')) p,
    ];
  }

  static int? _epochSeconds(Object? iso) {
    if (iso is! String) return null;
    final parsed = DateTime.tryParse(iso);
    return parsed == null ? null : parsed.millisecondsSinceEpoch ~/ 1000;
  }

  LiveTvProgram? _program(String channelId, Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    if (id is! String || title is! String) return null;
    final episodeTitle = json['episode_title'] is String && (json['episode_title'] as String).isNotEmpty
        ? json['episode_title'] as String
        : null;
    final recording = json['recording'];
    final recordingId = recording is Map && recording['id'] is String ? recording['id'] as String : null;
    final ruleId = recording is Map && recording['rule_id'] is String ? recording['rule_id'] as String : null;
    final recordable = json['recordable'] == true && json['placeholder'] != true;
    return LiveTvProgram(
      key: id,
      ratingKey: id,
      // The record flow's seed: the channel and the airing
      // (`LiveRecordingSchedule`), only on an entry the guide marks recordable.
      guid: recordable ? _TofaLiveTvDvrSupport.airingGuid(channelId, id) : null,
      title: episodeTitle ?? title,
      grandparentTitle: episodeTitle == null ? null : title,
      summary: json['synopsis'] is String ? json['synopsis'] as String : null,
      type: json['episode_number'] != null || episodeTitle != null ? 'episode' : 'movie',
      year: flexibleInt(json['year']),
      beginsAt: _epochSeconds(json['start_at']),
      endsAt: _epochSeconds(json['end_at']),
      index: flexibleInt(json['episode_number']),
      parentIndex: flexibleInt(json['season_number']),
      thumb: TofaMappers.art(json['image_url']),
      channelIdentifier: channelId,
      premiere: json['is_new'] == true,
      subscriptionId: recordingId == null ? null : '${_TofaLiveTvDvrSupport.recordingPrefix}$recordingId',
      grandparentSubscriptionId: recordingId != null && ruleId != null
          ? '${_TofaLiveTvDvrSupport.rulePrefix}$ruleId'
          : null,
      serverId: serverId.value,
      serverName: serverName,
    );
  }

  /// The viewer id the last tune answered, reused on the next tune.
  String? get _lastViewerId => _liveViewer;

  static Never _liveRefused(MediaServerResponse response) {
    final message = tofaErrorMessage(response.data);
    appLogger.w('[tofa] live channel refused HTTP ${response.statusCode} error=${tofaErrorCode(response.data) ?? '-'}');
    throw PlaybackException(
      message ?? t.messages.playbackFailed,
      reason: response.statusCode == 503
          ? PlaybackFailureReason.serverUnavailable
          : response.statusCode == 403
          ? PlaybackFailureReason.playbackNotAllowed
          : PlaybackFailureReason.invalidPlaybackData,
    );
  }

  /// Tune [channelKey] and open its stream (see the file comment).
  Future<LiveTvPlaybackSession?> _startLive(
    String channelKey,
    TranscodeQualityPreset quality, {
    Future<void> Function(Duration)? wait,
  }) async {
    final tune = await _liveRequest(
      'GET',
      '/api/v1/live/channels/${TofaClient._seg(channelKey)}/tune',
      query: {'viewer_id': ?_lastViewerId},
      timeout: MediaServerTimeouts.tune,
    );
    if (tune.statusCode >= 400) _liveRefused(tune);
    final data = tune.data;
    if (data is! Map<String, dynamic>) return null;
    final viewerId = data['viewer_id'];
    if (viewerId is! String || viewerId.isEmpty) {
      appLogger.w('[tofa] live tune answered without a viewer');
      return null;
    }
    _liveViewer = viewerId;
    final generation = data['tune_generation'];
    final viewer = _TofaLiveViewer(this, viewerId, generation?.toString());
    try {
      final opened = data['mode'] == 'live_session'
          ? await _openLiveSession(channelKey, quality, viewer, wait: wait)
          : await _openLibraryRow(channelKey, quality, viewer, data);
      if (opened == null) await viewer.release();
      return opened;
    } catch (_) {
      await viewer.release();
      rethrow;
    }
  }

  /// A provider or tuner channel: `POST /live/viewers/{id}/session`, polled
  /// until the stream reaches the live edge.
  Future<LiveTvPlaybackSession?> _openLiveSession(
    String channelKey,
    TranscodeQualityPreset quality,
    _TofaLiveViewer viewer, {
    Future<void> Function(Duration)? wait,
  }) async {
    final kbps = quality.isOriginal ? null : quality.videoBitrateKbps;
    final body = {
      'profile': TofaPlaybackCaps.liveProfile(),
      'at': null,
      'audio_stream_index': null,
      'max_bitrate': ?kbps,
    };
    final started = DateTime.now();
    while (true) {
      final response = await _liveRequest(
        'POST',
        '/api/v1/live/viewers/${TofaClient._seg(viewer.id)}/session',
        body: body,
        timeout: MediaServerTimeouts.tune,
      );
      if (response.statusCode >= 400) _liveRefused(response);
      final session = response.data;
      if (session is! Map<String, dynamic>) return null;
      final ingest = session['ingest'] is Map ? session['ingest'] as Map : const {};
      if (ingest['state'] == 'failed_terminal') {
        appLogger.w('[tofa] live channel ingest failed reason=${ingest['reason'] ?? '-'}');
        throw PlaybackException(t.liveTv.tofaChannelUnavailable, reason: PlaybackFailureReason.serverUnavailable);
      }
      final starting = ingest['state'] == 'connecting' || ingest['state'] == 'buffering';
      final waited = DateTime.now().difference(started);
      final url = session['playlist_url'];
      final sessionId = session['session_id'];
      if (session['live_edge_at'] != null ||
          waited > (starting ? const Duration(seconds: 90) : const Duration(seconds: 15))) {
        if (url is! String || url.isEmpty || sessionId is! String) {
          appLogger.w('[tofa] live session answered without a stream');
          return null;
        }
        viewer.sessionId = sessionId;
        appLogger.i(
          '[tofa] live channel session ready mode=${(session['selection'] is Map ? (session['selection'] as Map)['mode'] : null) ?? '-'}',
        );
        return _TofaLiveTvPlaybackSession(this, channelKey, quality, _api.resolveUrl(url), viewer, null);
      }
      await (wait ?? Future<void>.delayed)(const Duration(seconds: 1));
    }
  }

  /// A library channel: the row on air, played as its file from where the
  /// row is now (`in_ms` plus the time since `start_at`, 3 s ahead, within
  /// the row), with the live parameters of `/stream/{file}/info`.
  Future<LiveTvPlaybackSession?> _openLibraryRow(
    String channelKey,
    TranscodeQualityPreset quality,
    _TofaLiveViewer viewer,
    Map<String, dynamic> tune,
  ) async {
    final row = tune['current'];
    if (row is! Map || row['kind'] != 'media' || row['media_file_id'] is! String || flexibleInt(row['in_ms']) == null) {
      appLogger.i('[tofa] live library channel has nothing on air right now');
      throw PlaybackException(t.liveTv.tofaChannelOffAir, reason: PlaybackFailureReason.noPlayableSource);
    }
    final fileId = row['media_file_id'] as String;
    final inMs = flexibleInt(row['in_ms'])!;
    final start = DateTime.tryParse(row['start_at']?.toString() ?? '');
    final end = DateTime.tryParse(row['end_at']?.toString() ?? '');
    var position = inMs;
    if (start != null) {
      final outMs = flexibleInt(row['out_ms']) ?? (end == null ? null : inMs + end.difference(start).inMilliseconds);
      position = inMs + DateTime.now().add(const Duration(seconds: 3)).difference(start).inMilliseconds;
      if (position < inMs) position = inMs;
      if (outMs != null && position > outMs - 1) position = outMs - 1;
    }
    final playoutId = row['playout_id']?.toString();
    final revision = tune['revision'];
    final response = await _api.request(
      'GET',
      '/api/v1/stream/${TofaClient._seg(fileId)}/info',
      query: {
        ...TofaPlaybackCaps.streamQuery(preset: quality, resumeTicks: position * 10000),
        'live_viewer_id': viewer.id,
        'live_playout_id': ?playoutId,
        'live_revision': ?revision?.toString(),
      },
      timeout: MediaServerTimeouts.tune,
    );
    if (response.statusCode >= 400) _liveRefused(response);
    final info = response.data;
    if (info is! Map<String, dynamic>) return null;
    final rawUrl = info['stream_url'];
    final sessionId = info['session_id'];
    final sessionToken = info['session_token'];
    if (rawUrl is! String || rawUrl.isEmpty || sessionId is! String || sessionToken is! String) {
      appLogger.w('[tofa] live channel answer had no stream');
      return null;
    }
    LogRedactionManager.registerRotatingToken(sessionToken);
    final session = _TofaStreamSession(sessionId: sessionId, token: sessionToken, itemId: channelKey, fileId: fileId);
    _sessions[sessionId] = session;
    viewer
      ..sessionId = sessionId
      ..playoutId = playoutId;
    appLogger.i('[tofa] live library channel play_method=${info['play_method']} decision=${info['decision_mode']}');
    return _TofaLiveTvPlaybackSession(this, channelKey, quality, _api.resolveUrl(rawUrl), viewer, session);
  }

  Future<void> _stopLiveSession(_TofaStreamSession session) async {
    if (session.stopped) return;
    session.stopped = true;
    _sessions.remove(session.sessionId);
    try {
      final response = await _api.request(
        'POST',
        '/api/v1/stream/s/${TofaClient._seg(session.sessionId)}/stopped',
        query: {'st': session.token},
        auth: false,
      );
      appLogger.d('[tofa] live stream stopped answered ${response.statusCode}');
    } catch (e) {
      appLogger.d('[tofa] live stream stop failed', error: e.runtimeType);
    }
  }
}

/// One tuned viewer: renewed on the server's schedule, deleted when it stops.
class _TofaLiveViewer {
  _TofaLiveViewer(this._client, this.id, this.generation);

  final TofaClient _client;
  final String id;
  final String? generation;
  String? sessionId;
  String? playoutId;
  Timer? _renewTimer;
  bool _released = false;

  /// `POST /live/viewers/{id}/renew`, then again after
  /// `max(5, renew_after_seconds)` s. A 401/403/404/410 ends renewing.
  Future<void> renew() async {
    if (_released) return;
    try {
      final response = await _client._liveRequest(
        'POST',
        '/api/v1/live/viewers/${TofaClient._seg(id)}/renew',
        body: {'current_session_id': sessionId, 'current_playout_id': playoutId},
      );
      if (_released) return;
      if (const {401, 403, 404, 410}.contains(response.statusCode)) {
        appLogger.i('[tofa] live viewer renewal refused HTTP ${response.statusCode}; not renewing');
        return;
      }
      final data = response.data;
      final after = data is Map ? flexibleInt(data['renew_after_seconds']) : null;
      _schedule(Duration(seconds: after == null || after < 5 ? 30 : after));
    } catch (e) {
      appLogger.d('[tofa] live viewer renewal failed', error: e.runtimeType);
      _schedule(const Duration(seconds: 15));
    }
  }

  void _schedule(Duration delay) {
    _renewTimer?.cancel();
    if (_released) return;
    _renewTimer = Timer(delay, () => unawaited(renew()));
  }

  /// `DELETE /live/viewers/{id}?tune_generation=&grace=skip`, once.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _renewTimer?.cancel();
    try {
      await _client._liveRequest(
        'DELETE',
        '/api/v1/live/viewers/${TofaClient._seg(id)}',
        query: {'tune_generation': ?generation, 'grace': 'skip'},
      );
    } catch (e) {
      appLogger.d('[tofa] live viewer release failed', error: e.runtimeType);
    }
  }
}

class _TofaLiveTvSupport implements LiveTvSupport, LiveTvRecordedItems {
  _TofaLiveTvSupport(this._client);

  final TofaClient _client;

  @override
  LiveTvDvrSupport? get dvr => _TofaLiveTvDvrSupport(_client);

  @override
  Future<bool> isAvailable() => _client._liveAvailable();

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) => _client._liveChannels();

  /// Finished recordings: `GET /live/recordings` (newest first) rows that
  /// ended (`actual_end`), without an `error`, with the `media_id` they play
  /// as ("A finished recording plays like any other title").
  @override
  Future<List<LiveTvRecording>> fetchRecordings() async {
    final data = await _client._liveGet('/api/v1/live/recordings');
    final rows = data is Map && data['recordings'] is List ? data['recordings'] as List : const [];
    return [
      for (final row in rows.whereType<Map<String, dynamic>>())
        if (row['actual_end'] != null && row['error'] == null && row['media_id'] is String && row['title'] is String)
          LiveTvRecording(
            id: row['media_id'] as String,
            title: row['title'] as String,
            subtitle: row['episode_title'] is String && (row['episode_title'] as String).isNotEmpty
                ? row['episode_title'] as String
                : null,
            channelName: row['channel_name'] is String ? row['channel_name'] as String : null,
            recordedAt: row['actual_start'] is String ? DateTime.tryParse(row['actual_start'] as String) : null,
          ),
    ];
  }

  @override
  Future<MediaItem?> recordingItem(LiveTvRecording recording) => _client._fetchItem(recording.id);

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) => _client._liveGuide(from, to);

  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) => _client._startLive(channelKey, quality);

  // Server-side favourites (observed in Tofa's web app, 2026-11-26): the
  // builtin tab of `GET /live/tabs` lists them (`GET /live/channels?tab_id=`),
  // `PUT`/`DELETE /live/favorites/{channel}` change them. The server keeps no
  // order of its own beyond the tab's.
  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => 'server://${_client.serverId.value}/tofa';

  @override
  String get favoriteStoreKey => 'tofa:${_client.connection.id}';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  Future<String?> _favoritesTabId() async {
    final data = await _client._liveGet('/api/v1/live/tabs');
    final tabs = data is Map && data['tabs'] is List ? data['tabs'] as List : const [];
    for (final tab in tabs.whereType<Map>()) {
      if (tab['builtin'] == true && tab['id'] != null) return tab['id'].toString();
    }
    return null;
  }

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) async {
    final tabId = await _favoritesTabId();
    checkCurrent?.call();
    if (tabId == null) return const [];
    final source = await buildFavoriteChannelSource();
    final out = <FavoriteChannel>[];
    String? cursor;
    for (var page = 0; page < _TofaLive.maxChannelPages; page++) {
      final data = await _client._liveGet(
        '/api/v1/live/channels',
        query: {'tab_id': tabId, 'limit': '${_TofaLive.channelPageSize}', 'cursor': ?cursor},
      );
      if (data is! Map) break;
      for (final row in (data['channels'] is List ? data['channels'] as List : const []).whereType<Map>()) {
        final channel = _client._channel(row.cast<String, dynamic>());
        if (channel != null) out.add(FavoriteChannel.fromLiveTvChannel(channel, source));
      }
      final next = data['next_cursor'];
      if (next is! String || next.isEmpty || next == cursor) break;
      cursor = next;
    }
    checkCurrent?.call();
    return out;
  }

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) async {
    final current = {for (final c in await fetchFavoriteChannels(checkCurrent: checkCurrent)) c.id};
    final wanted = {for (final c in channels) c.id};
    Object? firstError;
    StackTrace? firstStack;
    for (final (id, on) in [
      for (final id in wanted.difference(current)) (id, true),
      for (final id in current.difference(wanted)) (id, false),
    ]) {
      checkCurrent?.call();
      try {
        await _client._liveSend(on ? 'PUT' : 'DELETE', '/api/v1/live/favorites/${TofaClient._seg(id)}');
      } catch (e, st) {
        firstError ??= e;
        firstStack ??= st;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  }
}

/// One tuned channel: the stream URL, the viewer kept alive by renewals,
/// and (for a library channel) the file's stream session, whose progress
/// posts are the heartbeats. No time-shift in Plezilo.
class _TofaLiveTvPlaybackSession implements LiveTvPlaybackSession {
  _TofaLiveTvPlaybackSession(this._client, this._channelKey, this._quality, this._url, this._viewer, this._session) {
    unawaited(_viewer.renew());
  }

  final TofaClient _client;
  final String _channelKey;
  final TranscodeQualityPreset _quality;
  final String _url;
  final _TofaLiveViewer _viewer;
  final _TofaStreamSession? _session;

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.stopAndExit;

  @override
  CaptureBuffer? get captureBuffer => null;

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  bool get canTimeShift => false;

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) async =>
      offsetSeconds == null && subtitleTrack == null ? _url : null;

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) async {
    final session = _session;
    if (state == 'stopped') {
      await _end();
      return null;
    }
    if (session != null) {
      await _client._sendProgress(session, Duration(milliseconds: positionMs), paused: state == 'paused');
    }
    return null;
  }

  Future<void> _end() async {
    final session = _session;
    await Future.wait([_viewer.release(), if (session != null) _client._stopLiveSession(session)]);
  }

  @override
  Future<void> discard() => _end();

  /// A dropped stream (or a library row that ended) tunes the channel again,
  /// reusing the viewer, and releases this session.
  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) async {
    final replacement = await _client._startLive(_channelKey, _quality);
    if (replacement != null) unawaited(_end());
    return replacement;
  }
}

/// Recording on Tofa behind Plezilo's DVR contract (Plex-shaped models, as
/// the MediaBrowser adapter does):
/// - a *rule* is a `LiveRecordingRule`;
/// - a *scheduled recording* is a `LiveRecording` that has not ended
///   (`include=scheduled`);
/// - the *template* offers "this programme" (`POST /live/recordings/scheduled`)
///   and "every airing" (`POST /live/recording-rules` with
///   `from_airing_id`), both from the guide entry's channel and airing ids.
class _TofaLiveTvDvrSupport implements LiveTvDvrSupport {
  _TofaLiveTvDvrSupport(this._client);

  final TofaClient _client;

  static const recordingPrefix = 'rec:';
  static const rulePrefix = 'rule:';
  static const _airingPrefix = 'tofa-airing:';

  /// Rule settings (ids are `LiveRecordingRuleDraft` / `Edit` fields).
  static const _newOnly = 'new_only';
  static const _anyChannel = 'any_channel';
  static const _keepLast = 'keep_last';

  static String airingGuid(String channelId, String airingId) => '$_airingPrefix$channelId/$airingId';

  static ({String channelId, String airingId})? _parseAiring(String guid) {
    if (!guid.startsWith(_airingPrefix)) return null;
    final rest = guid.substring(_airingPrefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0 || slash == rest.length - 1) return null;
    return (channelId: rest.substring(0, slash), airingId: rest.substring(slash + 1));
  }

  static String? _strip(String key, String prefix) =>
      key.startsWith(prefix) && key.length > prefix.length ? key.substring(prefix.length) : null;

  @override
  Future<List<LiveTvDvr>> fetchDvrs() async => const [];

  @override
  Future<void> reloadGuide(String dvrId) async {}

  @override
  bool get supportsRuleProcessing => false;

  @override
  Future<void> processRecordingRules() async => throw UnsupportedError('Tofa has no rule re-evaluation route');

  @override
  Future<List<SubscriptionTemplate>> getSubscriptionTemplate(String guid) async {
    final airing = _parseAiring(guid);
    if (airing == null) return const [];
    final stash = jsonEncode({'channel_id': airing.channelId, 'airing_id': airing.airingId});
    return [
      SubscriptionTemplate(
        subscriptions: [
          MediaSubscription(
            key: '',
            type: MediaSubscription.typeEpisode,
            title: t.liveTv.recordEpisode,
            selected: true,
            parameters: stash,
          ),
          MediaSubscription(
            key: '',
            type: MediaSubscription.typeSeries,
            title: t.liveTv.recordSeries,
            parameters: stash,
            settings: _ruleSettings(const {}),
          ),
        ],
      ),
    ];
  }

  List<SubscriptionSetting> _ruleSettings(Map<String, dynamic> rule) => [
    SubscriptionSetting(
      id: _newOnly,
      label: t.liveTv.recordSettings.newOnly,
      type: 'bool',
      value: rule['new_only'] == true,
    ),
    SubscriptionSetting(
      id: _anyChannel,
      label: t.liveTv.recordSettings.anyChannel,
      type: 'bool',
      // A saved rule names its channel; null means any channel.
      value: rule.isEmpty ? false : rule['channel_id'] == null,
    ),
    SubscriptionSetting(
      id: _keepLast,
      label: t.liveTv.recordSettings.keepUpTo,
      summary: t.liveTv.recordSettings.keepUpToHint,
      type: 'int',
      value: flexibleInt(rule['keep_last']) ?? 0,
      minimum: 0,
    ),
  ];

  @override
  Future<MediaSubscription?> createRecordingRule(MediaSubscriptionCreateRequest request) async {
    final stash = request.parameters;
    final decoded = stash == null ? null : jsonDecode(stash);
    if (decoded is! Map || decoded['channel_id'] is! String || decoded['airing_id'] is! String) {
      throw ArgumentError.value(stash, 'request.parameters', 'missing the airing');
    }
    final channelId = decoded['channel_id'] as String;
    final airingId = decoded['airing_id'] as String;
    if (request.type == MediaSubscription.typeSeries) {
      final keep = flexibleInt(request.prefs[_keepLast]);
      final anyChannel = request.prefs[_anyChannel] == true;
      final response = await _client._liveRequest(
        'POST',
        '/api/v1/live/recording-rules',
        body: {
          'from_airing_id': airingId,
          if (anyChannel) 'any_channel': true else 'channel_id': channelId,
          'new_only': request.prefs[_newOnly] == true,
          if (keep != null && keep > 0) 'keep_last': keep,
        },
      );
      _throwRecordError(response);
      appLogger.i('[tofa] recording rule created');
      return null;
    }
    final response = await _client._liveRequest(
      'POST',
      '/api/v1/live/recordings/scheduled',
      body: {'airing_id': airingId, 'channel_id': channelId},
    );
    _throwRecordError(response);
    // 200 is the recording this profile had already set; 201 a new one.
    if (response.statusCode == 200) {
      throw const RecordingConflictException('This programme is already set to record');
    }
    appLogger.i('[tofa] recording scheduled');
    return null;
  }

  /// A 409 here is a tuner conflict or a quota, not a duplicate (which
  /// answers 200), so it is reported as a failure, never "already set".
  static void _throwRecordError(MediaServerResponse response) {
    if (response.statusCode < 400) return;
    appLogger.w('[tofa] recording refused HTTP ${response.statusCode} error=${tofaErrorCode(response.data) ?? '-'}');
    throw MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      statusCode: response.statusCode == 409 ? null : response.statusCode,
      responseData: response.data,
      message: 'HTTP ${response.statusCode}',
      display: tofaErrorMessage(response.data),
    );
  }

  @override
  Future<MediaSubscription?> updateRecordingRule(
    String subscriptionId,
    Map<String, Object?> prefs, {
    void Function()? checkCurrent,
  }) async {
    final id = _strip(subscriptionId, rulePrefix);
    if (id == null) throw ArgumentError.value(subscriptionId, 'subscriptionId', 'expected a "rule:" key');
    checkCurrent?.call();
    final keep = prefs.containsKey(_keepLast) ? flexibleInt(prefs[_keepLast]) : null;
    final body = <String, Object?>{
      if (prefs[_newOnly] is bool) 'new_only': prefs[_newOnly],
      if (prefs[_anyChannel] is bool) 'any_channel': prefs[_anyChannel],
      if (prefs.containsKey(_keepLast)) ...(keep == null || keep <= 0 ? {'keep_all': true} : {'keep_last': keep}),
    };
    final response = await _client._liveRequest(
      'PATCH',
      '/api/v1/live/recording-rules/${TofaClient._seg(id)}',
      body: body,
    );
    TofaApi.throwIfTofaError(response);
    final data = response.data;
    return data is Map<String, dynamic> ? _rule(data, const {}) : null;
  }

  @override
  Future<void> deleteRecordingRule(String subscriptionId) async {
    final id = _strip(subscriptionId, rulePrefix);
    if (id == null) {
      // A one-off recording ("rec:"): `DELETE /live/recordings/{id}`.
      return cancelGrab(subscriptionId);
    }
    await _client._liveSend(
      'DELETE',
      '/api/v1/live/recording-rules/${TofaClient._seg(id)}',
      query: {'cancel_upcoming': 'true'},
    );
  }

  /// `DELETE /live/recordings/{id}` (observed in Tofa's web app, 2026-11-26).
  @override
  Future<void> cancelGrab(String operationId) async {
    final id = _strip(operationId, recordingPrefix) ?? operationId;
    if (id.isEmpty) throw ArgumentError.value(operationId, 'operationId', 'must not be empty');
    await _client._liveSend('DELETE', '/api/v1/live/recordings/${TofaClient._seg(id)}');
    appLogger.i('[tofa] scheduled recording cancelled');
  }

  @override
  Future<List<MediaSubscription>> fetchSubscriptionMapping({
    required String providerId,
    required List<String> ratingKeys,
    bool includeStorage = true,
  }) async => const [];

  /// Recordings that have not ended: upcoming or in progress.
  Future<List<Map<String, dynamic>>> _pendingRecordings() async {
    final data = await _client._liveGet('/api/v1/live/recordings', query: {'include': 'scheduled'});
    final rows = data is Map && data['recordings'] is List ? data['recordings'] as List : const [];
    return [
      for (final row in rows.whereType<Map<String, dynamic>>())
        // `state` lists no values; an ended, missed or failed one has an
        // `actual_end`, `missed_reason` or `error`.
        if (row['actual_end'] == null && row['missed_reason'] == null && row['error'] == null) row,
    ];
  }

  @override
  Future<List<MediaGrabOperation>> fetchScheduledRecordings() async => [
    for (final row in await _pendingRecordings()) _grab(row),
  ];

  MediaGrabOperation _grab(Map<String, dynamic> row) {
    final id = row['id']?.toString() ?? '';
    final ruleId = row['rule_id'];
    final start = row['scheduled_for'] ?? row['requested_start'];
    final episodeTitle = row['episode_title'];
    return MediaGrabOperation(
      id: '$recordingPrefix$id',
      status: row['actual_start'] != null ? 'grabbing' : 'scheduled',
      metadata: {
        'title': episodeTitle is String && episodeTitle.isNotEmpty ? episodeTitle : row['title'],
        if (episodeTitle is String && episodeTitle.isNotEmpty) 'grandparentTitle': row['title'],
        'summary': row['description'],
        'beginsAt': _TofaLive._epochSeconds(start),
        'endsAt': _TofaLive._epochSeconds(row['requested_end']),
        'channelIdentifier': row['channel_id'],
        'channelCallSign': row['channel_name'],
        'index': row['episode'],
        'parentIndex': row['season'],
        'subscriptionID': '$recordingPrefix$id',
        if (ruleId is String && ruleId.isNotEmpty) 'grandparentSubscriptionID': '$rulePrefix$ruleId',
      },
    );
  }

  MediaSubscription _rule(Map<String, dynamic> rule, Map<String, List<MediaGrabOperation>> grabs) {
    final id = rule['id']?.toString() ?? '';
    return MediaSubscription(
      key: '$rulePrefix$id',
      type: MediaSubscription.typeSeries,
      title: rule['name'] is String ? rule['name'] as String : null,
      settings: _ruleSettings(rule),
      grabOperations: grabs['$rulePrefix$id'] ?? const [],
    );
  }

  @override
  Future<List<MediaSubscription>> fetchRecordingRules({bool includeGrabs = true, bool includeStorage = true}) async {
    final data = await _client._liveGet('/api/v1/live/recording-rules');
    final rules = [
      for (final row
          in (data is Map && data['rules'] is List ? data['rules'] as List : const [])
              .whereType<Map<String, dynamic>>())
        row,
    ];
    final grabs = <String, List<MediaGrabOperation>>{};
    if (includeGrabs && rules.isNotEmpty) {
      for (final row in await _pendingRecordings()) {
        final ruleId = row['rule_id'];
        if (ruleId is String && ruleId.isNotEmpty) grabs.putIfAbsent('$rulePrefix$ruleId', () => []).add(_grab(row));
      }
    }
    return [for (final rule in rules) _rule(rule, grabs)];
  }
}
