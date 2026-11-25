import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../../connection/connection.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../media/artist_discography.dart';
import '../../media/download_resolution.dart';
import '../../media/ids.dart';
import '../../media/library_change_event.dart';
import '../../media/library_filter_result.dart';
import '../../media/library_genre.dart';
import '../../media/library_query.dart';
import '../../media/live_tv_support.dart';
import '../../media/lyrics.dart';
import '../../media/media_backend.dart';
import '../../media/media_file_info.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_person.dart';
import '../../media/media_playlist.dart';
import '../../media/media_server_client.dart';
import '../../media/media_sort.dart';
import '../../media/media_source_info.dart';
import '../../media/media_version.dart';
import '../../media/playback_report_metadata.dart';
import '../../media/server_capabilities.dart';
import '../../models/livetv_channel.dart';
import '../../models/livetv_program.dart';
import '../../models/transcode_quality_preset.dart';
import '../../mpv/mpv.dart';
import '../../utils/app_logger.dart';
import '../../utils/external_ids.dart';
import '../../utils/media_server_http_client.dart';
import '../../utils/url_utils.dart';
import '../api_cache.dart';
import '../download_artwork_helpers.dart';
import '../playback_initialization_types.dart';
import '../scrub_preview_source.dart';
import 'tofa_api.dart';
import 'tofa_api_cache.dart';
import 'tofa_mappers.dart';

/// [MediaServerClient] for a tofa server, spoken over its public `/api/v1`
/// HTTP API (see the `tofa-backend` skill).
///
/// One client is one [TofaConnection]: an account (or an admin API key) on
/// one server, acting as one tofa profile. Streaming, image and download URLs
/// carry short-lived `st` tokens, so the player needs no headers.
class TofaClient with MediaServerCacheMixin implements MediaServerClient, ScopedMediaServerClient, GracefullyCloseable {
  TofaClient._(this._connection, this._api);

  /// Build a client for [connection]. Fetches an image token up front so
  /// the first posters load.
  static Future<TofaClient> create(TofaConnection connection, {http.Client? httpClient}) async {
    final headers = await TofaClientHeaders.resolve(connection.deviceId);
    final client = _build(connection, headers, httpClient);
    unawaited(client._refreshImageToken());
    return client;
  }

  @visibleForTesting
  static TofaClient forTesting(TofaConnection connection, {http.Client? httpClient}) => _build(
    connection,
    TofaClientHeaders(deviceId: connection.deviceId, deviceName: 'test', deviceModel: '', platform: 'test', clientVersion: '1'),
    httpClient,
  );

  static TofaClient _build(TofaConnection connection, TofaClientHeaders headers, http.Client? httpClient) {
    late final TofaClient client;
    final api = TofaApi(
      baseUrl: connection.baseUrl,
      serverId: connection.serverId,
      headers: headers,
      tokens: TofaTokens(
        accessToken: connection.accessToken,
        refreshToken: connection.refreshToken,
        expiresAt: connection.accessTokenExpiresAt,
      ),
      isApiKey: connection.isApiKey,
      profileId: connection.profileId,
      profileToken: connection.profileToken,
      onTokensRefreshed: (tokens) => client._persistTokens(tokens),
      httpClient: httpClient,
    );
    client = TofaClient._(connection, api);
    return client;
  }

  TofaConnection _connection;
  final TofaApi _api;
  TofaConnection get connection => _connection;

  /// Called with the updated connection whenever the client changes its own
  /// credentials (a token refresh), so the registry can persist them.
  Future<void> Function(TofaConnection updated)? onConnectionUpdated;

  bool _offlineMode = false;
  bool _closed = false;

  String? _imageToken;
  DateTime _imageTokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _imageTokenFetch;
  Timer? _imageTokenTimer;

  final Map<String, String> _libraryTitles = {};

  /// Live stream sessions: session id → its `st` token.
  final Map<String, String> _sessionTokens = {};

  Future<void> _persistTokens(TofaTokens tokens) async {
    _connection = _connection.copyWith(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      accessTokenExpiresAt: tokens.expiresAt,
    );
    await onConnectionUpdated?.call(_connection);
  }

  TofaMappingContext get _ctx =>
      TofaMappingContext(serverId: _connection.serverId, serverName: _connection.serverName, libraryTitles: _libraryTitles);

  // ---------------------------------------------------------------------------
  // Identity and lifecycle
  // ---------------------------------------------------------------------------

  @override
  ServerId get serverId => ServerId(_connection.serverId);

  @override
  String get scopedServerId => _connection.id;

  @override
  String? get serverName => _connection.serverName;

  @override
  MediaBackend get backend => MediaBackend.tofa;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.tofa;

  @override
  final Object authenticationSessionId = Object();

  @override
  LibraryEventChannel? createLibraryEventChannel() => null;

  @override
  void close() {
    _closed = true;
    _imageTokenTimer?.cancel();
    _api.close();
  }

  @override
  Future<void> closeGracefully({Duration drainTimeout = const Duration(seconds: 2)}) async {
    _closed = true;
    _imageTokenTimer?.cancel();
    await _api.closeGracefully(drainTimeout: drainTimeout);
  }

  @override
  bool get isOfflineMode => _offlineMode;

  @override
  void setOfflineMode(bool offline) => _offlineMode = offline;

  @override
  ApiCache get cache => TofaApiCache.instance;

  TofaApiCache? get _tofaCache {
    try {
      return TofaApiCache.instance;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<HealthStatus> checkHealth() async {
    final status = await _probe();
    if (status != HealthStatus.offline) return status;
    // The current address is down: try the others the sign-in found.
    for (final url in _connection.fallbackUrls) {
      final previous = _api.baseUrl;
      _api.baseUrl = url;
      final retry = await _probe();
      if (retry != HealthStatus.offline) {
        appLogger.i('tofa: switched ${_connection.serverName} to another address');
        final others = [previous, ..._connection.fallbackUrls.where((u) => u != url)];
        _connection = _connection.copyWith(baseUrl: url, fallbackUrls: others);
        unawaited(onConnectionUpdated?.call(_connection));
        return retry;
      }
      _api.baseUrl = previous;
    }
    return HealthStatus.offline;
  }

  Future<HealthStatus> _probe() async {
    try {
      final response = await _api.request('GET', '/api/v1/users/me', timeout: const Duration(seconds: 10));
      if (response.statusCode == 200) {
        if (_imageToken == null) unawaited(_refreshImageToken());
        return HealthStatus.online;
      }
      if (response.statusCode == 401) {
        return _api.isApiKey || _api.sessionExpired ? HealthStatus.authError : HealthStatus.offline;
      }
      if (response.statusCode == 403) return HealthStatus.accessDenied;
      return HealthStatus.offline;
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 403) return HealthStatus.accessDenied;
      return HealthStatus.offline;
    } catch (_) {
      return HealthStatus.offline;
    }
  }

  @override
  Future<String?> getMachineIdentifier() async => _connection.serverId;

  // ---------------------------------------------------------------------------
  // Images
  // ---------------------------------------------------------------------------

  /// The hour-long image token; refreshed a minute before it lapses.
  Future<void> _refreshImageToken() {
    return _imageTokenFetch ??= () async {
      try {
        final data = await _api.getJson('/api/v1/auth/image-token');
        if (data is Map && data['token'] != null) {
          _imageToken = data['token'].toString();
          final seconds = data['expires_in'] is num ? (data['expires_in'] as num).toInt() : 3600;
          _imageTokenExpiresAt = DateTime.now().add(Duration(seconds: seconds));
          _imageTokenTimer?.cancel();
          if (!_closed) {
            final next = Duration(seconds: seconds > 120 ? seconds - 60 : 60);
            _imageTokenTimer = Timer(next, () => unawaited(_refreshImageToken()));
          }
        }
      } catch (e) {
        appLogger.w('tofa: image token fetch failed', error: e.runtimeType);
      } finally {
        _imageTokenFetch = null;
      }
    }();
  }

  Future<void> _ensureImageToken() async {
    if (_imageToken != null && DateTime.now().isBefore(_imageTokenExpiresAt)) return;
    if (_offlineMode) return;
    await _refreshImageToken();
  }

  bool _isOwnHost(String url) {
    final host = Uri.tryParse(url)?.host;
    if (host == null || host.isEmpty) return false;
    return [_api.baseUrl, ..._connection.fallbackUrls].any((base) => Uri.tryParse(base)?.host == host);
  }

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    if (path == null || path.isEmpty) return '';
    final size = width != null && width > 0 ? '&w=$width' : '';
    final token = _imageToken ?? '';
    if (path.startsWith('http://') || path.startsWith('https://')) {
      if (!_isOwnHost(path)) return path; // tofa's public metadata CDN: never add our token.
      return '$path${path.contains('?') ? '&' : '?'}st=$token$size';
    }
    final cachePath = path.startsWith('/cache/') ? path : '/cache/${path.startsWith('/') ? path.substring(1) : path}';
    return '${_api.resolveUrl(cachePath)}?st=$token$size';
  }

  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;

  /// tofa's media URLs authorise themselves with `st` tokens.
  @override
  Map<String, String> get streamHeaders => const {};

  // ---------------------------------------------------------------------------
  // Libraries and browsing
  // ---------------------------------------------------------------------------

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    unawaited(_ensureImageToken());
    final data = await _cachedJson('/api/v1/libraries');
    if (data is! List) return const [];
    final libraries = <MediaLibrary>[];
    for (final raw in data.whereType<Map<String, dynamic>>()) {
      final id = raw['id']?.toString();
      if (id == null) continue;
      final name = raw['name']?.toString() ?? '';
      _libraryTitles[id] = name;
      final kind = switch (raw['media_type']) {
        'movie' => MediaKind.movie,
        'tv' => MediaKind.show,
        _ => MediaKind.unknown,
      };
      libraries.add(
        MediaLibrary(
          id: id,
          backend: MediaBackend.tofa,
          title: name,
          kind: kind,
          defaultBrowseKinds: kind == MediaKind.unknown ? const [] : [kind],
          serverId: _connection.serverId,
          serverName: _connection.serverName,
        ),
      );
    }
    return libraries;
  }

  /// GET [path] with the offline-cache fallback; the decoded body or null.
  Future<dynamic> _cachedJson(String path, {Map<String, dynamic>? query}) async {
    final key = query == null || query.isEmpty ? path : '$path?${encodeQueryParameters(query)}';
    final cacheData = await fetchWithCacheFallback<dynamic>(
      cacheKey: key,
      networkCall: () async {
        final response = await _api.request('GET', path, query: query);
        // The shared cache stores objects only; wrap lists.
        if (response.data is List) {
          return MediaServerResponse(
            statusCode: response.statusCode,
            data: <String, dynamic>{'items': response.data},
            headers: response.headers,
            requestUri: response.requestUri,
          );
        }
        return response;
      },
      parseCache: (cached) => cached,
      parseResponse: (response) => response.data,
    );
    if (cacheData is Map && cacheData.length == 1 && cacheData['items'] is List) return cacheData['items'];
    return cacheData;
  }

  static const _sortFields = {'title', 'added_at', 'release_date', 'rating', 'random'};

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    unawaited(_ensureImageToken());
    final limit = query.limit <= 0 ? 50 : query.limit;
    final page = query.offset ~/ limit + 1;
    final skip = query.offset % limit;
    final sort = query.sort;
    final genre = query.filters.where((f) => f.field == 'genre' && !f.op.isNegated).expand((f) => f.values).firstOrNull;
    final params = <String, dynamic>{
      'library_id': libraryId,
      'page': page,
      'per_page': limit,
      if (sort != null && _sortFields.contains(sort.field)) 'sort': sort.field,
      if (sort != null) 'order': sort.direction == LibrarySortDirection.ascending ? 'asc' : 'desc',
      if (query.search != null && query.search!.isNotEmpty) 'q': query.search,
      'genre': ?genre,
    };
    final data = await _cachedJson('/api/v1/media', query: params);
    if (data is! Map) return const LibraryPage(items: [], totalCount: 0);
    final items = (data['items'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((m) => mapTitle(m, _ctx))
        .skip(skip)
        .toList();
    final total = data['total'] is num ? (data['total'] as num).toInt() : items.length;
    return LibraryPage(items: items, totalCount: total, offset: query.offset);
  }

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async =>
      LibraryFilterResult.empty;

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => const [
    MediaSort(key: 'title', title: 'Title', defaultDirection: 'asc'),
    MediaSort(key: 'added_at', title: 'Date added', defaultDirection: 'desc'),
    MediaSort(key: 'release_date', title: 'Release date', defaultDirection: 'desc'),
    MediaSort(key: 'rating', title: 'Rating', defaultDirection: 'desc'),
    MediaSort(key: 'random', title: 'Random'),
  ];

  @override
  Future<List<LibraryGenre>> fetchLibraryGenres(String libraryId, {required MediaKind libraryKind}) async {
    try {
      final data = await _cachedJson('/api/v1/media/genres', query: {'library_id': libraryId});
      final list = data is Map ? (data['genres'] ?? data['items']) : data;
      if (list is! List) return const [];
      return [
        for (final g in list)
          if ((g is Map ? g['name'] : g)?.toString() case final String name when name.isNotEmpty)
            LibraryGenre(title: name, filterValue: name),
      ];
    } catch (e) {
      appLogger.w('tofa: genres failed', error: e.runtimeType);
      return const [];
    }
  }

  @override
  Future<void> refreshLibraryMetadata(String libraryId) async {
    await _api.sendJson('POST', '/api/v1/libraries/${_seg(libraryId)}/refresh-metadata');
  }

  @override
  Future<void> scanLibrary(String libraryId) async {
    await _api.sendJson('POST', '/api/v1/libraries/${_seg(libraryId)}/scan');
  }

  static String _seg(String id) => Uri.encodeComponent(id);

  // ---------------------------------------------------------------------------
  // Items
  // ---------------------------------------------------------------------------

  /// The title's detail (`MediaDetail`), from the network or the cache.
  Future<Map<String, dynamic>?> _detail(String mediaId) async {
    try {
      final data = await _cachedJson(TofaApiCache.detailEndpoint(mediaId), query: const {'local_images': 'true'});
      return data is Map<String, dynamic> ? data : null;
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Watch progress for [fileIds] (missing ids are simply absent).
  Future<Map<String, Map<String, dynamic>>> _progressFor(List<String> fileIds) async {
    if (fileIds.isEmpty || _offlineMode) return const {};
    try {
      final data = await _api.sendJson('POST', '/api/v1/media/progress/batch', body: {'media_file_ids': fileIds});
      final items = data is Map ? data['items'] : null;
      if (items is! List) return const {};
      return {
        for (final p in items.whereType<Map<String, dynamic>>())
          if (p['media_file_id'] != null) p['media_file_id'].toString(): p,
      };
    } catch (e) {
      appLogger.w('tofa: progress batch failed', error: e.runtimeType);
      return const {};
    }
  }

  /// [MediaItem] for a title's detail, with the movie's own progress.
  Future<MediaItem> _titleFromDetail(Map<String, dynamic> detail) async {
    var item = mapTitle(detail, _ctx);
    final fileId = item.raw?[TofaRaw.fileId]?.toString();
    if (item.kind == MediaKind.movie && fileId != null) {
      final progress = (await _progressFor([fileId]))[fileId];
      if (progress != null && item is TofaMediaItem) {
        final completed = progress['completed'] == true;
        final position = progress['position_ms'] is num ? (progress['position_ms'] as num).toInt() : 0;
        item = item.copyWith(viewCount: completed ? 1 : 0, viewOffsetMs: !completed && position > 0 ? position : null);
      }
    }
    return item;
  }

  List<Map<String, dynamic>> _seasonsOf(Map<String, dynamic> detail) {
    final seasons = detail['seasons'];
    if (seasons is! List) return const [];
    final list = seasons.whereType<Map<String, dynamic>>().toList()
      ..sort((a, b) {
        final an = a['season_number'] is num ? (a['season_number'] as num).toInt() : 0;
        final bn = b['season_number'] is num ? (b['season_number'] as num).toInt() : 0;
        // Specials (season 0) after the numbered seasons.
        if (an == 0 && bn != 0) return 1;
        if (bn == 0 && an != 0) return -1;
        return an.compareTo(bn);
      });
    return list;
  }

  Future<List<MediaItem>> _episodesOf(Map<String, dynamic> season, MediaItem seasonItem, MediaItem show) async {
    final episodes = (season['episodes'] as List? ?? const []).whereType<Map<String, dynamic>>().toList()
      ..sort((a, b) => ((a['episode_number'] as num?) ?? 0).compareTo((b['episode_number'] as num?) ?? 0));
    final fileIds = [
      for (final e in episodes)
        if (primaryFile(e['files'])?['id'] case final Object id) id.toString(),
    ];
    final progress = await _progressFor(fileIds);
    return [
      for (final e in episodes)
        mapEpisode(e, seasonItem, show, _ctx, progress: progress[primaryFile(e['files'])?['id']?.toString()]),
    ];
  }

  @override
  Future<MediaItem?> fetchItem(String id) async {
    final parts = TofaIds.parse(id);
    final detail = await _detail(parts.mediaId);
    if (detail == null) return parts.seasonId == null && parts.episodeId == null ? await _cachedItem(id) : null;
    final title = await _titleFromDetail(detail);
    MediaItem? found = title;
    if (parts.seasonId != null || parts.episodeId != null) {
      found = null;
      for (final season in _seasonsOf(detail)) {
        final seasonItem = mapSeason(season, title, _ctx);
        if (parts.seasonId != null && season['id']?.toString() == parts.seasonId) {
          found = seasonItem;
          break;
        }
        if (parts.episodeId != null) {
          final episodes = (season['episodes'] as List? ?? const []).whereType<Map<String, dynamic>>();
          final match = episodes.where((e) => e['id']?.toString() == parts.episodeId).firstOrNull;
          if (match != null) {
            final fileId = primaryFile(match['files'])?['id']?.toString();
            final progress = fileId == null ? null : (await _progressFor([fileId]))[fileId];
            found = mapEpisode(match, seasonItem, title, _ctx, progress: progress);
            break;
          }
        }
      }
    }
    if (found != null) unawaited(_tofaCache?.putItem(ServerId(cacheServerId), found));
    return found;
  }

  Future<MediaItem?> _cachedItem(String id) async => _tofaCache?.getMetadata(ServerId(cacheServerId), id);

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async {
    final item = await fetchItem(id);
    if (item == null || item.kind != MediaKind.show) return (item: item, onDeckEpisode: null);
    final nextUp = item.raw?['next_up'];
    if (nextUp is Map && nextUp['episode_id'] != null) {
      final episode = await fetchItem(TofaIds.episode(item.id, nextUp['episode_id'].toString()));
      return (item: item, onDeckEpisode: episode);
    }
    return (item: item, onDeckEpisode: null);
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    final parts = TofaIds.parse(parentId);
    if (parts.episodeId != null) return const [];
    final detail = await _detail(parts.mediaId);
    if (detail == null) return const [];
    final show = mapTitle(detail, _ctx);
    if (show.kind != MediaKind.show) return const [];
    final seasons = _seasonsOf(detail);
    if (parts.seasonId == null) {
      return [for (final s in seasons) mapSeason(s, show, _ctx)];
    }
    final season = seasons.where((s) => s['id']?.toString() == parts.seasonId).firstOrNull;
    if (season == null) return const [];
    return _episodesOf(season, mapSeason(season, show, _ctx), show);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(String parentId, {int? start, int? size, AbortController? abort}) async =>
      _page(await fetchChildren(parentId), start, size);

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async {
    final parts = TofaIds.parse(parentId);
    if (parts.seasonId != null) return fetchChildren(parentId);
    final detail = await _detail(parts.mediaId);
    if (detail == null) return const [];
    final title = await _titleFromDetail(detail);
    if (title.kind == MediaKind.movie) return [title];
    final all = <MediaItem>[];
    for (final season in _seasonsOf(detail)) {
      all.addAll(await _episodesOf(season, mapSeason(season, title, _ctx), title));
    }
    return all;
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _page(await fetchPlayableDescendants(parentId), start, size);

  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) async {
    final episodes = await fetchPlayableDescendants(TofaIds.parse(seriesId).mediaId);
    return episodes.where((e) => (e.parentIndex ?? 1) != 0).toList();
  }

  LibraryPage<MediaItem> _page(List<MediaItem> all, int? start, int? size) {
    final from = (start ?? 0).clamp(0, all.length);
    final to = size == null ? all.length : (from + size).clamp(from, all.length);
    return LibraryPage(items: all.sublist(from, to), totalCount: all.length, offset: from);
  }

  @override
  Future<List<MediaItem>> fetchLibraryFolders(String libraryId, {void Function(List<MediaItem> itemsSoFar)? onPage}) async =>
      const [];

  @override
  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async => const [];

  // Music is not supported on tofa (movies and TV only).
  @override
  Future<List<MediaItem>> fetchArtistAlbums(MediaItem artist) async => const [];

  @override
  Future<List<ArtistDiscographyGroup>> fetchArtistDiscography(MediaItem artist) async => const [];

  @override
  Future<List<MediaItem>> fetchAlbumTracks(String albumId) async => const [];

  @override
  Future<List<MediaItem>> fetchInstantMix(String itemId, {int limit = 100}) async => const [];

  @override
  Future<Lyrics?> fetchLyrics(MediaItem track) async => null;

  // ---------------------------------------------------------------------------
  // Search, rows and recommendations
  // ---------------------------------------------------------------------------

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    if (_offlineMode || query.trim().isEmpty) return const [];
    unawaited(_ensureImageToken());
    final data = await _api.getJson(
      '/api/v1/search',
      query: {'q': query, 'limit': limit, 'movie_limit': limit, 'discover_limit': 0, 'actor_limit': 0},
      abort: abort,
    );
    final movies = data is Map ? data['movies'] : null;
    if (movies is! List) return const [];
    return movies.whereType<Map<String, dynamic>>().map((m) => mapTitle(m, _ctx)).toList();
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async => const [];

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async {
    unawaited(_ensureImageToken());
    final data = await _cachedJson('/api/v1/users/me/continue');
    if (data is! List) return const [];
    final items = data.whereType<Map<String, dynamic>>().map((m) => mapContinueItem(m, _ctx)).toList();
    return count == null ? items : items.take(count).toList();
  }

  static const _recentPrefix = 'tofa:recent';

  String _recentHubId(String? libraryId, String mediaType) => '$_recentPrefix|${libraryId ?? ''}|$mediaType';

  Future<List<MediaItem>> _recent(String? libraryId, String? mediaType, {int start = 0, required int limit}) async {
    final page = await fetchLibraryPagedContent(
      libraryId ?? '',
      query: LibraryQuery(
        offset: start,
        limit: limit,
        sort: const LibrarySort(field: 'added_at', direction: LibrarySortDirection.descending),
      ),
    ).catchError((_) => const LibraryPage<MediaItem>(items: [], totalCount: 0));
    return mediaType == null
        ? page.items
        : page.items.where((i) => i.kind == (mediaType == 'tv' ? MediaKind.show : MediaKind.movie)).toList();
  }

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async {
    final hubs = <MediaHub>[];
    try {
      final libraries = await fetchLibraries();
      final rows = await Future.wait([
        for (final library in libraries)
          fetchLibraryHubs(
            library.id,
            libraryName: library.title,
            limit: limit,
            includePlaybackHubs: false,
            libraryKind: library.kind,
            diagnostics: diagnostics,
          ),
      ]);
      for (final r in rows) {
        hubs.addAll(r);
      }
    } catch (e) {
      diagnostics?.recordFailure(e);
    }
    return hubs;
  }

  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) async {
    try {
      final items = await _recent(libraryId, null, limit: limit);
      if (items.isEmpty) return const [];
      return [
        MediaHub(
          id: _recentHubId(libraryId, ''),
          identifier: 'recentlyAdded',
          title: 'Recently added in $libraryName',
          type: libraryKind == MediaKind.show ? 'show' : 'movie',
          items: items,
          size: items.length,
          more: items.length >= limit,
          libraryId: libraryId,
          serverId: _connection.serverId,
          serverName: _connection.serverName,
        ),
      ];
    } catch (e) {
      diagnostics?.recordFailure(e);
      return const [];
    }
  }

  @override
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async =>
      (await fetchMoreHubItemsPage(hubId, start: 0, size: limit ?? 100)).items;

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(String hubId, {int? start, int? size, AbortController? abort}) async {
    if (hubId.startsWith(_recentPrefix)) {
      final parts = hubId.split('|');
      final libraryId = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
      final limit = size ?? 50;
      final items = await _recent(libraryId, null, start: start ?? 0, limit: limit);
      return LibraryPage(items: items, totalCount: (start ?? 0) + items.length + (items.length >= limit ? 1 : 0), offset: start ?? 0);
    }
    if (hubId.startsWith('tofa:similar|')) {
      return _page(await _similar(hubId.substring('tofa:similar|'.length)), start, size);
    }
    return const LibraryPage(items: [], totalCount: 0);
  }

  Future<List<MediaItem>> _similar(String mediaId) async {
    final data = await _api.getJson('/api/v1/media/${_seg(mediaId)}/similar');
    final owned = data is Map ? data['owned'] : null;
    if (owned is! List) return const [];
    return owned.whereType<Map<String, dynamic>>().map((m) => mapTitle(m, _ctx)).toList();
  }

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) async {
    final mediaId = TofaIds.parse(id).mediaId;
    try {
      final items = await _similar(mediaId);
      if (items.isEmpty) return const [];
      return [
        MediaHub(
          id: 'tofa:similar|$mediaId',
          identifier: 'similar',
          title: 'More like this',
          type: items.first.kind == MediaKind.show ? 'show' : 'movie',
          items: items.take(count).toList(),
          size: items.length,
          more: items.length > count,
          serverId: _connection.serverId,
          serverName: _connection.serverName,
        ),
      ];
    } catch (e) {
      appLogger.w('tofa: similar failed', error: e.runtimeType);
      return const [];
    }
  }

  @override
  Future<List<MediaItem>> fetchExtras(String id) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(String personId, {int? start, int? size, AbortController? abort}) async =>
      const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPersonDetails> fetchPersonDetails(String personId, {AbortController? abort}) async =>
      MediaPersonDetails.empty;

  // ---------------------------------------------------------------------------
  // Watch state
  // ---------------------------------------------------------------------------

  /// The media file [item] plays, reading its detail when the item lacks it.
  Future<String?> _fileIdOf(MediaItem item) async {
    final known = item.raw?[TofaRaw.fileId]?.toString();
    if (known != null && known.isNotEmpty) return known;
    final fresh = await fetchItem(item.id);
    return fresh?.raw?[TofaRaw.fileId]?.toString();
  }

  Future<void> _setWatched(MediaItem item, bool watched) async {
    final body = {'watched': watched};
    final parts = TofaIds.parse(item.id);
    switch (item.kind) {
      case MediaKind.show:
        await _api.sendJson('PUT', '/api/v1/shows/${_seg(parts.mediaId)}/watched', body: body);
      case MediaKind.season:
        final seasonId = parts.seasonId ?? item.raw?[TofaRaw.nativeId]?.toString();
        if (seasonId == null) throw UnsupportedError('tofa: season without id');
        await _api.sendJson('PUT', '/api/v1/seasons/${_seg(seasonId)}/watched', body: body);
      default:
        final fileId = await _fileIdOf(item);
        if (fileId == null) throw UnsupportedError('tofa: item has no media file');
        await _api.sendJson('PUT', '/api/v1/media/${_seg(fileId)}/watched', body: body);
    }
  }

  @override
  Future<void> markWatched(MediaItem item) => _setWatched(item, true);

  @override
  Future<void> markUnwatched(MediaItem item) => _setWatched(item, false);

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {
    final mediaId = TofaIds.parse(item.grandparentId ?? item.id).mediaId;
    await _api.sendJson('POST', '/api/v1/users/me/dismiss/${_seg(mediaId)}');
  }

  @override
  Future<void> rate(MediaItem item, double rating) async => throw UnsupportedError('tofa: no user ratings');

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) async => throw UnsupportedError('tofa: no favorites');

  // ---------------------------------------------------------------------------
  // Playlists, collections, deletion (not wired for tofa yet)
  // ---------------------------------------------------------------------------

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) async => null;

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) async =>
      const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) async =>
      throw UnsupportedError('tofa: no playlists');

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) async =>
      throw UnsupportedError('tofa: no playlists');

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) async => throw UnsupportedError('tofa: no playlists');

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) async => false;

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) async => false;

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<List<CollectionMembership>> fetchCollectionMemberships(Set<String> itemIds, {AbortController? abort}) async =>
      const [];

  @override
  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
  }) async => throw UnsupportedError('tofa: collections are not editable here');

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) async =>
      throw UnsupportedError('tofa: collections are not editable here');

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) async =>
      throw UnsupportedError('tofa: collections are not editable here');

  @override
  Future<bool> deleteCollection(MediaItem collection) async =>
      throw UnsupportedError('tofa: collections are not editable here');

  @override
  Future<bool> deleteMediaItem(MediaItem item) async => throw UnsupportedError('tofa: deletion is not wired');

  @override
  Future<MediaFileInfo?> getFileInfo(MediaItem item) async => null;

  // ---------------------------------------------------------------------------
  // External ids
  // ---------------------------------------------------------------------------

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    final detail = await _detail(TofaIds.parse(itemId).mediaId);
    if (detail == null) return const ExternalIds();
    String? imdb = detail['imdb_id']?.toString();
    int? tmdb = detail['tmdb_id'] is num ? (detail['tmdb_id'] as num).toInt() : null;
    int? tvdb;
    for (final p in (detail['provider_ids'] as List? ?? const []).whereType<Map>()) {
      final value = p['provider_id']?.toString();
      switch (p['provider']) {
        case 'imdb':
          imdb ??= value;
        case 'tmdb':
          tmdb ??= int.tryParse(value ?? '');
        case 'tvdb':
          tvdb = int.tryParse(value ?? '');
      }
    }
    return ExternalIds(imdb: imdb, tmdb: tmdb, tvdb: tvdb);
  }

  @override
  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async {
    final tmdb = ids.tmdb;
    if (tmdb == null || (kind != MediaKind.movie && kind != MediaKind.show)) return null;
    try {
      final data = await _api.getJson('/api/v1/media/by-tmdb/$tmdb');
      final list = data is List ? data : (data is Map ? (data['items'] ?? [data]) : const []);
      return [
        for (final m in (list as List).whereType<Map<String, dynamic>>())
          if (m['id'] != null) mapTitle(m, _ctx),
      ].where((i) => i.kind == kind).toList();
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 404) return const [];
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------------------

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async => PlaybackExtras(chapters: const [], markers: const []);

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async => null;

  @override
  Future<MediaSourceInfo?> fetchCachedMediaSourceInfo(
    String itemId, {
    int mediaIndex = 0,
    String? mediaSourceId,
    String? preferredVersionSignature,
    TranscodeQualityPreset? qualityPreset,
  }) async => null;

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({required MediaItem item, required MediaSourceInfo mediaSource}) async =>
      null;

  @override
  double get watchedThreshold => 0.9;

  /// Stop reports carry the position only; Plezilo marks watched explicitly.
  @override
  bool get marksWatchedOnPlaybackStopped => false;

  static const int _ticksPerMs = 10000;

  /// What Plezilo's player (mpv) plays directly.
  static const _capabilities = {
    'direct_play_video_codecs': 'hevc,h264,vp9,av1,mpeg2video,vc1,mpeg4',
    'direct_play_audio_codecs': 'truehd,dts,dtshd,eac3,ac3,aac,flac,pcm,opus,mp3,mp2,vorbis',
    'direct_play_containers': 'mkv,mp4,m2ts,ts,avi,mov,webm',
    'transcode_video_codecs': 'hevc,h264',
    'hdr_supported': 'true',
    'h264_10bit_supported': 'true',
    'hevc_10bit_supported': 'true',
    'deinterlacing_supported': 'true',
    'client_render_bitmap_subtitles': 'true',
    'include_text_subtitles': 'true',
  };

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final item = options.metadata;
    var versions = item.mediaVersions ?? const <MediaVersion>[];
    if (versions.isEmpty) {
      final fresh = await fetchItem(item.id);
      versions = fresh?.mediaVersions ?? const [];
    }
    var index = options.selectedMediaIndex;
    if (options.selectedMediaSourceId != null) {
      final byId = versions.indexWhere((v) => v.id == options.selectedMediaSourceId);
      if (byId >= 0) index = byId;
    }
    if (index < 0 || index >= versions.length) index = 0;
    final fileId = versions.isNotEmpty ? versions[index].id : await _fileIdOf(item);
    if (fileId == null || fileId.isEmpty) {
      throw const PlaybackException('No playable file', reason: PlaybackFailureReason.noPlayableSource);
    }
    final preset = options.forceTranscode && options.qualityPreset == TranscodeQualityPreset.original
        ? TranscodeQualityPreset.original
        : options.qualityPreset;
    final startMs = options.startPosition?.inMilliseconds ?? 0;
    final params = <String, dynamic>{
      ..._capabilities,
      'subtitle_contract_version': 2,
      'resume_ticks': startMs * _ticksPerMs,
      if (preset.videoBitrateKbps != null) 'max_bitrate': preset.videoBitrateKbps,
      if (preset == TranscodeQualityPreset.original && !options.forceTranscode) 'quality_mode': 'original',
      if (options.forceTranscode) 'force_method': 'transcode',
      'audio_stream_index': ?options.selectedAudioStreamId,
    };
    final MediaServerResponse response;
    try {
      response = await _api.request('GET', '/api/v1/stream/${_seg(fileId)}/info', query: params);
    } on MediaServerHttpException catch (e) {
      throw classifyPlaybackFailure(e);
    }
    if (response.statusCode == 401) {
      throw const PlaybackException('Sign in again', reason: PlaybackFailureReason.authenticationRequired);
    }
    if (response.statusCode == 403) {
      throw const PlaybackException('Not allowed', reason: PlaybackFailureReason.playbackNotAllowed);
    }
    if (response.statusCode >= 500) {
      throw const PlaybackException('Server unavailable', reason: PlaybackFailureReason.serverUnavailable);
    }
    throwIfHttpError(response);
    final data = response.data;
    if (data is! Map<String, dynamic> || data['stream_url'] == null) {
      throw const PlaybackException('Bad playback answer', reason: PlaybackFailureReason.invalidPlaybackData);
    }
    final sessionId = data['session_id']?.toString() ?? '';
    final sessionToken = data['session_token']?.toString() ?? '';
    if (sessionId.isNotEmpty) _sessionTokens[sessionId] = sessionToken;
    final playMethod = data['play_method']?.toString() ?? 'DirectPlay';
    final direct = playMethod == 'DirectPlay';
    final videoUrl = _api.resolveUrl(data['stream_url'].toString());

    final selectedAudio = data['selected_audio_stream_index'] is num
        ? (data['selected_audio_stream_index'] as num).toInt()
        : null;
    final audioTracks = <MediaAudioTrack>[
      for (final (i, a) in (data['audio_tracks'] as List? ?? const []).whereType<Map>().indexed)
        MediaAudioTrack(
          id: (a['index'] as num?)?.toInt() ?? i,
          index: i + 1,
          codec: a['codec']?.toString(),
          language: a['language']?.toString(),
          languageCode: a['language']?.toString(),
          title: a['title']?.toString(),
          channels: (a['channels'] as num?)?.toInt(),
          selected: selectedAudio == null ? i == 0 : (a['index'] as num?)?.toInt() == selectedAudio,
        ),
    ];
    final subtitleTracks = <MediaSubtitleTrack>[];
    final sidecars = <PlaybackSubtitleSidecar>[];
    for (final (i, s) in (data['subtitle_tracks'] as List? ?? const []).whereType<Map>().indexed) {
      final streamIndex = (s['index'] as num?)?.toInt() ?? i;
      final external = s['external'] == true;
      final textual = s['render'] != 'bitmap';
      // A transcoded stream carries no subtitles of its own; text tracks
      // come as files. Embedded tracks of a direct-played file stay in it.
      final asFile = textual && (external || !direct) && sessionId.isNotEmpty;
      subtitleTracks.add(
        MediaSubtitleTrack(
          id: streamIndex,
          index: i + 1,
          codec: s['codec']?.toString(),
          language: s['language']?.toString(),
          languageCode: s['language']?.toString(),
          title: s['title']?.toString(),
          selected: false,
          forced: s['forced'] == true,
          external: external,
          usesExternalDelivery: asFile,
        ),
      );
      if (asFile) {
        final url = _api.resolveUrl(
          '/api/v1/stream/s/${_seg(sessionId)}/subtitles/$streamIndex/full.vtt?st=${Uri.encodeQueryComponent(sessionToken)}',
        );
        sidecars.add(
          PlaybackSubtitleSidecar(
            sourceStreamId: streamIndex,
            track: SubtitleTrack.uri(
              url,
              title: s['title']?.toString(),
              language: s['language']?.toString(),
              codec: 'webvtt',
              isForced: s['forced'] == true,
            ),
          ),
        );
      }
    }
    final startTicks = data['start_position_ticks'] is num ? (data['start_position_ticks'] as num).toInt() : 0;
    final mediaInfo = MediaSourceInfo(
      videoUrl: videoUrl,
      audioTracks: audioTracks,
      subtitleTracks: subtitleTracks,
      chapters: const [],
      mediaSourceId: fileId,
      mediaIndex: index,
      // A transcode starting mid-file begins its timeline at the resume point.
      timelineOffset: direct ? Duration.zero : Duration(milliseconds: startTicks ~/ _ticksPerMs),
      defaultAudioStreamIndex: selectedAudio,
    );
    return PlaybackInitializationResult(
      availableVersions: versions,
      videoUrl: videoUrl,
      mediaInfo: mediaInfo,
      subtitleSidecars: sidecars,
      isTranscoding: !direct,
      activeAudioStreamId: selectedAudio,
      playSessionId: sessionId.isEmpty ? null : sessionId,
      playMethod: playMethod,
      selectedMediaIndex: index,
    );
  }

  Future<void> _sessionProgress(String sessionId, Duration position, {bool paused = false, bool ended = false}) async {
    final token = _sessionTokens[sessionId];
    if (token == null) return;
    final response = await _api.request(
      'POST',
      '/api/v1/stream/s/${_seg(sessionId)}/progress',
      query: {'st': token},
      // Ticks, not milliseconds: see the tofa-backend skill.
      body: {'position_ticks': position.inMilliseconds * _ticksPerMs, 'is_paused': paused, 'ended': ended},
    );
    final rotated = response.headers['x-profile-token'];
    if (rotated != null && rotated.isNotEmpty) _api.profileToken = rotated;
  }

  Future<void> _fileProgress(String itemId, Duration position, Duration? duration) async {
    final item = await fetchItem(itemId);
    if (item == null) return;
    final fileId = await _fileIdOf(item);
    if (fileId == null) return;
    final ended =
        duration != null && duration > Duration.zero && position.inMilliseconds >= duration.inMilliseconds * watchedThreshold;
    await _api.sendJson(
      'PUT',
      '/api/v1/media/${_seg(fileId)}/progress',
      body: {'position_ms': position.inMilliseconds, 'ended': ended},
    );
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
    if (playSessionId != null && _sessionTokens.containsKey(playSessionId)) {
      await _sessionProgress(playSessionId, position);
    } else {
      await _fileProgress(itemId, position, duration);
    }
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
    if (playSessionId != null && _sessionTokens.containsKey(playSessionId)) {
      await _sessionProgress(playSessionId, position, paused: isPaused);
    } else {
      await _fileProgress(itemId, position, duration);
    }
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
    final token = playSessionId == null ? null : _sessionTokens[playSessionId];
    if (playSessionId == null || token == null) {
      await _fileProgress(itemId, position, duration);
      return;
    }
    try {
      await _sessionProgress(playSessionId, position);
    } finally {
      _sessionTokens.remove(playSessionId);
      await _api.request('POST', '/api/v1/stream/s/${_seg(playSessionId)}/stopped', query: {'st': token});
    }
  }

  @override
  LiveTvSupport get liveTv => const _TofaNoLiveTv();

  // ---------------------------------------------------------------------------
  // Downloads and external players
  // ---------------------------------------------------------------------------

  Future<String?> _token(String path) async {
    final data = await _api.getJson(path);
    return data is Map ? data['token']?.toString() : null;
  }

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    final versions = item.mediaVersions ?? (await fetchItem(item.id))?.mediaVersions ?? const <MediaVersion>[];
    var version = mediaSourceId == null ? null : versions.where((v) => v.id == mediaSourceId).firstOrNull;
    version ??= mediaIndex >= 0 && mediaIndex < versions.length ? versions[mediaIndex] : versions.firstOrNull;
    final fileId = version?.id ?? await _fileIdOf(item);
    if (fileId == null || fileId.isEmpty) return const DownloadResolution(videoUrl: null);
    final token = await _token('/api/v1/auth/download-token/${_seg(fileId)}');
    if (token == null) return const DownloadResolution(videoUrl: null);
    final container = version?.container ?? 'mkv';
    final url = _api.resolveUrl(
      '/api/v1/stream/${_seg(fileId)}/download?st=${Uri.encodeQueryComponent(token)}#container=$container',
    );
    return DownloadResolution(videoUrl: url, mediaSourceId: fileId);
  }

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async {
    if (item.libraryId != null) return item;
    final fresh = await fetchItem(item.grandparentId ?? item.id);
    final libraryId = fresh?.libraryId;
    if (libraryId == null || item is! TofaMediaItem) return item;
    return item.copyWith(libraryId: libraryId, libraryTitle: fresh?.libraryTitle);
  }

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) =>
      buildArtworkSpecs(item, (path) => thumbnailUrl(path));

  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async {
    final versions = item.mediaVersions ?? (await fetchItem(item.id))?.mediaVersions ?? const <MediaVersion>[];
    var version = mediaSourceId == null ? null : versions.where((v) => v.id == mediaSourceId).firstOrNull;
    version ??= mediaIndex >= 0 && mediaIndex < versions.length ? versions[mediaIndex] : versions.firstOrNull;
    final fileId = version?.id ?? await _fileIdOf(item);
    if (fileId == null) return null;
    final token = await _token('/api/v1/auth/media-token');
    if (token == null) return null;
    return ExternalPlaybackTarget(
      url: _api.resolveUrl('/api/v1/stream/${_seg(fileId)}/direct?st=${Uri.encodeQueryComponent(token)}'),
    );
  }
}

/// tofa's live TV is not wired in this client.
class _TofaNoLiveTv implements LiveTvSupport {
  const _TofaNoLiveTv();

  @override
  LiveTvDvrSupport? get dvr => null;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) async => const [];

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async => const [];

  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async => null;

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => '';

  @override
  String get favoriteStoreKey => 'tofa';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) async =>
      const [];

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) async {}
}
