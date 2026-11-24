import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_source_info.dart';
import 'silo_mappers.dart';

/// Where a downloaded Silo file's end credits start (Silo Android #1038,
/// silo-android 137fca310).
///
/// Progress of a downloaded file goes up with `POST /api/v2/sync/progress`,
/// which does not name the played file, so the server can only apply its
/// watched percentage there: a download stopped in its end credits stayed
/// unwatched and in Continue Watching. Silo's apps store where the file's end
/// credits start when the download completes, and send a position at or past
/// it as the full duration, which the server stores as watched, as it judges a
/// streamed stop in the credits. The local resume point keeps the real
/// position.
abstract final class SiloEndCredits {
  /// The start of the end credits in a file of [duration]: the last credits
  /// range that starts in the file's tail window and before its end, or null.
  ///
  /// The tail window is the server's (`CreditsLimits.EndCreditsStart`, Silo's
  /// `MarkerTimeline.endCreditsStart`): the last 450 s or 40% of an episode,
  /// the last 900 s or 25% of anything else, whichever is shorter. Credits
  /// placed earlier never finish the title early, and touching ranges are not
  /// merged. [markers] are in source-time order ([SiloMappers.markers]).
  static Duration? start({required List<MediaMarker> markers, required Duration duration, required bool isEpisode}) {
    final durationMs = duration.inMilliseconds;
    if (durationMs <= 0) return null;
    final tailMs = isEpisode ? _min(450000, durationMs * 0.4) : _min(900000, durationMs * 0.25);
    final windowStartMs = durationMs - tailMs;
    MediaMarker? last;
    for (final marker in markers) {
      if (!marker.isCredits) continue;
      final startMs = marker.startTimeOffset;
      if (startMs >= windowStartMs && startMs < durationMs) last = marker;
    }
    return last == null ? null : Duration(milliseconds: last.startTimeOffset);
  }

  static double _min(num a, num b) => a < b ? a.toDouble() : b.toDouble();

  /// [start] for the version [fileId] of a watch-detail payload (the
  /// downloaded file), with its own `duration_seconds`. Null when the payload
  /// does not list that file, has no length for it or places no credits in
  /// its end window. The server bounds a file linked to an episode as an
  /// episode ([item] or the payload's `type`), anything else as a movie.
  static Duration? fromWatchDetail(Map<String, dynamic>? watch, {required String fileId, MediaItem? item}) {
    final versions = SiloMappers.watchVersions(watch);
    final index = versions.indexWhere((v) => v['file_id']?.toString() == fileId);
    if (index < 0) return null;
    final version = versions[index];
    final seconds = version['duration_seconds'] ?? version['duration'];
    if (seconds is! num || !seconds.isFinite || seconds <= 0) return null;
    final isEpisode = item?.kind == MediaKind.episode || watch?['type']?.toString() == 'episode';
    return start(
      markers: SiloMappers.markers(watch, version),
      duration: Duration(milliseconds: (seconds * 1000).round()),
      isEpisode: isEpisode,
    );
  }

  /// The position the server is sent for a downloaded file's [position]:
  /// the full [duration] at or past [endCreditsStart], else [position].
  static Duration reportedPosition({
    required Duration position,
    required Duration? duration,
    required Duration? endCreditsStart,
  }) {
    if (endCreditsStart == null || duration == null || duration <= Duration.zero) return position;
    return position >= endCreditsStart ? duration : position;
  }
}
