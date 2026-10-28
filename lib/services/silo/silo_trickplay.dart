import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_server_http_client.dart';
import '../scrub_preview_source.dart';
import 'silo_api.dart';
import 'silo_mappers.dart';

/// Seek-bar previews a Silo server published for one file (`trickplay_v1`,
/// `GET /api/v2/watch/{id}/trickplay?file_id=`): JPEG sprite sheets of
/// [columns] x [rows] thumbnails, one thumbnail per [intervalMs] of media
/// time. Every sheet holds the full grid (black after the last thumbnail).
///
/// The sheet URLs carry their own authorization until [expiresAt]; they are
/// credentials, so [toString] leaves them out and nothing logs them.
@immutable
class SiloTrickplayManifest {
  const SiloTrickplayManifest({
    required this.fileId,
    required this.intervalMs,
    required this.thumbnailWidth,
    required this.thumbnailHeight,
    required this.columns,
    required this.rows,
    required this.count,
    required this.sheetUrls,
    required this.expiresAt,
  });

  final String fileId;
  final int intervalMs;
  final int thumbnailWidth;
  final int thumbnailHeight;
  final int columns;
  final int rows;
  final int count;

  /// One absolute http(s) URL per sheet, in index order.
  final List<String> sheetUrls;

  /// When the sheet URLs stop working; null when the server's time did not parse.
  final DateTime? expiresAt;

  /// The largest sheet side, in pixels, a player decodes (the server keeps
  /// sheets within 3200), as in Silo's Android app.
  static const maxSheetSide = 8192;

  int get thumbnailsPerSheet => columns * rows;

  /// Validates a manifest answer. Null when it cannot be cut safely — another
  /// file's previews, a size outside 1..[maxSheetSide], a sheet wider or taller
  /// than [maxSheetSide], sheets that are not exactly indexes
  /// `0..ceil(count/(cols*rows))-1`, or a URL that is not http(s) — so the
  /// player keeps its time-only preview. [resolveUrl] makes root-relative
  /// sheet URLs absolute without touching their signed query.
  static SiloTrickplayManifest? parse(
    Object? json, {
    required String expectedFileId,
    required String Function(String url) resolveUrl,
  }) {
    if (json is! Map) return null;
    final fileId = json['file_id']?.toString();
    if (fileId == null || fileId.isEmpty || fileId != expectedFileId) return null;
    final interval = _int(json['interval_ms']);
    final width = _int(json['thumbnail_width']);
    final height = _int(json['thumbnail_height']);
    final columns = _int(json['tile_columns']);
    final rows = _int(json['tile_rows']);
    final count = _int(json['thumbnail_count']);
    if (interval == null || width == null || height == null || columns == null || rows == null || count == null) {
      return null;
    }
    if (interval <= 0 || count <= 0 || count > 0x7fffffff) return null;
    bool inRange(int v) => v >= 1 && v <= maxSheetSide;
    if (![width, height, columns, rows].every(inRange)) return null;
    if (columns * width > maxSheetSide || rows * height > maxSheetSide) return null;
    final perSheet = columns * rows;
    final rawSheets = json['sheets'];
    if (rawSheets is! List) return null;
    final sheets = <(int, String)>[];
    for (final entry in rawSheets) {
      if (entry is! Map) return null;
      final index = _int(entry['index']);
      final url = entry['url'];
      if (index == null || url is! String || url.isEmpty) return null;
      sheets.add((index, url));
    }
    sheets.sort((a, b) => a.$1.compareTo(b.$1));
    // Thumbnails are cut by index, so every sheet must be there, once.
    if (sheets.length != (count + perSheet - 1) ~/ perSheet) return null;
    final urls = <String>[];
    for (var i = 0; i < sheets.length; i++) {
      if (sheets[i].$1 != i) return null;
      final String absolute;
      try {
        absolute = resolveUrl(sheets[i].$2);
      } catch (_) {
        return null;
      }
      final scheme = Uri.tryParse(absolute)?.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') return null;
      urls.add(absolute);
    }
    final expiresRaw = json['expires_at'];
    return SiloTrickplayManifest(
      fileId: fileId,
      intervalMs: interval,
      thumbnailWidth: width,
      thumbnailHeight: height,
      columns: columns,
      rows: rows,
      count: count,
      sheetUrls: List.unmodifiable(urls),
      expiresAt: expiresRaw is String ? DateTime.tryParse(expiresRaw)?.toUtc() : null,
    );
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.truncateToDouble()) return value.toInt();
    return null;
  }

  /// The thumbnail for [time]: thumbnail i covers `[i*interval, (i+1)*interval)`,
  /// a time past the end shows the last one. Null for a negative time.
  SiloTrickplayTile? tileAt(Duration time) {
    final ms = time.inMilliseconds;
    if (ms < 0) return null;
    final position = ms ~/ intervalMs;
    final index = position >= count - 1 ? count - 1 : position;
    final cell = index % thumbnailsPerSheet;
    return SiloTrickplayTile(sheet: index ~/ thumbnailsPerSheet, column: cell % columns, row: cell ~/ columns);
  }

  /// Whether [other] cuts the same thumbnails, so its sheet URLs can stand in
  /// for these and sheets already held stay valid.
  bool hasSameLayout(SiloTrickplayManifest other) =>
      fileId == other.fileId &&
      intervalMs == other.intervalMs &&
      thumbnailWidth == other.thumbnailWidth &&
      thumbnailHeight == other.thumbnailHeight &&
      columns == other.columns &&
      rows == other.rows &&
      count == other.count &&
      sheetUrls.length == other.sheetUrls.length;

  @override
  String toString() =>
      'SiloTrickplayManifest(interval=${intervalMs}ms, ${thumbnailWidth}x$thumbnailHeight, '
      '${columns}x$rows, count=$count, sheets=${sheetUrls.length})';
}

/// One thumbnail: its sheet and its cell within that sheet.
@immutable
class SiloTrickplayTile {
  const SiloTrickplayTile({required this.sheet, required this.column, required this.row});

  final int sheet;
  final int column;
  final int row;

  @override
  bool operator ==(Object other) =>
      other is SiloTrickplayTile && other.sheet == sheet && other.column == column && other.row == row;

  @override
  int get hashCode => Object.hash(sheet, column, row);

  @override
  String toString() => 'SiloTrickplayTile(sheet=$sheet, column=$column, row=$row)';
}

/// A sheet download's outcome.
sealed class SiloTrickplaySheetResult {
  const SiloTrickplaySheetResult();
}

class SiloTrickplaySheetLoaded extends SiloTrickplaySheetResult {
  const SiloTrickplaySheetLoaded(this.bytes);
  final Uint8List bytes;
}

/// The server refused the URL (expired or revoked signature); a fresh
/// manifest may fix it.
class SiloTrickplaySheetRefused extends SiloTrickplaySheetResult {
  const SiloTrickplaySheetRefused();
}

class SiloTrickplaySheetFailed extends SiloTrickplaySheetResult {
  const SiloTrickplaySheetFailed();
}

/// Reads the manifest of the playing file. Throws [MediaServerHttpException]
/// for an HTTP or transport failure and [SiloTrickplayUnusable] for an answer
/// that does not validate.
typedef SiloTrickplayManifestLoader = Future<SiloTrickplayManifest> Function();

/// Downloads one sheet. The URL authorises itself: no Silo credentials or
/// device headers go with it (presigned URLs may point at another host).
typedef SiloTrickplaySheetLoader = Future<SiloTrickplaySheetResult> Function(String url);

/// The server answered with previews that cannot be cut.
class SiloTrickplayUnusable implements Exception {
  const SiloTrickplayUnusable();
  @override
  String toString() => 'SiloTrickplayUnusable';
}

/// Silo seek-bar previews for the player's scrub tooltip (port of Silo
/// Android's `TrickplayPreviews`, #695). Sheets load on demand into a bounded
/// in-memory cache (least recently used dropped first) and the next sheet is
/// prefetched. The sheet URLs are renewed by reading the manifest again
/// shortly before they expire, or when the server refuses one; a renewal that
/// lays the thumbnails out again drops the held sheets. A manifest the server
/// refuses on renewal withdraws the previews; transient failures back off.
class SiloTrickplayService implements ScrubPreviewSource {
  SiloTrickplayService({
    required this._manifest,
    required this._loadManifest,
    required this._loadSheet,
    DateTime Function()? now,
    this.sheetCacheBytes = defaultSheetCacheBytes,
  }) : _now = now ?? DateTime.now;

  /// About 16 sheets of 3000 x 1344, over three hours of a film at the
  /// server's default interval (Silo Android's bound).
  static const defaultSheetCacheBytes = 12 * 1024 * 1024;

  /// Largest sheet accepted; a body over it is cut off as it arrives.
  static const maxSheetBytes = 8 * 1024 * 1024;

  /// Sheet URLs are renewed this long before the manifest says they expire.
  static const renewalMargin = Duration(seconds: 60);

  /// How long a failed manifest read or sheet download is not repeated.
  static const retryBackoff = Duration(seconds: 30);

  final SiloTrickplayManifestLoader _loadManifest;
  final SiloTrickplaySheetLoader _loadSheet;
  final DateTime Function() _now;
  final int sheetCacheBytes;

  SiloTrickplayManifest _manifest;
  SiloTrickplayManifest get manifest => _manifest;

  bool _disposed = false;

  /// The server refused a renewal (or it no longer validates): no previews.
  bool _refused = false;

  /// Bumped whenever held sheets stop matching the manifest; work started
  /// before is dropped.
  int _generation = 0;

  Future<void>? _renewal;
  DateTime? _renewedAt;

  /// Encoded sheets held, by index, least recently used first.
  final LinkedHashMap<int, Uint8List> _held = LinkedHashMap<int, Uint8List>();
  int _heldBytes = 0;
  final Map<int, Future<Uint8List?>> _fetches = {};
  final Map<int, DateTime> _failedAt = {};

  /// One image provider per sheet, so the tooltip's image key is stable while
  /// the scrub dwells on a sheet.
  final Map<int, _SiloTrickplaySheetImage> _providers = {};
  int _attempt = 0;

  @visibleForTesting
  int get heldBytes => _heldBytes;

  @visibleForTesting
  Iterable<int> get heldSheets => _held.keys;

  @override
  bool get isAvailable => !_disposed && !_refused;

  @override
  ScrubFrame? getFrame(Duration time) {
    if (!isAvailable) return null;
    if (_expiresSoon()) unawaited(_renew());
    final manifest = _manifest;
    final tile = manifest.tileAt(time);
    if (tile == null) return null;
    final provider = _providerFor(tile.sheet);
    if (provider == null) return null;
    if (tile.sheet + 1 < manifest.sheetUrls.length) unawaited(sheetBytes(tile.sheet + 1));
    return SheetScrubFrame(
      sheet: provider,
      tileColumn: tile.column,
      tileRow: tile.row,
      sheetColumns: manifest.columns,
      sheetRows: manifest.rows,
      sourceTileSize: ui.Size(manifest.thumbnailWidth.toDouble(), manifest.thumbnailHeight.toDouble()),
    );
  }

  /// The provider for [index], or null while the sheet is backing off after
  /// a failure (the tooltip then shows the time only).
  _SiloTrickplaySheetImage? _providerFor(int index) {
    final existing = _providers[index];
    if (existing != null) return existing;
    final failed = _failedAt[index];
    if (failed != null && _now().difference(failed) < retryBackoff) return null;
    return _providers[index] = _SiloTrickplaySheetImage(this, _generation, index, ++_attempt);
  }

  /// The encoded bytes of sheet [index]: held, downloading (shared), or a new
  /// download. Null when it failed, is backing off, or the layout changed.
  @visibleForTesting
  Future<Uint8List?> sheetBytes(int index) {
    if (!isAvailable) return Future.value();
    final held = _held.remove(index);
    if (held != null) {
      _held[index] = held;
      return Future.value(held);
    }
    final inFlight = _fetches[index];
    if (inFlight != null) return inFlight;
    final failed = _failedAt[index];
    if (failed != null && _now().difference(failed) < retryBackoff) return Future.value();
    final generation = _generation;
    final future = _download(index).then((bytes) {
      if (generation != _generation || _disposed) return null;
      _fetches.remove(index);
      if (bytes != null) {
        _hold(index, bytes);
        _failedAt.remove(index);
      } else {
        _failedAt[index] = _now();
        _providers.remove(index);
      }
      return bytes;
    });
    _fetches[index] = future;
    return future;
  }

  Future<Uint8List?> _sheetBytesFor(int generation, int index) async {
    if (generation != _generation) return null;
    return sheetBytes(index);
  }

  Future<Uint8List?> _download(int index) async {
    var result = await _get(index);
    if (result is SiloTrickplaySheetRefused) {
      await _renew(force: true);
      result = await _get(index);
    }
    return result is SiloTrickplaySheetLoaded ? result.bytes : null;
  }

  Future<SiloTrickplaySheetResult?> _get(int index) async {
    if (!isAvailable || index >= _manifest.sheetUrls.length) return null;
    try {
      return await _loadSheet(_manifest.sheetUrls[index]);
    } catch (_) {
      return const SiloTrickplaySheetFailed();
    }
  }

  bool _expiresSoon() {
    final expires = _manifest.expiresAt;
    return expires != null && expires.difference(_now()) < renewalMargin;
  }

  /// Reads the manifest again for fresh sheet URLs. Concurrent callers share
  /// one read, and a read is not repeated within [retryBackoff] (a refused
  /// sheet also waits: its URL cannot be fixed by asking again at once).
  Future<void> _renew({bool force = false}) {
    final inFlight = _renewal;
    if (inFlight != null) return inFlight;
    final last = _renewedAt;
    if (last != null && _now().difference(last) < retryBackoff) return Future.value();
    if (!force && !_expiresSoon()) return Future.value();
    _renewedAt = _now();
    final renewal = _renewOnce();
    _renewal = renewal;
    return renewal.whenComplete(() {
      if (identical(_renewal, renewal)) _renewal = null;
    });
  }

  Future<void> _renewOnce() async {
    try {
      final renewed = await _loadManifest();
      if (_disposed) return;
      _install(renewed);
    } catch (e) {
      if (_disposed) return;
      if (isTransientTrickplayError(e)) {
        appLogger.d('Silo trickplay: renewal failed, keeping the current sheets', error: e.runtimeType);
        return;
      }
      appLogger.d('Silo trickplay: renewal refused; previews withdrawn', error: e.runtimeType);
      _refused = true;
      _dropSheets();
    }
  }

  void _install(SiloTrickplayManifest renewed) {
    final current = _manifest;
    _manifest = renewed;
    if (!renewed.hasSameLayout(current)) {
      appLogger.d('Silo trickplay: renewed manifest lays thumbnails out again: $renewed');
      _dropSheets();
    }
  }

  void _dropSheets() {
    _generation++;
    _fetches.clear();
    _held.clear();
    _heldBytes = 0;
    _failedAt.clear();
    _providers.clear();
  }

  void _hold(int index, Uint8List bytes) {
    final previous = _held.remove(index);
    if (previous != null) _heldBytes -= previous.length;
    _held[index] = bytes;
    _heldBytes += bytes.length;
    // The newest sheet stays even when it alone is over the bound.
    while (_heldBytes > sheetCacheBytes && _held.length > 1) {
      final eldest = _held.keys.first;
      _heldBytes -= _held.remove(eldest)!.length;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _dropSheets();
  }

  /// A dropped connection, rate limiting or a server error may pass; any
  /// other answer (404 none, 403 refused, an unusable manifest) is final.
  static bool isTransientTrickplayError(Object error) {
    if (error is! MediaServerHttpException) return false;
    if (error.isTransient) return true;
    final status = error.statusCode;
    return status == null ? !error.isCancellation : status == 429 || status >= 500;
  }

  // ---------------------------------------------------------------------------
  // Wiring to SiloClient
  // ---------------------------------------------------------------------------

  /// Builds the previews for [fileId] of [itemId] when the watch detail marks
  /// that version `trickplay_available` and its manifest validates. Null for
  /// every other outcome (no flag, 404, refused, unusable, offline), which
  /// keeps the time-only tooltip.
  static Future<SiloTrickplayService?> load({
    required SiloApi api,
    required String itemId,
    required String? fileId,
    required Future<Map<String, dynamic>?> Function() watchDetail,
  }) async {
    if (fileId == null || fileId.isEmpty) return null;
    try {
      final versions = SiloMappers.watchVersions(await watchDetail());
      final version = versions.where((v) => v['file_id']?.toString() == fileId).firstOrNull;
      if (version == null || version['trickplay_available'] != true) return null;
      Future<SiloTrickplayManifest> loadManifest() => fetchManifest(api, itemId: itemId, fileId: fileId);
      final manifest = await loadManifest();
      appLogger.d('Silo trickplay: $manifest');
      final client = api.rawHttpClient;
      return SiloTrickplayService(
        manifest: manifest,
        loadManifest: loadManifest,
        loadSheet: (url) => fetchSheet(client, url),
      );
    } catch (e) {
      appLogger.d(
        'Silo trickplay: no seek previews',
        error: e is MediaServerHttpException ? e.statusCode : e.runtimeType,
      );
      return null;
    }
  }

  /// `GET /api/v2/watch/{id}/trickplay?file_id=` (same access rules as the
  /// watch detail; 404 when the file has none).
  static Future<SiloTrickplayManifest> fetchManifest(
    SiloApi api, {
    required String itemId,
    required String fileId,
  }) async {
    final response = await api.request(
      'GET',
      '/api/v2/watch/${Uri.encodeComponent(itemId)}/trickplay',
      query: {'file_id': fileId},
    );
    throwIfHttpError(response);
    final manifest = SiloTrickplayManifest.parse(response.data, expectedFileId: fileId, resolveUrl: api.resolveUrl);
    if (manifest == null) throw const SiloTrickplayUnusable();
    return manifest;
  }

  /// Downloads one sheet with [client], sending nothing but the URL (it
  /// carries its own signature). 401/403/404/410 read as a refused (expired)
  /// URL; a body over [maxBytes] is cut off as it arrives.
  static Future<SiloTrickplaySheetResult> fetchSheet(
    http.Client client,
    String url, {
    int maxBytes = maxSheetBytes,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return const SiloTrickplaySheetFailed();
    }
    try {
      final streamed = await client.send(http.Request('GET', uri)).timeout(timeout);
      final status = streamed.statusCode;
      if (status != 200) {
        unawaited(streamed.stream.listen(null).cancel());
        return const {401, 403, 404, 410}.contains(status)
            ? const SiloTrickplaySheetRefused()
            : const SiloTrickplaySheetFailed();
      }
      final declared = streamed.contentLength;
      if (declared != null && declared > maxBytes) {
        unawaited(streamed.stream.listen(null).cancel());
        return const SiloTrickplaySheetFailed();
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) return const SiloTrickplaySheetFailed();
      }
      if (builder.isEmpty) return const SiloTrickplaySheetFailed();
      return SiloTrickplaySheetLoaded(builder.takeBytes());
    } catch (_) {
      return const SiloTrickplaySheetFailed();
    }
  }
}

/// A sheet image the tooltip crops; decoded from the service's held bytes.
/// Keyed by service, layout generation, sheet and attempt, so a renewal that
/// keeps the layout keeps the decoded image, and a retry after a failure is
/// a new image.
@immutable
class _SiloTrickplaySheetImage extends ImageProvider<_SiloTrickplaySheetImage> {
  const _SiloTrickplaySheetImage(this._owner, this._generation, this._index, this._attempt);

  final SiloTrickplayService _owner;
  final int _generation;
  final int _index;
  final int _attempt;

  @override
  Future<_SiloTrickplaySheetImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_SiloTrickplaySheetImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1.0, debugLabel: 'silo-trickplay-sheet-$_index');

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await _owner._sheetBytesFor(_generation, _index);
    if (bytes == null) throw StateError('Seek preview sheet $_index unavailable');
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is _SiloTrickplaySheetImage &&
      identical(other._owner, _owner) &&
      other._generation == _generation &&
      other._index == _index &&
      other._attempt == _attempt;

  @override
  int get hashCode => Object.hash(identityHashCode(_owner), _generation, _index, _attempt);
}
