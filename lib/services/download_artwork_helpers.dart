import '../media/download_resolution.dart';
import '../media/media_item.dart';

/// Maps a per-item image path/URL to the actual downloadable URL.
/// Plex resolves paths through `getThumbnailUrl` (token-aware); Jellyfin
/// stores absolute URLs already and passes them through. Returning `null`
/// or an empty string skips the entry.
typedef ArtworkUrlResolver = String? Function(String path);

/// Stable storage key for artwork. Jellyfin image URLs carry `api_key` for
/// fetching, but persisted DB rows and hashed local filenames must not contain
/// long-lived tokens.
///
/// Silo hands out self-authorising artwork URLs whose signature rotates at
/// least daily (`/api/v2/artwork/{key}?exp=&sig=`, or S3 presigned
/// `X-Amz-*` URLs), so those parameters are dropped too: the same image must
/// map to the same local file after the server re-signs its URL.
String artworkStorageKey(String pathOrUrl) {
  final uri = Uri.tryParse(pathOrUrl);
  if (uri == null || !uri.hasQuery) return pathOrUrl;
  final signedSiloArtwork = uri.path.contains('/api/v2/artwork/');
  bool isSignature(String key) => key.startsWith('X-Amz-') || (signedSiloArtwork && (key == 'exp' || key == 'sig'));
  final params = Map<String, String>.from(uri.queryParameters)..remove('api_key');
  final signatureCount = params.keys.where(isSignature).length;
  if (signatureCount > 0) {
    params.removeWhere((key, _) => isSignature(key));
    // `replace(queryParameters: null)` would keep the old query.
    if (params.isEmpty) return uri.replace(query: '').toString().replaceFirst(RegExp(r'\?(?=#|$)'), '');
  }
  return uri.replace(queryParameters: params.isEmpty ? null : params).toString();
}

/// Build [DownloadArtworkSpec]s for the four standard [MediaItem] image
/// fields (thumb, clearLogo, art, backgroundSquare). The four-field
/// enumeration is the same across backends; only the URL transformation
/// differs.
List<DownloadArtworkSpec> buildArtworkSpecs(MediaItem item, ArtworkUrlResolver resolveUrl) {
  final specs = <DownloadArtworkSpec>[];
  void addIfPresent(String? path) {
    if (path == null || path.isEmpty) return;
    final url = resolveUrl(path);
    if (url == null || url.isEmpty) return;
    specs.add(DownloadArtworkSpec(localKey: artworkStorageKey(path), url: url));
  }

  addIfPresent(item.thumbPath);
  addIfPresent(item.clearLogoPath);
  addIfPresent(item.artPath);
  addIfPresent(item.backgroundSquarePath);
  return specs;
}
