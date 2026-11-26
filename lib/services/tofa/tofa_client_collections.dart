part of 'tofa_client.dart';

/// Collections: franchise and curated ones (`GET /collections`,
/// `/collections/{id}`) and custom collections and lists
/// (`GET /collections/custom`, `/collections/custom/{id}`), read-only.
///
/// Tofa's collections span libraries (no `library_id` on either list), so
/// every library's Collections tab lists them all, as Jellyfin's BoxSets do.
/// A franchise or curated collection lists titles the library lacks too
/// (`AnnotatedDiscoveryItem.in_library`); only the ones it has are shown.
/// Playing one reads `GET /collections/{id}/play?mode=in_order`, the
/// server's own queue (series members expand to episodes); a collection it
/// refuses (unverified: whether custom ids are accepted there) plays its
/// members in order instead.
extension _TofaCollections on TofaClient {
  static const _listTtl = Duration(minutes: 2);

  Future<List<MediaItem>> _collectionsList({AbortController? abort}) {
    final cached = _collectionsCache;
    if (cached != null && DateTime.now().difference(cached.at) < _listTtl) return cached.items;
    final future = () async {
      final (curated, custom) = await (
        _readCollections('/api/v1/collections', custom: false, abort: abort),
        _readCollections('/api/v1/collections/custom', custom: true, abort: abort),
      ).wait;
      if (curated == null && custom == null) {
        throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'Tofa collections unavailable');
      }
      final items = [...?curated, ...?custom];
      for (final item in items) {
        _collectionItems[item.id] = item;
      }
      return items;
    }();
    _collectionsCache = (at: DateTime.now(), items: future);
    future.catchError((Object _) {
      if (identical(_collectionsCache?.items, future)) _collectionsCache = null;
      return const <MediaItem>[];
    });
    return future;
  }

  /// One of the two lists, or null when it failed (logged; the other list
  /// still shows).
  Future<List<MediaItem>?> _readCollections(String path, {required bool custom, AbortController? abort}) async {
    try {
      final data = await _api.getJson(path, abort: abort);
      final rows = data is Map && data['collections'] is List ? data['collections'] as List : const [];
      return [
        for (final row in rows.whereType<Map<String, dynamic>>()) ?TofaMappers.collection(row, _ctx, custom: custom),
      ];
    } catch (e) {
      appLogger.d('[tofa] collections list failed custom=$custom', error: e.runtimeType);
      return null;
    }
  }

  /// A collection's detail and its members that are in the library.
  Future<({MediaItem collection, List<MediaItem> members})?> _collectionDetail(
    String itemId, {
    AbortController? abort,
  }) async {
    final ref = TofaMappers.parseCollectionId(itemId);
    if (ref == null) return null;
    final path = ref.custom
        ? '/api/v1/collections/custom/${TofaClient._seg(ref.id)}'
        : '/api/v1/collections/${TofaClient._seg(ref.id)}';
    final data = await _api.getJson(path, abort: abort);
    if (data is! Map<String, dynamic>) return null;
    final collection = TofaMappers.collection(data, _ctx, custom: ref.custom);
    if (collection == null) return null;
    final rows = data['items'] is List
        ? (data['items'] as List).whereType<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];
    final members = <MediaItem>[
      for (final row in rows)
        if (ref.custom) ?TofaMappers.summary(row, _ctx) else ?TofaMappers.discoveryItem(row, _ctx),
    ];
    // The list's card keeps its artwork when the detail has none.
    final card = _collectionItems[itemId];
    final merged = card == null
        ? collection
        : collection.copyWith(
            thumbPath: collection.thumbPath ?? card.thumbPath,
            artPath: collection.artPath ?? card.artPath,
            clearLogoPath: collection.clearLogoPath ?? card.clearLogoPath,
          );
    _collectionItems[itemId] = merged;
    _collectionMembers[itemId] = members;
    return (collection: merged, members: members);
  }

  Future<LibraryPage<MediaItem>> _collectionsPage(int? start, int? size, AbortController? abort) async =>
      _pageOf(await _collectionsList(abort: abort), start, size);

  Future<LibraryPage<MediaItem>> _collectionMembersPage(
    String collectionId,
    int? start,
    int? size,
    AbortController? abort,
  ) async {
    // The first page reads the collection; later pages slice that read.
    final cached = _collectionMembers[collectionId];
    final members = (start ?? 0) > 0 && cached != null
        ? cached
        : (await _collectionDetail(collectionId, abort: abort))?.members ?? const <MediaItem>[];
    return _pageOf(members, start, size);
  }

  Future<MediaItem?> _collectionItem(String itemId) async =>
      (await _collectionDetail(itemId))?.collection ?? _collectionItems[itemId];

  /// Every playable item of a collection in the server's order.
  Future<List<MediaItem>> _collectionQueue(String itemId) async {
    final ref = TofaMappers.parseCollectionId(itemId);
    if (ref == null) return const [];
    Object? data;
    try {
      data = await _api.getJson('/api/v1/collections/${TofaClient._seg(ref.id)}/play', query: {'mode': 'in_order'});
    } on MediaServerHttpException catch (e) {
      final status = e.statusCode ?? 0;
      if (status < 400 || status >= 500) rethrow;
      appLogger.d('[tofa] collection play queue refused (HTTP $status); playing its members');
    }
    if (data is Map && data['entries'] is List) {
      final queue = await _queueItems((data['entries'] as List).whereType<Map<String, dynamic>>().toList());
      if (queue.isNotEmpty) return queue;
    }
    final members = _collectionMembers[itemId] ?? (await _collectionDetail(itemId))?.members ?? const [];
    final out = <MediaItem>[];
    for (final member in members) {
      out.addAll(await fetchPlayableDescendants(member.id));
    }
    return out;
  }

  /// `CollectionPlayQueueEntry` rows as playable items: a movie by its
  /// `media_id`, an episode found in its series by season and episode
  /// number (the entry carries no episode id). Unresolvable rows are left
  /// out and logged.
  Future<List<MediaItem>> _queueItems(List<Map<String, dynamic>> entries) async {
    final mediaIds = {
      for (final e in entries)
        if (e['media_id'] is String) e['media_id'] as String,
    };
    final resolved = <String, List<TofaMediaItem>>{};
    await Future.wait([
      for (final id in mediaIds)
        () async {
          try {
            final d = await _detail(id);
            if (d == null) return;
            final title = _mapDetail(id, d);
            if (title == null) return;
            resolved[id] = title.kind == MediaKind.show ? _allEpisodes(d, title) : [title];
          } catch (e) {
            appLogger.d('[tofa] collection queue title unavailable', error: e.runtimeType);
          }
        }(),
    ]);
    final out = <MediaItem>[];
    var skipped = 0;
    for (final entry in entries) {
      final items = resolved[entry['media_id']];
      if (items == null) {
        skipped++;
        continue;
      }
      final season = flexibleInt(entry['season_number']);
      final episode = flexibleInt(entry['episode_number']);
      if (season == null && episode == null) {
        if (items.length == 1 && items.single.kind == MediaKind.movie) {
          out.add(items.single);
        } else {
          out.addAll(items);
        }
        continue;
      }
      final match = items
          .where((i) => i.raw?[TofaRaw.seasonNumber] == season && i.raw?[TofaRaw.episodeNumber] == episode)
          .firstOrNull;
      if (match == null) {
        skipped++;
      } else {
        out.add(match);
      }
    }
    if (skipped > 0) appLogger.d('[tofa] collection queue left out $skipped entr${skipped == 1 ? 'y' : 'ies'}');
    return out;
  }
}

