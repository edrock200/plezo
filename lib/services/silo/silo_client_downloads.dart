part of 'silo_client.dart';

/// Where a registered download's bytes come from: null [url] means the
/// header-free direct-download link (the original file).
class _SiloManagedDownload {
  const _SiloManagedDownload({this.url, this.container, this.headers = const {}});

  final String? url;
  final String? container;
  final Map<String, String> headers;
}

/// Silo's managed downloads registry for this client's connection (one
/// account acting as one Silo profile). [SiloManagedDownloads] holds the
/// records and decides; this side supplies the identity and the transport.
mixin _SiloDownloadMethods on MediaServerCacheMixin, _SiloPlaybackMethods {
  late final SiloDownloadRegistryApi _downloadRegistry = SiloDownloadRegistryApi(_api);

  /// The quality presets this account may download in, or an empty list
  /// when the server has no registry or offers original only (no choice
  /// to show).
  Future<List<SiloDownloadQuality>> downloadQualityChoices() async {
    try {
      final cap = await SiloManagedDownloads.instance.capability(connection.id, _downloadRegistry);
      if (cap == null || !cap.managesDownloads) return const [];
      final qualities = cap.allowedQualities;
      return qualities.length > 1 ? qualities : const [];
    } catch (e) {
      appLogger.d('Silo: download qualities unavailable', error: e.runtimeType);
      return const [];
    }
  }

  /// Download [itemId] (and the episodes queued under a season or show) in
  /// [preset] from now on.
  Future<void> setDownloadQuality(String itemId, String preset) =>
      SiloManagedDownloads.instance.setQuality(connection.id, itemId, preset);

  /// Register the download of [fileId] with the server's registry and say
  /// how to fetch it; null on a server without the registry.
  @override
  Future<_SiloManagedDownload?> _managedDownload(MediaItem item, Map<String, dynamic> watch, String fileId) async {
    final isEpisode = item.kind == MediaKind.episode;
    final watchSeries = watch['series_id']?.toString();
    final seriesId = isEpisode
        ? (item.grandparentId ?? (watchSeries == null || watchSeries.isEmpty ? null : watchSeries))
        : null;
    final target = await SiloManagedDownloads.instance.prepare(
      scope: connection.id,
      api: _downloadRegistry,
      globalKey: buildGlobalKey(ServerId(item.serverId ?? connection.serverId), item.id),
      contentId: seriesId ?? item.id,
      episodeId: seriesId == null ? null : item.id,
      mediaFileId: fileId,
      qualityItemIds: [item.id, item.parentId, item.grandparentId],
    );
    if (target == null) return null;
    if (target.useDirectLink) return const _SiloManagedDownload();
    // A prepared copy (remux or conversion) is an MP4 served only to this
    // account, profile and device. The headers ride with the native task;
    // a later 401 (the access token expired) fails it and the retry
    // resolves again with fresh ones. Never a credential in the URL.
    final base = _api.baseUrl.endsWith('/') ? _api.baseUrl.substring(0, _api.baseUrl.length - 1) : _api.baseUrl;
    return _SiloManagedDownload(
      url: '$base${target.filePath}#container=mp4',
      container: 'mp4',
      headers: {..._api.device.toHeaders(), ..._api.authHeaders()},
    );
  }
}
