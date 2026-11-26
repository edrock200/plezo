import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/tofa/tofa_api.dart';
import 'package:plezy/services/tofa/tofa_api_cache.dart';
import 'package:plezy/services/tofa/tofa_auth_service.dart';
import 'package:plezy/services/tofa/tofa_client.dart';
import 'package:plezy/services/tofa/tofa_extras.dart';

import 'tofa_fixtures.dart';

Map<String, dynamic> discoveryRow(int tmdb, {String type = 'movie', bool inLibrary = false, String? local}) => {
  'tmdb_id': tmdb,
  'type': type,
  'title': 'Title $tmdb',
  'year': 2024,
  'genres': <String>[],
  'poster_path': '/p$tmdb.jpg',
  'in_library': inLibrary,
  'local_media_id': local,
  'request_status': null,
  'seen': false,
  'not_interested': false,
  'blocklisted': false,
  'upcoming': false,
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
    headers: const TofaClientHeaders(clientVersion: '1.0', platform: 'android', deviceName: 'Test device'),
    httpClient: fake.client,
  )..raceWait = (_) async {};

  group('discover', () {
    test('the page, a shelf by cursor, a lane, the radar and a person', () async {
      fake.on(
        'GET',
        '/api/v1/discovery/page',
        (_) => jsonResponse({
          'heroes': [
            {'item': discoveryRow(1), 'reason': 'new', 'source_shelf': 's1'},
          ],
          'shelves': [
            {
              'key': 's1',
              'kind': 'trending',
              'title': 'Trending',
              'subtitle': 'This week',
              'items': [discoveryRow(2, type: 'tv')],
              'missing_count': 0,
              'generated_at': '',
              'next_cursor': 'c2',
            },
          ],
          'lanes': [
            {'slug': 'noir', 'title': 'Noir', 'description': 'Shadows', 'followed': false, 'taste': false},
          ],
        }),
      );
      fake.on('GET', '/api/v1/discovery/shelf/s1', (r) {
        expect(r.url.queryParameters['cursor'], 'c2');
        return jsonResponse({
          'key': 's1',
          'kind': 'trending',
          'title': 'Trending',
          'subtitle': '',
          'items': [discoveryRow(3)],
          'missing_count': 0,
          'generated_at': '',
          'next_cursor': null,
        });
      });
      fake.on(
        'GET',
        '/api/v1/discovery/lanes/noir',
        (_) => jsonResponse({
          'lane': {'slug': 'noir', 'title': 'Noir', 'description': 'Shadows', 'followed': true, 'taste': false},
          'shelves': <Object>[],
        }),
      );
      fake.on('PUT', '/api/v1/discovery/lanes/noir/follow', (_) => http.Response('', 204));
      fake.on(
        'GET',
        '/api/v1/discovery/radar',
        (_) => jsonResponse({
          'generated_at': '',
          'buckets': [
            {
              'key': 'this_week',
              'title': 'This week',
              'subtitle': '',
              'items': [discoveryRow(4)..['available_on'] = 'Friday'],
            },
          ],
        }),
      );
      fake.on(
        'GET',
        '/api/v1/discovery/people/9',
        (_) => jsonResponse({
          'person_id': 9,
          'name': 'Jane',
          'biography': 'Bio',
          'profile_url': null,
          'credits': [
            discoveryRow(5)..['roles'] = ['Herself'],
          ],
          'also_known_as': <String>[],
          'credits_truncated': false,
          'details_pending': false,
        }),
      );
      final c = client();
      final page = await c.discoverPage();
      expect(page.heroes.single.tmdbId, 1);
      expect(page.shelves.single.items.single.isShow, isTrue);
      expect(page.shelves.single.hasMore, isTrue);
      expect(page.lanes.single.slug, 'noir');
      final next = await c.discoverShelf('s1', cursor: 'c2');
      expect(next!.items.single.tmdbId, 3);
      expect(next.hasMore, isFalse);
      expect((await c.discoverLane('noir')).lane!.followed, isTrue);
      await c.followLane('noir', true);
      final radar = await c.discoverRadar();
      expect(radar.single.items.single.availableOn, 'Friday');
      final person = await c.discoverPerson(9, 'Jane');
      expect(person.credits.single.roles, ['Herself']);
    });

    test('detail, seen and not interested, and artwork', () async {
      fake.on('GET', '/api/v1/discovery/detail/tv/7', (_) {
        return jsonResponse({
          'in_library': false,
          'requests_available': true,
          'request_blocked': false,
          'request_status': null,
          'is4k_capable': true,
          'seen': false,
          'not_interested': false,
          'youtube_trailer_id': 'yt',
          'overview': 'About it',
          'request_rights': {'movie': 'ask', 'tv': 'auto', 'movie_4k': 'off', 'tv_4k': 'ask'},
          'cast': [
            {'person_id': 3, 'name': 'Ann', 'role': 'Lead'},
          ],
        });
      });
      fake.on('PUT', '/api/v1/users/me/seen/tv/7', (_) => http.Response('', 204));
      fake.on('DELETE', '/api/v1/users/me/not-interested/tv/7', (_) => http.Response('', 204));
      final c = client();
      const item = TofaDiscoverItem(tmdbId: 7, type: 'tv', title: 'Show', posterPath: '/x.jpg');
      final detail = await c.discoverDetail(item);
      expect(detail.item.overview, 'About it');
      expect(detail.youtubeTrailerId, 'yt');
      expect(detail.rights!.accessFor('tv'), TofaRequestAccess.auto);
      expect(detail.rights!.accessFor('tv', is4k: true), TofaRequestAccess.ask);
      expect(detail.cast.single.personId, 3);
      await c.setSeen(item, true);
      await c.setNotInterested(item, false);
      expect(fake.to('PUT', '/api/v1/users/me/seen/tv/7'), hasLength(1));
      expect(fake.to('DELETE', '/api/v1/users/me/not-interested/tv/7'), hasLength(1));
      fake.on('GET', '/api/v1/auth/image-token', (_) => jsonResponse({'token': 'img', 'expires_in': 3600}));
      await c.ensureImageTokenForTesting();
      expect(Uri.parse(c.discoverImageUrl(item)).path, endsWith('/cache/x.jpg'));
    });
  });

  group('requests', () {
    test('rights, my requests, search and a new request', () async {
      fake.on(
        'GET',
        '/api/v1/requests/rights',
        (_) => jsonResponse({
          'user_id': 'u-1',
          'requests_available': true,
          'can_manage_requests': false,
          'can_view_others_requests': false,
          'rights': {'movie': 'ask', 'tv': 'off', 'movie_4k': 'off', 'tv_4k': 'off'},
          'quota': {
            'movie': {'days': 7, 'limit': 5, 'remaining': 3, 'used': 2, 'next_free_at': null},
            'tv': null,
          },
        }),
      );
      fake.on(
        'GET',
        '/api/v1/requests',
        (_) => jsonResponse({
          'requests': [
            {
              'id': 'r-1',
              'title': 'Wanted',
              'tmdb_id': 11,
              'media_type': 'movie',
              'status': 'downloading',
              'is4k': false,
              'created_at': '2026-11-20T10:00:00Z',
              'download': {'progress': 0.4, 'remaining_bytes': 1, 'size_bytes': 2, 'status': 'downloading'},
              'seasons': <Object>[],
              'can_retry': false,
            },
          ],
        }),
      );
      fake.on(
        'GET',
        '/api/v1/search',
        (r) => jsonResponse({
          'movies': <Object>[],
          'actors': <Object>[],
          'discover': [
            {
              'tmdb_id': 12,
              'type': 'movie',
              'title': 'Found',
              'source': 'tmdb',
              'genres': <String>[],
              'blocklisted': false,
            },
          ],
        }),
      );
      fake.on('POST', '/api/v1/requests', (r) {
        expect(jsonDecode(r.body), {'media_type': 'movie', 'tmdb_id': 12, 'title': 'Found'});
        return jsonResponse({
          'request': {
            'id': 'r-2',
            'title': 'Found',
            'tmdb_id': 12,
            'media_type': 'movie',
            'status': 'pending_approval',
          },
          'routing_cleared': <Object>[],
        }, 201);
      });
      final c = client();
      final rights = await c.requestRights();
      expect(rights.canRequestAnything, isTrue);
      expect(rights.movieRemaining, 3);
      expect(rights.accessFor('tv'), TofaRequestAccess.off);
      final mine = await c.myRequests();
      expect(mine.single.downloadProgress, 0.4);
      final found = await c.searchDiscover('found');
      final created = await c.createRequest(found.single);
      expect(created!.status, 'pending_approval');
    });
  });

  group('history', () {
    test('pages, opens the episode, deletes one and clears all', () async {
      fake.on('GET', '/api/v1/watch/history', (r) {
        final before = r.url.queryParameters['before_id'];
        return jsonResponse({
          'has_more': before == null,
          'items': [
            if (before == null)
              {
                'id': 'h-1',
                'title': 'A Show',
                'media_id': 'show-1',
                'episode_id': 'e-1',
                'season_number': 1,
                'episode_number': 1,
                'started_at': '2026-11-25T10:00:00Z',
                'play_method': 'DirectPlay',
                'position_ms': 0,
                'progress_percent': 100,
                'seconds_watched': 10,
              }
            else
              {
                'id': 'h-2',
                'title': 'A Movie',
                'media_id': 'm-1',
                'started_at': '2026-11-20T10:00:00Z',
                'play_method': 'DirectPlay',
                'position_ms': 0,
                'progress_percent': 50,
                'seconds_watched': 10,
              },
          ],
        });
      });
      fake.on('DELETE', '/api/v1/watch/history/h-1', (_) => http.Response('', 204));
      fake.on('DELETE', '/api/v1/watch/history', (_) => http.Response('', 204));
      fake.on('GET', '/api/v1/media/show-1', (_) => jsonResponse(showDetail()));
      fake.on('POST', '/api/v1/media/progress/batch', (_) => jsonResponse({'items': <Object>[]}));
      final c = client();
      final first = await c.watchHistory();
      expect(first.hasMore, isTrue);
      final second = await c.watchHistory(after: first.items.last);
      expect(second.items.single.id, 'h-2');
      expect(fake.to('GET', '/api/v1/watch/history').last.url.queryParameters['before'], '2026-11-25T10:00:00.000Z');
      final item = await c.historyItem(first.items.single);
      expect(item!.id, 'tofa-episode:show-1/e-1');
      await c.deleteHistoryEntry('h-1');
      await c.clearWatchHistory();
      expect(fake.to('DELETE', '/api/v1/watch/history'), hasLength(1));
    });
  });

  group('profiles', () {
    test('lists the account profiles, checks a PIN and builds the other profile connection', () async {
      fake.on(
        'GET',
        '/api/v1/profiles',
        (_) => jsonResponse([
          {'id': 'p-1', 'user_id': 'u-1', 'name': 'Me', 'avatar_image_url': '/api/v1/profiles/avatars/a.png'},
          {'id': 'p-2', 'user_id': 'u-1', 'name': 'Kid', 'is_locked': true, 'has_pin': true},
        ]),
      );
      fake.on('POST', '/api/v1/profiles/p-2/verify-pin', (r) {
        expect(r.headers['X-Profile-Id'], 'p-2');
        expect(jsonDecode(r.body)['pin'], '1234');
        return jsonResponse({'profile_token': 'pt', 'expires_at': null});
      });
      fake.on('GET', '/api/v1/auth/image-token', (_) => jsonResponse({'token': 'img', 'expires_in': 3600}));
      final c = client();
      await c.ensureImageTokenForTesting();
      final profiles = await c.accountProfiles();
      expect(profiles.map((p) => p.name), ['Me', 'Kid']);
      expect(Uri.parse(c.profileAvatarUrl(profiles.first)).queryParameters['st'], 'img');
      final pin = await c.verifyProfilePin(profiles.last, '1234');
      expect(pin, isA<TofaPinAccepted>());
      final next = c.connectionForProfile(profiles.last, pin: pin as TofaPinAccepted);
      expect(next.profileId, 'p-2');
      expect(next.profileToken, 'pt');
      expect(next.accessToken, c.connection.accessToken);
      expect(next.id, isNot(c.connection.id));
    });
  });
}
