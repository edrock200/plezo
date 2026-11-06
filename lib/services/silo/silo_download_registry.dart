import '../../exceptions/media_server_exceptions.dart';
import '../../i18n/strings.g.dart';
import '../../utils/media_server_http_client.dart';
import 'silo_api.dart';

/// Silo's managed downloads registry (`/api/v2/downloads`, Silo Android
/// #673 and the server's `docs/downloads-api.md`): the wire models and the
/// calls. [SiloManagedDownloads] decides when to make them.
///
/// Every call goes through [SiloApi], which already sends
/// `Authorization`, `X-Profile-Id` and `X-Silo-Device-Id` on every request;
/// the device header is what makes an entry a managed (per-device) one.

/// One of the server's quality presets, in ladder order (original first).
class SiloDownloadQuality {
  const SiloDownloadQuality(this.preset, {this.bitrateKbps, this.maxHeight});

  /// `original`, `20mbps`, `10mbps`, `5mbps`, `2mbps` or `1mbps`.
  final String preset;
  final int? bitrateKbps;

  /// The tallest output the preset can produce on this server.
  final int? maxHeight;

  static const original = SiloDownloadQuality(originalPreset);
  static const originalPreset = 'original';

  /// The presets Silo's server accepts, in the order its apps list them.
  static const ladder = ['original', '20mbps', '10mbps', '5mbps', '2mbps', '1mbps'];

  bool get isOriginal => preset == originalPreset;

  /// The bitrate the preset names, from its wire value when the server sent
  /// no `bitrate_kbps` (`10mbps` → 10000).
  int? get effectiveBitrateKbps {
    if (bitrateKbps != null && bitrateKbps! > 0) return bitrateKbps;
    final match = RegExp(r'^(\d+)mbps$').firstMatch(preset);
    return match == null ? null : int.parse(match.group(1)!) * 1000;
  }

  /// "Original quality", "10 Mbps", or "10 Mbps · up to 1080p" (4K for 2160).
  String get label {
    if (isOriginal) return t.siloManagedDownloads.qualityOriginal;
    final kbps = effectiveBitrateKbps;
    final mbps = kbps == null ? preset : _mbps(kbps);
    final height = maxHeight;
    if (height == null || height <= 0) return t.siloManagedDownloads.qualityBitrate(mbps: mbps);
    final resolution = height >= 2160 ? '4K' : '${height}p';
    return t.siloManagedDownloads.qualityBitrateUpTo(mbps: mbps, resolution: resolution);
  }

  static String _mbps(int kbps) {
    if (kbps % 1000 == 0) return '${kbps ~/ 1000}';
    return (kbps / 1000).toStringAsFixed(1);
  }

  @override
  bool operator ==(Object other) =>
      other is SiloDownloadQuality &&
      other.preset == preset &&
      other.bitrateKbps == bitrateKbps &&
      other.maxHeight == maxHeight;

  @override
  int get hashCode => Object.hash(preset, bitrateKbps, maxHeight);

  @override
  String toString() => 'SiloDownloadQuality($preset)';
}

/// `GET /api/v2/capabilities/downloads`: the per-account download policy.
class SiloDownloadCapability {
  const SiloDownloadCapability({
    this.revision,
    this.state,
    this.allowed,
    this.enabled = false,
    this.downloadAllowed = false,
    this.qualityPresets = const [],
    this.qualityOptions = const [],
    this.transcodeEnabled = false,
    this.transcodeUserAllowed = false,
    this.orderedStatus = false,
    this.fileDelivery = false,
    this.boundedCreation = false,
    this.directDownloadLinks = false,
    this.prepareAgain = false,
    this.revokedRemovesLocal = false,
  });

  final String? revision;
  final String? state;

  /// The effective answer (`download_allowed` and not refused by demo mode);
  /// absent on older servers.
  final bool? allowed;
  final bool enabled;
  final bool downloadAllowed;
  final List<String> qualityPresets;
  final List<SiloDownloadQuality> qualityOptions;
  final bool transcodeEnabled;
  final bool transcodeUserAllowed;
  final bool orderedStatus;
  final bool fileDelivery;
  final bool boundedCreation;
  final bool directDownloadLinks;
  final bool prepareAgain;
  final bool revokedRemovesLocal;

  factory SiloDownloadCapability.fromJson(Map<String, dynamic> json) {
    bool flag(String key) => json[key] == true;
    final presets = <String>[
      for (final value in (json['quality_presets'] is List ? json['quality_presets'] as List : const []))
        if (value is String && value.trim().isNotEmpty) value.trim().toLowerCase(),
    ];
    final options = <SiloDownloadQuality>[
      for (final value in (json['quality_options'] is List ? json['quality_options'] as List : const []))
        if (value is Map && value['preset'] is String)
          SiloDownloadQuality(
            (value['preset'] as String).trim().toLowerCase(),
            bitrateKbps: (value['bitrate_kbps'] as num?)?.toInt(),
            maxHeight: (value['max_height'] as num?)?.toInt(),
          ),
    ];
    return SiloDownloadCapability(
      revision: json['revision']?.toString(),
      state: json['state']?.toString(),
      allowed: json['allowed'] is bool ? json['allowed'] as bool : null,
      enabled: flag('enabled'),
      downloadAllowed: flag('download_allowed'),
      qualityPresets: presets,
      qualityOptions: options,
      transcodeEnabled: flag('transcode_enabled'),
      transcodeUserAllowed: flag('transcode_user_allowed'),
      orderedStatus: flag('ordered_status'),
      fileDelivery: flag('file_delivery'),
      boundedCreation: flag('bounded_creation'),
      directDownloadLinks: flag('direct_download_links'),
      prepareAgain: flag('prepare_again'),
      revokedRemovesLocal: flag('revoked_removes_local'),
    );
  }

  /// Downloads are on for this account (Silo's `isUsable`).
  bool get downloadsUsable =>
      enabled && downloadAllowed && allowed != false && (revision == null || state == 'available');

  /// Whether Plezilo registers its downloads here: the full native creation
  /// flow, revision-bound status reports and a usable account. A server that
  /// answers no (or has no capability route) gets today's untracked direct
  /// downloads.
  bool get managesDownloads => downloadsUsable && boundedCreation && orderedStatus;

  /// The presets to offer, in ladder order: the server's list, with every
  /// bitrate preset dropped unless converting is on for the server AND this
  /// user (Silo's `allowedQualities`). Never empty: original at least.
  List<SiloDownloadQuality> get allowedQualities {
    final offered = qualityPresets.toSet();
    final mayConvert = transcodeEnabled && transcodeUserAllowed;
    final result = <SiloDownloadQuality>[
      for (final preset in SiloDownloadQuality.ladder)
        if (offered.contains(preset) && (preset == SiloDownloadQuality.originalPreset || mayConvert))
          qualityOptions.firstWhere((o) => o.preset == preset, orElse: () => SiloDownloadQuality(preset)),
    ];
    return result.isEmpty ? const [SiloDownloadQuality.original] : result;
  }

  /// [preset] when this account may request it, else original (Silo's
  /// `effectiveDefault`: a saved preset the server would now refuse falls
  /// back rather than failing the download).
  String effectivePreset(String? preset) {
    final offered = allowedQualities.map((q) => q.preset).toList();
    if (preset != null && offered.contains(preset)) return preset;
    if (offered.contains(SiloDownloadQuality.originalPreset)) return SiloDownloadQuality.originalPreset;
    return offered.first;
  }
}

/// One managed registry entry (`DownloadEntry`).
class SiloDownloadEntry {
  const SiloDownloadEntry({
    required this.id,
    required this.contentId,
    this.episodeId,
    required this.mediaFileId,
    required this.status,
    this.quality = SiloDownloadQuality.originalPreset,
    this.effectiveQuality,
    this.deliveryFormat = 'original',
    this.revision = 0,
    this.fileSize = 0,
    this.deviceId,
    this.preparationState,
    this.queuePosition,
    this.preparationProgress,
    this.remainingSeconds,
  });

  final String id;
  final String contentId;
  final String? episodeId;
  final String mediaFileId;

  /// `preparing`, `ready`, `queued`, `downloading`, `completed`, `failed`,
  /// `cancelled`, `revoked` (or a newer value, kept as sent).
  final String status;
  final String quality;
  final String? effectiveQuality;

  /// `original`, `remux` or `transcode`.
  final String deliveryFormat;
  final int revision;
  final int fileSize;
  final String? deviceId;
  final String? preparationState;
  final int? queuePosition;
  final double? preparationProgress;
  final int? remainingSeconds;

  static SiloDownloadEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString();
    final contentId = raw['content_id']?.toString();
    final fileId = raw['media_file_id']?.toString();
    final status = raw['status']?.toString().trim().toLowerCase();
    if (id == null || id.isEmpty || contentId == null || fileId == null || fileId.isEmpty || status == null) {
      return null;
    }
    final preparation = raw['preparation'];
    final episode = raw['episode_id']?.toString();
    return SiloDownloadEntry(
      id: id,
      contentId: contentId,
      episodeId: episode == null || episode.isEmpty ? null : episode,
      mediaFileId: fileId,
      status: status,
      quality: raw['quality']?.toString().toLowerCase() ?? SiloDownloadQuality.originalPreset,
      effectiveQuality: raw['effective_quality']?.toString().toLowerCase(),
      deliveryFormat: raw['delivery_format']?.toString().toLowerCase() ?? 'original',
      revision: (raw['revision'] as num?)?.toInt() ?? 0,
      fileSize: (raw['file_size'] as num?)?.toInt() ?? 0,
      deviceId: raw['device_id']?.toString(),
      preparationState: preparation is Map ? preparation['state']?.toString() : null,
      queuePosition: preparation is Map ? (preparation['queue_position'] as num?)?.toInt() : null,
      preparationProgress: preparation is Map ? (preparation['progress'] as num?)?.toDouble() : null,
      remainingSeconds: preparation is Map ? (preparation['remaining_seconds'] as num?)?.toInt() : null,
    );
  }

  bool get isRevoked => status == 'revoked';
  bool get isPreparing => status == 'preparing';
  bool get isFailed => status == 'failed';

  /// An entry whose bytes are or will be servable without a new request.
  bool get isUsable => const {'ready', 'preparing', 'queued', 'downloading', 'completed'}.contains(status);

  /// The server serves the source file unchanged.
  bool get servesOriginal => deliveryFormat == 'original';
}

/// The registry's routes. Problems become [MediaServerHttpException]s whose
/// `display` is the sentence the download row shows.
class SiloDownloadRegistryApi {
  SiloDownloadRegistryApi(this._api);

  final SiloApi _api;

  static const _capabilityPath = '/api/v2/capabilities/downloads';
  static const _downloadsPath = '/api/v2/downloads';
  static String _entryPath(String id) => '$_downloadsPath/${Uri.encodeComponent(id)}';

  /// Server-relative path of an entry's bytes (needs the auth headers).
  static String filePath(String id) => '${_entryPath(id)}/file';

  /// The capability, or null when the server has no registry (404/405/501)
  /// or answers something that is not a capability document.
  Future<SiloDownloadCapability?> capability() async {
    final response = await _api.request('GET', _capabilityPath);
    if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501) return null;
    throwIfHttpError(response);
    final data = response.data;
    if (data is! Map) return null;
    return SiloDownloadCapability.fromJson(Map<String, dynamic>.from(data));
  }

  /// Every entry of this profile and device. All pages, or a throw: a
  /// prefix would make absent entries look deleted.
  Future<List<SiloDownloadEntry>> list() async {
    final entries = <String, SiloDownloadEntry>{};
    final cursors = <String>{};
    String? cursor;
    for (var page = 0; page < 100; page++) {
      final response = await _api.request('GET', _downloadsPath, query: {'limit': '100', 'cursor': ?cursor});
      throwIfHttpError(response);
      final data = response.data;
      final items = data is Map ? data['items'] : null;
      if (items is! List) throw _invalid(response.statusCode);
      for (final raw in items) {
        final entry = SiloDownloadEntry.fromJson(raw);
        if (entry != null) entries[entry.id] = entry;
      }
      final info = (data as Map)['page'];
      final hasMore = info is Map && info['has_more'] == true;
      if (!hasMore) return entries.values.toList();
      final next = info['next_cursor']?.toString();
      if (next == null || next.isEmpty || !cursors.add(next)) throw _invalid(response.statusCode);
      cursor = next;
    }
    throw _invalid(200);
  }

  /// `POST /downloads` for one file. [expected] is the entry this request
  /// may replace (its id and revision); null requires that none exists.
  /// Creation is never retried automatically (the server's rule): after an
  /// uncertain answer the next attempt reads the registry first.
  Future<SiloDownloadEntry> create({
    required String contentId,
    String? episodeId,
    required String mediaFileId,
    required String quality,
    SiloDownloadEntry? expected,
  }) async {
    final response = await _api.request(
      'POST',
      _downloadsPath,
      body: createBody(
        contentId: contentId,
        episodeId: episodeId,
        mediaFileId: mediaFileId,
        quality: quality,
        expected: expected,
      ),
      resendAfterRefresh: false,
    );
    _throwProblem(response);
    final data = response.data;
    final items = data is Map ? data['items'] : null;
    final entry = items is List && items.length == 1 ? SiloDownloadEntry.fromJson(items.single) : null;
    if (entry == null || entry.mediaFileId != mediaFileId) throw _invalid(response.statusCode);
    return entry;
  }

  /// The `POST /downloads` body for one managed file. No `caps`: Plezilo's
  /// player decodes in software whatever the device lacks, so an original
  /// download stays the source file (the server converts an `original`
  /// request only when caps say the device cannot play it).
  static Map<String, dynamic> createBody({
    required String contentId,
    String? episodeId,
    required String mediaFileId,
    required String quality,
    SiloDownloadEntry? expected,
  }) => {
    'content_id': contentId,
    'episode_id': ?episodeId,
    'media_file_id': mediaFileId,
    'quality': quality,
    'expected_revision': expected?.revision ?? 0,
    if (expected != null) 'expected_download_id': expected.id,
  };

  /// `PATCH /downloads/{id}`: one revision-bound status event. [updatedAt]
  /// is when the local state changed; a retry resends the same values.
  /// Returns the entry, or null when the server no longer has it (404) or
  /// the revision moved on (409): either way this event is spent.
  Future<SiloDownloadEntry?> reportStatus(
    String id, {
    required String status,
    required DateTime updatedAt,
    required int revision,
  }) async {
    final response = await _api.request(
      'PATCH',
      _entryPath(id),
      body: statusBody(status: status, updatedAt: updatedAt, revision: revision),
    );
    if (response.statusCode == 404 || response.statusCode == 409) return null;
    throwIfHttpError(response);
    return SiloDownloadEntry.fromJson(response.data);
  }

  static Map<String, dynamic> statusBody({
    required String status,
    required DateTime updatedAt,
    required int revision,
  }) => {'status': status, 'updated_at': updatedAt.toUtc().toIso8601String(), 'revision': revision};

  /// `DELETE /downloads/{id}`. True when the entry is gone (204, or 404:
  /// already gone or never this device's).
  Future<bool> delete(String id) async {
    final response = await _api.request('DELETE', _entryPath(id), resendAfterRefresh: false);
    if (response.statusCode == 404) return true;
    throwIfHttpError(response);
    return true;
  }

  /// `POST /downloads/{id}/prepare`, after the file route said
  /// `prepared_file_expired`.
  Future<SiloDownloadEntry?> prepareAgain(String id) async {
    final response = await _api.request('POST', '${_entryPath(id)}/prepare', resendAfterRefresh: false);
    _throwProblem(response);
    return SiloDownloadEntry.fromJson(response.data);
  }

  static MediaServerHttpException _invalid(int status) => MediaServerHttpException(
    type: MediaServerHttpErrorType.unknown,
    statusCode: status,
    message: 'Silo: incomplete download registry answer',
    display: t.siloManagedDownloads.errorInvalidAnswer,
  );

  /// A refused creation as the sentence the row shows: the account's limit
  /// (429), not allowed (403), a quality the server cannot make (422/501
  /// `capability_unsupported`), or a registry that changed meanwhile (409).
  static void _throwProblem(MediaServerResponse response) {
    final status = response.statusCode;
    if (status < 400) return;
    final display = switch (status) {
      429 => t.siloManagedDownloads.errorLimitReached,
      403 => t.siloManagedDownloads.errorNotAllowed,
      409 => t.siloManagedDownloads.errorChanged,
      422 || 501 => t.siloManagedDownloads.errorQualityUnavailable,
      _ => null,
    };
    throw MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      statusCode: status,
      responseData: response.data,
      requestUri: response.requestUri,
      message: 'HTTP $status',
      display: display,
    );
  }
}
