import '../i18n/strings.g.dart';
import 'media_item.dart';

/// A trailer or other video hosted by a third party (today only YouTube),
/// listed by a server next to an item.
///
/// Deliberately not a [MediaItem]: it never reaches the player, downloads,
/// caches, sync or watch state. The detail screen opens it with
/// `openYoutubeTrailer` (lib/utils/youtube_trailer_launcher.dart).
class RemoteTrailer {
  /// Provider name as the server sends it (`YouTube`); compare with [isYoutube].
  final String site;

  /// The provider's video id (YouTube's `v=` value).
  final String key;

  /// Display name from the provider, if any.
  final String? name;

  /// `trailer`, `teaser`, `featurette`, `clip`, … as the server labels it.
  final String kind;

  final bool isOfficial;
  final String? language;

  const RemoteTrailer({
    required this.site,
    required this.key,
    required this.kind,
    this.name,
    this.isOfficial = false,
    this.language,
  });

  bool get isYoutube => site.trim().toLowerCase() == 'youtube';

  /// YouTube's still for the video; `hqdefault` exists for every upload.
  String get thumbnailUrl => youtubeThumbnailUrl(key);

  @override
  bool operator ==(Object other) =>
      other is RemoteTrailer &&
      other.site == site &&
      other.key == key &&
      other.name == name &&
      other.kind == kind &&
      other.isOfficial == isOfficial &&
      other.language == language;

  @override
  int get hashCode => Object.hash(site, key, name, kind, isOfficial, language);

  @override
  String toString() => 'RemoteTrailer($site:$key, $kind, $name)';
}

/// YouTube's still image for [videoId].
String youtubeThumbnailUrl(String videoId) => 'https://i.ytimg.com/vi/${Uri.encodeComponent(videoId)}/hqdefault.jpg';

/// Optional capability of a `MediaServerClient`: third-party videos listed
/// for an item. Clients without remote trailers do not implement it, which
/// reads as an empty list (see [remoteTrailersOf]).
abstract interface class RemoteTrailerClient {
  /// Remote videos for [id] that Plezy can open, in the server's order.
  /// Empty when the item has none or the server does not list them.
  Future<List<RemoteTrailer>> fetchRemoteTrailers(String id);
}

/// [RemoteTrailerClient.fetchRemoteTrailers] for any client; empty for one
/// that does not list remote trailers.
Future<List<RemoteTrailer>> remoteTrailersOf(Object client, String id) async =>
    client is RemoteTrailerClient ? client.fetchRemoteTrailers(id) : const <RemoteTrailer>[];

/// One card of a detail page's "Trailers & Extras" row: a playable local
/// extra or a remote video.
sealed class ExtrasRailEntry {
  const ExtrasRailEntry();

  /// Namespaced so a local extra whose id equals a YouTube key cannot hide it.
  String get key;
}

final class LocalExtraEntry extends ExtrasRailEntry {
  final MediaItem item;
  const LocalExtraEntry(this.item);

  @override
  String get key => 'local:${item.id}';
}

final class RemoteTrailerEntry extends ExtrasRailEntry {
  final RemoteTrailer trailer;
  const RemoteTrailerEntry(this.trailer);

  @override
  String get key => 'remote:${trailer.site.toLowerCase()}:${trailer.key}';
}

/// Merge local extras and remote videos into one row, as Silo's apps do
/// (`trailerRailEntries`): local extras first in server order, because they
/// play in Plezy; then YouTube videos in server order (the server already
/// sorts trailers and official uploads first). Other sites and blank keys
/// are dropped rather than shown as cards that do nothing; duplicates keep
/// their first position.
List<ExtrasRailEntry> buildExtrasRail(List<MediaItem> local, List<RemoteTrailer> remote) {
  final seen = <String>{};
  final entries = <ExtrasRailEntry>[
    for (final item in local) LocalExtraEntry(item),
    for (final trailer in remote)
      if (trailer.isYoutube && trailer.key.trim().isNotEmpty) RemoteTrailerEntry(trailer),
  ];
  return entries.where((entry) => seen.add(entry.key)).toList();
}

/// The remote video a "Trailer" button should open when there is no local
/// trailer: the first YouTube `trailer`, else the first `teaser`.
RemoteTrailer? primaryRemoteTrailer(List<RemoteTrailer> remote) {
  final youtube = remote.where((t) => t.isYoutube && t.key.trim().isNotEmpty).toList();
  for (final kind in const ['trailer', 'teaser']) {
    for (final trailer in youtube) {
      if (trailer.kind.trim().toLowerCase() == kind) return trailer;
    }
  }
  return null;
}

/// Display label for an extra's or remote video's `kind` (Silo's
/// `extraKindLabel`), used when the server sends no title.
String extraKindLabel(String kind) {
  final labels = t.discover.extraKinds;
  switch (kind.trim().toLowerCase()) {
    case 'trailer':
      return labels.trailer;
    case 'teaser':
      return labels.teaser;
    case 'featurette':
      return labels.featurette;
    case 'behind_the_scenes' || 'behind-the-scenes' || 'behindthescenes':
      return labels.behindTheScenes;
    case 'deleted_scene' || 'deleted-scene' || 'deletedscene':
      return labels.deletedScene;
    case 'interview':
      return labels.interview;
  }
  final label = kind
      .replaceAll(RegExp('[_-]'), ' ')
      .split(' ')
      .where((word) => word.isNotEmpty)
      .map((word) => word[0].toUpperCase() + word.substring(1))
      .join(' ');
  return label.isEmpty ? labels.extra : label;
}
