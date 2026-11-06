/// Receives a viewer's explicit track pick in the player, already resolved
/// to the source's own track ids (`MediaAudioTrack.id` /
/// `MediaSubtitleTrack.id`), for a backend that remembers picks somewhere
/// other than Plex's per-part selection or MediaBrowser's progress reports
/// (Silo's series preferences). Only explicit picks reach it: automatic
/// selection, carried choices and restores never do.
///
/// Implementations must return at once and never throw: the pick has already
/// taken effect in the player, and remembering it is best effort.
abstract interface class SourceTrackPickSink {
  void audioPicked(int sourceAudioId);

  /// [sourceSubtitleId] null means subtitles were turned off.
  void subtitlePicked(int? sourceSubtitleId);
}
