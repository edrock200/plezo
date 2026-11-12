import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/screens/libraries/library_alpha_bar_strategy.dart';
import 'package:plezy/services/silo/silo_letter_index.dart';

SiloLetterIndex _index() => SiloLetterIndex.fromJson({
  'total': 300,
  'letters': [
    {'letter': '#', 'count': 10, 'position': 0},
    {'letter': 'A', 'count': 90, 'position': 10},
    {'letter': 'B', 'count': 50, 'position': 100},
    {'letter': 'C', 'count': 50, 'position': 150},
    {'letter': 'D', 'count': 50, 'position': 200},
    {'letter': 'E', 'count': 30, 'position': 250},
    {'letter': 'Z', 'count': 15, 'position': 280},
  ],
  'runs': [
    {'letter': '#', 'position': 0},
    {'letter': 'A', 'position': 10},
    {'letter': 'B', 'position': 100},
    {'letter': 'C', 'position': 150},
    {'letter': 'D', 'position': 200},
    {'letter': 'E', 'position': 250},
    {'letter': 'Z', 'position': 280},
    // Accented A titles the collation sorts after Z.
    {'letter': 'A', 'position': 295},
  ],
});

bool _show(
  LibraryAlphaBarStrategy s, {
  required int chars,
  bool phone = false,
  String? sort = 'title',
  String? prefix,
}) => s.shouldShow(
  totalItemCount: 300,
  loadedCharacterCount: chars,
  sortKey: sort,
  isFolderGrouping: false,
  mediaBrowserAlphaPrefix: prefix,
  isPhone: phone,
);

void main() {
  LibraryQuery query = const LibraryQuery();
  setUp(() => query = const LibraryQuery());

  test('title order: real letters, a tap jumps to the server position, runs name the letter', () async {
    final asked = <LibraryQuery>[];
    final strategy = SiloAlphaBarStrategy(
      currentQuery: () => query,
      loadLetterIndex: (q) async {
        asked.add(q);
        return _index();
      },
    );
    final result = await strategy.loadCharacters(filters: const {}, typeId: null, descending: false);
    expect(result.chars.map((c) => c.title), ['#', 'A', 'B', 'C', 'D', 'E', 'Z']);
    expect(result.chars.map((c) => c.size), [10, 90, 50, 50, 50, 30, 15]);
    expect(asked, hasLength(1));
    expect(strategy.filtersByPrefix, isFalse);
    // Shown like Plex's bar: phones too, title order only.
    expect(_show(strategy, chars: result.chars.length), isTrue);
    expect(_show(strategy, chars: result.chars.length, phone: true), isTrue);
    expect(_show(strategy, chars: result.chars.length, sort: 'addedAt'), isFalse);

    // The bar reports the helper's cumulative offset; the jump uses the
    // server's own position for the letter.
    final helper = result.helper;
    final jumps = <int>[];
    String? prefix;
    strategy.onLetterPressed(
      helper.indexForLetter('Z')!,
      helper,
      currentMediaBrowserPrefix: null,
      onPlexJump: jumps.add,
      onMediaBrowserPrefixChange: (p) => prefix = p,
    );
    expect(jumps, [280]);
    expect(prefix, isNull);
    expect(strategy.currentLetter(296, helper), 'A');
    expect(strategy.currentLetter(285, helper), 'Z');
    expect(strategy.currentLetter(120, helper), 'B');
  });

  test('descending title order maps letters through the reversed helper', () async {
    query = const LibraryQuery(
      sort: LibrarySort(field: 'title', direction: LibrarySortDirection.descending),
    );
    final strategy = SiloAlphaBarStrategy(currentQuery: () => query, loadLetterIndex: (_) async => _index());
    final result = await strategy.loadCharacters(filters: const {}, typeId: null, descending: true);
    final jumps = <int>[];
    strategy.onLetterPressed(
      result.helper.indexForLetter('B')!,
      result.helper,
      currentMediaBrowserPrefix: null,
      onPlexJump: jumps.add,
      onMediaBrowserPrefixChange: (_) {},
    );
    expect(jumps, [100]);
  });

  test('another sort hides the bar and, once the server is known, asks nothing', () async {
    var asks = 0;
    final strategy = SiloAlphaBarStrategy(
      currentQuery: () => query,
      loadLetterIndex: (_) async {
        asks++;
        return _index();
      },
    );
    query = const LibraryQuery(
      sort: LibrarySort(field: 'addedAt', direction: LibrarySortDirection.descending),
    );
    final first = await strategy.loadCharacters(filters: const {}, typeId: null, descending: false);
    expect(first.chars, isEmpty);
    expect(asks, 1);
    expect(strategy.filtersByPrefix, isFalse);
    final second = await strategy.loadCharacters(filters: const {}, typeId: null, descending: false);
    expect(second.chars, isEmpty);
    expect(asks, 1);
    expect(_show(strategy, chars: 0, sort: 'addedAt'), isFalse);
  });

  test('a server without the index keeps the name_prefix bar (hidden on phones)', () async {
    var asks = 0;
    final strategy = SiloAlphaBarStrategy(
      currentQuery: () => query,
      loadLetterIndex: (_) async {
        asks++;
        return null;
      },
    );
    final result = await strategy.loadCharacters(filters: const {}, typeId: null, descending: false);
    expect(strategy.filtersByPrefix, isTrue);
    expect(result.chars, hasLength(27));
    expect(_show(strategy, chars: 27), isTrue);
    expect(_show(strategy, chars: 27, phone: true), isFalse);
    await strategy.loadCharacters(filters: const {}, typeId: null, descending: false);
    expect(asks, 1);

    String? prefix;
    strategy.onLetterPressed(
      result.helper.indexForLetter('C')!,
      result.helper,
      currentMediaBrowserPrefix: null,
      onPlexJump: (_) => fail('no jump without an index'),
      onMediaBrowserPrefixChange: (p) => prefix = p,
    );
    expect(prefix, 'C');
    expect(strategy.currentLetter(5, result.helper, mediaBrowserAlphaPrefix: 'C'), 'C');
  });

  test('only the newest load keeps its index', () async {
    final slow = Completer<SiloLetterIndex?>();
    var call = 0;
    final strategy = SiloAlphaBarStrategy(
      currentQuery: () => query,
      loadLetterIndex: (_) {
        call++;
        if (call == 1) return slow.future;
        return Future.value(
          SiloLetterIndex.fromJson({
            'total': 100,
            'letters': [
              for (final (i, l) in ['A', 'B', 'C', 'D', 'E', 'F'].indexed)
                {'letter': l, 'count': 10, 'position': i * 10},
            ],
          }),
        );
      },
    );
    final older = strategy.loadCharacters(filters: const {}, typeId: null, descending: false);
    final newer = await strategy.loadCharacters(filters: const {}, typeId: null, descending: false);
    slow.complete(_index());
    final stale = await older;
    expect(stale.chars, isEmpty);
    expect(newer.chars.map((c) => c.title), ['A', 'B', 'C', 'D', 'E', 'F']);
    expect(strategy.letterIndex!.total, 100);
  });

  test('a failed read rethrows and drops the index', () async {
    final strategy = SiloAlphaBarStrategy(currentQuery: () => query, loadLetterIndex: (_) async => _index());
    await strategy.loadCharacters(filters: const {}, typeId: null, descending: false);
    expect(strategy.letterIndex, isNotNull);
    final failing = SiloAlphaBarStrategy(
      currentQuery: () => query,
      loadLetterIndex: (_) async => throw StateError('offline'),
    );
    await expectLater(failing.loadCharacters(filters: const {}, typeId: null, descending: false), throwsStateError);
    expect(failing.letterIndex, isNull);
    expect(failing.filtersByPrefix, isFalse);
  });

  test('the factory picks the Silo strategy only with a letter index loader', () {
    final withLoader = LibraryAlphaBarStrategy.forBackend(
      MediaBackend.silo,
      plexClientProvider: () => throw UnimplementedError(),
      libraryKey: '3',
      isShared: false,
      siloQuery: () => const LibraryQuery(),
      siloLetterIndex: (_) async => null,
    );
    expect(withLoader, isA<SiloAlphaBarStrategy>());
    final without = LibraryAlphaBarStrategy.forBackend(
      MediaBackend.silo,
      plexClientProvider: () => throw UnimplementedError(),
      libraryKey: '3',
      isShared: false,
    );
    expect(without, isA<MediaBrowserAlphaBarStrategy>());
    final jellyfin = LibraryAlphaBarStrategy.forBackend(
      MediaBackend.jellyfin,
      plexClientProvider: () => throw UnimplementedError(),
      libraryKey: '3',
      isShared: false,
      siloQuery: () => const LibraryQuery(),
      siloLetterIndex: (_) async => null,
    );
    expect(jellyfin, isA<MediaBrowserAlphaBarStrategy>());
  });
}
