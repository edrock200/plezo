part of 'tofa_client.dart';

/// Tofa's own pages beyond the library: Discover (`/discovery/*`), requests
/// (`/requests`, `/requests/rights`), seen and not-interested marks, the
/// profile's watch history (`/watch/history`) and its profiles
/// (`/profiles`, for switching without signing in again). Used by the
/// screens in `lib/screens/tofa/`.
extension TofaClientExtras on TofaClient {
  // --- Server features -------------------------------------------------------

  /// `GET /system/info`'s `requests_available` and `discover_enabled`; null
  /// fields when the read failed. Shared like the events capability read.
  Future<({bool? requests, bool? discover})> serverFeatures() async {
    try {
      final data = await _api.getJson('/api/v1/system/info');
      if (data is! Map) return (requests: null, discover: null);
      return (
        requests: data['requests_available'] is bool ? data['requests_available'] as bool : null,
        discover: data['discover_enabled'] is bool ? data['discover_enabled'] as bool : null,
      );
    } catch (e) {
      appLogger.d('[tofa] system info unavailable', error: e.runtimeType);
      return (requests: null, discover: null);
    }
  }

  // --- Discover --------------------------------------------------------------

  Future<TofaDiscoverPage> discoverPage() async =>
      TofaDiscoverPage.fromJson(await _api.getJson('/api/v1/discovery/page'));

  Future<({TofaDiscoverLane? lane, List<TofaDiscoverShelf> shelves})> discoverLane(String slug) async {
    final data = await _api.getJson('/api/v1/discovery/lanes/${TofaClient._seg(slug)}');
    return (
      lane: data is Map ? TofaDiscoverLane.fromJson(data['lane']) : null,
      shelves: [
        if (data is Map && data['shelves'] is List)
          for (final s in data['shelves'] as List) ?TofaDiscoverShelf.fromJson(s),
      ],
    );
  }

  /// One page of a shelf, from [cursor] (`next_cursor` of the last page).
  Future<TofaDiscoverShelf?> discoverShelf(String key, {String? cursor}) async => TofaDiscoverShelf.fromJson(
    await _api.getJson('/api/v1/discovery/shelf/${TofaClient._seg(key)}', query: {'cursor': ?cursor}),
  );

  Future<List<TofaRadarBucket>> discoverRadar() async =>
      TofaRadarBucket.listOf(await _api.getJson('/api/v1/discovery/radar'));

  Future<TofaDiscoverDetail> discoverDetail(TofaDiscoverItem item) async {
    final data = await _api.getJson('/api/v1/discovery/detail/${item.type}/${item.tmdbId}');
    return TofaDiscoverDetail.fromJson(data, item);
  }

  Future<TofaPersonPage> discoverPerson(int personId, String name) async =>
      TofaPersonPage.fromJson(await _api.getJson('/api/v1/discovery/people/$personId'), name);

  Future<void> followLane(String slug, bool follow) =>
      _api.send(follow ? 'PUT' : 'DELETE', '/api/v1/discovery/lanes/${TofaClient._seg(slug)}/follow');

  /// `PUT`/`DELETE /users/me/seen/{type}/{tmdb}`.
  Future<void> setSeen(TofaDiscoverItem item, bool seen) =>
      _api.send(seen ? 'PUT' : 'DELETE', '/api/v1/users/me/seen/${item.type}/${item.tmdbId}');

  /// `PUT`/`DELETE /users/me/not-interested/{type}/{tmdb}`.
  Future<void> setNotInterested(TofaDiscoverItem item, bool notInterested) =>
      _api.send(notInterested ? 'PUT' : 'DELETE', '/api/v1/users/me/not-interested/${item.type}/${item.tmdbId}');

  /// The library title a Discover item names, when it has one.
  Future<MediaItem?> discoverLibraryItem(TofaDiscoverItem item) async {
    final id = item.localMediaId;
    if (id == null) return null;
    return _fetchItem(id);
  }

  /// A Discover item's poster or backdrop URL: its path through
  /// [thumbnailUrl] (`/cache/{path}?st=`, as Tofa's web app draws Discover).
  String discoverImageUrl(TofaDiscoverItem item, {bool backdrop = false}) =>
      thumbnailUrl(backdrop ? item.backdropPath : item.posterPath);

  // --- Requests --------------------------------------------------------------

  /// Titles to request: `GET /search`'s `discover` hits
  /// (`DiscoverSearchResult`, from the server's metadata source).
  Future<List<TofaDiscoverItem>> searchDiscover(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final data = await _api.getJson(
      '/api/v1/search',
      query: {'q': q, 'discover_limit': '30', 'movie_limit': '0', 'actor_limit': '0'},
    );
    return TofaDiscoverItem.listOf(data is Map ? data['discover'] : null);
  }

  Future<TofaRequestRights> requestRights() async =>
      TofaRequestRights.fromJson(await _api.getJson('/api/v1/requests/rights'));

  Future<List<TofaRequest>> myRequests() async {
    final data = await _api.getJson('/api/v1/requests');
    return [
      if (data is Map && data['requests'] is List)
        for (final row in data['requests'] as List) ?TofaRequest.fromJson(row),
    ];
  }

  /// `POST /requests` for [item] (a series: every season; unverified, the
  /// spec gives `seasons` without its form, so none is sent). Returns the
  /// created request.
  Future<TofaRequest?> createRequest(TofaDiscoverItem item, {bool is4k = false}) async {
    final response = await _api.request(
      'POST',
      '/api/v1/requests',
      body: {'media_type': item.type, 'tmdb_id': item.tmdbId, 'title': item.title, if (is4k) 'is4k': true},
    );
    TofaApi.throwIfTofaError(response);
    final data = response.data;
    appLogger.i('[tofa] request created type=${item.type}');
    return data is Map ? TofaRequest.fromJson(data['request']) : null;
  }

  // --- Watch history ---------------------------------------------------------

  /// One page of `GET /watch/history`, older than [before] / [beforeId].
  Future<TofaHistoryPage> watchHistory({TofaHistoryEntry? after, int limit = 50}) async {
    final data = await _api.getJson(
      '/api/v1/watch/history',
      query: {
        'limit': '$limit',
        if (after?.startedAt != null) 'before': after!.startedAt!.toUtc().toIso8601String(),
        'before_id': ?after?.id,
      },
    );
    return TofaHistoryPage(
      items: [
        if (data is Map && data['items'] is List)
          for (final row in data['items'] as List) ?TofaHistoryEntry.fromJson(row),
      ],
      hasMore: data is Map && data['has_more'] == true,
    );
  }

  Future<void> deleteHistoryEntry(String id) => _api.send('DELETE', '/api/v1/watch/history/${TofaClient._seg(id)}');

  Future<void> clearWatchHistory() => _api.send('DELETE', '/api/v1/watch/history');

  /// The library item a history entry played: the episode in its series, else
  /// the title.
  Future<MediaItem?> historyItem(TofaHistoryEntry entry) async {
    final mediaId = entry.mediaId;
    if (mediaId == null) return null;
    final episode = entry.episodeId;
    if (episode != null) {
      final item = await _fetchItem(TofaMappers.episodeItemId(mediaId, episode));
      if (item != null) return item;
    }
    return _fetchItem(mediaId);
  }

  // --- Profiles --------------------------------------------------------------

  /// The account's profiles (`GET /profiles`), with this sign-in's token.
  Future<List<TofaProfile>> accountProfiles() async {
    final data = await _api.getJson('/api/v1/profiles');
    return [
      if (data is List)
        for (final row in data) ?TofaProfile.fromJson(row),
    ];
  }

  /// `POST /profiles/{id}/verify-pin` for [profile] (see
  /// `TofaAuthService.verifyPin` for the status mapping).
  Future<TofaPinResult> verifyProfilePin(TofaProfile profile, String pin) async {
    final response = await _api.request(
      'POST',
      '/api/v1/profiles/${TofaClient._seg(profile.id)}/verify-pin',
      body: {'pin': pin, 'remember_device': true},
      profile: false,
      headers: {'X-Profile-Id': profile.id},
    );
    if (response.statusCode == 200) {
      final data = response.data;
      final token = data is Map ? data['profile_token'] : null;
      if (token is! String || token.isEmpty) return const TofaPinWrong();
      LogRedactionManager.registerToken(token);
      final expires = data is Map ? data['expires_at'] : null;
      return TofaPinAccepted(token, expires is String ? DateTime.tryParse(expires) : null);
    }
    if (response.statusCode == 429) return const TofaPinTooManyTries();
    if (response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403) {
      return const TofaPinWrong();
    }
    TofaApi.throwIfTofaError(response);
    return const TofaPinWrong();
  }

  /// This sign-in acting as [profile]: same account and tokens, another
  /// Tofa profile (a connection of its own: `server/user/profile`).
  TofaConnection connectionForProfile(TofaProfile profile, {TofaPinAccepted? pin}) {
    final c = connection;
    return TofaConnection(
      id: TofaConnection.compoundId(serverId: c.serverId, userId: c.userId, profileId: profile.id),
      baseUrl: c.baseUrl,
      serverName: c.serverName,
      serverId: c.serverId,
      connectUrl: c.connectUrl,
      userId: c.userId,
      userName: c.userName,
      isAdministrator: c.isAdministrator,
      accessToken: c.accessToken,
      refreshToken: c.refreshToken,
      accessTokenExpiresAt: c.accessTokenExpiresAt,
      profileId: profile.id,
      profileName: profile.name,
      profileAvatarUrl: profile.avatarImageUrl,
      profileToken: pin?.profileToken,
      profileTokenExpiresAt: pin?.expiresAt,
      profileIsLocked: profile.isLocked,
      createdAt: DateTime.now(),
      lastAuthenticatedAt: DateTime.now(),
    );
  }

  /// A profile avatar URL Plezilo can draw: `avatar_image_url` through
  /// [thumbnailUrl] (absolute as it is, else `/cache/…?st=`; how Tofa's web
  /// app resolves image paths, 2026-11-26).
  String profileAvatarUrl(TofaProfile profile) => thumbnailUrl(profile.avatarImageUrl);

  // --- Subtitle search -------------------------------------------------------

  /// The file playing for [itemId] now (a multi-part set: the open part).
  String? playingFileId(String itemId) {
    for (final session in _sessions.values.toList().reversed) {
      if (session.itemId == itemId && !session.stopped) return session.fileId;
    }
    return _playingFileIds[itemId];
  }

  /// `GET /subtitles/fetch/files/{file}/candidates?language=` (ISO 639-1
  /// codes, as Plezilo's language picker gives them; unverified that the
  /// server takes those rather than 639-2).
  Future<TofaSubtitleCandidates> subtitleCandidates(String fileId, String language) async =>
      TofaSubtitleCandidates.fromJson(
        await _api.getJson(
          '/api/v1/subtitles/fetch/files/${TofaClient._seg(fileId)}/candidates',
          query: {'language': language},
        ),
      );

  /// `POST …/candidate`: the server fetches the pick in the background
  /// (202). Watch [fileSubtitleTracks] for it to appear.
  Future<void> selectSubtitleCandidate(String fileId, String candidateId, String language) async {
    await _api.send(
      'POST',
      '/api/v1/subtitles/fetch/files/${TofaClient._seg(fileId)}/candidate',
      body: {'candidate_id': candidateId, 'language': language},
    );
    appLogger.i('[tofa] subtitle candidate picked; waiting for the server to fetch it');
  }

  /// `DELETE …/subtitles/{language}`: removes the fetched subtitle.
  Future<void> removeFetchedSubtitle(String fileId, String language) => _api.send(
    'DELETE',
    '/api/v1/subtitles/fetch/files/${TofaClient._seg(fileId)}/subtitles/${TofaClient._seg(language)}',
  );

  /// The file's subtitle tracks (`GET /stream/{file}/subtitles`): indexes
  /// with their language, to spot a newly fetched one.
  Future<List<({int index, String? language, bool external})>> fileSubtitleTracks(String fileId) async {
    final data = await _api.getJson('/api/v1/stream/${TofaClient._seg(fileId)}/subtitles');
    return [
      if (data is List)
        for (final row in data.whereType<Map>())
          if (flexibleInt(row['index']) case final index?)
            (
              index: index,
              language: row['language'] is String ? row['language'] as String : null,
              external: row['external'] == true,
            ),
    ];
  }

  /// Waits for a subtitle track that is not in [before] to appear on
  /// [fileId] (the fetched pick), every [interval] up to [timeout]. Its
  /// index, or null when none came.
  Future<int?> waitForNewSubtitle(
    String fileId,
    Set<int> before, {
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(seconds: 30),
    Future<void> Function(Duration)? wait,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await (wait ?? Future<void>.delayed)(interval);
      try {
        final tracks = await fileSubtitleTracks(fileId);
        final fresh = tracks.where((t) => !before.contains(t.index)).firstOrNull;
        if (fresh != null) return fresh.index;
      } catch (e) {
        appLogger.d('[tofa] subtitle list read failed', error: e.runtimeType);
      }
    }
    return null;
  }
}
