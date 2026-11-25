import 'dart:convert';

import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../media/ids.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../utils/global_key_utils.dart';
import '../../utils/isolate_helper.dart';
import '../api_cache.dart';
import 'tofa_downloads.dart';

/// Cache for Tofa. Registered so `ApiCache.forBackend(MediaBackend.tofa)`
/// never falls back to the Plex cache.
///
/// Mapped items are stored under [itemEndpoint] (serialized [MediaItem]s).
/// A download pins its item, its [TofaDownloadRecord] ([downloadEndpoint])
/// and its file's QuickView answer ([quickViewEndpoint]: chapters and skip
/// segments), which is everything offline playback reads.
class TofaApiCache extends ApiCache {
  static final _singleton = ApiCacheSingleton<TofaApiCache>(const {MediaBackend.tofa}, 'TofaApiCache');
  static TofaApiCache get instance => _singleton.instance;

  TofaApiCache._(super.db);

  static void initialize(AppDatabase db) => _singleton.install(TofaApiCache._(db));

  static const _itemPrefix = 'tofa:item/';
  static String itemEndpoint(String itemId) => '$_itemPrefix$itemId';

  /// A file's `GET /media/{file_id}/quickview` answer.
  static String quickViewEndpoint(String fileId) => 'tofa:quickview/$fileId';

  /// An item's download registration ([TofaDownloadRecord]).
  static String downloadEndpoint(String itemId) => 'tofa:download/$itemId';

  /// The download quality picked for an item (and the episodes under it).
  static String qualityEndpoint(String itemId) => 'tofa:download-quality/$itemId';
  static final RegExp _itemKeyPattern = RegExp(r'^[^:]+:tofa:item/(.+)$');

  Future<void> putItem(ServerId serverId, MediaItem item) => put(serverId, itemEndpoint(item.id), item.toJson());

  @override
  Future<MediaItem?> getMetadata(ServerId serverId, String itemId) async {
    final data = await get(serverId, itemEndpoint(itemId));
    if (data == null) return null;
    try {
      return MediaItem.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> pinForOffline(ServerId serverId, String itemId) async {
    await pin(serverId, itemEndpoint(itemId));
    final record = await getDownloadRecord(serverId, itemId);
    if (record == null) return;
    await pin(serverId, downloadEndpoint(itemId));
    await pin(serverId, quickViewEndpoint(record.fileId));
  }

  @override
  Future<void> deleteForItem(ServerId serverId, String itemId) async {
    final record = await getDownloadRecord(serverId, itemId);
    final keys = [
      '$serverId:${itemEndpoint(itemId)}',
      '$serverId:${downloadEndpoint(itemId)}',
      if (record != null) '$serverId:${quickViewEndpoint(record.fileId)}',
    ];
    await (database.delete(database.apiCache)..where((t) => t.cacheKey.isIn(keys))).go();
  }

  Future<TofaDownloadRecord?> getDownloadRecord(ServerId serverId, String itemId) async =>
      TofaDownloadRecord.fromJson(await get(serverId, downloadEndpoint(itemId)));

  /// Stores [record] pinned: offline playback and sync need it until the
  /// download is deleted.
  Future<void> putDownloadRecord(ServerId serverId, String itemId, TofaDownloadRecord record) async {
    await put(serverId, downloadEndpoint(itemId), record.toJson());
    await pin(serverId, downloadEndpoint(itemId));
  }

  Future<void> removeDownloadRecord(ServerId serverId, String itemId) async {
    final key = '$serverId:${downloadEndpoint(itemId)}';
    await (database.delete(database.apiCache)..where((t) => t.cacheKey.equals(key))).go();
  }

  @override
  Future<void> applyWatchState({
    required ServerId serverId,
    required String itemId,
    required bool isWatched,
    int? viewOffsetMs,
    int? lastViewedAt,
    int? viewedLeafCount,
  }) async {
    final key = '$serverId:${itemEndpoint(itemId)}';
    final row = await (database.select(database.apiCache)..where((t) => t.cacheKey.equals(key))).getSingleOrNull();
    if (row == null) return;
    try {
      final item = MediaItem.fromJson(jsonDecode(row.data) as Map<String, dynamic>);
      if (item is! TofaMediaItem) return;
      final updated = item.copyWith(
        viewCount: isWatched ? 1 : 0,
        viewOffsetMs: viewOffsetMs,
        lastViewedAt: lastViewedAt ?? item.lastViewedAt,
        viewedLeafCount: viewedLeafCount ?? item.viewedLeafCount,
      );
      await (database.update(
        database.apiCache,
      )..where((t) => t.cacheKey.equals(key))).write(ApiCacheCompanion(data: Value(jsonEncode(updated.toJson()))));
    } catch (_) {
      // Skip malformed entries.
    }
  }

  @override
  Future<Map<String, MediaItem>> getAllPinnedMetadata({Set<ServerId>? cacheServerIds}) async {
    final rows = await listPinnedRowsByPattern(_itemKeyPattern);
    final selected = cacheServerIds == null
        ? rows
        : rows.where((row) => cacheServerIds.contains(row.serverId)).toList(growable: false);
    if (selected.isEmpty) return {};
    return tryIsolateRun(
      () => decodeCachedMediaRows(
        selected,
        serializedData: (row) => row.data,
        decode: (row, json) => MapEntry(buildGlobalKey(row.serverId, row.id), MediaItem.fromJson(json)),
      ),
    );
  }
}
