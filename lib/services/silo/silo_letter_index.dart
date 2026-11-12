/// Silo's letter index (`POST /api/v2/catalog/letters`, Silo Android #888):
/// where each letter's titles start in a title-ordered query-source browse,
/// so the A–Z bar can scroll the grid to a letter instead of filtering it.
///
/// Positions are zero-based and count in the browse's own order (ascending
/// or descending title), exactly as `seek` counts them on `GET /api/v2/catalog`.
class SiloLetterIndex {
  /// Titles in the whole list (the sum of the counts).
  final int total;

  /// Letters with at least one title, in list order. `A`–`Z`, or `#` for
  /// digits, symbols and non-Latin initials.
  final List<SiloLetter> letters;

  /// Blocks of consecutive titles under one letter, in list order, covering
  /// the whole list. The server's collation can sort some of a letter's
  /// titles apart from the rest (accented initials after Z), so a position's
  /// letter comes from these, not from [letters].
  final List<SiloLetterRun> runs;

  const SiloLetterIndex({required this.total, required this.letters, required this.runs});

  /// Parse the response body; malformed entries are skipped.
  factory SiloLetterIndex.fromJson(Map<String, dynamic> json) {
    int? intOf(Object? v) => v is num ? v.toInt() : null;
    final letters = <SiloLetter>[];
    final rawLetters = json['letters'];
    if (rawLetters is List) {
      for (final entry in rawLetters.whereType<Map>()) {
        final letter = entry['letter'];
        final count = intOf(entry['count']);
        final position = intOf(entry['position']);
        if (letter is! String || letter.isEmpty || count == null || count <= 0 || position == null || position < 0) {
          continue;
        }
        letters.add(SiloLetter(letter: letter.toUpperCase(), count: count, position: position));
      }
    }
    final runs = <SiloLetterRun>[];
    final rawRuns = json['runs'];
    if (rawRuns is List) {
      for (final entry in rawRuns.whereType<Map>()) {
        final letter = entry['letter'];
        final position = intOf(entry['position']);
        if (letter is! String || letter.isEmpty || position == null || position < 0) continue;
        runs.add(SiloLetterRun(letter: letter.toUpperCase(), position: position));
      }
    }
    runs.sort((a, b) => a.position.compareTo(b.position));
    final total = intOf(json['total']) ?? letters.fold<int>(0, (sum, l) => sum + l.count);
    return SiloLetterIndex(total: total < 0 ? 0 : total, letters: letters, runs: runs);
  }

  /// First list position of [letter], or null when no title files under it.
  int? positionOf(String letter) {
    final upper = letter.toUpperCase();
    for (final l in letters) {
      if (l.letter == upper) return l.position;
    }
    return null;
  }

  /// The letter whose titles the list shows at [position], or null for an
  /// empty index.
  String? letterAt(int position) {
    if (runs.isEmpty) {
      // A server that sent no runs: fall back to the letters' first positions.
      String? current;
      for (final l in letters) {
        if (l.position <= position) current = l.letter;
      }
      return current ?? (letters.isEmpty ? null : letters.first.letter);
    }
    // Last run starting at or before [position].
    var lo = 0;
    var hi = runs.length - 1;
    var found = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (runs[mid].position <= position) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return runs[found].letter;
  }

  /// The `POST /api/v2/catalog/letters` body describing the same list as the
  /// `GET /api/v2/catalog` [catalogParams] (as `SiloClient` builds them), or
  /// null when the letter index cannot describe that list: another source, a
  /// search (`q`), a `name_prefix`, or a sort other than title.
  ///
  /// The browse's implicit filters become the rule groups the server itself
  /// derives from them (`internal/catalog/catalog_parser.go`): `genre`
  /// contains, `year` between/gte/lte in one `all` group, and
  /// `content_rating` `is` (one rating) or an `any` group of `is` rules.
  static Map<String, dynamic>? requestBody(Map<String, dynamic> catalogParams) {
    final source = catalogParams['source'];
    if (source != null && source != 'query') return null;
    if (_nonEmpty(catalogParams['q']) || _nonEmpty(catalogParams['name_prefix'])) return null;
    final order = switch (catalogParams['sort']) {
      'title' => 'asc',
      '-title' => 'desc',
      _ => null,
    };
    if (order == null) return null;

    final groups = <Map<String, dynamic>>[];
    final implicit = <Map<String, dynamic>>[];
    final genre = catalogParams['genre'];
    if (genre is String && genre.trim().isNotEmpty) {
      implicit.add({'field': 'genre', 'op': 'contains', 'value': genre.trim()});
    }
    final yearMin = _int(catalogParams['year_min']);
    final yearMax = _int(catalogParams['year_max']);
    if (yearMin != null && yearMin > 0 && yearMax != null && yearMax > 0) {
      implicit.add({
        'field': 'year',
        'op': 'between',
        'value': [yearMin, yearMax],
      });
    } else if (yearMin != null && yearMin > 0) {
      implicit.add({'field': 'year', 'op': 'gte', 'value': yearMin});
    } else if (yearMax != null && yearMax > 0) {
      implicit.add({'field': 'year', 'op': 'lte', 'value': yearMax});
    }
    if (implicit.isNotEmpty) groups.add({'match': 'all', 'rules': implicit});

    final rawRatings = catalogParams['content_rating'];
    final ratings = <String>[
      if (rawRatings is String) ...rawRatings.split(','),
      if (rawRatings is Iterable) ...rawRatings.map((r) => '$r'),
    ].map((r) => r.trim()).where((r) => r.isNotEmpty).toList();
    if (ratings.length == 1) {
      groups.add({
        'match': 'all',
        'rules': [
          {'field': 'content_rating', 'op': 'is', 'value': ratings.single},
        ],
      });
    } else if (ratings.length > 1) {
      groups.add({
        'match': 'any',
        'rules': [
          for (final r in ratings) {'field': 'content_rating', 'op': 'is', 'value': r},
        ],
      });
    }

    return {
      if (_nonEmpty(catalogParams['library_id'])) 'library_id': '${catalogParams['library_id']}',
      if (_nonEmpty(catalogParams['type'])) 'type': '${catalogParams['type']}',
      if (groups.isNotEmpty) 'groups': groups,
      'order': order,
    };
  }

  static bool _nonEmpty(Object? v) => v != null && '$v'.trim().isNotEmpty;

  static int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));
}

/// One letter of a [SiloLetterIndex].
class SiloLetter {
  final String letter;

  /// Titles filed under the letter.
  final int count;

  /// Zero-based list position of the letter's first title.
  final int position;

  const SiloLetter({required this.letter, required this.count, required this.position});
}

/// One block of consecutive titles under one letter.
class SiloLetterRun {
  final String letter;

  /// Zero-based list position of the block's first title; the block ends
  /// where the next starts, or at the index's total.
  final int position;

  const SiloLetterRun({required this.letter, required this.position});
}
