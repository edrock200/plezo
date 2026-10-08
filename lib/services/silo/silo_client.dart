import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../i18n/strings.g.dart';
import '../../media/artist_discography.dart';
import '../../media/download_resolution.dart';
import '../../media/ids.dart';
import '../../media/library_change_event.dart';
import '../../media/library_filter_result.dart';
import '../../media/library_query.dart';
import '../../media/live_tv_support.dart';
import '../../media/lyrics.dart';
import '../../media/media_backend.dart';
import '../../media/media_file_info.dart';
import '../../media/media_filter.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_person.dart';
import '../../media/media_playlist.dart';
import '../../media/media_server_client.dart';
import '../../media/media_sort.dart';
import '../../media/media_source_info.dart';
import '../../media/playback_report_metadata.dart';
import '../../media/server_capabilities.dart';
import '../../models/livetv_channel.dart';
import '../../models/livetv_program.dart';
import '../../models/transcode_quality_preset.dart';
import '../../mpv/mpv.dart';
import '../../utils/app_logger.dart';
import '../../utils/external_ids.dart';
import '../../utils/log_redaction_manager.dart';
import '../../utils/media_server_http_client.dart';
import '../../utils/url_utils.dart';
import '../api_cache.dart';
import '../connectivity_probe.dart';
import '../../utils/connectivity_link_type.dart';
import '../download_artwork_helpers.dart';
import '../playback_initialization_types.dart';
import '../scrub_preview_source.dart';
import 'silo_api.dart';
import 'silo_api_cache.dart';
import 'silo_mappers.dart';
import 'silo_playback_caps.dart';

part 'silo_client_playback.dart';

/// [MediaServerClient] for a Silo server, spoken over the `/api/v2` REST
/// contract only (the same surface Silo's Android TV app and the Siku Roku
/// port use).
///
/// One client is one [SiloConnection]: an account signed in on one server,
/// acting as one Silo profile. Every content request carries that profile's
/// `X-Profile-Id` (and `X-Profile-Token` for a PIN-locked one).
///
/// Silo paginates with opaque cursors while Plezy pages by offset, so the
/// client remembers the cursor that reaches each offset of a query and walks
/// forward when asked for one it has not seen.
class SiloClient
    with MediaServerCacheMixin, _SiloPlaybackMethods
    implements MediaServerClient, ScopedMediaServerClient, GracefullyCloseable {
  SiloClient._({required this._connection, required this._api});

  /// Build a client for [connection]. Network I/O stays lazy.
  static Future<SiloClient> create(SiloConnection connection, {http.Client? httpClient}) async {
    final headers = await SiloDeviceHeaders.resolve(connection.deviceId);
    return _build(connection, headers, httpClient);
  }

  @visibleForTesting
  static SiloClient forTesting(
    SiloConnection connection, {
    required SiloDeviceHeaders headers,
    http.Client? httpClient,
  }) => _build(connection, headers, httpClient);

  static SiloClient _build(SiloConnection connection, SiloDeviceHeaders headers, http.Client? httpClient) {
    _registerDiagnostics(connection);
    final api = SiloApi(
      baseUrl: connection.baseUrl,
      device: headers,
      tokens: SiloTokens(
        accessToken: connection.accessToken,
        refreshToken: connection.refreshToken,
        expiresAt: connection.accessTokenExpiresAt,
      ),
      profileId: connection.profileId,
      profileToken: connection.profileToken,
      client: httpClient,
    );
    final client = SiloClient._(connection: connection, api: api);
    api.onTokensRefreshed = client._handleTokensRefreshed;
    api.onSessionExpired = () => client._sessionExpired = true;
    return client;
  }

  static void _registerDiagnostics(SiloConnection connection) {
    for (final token in [connection.accessToken, connection.refreshToken, connection.profileToken]) {
      if (token != null && token.isNotEmpty) LogRedactionManager.registerToken(token);
    }
    LogRedactionManager.registerServerUrl(connection.baseUrl);
  }

  SiloConnection _connection;
  @override
  SiloConnection get connection => _connection;

  @override
  final SiloApi _api;

  bool _offlineMode = false;
  bool _sessionExpired = false;

  /// Every refresh token this client has held. Refresh tokens rotate, so a
  /// connection row read before a rotation was persisted carries an older
  /// one; it still describes this same live session.
  late final Set<String> _knownRefreshTokens = {_connection.refreshToken};

  /// Whether [refreshToken] belongs to this client's login session (current
  /// or rotated away from).
  bool ownsRefreshToken(String refreshToken) => _knownRefreshTokens.contains(refreshToken);

  /// Persists connection changes (rotated tokens, admin role). Wired by
  /// `MultiServerManager`.
  FutureOr<void> Function(SiloConnection connection)? onConnectionUpdated;

  Future<void> _handleTokensRefreshed(SiloTokens tokens) async {
    LogRedactionManager.registerToken(tokens.accessToken);
    LogRedactionManager.registerToken(tokens.refreshToken);
    _sessionExpired = false;
    _knownRefreshTokens.add(tokens.refreshToken);
    _connection = _connection.copyWith(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      accessTokenExpiresAt: tokens.expiresAt,
    );
    await onConnectionUpdated?.call(_connection);
  }

  @override
  SiloMappingContext get _ctx =>
      SiloMappingContext(serverId: serverId, serverName: serverName, resolveUrl: _api.resolveUrl);

  // ---------------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------------

  @override
  ServerId get serverId => ServerId(connection.serverId);

  @override
  String get scopedServerId => connection.id;

  @override
  String? get serverName => connection.serverName;

  @override
  MediaBackend get backend => MediaBackend.silo;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.silo;

  @override
  final Object authenticationSessionId = Object();

  @override
  LibraryEventChannel? createLibraryEventChannel() => null;

  @override
  void close() => _api.close();

  @override
  Future<void> closeGracefully({Duration drainTimeout = const Duration(seconds: 2)}) =>
      _api.closeGracefully(drainTimeout: drainTimeout);

  @override
  bool get isOfflineMode => _offlineMode;

  @override
  void setOfflineMode(bool offline) => _offlineMode = offline;

  @override
  ApiCache get cache => SiloApiCache.instance;

  SiloApiCache? get _siloCache {
    try {
      return SiloApiCache.instance;
    } catch (_) {
      return null;
    }
  }

  /// Authenticated round-trip on `/api/v2/account/me`, which needs no
  /// profile. A refused refresh (signed out elsewhere, session expired)
  /// surfaces as [HealthStatus.authError].
  @override
  Future<HealthStatus> checkHealth() async {
    try {
      final response = await _api.request(
        'GET',
        '/api/v2/account/me',
        profile: false,
        timeout: const Duration(seconds: 10),
      );
      if (response.statusCode == 200) {
        _sessionExpired = false;
        final data = response.data;
        if (data is Map) {
          final isAdmin = data['role'] == 'admin';
          if (isAdmin != _connection.isAdministrator) {
            _connection = _connection.copyWith(isAdministrator: isAdmin);
            try {
              await onConnectionUpdated?.call(_connection);
            } catch (e, st) {
              appLogger.w('Failed to persist Silo connection update', error: e, stackTrace: st);
            }
          }
        }
        return HealthStatus.online;
      }
      if (response.statusCode == 401 || _sessionExpired) return HealthStatus.authError;
      if (response.statusCode == 403) return HealthStatus.accessDenied;
      return HealthStatus.offline;
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 401) return HealthStatus.authError;
      if (e.statusCode == 403) return HealthStatus.accessDenied;
      return HealthStatus.offline;
    } catch (_) {
      return HealthStatus.offline;
    }
  }

  @override
  Future<String?> getMachineIdentifier() async {
    try {
      final data = await _api.getJson('/api/v2/system/identity', profile: false);
      return data['server_id']?.toString() ?? connection.serverId;
    } catch (e) {
      appLogger.w('SiloClient: getMachineIdentifier failed', error: e.runtimeType);
      return connection.serverId;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _seg(String id) => Uri.encodeComponent(id);

  static const _imageSize = 'medium';

  /// GET [path] through the cache-fallback helper, returning the JSON object.
  Future<Map<String, dynamic>?> _cachedGet(String path, {Map<String, dynamic>? query, AbortController? abort}) {
    final cacheKey = query == null || query.isEmpty ? path : '$path?${encodeQueryParameters(query)}';
    return fetchWithCacheFallback<Map<String, dynamic>>(
      cacheKey: cacheKey,
      networkCall: () => _api.request('GET', path, query: query, abort: abort),
      parseCache: (data) => data is Map<String, dynamic> ? data : null,
      parseResponse: (response) => response.data is Map<String, dynamic> ? response.data as Map<String, dynamic> : null,
      shouldFallback: (error) => error is MediaServerHttpException && error.isTransient,
    );
  }

  List<Map<String, dynamic>> _itemsOf(Map<String, dynamic>? data, [String key = 'items']) {
    final list = data?[key];
    return list is List ? list.whereType<Map<String, dynamic>>().toList() : const [];
  }

  // ---------------------------------------------------------------------------
  // Cursor paging
  // ---------------------------------------------------------------------------

  /// Query signature → (offset → cursor that starts there). Bounded LRU.
  final LinkedHashMap<String, Map<int, String>> _cursors = LinkedHashMap();
  static const _maxCursorQueries = 64;

  /// Fetch [limit] rows at [offset] of a cursor-paginated `GET` [path].
  /// [params] must be identical for every page of one listing.
  Future<({List<Map<String, dynamic>> items, int? total, bool hasMore})> _pageAt(
    String path,
    Map<String, dynamic> params, {
    required int offset,
    required int limit,
    AbortController? abort,
  }) async {
    final signature =
        '$path?${encodeQueryParameters(Map.fromEntries(params.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))}';
    final cursors = _cursors.remove(signature) ?? {0: ''};
    _cursors[signature] = cursors;
    while (_cursors.length > _maxCursorQueries) {
      _cursors.remove(_cursors.keys.first);
    }

    Future<({List<Map<String, dynamic>> items, int? total, bool hasMore, String? next})> fetch(
      String cursor,
      int pageLimit,
    ) async {
      final query = {...params, 'limit': pageLimit.clamp(1, 200), if (cursor.isNotEmpty) 'cursor': cursor};
      final response = await _api.send('GET', path, query: query, abort: abort);
      final data = response.data is Map<String, dynamic> ? response.data as Map<String, dynamic> : null;
      final page = data?['page'];
      final hasMore = page is Map && page['has_more'] == true;
      final next = page is Map ? page['next_cursor'] as String? : null;
      return (items: _itemsOf(data), total: (data?['total'] as num?)?.toInt(), hasMore: hasMore, next: next);
    }

    // Walk forward from the nearest known offset.
    if (!cursors.containsKey(offset)) {
      var start = cursors.keys.where((k) => k <= offset).fold<int>(0, (a, b) => b > a ? b : a);
      while (start < offset) {
        abort?.throwIfAborted();
        final page = await fetch(cursors[start]!, (offset - start).clamp(1, 200));
        if (page.items.isEmpty || !page.hasMore || page.next == null || page.next!.isEmpty) {
          return (
            items: const <Map<String, dynamic>>[],
            total: page.total ?? start + page.items.length,
            hasMore: false,
          );
        }
        start += page.items.length;
        cursors[start] = page.next!;
      }
    }
    final page = await fetch(cursors[offset]!, limit);
    if (page.hasMore && page.next != null && page.next!.isNotEmpty) {
      cursors[offset + page.items.length] = page.next!;
    }
    return (items: page.items, total: page.total, hasMore: page.hasMore);
  }

  LibraryPage<MediaItem> _libraryPage(
    ({List<Map<String, dynamic>> items, int? total, bool hasMore}) page, {
    required int offset,
    required int limit,
    String? libraryId,
    String? libraryTitle,
  }) {
    final items = SiloMappers.items(page.items, _ctx, libraryId: libraryId, libraryTitle: libraryTitle);
    final total = page.total ?? (page.hasMore ? offset + page.items.length + 1 : offset + page.items.length);
    return LibraryPage(items: items, totalCount: total, offset: offset);
  }

  // ---------------------------------------------------------------------------
  // Libraries and browse
  // ---------------------------------------------------------------------------

  final Map<String, String> _libraryTitles = {};

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    final data = await _cachedGet('/api/v2/user/libraries');
    final libraries = <MediaLibrary>[];
    for (final json in _itemsOf(data)) {
      // Music, audiobooks and reading libraries have no Plezy surface yet.
      if (SiloMappers.libraryFamily(json['type'] as String?) != SiloLibraryFamily.video) continue;
      final library = SiloMappers.library(json, _ctx);
      if (library == null) continue;
      _libraryTitles[library.id] = library.title;
      libraries.add(library);
    }
    return libraries;
  }

  static const _sortFields = {
    'title': 'title',
    'titleSort': 'title',
    'addedAt': 'added_at',
    'year': 'year',
    'productionYear': 'year',
    'releaseDate': 'release_date',
    'originallyAvailableAt': 'release_date',
    'rating': 'rating',
    'runtime': 'runtime',
    'duration': 'runtime',
    'random': 'random',
  };

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => [
    MediaSort(key: 'title', descKey: 'title:desc', title: t.libraries.sortLabels.title, defaultDirection: 'asc'),
    MediaSort(
      key: 'addedAt',
      descKey: 'addedAt:desc',
      title: t.libraries.sortLabels.dateAdded,
      defaultDirection: 'desc',
    ),
    MediaSort(
      key: 'releaseDate',
      descKey: 'releaseDate:desc',
      title: t.libraries.sortLabels.releaseDate,
      defaultDirection: 'desc',
    ),
    MediaSort(
      key: 'year',
      descKey: 'year:desc',
      title: t.libraries.sortLabels.productionYear,
      defaultDirection: 'desc',
    ),
    MediaSort(
      key: 'rating',
      descKey: 'rating:desc',
      title: t.libraries.sortLabels.communityRating,
      defaultDirection: 'desc',
    ),
    MediaSort(key: 'runtime', descKey: 'runtime:desc', title: t.libraries.sortLabels.runtime, defaultDirection: 'desc'),
    MediaSort(key: 'random', title: t.libraries.sortLabels.random, defaultDirection: 'asc'),
  ];

  /// `field` / `-field` for a neutral sort; unknown fields fall back to
  /// title so the server never answers 422 for an unknown sort.
  static String _sortParam(LibrarySort? sort) {
    if (sort == null) return 'title';
    var field = sort.field;
    var descending = sort.direction == LibrarySortDirection.descending;
    if (field.endsWith(':desc')) {
      field = field.substring(0, field.length - 5);
      descending = true;
    }
    final silo = _sortFields[field] ?? 'title';
    if (silo == 'random') return silo;
    return descending ? '-$silo' : silo;
  }

  Map<String, dynamic> _catalogParams(String libraryId, LibraryQuery query, MediaKind? libraryKind) {
    final kind = query.kind ?? (query.includeKinds.length == 1 ? query.includeKinds.single : null) ?? libraryKind;
    final params = <String, dynamic>{
      'source': 'query',
      'library_id': libraryId,
      'sort': _sortParam(query.sort),
      'image_size': _imageSize,
      'type': ?SiloMappers.catalogType(kind),
      if (query.search case final search? when search.trim().isNotEmpty) 'q': search.trim(),
      if (query.nameStartsWith case final prefix? when prefix.isNotEmpty && prefix != '#') 'name_prefix': prefix,
    };
    for (final filter in query.filters) {
      if (filter.op != LibraryFilterOperator.is_ || filter.values.isEmpty) continue;
      switch (filter.field) {
        case MediaFilterField.genre:
          params['genre'] = filter.values.first;
        case MediaFilterField.contentRating:
          params['content_rating'] = filter.values;
        case MediaFilterField.year:
          final year = int.tryParse(filter.values.first);
          if (year != null) {
            params['year_min'] = year;
            params['year_max'] = year;
          }
      }
    }
    return params;
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    final page = await _pageAt(
      '/api/v2/catalog',
      _catalogParams(libraryId, query, libraryKind),
      offset: query.offset,
      limit: query.limit,
      abort: abort,
    );
    return _libraryPage(
      page,
      offset: query.offset,
      limit: query.limit,
      libraryId: libraryId,
      libraryTitle: _libraryTitles[libraryId],
    );
  }

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async {
    const valueOperators = [LibraryFilterOperator.is_];
    Map<String, dynamic>? data;
    try {
      data = await _api.getJson('/api/v2/catalog/filters', query: {'library_id': libraryId, 'skip_technical': 'true'});
    } on MediaServerHttpException catch (e) {
      if (!e.isTransient) rethrow;
      return LibraryFilterResult.empty;
    }
    List<String> values(String key) {
      final raw = data?[key];
      if (raw is! List) return const [];
      return raw
          .map((v) => v is Map ? (v['value'] ?? v['name'])?.toString() : v?.toString())
          .nonNulls
          .where((v) => v.isNotEmpty)
          .toList();
    }

    final filters = <MediaFilter>[];
    final cached = <String, List<MediaFilterValue>>{};
    void add(String field, String key, String title) {
      final list = values(key);
      if (list.isEmpty) return;
      filters.add(
        MediaFilter(
          filter: field,
          filterType: MediaFilterType.tag,
          key: 'silo:$field',
          title: title,
          type: 'filter',
          operators: valueOperators,
        ),
      );
      cached[field] = (List<String>.from(list)..sort()).map((v) => MediaFilterValue(key: v, title: v)).toList();
    }

    add(MediaFilterField.genre, 'genres', t.libraries.filterCategories.genre);
    add(MediaFilterField.contentRating, 'content_ratings', t.libraries.filterCategories.contentRating);
    return LibraryFilterResult(filters: filters, cachedValues: cached);
  }

  @override
  Future<void> refreshLibraryMetadata(String libraryId) =>
      throw UnsupportedError('Silo library scans are started from the server dashboard.');

  // ---------------------------------------------------------------------------
  // Items
  // ---------------------------------------------------------------------------

  /// Season content id → (series id, season number), learned from season
  /// lists so a season's episodes can be fetched by series and number.
  final Map<String, ({String seriesId, int seasonNumber})> _seasonRefs = {};

  static const _collectionPrefix = 'silo-collection:';

  @override
  Future<MediaItem?> fetchItem(String id) async {
    final synthetic = SiloMappers.parseSyntheticSeasonId(id);
    if (synthetic != null) return _fetchSeason(synthetic.seriesId, synthetic.seasonNumber, id: id);
    if (id.startsWith(_collectionPrefix)) return _collectionItem(id);
    try {
      final data = await _cachedGet('/api/v2/catalog/items/${_seg(id)}', query: {'image_size': 'large'});
      if (data == null) return null;
      final item = SiloMappers.item(data, _ctx);
      if (item == null) return null;
      if (item.kind == MediaKind.season) {
        final seriesId = data['series_id']?.toString();
        final number = (data['season_number'] as num?)?.toInt();
        if (seriesId != null && number != null) _seasonRefs[id] = (seriesId: seriesId, seasonNumber: number);
      }
      // Awaited: a download pins this row right after the fetch returns.
      await _cacheItem(item);
      return item;
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<MediaItem?> _fetchSeason(String seriesId, int seasonNumber, {required String id}) async {
    final seasons = await _fetchSeasons(seriesId);
    for (final season in seasons) {
      if (season.index == seasonNumber) {
        final item = season.copyWith(id: id);
        await _cacheItem(item);
        return item;
      }
    }
    return null;
  }

  Future<void> _cacheItem(MediaItem item) async {
    try {
      await _siloCache?.putItem(ServerId(cacheServerId), item);
    } catch (e) {
      appLogger.d('SiloClient: item cache write failed', error: e.runtimeType);
    }
  }

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async {
    final item = await fetchItem(id);
    if (item == null || item.kind != MediaKind.show) return (item: item, onDeckEpisode: null);
    final playId = item.raw?['play_content_id']?.toString();
    if (playId == null || playId.isEmpty || playId == id) return (item: item, onDeckEpisode: null);
    onItemReady?.call(item);
    MediaItem? onDeck;
    try {
      onDeck = await fetchItem(playId);
    } catch (e) {
      appLogger.d('SiloClient: next-up episode unavailable', error: e.runtimeType);
    }
    return (item: item, onDeckEpisode: onDeck);
  }

  Future<List<MediaItem>> _fetchSeasons(String seriesId) async {
    final seriesData = await _cachedGet(
      '/api/v2/catalog/series/${_seg(seriesId)}/seasons',
      query: {'image_size': _imageSize, 'include_artwork': 'true'},
    );
    final seasons = <MediaItem>[];
    for (final json in _itemsOf(seriesData)) {
      final number = (json['season_number'] as num?)?.toInt();
      final contentId = json['content_id']?.toString();
      final id = contentId == null || contentId.isEmpty
          ? (number == null ? null : SiloMappers.syntheticSeasonId(seriesId, number))
          : contentId;
      if (id == null) continue;
      if (number != null) _seasonRefs[id] = (seriesId: seriesId, seasonNumber: number);
      final mapped = SiloMappers.item({...json, 'type': 'season', 'content_id': id, 'series_id': seriesId}, _ctx);
      if (mapped != null) seasons.add(mapped);
    }
    return seasons;
  }

  Future<({String seriesId, int seasonNumber})?> _seasonRef(String seasonId) async {
    final synthetic = SiloMappers.parseSyntheticSeasonId(seasonId);
    if (synthetic != null) return synthetic;
    final known = _seasonRefs[seasonId];
    if (known != null) return known;
    await fetchItem(seasonId);
    return _seasonRefs[seasonId];
  }

  Future<List<MediaItem>> _fetchEpisodes(String seriesId, int seasonNumber, {required String seasonId}) async {
    final data = await _cachedGet(
      '/api/v2/catalog/series/${_seg(seriesId)}/seasons/$seasonNumber/episodes',
      query: {'image_size': _imageSize},
    );
    return SiloMappers.items(
      _itemsOf(data).map(
        (json) => {
          ...json,
          'type': 'episode',
          'series_id': json['series_id'] ?? seriesId,
          'season_number': json['season_number'] ?? seasonNumber,
          'season_id': seasonId,
        },
      ),
      _ctx,
    );
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    if (parentId.startsWith(_collectionPrefix)) {
      final page = await fetchCollectionPage(parentId, start: 0, size: 200);
      return page.items;
    }
    final ref = SiloMappers.parseSyntheticSeasonId(parentId) ?? _seasonRefs[parentId];
    if (ref != null) return _fetchEpisodes(ref.seriesId, ref.seasonNumber, seasonId: parentId);
    final item = await fetchItem(parentId);
    if (item == null) return const [];
    return switch (item.kind) {
      MediaKind.show => _fetchSeasons(parentId),
      MediaKind.season => switch (await _seasonRef(parentId)) {
        final ref? => _fetchEpisodes(ref.seriesId, ref.seasonNumber, seasonId: parentId),
        null => const <MediaItem>[],
      },
      _ => const <MediaItem>[],
    };
  }

  static LibraryPage<MediaItem> _slice(List<MediaItem> all, int? start, int? size) {
    final from = (start ?? 0).clamp(0, all.length);
    final to = size == null ? all.length : (from + size).clamp(from, all.length);
    return LibraryPage(items: all.sublist(from, to), totalCount: all.length, offset: from);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _slice(await fetchChildren(parentId), start, size);

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async {
    if (parentId.startsWith(_collectionPrefix)) return fetchChildren(parentId);
    final seasonRef = SiloMappers.parseSyntheticSeasonId(parentId) ?? _seasonRefs[parentId];
    if (seasonRef != null) return _fetchEpisodes(seasonRef.seriesId, seasonRef.seasonNumber, seasonId: parentId);
    final item = await fetchItem(parentId);
    if (item == null) return const [];
    switch (item.kind) {
      case MediaKind.movie || MediaKind.episode:
        return [item];
      case MediaKind.season:
        return fetchChildren(parentId);
      case MediaKind.show:
        final seasons = await _fetchSeasons(parentId);
        final ordered = [...seasons.where((s) => (s.index ?? 0) > 0), ...seasons.where((s) => (s.index ?? 0) == 0)];
        final episodes = <MediaItem>[];
        for (final season in ordered) {
          final number = season.index;
          if (number == null) continue;
          episodes.addAll(await _fetchEpisodes(parentId, number, seasonId: season.id));
        }
        return episodes;
      default:
        return const [];
    }
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _slice(await fetchPlayableDescendants(parentId), start, size);

  /// Regular seasons in order; specials are reached only from a special,
  /// matching Silo's own next-episode resolver.
  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) async {
    final seasons = await _fetchSeasons(seriesId);
    final episodes = <MediaItem>[];
    for (final season in seasons.where((s) => (s.index ?? 0) > 0)) {
      episodes.addAll(await _fetchEpisodes(seriesId, season.index!, seasonId: season.id));
    }
    return episodes;
  }

  @override
  Future<List<MediaItem>> fetchLibraryFolders(
    String libraryId, {
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async => const [];

  @override
  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async => const [];

  // Music is not mapped yet: Silo's v2 contract has no album/artist/track
  // types (its own TV app keeps music minimal), so these have nothing to return.
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
  // Search
  // ---------------------------------------------------------------------------

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final response = await _api.send(
      'GET',
      '/api/v2/catalog',
      query: {'source': 'query', 'q': text, 'limit': limit.clamp(1, 100), 'image_size': _imageSize},
      abort: abort,
    );
    final data = response.data is Map<String, dynamic> ? response.data as Map<String, dynamic> : null;
    return SiloMappers.items(
      _itemsOf(data),
      _ctx,
    ).where((item) => item.libraryId == null || !excludedLibraryIds.contains(item.libraryId)).toList();
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    final text = query.trim();
    if (text.isEmpty) return const [];
    final response = await _api.send(
      'GET',
      '/api/v2/catalog/people',
      query: {'q': text, 'limit': limit, 'media_scope': 'video'},
      abort: abort,
    );
    final data = response.data is Map<String, dynamic> ? response.data as Map<String, dynamic> : null;
    return [
      for (final json in _itemsOf(data))
        if (json['id'] != null && json['name'] is String)
          MediaPerson(
            id: json['id'].toString(),
            name: json['name'] as String,
            thumbPath: json['photo_url'] is String && (json['photo_url'] as String).isNotEmpty
                ? _api.resolveUrl(json['photo_url'] as String)
                : null,
            backend: MediaBackend.silo,
            serverId: serverId,
            serverName: serverName,
          ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Hubs
  // ---------------------------------------------------------------------------

  static const _playbackSectionTypes = {'continue_watching', 'next_up'};

  Future<List<Map<String, dynamic>>> _homeSections({AbortController? abort}) async {
    final data = await _cachedGet('/api/v2/home/sections', query: {'image_size': _imageSize}, abort: abort);
    return _itemsOf(data, 'sections');
  }

  /// Sections may arrive without inline items while `total_count > 0`.
  Future<List<Map<String, dynamic>>> _sectionItems(Map<String, dynamic> section, String itemsPath) async {
    final inline = _itemsOf(section);
    final total = (section['total_count'] as num?)?.toInt() ?? 0;
    if (inline.isNotEmpty || total == 0) return inline;
    try {
      final data = await _api.getJson(itemsPath, query: {'image_size': _imageSize});
      return _itemsOf(data);
    } catch (e) {
      appLogger.d('SiloClient: section items unavailable', error: e.runtimeType);
      return const [];
    }
  }

  static String _hubType(List<MediaItem> items) {
    final kinds = items.map((item) => item.kind).toSet();
    if (kinds.length == 1) return kinds.single.id;
    return 'mixed';
  }

  MediaHub _hub({
    required String id,
    required Map<String, dynamic> section,
    required List<Map<String, dynamic>> rows,
    required int limit,
    String? libraryId,
  }) {
    final items = SiloMappers.items(
      rows.take(limit),
      _ctx,
      libraryId: libraryId,
      libraryTitle: _libraryTitles[libraryId],
    );
    final total = (section['total_count'] as num?)?.toInt() ?? rows.length;
    return MediaHub(
      id: id,
      identifier: section['section_type']?.toString() ?? section['id']?.toString(),
      title: (section['title'] as String?) ?? '',
      type: _hubType(items),
      items: items,
      size: total,
      more: total > items.length,
      libraryId: libraryId,
      serverId: serverId,
      serverName: serverName,
    );
  }

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async {
    final sections = await _homeSections();
    final items = <MediaItem>[];
    for (final section in sections.where((s) => s['section_type'] == 'continue_watching')) {
      final rows = await _sectionItems(section, '/api/v2/home/sections/${_seg(section['id'].toString())}/items');
      items.addAll(SiloMappers.items(rows, _ctx));
    }
    final visible = items.where((item) => item.libraryId == null || !excludedLibraryIds.contains(item.libraryId));
    return count == null ? visible.toList() : visible.take(count).toList();
  }

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async {
    final List<Map<String, dynamic>> sections;
    try {
      sections = await _homeSections();
    } catch (e) {
      diagnostics?.recordFailure(e);
      return const [];
    }
    final hubs = <MediaHub>[];
    for (final section in sections) {
      final sectionId = section['id']?.toString();
      if (sectionId == null) continue;
      if (!includePlaybackHubs && _playbackSectionTypes.contains(section['section_type'])) continue;
      final rows = await _sectionItems(section, '/api/v2/home/sections/${_seg(sectionId)}/items');
      final hub = _hub(id: 'home:$sectionId', section: section, rows: rows, limit: limit);
      if (hub.items.isNotEmpty) hubs.add(hub);
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
    _libraryTitles[libraryId] = libraryName;
    final Map<String, dynamic>? data;
    try {
      data = await _cachedGet('/api/v2/library/${_seg(libraryId)}/sections', query: {'image_size': _imageSize});
    } catch (e) {
      diagnostics?.recordFailure(e);
      return const [];
    }
    final hubs = <MediaHub>[];
    for (final section in _itemsOf(data, 'sections')) {
      final sectionId = section['id']?.toString();
      if (sectionId == null) continue;
      if (!includePlaybackHubs && _playbackSectionTypes.contains(section['section_type'])) continue;
      final rows = await _sectionItems(section, '/api/v2/library/${_seg(libraryId)}/sections/${_seg(sectionId)}/items');
      final hub = _hub(
        id: 'library:$libraryId:$sectionId',
        section: section,
        rows: rows,
        limit: limit,
        libraryId: libraryId,
      );
      if (hub.items.isNotEmpty) hubs.add(hub);
    }
    return hubs;
  }

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) async {
    try {
      final data = await _api.getJson(
        '/api/v2/recommendations/similar/${_seg(id)}',
        query: {'limit': count.clamp(1, 50)},
      );
      final items = SiloMappers.items(_itemsOf(data), _ctx);
      if (items.isEmpty) return const [];
      return [
        MediaHub(
          id: 'similar:$id',
          identifier: 'similar',
          title: t.discover.moreLikeThis,
          type: _hubType(items),
          items: items,
          size: items.length,
          serverId: serverId,
          serverName: serverName,
        ),
      ];
    } on MediaServerHttpException catch (e) {
      if (e.statusCode == 404) return const [];
      rethrow;
    }
  }

  @override
  Future<List<MediaItem>> fetchExtras(String id) async => const [];

  /// `GET /catalog?source=section` parameters for a hub id built by
  /// [fetchGlobalHubs] / [fetchLibraryHubs].
  Map<String, dynamic>? _hubCatalogParams(String hubId) {
    if (hubId.startsWith('home:')) {
      return {'source': 'section', 'section_id': hubId.substring(5), 'scope': 'home', 'image_size': _imageSize};
    }
    if (hubId.startsWith('library:')) {
      final rest = hubId.substring(8);
      final colon = rest.indexOf(':');
      if (colon <= 0) return null;
      return {
        'source': 'section',
        'library_id': rest.substring(0, colon),
        'section_id': rest.substring(colon + 1),
        'scope': 'library',
        'image_size': _imageSize,
      };
    }
    return null;
  }

  @override
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async {
    final page = await fetchMoreHubItemsPage(hubId, start: 0, size: limit ?? 100);
    return page.items;
  }

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(
    String hubId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final params = _hubCatalogParams(hubId);
    if (params == null) return const LibraryPage(items: [], totalCount: 0);
    final offset = start ?? 0;
    final limit = size ?? 50;
    final page = await _pageAt('/api/v2/catalog', params, offset: offset, limit: limit, abort: abort);
    return _libraryPage(page, offset: offset, limit: limit, libraryId: params['library_id'] as String?);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final offset = start ?? 0;
    final limit = size ?? 50;
    final page = await _pageAt(
      '/api/v2/catalog',
      {'source': 'person', 'person_id': personId, 'sort': '-year', 'image_size': _imageSize},
      offset: offset,
      limit: limit,
      abort: abort,
    );
    return _libraryPage(page, offset: offset, limit: limit);
  }

  // ---------------------------------------------------------------------------
  // Watch state
  // ---------------------------------------------------------------------------

  @override
  Future<void> markWatched(MediaItem item) async {
    await _api.send('POST', '/api/v2/watched/${_seg(_writeId(item))}');
  }

  @override
  Future<void> markUnwatched(MediaItem item) async {
    await _api.send('DELETE', '/api/v2/watched/${_seg(_writeId(item))}');
  }

  /// Silo writes take real content ids; a synthetic season id has none, so
  /// its writes go to the series. (Only episode cards produce one, and the
  /// season screens use real ids.)
  String _writeId(MediaItem item) {
    final synthetic = SiloMappers.parseSyntheticSeasonId(item.id);
    return synthetic?.seriesId ?? item.id;
  }

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {
    final raw = item.raw;
    if (raw?['item_source'] == 'next_up') {
      final seriesId = raw?['series_id']?.toString() ?? item.grandparentId;
      await _api.send('PUT', '/api/v2/home/dismissals/next_up/${_seg(item.id)}', body: {'series_id': ?seriesId});
      return;
    }
    final updatedAt = raw?['progress_updated_at']?.toString();
    await _api.send(
      'PUT',
      '/api/v2/home/dismissals/continue_watching/${_seg(item.id)}',
      body: {'progress_updated_at': ?updatedAt},
    );
  }

  /// [rating] is Plezy's 0–10 scale; Silo stores 1–5. A non-positive value
  /// clears the rating.
  @override
  Future<void> rate(MediaItem item, double rating) async {
    final path = '/api/v2/ratings/${_seg(_writeId(item))}';
    if (rating <= 0) {
      final response = await _api.request('DELETE', path);
      if (response.statusCode != 404) throwIfHttpError(response);
      return;
    }
    await _api.send('PUT', path, body: {'rating': (rating / 2).round().clamp(1, 5)});
  }

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) async {
    await _api.send(isFavorite ? 'PUT' : 'DELETE', '/api/v2/favorites/${_seg(_writeId(item))}');
  }

  // ---------------------------------------------------------------------------
  // Playlists (not in the Silo v2 contract)
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

  static Never _unsupported(String what) => throw UnsupportedError('Silo does not support $what.');

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) =>
      _unsupported('playlists');

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) => _unsupported('playlists');

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) => _unsupported('playlists');

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) => _unsupported('playlists');

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) => _unsupported('playlists');

  // ---------------------------------------------------------------------------
  // Collections (read-only library collections)
  // ---------------------------------------------------------------------------

  String _collectionId(String libraryId, String collectionId) => '$_collectionPrefix$libraryId:$collectionId';

  ({String libraryId, String collectionId})? _parseCollectionId(String id) {
    if (!id.startsWith(_collectionPrefix)) return null;
    final rest = id.substring(_collectionPrefix.length);
    final colon = rest.indexOf(':');
    if (colon <= 0) return null;
    return (libraryId: rest.substring(0, colon), collectionId: rest.substring(colon + 1));
  }

  final Map<String, MediaItem> _collections = {};

  MediaItem _mapCollection(String libraryId, Map<String, dynamic> json) {
    final id = _collectionId(libraryId, json['id'].toString());
    final poster = json['poster_url'];
    final item = MediaItem.silo(
      id: id,
      kind: MediaKind.collection,
      title: json['title']?.toString() ?? json['name']?.toString(),
      summary: json['overview']?.toString(),
      thumbPath: poster is String && poster.isNotEmpty ? _api.resolveUrl(poster) : null,
      leafCount: (json['item_count'] as num?)?.toInt(),
      childCount: (json['item_count'] as num?)?.toInt(),
      libraryId: libraryId,
      libraryTitle: _libraryTitles[libraryId],
      serverId: serverId,
      serverName: serverName,
      raw: json,
    );
    _collections[id] = item;
    return item;
  }

  Future<MediaItem?> _collectionItem(String id) async {
    final cached = _collections[id];
    if (cached != null) return cached;
    final parsed = _parseCollectionId(id);
    if (parsed == null) return null;
    await fetchCollectionsPage(parsed.libraryId);
    return _collections[id];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final data = await _cachedGet('/api/v2/library/${_seg(libraryId)}/collections', abort: abort);
    final rows = <Map<String, dynamic>>[
      ..._itemsOf(data, 'collections'),
      for (final group in _itemsOf(data, 'groups')) ..._itemsOf(group, 'collections'),
      ..._itemsOf(
        data?['ungrouped'] is Map<String, dynamic> ? data!['ungrouped'] as Map<String, dynamic> : null,
        'collections',
      ),
    ];
    final seen = <String>{};
    final items = [
      for (final row in rows)
        if (row['id'] != null && seen.add(row['id'].toString())) _mapCollection(libraryId, row),
    ];
    return _slice(items, start, size);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  }) async {
    final parsed = _parseCollectionId(collectionId);
    if (parsed == null) return const LibraryPage(items: [], totalCount: 0);
    final offset = start ?? 0;
    final limit = size ?? 50;
    final page = await _pageAt(
      '/api/v2/catalog',
      {
        'source': 'library_collection',
        'collection_id': parsed.collectionId,
        'library_id': parsed.libraryId,
        'image_size': _imageSize,
      },
      offset: offset,
      limit: limit,
      abort: abort,
    );
    return _libraryPage(
      page,
      offset: offset,
      limit: limit,
      libraryId: parsed.libraryId,
      libraryTitle: libraryTitle ?? _libraryTitles[parsed.libraryId],
    );
  }

  @override
  Future<List<CollectionMembership>> fetchCollectionMemberships(Set<String> itemIds, {AbortController? abort}) async =>
      const [];

  @override
  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
  }) => _unsupported('editing collections');

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) =>
      _unsupported('editing collections');

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) =>
      _unsupported('editing collections');

  @override
  Future<bool> deleteCollection(MediaItem collection) => _unsupported('editing collections');

  @override
  Future<bool> deleteMediaItem(MediaItem item) => _unsupported('deleting media');

  @override
  Future<MediaFileInfo?> getFileInfo(MediaItem item) async => null;

  // ---------------------------------------------------------------------------
  // Images and identity
  // ---------------------------------------------------------------------------

  /// Silo hands out ready-made, self-authorising artwork URLs; the mapper has
  /// already made them absolute, so they are used as they are (never with an
  /// `Authorization` header, and never re-encoded).
  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) =>
      path == null || path.isEmpty ? '' : _api.resolveUrl(path);

  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;

  @override
  Map<String, String> get streamHeaders => {..._api.device.toHeaders(), ..._api.authHeaders(includeProfile: false)};

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    final item = await fetchItem(itemId);
    final raw = item?.raw;
    if (raw == null) return const ExternalIds();
    int? asInt(Object? v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
    final imdb = raw['imdb_id']?.toString();
    return ExternalIds(
      imdb: imdb == null || imdb.isEmpty ? null : imdb,
      tmdb: asInt(raw['tmdb_id']),
      tvdb: asInt(raw['tvdb_id']),
    );
  }

  /// Title search narrowed by kind and year, then confirmed by external id
  /// where the rows carry one.
  @override
  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async {
    final type = SiloMappers.catalogType(kind);
    if (type == null || titles.isEmpty) return null;
    final matches = <String, MediaItem>{};
    for (final title in titles.take(3)) {
      final response = await _api.send(
        'GET',
        '/api/v2/catalog',
        query: {'source': 'query', 'q': title, 'type': type, 'limit': 20, 'image_size': _imageSize},
      );
      final data = response.data is Map<String, dynamic> ? response.data as Map<String, dynamic> : null;
      for (final item in SiloMappers.items(_itemsOf(data), _ctx)) {
        if (item.kind != kind) continue;
        final raw = item.raw ?? const {};
        final tmdb = raw['tmdb_id']?.toString();
        final imdb = raw['imdb_id']?.toString();
        final idMatch = (ids.tmdb != null && tmdb == ids.tmdb.toString()) || (ids.imdb != null && imdb == ids.imdb);
        final idKnown = tmdb != null || imdb != null;
        final yearMatch = year == null || item.year == null || (item.year! - year).abs() <= 1;
        final titleMatch = (item.title ?? '').toLowerCase() == title.toLowerCase();
        if (idMatch || (!idKnown && yearMatch && titleMatch)) matches[item.id] = item;
      }
    }
    return matches.values.toList();
  }

  @override
  LiveTvSupport get liveTv => const _SiloNoLiveTv();

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async {
    if (item.libraryId != null) return item;
    final raw = item.raw?['library_id']?.toString();
    if (raw == null || raw.isEmpty) return item;
    return (item as SiloMediaItem).copyWith(libraryId: raw, libraryTitle: _libraryTitles[raw]);
  }

  /// Artwork URLs are already absolute and self-authorising;
  /// [artworkStorageKey] drops their rotating signature for the local key.
  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) => buildArtworkSpecs(item, (path) => path);
}

/// Silo has no live TV.
class _SiloNoLiveTv implements LiveTvSupport {
  const _SiloNoLiveTv();

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
  String get favoriteStoreKey => 'silo';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) async =>
      const [];

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) async {}
}
