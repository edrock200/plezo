part of 'tofa_client.dart';

/// Home rows and library Recommended rows, each from a documented source.
///
/// Home ([_globalHubs]):
/// - Recently Added per Browse section (`GET /browse/sections`: a library of
///   its own, or a type such as Movies across libraries), as Tofa's own Home
///   gives each one a Recently Added row; only where `/media/facets` lists a
///   date-added sort (newest first). Without sections, one row for all.
/// - Suggested for You: `GET /users/me/suggested` (`items` only; its
///   `requestable` titles are not in the library).
/// - Ready to Binge: `GET /media/binge-ready` (complete seasons).
/// - Watchlist: `GET /users/me/watchlist`, titles in the library.
/// - Pinned collections: `GET /collections/home-rows`, `pinned_collection`
///   rows (`finish_sets` rows list titles not in the library).
///
/// A library's Recommended tab ([_libraryHubs]), every row built from
/// `/media` parameters and the values that library's facets list (the spec
/// has no per-library row list): in progress, recently added, suggested and
/// Ready to Binge narrowed to the library, recently released, top rated,
/// unwatched, and one row per most common genre.
///
/// Rows read from `/media` carry their query in the hub id
/// (`tofa:q:<base64 json>`), so "View all" pages through the same query.
extension _TofaHome on TofaClient {
  static const _queryPrefix = 'tofa:q:';
  static const _suggestedId = 'tofa:suggested';
  static const _bingeId = 'tofa:binge';
  static const _watchlistId = 'tofa:watchlist';
  static const _collectionPrefix = 'tofa:collection:';

  /// How many genre rows a library's Recommended tab shows.
  static const genreRows = 5;

  static String _queryHubId(Map<String, String> params) =>
      '$_queryPrefix${base64Url.encode(utf8.encode(jsonEncode(params)))}';

  static Map<String, String>? _queryOf(String hubId) {
    if (!hubId.startsWith(_queryPrefix)) return null;
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(hubId.substring(_queryPrefix.length))));
      if (decoded is! Map) return null;
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    } catch (_) {
      return null;
    }
  }

  /// The date-added sort the facets list, or null.
  static String? _dateAddedSort(TofaFacets? facets) {
    if (facets == null || !facets.ordersAscDesc) return null;
    for (final sort in tofaDateAddedSorts) {
      if (facets.sorts.contains(sort)) return sort;
    }
    return null;
  }

  static String? _listedSort(TofaFacets? facets, List<String> candidates) {
    if (facets == null || !facets.ordersAscDesc) return null;
    for (final sort in candidates) {
      if (facets.sorts.contains(sort)) return sort;
    }
    return null;
  }

  MediaHub _hub(String id, String title, List<MediaItem> items, {int? limit, bool more = false, String? libraryId}) {
    final shown = limit == null ? items : items.take(limit).toList();
    return MediaHub(
      id: id,
      identifier: id,
      title: title,
      type: 'mixed',
      items: shown,
      size: shown.length,
      more: more || shown.length < items.length,
      libraryId: libraryId,
      serverId: serverId.value,
      serverName: serverName,
    );
  }

  /// A row of `/media` with [params]: one more than [limit] is read so the
  /// row knows whether "View all" has more.
  Future<List<MediaHub>> _queryRow(String title, Map<String, String> params, int limit, {String? libraryId}) async {
    final page = await _mediaQuery(params, offset: 0, limit: limit + 1);
    if (page.items.isEmpty) return const [];
    return [
      _hub(_queryHubId(params), title, page.items, limit: limit, more: page.totalCount > limit, libraryId: libraryId),
    ];
  }

  Future<List<MediaItem>> _suggestedItems() async {
    final data = await _api.getJson('/api/v1/users/me/suggested');
    final rows = data is Map && data['items'] is List ? data['items'] as List : const [];
    return [for (final row in rows.whereType<Map<String, dynamic>>()) ?TofaMappers.summary(row, _ctx)];
  }

  Future<List<MediaItem>> _bingeItems(int limit) async {
    final data = await _api.getJson('/api/v1/media/binge-ready', query: {'limit': '$limit'});
    final rows = data is Map && data['items'] is List ? data['items'] as List : const [];
    return [for (final row in rows.whereType<Map<String, dynamic>>()) ?TofaMappers.bingeReadySeason(row, _ctx)];
  }

  Future<List<MediaHub>> _pinnedCollections(int limit) async {
    final data = await _api.getJson('/api/v1/collections/home-rows');
    final rows = data is Map && data['rows'] is List ? data['rows'] as List : const [];
    final hubs = <MediaHub>[];
    for (final row in rows.whereType<Map<String, dynamic>>()) {
      if (row['kind'] != 'pinned_collection' || row['enabled'] == false) continue;
      final id = row['collection_id'] ?? row['id'];
      final name = row['name'];
      if (id is! String || name is! String || name.isEmpty) continue;
      final items = [
        if (row['items'] is List)
          for (final item in (row['items'] as List).whereType<Map<String, dynamic>>()) ?TofaMappers.summary(item, _ctx),
      ];
      _homeLists['$_collectionPrefix$id'] = items;
      if (items.isNotEmpty) hubs.add(_hub('$_collectionPrefix$id', name, items, limit: limit));
    }
    return hubs;
  }

  /// The profile's watchlist titles that are in the library, every page.
  Future<List<MediaItem>> _watchlistItems() async {
    final items = <MediaItem>[];
    final ids = <String>{};
    for (var page = 1; page <= 20; page++) {
      final data = await _api.getJson('/api/v1/users/me/watchlist', query: {'page': '$page', 'per_page': '100'});
      // `WatchlistResponse` is either a bare list or a paginated object.
      final rows = data is List ? data : (data is Map && data['items'] is List ? data['items'] as List : const []);
      for (final row in rows.whereType<Map<String, dynamic>>()) {
        final mediaId = row['media_id'];
        if (mediaId is String) ids.add(mediaId);
        final item = TofaMappers.watchlistItem(row, _ctx);
        if (item != null) items.add(item);
      }
      final totalPages = data is Map ? (data['total_pages'] as num?)?.toInt() : null;
      if (data is List || totalPages == null || page >= totalPages || rows.isEmpty) break;
    }
    _watchlistIds = ids;
    _watchlistReadAt = DateTime.now();
    return items;
  }

  /// One row read, degrading to none: a failed leg is recorded in
  /// [diagnostics] and never sinks the page.
  Future<List<MediaHub>> _leg(
    String name,
    Future<List<MediaHub>> Function() read,
    HubFetchDiagnostics? d, {
    List<Object>? failures,
  }) async {
    try {
      return await read();
    } catch (e) {
      appLogger.d('[tofa] row $name failed', error: e.runtimeType);
      d?.recordFailure(e);
      failures?.add(e);
      return const [];
    }
  }

  /// A failure a later Home read may not hit: a timeout, a lost connection,
  /// 408, 429 or a 5xx (as for Silo's Home).
  static bool _transient(Object error) {
    if (error is TimeoutException) return true;
    if (error is! MediaServerHttpException || error.isCancellation) return false;
    if (error.isTransient) return true;
    final status = error.statusCode;
    return status == 408 || status == 429 || (status != null && status >= 500 && status <= 599);
  }

  /// Browse sections (`GET /browse/sections`): the server's chosen layout.
  Future<List<Map<String, dynamic>>> _browseSections() async {
    final data = await _api.getJson('/api/v1/browse/sections');
    final rows = data is Map && data['sections'] is List ? data['sections'] as List : const [];
    return [
      for (final s in rows.whereType<Map<String, dynamic>>())
        if (s['name'] is String && ((s['total'] as num?)?.toInt() ?? 1) > 0) s,
    ];
  }

  /// Recently Added rows for Home: one per Browse section, else one for all.
  Future<List<MediaHub>> _recentRows(int limit) async {
    List<Map<String, dynamic>> sections;
    try {
      sections = await _browseSections();
    } catch (e) {
      appLogger.d('[tofa] browse sections unavailable; one Recently Added row', error: e.runtimeType);
      sections = const [];
    }
    if (sections.isEmpty) {
      final sort = _dateAddedSort(await _facetsFor(null));
      if (sort == null) return const [];
      return _queryRow(t.discover.recentlyAdded, {'sort': sort, 'order': 'desc'}, limit);
    }
    final rows = await Future.wait([
      for (final section in sections)
        () async {
          // `BrowseSection`: `kind` `library` names one library; `type`
          // spans the libraries of its (required) `media_type`.
          final libraryId = section['kind'] == 'library' && section['library_id'] is String
              ? section['library_id'] as String
              : null;
          final mediaType = section['media_type'];
          if (libraryId == null && (section['kind'] != 'type' || mediaType is! String)) {
            return const <MediaHub>[];
          }
          final facets = await _facetsFor(libraryId);
          final sort = _dateAddedSort(facets);
          if (sort == null) return const <MediaHub>[];
          return _queryRow(
            t.discover.recentlyAddedIn(library: section['name'] as String),
            {
              ...libraryId != null ? {'library_id': libraryId} : {'media_type': mediaType as String},
              'sort': sort,
              'order': 'desc',
            },
            limit,
            libraryId: libraryId,
          );
        }(),
    ]);
    return [for (final r in rows) ...r];
  }

  Future<List<MediaHub>> _globalHubs(int limit, HubFetchDiagnostics? diagnostics) async {
    final failures = <Object>[];
    final legs = await Future.wait([
      _leg('recent', () => _recentRows(limit), diagnostics, failures: failures),
      _leg(
        'suggested',
        () async {
          final items = await _suggestedItems();
          _homeLists[_suggestedId] = items;
          return [if (items.isNotEmpty) _hub(_suggestedId, t.discover.tofaSuggested, items, limit: limit)];
        },
        diagnostics,
        failures: failures,
      ),
      _leg(
        'binge',
        () async {
          final items = await _bingeItems(limit + 1);
          _homeLists[_bingeId] = items;
          return [if (items.isNotEmpty) _hub(_bingeId, t.discover.tofaReadyToBinge, items, limit: limit)];
        },
        diagnostics,
        failures: failures,
      ),
      _leg(
        'watchlist',
        () async {
          final items = await _watchlistItems();
          _homeLists[_watchlistId] = items;
          return [if (items.isNotEmpty) _hub(_watchlistId, t.discover.tofaWatchlist, items, limit: limit)];
        },
        diagnostics,
        failures: failures,
      ),
      _leg('collections', () => _pinnedCollections(limit), diagnostics, failures: failures),
    ]);
    _lastHomeIncomplete = failures.any(_transient);
    return [for (final hubs in legs) ...hubs];
  }

  /// Every row Plezilo can build for one library, read together.
  Future<List<MediaHub>> _libraryHubs(
    String libraryId,
    String libraryName,
    int limit,
    HubFetchDiagnostics? diagnostics, {
    bool includePlaybackHubs = true,
  }) async {
    final facets = await _facetsFor(libraryId);
    final lib = {'library_id': libraryId};
    final added = _dateAddedSort(facets);
    final released = _listedSort(facets, const ['release_date']);
    final rated = _listedSort(facets, const ['rating', 'imdb_rating']);
    final watched = facets?.watched ?? const <String>[];
    final genres = [...?facets?.genres].take(genreRows).toList();
    String inLibrary(MediaItem item) => item.libraryId ?? '';
    final legs = await Future.wait([
      if (includePlaybackHubs && watched.contains('in_progress'))
        _leg(
          'in_progress:$libraryId',
          () => _queryRow(
            t.discover.continueWatchingIn(library: libraryName),
            {...lib, 'watched': 'in_progress'},
            limit,
            libraryId: libraryId,
          ),
          diagnostics,
        ),
      if (added != null)
        _leg(
          'recent:$libraryId',
          () => _queryRow(
            t.discover.recentlyAddedIn(library: libraryName),
            {...lib, 'sort': added, 'order': 'desc'},
            limit,
            libraryId: libraryId,
          ),
          diagnostics,
        ),
      _leg('suggested:$libraryId', () async {
        final items = [
          for (final i in await _suggestedItems())
            if (inLibrary(i) == libraryId) i,
        ];
        final id = '$_suggestedId:$libraryId';
        _homeLists[id] = items;
        return [if (items.isNotEmpty) _hub(id, t.discover.tofaSuggested, items, limit: limit, libraryId: libraryId)];
      }, diagnostics),
      _leg('binge:$libraryId', () async {
        final items = [
          for (final i in await _bingeItems(50))
            if (inLibrary(i) == libraryId) i,
        ];
        final id = '$_bingeId:$libraryId';
        _homeLists[id] = items;
        return [if (items.isNotEmpty) _hub(id, t.discover.tofaReadyToBinge, items, limit: limit, libraryId: libraryId)];
      }, diagnostics),
      if (released != null)
        _leg(
          'released:$libraryId',
          () => _queryRow(
            t.discover.tofaRecentlyReleased,
            {...lib, 'sort': released, 'order': 'desc', 'released_only': 'true'},
            limit,
            libraryId: libraryId,
          ),
          diagnostics,
        ),
      if (rated != null)
        _leg(
          'rated:$libraryId',
          () =>
              _queryRow(t.discover.tofaTopRated, {...lib, 'sort': rated, 'order': 'desc'}, limit, libraryId: libraryId),
          diagnostics,
        ),
      if (watched.contains('unwatched'))
        _leg(
          'unwatched:$libraryId',
          () => _queryRow(
            t.discover.tofaUnwatched,
            {...lib, 'watched': 'unwatched', if (facets?.sorts.contains('random') ?? false) 'sort': 'random'},
            limit,
            libraryId: libraryId,
          ),
          diagnostics,
        ),
      for (final genre in genres)
        _leg(
          'genre:$genre',
          () => _queryRow(genre, {...lib, 'genre': genre}, limit, libraryId: libraryId),
          diagnostics,
        ),
    ]);
    return [for (final hubs in legs) ...hubs];
  }

  /// "View all" of a row: `/media` rows page through their query; the list
  /// rows page through what their last read returned.
  Future<LibraryPage<MediaItem>> _moreHubItemsPage(String hubId, int start, int? size) async {
    final query = _queryOf(hubId);
    if (query != null) return _mediaQuery(query, offset: start, limit: size ?? 50);
    var items = _homeLists[hubId];
    if (items == null) {
      items = switch (hubId) {
        _suggestedId => await _suggestedItems(),
        _bingeId => await _bingeItems(200),
        _watchlistId => await _watchlistItems(),
        _ => const <MediaItem>[],
      };
      _homeLists[hubId] = items;
    }
    final from = start.clamp(0, items.length);
    final to = size == null ? items.length : (from + size).clamp(from, items.length);
    return LibraryPage(items: items.sublist(from, to), totalCount: items.length, offset: from);
  }
}
