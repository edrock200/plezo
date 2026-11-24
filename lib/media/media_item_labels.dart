import '../utils/formatters.dart';
import 'media_item.dart';
import 'media_kind.dart';

/// An episode's air date formatted for the locale ("Nov 20, 2026"), shown in
/// place of its season and episode code when its series is labeled by date
/// ([MediaItem.episodeAirDateLabel]: Silo sports series). Null shows the code,
/// which every Plex and Jellyfin item does.
String? episodeAirDateText(MediaItem item) {
  final date = item.episodeAirDateLabel;
  return date == null ? null : formatAbbreviatedDate(date);
}

/// [formatSeasonEpisodeLabel] ("S1 E2"), or the air date of an episode whose
/// series is labeled by date ([episodeAirDateText]).
String? formatEpisodeLabel(MediaItem item) =>
    episodeAirDateText(item) ?? formatSeasonEpisodeLabel(item.parentIndex, item.index);

String formatQueueItemSubtitle(MediaItem item) {
  final grandparentTitle = item.grandparentTitle;
  if (episodeAirDateText(item) case final date? when grandparentTitle != null) {
    return '$grandparentTitle \u00b7 $date';
  }
  if (grandparentTitle != null && item.parentIndex != null && item.index != null) {
    return '$grandparentTitle \u00b7 S${item.parentIndex}E${item.index}';
  }
  if (grandparentTitle != null) return grandparentTitle;
  if (item.year != null) {
    final edition = item.editionTitle;
    return edition != null ? '${item.year} \u00b7 $edition' : '${item.year}';
  }
  return item.kind.label;
}

/// Unambiguous label for the exact item a destructive action will affect.
///
/// [MediaItem.displayTitle] deliberately collapses an episode or season to its
/// show name so cards can headline the series. That makes it actively
/// dangerous in a delete confirmation: a show and one of its episodes render
/// the identical string, which is how #1781 was reported as "deleting one
/// episode deleted them all". This names the target instead.
String formatMediaTargetLabel(MediaItem item) {
  final segments = <String>[];
  void add(String? value) {
    if (value != null && value.isNotEmpty) segments.add(value);
  }

  switch (item.kind) {
    case MediaKind.episode:
      add(item.grandparentTitle);
      add(formatEpisodeLabel(item));
      add(item.title);
    case MediaKind.season:
      add(item.grandparentTitle ?? item.parentTitle);
      add(item.title);
    default:
      add(item.title);
  }

  // Every segment can be absent on a sparse row; the collapsed show name still
  // beats an empty confirmation.
  return segments.isEmpty ? item.displayTitle : toBulletedString(segments);
}
