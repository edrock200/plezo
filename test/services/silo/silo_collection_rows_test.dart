import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_catalog_strings.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_collection_cards.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection() => SiloConnection(
  id: 'srv-1/1/p-owner',
  baseUrl: 'https://silo.example.com/base',
  serverName: 'Home Silo',
  serverId: 'srv-1',
  userId: '1',
  userName: 'laura',
  accessToken: 'acc-1',
  refreshToken: 'ref-1',
  deviceId: 'dev-1',
  profileId: 'p-owner',
  profileName: 'Laura',
  createdAt: DateTime(2026),
);

http.Response _json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

Map<String, dynamic> _movie(int i) => {'content_id': 'movie:m$i', 'type': 'movie', 'title': 'Movie $i'};

/// A row of collections as silo-server #4410 / #4415 send it: `items` empty,
/// the cards in `collections`, `total_count` their number.
Map<String, dynamic> _collectionRow({String id = 'picks', String? libraryId, int cards = 3}) => {
  'id': id,
  'section_type': 'collection_posters',
  'title': 'Our Picks',
  'featured': false,
  'item_limit': 20,
  'total_count': cards,
  'is_custom': true,
  'customized': false,
  'items': <Object>[],
  'collections': [
    {
      'id': 'c1',
      'source': 'library',
      'title': 'Heists',
      'poster_url': '/p/c1.jpg',
      'poster_thumbhash': 'abc',
      'poster_is_collage': false,
      'backdrop_url': 'https://cdn.example.com/b/c1.jpg?sig=1',
      'backdrop_thumbhash': 'def',
      'item_count': 12,
      'library_id': libraryId ?? '3',
    },
    {
      'id': 'u1',
      'source': 'user',
      'title': 'Date night',
      'poster_url': 'https://cdn.example.com/collage/u1.jpg',
      'poster_is_collage': true,
      'item_count': 4,
      'creator_profile_id': 'p-owner',
    },
    {
      'id': 'c2',
      'source': 'library',
      'title': 'Empty',
      'poster_url': '',
      'poster_is_collage': false,
      'item_count': 0,
      'library_id': libraryId ?? '3',
    },
    for (var i = 3; i < cards; i++)
      {
        'id': 'x$i',
        'source': 'library',
        'title': 'Extra $i',
        'poster_url': '',
        'poster_is_collage': false,
        'item_count': 1,
        'library_id': libraryId ?? '3',
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;

  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
    requests = [];
  });

  /// The profile's libraries: Movies (3), Shows (5) and an e-book library
  /// (7), which Plezilo does not show.
  Future<http.Response> libraries() async => _json({
    'items': [
      {'id': '3', 'name': 'Movies', 'type': 'movies'},
      {'id': '5', 'name': 'Shows', 'type': 'series'},
      {'id': '7', 'name': 'Books', 'type': 'ebooks'},
    ],
  });

  /// [handler] answers everything but the library list, which [librariesAnswer]
  /// (default [libraries]) answers.
  SiloClient client(
    Future<http.Response> Function(http.Request request) handler, {
    Future<http.Response> Function()? librariesAnswer,
  }) => SiloClient.forTesting(
    _connection(),
    headers: _headers,
    httpClient: MockClient((request) {
      requests.add(request);
      if (request.url.path.endsWith('/api/v2/user/libraries')) return (librariesAnswer ?? libraries)();
      return handler(request);
    }),
  );

  Future<http.Response> emptyPage() async => _json({
    'items': [_movie(1)],
    'page': {'has_more': false},
    'total': 1,
  });

  test('isCollectionRow reads section_type in any case', () {
    expect(SiloClient.isCollectionRow({'section_type': 'collection_posters'}), isTrue);
    expect(SiloClient.isCollectionRow({'section_type': 'Collection_Posters'}), isTrue);
    expect(SiloClient.isCollectionRow({'section_type': 'collection'}), isFalse);
    expect(SiloClient.isCollectionRow({}), isFalse);
  });

  group('a Home row of collections', () {
    test('shows one collection card per server card, in order, with no View All', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [
              _collectionRow(),
              {
                'id': 'ra',
                'section_type': 'recently_added',
                'title': 'Recently Added',
                'total_count': 40,
                'items': [_movie(2)],
              },
            ],
          });
        }
        return emptyPage();
      });

      final hubs = await c.fetchGlobalHubs();
      expect(hubs.map((h) => h.id), ['home:picks', 'home:ra']);
      final row = hubs.first;
      expect(row.title, 'Our Picks');
      expect(row.type, 'collection');
      expect(row.more, isFalse);
      expect(row.items.map((i) => i.id), ['silo-collection:~:c1', 'silo-user-collection:~:u1', 'silo-collection:~:c2']);
      expect(row.items.every((i) => i.kind == MediaKind.collection && i.backend == MediaBackend.silo), isTrue);

      final heists = row.items[0];
      expect(heists.title, 'Heists');
      expect(heists.leafCount, 12);
      expect(heists.childCount, 12);
      // Root-relative poster resolved against the server origin; presigned
      // backdrop kept exactly as sent.
      expect(heists.thumbPath, 'https://silo.example.com/p/c1.jpg');
      expect(heists.artPath, 'https://cdn.example.com/b/c1.jpg?sig=1');
      // Home cards belong to no one library; a server card names its own
      // for Plezilo's hidden-library setting, a personal one none.
      expect(heists.libraryId, isNull);
      expect(heists.raw?[MediaItem.sourceLibraryKey], '3');
      expect(heists.hidingLibraryGlobalKey, 'srv-1:3');
      expect(row.items[1].raw?.containsKey(MediaItem.sourceLibraryKey), isFalse);
      expect(row.items[1].hidingLibraryGlobalKey, isNull);

      final dateNight = row.items[1];
      expect(dateNight.thumbPath, 'https://cdn.example.com/collage/u1.jpg');
      expect(dateNight.artPath, isNull);

      final empty = row.items[2];
      expect(empty.thumbPath, isNull, reason: 'placeholder poster');
      expect(empty.leafCount, 0);

      // The row's cards come with the section: no items read for it.
      expect(requests.where((r) => r.url.path.contains('/home/sections/picks')), isEmpty);
    });

    test('shows every card the server sends, past the 20-card preview cap', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [_collectionRow(cards: 30)],
          });
        }
        return emptyPage();
      });
      final row = (await c.fetchGlobalHubs(limit: 20)).single;
      expect(row.items, hasLength(30));
      expect(row.size, 30);
      expect(row.more, isFalse);
    });

    test('stays when playback rows are left out, and a row without cards is dropped', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [
              _collectionRow(),
              {..._collectionRow(id: 'none'), 'collections': <Object>[], 'total_count': 0},
              {..._collectionRow(id: 'old'), 'collections': null},
            ],
          });
        }
        return emptyPage();
      });
      final hubs = await c.fetchGlobalHubs(includePlaybackHubs: false);
      expect(hubs.map((h) => h.id), ['home:picks']);
    });

    test('a card opens every member the viewer sees: no library_id', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [_collectionRow()],
          });
        }
        return emptyPage();
      });
      final row = (await c.fetchGlobalHubs()).single;

      requests.clear();
      final page = await c.fetchCollectionPage(row.items[0].id, libraryId: row.items[0].libraryId);
      expect(page.items.map((i) => i.id), ['movie:m1']);
      final q = requests.single.url.queryParameters;
      expect(q['source'], 'library_collection');
      expect(q['collection_id'], 'c1');
      expect(q.containsKey('library_id'), isFalse);

      requests.clear();
      await c.fetchCollectionPage(row.items[1].id);
      final personal = requests.single.url.queryParameters;
      expect(personal['source'], 'user_collection');
      expect(personal['collection_id'], 'u1');
      expect(personal.containsKey('library_id'), isFalse);

      // The card is known from its row; no library index is read for it.
      requests.clear();
      expect((await c.fetchItem(row.items[0].id))?.title, 'Heists');
      expect(requests, isEmpty);
    });
  });

  group('a library row of collections', () {
    test('opens that library\'s view, like the Collections tab', () async {
      final c = client((request) async {
        final path = Uri.decodeComponent(request.url.path);
        if (path.endsWith('/library/3/sections')) {
          return _json({
            'sections': [
              _collectionRow(libraryId: '3', cards: 25),
              {
                'id': 'ra',
                'section_type': 'recently_added',
                'title': 'Recently Added',
                'total_count': 1,
                'items': [_movie(2)],
              },
            ],
          });
        }
        return emptyPage();
      });

      final hubs = await c.fetchLibraryHubs('3', libraryName: 'Movies', includePlaybackHubs: false);
      expect(hubs.map((h) => h.id), ['library:3:picks', 'library:3:ra']);
      final row = hubs.first;
      expect(row.more, isFalse);
      expect(row.items, hasLength(25));
      expect(row.items.first.id, 'silo-collection:3:c1');
      expect(row.items[1].id, 'silo-user-collection:3:u1');
      expect(row.items.first.libraryId, '3');
      expect(row.items.first.libraryTitle, 'Movies');
      expect(requests.where((r) => r.url.path.contains('/sections/picks')), isEmpty);

      requests.clear();
      await c.fetchCollectionPage(row.items.first.id);
      final q = requests.single.url.queryParameters;
      expect(q['source'], 'library_collection');
      expect(q['library_id'], '3');

      requests.clear();
      await c.fetchCollectionPage(row.items[1].id);
      expect(requests.single.url.queryParameters['source'], 'user_collection');
      expect(requests.single.url.queryParameters['library_id'], '3');
    });
  });

  group('cards (Silo Android #979)', () {
    Future<List<MediaHub>> homeWith(List<Object?> cards, {List<Map<String, dynamic>> more = const []}) {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [
              {..._collectionRow(), 'collections': cards, 'total_count': cards.length},
              ...more,
            ],
          });
        }
        return emptyPage();
      });
      return c.fetchGlobalHubs();
    }

    Map<String, dynamic> good(String id, [Map<String, dynamic> extra = const {}]) => {
      'id': id,
      'source': 'library',
      'title': 'Title $id',
      'poster_url': '',
      'item_count': 2,
      'library_id': '3',
      ...extra,
    };

    test('a card with a wrongly typed field is left out; the row and Home keep the rest', () async {
      final hubs = await homeWith(
        [
          good('ok-1'),
          good('bad-count', {'item_count': '3'}),
          good('bad-fraction', {'item_count': 2.5}),
          good('bad-title', {'title': 42}),
          good('bad-poster', {'poster_url': false}),
          good('bad-backdrop', {'backdrop_url': 7}),
          good('bad-collage', {'poster_is_collage': 'yes'}),
          good('bad-library', {'library_id': true}),
          {...good('bad-creator'), 'source': 'user', 'creator_profile_id': <Object>[]},
          good('bad-id', {'id': <String, Object>{}}),
          'not a card',
          null,
          good('ok-2', {'item_count': 3.0}),
        ],
        more: [
          {
            'id': 'ra',
            'section_type': 'recently_added',
            'title': 'Recently Added',
            'total_count': 1,
            'items': [_movie(2)],
          },
        ],
      );
      expect(hubs.map((h) => h.id), ['home:picks', 'home:ra']);
      expect(hubs.first.items.map((i) => i.id), ['silo-collection:~:ok-1', 'silo-collection:~:ok-2']);
      expect(hubs.first.items.last.leafCount, 3);
    });

    test('an unknown source or a server collection without a library is left out', () async {
      final hubs = await homeWith([
        good('ok'),
        good('no-source', {'source': null}),
        good('other-source', {'source': 'smart'}),
        {...good('no-library')}..remove('library_id'),
        good('blank-library', {'library_id': ' '}),
        // A personal collection needs no library.
        {'id': 'mine', 'source': 'user', 'title': 'Mine', 'item_count': 1, 'creator_profile_id': 'p-owner'},
      ]);
      expect(hubs.single.items.map((i) => i.id), ['silo-collection:~:ok', 'silo-user-collection:~:mine']);
    });

    test('a row whose every card is unreadable is dropped, not Home', () async {
      final hubs = await homeWith(
        [
          good('bad', {'item_count': 'x'}),
        ],
        more: [
          {
            'id': 'ra',
            'section_type': 'recently_added',
            'title': 'Recently Added',
            'total_count': 1,
            'items': [_movie(2)],
          },
        ],
      );
      expect(hubs.map((h) => h.id), ['home:ra']);
    });
  });

  group('e-book and other hidden libraries', () {
    Map<String, dynamic> row() => {
      ..._collectionRow(),
      'collections': [
        {'id': 'm', 'source': 'library', 'title': 'Films', 'item_count': 2, 'library_id': '3'},
        {'id': 'b', 'source': 'library', 'title': 'Novels', 'item_count': 5, 'library_id': '7'},
        {'id': 'gone', 'source': 'library', 'title': 'Elsewhere', 'item_count': 5, 'library_id': '99'},
        {'id': 'u', 'source': 'user', 'title': 'Mine', 'item_count': 1, 'creator_profile_id': 'p-owner'},
      ],
    };

    test('Home never shows an e-book library\'s collection', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [row()],
          });
        }
        return emptyPage();
      });
      final items = (await c.fetchGlobalHubs()).single.items;
      expect(items.map((i) => i.id), ['silo-collection:~:m', 'silo-user-collection:~:u']);
    });

    test('the library list read for Home is the one the app already read', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [row()],
          });
        }
        return emptyPage();
      });
      await c.fetchLibraries();
      requests.clear();
      await c.fetchGlobalHubs();
      expect(requests.where((r) => r.url.path.endsWith('/user/libraries')), isEmpty);
    });

    test('without the library list, Home holds server collections back and keeps personal ones', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [row()],
          });
        }
        return emptyPage();
      }, librariesAnswer: () async => http.Response('down', 500));
      final items = (await c.fetchGlobalHubs()).single.items;
      expect(items.map((i) => i.id), ['silo-user-collection:~:u']);
    });

    test('a library page keeps its own row\'s cards', () async {
      final c = client((request) async {
        if (Uri.decodeComponent(request.url.path).endsWith('/library/3/sections')) {
          return _json({
            'sections': [row()],
          });
        }
        return emptyPage();
      });
      final items = (await c.fetchLibraryHubs('3', libraryName: 'Movies')).single.items;
      expect(items, hasLength(4));
      expect(requests.where((r) => r.url.path.endsWith('/user/libraries')), isEmpty);
    });
  });

  group('shared personal collections', () {
    Map<String, dynamic> row() => {
      ..._collectionRow(),
      'collections': [
        {'id': 'h', 'source': 'library', 'title': 'Heists', 'item_count': 12, 'library_id': '3'},
        {'id': 'own', 'source': 'user', 'title': 'Mine', 'item_count': 4, 'creator_profile_id': 'p-owner'},
        {'id': 'alex', 'source': 'user', 'title': 'Alex picks', 'item_count': 3, 'creator_profile_id': 'p-alex'},
        {'id': 'empty', 'source': 'user', 'title': 'Soon', 'item_count': 0, 'creator_profile_id': 'p-alex'},
        {'id': 'one', 'source': 'user', 'title': 'Single', 'item_count': 1, 'creator_profile_id': 'p-gone'},
      ],
    };

    Future<http.Response> profiles() async => _json({
      'items': [
        {'id': 'p-owner', 'name': 'Laura'},
        {'id': 'p-alex', 'name': 'Alex'},
      ],
    });

    tearDown(() => SiloCatalogStrings.debugSetTables());

    test('another profile\'s collection reads "by Name"; the viewer\'s own and the library\'s do not', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [row()],
          });
        }
        if (request.url.path.endsWith('/api/v2/profiles')) return profiles();
        return emptyPage();
      });
      final items = (await c.fetchGlobalHubs()).single.items;
      final captions = {for (final i in items) i.title: SiloCollectionCards.caption(i, tv: false)};
      expect(captions, {
        'Heists': '12 items',
        'Mine': '4 items',
        'Alex picks': '3 items · by Alex',
        // The row's count is exact: an empty collection says so.
        'Soon': '0 items · by Alex',
        // A maker this account has no name for shows the count alone.
        'Single': '1 item',
      });
      final tv = {for (final i in items) i.title: SiloCollectionCards.caption(i, tv: true)};
      expect(tv['Alex picks'], 'by Alex');
      expect(tv['Soon'], 'by Alex');
      expect(tv['Mine'], '4 items');
      expect(tv['Heists'], '12 items');

      // The account's profiles are read once, without profile headers.
      final read = requests.where((r) => r.url.path.endsWith('/api/v2/profiles')).toList();
      expect(read, hasLength(1));
      expect(read.single.headers.containsKey('X-Profile-Id'), isFalse);
      requests.clear();
      await c.fetchGlobalHubs();
      expect(requests.where((r) => r.url.path.endsWith('/api/v2/profiles')), isEmpty);
    });

    test('the byline uses Silo\'s catalog text in the app\'s language', () async {
      SiloCatalogStrings.debugSetTables(
        english: {'collections.posterCard.byOwner': 'by {owner}'},
        current: {'collections.posterCard.byOwner': 'von {owner}'},
      );
      expect(SiloCollectionCards.byOwner('Alex'), 'von Alex');
      SiloCatalogStrings.debugSetTables(english: {'collections.posterCard.byOwner': 'by {owner}'});
      expect(SiloCollectionCards.byOwner('Alex'), 'by Alex');
      SiloCatalogStrings.debugSetTables();
      expect(SiloCollectionCards.byOwner('Alex'), 'by Alex');
    });

    test('a failed profile read shows counts, never fails the row', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [row()],
          });
        }
        if (request.url.path.endsWith('/api/v2/profiles')) return http.Response('nope', 500);
        return emptyPage();
      });
      final items = (await c.fetchGlobalHubs()).single.items;
      expect(items, hasLength(5));
      expect(items.map((i) => SiloCollectionCards.caption(i, tv: true)), [
        '12 items',
        '4 items',
        '3 items',
        '0 items',
        '1 item',
      ]);
    });

    test('no profile read when every personal collection is the viewer\'s', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [_collectionRow()],
          });
        }
        return emptyPage();
      });
      await c.fetchGlobalHubs();
      expect(requests.where((r) => r.url.path.endsWith('/api/v2/profiles')), isEmpty);
    });

    test('a library row names the maker too, and Collections tab cards keep their caption', () async {
      final c = client((request) async {
        final path = Uri.decodeComponent(request.url.path);
        if (path.endsWith('/library/3/sections')) {
          return _json({
            'sections': [row()],
          });
        }
        if (path.endsWith('/api/v2/profiles')) return profiles();
        if (path.endsWith('/library/3/collections')) {
          return _json({
            'collections': [
              {'id': 'h', 'title': 'Heists', 'item_count': 0},
            ],
          });
        }
        return emptyPage();
      });
      final items = (await c.fetchLibraryHubs('3', libraryName: 'Movies')).single.items;
      expect(SiloCollectionCards.caption(items[2], tv: false), '3 items · by Alex');
      final tab = await c.fetchCollectionsPage('3');
      expect(SiloCollectionCards.caption(tab.items.single, tv: false), isNull);
    });
  });

  group('library pages', () {
    test('a featured row of collections stays and opens personal collections in that library', () async {
      final c = client((request) async {
        final path = Uri.decodeComponent(request.url.path);
        if (path.endsWith('/library/5/sections')) {
          return _json({
            'sections': [
              {..._collectionRow(libraryId: '5'), 'featured': true},
            ],
          });
        }
        return emptyPage();
      });
      final row = (await c.fetchLibraryHubs('5', libraryName: 'Shows', libraryKind: MediaKind.show)).single;
      expect(row.id, 'library:5:picks');
      expect(row.type, 'collection');
      final personal = row.items.firstWhere((i) => i.id.startsWith('silo-user-collection:'));
      expect(personal.id, 'silo-user-collection:5:u1');
      expect(personal.libraryId, '5');
      requests.clear();
      await c.fetchCollectionPage(personal.id);
      final q = requests.single.url.queryParameters;
      expect(q['source'], 'user_collection');
      expect(q['library_id'], '5');
    });
  });

  group('Home filters', () {
    late MultiServerManager manager;

    setUp(() {
      resetSharedPreferencesForTest();
      SettingsService.resetForTesting();
      manager = MultiServerManager();
    });

    tearDown(() => manager.dispose());

    /// Home: a row of collections (library 3's Heists and Empty, library 5's
    /// Westerns, the viewer's Date night) and a title row of library 3.
    SiloClient homeClient({List<Map<String, dynamic>>? collections}) {
      final row = _collectionRow();
      final cards =
          collections ??
          [
            ...(row['collections'] as List).cast<Map<String, dynamic>>(),
            {'id': 'w', 'source': 'library', 'title': 'Westerns', 'item_count': 2, 'library_id': '5'},
          ];
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) {
          return _json({
            'sections': [
              {...row, 'collections': cards, 'total_count': cards.length},
              {
                'id': 'ra',
                'section_type': 'recently_added',
                'title': 'Recently Added',
                'total_count': 1,
                'items': [
                  {..._movie(2), 'library_id': '3'},
                ],
              },
            ],
          });
        }
        return emptyPage();
      });
      manager.debugRegisterClientForTesting(c);
      return c;
    }

    test('a hidden library\'s server collections leave Home; personal ones and other libraries\' stay', () async {
      homeClient();
      final result = await DataAggregationService(
        manager,
      ).getHubsFromAllServers(hiddenLibraryKeys: {'srv-1:3'}, includePlaybackHubs: false);
      // The title row of the hidden library goes too.
      expect(result.hubs.map((h) => h.id), ['home:picks']);
      expect(result.hubs.single.items.map((i) => i.id), ['silo-user-collection:~:u1', 'silo-collection:~:w']);
      expect(result.hubs.single.size, 2);
    });

    test('with nothing hidden the row is whole', () async {
      homeClient();
      final result = await DataAggregationService(manager).getHubsFromAllServers(includePlaybackHubs: false);
      expect(result.hubs.map((h) => h.id), ['home:picks', 'home:ra']);
      expect(result.hubs.first.items, hasLength(4));
    });

    test('a row whose every card is in a hidden library goes', () async {
      homeClient(
        collections: [
          {'id': 'h', 'source': 'library', 'title': 'Heists', 'item_count': 2, 'library_id': '3'},
        ],
      );
      final result = await DataAggregationService(
        manager,
      ).getHubsFromAllServers(hiddenLibraryKeys: {'srv-1:3', 'srv-1:5'}, includePlaybackHubs: false);
      expect(result.hubs, isEmpty);
    });

    test('another server\'s hidden library with the same id changes nothing', () async {
      homeClient();
      final result = await DataAggregationService(
        manager,
      ).getHubsFromAllServers(hiddenLibraryKeys: {'other:3'}, includePlaybackHubs: false);
      expect(result.hubs.first.items, hasLength(4));
    });

    test('a library page\'s row is that library: its cards carry no other library', () async {
      final c = client((request) async {
        if (Uri.decodeComponent(request.url.path).endsWith('/library/5/sections')) {
          return _json({
            'sections': [_collectionRow(libraryId: '3')],
          });
        }
        return emptyPage();
      });
      final items = (await c.fetchLibraryHubs('5', libraryName: 'Shows')).single.items;
      expect(items.map((i) => i.hidingLibraryGlobalKey).toSet(), {'srv-1:5'});
      expect(items.any((i) => i.raw?.containsKey(MediaItem.sourceLibraryKey) ?? false), isFalse);
    });
  });
}
