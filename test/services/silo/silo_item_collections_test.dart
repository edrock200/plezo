import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_catalog_strings.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_collection_cards.dart';

/// The collections a movie or series page lists (Silo Android #1007,
/// silo-server #4528 `listCatalogItemCollections`). Bodies follow the
/// commit's fixtures `list_catalog_item_collections_ok.json` and
/// `list_catalog_item_collections_single_preview.json`.

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

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _serverCard({String id = '01J9Z8C3W4R5T6Y7U8I9O0P1Q2', String libraryId = '1'}) => {
  'id': id,
  'source': 'library',
  'title': 'Crime classics',
  'poster_url': '/api/v2/images/collections/$id/poster',
  'poster_is_collage': false,
  'item_count': 24,
  'library_id': libraryId,
};

Map<String, dynamic> get _userCard => {
  'id': 'c1',
  'source': 'user',
  'title': 'Favorites',
  'poster_url': '/api/v2/images/user-collections/c1/collage',
  'poster_is_collage': true,
  'item_count': 7,
  'creator_profile_id': 'p-owner',
};

Map<String, dynamic> _title(String id, String title) => {
  'content_id': id,
  'type': 'movie',
  'title': title,
  'year': 2019,
  'genres': <Object>[],
  'keywords': <Object>[],
  'status': '',
  'poster_url': '/api/v2/images/items/$id/poster',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;
  late Map<String, dynamic> capabilities;
  late Object? Function(String id) collectionsAnswer;

  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
    requests = [];
    capabilities = {'state': 'available', 'allowed': true, 'item_collections': true};
    collectionsAnswer = (_) => {'items': <Object>[], 'preview_items': <Object>[]};
    SiloCatalogStrings.debugSetTables();
  });

  tearDown(SiloCatalogStrings.debugSetTables);

  SiloClient client() => SiloClient.forTesting(
    _connection(),
    headers: _headers,
    httpClient: MockClient((request) async {
      requests.add(request);
      final path = Uri.decodeComponent(request.url.path);
      if (path.endsWith('/api/v2/user/libraries')) {
        return _json({
          'items': [
            {'id': '1', 'name': 'Movies', 'type': 'movies'},
            {'id': '5', 'name': 'Shows', 'type': 'series'},
            {'id': '7', 'name': 'Books', 'type': 'ebooks'},
          ],
        });
      }
      if (path.endsWith('/catalog/search/capabilities')) return _json(capabilities);
      final collections = RegExp(r'/catalog/items/([^/]+)/collections$').firstMatch(path);
      if (collections != null) {
        final answer = collectionsAnswer(collections.group(1)!);
        return answer is http.Response ? answer : _json(answer!);
      }
      if (path.endsWith('/catalog/items/movie:harbor-lights-2019')) {
        return _json({
          'content_id': 'movie:harbor-lights-2019',
          'type': 'movie',
          'title': 'Harbor Lights',
          'library_id': 1,
        });
      }
      if (path.endsWith('/catalog/items/movie:night-ferry-2021')) {
        return _json({
          'content_id': 'movie:night-ferry-2021',
          'type': 'movie',
          'title': 'Night Ferry',
          'library_id': 1,
        });
      }
      if (path.endsWith('/catalog/items/series:s1')) {
        return _json({'content_id': 'series:s1', 'type': 'series', 'title': 'Show', 'library_id': 5});
      }
      if (path.endsWith('/catalog/items/episode:e1')) {
        return _json({'content_id': 'episode:e1', 'type': 'episode', 'title': 'Pilot', 'library_id': 5});
      }
      return _json({'items': <Object>[]});
    }),
  );

  Iterable<http.Request> collectionReads() => requests.where((r) => r.url.path.endsWith('/collections'));

  test('several collections: an "Also in" row of their cards, between the box set and More Like This', () async {
    collectionsAnswer = (_) => {
      'items': [_serverCard(), _userCard],
      'preview_items': <Object>[],
    };
    final c = client();
    final hubs = await c.fetchRelatedHubs('movie:harbor-lights-2019');
    final hub = hubs.singleWhere((h) => h.identifier == 'item_collections');
    expect(hub.title, 'Also in');
    expect(hub.items.map((i) => i.title), ['Crime classics', 'Favorites']);
    expect(hub.items.every((i) => i.kind == MediaKind.collection), isTrue);
    expect(hub.more, isFalse);
    // The read names the page's library, and nothing the route does not know.
    expect(collectionReads().single.url.queryParameters, {'library_id': '1'});
    // The cards carry their exact count, as a row of collections does.
    expect(SiloCollectionCards.caption(hub.items.first, tv: false), isNotNull);
  });

  test('one collection with other titles: its titles (at most six, not this one), then its card', () async {
    collectionsAnswer = (_) => {
      'items': [_serverCard()],
      'preview_items': [
        _title('movie:night-ferry-2021', 'Night Ferry'),
        for (var i = 0; i < 8; i++) _title('movie:m$i', 'Movie $i'),
      ],
    };
    final hubs = await client().fetchRelatedHubs('movie:night-ferry-2021');
    final hub = hubs.singleWhere((h) => h.identifier == 'item_collection_preview');
    expect(hub.title, 'Crime classics');
    expect(hub.items.map((i) => i.title), [for (var i = 0; i < 6; i++) 'Movie $i', 'Crime classics']);
    expect(hub.items.last.kind, MediaKind.collection);
    expect(hubs.where((h) => h.identifier == 'item_collections'), isEmpty);
  });

  test('the fixture with a single preview title shows it before the card', () async {
    collectionsAnswer = (_) => {
      'items': [_serverCard()],
      'preview_items': [_title('movie:harbor-lights-2019', 'Harbor Lights')],
    };
    final hubs = await client().fetchRelatedHubs('movie:night-ferry-2021');
    final hub = hubs.singleWhere((h) => h.identifier == 'item_collection_preview');
    expect(hub.items.map((i) => i.id), ['movie:harbor-lights-2019', isA<String>()]);
    expect(hub.items.first, isA<SiloMediaItem>());
  });

  test('one collection without other titles shows its card under "Also in"', () async {
    collectionsAnswer = (_) => {
      'items': [_userCard],
      'preview_items': <Object>[],
    };
    final hubs = await client().fetchRelatedHubs('movie:harbor-lights-2019');
    expect(hubs.singleWhere((h) => h.identifier == 'item_collections').items.single.title, 'Favorites');
  });

  test('a server without item_collections is never asked', () async {
    capabilities = {'state': 'available', 'allowed': true};
    final hubs = await client().fetchRelatedHubs('movie:harbor-lights-2019');
    expect(hubs.where((h) => h.identifier?.startsWith('item_collection') ?? false), isEmpty);
    expect(collectionReads(), isEmpty);
  });

  test('series ask too; episodes do not', () async {
    collectionsAnswer = (_) => {
      'items': [_userCard],
      'preview_items': <Object>[],
    };
    final c = client();
    expect((await c.fetchRelatedHubs('series:s1')).map((h) => h.identifier), contains('item_collections'));
    await c.fetchRelatedHubs('episode:e1');
    expect(collectionReads().map((r) => Uri.decodeComponent(r.url.path)), [endsWith('series:s1/collections')]);
  });

  test('the capability is read once for several pages', () async {
    final c = client();
    await c.fetchRelatedHubs('movie:harbor-lights-2019');
    await c.fetchRelatedHubs('movie:night-ferry-2021');
    expect(requests.where((r) => r.url.path.endsWith('/search/capabilities')), hasLength(1));
  });

  test('no collection, or only one of a library Plezilo does not list, shows no row', () async {
    final c = client();
    expect(
      (await c.fetchRelatedHubs('movie:harbor-lights-2019')).map((h) => h.identifier),
      isNot(contains('item_collections')),
    );
    collectionsAnswer = (_) => {
      'items': [_serverCard(libraryId: '7')],
      'preview_items': [_title('movie:m1', 'Movie 1')],
    };
    final hubs = await c.fetchRelatedHubs('movie:night-ferry-2021');
    expect(hubs.where((h) => h.identifier?.startsWith('item_collection') ?? false), isEmpty);
  });

  test('a card that does not decode is left out, never the row', () async {
    collectionsAnswer = (_) => {
      'items': [
        _serverCard(),
        {'id': 'bad', 'source': 'library', 'title': 7, 'library_id': '1'},
        _userCard,
      ],
      'preview_items': <Object>[],
    };
    final hubs = await client().fetchRelatedHubs('movie:harbor-lights-2019');
    expect(hubs.singleWhere((h) => h.identifier == 'item_collections').items, hasLength(2));
  });

  test('a failed first read shows nothing; a failed refresh keeps the row', () async {
    collectionsAnswer = (_) => _json({'title': 'boom'}, 500);
    final c = client();
    expect(
      (await c.fetchRelatedHubs('movie:harbor-lights-2019')).map((h) => h.identifier),
      isNot(contains('item_collections')),
    );
    collectionsAnswer = (_) => {
      'items': [_serverCard(), _userCard],
      'preview_items': <Object>[],
    };
    expect(
      (await c.fetchRelatedHubs('movie:harbor-lights-2019')).map((h) => h.identifier),
      contains('item_collections'),
    );
    collectionsAnswer = (_) => _json({'title': 'boom'}, 500);
    final kept = await c.fetchRelatedHubs('movie:harbor-lights-2019');
    expect(kept.singleWhere((h) => h.identifier == 'item_collections').items, hasLength(2));
  });

  test('the heading comes from Silo\'s catalog in the app\'s language, else Plezilo\'s English', () {
    expect(SiloCollectionCards.alsoInTitle, 'Also in');
    SiloCatalogStrings.debugSetTables(
      english: {'detail.alsoIn': 'Also in'},
      current: {'detail.alsoIn': 'Auch enthalten in'},
    );
    expect(SiloCollectionCards.alsoInTitle, 'Auch enthalten in');
  });
}
