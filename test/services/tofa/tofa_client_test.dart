import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/tofa/tofa_client.dart';
import 'package:plezy/services/tofa/tofa_mappers.dart';

import 'tofa_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTofa fake;
  setUp(() => fake = FakeTofa());

  TofaClient client({TofaConnection? connection}) =>
      TofaClient.forTesting(connection ?? tofaConnection(), httpClient: fake.client);

  void serveMovie({List<Map<String, dynamic>>? files, List<Map<String, dynamic>> progress = const []}) {
    fake.on('GET', '/api/v1/media/m-1', (_) => jsonResponse(movieDetail(files: files)));
    fake.on('POST', '/api/v1/media/progress/batch', (_) => jsonResponse({'items': progress}));
  }

  void serveShow({List<Map<String, dynamic>> progress = const [], Map<String, dynamic>? nextUp}) {
    fake.on('GET', '/api/v1/media/show-1', (_) => jsonResponse(showDetail(nextUp: nextUp)));
    fake.on('POST', '/api/v1/media/progress/batch', (_) => jsonResponse({'items': progress}));
  }

  group('requests', () {
    test('carry the bearer, the profile and the X-Tofa client headers', () async {
      fake.on('GET', '/api/v1/libraries', (_) => jsonResponse(<Object>[]));
      await client(connection: tofaConnection(profileToken: 'ptok')).fetchLibraries();
      final request = fake.requests.single;
      expect(request.headers['Authorization'], 'Bearer acc-1');
      expect(request.headers['X-Profile-Id'], 'p-1');
      expect(request.headers['X-Profile-Token'], 'ptok');
      expect(request.headers['X-Tofa-Client'], 'Plezilo');
      expect(request.headers['X-Tofa-Platform'], 'android');
      expect(request.headers['X-Tofa-Device-Name'], 'Test device');
    });

    test('the backend is Tofa and not a MediaBrowser server', () {
      final c = client();
      expect(c.backend, MediaBackend.tofa);
      expect(c.backend.usesMediaBrowserApi, isFalse);
      expect(c.backend.supportsDownloads, isFalse);
      expect(c.scopedServerId, 'srv-1/u-1/p-1');
      expect(c.serverId.value, 'srv-1');
    });
  });

  group('health', () {
    test('200 is online, 403 access denied, 5xx offline', () async {
      var status = 200;
      fake.on(
        'GET',
        '/api/v1/users/me',
        (_) => status == 200
            ? jsonResponse({'id': 'u-1', 'username': 'laura', 'disabled': false, 'preferences': {}})
            : tofaError(status, 'x'),
      );
      fake.on('GET', '/api/v1/auth/image-token', (_) => jsonResponse({'token': 'img', 'expires_in': 3600}));
      final c = client();
      expect(await c.checkHealth(), HealthStatus.online);
      status = 403;
      expect(await c.checkHealth(), HealthStatus.accessDenied);
      status = 502;
      expect(await c.checkHealth(), HealthStatus.offline);
    });

    test('a 401 whose refresh the cloud refuses is an auth error', () async {
      fake.on('GET', '/api/v1/users/me', (_) => tofaError(401, 'unauthorized'));
      fake.on('POST', '/servers/srv-1/device-token/refresh', (_) => jsonResponse({'error': 'invalid_grant'}, 401));
      expect(await client().checkHealth(), HealthStatus.authError);
      expect(fake.to('POST', '/servers/srv-1/device-token/refresh'), hasLength(1));
    });
  });

  group('token refresh', () {
    test('a 401 refreshes at the cloud, persists the rotated pair first, then resends with it', () async {
      final order = <String>[];
      fake.on('GET', '/api/v1/libraries', (request) {
        order.add('libraries ${request.headers['Authorization']}');
        return request.headers['Authorization'] == 'Bearer acc-2'
            ? jsonResponse(<Object>[])
            : tofaError(401, 'expired');
      });
      fake.on('POST', '/servers/srv-1/device-token/refresh', (request) {
        expect(jsonDecode(request.body), {'refresh_token': 'ref-1'});
        expect(request.headers['Authorization'], isNull, reason: 'the refresh token is the credential');
        order.add('refresh');
        return jsonResponse({
          'access_token': 'acc-2',
          'refresh_token': 'ref-2',
          'token_type': 'Bearer',
          'expires_in': 2592000,
        });
      });
      final c = client();
      c.onConnectionUpdated = (updated) {
        order.add('persist ${updated.accessToken}/${updated.refreshToken}');
      };
      await c.fetchLibraries();
      expect(order, ['libraries Bearer acc-1', 'refresh', 'persist acc-2/ref-2', 'libraries Bearer acc-2']);
      expect(c.connection.refreshToken, 'ref-2');
      expect(c.ownsRefreshToken('ref-1'), isTrue);
      expect(c.ownsRefreshToken('ref-2'), isTrue);
    });

    test('the rotated pair is not used before it is persisted', () async {
      final persisted = Completer<void>();
      var librariesWithNewToken = 0;
      fake.on('GET', '/api/v1/libraries', (request) {
        if (request.headers['Authorization'] == 'Bearer acc-2') {
          librariesWithNewToken++;
          expect(persisted.isCompleted, isTrue);
          return jsonResponse(<Object>[]);
        }
        return tofaError(401, 'expired');
      });
      fake.on(
        'POST',
        '/servers/srv-1/device-token/refresh',
        (_) =>
            jsonResponse({'access_token': 'acc-2', 'refresh_token': 'ref-2', 'token_type': 'Bearer', 'expires_in': 60}),
      );
      final c = client();
      c.onConnectionUpdated = (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        persisted.complete();
      };
      await c.fetchLibraries();
      expect(librariesWithNewToken, 1);
    });

    test('concurrent 401s share one refresh', () async {
      fake.on(
        'GET',
        '/api/v1/libraries',
        (request) =>
            request.headers['Authorization'] == 'Bearer acc-2' ? jsonResponse(<Object>[]) : tofaError(401, 'expired'),
      );
      fake.on(
        'GET',
        '/api/v1/users/me/continue',
        (request) =>
            request.headers['Authorization'] == 'Bearer acc-2' ? jsonResponse(<Object>[]) : tofaError(401, 'expired'),
      );
      fake.on(
        'POST',
        '/servers/srv-1/device-token/refresh',
        (_) =>
            jsonResponse({'access_token': 'acc-2', 'refresh_token': 'ref-2', 'token_type': 'Bearer', 'expires_in': 60}),
      );
      final c = client();
      await Future.wait([c.fetchLibraries(), c.fetchContinueWatching()]);
      expect(fake.to('POST', '/servers/srv-1/device-token/refresh'), hasLength(1));
    });

    test('a token with a day or less left is refreshed before the request', () async {
      fake.on('GET', '/api/v1/libraries', (_) => jsonResponse(<Object>[]));
      fake.on(
        'POST',
        '/servers/srv-1/device-token/refresh',
        (_) => jsonResponse({
          'access_token': 'acc-2',
          'refresh_token': 'ref-2',
          'token_type': 'Bearer',
          'expires_in': 2592000,
        }),
      );
      final c = client(connection: tofaConnection(accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 3))));
      await c.fetchLibraries();
      expect(fake.requests.map((r) => r.url.path), ['/servers/srv-1/device-token/refresh', '/api/v1/libraries']);
      expect(fake.requests.last.headers['Authorization'], 'Bearer acc-2');
    });
  });

  group('browsing', () {
    test('libraries are mapped in sort order', () async {
      fake.on(
        'GET',
        '/api/v1/libraries',
        (_) => jsonResponse([
          {'id': 'lib-2', 'name': 'Shows', 'media_type': 'tv', 'library_kind': 'tv', 'sort_order': 2},
          {'id': 'lib-1', 'name': 'Movies', 'media_type': 'movie', 'library_kind': 'movie', 'sort_order': 1},
        ]),
      );
      final libraries = await client().fetchLibraries();
      expect(libraries.map((l) => l.title), ['Movies', 'Shows']);
      expect(libraries.map((l) => l.kind), [MediaKind.movie, MediaKind.show]);
      expect(libraries.first.backend, MediaBackend.tofa);
    });

    test('offset paging maps onto page and per_page', () async {
      fake.on('GET', '/api/v1/media', (request) {
        final page = int.parse(request.url.queryParameters['page']!);
        final perPage = int.parse(request.url.queryParameters['per_page']!);
        return jsonResponse({
          'items': [for (var i = 0; i < perPage; i++) mediaSummary('m-${(page - 1) * perPage + i}')],
          'page': page,
          'per_page': perPage,
          'total': 95,
          'total_pages': 4,
        });
      });
      final page = await client().fetchLibraryPagedContent(
        'lib-1',
        query: const LibraryQuery(offset: 50, limit: 25, kind: MediaKind.movie),
      );
      final request = fake.requests.single;
      expect(request.url.queryParameters, containsPair('library_id', 'lib-1'));
      expect(request.url.queryParameters, containsPair('page', '3'));
      expect(request.url.queryParameters, containsPair('per_page', '25'));
      expect(request.url.queryParameters, containsPair('media_type', 'movie'));
      expect(request.url.queryParameters.containsKey('sort'), isFalse, reason: 'sort values are unverified');
      expect(page.items.first.id, 'm-50');
      expect(page.items, hasLength(25));
      expect(page.totalCount, 95);
      expect(page.offset, 50);
    });

    test('an offset between pages reads both pages and slices', () {
      expect(TofaClient.pagesFor(0, 50), [(page: 1, skip: 0)]);
      expect(TofaClient.pagesFor(100, 50), [(page: 3, skip: 0)]);
      expect(TofaClient.pagesFor(30, 20), [(page: 2, skip: 10), (page: 3, skip: 0)]);
    });

    test('a non-letter prefix is not guessed at: an empty page, no request', () async {
      final page = await client().fetchLibraryPagedContent('lib-1', query: const LibraryQuery(nameStartsWith: '#'));
      expect(page.items, isEmpty);
      expect(fake.requests, isEmpty);
    });

    test('a movie detail carries its files, artwork paths and watch state from the progress batch', () async {
      serveMovie(progress: [progressRow('f-1', positionMs: 120000)]);
      final item = await client().fetchItem('m-1');
      expect(item, isA<TofaMediaItem>());
      expect(item!.kind, MediaKind.movie);
      expect(item.title, 'A Movie');
      expect(item.viewOffsetMs, 120000);
      expect(item.isWatched, isFalse);
      expect(item.mediaVersions!.single.id, 'f-1');
      expect(TofaMappers.fileIdsOf(item), ['f-1']);
      expect(item.thumbPath, 'tofa-artwork:m-1/poster');
      expect(item.raw?[TofaRaw.imdbId], 'tt0000001');
      final batch = fake.to('POST', '/api/v1/media/progress/batch').single;
      expect(jsonDecode(batch.body), {
        'media_file_ids': ['f-1'],
      });
    });

    test('a missing item is null', () async {
      expect(await client().fetchItem('nope'), isNull);
    });

    test('a series lists seasons in order (specials last) and episodes with their watch state', () async {
      serveShow(progress: [progressRow('f-e1b', completed: true)]);
      final c = client();
      final seasons = await c.fetchChildren('show-1');
      expect(seasons.map((s) => s.index), [1, 0]);
      expect(seasons.first.id, 'tofa-season:show-1/sea-1');
      expect(seasons.first.viewedLeafCount, 1);
      final episodes = await c.fetchChildren(seasons.first.id);
      expect(episodes.map((e) => e.index), [1, 2]);
      expect(episodes.first.id, 'tofa-episode:show-1/e-1');
      expect(episodes.first.isWatched, isTrue);
      expect(episodes.first.grandparentTitle, 'A Show');
      expect(episodes.first.parentIndex, 1);
      expect(TofaMappers.fileIdsOf(episodes.first), ['f-e1a', 'f-e1b']);
      // One detail read serves the season and episode lists.
      expect(fake.to('GET', '/api/v1/media/show-1'), hasLength(1));
    });

    test('a season or episode id is fetched through its series', () async {
      serveShow();
      final episode = await client().fetchItem('tofa-episode:show-1/e-2');
      expect(episode!.kind, MediaKind.episode);
      expect(episode.title, 'Episode 2');
      final season = await client().fetchItem('tofa-season:show-1/sea-0');
      expect(season!.kind, MediaKind.season);
      expect(season.index, 0);
    });

    test('the on-deck episode is the series next_up, with its resume point', () async {
      serveShow(
        nextUp: {
          'episode_id': 'e-2',
          'season_id': 'sea-1',
          'media_file_id': 'f-e2',
          'position_ms': 5000,
          'kind': 'resume',
        },
      );
      final result = await client().fetchItemWithOnDeck('show-1');
      expect(result.item!.kind, MediaKind.show);
      expect(result.onDeckEpisode!.id, 'tofa-episode:show-1/e-2');
      expect(result.onDeckEpisode!.viewOffsetMs, 5000);
    });

    test('the episode queue leaves specials out', () async {
      serveShow();
      final queue = await client().fetchClientSideEpisodeQueue('show-1');
      expect(queue!.map((e) => e.id), ['tofa-episode:show-1/e-1', 'tofa-episode:show-1/e-2']);
    });

    test('Continue Watching keeps the server order and maps movies and episodes', () async {
      fake.on(
        'GET',
        '/api/v1/users/me/continue',
        (_) => jsonResponse([
          {
            'kind': 'resume',
            'media_id': 'm-1',
            'media_file_id': 'f-1',
            'title': 'A Movie',
            'position_ms': 60000,
            'duration_ms': 6000000,
            'genres': <String>[],
            'poster_path': '/p.jpg',
            'updated_at': '2026-11-20T10:00:00Z',
          },
          {
            'kind': 'next_up',
            'media_id': 'show-1',
            'media_file_id': 'f-e2',
            'episode_id': 'e-2',
            'season_id': 'sea-1',
            'season_number': 1,
            'episode_number': 2,
            'title': 'A Show',
            'episode_title': 'Episode 2',
            'position_ms': 0,
            'genres': <String>[],
            'updated_at': '2026-11-21T10:00:00Z',
          },
        ]),
      );
      final rows = await client().fetchContinueWatching();
      expect(rows.map((r) => r.kind), [MediaKind.movie, MediaKind.episode]);
      expect(rows.first.viewOffsetMs, 60000);
      expect(rows.last.id, 'tofa-episode:show-1/e-2');
      expect(rows.last.grandparentTitle, 'A Show');
      expect(rows.last.viewOffsetMs, isNull, reason: 'a next-up card has no resume point');
      expect(rows.first.recencySortKey, greaterThan(rows.last.recencySortKey));
    });

    test('search returns the movies list only, without discover titles', () async {
      fake.on('GET', '/api/v1/search', (request) {
        expect(request.url.queryParameters['q'], 'heat');
        return jsonResponse({
          'movies': [mediaSummary('m-9'), mediaSummary('show-9', type: 'tv')],
          'actors': <Object>[],
          'discover': [
            {'title': 'Not here'},
          ],
        });
      });
      final hits = await client().searchItems(' heat ');
      expect(hits.map((h) => h.kind), [MediaKind.movie, MediaKind.show]);
      expect(hits.first.libraryId, 'lib-1');
    });

    test('More Like This lists the owned similar titles', () async {
      fake.on(
        'GET',
        '/api/v1/media/m-1/similar',
        (_) => jsonResponse({
          'owned': [mediaSummary('m-2')],
          'requestable': <Object>[],
        }),
      );
      final hubs = await client().fetchRelatedHubs('m-1');
      expect(hubs.single.items.single.id, 'm-2');
    });
  });

  group('watch state', () {
    test('a movie is marked on each of its files', () async {
      fake.on('PUT', '/api/v1/media/f-1/watched', (_) => jsonResponse(progressRow('f-1', completed: true)));
      fake.on('PUT', '/api/v1/media/f-2/watched', (_) => jsonResponse(progressRow('f-2', completed: true)));
      serveMovie(files: [mediaFile('f-1'), mediaFile('f-2')]);
      final c = client();
      final movie = await c.fetchItem('m-1');
      await c.markWatched(movie!);
      expect(jsonDecode(fake.to('PUT', '/api/v1/media/f-1/watched').single.body), {'watched': true});
      expect(fake.to('PUT', '/api/v1/media/f-2/watched'), hasLength(1));
    });

    test('seasons and shows use their own routes', () async {
      fake.on('PUT', '/api/v1/seasons/sea-1/watched', (_) => jsonResponse(<String, dynamic>{}));
      fake.on('PUT', '/api/v1/shows/show-1/watched', (_) => jsonResponse(<String, dynamic>{}));
      final c = client();
      await c.markUnwatched(
        MediaItem(id: 'tofa-season:show-1/sea-1', backend: MediaBackend.tofa, kind: MediaKind.season),
      );
      await c.markWatched(MediaItem(id: 'show-1', backend: MediaBackend.tofa, kind: MediaKind.show));
      expect(jsonDecode(fake.to('PUT', '/api/v1/seasons/sea-1/watched').single.body), {'watched': false});
      expect(jsonDecode(fake.to('PUT', '/api/v1/shows/show-1/watched').single.body), {'watched': true});
    });

    test('Continue Watching removal dismisses the title', () async {
      fake.on('POST', '/api/v1/users/me/dismiss/show-1', (_) => http.Response('', 204));
      await client().removeFromContinueWatching(
        MediaItem(
          id: 'tofa-episode:show-1/e-2',
          backend: MediaBackend.tofa,
          kind: MediaKind.episode,
          raw: {TofaRaw.mediaId: 'show-1'},
        ),
      );
      expect(fake.to('POST', '/api/v1/users/me/dismiss/show-1'), hasLength(1));
    });
  });

  group('artwork', () {
    test('artwork goes through the artwork route with the image token, never the bearer', () async {
      fake.on('GET', '/api/v1/auth/image-token', (_) => jsonResponse({'token': 'img-tok', 'expires_in': 3600}));
      final c = client();
      expect(c.thumbnailUrl('tofa-artwork:m-1/poster'), '', reason: 'no URL the server would refuse');
      await c.ensureImageTokenForTesting();
      final url = Uri.parse(c.thumbnailUrl('tofa-artwork:m-1/poster', width: 300, height: 450));
      expect(url.toString(), startsWith('$tofaBase/api/v1/artwork/m-1/poster?'));
      expect(url.queryParameters, {'st': 'img-tok', 'w': '300', 'h': '450'});
      expect(c.streamHeaders, isEmpty);
      // An undocumented raw path is not guessed at.
      expect(c.thumbnailUrl('/posters/m-1.jpg'), '');
      expect(c.thumbnailUrl('https://images.example.com/a.jpg'), 'https://images.example.com/a.jpg');
    });
  });

  group('playback', () {
    void serveVersions(String? recommended) => fake.on(
      'GET',
      '/api/v1/media/m-1/versions',
      (_) => jsonResponse({'recommended_media_file_id': recommended, 'versions': <Object>[]}),
    );

    test('with several files, the recommended one plays; never the first by position', () async {
      serveMovie(files: [mediaFile('f-1'), mediaFile('f-2')]);
      serveVersions('f-2');
      final c = client();
      final movie = await c.fetchItem('m-1');
      expect(await c.chooseFile(movie!), 'f-2');
      final versions = fake.to('GET', '/api/v1/media/m-1/versions').single;
      expect(versions.url.queryParameters['direct_play_video_codecs'], contains('h264'));
    });

    test('with several files and no recommendation, nothing is picked', () async {
      serveMovie(files: [mediaFile('f-1'), mediaFile('f-2')]);
      serveVersions(null);
      final c = client();
      final movie = await c.fetchItem('m-1');
      await expectLater(c.chooseFile(movie!), throwsA(isA<PlaybackException>()));
    });

    test('a requested file wins when it is one of the item\'s', () async {
      serveMovie(files: [mediaFile('f-1'), mediaFile('f-2')]);
      final c = client();
      final movie = await c.fetchItem('m-1');
      expect(await c.chooseFile(movie!, requestedFileId: 'f-1'), 'f-1');
      expect(fake.to('GET', '/api/v1/media/m-1/versions'), isEmpty);
    });

    test('an episode asks for the series versions with season and episode', () async {
      serveShow();
      fake.on(
        'GET',
        '/api/v1/media/show-1/versions',
        (_) => jsonResponse({'recommended_media_file_id': 'f-e1b', 'versions': <Object>[]}),
      );
      final c = client();
      final episode = await c.fetchItem('tofa-episode:show-1/e-1');
      expect(await c.chooseFile(episode!), 'f-e1b');
      final q = fake.to('GET', '/api/v1/media/show-1/versions').single.url.queryParameters;
      expect(q['season'], '1');
      expect(q['episode'], '1');
    });

    Future<(TofaClient, PlaybackInitializationResult)> start({
      Map<String, dynamic>? info,
      Duration? startPosition,
    }) async {
      serveMovie();
      fake.on('GET', '/api/v1/stream/f-1/info', (_) => jsonResponse(info ?? playbackInfo()));
      final c = client();
      final movie = await c.fetchItem('m-1');
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: movie!, selectedMediaIndex: 0, startPosition: startPosition),
      );
      return (c, result);
    }

    test('negotiates with the device capabilities, the resume point in ticks and the client headers', () async {
      final (_, result) = await start(startPosition: const Duration(minutes: 2));
      final request = fake.to('GET', '/api/v1/stream/f-1/info').single;
      final q = request.url.queryParameters;
      expect(q['resume_ticks'], '${2 * 60 * 10000000}');
      expect(q['direct_play_video_codecs'], contains('h264'));
      expect(q['direct_play_audio_codecs'], contains('eac3'));
      expect(q['include_text_subtitles'], 'true');
      expect(request.headers['X-Tofa-Client'], 'Plezilo');
      expect(request.headers['X-Profile-Id'], 'p-1');
      expect(result.videoUrl, '$tofaBase/api/v1/stream/f-1/file.mkv?st=stream-token');
      expect(result.playSessionId, 'sid-1');
      expect(result.playMethod, 'DirectPlay');
      expect(result.selectedMediaSourceId, 'f-1');
      expect(result.isTranscoding, isFalse);
    });

    test('tracks come from the answer; an original file gets only its external text track as a sidecar', () async {
      final (c, result) = await start();
      final info = result.mediaInfo!;
      expect(info.audioTracks.map((a) => a.id), [1, 2]);
      expect(info.audioTracks.where((a) => a.selected).single.language, 'fra');
      expect(result.activeAudioStreamId, 2);
      expect(info.subtitleTracks.map((s) => s.id), [1, 2, 3]);
      expect(result.subtitleSidecars.single.sourceStreamId, 2);
      expect(result.subtitleSidecars.single.track.uri, c.subtitleSidecarUrl('sid-1', 1, 'sess-tok'));
      expect(
        c.subtitleSidecarUrl('sid-1', 1, 'sess-tok'),
        '$tofaBase/api/v1/stream/s/sid-1/subtitles/1/full.vtt?st=sess-tok',
      );
    });

    test('a transcode gets every text track as a sidecar and no bitmap track', () async {
      final (_, result) = await start(
        info: playbackInfo(playMethod: 'Transcode', streamUrl: 'https://relay.example.com/m.m3u8?st=x'),
      );
      expect(result.isTranscoding, isTrue);
      expect(result.videoUrl, 'https://relay.example.com/m.m3u8?st=x');
      expect(result.subtitleSidecars.map((s) => s.sourceStreamId), [1, 2]);
      expect(result.mediaInfo!.subtitleTracks.map((s) => s.id), [1, 2]);
    });

    test('a 503 shows the server\'s message', () async {
      serveMovie();
      fake.on(
        'GET',
        '/api/v1/stream/f-1/info',
        (_) => tofaError(503, 'server_relay_not_connected', 'Your server is offline.'),
      );
      final c = client();
      final movie = await c.fetchItem('m-1');
      await expectLater(
        c.getPlaybackInitialization(PlaybackInitializationOptions(metadata: movie!, selectedMediaIndex: 0)),
        throwsA(isA<PlaybackException>().having((e) => e.message, 'message', 'Your server is offline.')),
      );
    });

    test('progress goes to the session in ticks with its st token; a 410 stops reporting', () async {
      final (c, _) = await start();
      var progressStatus = 204;
      fake.on('POST', '/api/v1/stream/s/sid-1/progress', (_) => http.Response('', progressStatus));
      fake.on('POST', '/api/v1/stream/s/sid-1/stopped', (_) => http.Response('', 204));
      await c.reportPlaybackProgress(
        itemId: 'm-1',
        position: const Duration(seconds: 10),
        duration: const Duration(minutes: 100),
        isPaused: true,
        playSessionId: 'sid-1',
      );
      final first = fake.to('POST', '/api/v1/stream/s/sid-1/progress').single;
      expect(first.url.queryParameters['st'], 'sess-tok');
      expect(first.headers['Authorization'], isNull, reason: 'the session token is the credential');
      expect(jsonDecode(first.body), {'position_ticks': 100000000, 'is_paused': true, 'ended': false});

      progressStatus = 410;
      await c.reportPlaybackProgress(
        itemId: 'm-1',
        position: const Duration(seconds: 20),
        duration: const Duration(minutes: 100),
        playSessionId: 'sid-1',
      );
      expect(c.isSessionLive('sid-1'), isFalse);
      await c.reportPlaybackProgress(
        itemId: 'm-1',
        position: const Duration(seconds: 30),
        duration: const Duration(minutes: 100),
        playSessionId: 'sid-1',
      );
      expect(fake.to('POST', '/api/v1/stream/s/sid-1/progress'), hasLength(2), reason: 'nothing after the 410');
      expect(fake.to('GET', '/api/v1/stream/f-1/info'), hasLength(1), reason: 'the session is not restarted');
    });

    test('closing posts the last position, then stopped', () async {
      final (c, _) = await start();
      fake.on('POST', '/api/v1/stream/s/sid-1/progress', (_) => http.Response('', 204));
      fake.on('POST', '/api/v1/stream/s/sid-1/stopped', (_) => http.Response('', 204));
      await c.reportPlaybackStopped(
        itemId: 'm-1',
        position: const Duration(minutes: 99, seconds: 59),
        duration: const Duration(minutes: 100),
        playSessionId: 'sid-1',
      );
      final paths = fake.requests.map((r) => r.url.path).toList();
      expect(paths.sublist(paths.length - 2), ['/api/v1/stream/s/sid-1/progress', '/api/v1/stream/s/sid-1/stopped']);
      expect(jsonDecode(fake.to('POST', '/api/v1/stream/s/sid-1/progress').single.body)['ended'], isTrue);
      expect(fake.to('POST', '/api/v1/stream/s/sid-1/stopped').single.url.queryParameters['st'], 'sess-tok');
      expect(c.isSessionLive('sid-1'), isFalse);
    });

    test('a stop sent after a 410 still releases the session', () async {
      final (c, _) = await start();
      fake.on('POST', '/api/v1/stream/s/sid-1/progress', (_) => tofaError(410, 'gone'));
      fake.on('POST', '/api/v1/stream/s/sid-1/stopped', (_) => http.Response('', 204));
      await c.reportPlaybackProgress(
        itemId: 'm-1',
        position: const Duration(seconds: 5),
        duration: const Duration(minutes: 100),
        playSessionId: 'sid-1',
      );
      await c.reportPlaybackStopped(itemId: 'm-1', position: const Duration(seconds: 6), playSessionId: 'sid-1');
      expect(fake.to('POST', '/api/v1/stream/s/sid-1/progress'), hasLength(1));
      expect(fake.to('POST', '/api/v1/stream/s/sid-1/stopped'), hasLength(1));
    });

    test('a report without a session saves the position on the file', () async {
      final (c, _) = await start();
      fake.on('PUT', '/api/v1/media/f-1/progress', (_) => jsonResponse(progressRow('f-1')));
      await c.reportPlaybackStopped(
        itemId: 'm-1',
        position: const Duration(seconds: 90),
        duration: const Duration(minutes: 100),
      );
      expect(jsonDecode(fake.to('PUT', '/api/v1/media/f-1/progress').single.body), {
        'position_ms': 90000,
        'ended': false,
      });
    });
  });

  test('unsupported members answer empty or throw UnsupportedError', () async {
    final c = client();
    expect(await c.fetchPlaylistsPage(), isA<LibraryPage<Object>>().having((p) => p.items, 'items', isEmpty));
    expect(await c.searchPeople('x'), isEmpty);
    expect(await c.fetchSortOptions('lib-1'), isEmpty);
    expect(
      await c.resolveExternalPlayback(MediaItem(id: 'm-1', backend: MediaBackend.tofa, kind: MediaKind.movie)),
      isNull,
    );
    expect(
      () => c.resolveDownload(MediaItem(id: 'm-1', backend: MediaBackend.tofa, kind: MediaKind.movie)),
      throwsUnsupportedError,
    );
    expect(
      () => c.rate(MediaItem(id: 'm-1', backend: MediaBackend.tofa, kind: MediaKind.movie), 5),
      throwsUnsupportedError,
    );
    expect(fake.requests, isEmpty);
  });
}
