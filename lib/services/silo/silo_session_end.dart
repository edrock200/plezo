import '../../i18n/strings.g.dart';
import 'silo_api.dart';
import 'silo_catalog_strings.dart';

/// Why a Silo server ended a video playback session for good. Each is a 410
/// problem ([problemCode]) that progress posts and replans answer once the
/// session is over; the player leaves instead of starting a fresh session,
/// which would undo the stop (Silo Android #1043, protocol v3 §6.3).
enum SiloSessionEnd {
  /// An administrator stopped a player that could not be told directly.
  admin('playback_session_ended'),

  /// The session stayed paused past the administrator's limit
  /// (`playback.paused_session_timeout_minutes`). Only an attempt that
  /// advertised `paused_timeout_v1` gets this answer; others get [admin]'s.
  pausedTimeout('playback_session_paused_timeout');

  const SiloSessionEnd(this.problemCode);

  /// The 410 problem code that names this end.
  final String problemCode;

  /// The end a response names, or null when it does not say the server ended
  /// the session (any other status or problem, a 404 included).
  static SiloSessionEnd? of(int? status, Object? problem) {
    if (status != 410) return null;
    final code = problem is Map && problem['code'] is String ? problem['code'] as String : siloProblemCode(problem);
    for (final end in values) {
      if (end.problemCode == code) return end;
    }
    return null;
  }

  /// What the player says as it leaves. The paused timeout uses Silo's own
  /// catalog text (`player.notice.pausedTimeout`), as its apps do.
  String get notice => switch (this) {
    admin => t.messages.playbackSessionEndedByServer,
    pausedTimeout =>
      SiloCatalogStrings.format(pausedTimeoutCatalogKey, const {}) ?? t.messages.playbackStoppedPausedTooLong,
  };

  /// Silo's catalog key of the paused-timeout notice.
  static const pausedTimeoutCatalogKey = 'player.notice.pausedTimeout';
}
