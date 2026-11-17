import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../utils/formatters.dart';
import 'silo_catalog_strings.dart';

/// The cards of a Home or library row of collections (`collection_posters`,
/// silo-server #4410 / #4415; Silo Android #979 `SectionCollectionCard`).
abstract final class SiloCollectionCards {
  /// Raw marker on a collection item that came from a row of collections:
  /// its count is exact (0 is an empty collection), unlike the Collections
  /// tab's cards, whose 0 can mean "not counted".
  static const rowCardKey = 'plezy_silo_row_card';

  /// Raw field naming the profile that made and shared a personal collection
  /// (another profile of the account than the viewer's).
  static const ownerNameKey = 'plezy_silo_collection_owner';

  static const sourceLibrary = 'library';
  static const sourceUser = 'user';

  /// [card] when this client can read and open it, else null: a map whose
  /// fields have the contract's types, with a known `source` and an `id`, and
  /// a `library_id` on a server collection. Each card decodes on its own, as
  /// Silo's Android app does (#979): a card with a wrongly typed field is left
  /// out, never the row or Home.
  static Map<String, dynamic>? readable(Object? card) {
    if (card is! Map) return null;
    final json = <String, dynamic>{};
    for (final MapEntry(:key, :value) in card.entries) {
      if (key is! String) return null;
      json[key] = value;
    }
    final id = _idText(json['id']);
    if (id == null) return null;
    final source = json['source'];
    if (source != sourceLibrary && source != sourceUser) return null;
    for (final field in const [
      'title',
      'description',
      'overview',
      'poster_url',
      'poster_thumbhash',
      'backdrop_url',
      'backdrop_thumbhash',
    ]) {
      if (json[field] case final value? when value is! String) return null;
    }
    if (json['poster_is_collage'] case final value? when value is! bool) return null;
    if (json['item_count'] case final value? when value is! num || value != value.roundToDouble()) return null;
    if (json['library_id'] case final value? when _idText(value) == null) return null;
    if (json['creator_profile_id'] case final value? when value is! String && value is! int) return null;
    // A server collection opens in a library (and Home needs the library to
    // know it is one Plezilo shows).
    if (source == sourceLibrary && _idText(json['library_id']) == null) return null;
    return json;
  }

  static String? _idText(Object? value) {
    if (value is! String && value is! int) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// The card's library id (server collections), or null.
  static String? libraryIdOf(Map<String, dynamic> card) => _idText(card['library_id']);

  /// The profile that made a personal collection, or null.
  static String? creatorOf(Map<String, dynamic> card) =>
      card['source'] == sourceUser ? _idText(card['creator_profile_id']) : null;

  /// "by Name" in the app's language: Silo's catalog text
  /// (`collections.posterCard.byOwner`), then Silo's English, then Plezilo's.
  static String byOwner(String name) =>
      SiloCatalogStrings.format('collections.posterCard.byOwner', {'owner': name}) ??
      t.siloCollections.byOwner(owner: name);

  /// The caption under a row-of-collections card, or null for any other
  /// item. The count is exact (0 included). A personal collection another
  /// profile shared reads "by Name": beside the count on phones, tablets and
  /// desktops (Silo's phone card keeps the count on its poster), instead of it
  /// on a TV, whose poster-wide caption cannot hold both (Silo Android TV).
  static String? caption(MediaItem item, {required bool tv}) {
    if (item.kind != MediaKind.collection || item is! SiloMediaItem) return null;
    final raw = item.raw;
    if (raw == null || raw[rowCardKey] != true) return null;
    final count = item.childCount ?? item.leafCount ?? 0;
    final countText = count == 1 ? t.playlists.oneItem : t.playlists.itemCount(count: formatGroupedCount(count));
    final owner = raw[ownerNameKey];
    if (owner is! String || owner.isEmpty) return countText;
    final byline = byOwner(owner);
    return tv ? byline : '$countText · $byline';
  }
}
