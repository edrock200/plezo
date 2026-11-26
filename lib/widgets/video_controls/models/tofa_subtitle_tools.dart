import '../../../services/tofa/tofa_client.dart';
import 'track_controls_state.dart';

/// What the player's Tofa subtitle search sheet needs from the playing video.
/// Built by the video controls only for an online Tofa item.
class TofaSubtitleTools {
  const TofaSubtitleTools({required this.client, required this.itemId, required this.applyTrack});

  final TofaClient client;
  final String itemId;

  /// Reloads playback so the session lists the subtitle the server just
  /// fetched (track [index] of the file), and selects it.
  final Future<SubtitleDownloadApplyOutcome> Function(int index) applyTrack;
}
