import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/download_resolution.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_filter.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/playback_report_metadata.dart';
import 'package:plezy/services/cached_playback_metadata_service.dart';
import 'package:plezy/services/jellyfin_trickplay_service.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_memberships.dart';
import 'package:plezy/services/tofa/tofa_api.dart';
import 'package:plezy/services/tofa/tofa_api_cache.dart';
import 'package:plezy/services/tofa/tofa_client.dart';
import 'package:plezy/services/tofa/tofa_downloads.dart';
import 'package:plezy/services/tofa/tofa_endpoints.dart';
import 'package:plezy/services/tofa/tofa_library_options.dart';
import 'package:plezy/utils/external_ids.dart';

import 'tofa_fixtures.dart';

Map<String, dynamic> _facets({
  List<String> sorts = const ['title', 'added_at', 'release_date', 'rating'],
  String defaultSort = 'title',
  String defaultOrder = 'asc',
}) => {
  'sorts': sorts,
  'default_sort': defaultSort,
  'default_order': defaultOrder,
  'genres': [
    {'value': 'Drama', 'count': 3},
    {'value': 'Comedy', 'count': 1},
  ],
  'quality': [
    {'value': '4k', 'count': 2},
  ],
  'letters': [
    {'value': 'A', 'count': 2},
    {'value': '#', 'count': 1},
  ],
  'watched': {'watched': 1, 'in_progress': 1, 'unwatched': 2},
  'years': {'min': 1990, 'max': 2024},
};

Map<String, dynamic> _page(List<Map<String, dynamic>> items) => {
  'items': items,
  'page': 1,
  'per_page': 50,
  'total': items.length,
  'total_pages': 1,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTofa fake;
  late AppDatabase db;

  setUp(() {
    fake = FakeTofa();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    TofaApiCache.initialize(db);
  });
  tearDown(() => db.close());

  TofaClient client() => TofaClient.forTesting(
    tofaConnection(),
    headers: const TofaClientHeaders(
      clientVersion: '1.0',
      platform: 'android',
      deviceName: 'Test device',
      deviceId: 'dev-1',
    ),
    httpClient: fake.client,
  )..raceWait = (_) async {};

  // ---------------------------------------------------------------------------
  group('sorting and filters', () {
    test('sorts are the ones the facets list, with descending variants when order is asc/desc', () async {
      fake.on('GET', '/api/v1/media/facets', (r) {
        expect(r.url.queryParameters['library_id'], 'lib-1');
        return jsonResponse(_facets(sorts: ['title', 'added_at', 'tofa_score']));
      });
      final sorts = await client().fetchSortOptions('lib-1');
      expect(sorts.map((s) => s.key), ['title', 'added_at', 'tofa_score']);
      expect(sorts.map((s) => s.title), ['Title', 'Date Added', 'Tofa score']);
      expect(sorts.first.descKey, 'title:desc');
      expect(sorts.first.defaultDirection, 'asc');
    });

    test('without asc/desc in the facets, no order is offered or sent', () {
      final facets = TofaFacets.fromJson(_facets(defaultOrder: 'ascending'))!;
      expect(TofaLibraryOptions.sorts(facets).first.descKey, isNull);
      final params = TofaLibraryOptions.queryParams(const LibraryQuery(sort: LibrarySort(field: 'title:desc')), facets);
      expect(params, {'sort': 'title'});
    });

    test('filters: genre, watch status, quality, year and available only', () async {
      fake.on('GET', '/api/v1/media/facets', (_) => jsonResponse(_facets()));
      final result = await client().fetchLibraryFiltersWithValues('lib-1');
      expect(result.filters.map((f) => f.filter), [
        TofaFilterField.genre,
        TofaFilterField.watched,
        TofaFilterField.quality,
        TofaFilterField.year,
        TofaFilterField.availableOnly,
      ]);
      expect(result.cachedValues[TofaFilterField.genre]!.map((v) => v.key), ['Drama', 'Comedy']);
      expect(result.cachedValues[TofaFilterField.watched]!.map((v) => v.key), ['unwatched', 'in_progress', 'watched']);
      expect(
        result.filters.firstWhere((f) => f.filter == TofaFilterField.availableOnly).filterType,
        MediaFilterType.boolean,
      );
    });

    test('the query sends listed values only', () async {
      fake.on('GET', '/api/v1/media/facets', (_) => jsonResponse(_facets()));
      fake.on('GET', '/api/v1/media', (_) => jsonResponse(_page([mediaSummary('m-1')])));
      await client().fetchLibraryPagedContent(
        'lib-1',
        query: const LibraryQuery(
          sort: LibrarySort(field: 'added_at:desc'),
          nameStartsWith: '#',
          filters: [
            LibraryFilter(field: TofaFilterField.genre, values: ['Drama']),
            LibraryFilter(field: TofaFilterField.watched, values: ['in_progress']),
            LibraryFilter(field: TofaFilterField.quality, values: ['8k']),
            LibraryFilter(field: TofaFilterField.year, op: LibraryFilterOperator.atLeast, values: ['2000']),
            LibraryFilter(field: TofaFilterField.availableOnly, values: ['1']),
          ],
        ),
      );
      final q = fake.to('GET', '/api/v1/media').single.url.queryParameters;
      expect(q['sort'], 'added_at');
      expect(q['order'], 'desc');
      expect(q['letter'], '#', reason: 'listed in the facets');
      expect(q['genre'], 'Drama');
      expect(q['watched'], 'in_progress');
      expect(q.containsKey('quality'), isFalse, reason: '8k is not a listed quality');
      expect(q['year_from'], '2000');
      expect(q['available_only'], 'true');
    });

    test('an unlisted sort is not sent', () {
      final facets = TofaFacets.fromJson(_facets())!;
      expect(
        TofaLibraryOptions.queryParams(const LibraryQuery(sort: LibrarySort(field: 'popularity')), facets),
        isEmpty,
      );
    });

    test('genres come from /media/genres, sorted', () async {
      fake.on('GET', '/api/v1/media/genres', (r) {
        expect(r.url.queryParameters['library_id'], 'lib-1');
        return jsonResponse(['Thriller', 'action', 'Drama']);
      });
      final genres = await client().fetchLibraryGenres('lib-1', libraryKind: MediaKind.movie);
      expect(genres.map((g) => g.title), ['action', 'Drama', 'Thriller']);
      expect(genres.first.filterValue, 'action');
    });
  });

  // ---------------------------------------------------------------------------
  group('Home rows', () {
    void serveHome({bool dateSort = true}) {
      fake.on(
        'GET',
        '/api/v1/media/facets',
        (_) => jsonResponse(_facets(sorts: dateSort ? ['title', 'added_at'] : ['title'])),
      );
      fake.on('GET', '/api/v1/media', (r) {
        expect(r.url.queryParameters['sort'], 'added_at');
        expect(r.url.queryParameters['order'], 'desc');
        return jsonResponse(_page([mediaSummary('m-new')]));
      });
      fake.on(
        'GET',
        '/api/v1/users/me/suggested',
        (_) => jsonResponse({
          'items': [mediaSummary('m-sug')],
          'personalized': true,
          'requestable': <Object>[],
          'seeds': <Object>[],
        }),
      );
      fake.on(
        'GET',
        '/api/v1/media/binge-ready',
        (_) => jsonResponse({
          'items': [
            {
              'media': mediaSummary('show-1', type: 'tv'),
              'season_id': 'sea-1',
              'season_number': 1,
              'season_title': 'Season 1',
              'season_poster_path': null,
              'episode_count': 8,
              'last_air_date': '2026-11-01',
              'ready_at': null,
            },
          ],
        }),
      );
      fake.on(
        'GET',
        '/api/v1/users/me/watchlist',
        (_) => jsonResponse([
          {
            'media_id': 'm-wl',
            'owned': true,
            'title': 'On my list',
            'media_type': 'movie',
            'genres': <String>[],
            'added_at': '',
          },
          {'media_id': null, 'owned': false, 'title': 'Not here', 'tmdb_id': 9, 'genres': <String>[], 'added_at': ''},
        ]),
      );
      fake.on(
        'GET',
        '/api/v1/collections/home-rows',
        (_) => jsonResponse({
          'rows': [
            {
              'id': 'row-1',
              'kind': 'pinned_collection',
              'enabled': true,
              'after': null,
              'collection_id': 'col-1',
              'name': 'Heist films',
              'items': [mediaSummary('m-col')],
            },
            {'id': 'row-2', 'kind': 'finish_sets', 'enabled': true, 'after': null, 'sets': <Object>[]},
          ],
        }),
      );
    }

    test('every documented row, read together', () async {
      serveHome();
      final hubs = await client().fetchGlobalHubs();
      expect(hubs.map((h) => h.title), [
        'Recently Added',
        'Suggested for You',
        'Ready to Binge',
        'Watchlist',
        'Heist films',
      ]);
      expect(hubs[0].items.single.id, 'm-new');
      expect(hubs[2].items.single.id, 'tofa-season:show-1/sea-1');
      expect(hubs[2].items.single.kind, MediaKind.season);
      expect(hubs[3].items.single.id, 'm-wl', reason: 'titles not in the library are left out');
      expect(hubs.any((h) => h.isContinueWatchingHub), isFalse);
    });

    test('no Recently Added row without a listed date-added sort; a failed row is recorded, not fatal', () async {
      serveHome(dateSort: false);
      fake.on('GET', '/api/v1/users/me/suggested', (_) => tofaError(500, 'boom'));
      final diagnostics = HubFetchDiagnostics();
      final hubs = await client().fetchGlobalHubs(diagnostics: diagnostics);
      expect(hubs.map((h) => h.title), ['Ready to Binge', 'Watchlist', 'Heist films']);
      expect(diagnostics.failed, isTrue);
      expect(fake.to('GET', '/api/v1/media'), isEmpty);
    });

    test('Home gives each Browse section its own Recently Added row', () async {
      serveHome();
      fake.on(
        'GET',
        '/api/v1/browse/sections',
        (_) => jsonResponse({
          'sections': [
            {
              'key': 'lib-1',
              'kind': 'library',
              'library_id': 'lib-1',
              'media_type': 'movie',
              'name': 'Movies',
              'total': 3,
              'libraries': [
                {'id': 'lib-1', 'name': 'Movies'},
              ],
            },
            {
              'key': 'tv',
              'kind': 'type',
              'library_id': null,
              'media_type': 'tv',
              'name': 'TV Shows',
              'total': 2,
              'libraries': <Object>[],
            },
            {
              'key': 'empty',
              'kind': 'library',
              'library_id': 'lib-9',
              'media_type': 'movie',
              'name': 'Empty',
              'total': 0,
              'libraries': <Object>[],
            },
          ],
        }),
      );
      final hubs = await client().fetchGlobalHubs();
      expect(hubs.take(2).map((h) => h.title), ['Recently Added in Movies', 'Recently Added in TV Shows']);
      final queries = [for (final r in fake.to('GET', '/api/v1/media')) r.url.queryParameters];
      expect(queries.any((q) => q['library_id'] == 'lib-1'), isTrue);
      expect(queries.any((q) => q['media_type'] == 'tv' && q['library_id'] == null), isTrue);
      expect(queries.any((q) => q['library_id'] == 'lib-9'), isFalse, reason: 'an empty section gets no row');
    });

    test('a library Recommended tab gets every row its facets allow, and View All pages its query', () async {
      fake.on(
        'GET',
        '/api/v1/media/facets',
        (_) => jsonResponse(_facets(sorts: ['title', 'added_at', 'release_date', 'rating', 'random'])),
      );
      fake.on('GET', '/api/v1/media', (r) {
        expect(r.url.queryParameters['library_id'], 'lib-1');
        return jsonResponse(_page([mediaSummary('m-${r.url.queryParameters.length}')]));
      });
      fake.on(
        'GET',
        '/api/v1/users/me/suggested',
        (_) => jsonResponse({
          'items': [mediaSummary('m-sug'), mediaSummary('m-other', library: 'lib-2')],
        }),
      );
      fake.on('GET', '/api/v1/media/binge-ready', (_) => jsonResponse({'items': <Object>[]}));
      final c = client();
      final hubs = await c.fetchLibraryHubs('lib-1', libraryName: 'Movies');
      expect(hubs.map((h) => h.title), [
        'Continue Watching in Movies',
        'Recently Added in Movies',
        'Suggested for You',
        'Recently Released',
        'Top Rated',
        'Unwatched',
        'Drama',
        'Comedy',
      ]);
      expect(hubs[2].items.map((i) => i.id), ['m-sug'], reason: 'other libraries are left out');
      final queries = [for (final r in fake.to('GET', '/api/v1/media')) r.url.queryParameters];
      expect(queries.any((q) => q['watched'] == 'in_progress'), isTrue);
      expect(queries.any((q) => q['sort'] == 'release_date' && q['released_only'] == 'true'), isTrue);
      expect(queries.any((q) => q['sort'] == 'rating' && q['order'] == 'desc'), isTrue);
      expect(queries.any((q) => q['watched'] == 'unwatched' && q['sort'] == 'random'), isTrue);
      expect(queries.any((q) => q['genre'] == 'Drama'), isTrue);

      final before = fake.to('GET', '/api/v1/media').length;
      final page = await c.fetchMoreHubItemsPage(hubs[6].id, start: 0, size: 10);
      expect(page.items, isNotEmpty);
      final viewAll = fake.to('GET', '/api/v1/media');
      expect(viewAll.length, before + 1);
      expect(viewAll.last.url.queryParameters['genre'], 'Drama');

      final noPlayback = await c.fetchLibraryHubs('lib-1', libraryName: 'Movies', includePlaybackHubs: false);
      expect(noPlayback.first.title, 'Recently Added in Movies');
    });

    test('a library offers only rows its facets list', () async {
      fake.on(
        'GET',
        '/api/v1/media/facets',
        (_) => jsonResponse(
          _facets(sorts: ['title'])
            ..['genres'] = <Object>[]
            ..['watched'] = <String, Object>{},
        ),
      );
      fake.on('GET', '/api/v1/media', (_) => jsonResponse(_page([mediaSummary('m-x')])));
      fake.on('GET', '/api/v1/users/me/suggested', (_) => jsonResponse({'items': <Object>[]}));
      fake.on('GET', '/api/v1/media/binge-ready', (_) => jsonResponse({'items': <Object>[]}));
      final hubs = await client().fetchLibraryHubs('lib-1', libraryName: 'Movies');
      expect(hubs, isEmpty);
      expect(fake.to('GET', '/api/v1/media'), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  group('watchlist', () {
    test('Tofa offers the watchlist only, read from the server', () async {
      fake.on('GET', '/api/v1/media/m-1', (_) => jsonResponse(movieDetail()));
      fake.on('POST', '/api/v1/media/progress/batch', (_) => jsonResponse({'items': <Object>[]}));
      fake.on(
        'GET',
        '/api/v1/users/me/watchlist',
        (_) => jsonResponse(
          _page([
            {
              'media_id': 'm-1',
              'owned': true,
              'title': 'A Movie',
              'media_type': 'movie',
              'genres': <String>[],
              'added_at': '',
            },
          ])..['total_pages'] = 1,
        ),
      );
      final c = client();
      expect(c, isA<MembershipListsClient>());
      expect(c.membershipKinds, {SiloMembership.watchlist});
      final movie = await c.fetchItem('m-1');
      expect(c.memberships.isMember(movie!, SiloMembership.watchlist), isTrue);
    });

    test('toggles write POST and DELETE, and a refusal rolls back', () async {
      fake.on('GET', '/api/v1/users/me/watchlist', (_) => jsonResponse(<Object>[]));
      var status = 204;
      fake.on('POST', '/api/v1/users/me/watchlist/m-2', (_) => http.Response('', status));
      fake.on('DELETE', '/api/v1/users/me/watchlist/m-2', (_) => http.Response('', 204));
      final c = client();
      final movie = MediaItem(id: 'm-2', backend: MediaBackend.tofa, kind: MediaKind.movie);
      var outcome = await c.memberships.toggle(movie, SiloMembership.watchlist);
      expect(outcome!.ok, isTrue);
      expect(c.memberships.isMember(movie, SiloMembership.watchlist), isTrue);
      outcome = await c.memberships.toggle(movie, SiloMembership.watchlist);
      expect(outcome!.ok, isTrue);
      expect(fake.to('DELETE', '/api/v1/users/me/watchlist/m-2'), hasLength(1));
      status = 403;
      fake.on('POST', '/api/v1/users/me/watchlist/m-2', (_) => tofaError(403, 'forbidden', 'Not allowed here.'));
      outcome = await c.memberships.toggle(movie, SiloMembership.watchlist);
      expect(outcome!.ok, isFalse);
      expect(outcome.message, contains('Not allowed here.'));
      expect(c.memberships.isMember(movie, SiloMembership.watchlist), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  Map<String, dynamic> quickView() => {
    'media_file_id': 'f-1',
    'generated_at': '2026-11-01T00:00:00Z',
    'chapters': [
      {
        'chapter_index': 1,
        'title': 'Middle',
        'start_ticks': 6000000000,
        'image_tag': 't',
        'image_rel_path': null,
        'source': 'file',
      },
      {
        'chapter_index': 0,
        'title': 'Opening',
        'start_ticks': 0,
        'image_tag': null,
        'image_rel_path': null,
        'source': 'file',
      },
    ],
    'segments': [
      {'id': 's1', 'segment_type': 'Intro', 'start_ticks': 100000000, 'end_ticks': 900000000, 'provider_id': 'audio'},
      {'id': 's2', 'segment_type': 'outro', 'start_ticks': 50000000000, 'end_ticks': 55000000000, 'provider_id': 'bf'},
      {'id': 's3', 'segment_type': 'commercial', 'start_ticks': 1, 'end_ticks': 2, 'provider_id': 'x'},
    ],
    'tiles': [
      {
        'width': 320,
        'height': 180,
        'tile_width': 10,
        'tile_height': 10,
        'thumbnail_count': 250,
        'interval_ms': 10000,
        'bandwidth_bps': 0,
        'playlist_url': '/x',
      },
    ],
  };

  group('chapters, markers and seek previews', () {
    Future<TofaClient> playing() async {
      fake.on('GET', '/api/v1/media/m-1', (_) => jsonResponse(movieDetail()));
      fake.on('POST', '/api/v1/media/progress/batch', (_) => jsonResponse({'items': <Object>[]}));
      fake.on('GET', '/api/v1/users/me/watchlist', (_) => jsonResponse(<Object>[]));
      fake.on('GET', '/api/v1/stream/f-1/info', (_) => jsonResponse(playbackInfo()));
      fake.on('GET', '/api/v1/media/f-1/quickview', (_) => jsonResponse(quickView()));
      fake.on('GET', '/api/v1/auth/image-token', (_) => jsonResponse({'token': 'img', 'expires_in': 3600}));
      final c = client();
      final movie = await c.fetchItem('m-1');
      await c.getPlaybackInitialization(PlaybackInitializationOptions(metadata: movie!, selectedMediaIndex: 0));
      return c;
    }

    test('chapters in order and skip markers by segment type (unknown types left out)', () async {
      final c = await playing();
      await c.ensureImageTokenForTesting();
      final extras = await c.fetchPlaybackExtras('m-1');
      expect(extras.chapters.map((ch) => ch.title), ['Opening', 'Middle']);
      expect(extras.chapters.map((ch) => ch.startTimeOffset), [0, 600000]);
      expect(extras.chapters.last.thumb, contains('/api/v1/media/f-1/quickview/chapters/1?st=img'));
      expect(extras.markers.map((m) => (m.type, m.startTimeOffset, m.endTimeOffset)), [
        ('intro', 10000, 90000),
        ('credits', 5000000, 5500000),
      ]);
    });

    test('seek previews read the QuickView tiles with the image token', () async {
      final c = await playing();
      final source = await c.createScrubPreviewSource(
        item: MediaItem(id: 'm-1', backend: MediaBackend.tofa, kind: MediaKind.movie),
        mediaSource: MediaSourceInfo(
          videoUrl: '',
          audioTracks: [],
          subtitleTracks: [],
          chapters: [],
          mediaSourceId: 'f-1',
        ),
      );
      expect(source, isA<JellyfinTrickplayService>());
      final trickplay = source! as JellyfinTrickplayService;
      expect(trickplay.isAvailable, isTrue);
      expect(trickplay.sheetUrlFor(2), '$tofaBase/api/v1/media/f-1/quickview/tiles/320/2?st=img');
      final loc = trickplay.tileLocationFor(const Duration(seconds: 1015))!;
      expect((loc.sheetIndex, loc.tileColumn, loc.tileRow), (1, 1, 0));
    });

    test('the QuickView answer is kept for offline use', () async {
      final c = await playing();
      await c.fetchPlaybackExtras('m-1');
      await Future<void>.delayed(Duration.zero);
      final cached = await TofaApiCache.instance.get(ServerId(c.cacheServerId), TofaApiCache.quickViewEndpoint('f-1'));
      expect(cached?['media_file_id'], 'f-1');
    });
  });

  // ---------------------------------------------------------------------------
  group('downloads', () {
    Map<String, dynamic> registration({String id = 'dl-1'}) => {
      'download_id': id,
      'active_profile_id': 'p-1',
      'auth': {'token': 'dl-tok', 'mode': 'query', 'expires_at': '2026-12-01T00:00:00Z'},
      'container': 'mkv',
      'content_hash': 'h',
      'content_length': 1000,
      'contract_version': 1,
      'downloads_enabled': true,
      'duration_seconds': 6000.0,
      'min_client_contract_version': 1,
      'relative_path': 'media/f-1.mkv',
      'transport': 'http',
      'metadata_snapshot': {
        'kind': 'movie',
        'media_file_id': 'f-1',
        'media_id': 'm-1',
        'title': 'A Movie',
        'genres': <String>[],
        'audio_tracks': <Object>[],
        'subtitles': <Object>[],
        'skip_segments': <Object>[],
      },
      'audio_tracks': [
        {'index': 0, 'codec': 'eac3', 'language': 'eng', 'title': 'English', 'channels': 6},
      ],
      'subtitle_tracks': [
        {'index': 0, 'language': 'eng', 'title': 'English', 'is_forced': false, 'relative_path': 'subs/0.vtt'},
      ],
      'skip_segments': [
        {'id': 'k1', 'kind': 'intro', 'start_seconds': 10.0, 'end_seconds': 90.0},
      ],
      'subtitle_manifest': {
        'version': 1,
        'tracks': [
          {
            'track_id': 'tr-1',
            'relative_path': 'subs/0.vtt',
            'content_length': 10,
            'auth': {'token': 'sub-tok', 'mode': 'query', 'expires_at': ''},
            'representation': {'format': 'vtt', 'schema': 'v1', 'revision': 'r1'},
          },
          {
            'track_id': 'tr-2',
            'relative_path': 'subs/1.sup',
            'content_length': 10,
            'auth': {'token': 'sub-tok', 'mode': 'query', 'expires_at': ''},
            'representation': {'format': 'pgs', 'schema': 'v1', 'revision': 'r1'},
          },
        ],
      },
    };

    List<Map<String, dynamic>> options() => [
      {
        'tag': 'orig',
        'label': 'Original (4K)',
        'is_original': true,
        'height': 2160,
        'bitrate_kbps': 25000,
        'size_bytes': 9000,
        'size_is_estimate': false,
      },
      {
        'tag': 'q1080',
        'label': '1080p',
        'is_original': false,
        'height': 1080,
        'bitrate_kbps': 8000,
        'size_bytes': 3000,
        'size_is_estimate': true,
      },
    ];

    void serve({http.Response Function(http.Request)? register}) {
      fake.on(
        'GET',
        '/api/v1/media/m-1',
        (_) => jsonResponse(movieDetail(files: [mediaFile('f-1')..['download_options'] = options()])),
      );
      fake.on('POST', '/api/v1/media/progress/batch', (_) => jsonResponse({'items': <Object>[]}));
      fake.on('GET', '/api/v1/users/me/watchlist', (_) => jsonResponse(<Object>[]));
      fake.on('GET', '/api/v1/auth/image-token', (_) => jsonResponse({'token': 'img', 'expires_in': 3600}));
      fake.on('GET', '/api/v1/media/f-1/quickview', (_) => jsonResponse(quickView()));
      fake.on('POST', '/api/v1/download/register', register ?? (_) => jsonResponse(registration()));
    }

    test('register, then download the original with the scoped token as st', () async {
      serve();
      final c = client();
      final movie = await c.fetchItem('m-1');
      final resolution = await c.resolveDownload(movie!);
      final body = jsonDecode(fake.to('POST', '/api/v1/download/register').single.body) as Map;
      expect(body['media_file_id'], 'f-1');
      expect(body['quality_key'], 'orig');
      expect(body['device_id'], 'dev-1');
      expect(body['client_request_id'], isNotEmpty);
      final url = Uri.parse(resolution.videoUrl!);
      expect(url.path, '/api/v1/stream/f-1/download');
      expect(url.queryParameters, {'quality': 'orig', 'st': 'dl-tok'});
      expect(url.fragment, 'container=mkv');
      expect(resolution.mediaSourceId, 'f-1');
      expect(resolution.headers, isEmpty, reason: 'the bearer never rides with the download');
      final sub = resolution.externalSubtitles.single;
      expect(sub.url, contains('/api/v1/stream/f-1/download/subtitles/tr-1/vtt/v1/r1?st=sub-tok'));
      expect(sub.headers, {'X-Tofa-Device-Id': 'dev-1'});
      expect(sub.language, 'eng');
      final record = await TofaApiCache.instance.getDownloadRecord(ServerId(c.cacheServerId), 'm-1');
      expect(record!.downloadId, 'dl-1');
      expect(jsonEncode(record.toJson()), isNot(contains('dl-tok')), reason: 'no token is stored');
    });

    test('a picked quality is used for later downloads', () async {
      serve();
      final c = client();
      final movie = await c.fetchItem('m-1');
      final choices = await c.downloadQualityChoices(movie!);
      expect(choices.map((q) => q.label), ['Original (4K)', '1080p']);
      await c.setDownloadQuality(movie, choices.last);
      await c.resolveDownload(movie);
      expect((jsonDecode(fake.to('POST', '/api/v1/download/register').single.body) as Map)['quality_key'], 'q1080');
    });

    test('a quality still being prepared waits with the preparation message', () async {
      serve(register: (_) => tofaError(409, 'preparing', 'Preparing'));
      fake.onPrefix(
        'GET',
        '/api/v1/download/prepare/',
        (_) => jsonResponse({
          'request_id': 'x',
          'finished': false,
          'message': 'Converting to 1080p (40%)',
          'phase': 'transcode',
          'progress': 0.4,
          'updated_at': '2026-11-25T00:00:00Z',
        }),
      );
      final c = client();
      final movie = await c.fetchItem('m-1');
      await expectLater(
        c.resolveDownload(movie!),
        throwsA(isA<DownloadNotReadyException>().having((e) => e.message, 'message', 'Converting to 1080p (40%)')),
      );
      final sentId = (jsonDecode(fake.to('POST', '/api/v1/download/register').single.body) as Map)['client_request_id'];
      expect(
        fake.requests.where((r) => r.url.path == '/api/v1/download/prepare/$sentId'),
        hasLength(1),
        reason: 'the preparation is read under the request id that was sent',
      );
    });

    test('offline playback reads the tracks and skip markers the registration stored', () async {
      serve();
      final c = client();
      final movie = await c.fetchItem('m-1');
      await c.resolveDownload(movie!);
      await TofaApiCache.instance.pinForOffline(ServerId(c.cacheServerId), 'm-1');
      final info = await CachedPlaybackMetadataService.fetchMediaSourceInfo(
        backend: MediaBackend.tofa,
        cacheServerId: c.cacheServerId,
        itemId: 'm-1',
      );
      expect(info!.audioTracks.single.language, 'eng');
      expect(info.mediaSourceId, 'f-1');
      final extras = await CachedPlaybackMetadataService.fetchPlaybackExtras(
        backend: MediaBackend.tofa,
        cacheServerId: c.cacheServerId,
        itemId: 'm-1',
      );
      expect(extras!.markers.first.type, 'intro');
    });

    test('offline progress goes up with a rising sequence; deleting the copy unregisters it', () async {
      serve();
      fake.on('POST', '/api/v1/playback/offlineProgress', (_) => http.Response('', 204));
      fake.on('DELETE', '/api/v1/download/dl-1', (_) => http.Response('', 204));
      final c = client();
      final movie = await c.fetchItem('m-1');
      await c.resolveDownload(movie!);
      for (final seconds in [30, 60]) {
        await c.reportPlaybackStopped(
          itemId: 'm-1',
          position: Duration(seconds: seconds),
          duration: const Duration(minutes: 100),
          report: PlaybackReportMetadata.offlineReplay(recordedAt: DateTime.utc(2026, 11, 20, 8)),
        );
      }
      final events = [
        for (final r in fake.to('POST', '/api/v1/playback/offlineProgress')) (jsonDecode(r.body) as List).single as Map,
      ];
      expect(events.map((e) => e['monotonic_seq']), [1, 2]);
      expect(events.last, containsPair('position_seconds', 60.0));
      expect(events.last, containsPair('download_id', 'dl-1'));
      expect(events.last['occurred_at_wall'], '2026-11-20T08:00:00.000Z');
      expect(fake.to('PUT', '/api/v1/media/f-1/progress'), isEmpty);

      await TofaDownloadTracker.instance.localCopyRemoved('${c.serverId.value}:m-1');
      expect(fake.to('DELETE', '/api/v1/download/dl-1').single.headers['X-Tofa-Device-Id'], 'dev-1');
      expect(await TofaApiCache.instance.getDownloadRecord(ServerId(c.cacheServerId), 'm-1'), isNull);
    });

    test('an option is never picked by position when none is the original', () {
      final options = TofaDownloadQuality.listOf([
        {'tag': 'a', 'label': '1080p', 'is_original': false, 'height': 1080},
        {'tag': 'b', 'label': '720p', 'is_original': false, 'height': 720},
      ]);
      expect(TofaDownloadQuality.pick(options, null), isNull);
      expect(TofaDownloadQuality.pick(options, 'height:720')!.tag, 'b');
    });
  });

  // ---------------------------------------------------------------------------
  group('connecting from away', () {
    const lan = 'lan.example.com';
    const wan = 'wan.example.com';

    Map<String, dynamic> info({bool lanAvailable = true}) => {
      'connection_type': 'direct',
      'online': true,
      'connect_url': 'https://$wan:33333',
      'proxy_url': null,
      'proxy_available': false,
      'candidates': [
        {'type': 'lan-direct', 'url': 'https://$lan:33333', 'stagger_ms': 0, if (!lanAvailable) 'available': false},
        {'type': 'wan-direct', 'url': 'https://$wan:33333', 'stagger_ms': 100},
        {'type': 'carrier-pigeon', 'url': 'https://bird.example.com', 'stagger_ms': 150},
        {'type': 'relay', 'url': '$tofaCloud/servers/srv-1/relay', 'stagger_ms': 200, 'available': true},
      ],
    };

    void serve() {
      fake.on('GET', '/servers/srv-1/connection-info', (r) {
        expect(r.headers['Authorization'], 'Bearer acc-1');
        return jsonResponse(info());
      });
      final status = {'claimed': true, 'claim_pending': false, 'server_id': 'srv-1', 'connect_url': tofaCloud};
      fake.on('GET', '/api/v1/auth/status', (_) => jsonResponse(status));
      fake.on('GET', '/servers/srv-1/relay/api/v1/auth/status', (_) => jsonResponse(status));
      final me = {'id': 'u-1', 'username': 'laura', 'disabled': false, 'preferences': {}};
      fake.on('GET', '/api/v1/users/me', (_) => jsonResponse(me));
      fake.on('GET', '/servers/srv-1/relay/api/v1/users/me', (_) => jsonResponse(me));
      fake.on('GET', '/api/v1/auth/image-token', (_) => jsonResponse({'token': 'img', 'expires_in': 3600}));
      fake.on(
        'GET',
        '/servers/srv-1/relay/api/v1/auth/image-token',
        (_) => jsonResponse({'token': 'img', 'expires_in': 3600}),
      );
    }

    test('the entered address wins when it answers', () async {
      serve();
      final c = client();
      expect(await c.checkHealth(), HealthStatus.online);
      expect(c.endpointKind, TofaEndpointKind.typed);
      expect(c.activeBaseUrl, tofaBase);
    });

    test('away from home: local, then direct, then relay; unknown types skipped', () async {
      serve();
      fake.downHosts.addAll({'tofa.example.com', lan});
      final c = client();
      expect(await c.checkHealth(), HealthStatus.online);
      expect(c.endpointKind, TofaEndpointKind.wanDirect);
      expect(c.activeBaseUrl, 'https://$wan:33333');
      expect(fake.requests.where((r) => r.url.host == 'bird.example.com'), isEmpty);
    });

    test('with only the relay left, requests go through it and playback says so', () async {
      serve();
      fake.downHosts.addAll({'tofa.example.com', lan, wan});
      fake.on('GET', '/servers/srv-1/relay/api/v1/stream/f-1/info', (r) {
        expect(r.headers['Authorization'], 'Bearer acc-1');
        return jsonResponse(playbackInfo(streamUrl: '/api/v1/stream/f-1/file.mkv?st=s'));
      });
      final c = client();
      expect(await c.checkHealth(), HealthStatus.online);
      expect(c.endpointKind, TofaEndpointKind.relay);
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(
          metadata: MediaItem(
            id: 'm-1',
            backend: MediaBackend.tofa,
            kind: MediaKind.movie,
            raw: const {
              'tofa_file_ids': ['f-1'],
            },
          ),
          selectedMediaIndex: 0,
        ),
      );
      expect(result.videoUrl, '$tofaCloud/servers/srv-1/relay/api/v1/stream/f-1/file.mkv?st=s');
      expect(result.playbackNotice, contains('relay'));
    });

    test('when the address in use stops answering, the race runs again', () async {
      serve();
      final c = client();
      await c.checkHealth();
      expect(c.endpointKind, TofaEndpointKind.typed);
      fake.downHosts.add('tofa.example.com');
      fake.on('GET', '/api/v1/libraries', (_) => jsonResponse(<Object>[]));
      for (var i = 0; i < 2; i++) {
        await expectLater(c.fetchLibraries(), throwsA(anything));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(c.endpointKind, TofaEndpointKind.lanDirect);
      expect(await c.fetchLibraries(), isEmpty);
    });

    test('a relay that is not connected yet is retried', () async {
      serve();
      var calls = 0;
      fake.on(
        'GET',
        '/api/v1/libraries',
        (_) => ++calls < 3 ? tofaError(503, 'server_relay_not_connected') : jsonResponse(<Object>[]),
      );
      final c = client()..relayRetryDelays = const [Duration.zero, Duration.zero, Duration.zero];
      expect(await c.fetchLibraries(), isEmpty);
      expect(calls, 3);
    });

    test('the race: staggered starts, first success wins, all failing is null', () async {
      final waits = <Duration>[];
      final winner = await raceTofaEndpoints(
        const [
          TofaEndpointCandidate(url: 'a', kind: TofaEndpointKind.lanDirect),
          TofaEndpointCandidate(url: 'b', kind: TofaEndpointKind.wanDirect, stagger: Duration(milliseconds: 100)),
          TofaEndpointCandidate(url: 'a', kind: TofaEndpointKind.relay, stagger: Duration(milliseconds: 200)),
        ],
        (c) async => c.url == 'b',
        wait: (d) async => waits.add(d),
      );
      expect(winner!.url, 'b');
      expect(waits, [Duration.zero, const Duration(milliseconds: 100)], reason: 'a duplicate address is tried once');
      expect(
        await raceTofaEndpoints(const [
          TofaEndpointCandidate(url: 'a', kind: TofaEndpointKind.typed),
        ], (_) async => false),
        isNull,
      );
    });
  });

  // ---------------------------------------------------------------------------
  group('collections', () {
    Map<String, dynamic> discovery(String? localId, {bool inLibrary = true, String type = 'movie'}) => {
      'title': 'Member $localId',
      'tmdb_id': 7,
      'type': type,
      'genres': <String>[],
      'in_library': inLibrary,
      'local_media_id': localId,
      'poster_path': '/p.jpg',
      'year': 2001,
      'blocklisted': false,
      'not_interested': false,
      'seen': false,
      'upcoming': false,
    };

    void serveCollections() {
      fake.on(
        'GET',
        '/api/v1/collections',
        (_) => jsonResponse({
          'collections': [
            {
              'id': 'c-1',
              'name': 'Space Saga',
              'kind': 'franchise',
              'item_count': 3,
              'poster_url': '/api/v1/collections/c-1/poster',
              'backdrop_url': 'https://img.example.com/b.jpg',
            },
          ],
        }),
      );
      fake.on(
        'GET',
        '/api/v1/collections/custom',
        (_) => jsonResponse({
          'collections': [
            {
              'id': 'u-1',
              'name': 'Rainy days',
              'item_count': 1,
              'can_edit': true,
              'poster_path': 'not-a-route.jpg',
              'backdrop_path': null,
              'poster_paths': <String>[],
              'overview': null,
              'created_at': '',
              'updated_at': '',
              'created_by': null,
              'created_by_name': null,
            },
          ],
          'containing': <String>[],
        }),
      );
      fake.on(
        'GET',
        '/api/v1/collections/c-1',
        (_) => jsonResponse({
          'id': 'c-1',
          'name': 'Space Saga',
          'kind': 'franchise',
          'overview': 'Three films',
          'poster_url': null,
          'items': [discovery('m-1'), discovery(null, inLibrary: false), discovery('show-1', type: 'tv')],
        }),
      );
      fake.on(
        'GET',
        '/api/v1/collections/custom/u-1',
        (_) => jsonResponse({
          'id': 'u-1',
          'name': 'Rainy days',
          'item_count': 1,
          'can_edit': true,
          'poster_path': null,
          'backdrop_path': null,
          'poster_paths': <String>[],
          'overview': null,
          'created_at': '',
          'updated_at': '',
          'created_by': null,
          'created_by_name': null,
          'items': [mediaSummary('m-1')],
        }),
      );
      fake.on('GET', '/api/v1/media/m-1', (_) => jsonResponse(movieDetail()));
      fake.on('GET', '/api/v1/media/show-1', (_) => jsonResponse(showDetail()));
      fake.on('POST', '/api/v1/media/progress/batch', (_) => jsonResponse({'items': <Object>[]}));
    }

    test('both kinds are listed on a library Collections tab, with their artwork', () async {
      serveCollections();
      fake.on('GET', '/api/v1/auth/image-token', (_) => jsonResponse({'token': 'img', 'expires_in': 3600}));
      final c = client();
      await c.ensureImageTokenForTesting();
      final page = await c.fetchCollectionsPage('lib-1');
      final poster = Uri.parse(c.thumbnailUrl(page.items.first.thumbPath, width: 300));
      expect(poster.path, '/api/v1/collections/c-1/poster');
      expect(poster.queryParameters, {'st': 'img', 'w': '300'});
      expect(page.items.map((i) => i.title), ['Space Saga', 'Rainy days']);
      expect(page.items.every((i) => i.kind == MediaKind.collection), isTrue);
      expect(page.items.first.childCount, 3);
      expect(page.items.first.artPath, 'https://img.example.com/b.jpg');
      expect(page.items.last.thumbPath, isNull, reason: 'a bare file path is not guessed at');
      await c.fetchCollectionsPage('lib-1', start: 1, size: 1);
      expect(fake.to('GET', '/api/v1/collections'), hasLength(1), reason: 'pages slice one read');
    });

    test('a failed list leaves the other one', () async {
      serveCollections();
      fake.on('GET', '/api/v1/collections/custom', (_) => tofaError(500, 'boom'));
      final page = await client().fetchCollectionsPage('lib-1');
      expect(page.items.single.title, 'Space Saga');
    });

    test('members are the titles in the library; custom collections read their own route', () async {
      serveCollections();
      final c = client();
      final page = await c.fetchCollectionPage('tofa-collection:c-1');
      expect(page.items.map((i) => i.id), ['m-1', 'show-1']);
      expect(page.items.last.kind, MediaKind.show);
      final custom = await c.fetchCollectionPage('tofa-custom:u-1');
      expect(custom.items.single.id, 'm-1');
      final item = await c.fetchItem('tofa-collection:c-1');
      expect(item?.summary, 'Three films');
      expect(item?.kind, MediaKind.collection);
    });

    test('playing uses the server queue, episodes found by number', () async {
      serveCollections();
      fake.on('GET', '/api/v1/collections/c-1/play', (r) {
        expect(r.url.queryParameters['mode'], 'in_order');
        return jsonResponse({
          'collection_id': 'c-1',
          'mode': 'in_order',
          'sort_mode': 'release',
          'entries': [
            {'media_id': 'm-1', 'media_type': 'movie', 'media_file_id': 'f-1', 'title': 'A Movie', 'tmdb_id': 1},
            {
              'media_id': 'show-1',
              'media_type': 'tv',
              'media_file_id': 'f-e2',
              'title': 'A Show',
              'tmdb_id': 2,
              'season_number': 1,
              'episode_number': 2,
            },
            {'media_id': 'gone', 'media_type': 'movie', 'media_file_id': 'f-x', 'title': 'Gone', 'tmdb_id': 3},
          ],
        });
      });
      final queue = await client().fetchPlayableDescendants('tofa-collection:c-1');
      expect(queue.map((i) => i.id), ['m-1', 'tofa-episode:show-1/e-2']);
    });

    test('a refused queue plays the members in order', () async {
      serveCollections();
      fake.on('GET', '/api/v1/collections/u-1/play', (_) => tofaError(404, 'not_found'));
      final queue = await client().fetchPlayableDescendants('tofa-custom:u-1');
      expect(queue.map((i) => i.id), ['m-1']);
    });
  });

  // ---------------------------------------------------------------------------
  group('people and trailers', () {
    test('a cast member opens their titles in the library and their biography', () async {
      fake.on('GET', '/api/v1/media/m-1', (_) => jsonResponse(movieDetail()..['youtube_trailer_id'] = 'yt123'));
      fake.on('POST', '/api/v1/media/progress/batch', (_) => jsonResponse({'items': <Object>[]}));
      fake.on('GET', '/api/v1/media', (r) {
        expect(r.url.queryParameters['cast'], 'Actor One');
        return jsonResponse(_page([mediaSummary('m-2')]));
      });
      fake.on('GET', '/api/v1/discovery/people/by-name', (r) {
        expect(r.url.queryParameters['name'], 'Actor One');
        return jsonResponse({
          'person_id': 5,
          'name': 'Jane Doe',
          'biography': ' An actor. ',
          'birthday': '1980-02-03',
          'deathday': null,
          'place_of_birth': 'Reykjavik',
          'also_known_as': <String>[],
          'credits': <Object>[],
          'credits_truncated': false,
          'details_pending': false,
          'imdb_id': null,
          'known_for_department': 'Acting',
          'profile_url': null,
        });
      });
      final c = client();
      final item = await c.fetchItem('m-1');
      final role = item!.roles!.single;
      expect(role.tag, 'Actor One');
      expect(role.id, 'tofa-person:Actor One');
      final page = await c.fetchPersonMediaPage(role.id!);
      expect(page.items.single.id, 'm-2');
      final details = await c.fetchPersonDetails(role.id!);
      expect(details.biography, 'An actor.');
      expect(details.birthDate, DateTime.utc(1980, 2, 3));
      expect(details.birthPlace, 'Reykjavik');
      final trailers = await c.fetchRemoteTrailers('m-1');
      expect(trailers.single.key, 'yt123');
      expect(trailers.single.isYoutube, isTrue);
    });

    test('people search lists actors with titles; title search adds collections', () async {
      fake.on('GET', '/api/v1/search', (r) {
        final q = r.url.queryParameters;
        return jsonResponse({
          'movies': q['movie_limit'] == '0' ? <Object>[] : [mediaSummary('m-1')],
          'actors': [
            {
              'name': 'Jane Doe',
              'media_count': 2,
              'profile_url': 'https://img.example.com/j.jpg',
              'sample_poster_path': null,
            },
            {'name': 'Nobody', 'media_count': 0, 'profile_url': null, 'sample_poster_path': null},
          ],
          'discover': <Object>[],
          'collections': [
            {
              'id': 'u-1',
              'kind': 'custom',
              'name': 'Rainy days',
              'item_count': 2,
              'poster_path': null,
              'backdrop_path': null,
              'poster_paths': <String>[],
            },
          ],
        });
      });
      final c = client();
      final people = await c.searchPeople('jane');
      expect(people.single.id, 'tofa-person:Jane Doe');
      expect(people.single.thumbPath, 'https://img.example.com/j.jpg');
      final items = await c.searchItems('rain');
      expect(items.map((i) => i.id), ['m-1', 'tofa-custom:u-1']);
    });
  });

  // ---------------------------------------------------------------------------
  test('a catalog title is found in the library by its TMDB id', () async {
    fake.on('GET', '/api/v1/media/by-tmdb/42', (r) {
      expect(r.url.queryParameters['media_type'], 'tv');
      return jsonResponse({'media_id': 'show-1', 'files': <Object>[]});
    });
    fake.on('GET', '/api/v1/media/by-tmdb/7', (_) => tofaError(404, 'not_found'));
    fake.on('GET', '/api/v1/media/show-1', (_) => jsonResponse(showDetail()));
    fake.on('POST', '/api/v1/media/progress/batch', (_) => jsonResponse({'items': <Object>[]}));
    final c = client();
    final found = await c.findByExternalIds(const ExternalIds(tmdb: 42), kind: MediaKind.show);
    expect(found!.single.id, 'show-1');
    final season3 = await c.findByExternalIds(
      const ExternalIds(tmdb: 42),
      kind: MediaKind.show,
      season: const ExternalSeasonRef(tvdb: 3, tmdb: 3),
    );
    expect(season3, isEmpty, reason: 'the library has no season 3');
    expect(await c.findByExternalIds(const ExternalIds(tmdb: 7), kind: MediaKind.movie), isEmpty);
    expect(await c.findByExternalIds(const ExternalIds(imdb: 'tt1'), kind: MediaKind.movie), isNull);
  });
}
