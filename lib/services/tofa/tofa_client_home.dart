part of 'tofa_client.dart';

/// Home rows beyond Continue Watching, each from a documented source:
///
/// - Recently Added: `GET /media` sorted by a date-added sort that
///   `/media/facets` lists (newest first), only when it lists one.
/// - Suggested for You: `GET /users/me/suggested` (`items`, titles in the
///   library; its `requestable` titles are left out).
/// - Ready to Binge: `GET /media/binge-ready` (complete seasons).
/// - Pinned collections: `GET /collections/home-rows`, rows of kind
///   `pinned_collection` with their `items` (`finish_sets` rows list titles
///   not in the library and are left out).
/// - Watchlist: `GET /users/me/watchlist`, titles in the library.
///
/// `POST /media/latest-episodes` answers which episode is newest for given
/// shows (not a row of its own) and `/browse/sections` names the Browse
/// sections; neither makes a Home row.
extension _TofaHome on TofaClient {
  static const _recentPrefix = 'tofa:recent';
  static const _suggestedId = 'tofa:suggested';
  static const _bingeId = 'tofa:binge';
  static const _watchlistId = 'tofa:watchlist';
  static const _collectionPrefix = 'tofa:collection:';

  /// The date-added sort `/media/facets` lists, or null.
  Future<String?> _dateAddedSort(String? libraryId) async {
    final facets = await _facetsFor(libraryId);
    if (facets == null || !facets.ordersAscDesc) return null;
    for (final sort in tofaDateAddedSorts) {
      if (facets.sorts.contains(sort)) return sort;
    }
    return null;
  }

  Future<List<MediaItem>> _recentItems(String? libraryId, {required int offset, required int limit}) async {
    final sort = await _dateAddedSort(libraryId);
    if (sort == null) {
      appLogger.d('[tofa] no date-added sort listed; no Recently Added row');
      return const [];
    }
    final page = await fetchLibraryPagedContent(
      libraryId ?? '',
      query: LibraryQuery(
        offset: offset,
        limit: limit,
        sort: LibrarySort(field: sort, direction: LibrarySortDirection.descending),
      ),
    );
    return page.items;
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
  /// [diagnostics] and never sinks Home.
  Future<List<MediaHub>> _leg(String name, Future<List<MediaHub>> Function() read, HubFetchDiagnostics? d) async {
    try {
      return await read();
    } catch (e) {
      appLogger.d('[tofa] Home row $name failed', error: e.runtimeType);
      d?.recordFailure(e);
      return const [];
    }
  }

  Future<List<MediaHub>> _globalHubs(int limit, HubFetchDiagnostics? diagnostics) async {
    final legs = await Future.wait([
      _leg('recent', () async {
        final items = await _recentItems(null, offset: 0, limit: limit + 1);
        return [if (items.isNotEmpty) _hub(_recentPrefix, t.discover.recentlyAdded, items, limit: limit)];
      }, diagnostics),
      _leg('suggested', () async {
        final items = await _suggestedItems();
        _homeLists[_suggestedId] = items;
        return [if (items.isNotEmpty) _hub(_suggestedId, t.discover.tofaSuggested, items, limit: limit)];
      }, diagnostics),
      _leg('binge', () async {
        final items = await _bingeItems(limit + 1);
        _homeLists[_bingeId] = items;
        return [if (items.isNotEmpty) _hub(_bingeId, t.discover.tofaReadyToBinge, items, limit: limit)];
      }, diagnostics),
      _leg('watchlist', () async {
        final items = await _watchlistItems();
        _homeLists[_watchlistId] = items;
        return [if (items.isNotEmpty) _hub(_watchlistId, t.discover.tofaWatchlist, items, limit: limit)];
      }, diagnostics),
      _leg('collections', () => _pinnedCollections(limit), diagnostics),
    ]);
    return [for (final hubs in legs) ...hubs];
  }

  Future<List<MediaHub>> _libraryHubs(
    String libraryId,
    String libraryName,
    int limit,
    HubFetchDiagnostics? diagnostics,
  ) => _leg('recent:$libraryId', () async {
    final items = await _recentItems(libraryId, offset: 0, limit: limit + 1);
    return [
      if (items.isNotEmpty)
        _hub(
          '$_recentPrefix:$libraryId',
          t.discover.recentlyAddedIn(library: libraryName),
          items,
          limit: limit,
          libraryId: libraryId,
        ),
    ];
  }, diagnostics);

  /// "View all" of a Home row: Recently Added pages through `/media`; the
  /// list rows page through what their last read returned.
  Future<LibraryPage<MediaItem>> _moreHubItemsPage(String hubId, int start, int? size) async {
    if (hubId == _recentPrefix || hubId.startsWith('$_recentPrefix:')) {
      final libraryId = hubId == _recentPrefix ? null : hubId.substring(_recentPrefix.length + 1);
      final limit = size ?? 50;
      final items = await _recentItems(libraryId, offset: start, limit: limit);
      return LibraryPage(
        items: items,
        totalCount: fallbackPageTotal(offset: start, itemCount: items.length, requestedSize: limit),
        offset: start,
      );
    }
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
