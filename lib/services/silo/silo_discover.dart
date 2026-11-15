import 'silo_section_titles.dart';

/// One row of Silo's personalised recommendations
/// (`GET /api/v2/recommendations/discover`, the feed of Silo's "For You" page).
class SiloDiscoverRow {
  /// Stable across refreshes (see [SiloDiscover.stableId]).
  final String id;

  /// Row type: `cluster`, `similar_users_liked`, `popular`, `recently_added`,
  /// `top_rated`, `genre_sampler` (the set may grow).
  final String type;

  /// The server's own `title` (English when it carries a key).
  final String serverTitle;

  /// The title to show: [serverTitle] translated through `title_key`.
  final String title;

  /// Section kind (`for-you-main`, `cluster`, `similar-users`, `popular`,
  /// `recently-added`, `top-rated`, `genre`); null on older servers.
  final String? kind;

  /// Pairs with [kind] for the repeatable kinds (cluster index, genre name).
  final String? key;

  final String? titleKey;
  final Map<String, String> titleArgs;

  /// The cards as the server sent them (Silo catalog card JSON).
  final List<Map<String, dynamic>> items;

  const SiloDiscoverRow({
    required this.id,
    required this.type,
    required this.serverTitle,
    required this.title,
    required this.items,
    this.kind,
    this.key,
    this.titleKey,
    this.titleArgs = const {},
  });

  /// The profile's main personalised row, which Silo's apps put first.
  bool get isForYouMain =>
      kind?.toLowerCase() == SiloDiscover.forYouMainKind || serverTitle.trim().toLowerCase() == 'for you';
}

/// Parsing and ordering of the Discover feed, ported from Silo Android's
/// `DiscoverV2Api` and `RecommendationsViewModel.toResolvedSections` (rows in
/// server order, empty ones dropped, one row per identity, "For You" first;
/// Discover is not paged and its rows have no "Explore all").
abstract final class SiloDiscover {
  static const path = '/api/v2/recommendations/discover';
  static const forYouMainKind = 'for-you-main';

  /// Prefix of the hub ids (and identifiers) of Discover rows.
  static const hubIdPrefix = 'silo-discover:';

  /// The most cards one row shows (the server sizes its rows; this only
  /// bounds a surprising answer).
  static const maxItemsPerRow = 50;

  /// Kinds the server sends at most once per answer, without a key (silo-server
  /// `discoverRowSectionKey`); `cluster` and `genre` repeat and carry a key.
  static const _singletonKinds = {forYouMainKind, 'similar-users', 'popular', 'recently-added', 'top-rated'};

  /// The rows of a Discover answer `{items: [{type, title, title_key?,
  /// title_args?, kind?, key?, items: [card]}]}`.
  static List<SiloDiscoverRow> rows(Map<String, dynamic>? data) {
    final list = data?['items'];
    if (list is! List) return const [];
    final seen = <String>{};
    final rows = <SiloDiscoverRow>[];
    for (final raw in list.whereType<Map<String, dynamic>>()) {
      final cards = raw['items'];
      final items = [
        if (cards is List)
          for (final card in cards.whereType<Map<String, dynamic>>())
            if (_text(card['content_id']) != null) card,
      ];
      if (items.isEmpty) continue;
      final type = _text(raw['type']) ?? '';
      final serverTitle = raw['title']?.toString() ?? '';
      final kind = _text(raw['kind']);
      final key = _text(raw['key']);
      final id = stableId(type: type, title: serverTitle, kind: kind, key: key, items: items);
      if (!seen.add(id)) continue;
      final titleArgs = raw['title_args'];
      rows.add(
        SiloDiscoverRow(
          id: id,
          type: type,
          serverTitle: serverTitle,
          title: SiloSectionTitles.of(raw),
          kind: kind,
          key: key,
          titleKey: _text(raw['title_key']),
          titleArgs: {
            if (titleArgs is Map)
              for (final MapEntry(:key, :value) in titleArgs.entries)
                if (value != null) key.toString(): value.toString(),
          },
          items: items.length > maxItemsPerRow ? items.sublist(0, maxItemsPerRow) : items,
        ),
      );
    }
    // A stable sort: the For You row first, the rest in server order.
    final forYou = rows.where((row) => row.isForYouMain);
    return [...forYou, ...rows.where((row) => !row.isForYouMain)];
  }

  /// A row's identity, as Silo Android's `stableSectionId`: kind + key when
  /// the server sends them (kind alone for the singleton kinds), else the
  /// type, title and the cards it holds, so two key-less rows never collide
  /// and a refreshed row keeps its id (and its focus) when it can.
  static String stableId({
    required String type,
    required String title,
    String? kind,
    String? key,
    required List<Map<String, dynamic>> items,
  }) {
    if (kind != null && (key != null || _singletonKinds.contains(kind))) {
      return '$hubIdPrefix${_part(kind)}${_part(key ?? '')}';
    }
    final cards = [
      for (final item in items) _part(item['type']?.toString() ?? '') + _part(item['content_id'].toString()),
    ]..sort();
    return '${hubIdPrefix}legacy:${_part(type)}${_part(title)}${_part(cards.join())}';
  }

  static String? _text(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// Length-prefixed, so a separator inside a value cannot make two
  /// identities equal.
  static String _part(String value) => '${value.length}:$value';
}
