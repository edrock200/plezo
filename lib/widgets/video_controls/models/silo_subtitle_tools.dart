import '../../../services/silo/silo_client.dart';
import 'track_controls_state.dart';

/// What the player's Silo subtitle sheets (search and "Translate with AI")
/// need from the playing video. Built by the video controls only for an
/// online Silo item.
class SiloSubtitleTools {
  const SiloSubtitleTools({
    required this.client,
    required this.itemId,
    required this.position,
    required this.isCurrent,
    required this.applyStored,
    required this.notify,
  });

  final SiloClient client;
  final String itemId;

  /// The playhead, for the AI job's `start_position`.
  final Duration Function() position;

  /// Whether [itemId] is still the playing item of the same controls; an AI
  /// job that outlives it stops being followed (it keeps running on the server).
  final bool Function() isCurrent;

  /// Reloads playback so the session lists the subtitle the server just
  /// stored, and selects it.
  final Future<SubtitleDownloadApplyOutcome> Function(String storedId) applyStored;

  /// Shows a message over the player (also when no sheet is open).
  final void Function(String message, {bool error}) notify;
}
