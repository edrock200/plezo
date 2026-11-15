import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_discover.dart';
import 'package:plezy/services/silo/silo_section_titles.dart';
import 'package:plezy/utils/hub_icons.dart';
import 'package:plezy/utils/media_hub_ordering.dart';

import '../../test_helpers/prefs.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection({String serverId = 'srv-1', String profileId = 'p-owner'}) => SiloConnection(
  id: '$serverId/1/$profileId',
  baseUrl: 'https://silo.example.com',
  serverName: 'Home Silo',
  serverId: serverId,
  userId: '1',
  userName: 'laura',
  accessToken: 'acc-1',
  refreshToken: 'ref-1',
  deviceId: 'dev-1',
  profileId: profileId,
  profileName: 'Laura',
  createdAt: DateTime(2026),
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _movie(int i) => {'content_id': 'movie:m$i', 'type': 'movie', 'title': 'Movie $i'};

/// A Discover answer shaped like silo-server's `getDiscover` (and Siku's mock).
Map<String, dynamic> _discover() => {
  'items': [
    {
      'type': 'cluster',
      'kind': 'cluster',
      'key': '2',
      'title': 'Because You Watched Heat',
      'title_key': 'home.section.becauseYouWatchedTitle',
      'title_args': {'title': 'Heat'},
      'items': [_movie(10), _movie(11)],
    },
    {
      'type': 'popular',
      'kind': 'popular',
      'title': 'Popular on This Server',
      'title_key': 'home.section.popularOnServer',
      'items': [_movie(12)],
    },
    {
      'type': 'cluster',
      'kind': 'for-you-main',
      'title': 'For You',
      'title_key': 'home.section.forYou',
      'items': [_movie(13), _movie(14)],
    },
    {'type': 'top_rated', 'kind': 'top-rated', 'title': 'Top Rated', 'items': <Object>[]},
  ],
};

Map<String, dynamic> _homeSections() => {
  'sections': [
    {
      'id': 'ra-3',
      'section_type': 'recently_added',
      'title': 'Recently Added',
      'title_key': 'home.section.recentlyAddedIn',
      'title_args': {'library': 'Movies'},
      'total_count': 1,
      'items': [_movie(1)],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
    requests = [];
  });

  tearDown(() => db.close());

  SiloClient client(Future<http.Response> Function(http.Request request) handler, {SiloConnection? connection}) =>
      SiloClient.forTesting(
        connection ?? _connection(),
        headers: _headers,
        httpClient: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
      );

  /// A server answering Home with [home] and Discover with [discover].
  SiloClient server({http.Response Function()? discover, http.Response Function()? home, SiloConnection? connection}) =>
      client((request) async {
        final path = request.url.path;
        if (path.endsWith('/recommendations/discover')) return (discover ?? () => _json(_discover()))();
        if (path.endsWith('/home/sections')) return (home ?? () => _json(_homeSections()))();
        if (path.endsWith('/user/libraries')) return _json({'items': <Object>[]});
        // Capabilities, card overlay settings: a server without them.
        return http.Response('', 404);
      }, connection: connection);

  group('section titles', () {
    test('a known key is shown in the app language with its arguments', () {
      expect(
        SiloSectionTitles.localize(
          titleKey: 'home.section.becauseYouWatchedTitle',
          titleArgs: {'title': 'Heat'},
          fallback: 'x',
        ),
        'Because You Watched Heat',
      );
      expect(
        SiloSectionTitles.localize(titleKey: 'home.section.topGenre', titleArgs: {'genre': 'Drama'}, fallback: 'x'),
        'Top Drama',
      );
      expect(SiloSectionTitles.localize(titleKey: 'home.section.forYou', fallback: 'x'), 'For You');
    });

    test('an unknown key, a missing argument or no key shows the server title', () {
      expect(
        SiloSectionTitles.localize(titleKey: 'home.section.seasonal.winter.cozy', fallback: 'Cozy Winter'),
        'Cozy Winter',
      );
      expect(
        SiloSectionTitles.localize(titleKey: 'home.section.becauseYouWatchedTitle', fallback: 'Because you watched X'),
        'Because you watched X',
      );
      expect(SiloSectionTitles.localize(titleKey: 'error.notFound', fallback: 'Mine'), 'Mine');
      expect(SiloSectionTitles.of({'title': 'Picked by Laura'}), 'Picked by Laura');
    });
  });

  group('Discover rows', () {
    test('rows keep server order with For You first; empty rows and blank cards are dropped', () {
      final rows = SiloDiscover.rows({
        'items': [
          ..._discover()['items'] as List,
          {
            'type': 'genre_sampler',
            'kind': 'genre',
            'key': 'Drama',
            'title': 'Top Drama',
            'title_key': 'home.section.topGenre',
            'title_args': {'genre': 'Drama'},
            'items': [
              {'content_id': '', 'type': 'movie', 'title': 'Blank'},
              _movie(20),
            ],
          },
        ],
      });
      expect(rows.map((r) => r.title), ['For You', 'Because You Watched Heat', 'Popular on This Server', 'Top Drama']);
      expect(rows.first.isForYouMain, isTrue);
      expect(rows.last.items.map((c) => c['content_id']), ['movie:m20']);
    });

    test('ids come from kind and key, else from the cards; duplicates are dropped', () {
      final rows = SiloDiscover.rows({
        'items': [
          {
            'type': 'popular',
            'kind': 'popular',
            'title': 'Popular',
            'items': [_movie(1)],
          },
          {
            'type': 'popular',
            'kind': 'popular',
            'title': 'Popular again',
            'items': [_movie(2)],
          },
          {
            'type': 'cluster',
            'title': 'Because you enjoy Drama',
            'items': [_movie(3)],
          },
          {
            'type': 'cluster',
            'title': 'Because you enjoy Drama',
            'items': [_movie(4)],
          },
        ],
      });
      expect(rows, hasLength(3));
      expect(rows.first.id, 'silo-discover:7:popular0:');
      expect(rows[1].id, startsWith('silo-discover:legacy:'));
      expect(rows[1].id, isNot(rows[2].id));
      // A refreshed row with the same cards keeps its id.
      final again = SiloDiscover.rows({
        'items': [
          {
            'type': 'cluster',
            'title': 'Because you enjoy Drama',
            'items': [_movie(3)],
          },
        ],
      });
      expect(again.single.id, rows[1].id);
    });

    test('a malformed answer has no rows', () {
      expect(SiloDiscover.rows(null), isEmpty);
      expect(SiloDiscover.rows({'items': 'nope'}), isEmpty);
      expect(SiloDiscover.rows({'rows': []}), isEmpty);
    });

    test('rows Home already shows are left out', () {
      final rows = SiloDiscover.rows(_discover());
      final kept = SiloDiscover.withoutHomeDuplicates(rows, [
        // The same row by title key and arguments.
        {
          'id': 'byw',
          'section_type': 'because_you_watched',
          'title': 'Because you watched Heat',
          'title_key': 'home.section.becauseYouWatchedTitle',
          'title_args': {'title': 'Heat'},
          'items': <Object>[],
        },
        // Home's own For You section.
        {'id': 'rfy', 'section_type': 'recommended_for_you', 'title': 'Picked for Laura', 'items': <Object>[]},
      ]);
      expect(kept.map((r) => r.title), ['Popular on This Server']);

      expect(
        SiloDiscover.withoutHomeDuplicates(rows, [
          {'id': 'p', 'section_type': 'popular', 'title': 'popular on this  server'},
        ]).map((r) => r.title),
        ['For You', 'Because You Watched Heat'],
      );
      // Every card already in one Home row.
      expect(
        SiloDiscover.withoutHomeDuplicates(rows, [
          {
            'id': 'x',
            'section_type': 'custom',
            'title': 'Laura picks',
            'items': [_movie(13), _movie(14), _movie(15)],
          },
        ]).map((r) => r.title),
        ['Because You Watched Heat', 'Popular on This Server'],
      );
    });
  });

  group('SiloClient Home', () {
    test('recommendation rows follow the Home rows, read with the profile', () async {
      final c = server();
      final hubs = await c.fetchGlobalHubs();
      expect(hubs.map((h) => h.title), [
        'Recently Added in Movies',
        'For You',
        'Because You Watched Heat',
        'Popular on This Server',
      ]);
      expect(hubs.first.personalRecommendations, isFalse);
      final forYou = hubs[1];
      expect(forYou.personalRecommendations, isTrue);
      expect(forYou.more, isFalse);
      expect(forYou.id, forYou.identifier);
      expect(forYou.id, startsWith(SiloDiscover.hubIdPrefix));
      expect(forYou.serverId, 'srv-1');
      expect(forYou.items.map((i) => i.id), ['movie:m13', 'movie:m14']);
      expect(forYou.items.first.backend, MediaBackend.silo);
      expect(forYou.items.first.kind, MediaKind.movie);

      final read = requests.singleWhere((r) => r.url.path.endsWith('/recommendations/discover'));
      expect(read.url.path, '/api/v2/recommendations/discover');
      expect(read.url.queryParameters['image_size'], 'medium');
      expect(read.headers['X-Profile-Id'], 'p-owner');
      expect(read.headers['Authorization'], 'Bearer acc-1');
    });

    test('each refresh reads the recommendations again', () async {
      final c = server();
      await c.fetchGlobalHubs();
      await c.fetchGlobalHubs(includePlaybackHubs: false);
      expect(requests.where((r) => r.url.path.endsWith('/recommendations/discover')), hasLength(2));
    });

    test('a server without the feed shows Home only and is not asked again', () async {
      final c = server(discover: () => http.Response('', 404));
      expect((await c.fetchGlobalHubs()).map((h) => h.id), ['home:ra-3']);
      expect((await c.fetchGlobalHubs()).map((h) => h.id), ['home:ra-3']);
      expect(requests.where((r) => r.url.path.endsWith('/recommendations/discover')), hasLength(1));
    });

    test('an empty feed, a failure or a malformed answer shows no rows and keeps Home', () async {
      for (final answer in [
        () => _json({'items': <Object>[]}),
        () => _json({'title': 'x'}, 503),
        () => _json({'title': 'x'}, 500),
        () => http.Response('<html>', 200, headers: {'content-type': 'text/html'}),
      ]) {
        final c = server(discover: answer);
        final hubs = await c.fetchGlobalHubs();
        expect(hubs.map((h) => h.id), ['home:ra-3']);
        expect(hubs.any((h) => h.personalRecommendations), isFalse);
      }
      // A failure is not remembered: the next Home load asks again.
      requests.clear();
      final c = server(discover: () => _json({'title': 'x'}, 500));
      await c.fetchGlobalHubs();
      await c.fetchGlobalHubs();
      expect(requests.where((r) => r.url.path.endsWith('/recommendations/discover')), hasLength(2));
    });

    test('a failed Home load fails as before, recommendations or not', () async {
      final c = server(home: () => _json({'title': 'x'}, 500));
      expect(await c.fetchGlobalHubs(), isEmpty);
    });

    test('library rows never carry recommendations', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/library/7/sections')) return _json(_homeSections());
        if (request.url.path.endsWith('/recommendations/discover')) return _json(_discover());
        return http.Response('', 404);
      });
      final hubs = await c.fetchLibraryHubs('7', libraryName: 'Movies');
      expect(hubs.single.id, 'library:7:ra-3');
      expect(requests.where((r) => r.url.path.endsWith('/recommendations/discover')), isEmpty);
    });
  });

  group('Home wiring', () {
    test('recommendations keep their order after the library rows and show the sparkle', () {
      MediaHub hub(String id, {String? libraryId, bool recs = false}) => MediaHub(
        id: id,
        title: id == 'byw' ? 'Because You Watched Heat' : id,
        type: 'movie',
        items: const [],
        libraryId: libraryId,
        serverId: 'srv-1',
        personalRecommendations: recs,
      );
      final hubs = [hub('for-you', recs: true), hub('byw', recs: true), hub('movies', libraryId: 'm')];
      const library = MediaLibrary(
        id: 'm',
        backend: MediaBackend.silo,
        title: 'Movies',
        kind: MediaKind.movie,
        serverId: 'srv-1',
      );
      sortMediaHubsByLibraryOrder(hubs, const [library]);
      expect(hubs.map((h) => h.id), ['movies', 'for-you', 'byw']);
      expect(hubIconFor(hubs[2]), Symbols.auto_awesome_rounded);
      expect(hubs[2].copyWith(items: const []).personalRecommendations, isTrue);
    });

    test('two Silo servers each bring their own profile\'s recommendations to Home', () async {
      resetSharedPreferencesForTest();
      SettingsService.resetForTesting();
      final manager = MultiServerManager();
      addTearDown(manager.dispose);
      final a = server(
        connection: _connection(serverId: 'srv-a', profileId: 'p-a'),
      );
      final b = server(
        connection: _connection(serverId: 'srv-b', profileId: 'p-b'),
        discover: () => http.Response('', 404),
      );
      manager.debugRegisterClientForTesting(a);
      manager.debugRegisterClientForTesting(b);

      final result = await DataAggregationService(
        manager,
      ).getHubsFromAllServers(useGlobalHubs: true, includePlaybackHubs: false);
      expect(result.succeededServerIds, {'srv-a', 'srv-b'});
      final recs = result.hubs.where((h) => h.personalRecommendations).toList();
      expect(recs.map((h) => h.serverId).toSet(), {'srv-a'});
      expect(recs.map((h) => h.title), ['For You', 'Because You Watched Heat', 'Popular on This Server']);
      final discoverReads = requests.where((r) => r.url.path.endsWith('/recommendations/discover'));
      expect(discoverReads.map((r) => r.headers['X-Profile-Id']).toSet(), {'p-a', 'p-b'});
    });
  });
}
