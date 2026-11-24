import 'dart:convert';

import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../media/ids.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../utils/global_key_utils.dart';
import '../../utils/isolate_helper.dart';
import '../api_cache.dart';

/// Offline cache for Silo. Raw responses go through the shared
/// [ApiCache.get]/[ApiCache.put] keyed by request; mapped items are stored
/// separately as serialized [MediaItem]s under [itemEndpoint], so reading one
/// back needs no connection context (Silo artwork URLs arrive absolute or are
/// resolved before mapping).
class SiloApiCache extends ApiCache {
  static final _singleton = ApiCacheSingleton<SiloApiCache>(const {MediaBackend.silo}, 'SiloApiCache');
  static SiloApiCache get instance => _singleton.instance;

  SiloApiCache._(super.db);

  static void initialize(AppDatabase db) => _singleton.install(SiloApiCache._(db));

  static const _itemPrefix = 'silo:item/';
  static String itemEndpoint(String itemId) => '$_itemPrefix$itemId';

  /// Cache key of an item's watch detail (versions, tracks, chapters,
  /// markers), which offline playback of a download reads.
  static String watchEndpoint(String itemId) => '/api/v2/watch/${Uri.encodeComponent(itemId)}';

  /// Cache key of where a downloaded file's end credits start
  /// ([SiloEndCreditsRecord]), stored when the download completes.
  static String endCreditsEndpoint(String itemId) => 'silo:end-credits/${Uri.encodeComponent(itemId)}';
  static final RegExp _itemKeyPattern = RegExp(r'^[^:]+:silo:item/(.+)$');

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
    await pin(serverId, watchEndpoint(itemId));
  }

  @override
  Future<void> deleteForItem(ServerId serverId, String itemId) async {
    final keys = [
      '$serverId:${itemEndpoint(itemId)}',
      '$serverId:${watchEndpoint(itemId)}',
      '$serverId:${endCreditsEndpoint(itemId)}',
    ];
    await (database.delete(database.apiCache)..where((t) => t.cacheKey.isIn(keys))).go();
  }

  /// Records where the downloaded file [SiloEndCreditsRecord.fileId] of
  /// [itemId] ends its credits (null start: none in its end window), pinned
  /// with the download.
  Future<void> putEndCredits(ServerId serverId, String itemId, SiloEndCreditsRecord record) async {
    await put(serverId, endCreditsEndpoint(itemId), record.toJson());
    await pin(serverId, endCreditsEndpoint(itemId));
  }

  /// The record [putEndCredits] stored for [itemId]; null when the download
  /// completed before this existed or the record is unreadable.
  Future<SiloEndCreditsRecord?> getEndCredits(ServerId serverId, String itemId) async {
    final data = await get(serverId, endCreditsEndpoint(itemId));
    return data == null ? null : SiloEndCreditsRecord.fromJson(data);
  }

  /// The pinned watch detail of a downloaded item, for offline playback.
  Future<Map<String, dynamic>?> getWatchDetail(ServerId serverId, String itemId) =>
      get(serverId, watchEndpoint(itemId));

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
      if (item is! SiloMediaItem) return;
      final updated = item.copyWith(
        viewCount: isWatched ? ((item.viewCount ?? 0) < 1 ? 1 : item.viewCount) : 0,
        viewOffsetMs: viewOffsetMs,
        lastViewedAt: lastViewedAt ?? (isWatched ? DateTime.now().millisecondsSinceEpoch ~/ 1000 : item.lastViewedAt),
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
        decode: (row, json) {
          final item = MediaItem.fromJson(json);
          return MapEntry(buildGlobalKey(row.serverId, row.id), item);
        },
      ),
    );
  }
}

/// Where a downloaded Silo file's end credits start (Silo Android #1038).
class SiloEndCreditsRecord {
  const SiloEndCreditsRecord({required this.fileId, required this.start});

  /// The downloaded file.
  final String fileId;

  /// The start of its end credits; null when it places none in its end window.
  final Duration? start;

  Map<String, dynamic> toJson() => {'file_id': fileId, 'end_credits_start_ms': start?.inMilliseconds};

  static SiloEndCreditsRecord? fromJson(Map<String, dynamic> json) {
    final fileId = json['file_id'];
    final startMs = json['end_credits_start_ms'];
    if (fileId is! String || fileId.isEmpty) return null;
    if (startMs != null && (startMs is! int || startMs < 0)) return null;
    return SiloEndCreditsRecord(
      fileId: fileId,
      start: startMs == null ? null : Duration(milliseconds: startMs),
    );
  }
}
