import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/silo/silo_letter_index.dart';

void main() {
  group('SiloLetterIndex.fromJson', () {
    test('reads the contract fixture (query_catalog_letters_ok)', () {
      final index = SiloLetterIndex.fromJson({
        'total': 5,
        'letters': [
          {'letter': '#', 'count': 2, 'position': 0},
          {'letter': 'H', 'count': 3, 'position': 1},
        ],
        'runs': [
          {'letter': '#', 'position': 0},
          {'letter': 'H', 'position': 1},
          {'letter': '#', 'position': 4},
        ],
      });
      expect(index.total, 5);
      expect(index.letters.map((l) => l.letter), ['#', 'H']);
      expect(index.positionOf('H'), 1);
      expect(index.positionOf('h'), 1);
      expect(index.positionOf('B'), isNull);
      // Runs decide a position's letter: a collation can split a letter.
      expect(index.letterAt(0), '#');
      expect(index.letterAt(3), 'H');
      expect(index.letterAt(4), '#');
      expect(index.letterAt(400), '#');
    });

    test('accented titles sorted after Z keep their letter by run', () {
      final index = SiloLetterIndex.fromJson({
        'total': 250,
        'letters': [
          {'letter': '#', 'count': 10, 'position': 0},
          {'letter': 'A', 'count': 200, 'position': 10},
          {'letter': 'Z', 'count': 40, 'position': 210},
        ],
        'runs': [
          {'letter': 'Z', 'position': 210},
          {'letter': '#', 'position': 0},
          {'letter': 'A', 'position': 10},
          {'letter': 'A', 'position': 245},
        ],
      });
      expect(index.positionOf('A'), 10);
      expect(index.letterAt(9), '#');
      expect(index.letterAt(244), 'Z');
      expect(index.letterAt(249), 'A');
    });

    test('skips malformed entries and derives a missing total', () {
      final index = SiloLetterIndex.fromJson({
        'letters': [
          {'letter': 'A', 'count': 3, 'position': 0},
          {'letter': 'B', 'count': 0, 'position': 3},
          {'letter': '', 'count': 2, 'position': 3},
          {'count': 2, 'position': 3},
          {'letter': 'C', 'count': 'x', 'position': 3},
          {'letter': 'd', 'count': 4, 'position': 3},
        ],
      });
      expect(index.letters.map((l) => l.letter), ['A', 'D']);
      expect(index.total, 7);
      // No runs: letters' first positions place a position.
      expect(index.letterAt(1), 'A');
      expect(index.letterAt(5), 'D');
    });

    test('an empty index has no letters', () {
      final index = SiloLetterIndex.fromJson({'total': 0, 'letters': [], 'runs': []});
      expect(index.total, 0);
      expect(index.letterAt(0), isNull);
      expect(index.positionOf('A'), isNull);
    });
  });

  group('SiloLetterIndex.requestBody', () {
    test('a title-ordered library browse maps scope and order', () {
      expect(
        SiloLetterIndex.requestBody({
          'source': 'query',
          'library_id': '3',
          'sort': 'title',
          'image_size': 'medium',
          'type': 'movie',
        }),
        {'library_id': '3', 'type': 'movie', 'order': 'asc'},
      );
      expect(SiloLetterIndex.requestBody({'library_id': '3', 'sort': '-title'}), {'library_id': '3', 'order': 'desc'});
    });

    test('lists the index cannot describe give no body', () {
      expect(SiloLetterIndex.requestBody({'library_id': '3', 'sort': '-added_at'}), isNull);
      expect(SiloLetterIndex.requestBody({'library_id': '3', 'sort': 'title', 'q': 'heat'}), isNull);
      expect(SiloLetterIndex.requestBody({'library_id': '3', 'sort': 'title', 'name_prefix': 'B'}), isNull);
      expect(SiloLetterIndex.requestBody({'source': 'favorites', 'sort': 'title'}), isNull);
    });

    test('implicit filters become the groups the server derives from them', () {
      final body = SiloLetterIndex.requestBody({
        'library_id': '3',
        'sort': 'title',
        'genre': 'Drama',
        'year_min': 1990,
        'year_max': 1999,
        'content_rating': ['PG', 'R'],
      });
      expect(body!['groups'], [
        {
          'match': 'all',
          'rules': [
            {'field': 'genre', 'op': 'contains', 'value': 'Drama'},
            {
              'field': 'year',
              'op': 'between',
              'value': [1990, 1999],
            },
          ],
        },
        {
          'match': 'any',
          'rules': [
            {'field': 'content_rating', 'op': 'is', 'value': 'PG'},
            {'field': 'content_rating', 'op': 'is', 'value': 'R'},
          ],
        },
      ]);

      final single = SiloLetterIndex.requestBody({
        'library_id': '3',
        'sort': 'title',
        'year_min': 2001,
        'content_rating': ['PG-13'],
      });
      expect(single!['groups'], [
        {
          'match': 'all',
          'rules': [
            {'field': 'year', 'op': 'gte', 'value': 2001},
          ],
        },
        {
          'match': 'all',
          'rules': [
            {'field': 'content_rating', 'op': 'is', 'value': 'PG-13'},
          ],
        },
      ]);
    });
  });
}
