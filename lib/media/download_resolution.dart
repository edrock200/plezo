/// Backend-neutral download resolution types.
///
/// Returned by [MediaServerClient] download-resolution methods so the
/// [DownloadManagerService] doesn't need to know whether it's talking to
/// Plex or Jellyfin.
library;

/// Spec for a single external subtitle track that should be downloaded
/// alongside the video file.
///
/// `id` is a backend-stable integer used in the on-disk filename
/// (Plex stream id, Jellyfin stream index).
class DownloadSubtitleSpec {
  final int id;
  final String url;
  final String? codec;
  final String? language;
  final String? languageCode;
  final bool forced;
  final String? displayTitle;

  const DownloadSubtitleSpec({
    required this.id,
    required this.url,
    this.codec,
    this.language,
    this.languageCode,
    this.forced = false,
    this.displayTitle,
  });
}

/// Spec for a single artwork file. `localKey` is the deterministic key the
/// storage service hashes to compute the on-disk filename — Plex passes the
/// backend-relative path so cache deduplication works across items that
/// reference the same blob; Jellyfin passes the absolute URL since artwork
/// URLs are already unique per item after stripping auth query parameters.
class DownloadArtworkSpec {
  final String localKey;
  final String url;

  const DownloadArtworkSpec({required this.localKey, required this.url});
}

/// A file after the first of an item stacked across several files (Plex
/// `Part 2`, `Part 3`), with the subtitle sidecars that belong to that file.
class DownloadPartResolution {
  final String url;
  final List<DownloadSubtitleSpec> externalSubtitles;

  const DownloadPartResolution({required this.url, this.externalSubtitles = const []});
}

/// Bundle of everything the download pipeline needs to fetch the primary
/// video file and its companion subtitle sidecars for a chosen media
/// version.
class DownloadResolution {
  /// The first (for most items the only) file.
  final String? videoUrl;
  final String? mediaSourceId;
  final List<DownloadSubtitleSpec> externalSubtitles;

  /// Whether [externalSubtitles] is authoritative. A false value keeps the
  /// supplementary-download queue pending so it can retry enrichment later.
  final bool externalSubtitlesResolved;

  /// The files after [videoUrl], in playback order, when the version is
  /// stacked across several files. Empty for a single-file version.
  final List<DownloadPartResolution> additionalParts;

  /// HTTP headers the native download task sends with [videoUrl]. Empty for
  /// self-authorising URLs (the usual case). Silo's prepared downloads are
  /// served only to an authenticated, profile- and device-scoped request.
  final Map<String, String> headers;

  const DownloadResolution({
    required this.videoUrl,
    this.mediaSourceId,
    this.externalSubtitles = const [],
    this.externalSubtitlesResolved = true,
    this.additionalParts = const [],
    this.headers = const {},
  });
}

/// The server accepted the download but its file is not ready yet (Silo
/// prepares a converted copy first). The download waits [retryAfter] and
/// asks again; it is not a failure and spends no retry.
class DownloadNotReadyException implements Exception {
  /// Shown on the download row while it waits.
  final String message;
  final Duration retryAfter;

  const DownloadNotReadyException(this.message, {this.retryAfter = const Duration(seconds: 30)});

  @override
  String toString() => 'DownloadNotReadyException: $message';
}

/// A backend that keeps a server-side record of each download (Silo's
/// managed downloads registry) and follows the local copy's life. Registered
/// once at start-up in [DownloadServerTrackers]; the download manager calls
/// it with the download's global key and never waits for the server.
abstract interface class DownloadServerTracker {
  /// Every file of [globalKey] is stored locally.
  Future<void> localCopyCompleted(String globalKey);

  /// The local copy of [globalKey] is gone (deleted by the user, revoked,
  /// cleaned up).
  Future<void> localCopyRemoved(String globalKey);
}

/// The registered [DownloadServerTracker]s. Each call is best effort: a
/// tracker's failure is its own business and never reaches the caller.
abstract final class DownloadServerTrackers {
  static final List<DownloadServerTracker> _trackers = [];

  static void register(DownloadServerTracker tracker) {
    if (!_trackers.contains(tracker)) _trackers.add(tracker);
  }

  static void unregister(DownloadServerTracker tracker) => _trackers.remove(tracker);

  static void notifyCompleted(String globalKey) {
    for (final tracker in List.of(_trackers)) {
      _guard(() => tracker.localCopyCompleted(globalKey));
    }
  }

  static void notifyRemoved(String globalKey) {
    for (final tracker in List.of(_trackers)) {
      _guard(() => tracker.localCopyRemoved(globalKey));
    }
  }

  static void _guard(Future<void> Function() call) {
    try {
      call().catchError((Object _) {});
    } catch (_) {}
  }
}
