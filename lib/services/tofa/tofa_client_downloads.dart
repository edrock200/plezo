part of 'tofa_client.dart';

/// Downloads for offline playback (`POST /api/v1/download/register`).
///
/// 1. The file is picked as for playback; its `download_options` (best
///    first) give the qualities, and the picked one's `tag` is the
///    `quality_key`. Original is used unless the person picked another.
/// 2. Registering answers the download's id, a scoped token (`auth`) and the
///    offline metadata (tracks, skip segments), kept pinned as a
///    [TofaDownloadRecord]. A quality the server first has to prepare
///    answers 409/503; its progress is read from
///    `GET /download/prepare/{client_request_id}` and the download waits
///    ([DownloadNotReadyException]).
/// 3. The bytes come from `GET /stream/{file_id}/download?quality=` with the
///    scoped token as `st` (the route's only scheme). Text subtitles come from
///    the offline subtitle artifact route listed in `subtitle_manifest`, with
///    the `X-Tofa-Device-Id` header it requires.
/// 4. Deleting the local copy unregisters it (`DELETE /download/{id}`).
///    Progress made offline goes up as `POST /playback/offlineProgress`.
///
/// Unverified on a server: that `auth.token` is the `st` of the download
/// route (its `mode` values are not listed); that `request_id` of the
/// preparation route is the `client_request_id` sent; that re-registering
/// with the same `client_request_id` answers the same download with fresh
/// tokens; that `quality` on the download route takes the option's `tag`.
/// Tokens never reach a log or a stored path: the URL goes only to the
/// native download task, and file names come from the item's metadata.
extension _TofaDownloads on TofaClient {
  TofaApiCache? get _cacheOrNull => _tofaCache;

  Future<TofaDownloadRecord?> _downloadRecord(String itemId) async =>
      _cacheOrNull?.getDownloadRecord(ServerId(cacheServerId), itemId);

  /// The detail JSON of the file [fileId] of [item], for its
  /// `download_options`.
  Future<Map<String, dynamic>?> _fileJson(MediaItem item, String fileId) async {
    final d = await _detail(TofaMappers.mediaIdOf(item.id));
    if (d == null) return null;
    Map<String, dynamic>? find(Object? files) {
      if (files is! List) return null;
      for (final f in files.whereType<Map<String, dynamic>>()) {
        if (f['id'] == fileId) return f;
      }
      return null;
    }

    final own = find(d.json['files']);
    if (own != null) return own;
    final seasons = d.json['seasons'];
    if (seasons is List) {
      for (final season in seasons.whereType<Map>()) {
        final episodes = season['episodes'];
        if (episodes is! List) continue;
        for (final episode in episodes.whereType<Map>()) {
          final hit = find(episode['files']);
          if (hit != null) return hit;
        }
      }
    }
    return null;
  }

  /// The qualities [item] can be downloaded at (for a season or show: those
  /// of its first episode with a file, as a guide; each episode then takes
  /// its own option of that kind). Empty when there is nothing to choose.
  Future<List<TofaDownloadQuality>> _qualityChoices(MediaItem item) async {
    var target = item;
    if (item.kind == MediaKind.show || item.kind == MediaKind.season) {
      final episodes = await fetchPlayableDescendants(item.id);
      target = episodes.firstWhere((e) => TofaMappers.fileIdsOf(e).isNotEmpty, orElse: () => item);
      if (identical(target, item)) return const [];
    }
    final String fileId;
    try {
      fileId = await chooseFile(target);
    } on PlaybackException {
      return const [];
    }
    final options = TofaDownloadQuality.listOf((await _fileJson(target, fileId))?['download_options']);
    return options.length > 1 ? options : const [];
  }

  Future<void> _setQuality(MediaItem item, TofaDownloadQuality quality) async {
    await _cacheOrNull?.put(ServerId(cacheServerId), TofaApiCache.qualityEndpoint(item.id), {
      'preference': quality.preference,
    });
    await _cacheOrNull?.pin(ServerId(cacheServerId), TofaApiCache.qualityEndpoint(item.id));
  }

  /// The quality picked for [item], or for its season or show.
  Future<String?> _qualityPreference(MediaItem item) async {
    for (final id in [item.id, item.parentId, item.grandparentId].nonNulls) {
      final stored = await _cacheOrNull?.get(ServerId(cacheServerId), TofaApiCache.qualityEndpoint(id));
      final preference = stored?['preference'];
      if (preference is String) return preference;
    }
    return null;
  }

  Future<({TofaDownloadRecord record, Map<String, dynamic> answer})> _register(
    MediaItem item, {
    required String fileId,
    required TofaDownloadQuality quality,
    required String clientRequestId,
  }) async {
    final response = await _api.request(
      'POST',
      '/api/v1/download/register',
      body: {
        'device_id': _api.headers.deviceId,
        'media_file_id': fileId,
        'quality_key': quality.tag,
        'client_request_id': clientRequestId,
      },
    );
    if (response.statusCode == 409 || response.statusCode == 503) {
      throw await _preparationWait(clientRequestId, response.data);
    }
    TofaApi.throwIfTofaError(response);
    final data = response.data;
    if (data is Map && data['downloads_enabled'] == false) {
      throw const TofaDownloadsOffException();
    }
    final record = TofaDownloadRecord.fromRegistration(
      data,
      fileId: fileId,
      mediaId: TofaMappers.mediaIdOf(item.id),
      qualityKey: quality.tag,
      clientRequestId: clientRequestId,
    );
    if (record == null || data is! Map<String, dynamic>) {
      throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'Unusable download registration');
    }
    final previous = await _downloadRecord(item.id);
    await _cacheOrNull?.putDownloadRecord(
      ServerId(cacheServerId),
      item.id,
      previous?.downloadId == record.downloadId ? record.copyWith(seq: previous!.seq) : record,
    );
    // Offline chapters and skip markers come from the file's QuickView.
    unawaited(_quickView(fileId).then((_) => null, onError: (_) => null));
    appLogger.i('[tofa] download registered quality=${quality.isOriginal ? 'original' : quality.height}');
    return (record: record, answer: data);
  }

  /// A quality the server is still preparing: how far it got, as a wait.
  Future<Exception> _preparationWait(String requestId, Object? refusal) async {
    try {
      final status = await _api.getJson('/api/v1/download/prepare/${TofaClient._seg(requestId)}');
      if (status is Map) {
        final error = status['error'];
        if (status['finished'] == true && error is String && error.isNotEmpty) {
          appLogger.w('[tofa] download preparation failed error=$error');
          return MediaServerHttpException(
            type: MediaServerHttpErrorType.unknown,
            message: 'Download preparation failed',
            display: status['message'] is String ? status['message'] as String : null,
          );
        }
        final progress = (status['progress'] as num?)?.toDouble();
        final message = status['message'] is String && (status['message'] as String).isNotEmpty
            ? status['message'] as String
            : t.downloads.tofaPreparing;
        appLogger.d('[tofa] download preparing phase=${status['phase']} progress=$progress');
        return DownloadNotReadyException(message, retryAfter: const Duration(seconds: 20));
      }
    } catch (e) {
      appLogger.d('[tofa] download preparation status unavailable', error: e.runtimeType);
    }
    return DownloadNotReadyException(
      tofaErrorMessage(refusal) ?? t.downloads.tofaPreparing,
      retryAfter: const Duration(seconds: 30),
    );
  }

  Future<DownloadResolution> _resolveDownload(MediaItem item, {String? mediaSourceId}) async {
    final fileId = await chooseFile(item, requestedFileId: mediaSourceId);
    final options = TofaDownloadQuality.listOf((await _fileJson(item, fileId))?['download_options']);
    final quality = TofaDownloadQuality.pick(options, await _qualityPreference(item));
    if (quality == null) {
      // An older server lists no download options: nothing to register with.
      appLogger.w('[tofa] no download option for the file; not downloadable here');
      return const DownloadResolution(videoUrl: null);
    }
    final previous = await _downloadRecord(item.id);
    final requestId = previous != null && previous.fileId == fileId && previous.qualityKey == quality.tag
        ? previous.clientRequestId
        : const Uuid().v4();
    final (:record, :answer) = await _register(item, fileId: fileId, quality: quality, clientRequestId: requestId);
    final token = await _downloadToken(fileId, answer['auth']);
    final container = record.container?.trim().toLowerCase();
    final url = _api.resolveUrl(
      '/api/v1/stream/${TofaClient._seg(fileId)}/download?'
      '${encodeQueryParameters({'quality': quality.tag, 'st': token})}',
    );
    return DownloadResolution(
      videoUrl: container == null || container.isEmpty ? url : '$url#container=$container',
      mediaSourceId: fileId,
      externalSubtitles: _subtitleSpecs(fileId, answer),
      externalSubtitlesResolved: true,
    );
  }

  /// The registration's scoped token, else `GET /auth/download-token/{file}`.
  Future<String> _downloadToken(String fileId, Object? auth) async {
    final scoped = auth is Map ? auth['token'] : null;
    if (scoped is String && scoped.isNotEmpty) {
      LogRedactionManager.registerRotatingToken(scoped);
      return scoped;
    }
    final data = await _api.getJson('/api/v1/auth/download-token/${TofaClient._seg(fileId)}');
    final token = data is Map ? data['token'] : null;
    if (token is! String || token.isEmpty) {
      throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'No download token');
    }
    LogRedactionManager.registerRotatingToken(token);
    return token;
  }

  /// FNV-1a of [text]: a stable file-name id for a subtitle track id.
  static int _stableId(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  /// Text subtitle artifacts of `subtitle_manifest` (VTT, ASS); PGS stays
  /// out, as in Tofa's own apps. Language and title come from the
  /// `subtitle_tracks` snapshot with the same `relative_path`.
  List<DownloadSubtitleSpec> _subtitleSpecs(String fileId, Map<String, dynamic> answer) {
    final manifest = answer['subtitle_manifest'];
    final tracks = manifest is Map ? manifest['tracks'] : null;
    if (tracks is! List) return const [];
    final snapshots = {
      for (final s
          in (answer['subtitle_tracks'] is List ? answer['subtitle_tracks'] as List : const []).whereType<Map>())
        if (s['relative_path'] is String) s['relative_path'] as String: s,
    };
    final specs = <DownloadSubtitleSpec>[];
    for (final track in tracks.whereType<Map>()) {
      final trackId = track['track_id'];
      final rep = track['representation'];
      final auth = track['auth'];
      if (trackId is! String || rep is! Map || auth is! Map) continue;
      final format = rep['format'];
      final schema = rep['schema'];
      final revision = rep['revision'];
      final token = auth['token'];
      if (format is! String || schema is! String || revision is! String || token is! String) continue;
      if (format != 'vtt' && format != 'ass') continue;
      LogRedactionManager.registerRotatingToken(token);
      final snapshot = snapshots[track['relative_path']];
      specs.add(
        DownloadSubtitleSpec(
          id: int.tryParse(trackId) ?? _stableId(trackId),
          url: _api.resolveUrl(
            '/api/v1/stream/${TofaClient._seg(fileId)}/download/subtitles/${TofaClient._seg(trackId)}/'
            '$format/${TofaClient._seg(schema)}/${TofaClient._seg(revision)}?st=${Uri.encodeQueryComponent(token)}',
          ),
          codec: format == 'vtt' ? 'webvtt' : 'ass',
          language: snapshot?['language']?.toString(),
          languageCode: snapshot?['language']?.toString(),
          forced: snapshot?['is_forced'] == true,
          displayTitle: snapshot?['title']?.toString(),
          headers: {'X-Tofa-Device-Id': _api.headers.deviceId},
        ),
      );
    }
    return specs;
  }

  /// `DELETE /api/v1/download/{id}` for [itemId]'s download, then forget
  /// its record. Best effort: an unreachable server keeps the record for a
  /// later try.
  Future<void> _unregister(String itemId) async {
    final record = await _downloadRecord(itemId);
    if (record == null) return;
    try {
      final response = await _api.request('DELETE', '/api/v1/download/${TofaClient._seg(record.downloadId)}');
      if (response.statusCode < 300 || response.statusCode == 404) {
        await _cacheOrNull?.removeDownloadRecord(ServerId(cacheServerId), itemId);
        appLogger.i('[tofa] download unregistered');
      } else {
        appLogger.d('[tofa] download unregister answered ${response.statusCode}');
      }
    } catch (e) {
      appLogger.d('[tofa] download unregister failed', error: e.runtimeType);
    }
  }

  /// Progress played on the downloaded file, sent once the server is back
  /// (`POST /playback/offlineProgress`), with the next `monotonic_seq`.
  /// Null when [itemId] has no download (the caller saves it on the file).
  Future<bool> _sendOfflineProgress(String itemId, Duration position, DateTime? recordedAt) async {
    final record = await _downloadRecord(itemId);
    if (record == null) return false;
    final seq = record.seq + 1;
    await _api.send(
      'POST',
      '/api/v1/playback/offlineProgress',
      body: [
        {
          'device_id': _api.headers.deviceId,
          'download_id': record.downloadId,
          'media_file_id': record.fileId,
          'media_id': record.mediaId,
          'monotonic_seq': seq,
          'occurred_at_wall': ?recordedAt?.toUtc().toIso8601String(),
          'position_seconds': position.inMilliseconds / 1000,
        },
      ],
    );
    await _cacheOrNull?.putDownloadRecord(ServerId(cacheServerId), itemId, record.copyWith(seq: seq));
    appLogger.d('[tofa] offline progress sent seq=$seq');
    return true;
  }
}

/// The server turned downloads off for this account (`downloads_enabled`
/// false on registration).
class TofaDownloadsOffException implements Exception {
  const TofaDownloadsOffException();

  @override
  String toString() => 'TofaDownloadsOffException';
}

/// Unregisters a Tofa download when its local copy goes away. Registered
/// once; finds the live client of the download's server.
class TofaDownloadTracker implements DownloadServerTracker {
  TofaDownloadTracker._();

  static final instance = TofaDownloadTracker._();
  final Map<String, TofaClient> _clients = {};
  bool _registered = false;

  void attach(TofaClient client) {
    _clients[client.serverId.value] = client;
    if (!_registered) {
      _registered = true;
      DownloadServerTrackers.register(this);
    }
  }

  void detach(TofaClient client) {
    if (identical(_clients[client.serverId.value], client)) _clients.remove(client.serverId.value);
  }

  @override
  Future<void> localCopyCompleted(String globalKey) async {}

  @override
  Future<void> localCopyRemoved(String globalKey) async {
    final parsed = parseGlobalKey(globalKey);
    if (parsed == null) return;
    final client = _clients[parsed.serverId.value];
    if (client == null || client.isOfflineMode) return;
    await client._unregister(parsed.ratingKey);
  }
}
