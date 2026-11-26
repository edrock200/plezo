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

  /// A Discover item's poster or backdrop URL. A title in the library uses
  /// its own artwork route; otherwise `poster_path` is used when absolute,
  /// or (unverified, as for Silo's request posters) as a TMDB file path.
  String discoverImageUrl(TofaDiscoverItem item, {bool backdrop = false}) {
    final local = item.localMediaId;
    if (local != null) {
      return thumbnailUrl(
        TofaMappers.artworkPath(local, backdrop ? 'backdrop' : 'poster'),
        width: backdrop ? 780 : 342,
      );
    }
    final path = backdrop ? item.backdropPath : item.posterPath;
    if (path == null) return '';
    if (path.startsWith('https://') || path.startsWith('http://')) return path;
    if (path.startsWith('/api/')) return thumbnailUrl(path);
    if (path.startsWith('/')) return 'https://image.tmdb.org/t/p/${backdrop ? 'w780' : 'w342'}$path';
    return '';
  }

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

  /// A profile avatar URL Plezilo can draw: an absolute URL as is, a server
  /// route (`/api/...`, e.g. `/profiles/avatars/{file}`) signed with the image
  /// token (unverified: which auth avatars need), else none.
  String profileAvatarUrl(TofaProfile profile) {
    final url = profile.avatarImageUrl;
    if (url == null) return '';
    if (url.startsWith('https://') || url.startsWith('http://')) return url;
    if (url.startsWith('/api/')) return thumbnailUrl(url);
    return '';
  }
}
