/// Receives a viewer's explicit track pick in the player, already resolved
/// to the source's own track ids (`MediaAudioTrack.id` /
/// `MediaSubtitleTrack.id`), for a backend that remembers picks somewhere
/// other than Plex's per-part selection or MediaBrowser's progress reports
/// (Silo's series and movie preferences). Only explicit picks that took
/// effect reach it: automatic selection, carried choices, restores and
/// track changes that failed never do.
///
/// Implementations must return at once and never throw: the pick has already
/// taken effect in the player, and remembering it is best effort.
abstract interface class SourceTrackPickSink {
  /// [reopened]: the pick reopened the source with a new playback (a
  /// server-side audio switch) that has opened; the backend remembers it only
  /// when that playback plays the track. Otherwise the player already
  /// switched to the track itself.
  void audioPicked(int sourceAudioId, {bool reopened = false});

  /// [sourceSubtitleId] null means subtitles were turned off.
  void subtitlePicked(int? sourceSubtitleId);
}

/// A client whose backend remembers a viewer's explicit track picks itself
/// (Silo). The player asks it for the sink of the item it plays; other
/// backends do not implement it and get none.
abstract interface class SourceTrackPickClient {
  SourceTrackPickSink trackPickSink(String itemId);
}
