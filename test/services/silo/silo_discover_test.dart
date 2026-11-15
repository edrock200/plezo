import 'dart:async';
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
import 'package:plezy/providers/discover_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
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
import 'package:plezy/utils/recommendation_hubs.dart';

import '../../test_helpers/media_items.dart';
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

/// A card as silo-server's `catalogItemOfSection` renders it (CatalogItem).
Map<String, dynamic> _card(String id, String type, String title, {int? year}) => {
  'content_id': id,
  'type': type,
  'title': title,
  'year': ?year,
  'genres': ['Crime', 'Thriller'],
  'keywords': <String>[],
  'status': 'matched',
  'overview': 'An overview.',
  'poster_url': '/api/v2/images/p/${Uri.encodeComponent(id)}?sig=abc',
  'poster_thumbhash': 'k0oGLQaSVsN0',
  'backdrop_url': '/api/v2/images/b/${Uri.encodeComponent(id)}?sig=abc',
  'is_favorite': false,
  'is_watchlisted': false,
};

/// `GET /api/v2/recommendations/discover` as silo-server's `getDiscover`
/// answers it: a `Collection[RecommendationRow]` (`items`, no `page`), each
/// row `{type, title, title_key?, title_args?, kind?, key?, items}`, For You
/// first as the server sends it.
Map<String, dynamic> _serverDiscover() => {
  'items': [
    {
      'type': 'cluster',
      'title': 'For You',
      'title_key': 'home.section.forYou',
      'kind': 'for-you-main',
      'items': [
        _card('movie:heat-1995', 'movie', 'Heat', year: 1995),
        _card('series:severance', 'series', 'Severance', year: 2022),
        _movie(3),
      ],
    },
    {
      'type': 'cluster',
      'title': 'Because you enjoy Crime & Thriller',
      'title_key': 'home.section.becauseYouEnjoy',
      'title_args': {'genres': 'Crime, Thriller'},
      'kind': 'cluster',
      'key': '0',
      'items': [_movie(4), _movie(5)],
    },
    {
      'type': 'similar_users_liked',
      'title': 'Profiles Like You Enjoyed',
      'title_key': 'home.section.profilesLikeYouEnjoyed',
      'kind': 'similar-users',
      'items': [_movie(6)],
    },
    {
      'type': 'popular',
      'title': 'Popular on This Server',
      'title_key': 'home.section.popularOnServer',
      'kind': 'popular',
      'items': [_movie(7), _movie(8)],
    },
    {
      'type': 'recently_added',
      'title': 'Recently Added',
      'title_key': 'home.section.recentlyAdded',
      'kind': 'recently-added',
      // The same cards as Home's Recently Added Movies.
      'items': [_movie(20), _movie(21)],
    },
    {
      'type': 'top_rated',
      'title': 'Highly Rated in Your Library',
      'title_key': 'home.section.highlyRatedInLibrary',
      'kind': 'top-rated',
      'items': <Object>[],
    },
    {
      'type': 'genre_sampler',
      'title': 'Top Drama',
      'title_key': 'home.section.topGenre',
      'title_args': {'genre': 'Drama'},
      'kind': 'genre',
      'key': 'Drama',
      'items': [_movie(9)],
    },
  ],
};

/// Silo's default Home: Recently Added Movies, and a "Recommended for You"
/// section of its own whose cards differ from Discover's For You row.
Map<String, dynamic> _homeSections() => {
  'sections': [
    {
      'id': 'default-recently-added-movies',
      'section_type': 'recently_added',
      'title': 'Recently Added Movies',
      'title_key': 'home.section.recentlyAddedMovies',
      'total_count': 3,
      'items': [_movie(20), _movie(21), _movie(22)],
    },
    {
      'id': 'default-recommended-for-you',
      'section_type': 'recommended_for_you',
      'title': 'Recommended for You',
      'title_key': 'home.section.recommendedForYou',
      'total_count': 2,
      'items': [_movie(30), _movie(31)],
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
        if (path.endsWith('/recommendations/discover')) return (discover ?? () => _json(_serverDiscover()))();
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
  });

  group('Home duplicates', () {
    MediaHub row(String title, List<int> cards, {bool recs = true, String serverId = 'srv-1'}) => MediaHub(
      id: '$title-$serverId',
      title: title,
      type: 'movie',
      items: [
        for (final i in cards)
          testMediaItem(id: 'movie:m$i', backend: MediaBackend.silo, kind: MediaKind.movie, serverId: serverId),
      ],
      serverId: serverId,
      personalRecommendations: recs,
    );

    test('a Home row with the same name or kind but other cards hides nothing', () {
      final recs = [
        row('For You', [1, 2, 3, 4]),
        row('Recently Added', [5, 6]),
      ];
      final result = withoutRecommendationsShownOnHome(recs, [
        // Silo's default Home "Recommended for You" section: its own picks.
        row('Recommended for You', [9, 10, 1], recs: false),
        row('Recently Added', [7, 20, 21], recs: false),
      ]);
      expect(result.kept.map((h) => h.title), ['For You', 'Recently Added']);
      expect(result.dropped, 0);
    });

    test('a row really on Home already is left out', () {
      final recs = [
        row('For You', [1, 2, 3, 4, 5]),
        row('Recently Added', [6, 7]),
        row('Popular on This Server', [8, 9]),
        row('Top Drama', [30]),
      ];
      final result = withoutRecommendationsShownOnHome(recs, [
        // Four in five cards in one Home row.
        row('Recommended for You', [1, 2, 3, 4, 99], recs: false),
        // Same title, half the cards.
        row('recently  added', [6, 50], recs: false),
        // Every card.
        row('Trending', [8, 9, 10], recs: false),
        // Another server's row with the same cards does not count.
        row('Drama', [30], recs: false, serverId: 'srv-2'),
      ]);
      expect(result.kept.map((h) => h.title), ['Top Drama']);
      expect(result.dropped, 3);
    });
  });

  group('SiloClient recommendations', () {
    test('a realistic answer becomes recommendation rows, read with the profile', () async {
      final c = server();
      final hubs = await c.fetchPersonalRecommendationHubs();
      expect(hubs!.map((h) => h.title), [
        'For You',
        'Because you enjoy Crime, Thriller',
        'Profiles Like You Enjoyed',
        'Popular on This Server',
        'Recently Added',
        'Top Drama',
      ]);
      final forYou = hubs.first;
      expect(forYou.personalRecommendations, isTrue);
      expect(forYou.more, isFalse);
      expect(forYou.id, forYou.identifier);
      expect(forYou.id, startsWith(SiloDiscover.hubIdPrefix));
      expect(forYou.serverId, 'srv-1');
      expect(forYou.libraryId, isNull);
      expect(forYou.items.map((i) => i.id), ['movie:heat-1995', 'series:severance', 'movie:m3']);
      expect(forYou.items.first.backend, MediaBackend.silo);
      expect(forYou.items.first.kind, MediaKind.movie);
      expect(forYou.items.first.title, 'Heat');
      expect(forYou.items.first.year, 1995);
      expect(forYou.items[1].kind, MediaKind.show);
      expect(forYou.type, 'mixed');

      final read = requests.singleWhere((r) => r.url.path.endsWith('/recommendations/discover'));
      expect(read.url.path, '/api/v2/recommendations/discover');
      expect(read.url.queryParameters['image_size'], 'medium');
      expect(read.headers['X-Profile-Id'], 'p-owner');
      expect(read.headers['Authorization'], 'Bearer acc-1');
    });

    test('Home rows no longer read or wait for the recommendations', () async {
      final c = server(discover: () => throw StateError('Home must not read Discover'));
      final hubs = await c.fetchGlobalHubs(includePlaybackHubs: false);
      expect(hubs.map((h) => h.title), ['Recently Added Movies', 'Recommended for You']);
      expect(hubs.any((h) => h.personalRecommendations), isFalse);
      expect(requests.where((r) => r.url.path.endsWith('/recommendations/discover')), isEmpty);
    });

    test('a server without the feed is a settled none and is not asked again', () async {
      final c = server(discover: () => http.Response('', 404));
      expect(await c.fetchPersonalRecommendationHubs(), isEmpty);
      expect(await c.fetchPersonalRecommendationHubs(), isEmpty);
      expect(requests.where((r) => r.url.path.endsWith('/recommendations/discover')), hasLength(1));
    });

    test('an empty feed is a settled none; a failure or an unreadable answer keeps what is shown', () async {
      expect(await server(discover: () => _json({'items': <Object>[]})).fetchPersonalRecommendationHubs(), isEmpty);
      for (final answer in [
        () => _json({'title': 'x'}, 503),
        () => _json({'title': 'x'}, 500),
        () => http.Response('<html>', 200, headers: {'content-type': 'text/html'}),
      ]) {
        expect(await server(discover: answer).fetchPersonalRecommendationHubs(), isNull);
      }
      // A failure is not remembered: the next read asks again.
      requests.clear();
      final c = server(discover: () => _json({'title': 'x'}, 500));
      await c.fetchPersonalRecommendationHubs();
      await c.fetchPersonalRecommendationHubs();
      expect(requests.where((r) => r.url.path.endsWith('/recommendations/discover')), hasLength(2));
    });

    test('a slow answer is waited for well past the old 8 s, then given up', () async {
      expect(SiloClient.discoverReadTimeout, greaterThanOrEqualTo(const Duration(seconds: 30)));
      final never = Completer<http.Response>();
      final c = client((request) {
        if (request.url.path.endsWith('/recommendations/discover')) return never.future;
        return Future.value(http.Response('', 404));
      })..recommendationsReadTimeout = const Duration(milliseconds: 50);
      expect(await c.fetchPersonalRecommendationHubs(), isNull);
    });

    test('library rows never carry recommendations', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/library/7/sections')) return _json(_homeSections());
        if (request.url.path.endsWith('/recommendations/discover')) return _json(_discover());
        return http.Response('', 404);
      });
      final hubs = await c.fetchLibraryHubs('7', libraryName: 'Movies');
      expect(hubs.map((h) => h.id), [
        'library:7:default-recently-added-movies',
        'library:7:default-recommended-for-you',
      ]);
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

    group('end to end', () {
      late MultiServerManager manager;
      late MultiServerProvider multiServer;
      late HiddenLibrariesProvider hidden;
      late LibrariesProvider libraries;
      late DiscoverProvider discover;

      Future<void> setUpHome(List<SiloClient> clients) async {
        resetSharedPreferencesForTest();
        SettingsService.resetForTesting();
        manager = MultiServerManager();
        for (final c in clients) {
          manager.debugRegisterClientForTesting(c);
        }
        multiServer = MultiServerProvider(manager, DataAggregationService(manager));
        hidden = HiddenLibrariesProvider();
        await hidden.ensureInitialized();
        libraries = LibrariesProvider();
        discover = DiscoverProvider(
          multiServer,
          hidden,
          libraries,
          profileId: 'profile-a',
          isProfileBinding: () => false,
        );
        addTearDown(() {
          discover.dispose();
          libraries.dispose();
          hidden.dispose();
          multiServer.dispose();
          manager.dispose();
        });
      }

      /// What Home draws: the phone/desktop list shows [DiscoverProvider.hubs]
      /// in order; the TV rail shows Continue Watching (empty here) and then
      /// the same hubs.
      List<String> homeRows() => [
        for (final hub in discover.hubs)
          if (hub.items.isNotEmpty) hub.title,
      ];

      test('a slow answer arriving after Home is shown adds its rows after the Home rows', () async {
        final answer = Completer<http.Response>();
        final c = client((request) {
          final path = request.url.path;
          if (path.endsWith('/recommendations/discover')) return answer.future;
          if (path.endsWith('/home/sections')) return Future.value(_json(_homeSections()));
          if (path.endsWith('/user/libraries')) return Future.value(_json({'items': <Object>[]}));
          return Future.value(http.Response('', 404));
        });
        await setUpHome([c]);
        var notifications = 0;
        discover.addListener(() => notifications++);

        await discover.load();
        // Home is shown without waiting for the recommendations.
        expect(discover.areHubsLoading, isFalse);
        expect(homeRows(), ['Recently Added Movies', 'Recommended for You']);
        final before = notifications;

        answer.complete(_json(_serverDiscover()));
        await discover.recommendationsSettled;
        expect(notifications, greaterThan(before));
        // Home's own "Recommended for You" holds other cards, so For You
        // stays; Discover's Recently Added is Home's Recently Added Movies.
        expect(homeRows(), [
          'Recently Added Movies',
          'Recommended for You',
          'For You',
          'Because you enjoy Crime, Thriller',
          'Profiles Like You Enjoyed',
          'Popular on This Server',
          'Top Drama',
        ]);
        final forYou = discover.hubs.firstWhere((h) => h.title == 'For You');
        expect(forYou.personalRecommendations, isTrue);
        expect(forYou.serverId, 'srv-1');
        expect(hubIconFor(forYou), Symbols.auto_awesome_rounded);
      });

      test('a refresh keeps the rows until the next answer; a failed read keeps them', () async {
        var calls = 0;
        Completer<http.Response>? pending;
        final c = client((request) {
          final path = request.url.path;
          if (path.endsWith('/recommendations/discover')) {
            calls++;
            if (calls == 1) return Future.value(_json(_serverDiscover()));
            return (pending = Completer<http.Response>()).future;
          }
          if (path.endsWith('/home/sections')) return Future.value(_json(_homeSections()));
          if (path.endsWith('/user/libraries')) return Future.value(_json({'items': <Object>[]}));
          return Future.value(http.Response('', 404));
        });
        await setUpHome([c]);
        await discover.load();
        await discover.recommendationsSettled;
        expect(homeRows(), contains('For You'));

        await discover.load();
        // The Home rows were replaced; the recommendations are still shown.
        expect(homeRows(), contains('For You'));
        pending!.complete(_json({'title': 'x'}, 503));
        await discover.recommendationsSettled;
        expect(homeRows(), contains('For You'));

        await discover.load();
        pending!.complete(
          _json({
            'items': [
              {
                'type': 'popular',
                'title': 'Popular on This Server',
                'kind': 'popular',
                'items': [_movie(40)],
              },
            ],
          }),
        );
        await discover.recommendationsSettled;
        expect(homeRows(), ['Recently Added Movies', 'Recommended for You', 'Popular on This Server']);
      });

      test('an older, slower answer never replaces a newer one', () async {
        final answers = <Completer<http.Response>>[];
        final c = client((request) {
          final path = request.url.path;
          if (path.endsWith('/recommendations/discover')) return (answers..add(Completer())).last.future;
          if (path.endsWith('/home/sections')) return Future.value(_json(_homeSections()));
          if (path.endsWith('/user/libraries')) return Future.value(_json({'items': <Object>[]}));
          return Future.value(http.Response('', 404));
        });
        await setUpHome([c]);
        await discover.load();
        await discover.load();
        expect(answers, hasLength(2));
        Map<String, dynamic> feed(String title) => {
          'items': [
            {
              'type': 'popular',
              'title': title,
              'kind': 'popular',
              'items': [_movie(41)],
            },
          ],
        };
        answers[1].complete(_json(feed('Newer')));
        await pumpEventQueue();
        answers[0].complete(_json(feed('Older')));
        await discover.recommendationsSettled;
        expect(homeRows().last, 'Newer');
        expect(homeRows(), isNot(contains('Older')));
      });

      test('recommendations show with the library layout too (Home layout off)', () async {
        final c = client((request) async {
          final path = request.url.path;
          if (path.endsWith('/recommendations/discover')) return _json(_serverDiscover());
          if (path.endsWith('/user/libraries')) return _json({'items': <Object>[]});
          return http.Response('', 404);
        });
        await setUpHome([c]);
        await (await SettingsService.getInstance()).write(SettingsService.useGlobalHubs, false);
        await discover.load();
        await discover.recommendationsSettled;
        expect(homeRows(), contains('For You'));
        expect(homeRows(), contains('Recently Added'));
      });

      test('two Silo servers each bring their own profile\'s recommendations', () async {
        final a = server(
          connection: _connection(serverId: 'srv-a', profileId: 'p-a'),
        );
        final b = server(
          connection: _connection(serverId: 'srv-b', profileId: 'p-b'),
          discover: () => http.Response('', 404),
        );
        await setUpHome([a, b]);
        await discover.load();
        await discover.recommendationsSettled;
        final recs = discover.hubs.where((h) => h.personalRecommendations).toList();
        expect(recs.map((h) => h.serverId).toSet(), {'srv-a'});
        expect(recs.first.title, 'For You');
        final discoverReads = requests.where((r) => r.url.path.endsWith('/recommendations/discover'));
        expect(discoverReads.map((r) => r.headers['X-Profile-Id']).toSet(), {'p-a', 'p-b'});
      });
    });
  });
}
