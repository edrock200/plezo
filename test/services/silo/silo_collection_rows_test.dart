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
import 'package:plezy/services/silo/silo_client.dart';

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
    {'id': 'c2', 'source': 'library', 'title': 'Empty', 'poster_url': '', 'poster_is_collage': false, 'item_count': 0},
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

  SiloClient client(Future<http.Response> Function(http.Request request) handler) => SiloClient.forTesting(
    _connection(),
    headers: _headers,
    httpClient: MockClient((request) {
      requests.add(request);
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
      // Home cards belong to no one library (hidden libraries never drop them).
      expect(heists.libraryId, isNull);

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
}
