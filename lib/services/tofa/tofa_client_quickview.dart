part of 'tofa_client.dart';

/// Chapters, skip markers and seek-bar previews from Tofa's QuickView
/// (`GET /api/v1/media/{file_id}/quickview`: "chapter markers, detected
/// segments such as intros and outros, the skip policy, and thumbnail tile
/// metadata").
///
/// - Chapters: `chapters[]` (`start_ticks`, `title`), with the chapter image
///   route as the thumbnail.
/// - Markers: `segments[]` by `segment_type` ([TofaOfflineExtras.markerType]).
/// - Previews: `tiles[]` has the Jellyfin trickplay layout (`width`,
///   `height`, `tile_width` × `tile_height` thumbnails per sheet,
///   `thumbnail_count`, `interval_ms`); sheets are
///   `/quickview/tiles/{width}/{index}` with the image token as `st` (the
///   route takes a bearer or `st`; image views cannot send headers).
extension _TofaQuickView on TofaClient {
  /// The QuickView answer of [fileId]: fresh from the server, cached for
  /// offline use, or the cached copy when the server cannot be read.
  Future<Map<String, dynamic>?> _quickView(String fileId, {bool cacheOnly = false}) async {
    final key = TofaApiCache.quickViewEndpoint(fileId);
    final scope = ServerId(cacheServerId);
    if (cacheOnly || _offlineMode) return _tofaCache?.get(scope, key);
    final inMemory = _quickViews[fileId];
    if (inMemory != null) return inMemory;
    try {
      final response = await _api.request('GET', '/api/v1/media/${TofaClient._seg(fileId)}/quickview');
      if (response.statusCode == 404) return null;
      TofaApi.throwIfTofaError(response);
      final data = response.data;
      if (data is! Map<String, dynamic>) return null;
      _quickViews[fileId] = data;
      unawaited(_tofaCache?.put(scope, key, data).catchError((_) {}));
      return data;
    } on MediaServerHttpException catch (e) {
      if (e.isCancellation) rethrow;
      appLogger.d('[tofa] QuickView read failed (HTTP ${e.statusCode}); trying the cache');
      return _tofaCache?.get(scope, key);
    }
  }

  /// A chapter image as an absolute URL with the image token; nothing when
  /// no token is known yet.
  String? _chapterImagePath(String fileId, int index) {
    final token = _imageToken?.token;
    if (token == null) return null;
    return _api.resolveUrl(
      '/api/v1/media/${TofaClient._seg(fileId)}/quickview/chapters/$index?st=${Uri.encodeQueryComponent(token)}',
    );
  }

  /// The file whose extras an item's playback uses: the one playing, else
  /// the one a download stored, else the one [chooseFile] picks.
  Future<String?> _extrasFileId(String itemId, {bool cacheOnly = false}) async {
    final playing = _playingFileIds[itemId];
    if (playing != null) return playing;
    final stored = await _downloadRecord(itemId);
    if (stored != null) return stored.fileId;
    if (cacheOnly) return null;
    final item = await _fetchItem(itemId);
    if (item == null) return null;
    try {
      return await chooseFile(item);
    } on PlaybackException {
      return null;
    }
  }

  Future<PlaybackExtras> _extras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool cacheOnly = false,
  }) async {
    final fileId = await _extrasFileId(itemId, cacheOnly: cacheOnly);
    final quickView = fileId == null ? null : await _quickView(fileId, cacheOnly: cacheOnly);
    return TofaOfflineExtras.build(
      record: await _downloadRecord(itemId),
      quickView: quickView,
      classifier: await ChapterMarkerClassifier.bundled,
      chapterThumb: fileId == null || cacheOnly ? null : (index) => _chapterImagePath(fileId, index),
      introPattern: introPattern,
      creditsPattern: creditsPattern,
      forceChapterFallback: forceChapterFallback,
    );
  }

  /// QuickView `tiles` as a trickplay manifest by width.
  static Map<int, TrickplayInfo> trickplayManifest(Object? tiles) {
    final out = <int, TrickplayInfo>{};
    if (tiles is! List) return out;
    for (final tile in tiles.whereType<Map>()) {
      int? n(String key) => (tile[key] as num?)?.toInt();
      final width = n('width');
      final height = n('height');
      final cols = n('tile_width');
      final rows = n('tile_height');
      final count = n('thumbnail_count');
      final interval = n('interval_ms');
      if (width == null || height == null || cols == null || rows == null || count == null || interval == null) {
        continue;
      }
      if (width <= 0 || height <= 0 || cols <= 0 || rows <= 0 || count <= 0 || interval <= 0) continue;
      out[width] = TrickplayInfo(
        width: width,
        height: height,
        tileWidth: cols,
        tileHeight: rows,
        thumbnailCount: count,
        interval: interval,
        bandwidth: n('bandwidth_bps') ?? 0,
      );
    }
    return out;
  }

  Future<ScrubPreviewSource?> _scrubPreview(MediaItem item, MediaSourceInfo mediaSource) async {
    final fileId = mediaSource.mediaSourceId ?? _playingFileIds[item.id];
    if (fileId == null || _offlineMode) return null;
    final (quickView, _) = await (_quickView(fileId), _ensureImageToken().catchError((_) {})).wait;
    final manifest = trickplayManifest(quickView?['tiles']);
    final token = _imageToken?.token;
    if (manifest.isEmpty || token == null) {
      appLogger.d('[tofa] no seek previews (tiles=${manifest.length}, token=${token != null})');
      return null;
    }
    return JellyfinTrickplayService.forSheets(
      sheetUrl: (width, index) => _api.resolveUrl(
        '/api/v1/media/${TofaClient._seg(fileId)}/quickview/tiles/$width/$index?st=${Uri.encodeQueryComponent(token)}',
      ),
      manifest: manifest,
    );
  }
}
