import 'dart:convert';

import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_audiobook.dart';
import 'package:plezy/services/silo/silo_audiobook_player.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_mappers.dart';

import '../../test_helpers/silo_audiobook_fakes.dart';

final _ctx = SiloMappingContext(
  serverId: 'srv-1',
  serverName: 'Home Silo',
  resolveUrl: (url) => url.startsWith('/') ? 'https://silo.example.com$url' : url,
);

/// A two-part book in Siku's mock shape (and Silo's contract): parts are
/// `audiobook_part` versions with part indexes and per-part chapters.
Map<String, dynamic> _bookDetail({double position = 0, bool played = false}) => {
  'content_id': 'audiobook:orbit',
  'type': 'audiobook',
  'title': 'The Long Orbit',
  'year': 2023,
  'overview': 'A story.',
  'poster_url': '/img/book.jpg',
  'duration_seconds': 700,
  'versions': [
    {
      'file_id': 'b12',
      'codec_audio': 'aac',
      'container': 'm4b',
      'duration': 400,
      'presentation_kind': 'audiobook_part',
      'presentation_group_key': 'default',
      'presentation_part_index': 2,
      'chapters': [
        {'index': 0, 'title': '3', 'start_seconds': 0, 'end_seconds': 250},
        {'index': 1, 'title': 'The Return', 'start_seconds': 250, 'end_seconds': 400},
      ],
    },
    {
      'file_id': 'b11',
      'codec_audio': 'aac',
      'container': 'm4b',
      'duration': 300,
      'presentation_kind': 'audiobook_part',
      'presentation_group_key': 'default',
      'presentation_part_index': 1,
      'chapters': [
        {'index': 0, 'title': 'Launch', 'start_seconds': 0, 'end_seconds': 100},
        {'index': 1, 'title': '', 'start_seconds': 100, 'end_seconds': 300},
      ],
    },
  ],
  'user_data': {'position_seconds': position, 'played': played, 'last_file_id': 'b11'},
  'audiobook': {
    'authors': [
      {'name': 'Ava Thornton', 'person_id': '100'},
    ],
    'narrators': [
      {'name': 'Ben Ode', 'person_id': '101'},
    ],
    'total_duration_seconds': 700,
    'publisher': 'Mock House Audio',
    'series': {'name': 'Orbit Cycle', 'entries': []},
  },
};

SiloAudiobookDetail _detail({double position = 0}) =>
    SiloAudiobookDetail.parse(_bookDetail(position: position), resolveUrl: _ctx.resolveUrl);

void main() {
  group('mapping', () {
    test('an audiobook card maps to an album with its authors and progress', () {
      final item = SiloMappers.item({
        'content_id': 'audiobook:orbit',
        'type': 'audiobook',
        'title': 'The Long Orbit',
        'duration_seconds': 7200,
        'position_seconds': 1800,
        'authors': ['Ava Thornton', 'Sam Lee'],
        'poster_url': '/img/book.jpg',
      }, _ctx)!;
      expect(item.kind, MediaKind.album);
      expect(item.backend, MediaBackend.silo);
      expect(item.albumArtistTitle, 'Ava Thornton, Sam Lee');
      expect(item.durationMs, 7200000);
      expect(item.viewOffsetMs, 1800000);
      expect(item.thumbPath, 'https://silo.example.com/img/book.jpg');
      expect(SiloMappers.isAudiobook(item), isTrue);
    });

    test('a detail takes authors from the audiobook object and its total length', () {
      final json = _bookDetail()..remove('duration_seconds');
      final item = SiloMappers.item(json, _ctx)!;
      expect(item.albumArtistTitle, 'Ava Thornton');
      expect(item.durationMs, 700000);
    });

    test('music, podcasts and reading items stay unmapped', () {
      for (final type in ['ebook', 'manga', 'podcast', 'podcast_episode', 'track', 'album', 'artist']) {
        expect(SiloMappers.item({'content_id': 'x:1', 'type': type}, _ctx), isNull, reason: type);
      }
      final movie = SiloMappers.item({'content_id': 'movie:m', 'type': 'movie'}, _ctx)!;
      expect(SiloMappers.isAudiobook(movie), isFalse);
    });

    test('audiobook libraries are shown, music and reading libraries are not', () {
      expect(SiloMappers.isShownLibraryType('audiobooks'), isTrue);
      expect(SiloMappers.isShownLibraryType('Audiobook'), isTrue);
      expect(SiloMappers.isShownLibraryType('movies'), isTrue);
      for (final type in ['music', 'albums', 'ebooks', 'manga', 'comics', 'podcasts', 'reading', 'whatever']) {
        expect(SiloMappers.isShownLibraryType(type), isFalse, reason: type);
      }
      final library = SiloMappers.library({'id': '4', 'name': 'Audiobooks', 'type': 'audiobooks'}, _ctx)!;
      expect(library.kind, MediaKind.album);
      expect(library.defaultBrowseKinds, [MediaKind.album]);
      expect(SiloMappers.catalogType(MediaKind.album), 'audiobook');
    });
  });

  group('timeline', () {
    test('parts are ordered by part index and chapters placed on the book timeline', () {
      final timeline = _detail().timeline!;
      expect(timeline.parts.map((p) => p.fileId), ['b11', 'b12']);
      expect(timeline.parts.map((p) => p.offsetSeconds), [0, 300]);
      expect(timeline.totalSeconds, 700);
      expect(timeline.chapters.map((c) => c.startSeconds), [0, 100, 300, 550]);
      expect(timeline.chapters.map((c) => c.title), ['Launch', 'Chapter 2', 'Chapter 3', 'The Return']);
      expect(timeline.chapters.map((c) => c.partIndex), [0, 0, 1, 1]);
      expect(timeline.isSinglePart, isFalse);
    });

    test('a variant present in every part is chosen', () {
      final versions = <Map<String, dynamic>>[
        {
          'file_id': 'mp3-1',
          'duration': 10,
          'presentation_kind': 'audiobook_part',
          'presentation_group_key': 'mp3',
          'presentation_part_index': 1,
        },
        {
          'file_id': 'm4b-1',
          'duration': 10,
          'presentation_kind': 'audiobook_part',
          'presentation_group_key': 'm4b',
          'presentation_part_index': 1,
        },
        {
          'file_id': 'm4b-2',
          'duration': 10,
          'presentation_kind': 'audiobook_part',
          'presentation_group_key': 'm4b',
          'presentation_part_index': 2,
        },
      ];
      expect(SiloAudiobookTimeline.audioParts(versions).map((v) => v['file_id']), ['m4b-1', 'm4b-2']);
      // The preferred file's variant wins when it is complete.
      final complete = [
        ...versions,
        {
          'file_id': 'mp3-2',
          'duration': 10,
          'presentation_kind': 'audiobook_part',
          'presentation_group_key': 'mp3',
          'presentation_part_index': 2,
        },
      ];
      expect(SiloAudiobookTimeline.audioParts(complete, preferredFileId: 'mp3-2').map((v) => v['file_id']), [
        'mp3-1',
        'mp3-2',
      ]);
    });

    test('a single file without part indexes is the whole book; its duration may come from chapters', () {
      final timeline = SiloAudiobookTimeline.build([
        {'file_id': 'video', 'codec_video': 'h264'},
        {
          'file_id': 'f1',
          'codec_audio': 'aac',
          'chapters': [
            {'start_seconds': 0, 'end_seconds': 60},
            {'start_seconds': 60, 'end_seconds': 90},
          ],
        },
      ])!;
      expect(timeline.parts.single.fileId, 'f1');
      expect(timeline.totalSeconds, 90);
      expect(timeline.isSinglePart, isTrue);
      expect(
        SiloAudiobookTimeline.build([
          {'file_id': 'video', 'codec_video': 'h264'},
        ]),
        isNull,
      );
    });

    test('book time maps to a part and a part-local time', () {
      final timeline = _detail().timeline!;
      expect(timeline.partAt(0).index, 0);
      expect(timeline.partAt(299.9).index, 0);
      expect(timeline.partAt(300).index, 1);
      expect(timeline.partAt(9999).index, 1);
      expect(SiloAudiobookTimeline.localTime(timeline.parts[1], 450), 150);
      expect(SiloAudiobookTimeline.localTime(timeline.parts[1], 100), 0);
      expect(timeline.clamp(-5), 0);
      expect(timeline.clamp(1000), 700);
    });

    test('chapter navigation follows Silo\'s rules', () {
      final timeline = _detail().timeline!;
      expect(timeline.chapterIndexAt(0), 0);
      expect(timeline.chapterIndexAt(100), 1); // a boundary belongs to the later chapter
      expect(timeline.chapterIndexAt(699), 3);
      expect(timeline.nextChapterTarget(50), 100);
      expect(timeline.nextChapterTarget(600), 550); // last chapter: its own start
      expect(timeline.previousChapterTarget(310), 300); // 10 s in: restart it
      expect(timeline.previousChapterTarget(302), 100); // 2 s in: the previous one
      expect(timeline.previousChapterTarget(2), 0); // the first: its start
      expect(timeline.chapterProgress(200), closeTo(0.5, 1e-9));
    });

    test('resume starts at the recorded position unless the book is finished', () {
      expect(_detail(position: 450).resumeSeconds, 450);
      expect(_detail(position: 0).resumeSeconds, 0);
      expect(_detail(position: 698).resumeSeconds, 0);
      final detail = _detail(position: 120);
      expect(detail.authors, ['Ava Thornton']);
      expect(detail.narrators, ['Ben Ode']);
      expect(detail.seriesName, 'Orbit Cycle');
      expect(detail.coverUrl, 'https://silo.example.com/img/book.jpg');
      expect(detail.lastFileId, 'b11');
    });
  });

  group('session rules (#708)', () {
    test('a forgotten session is told apart from other 404s', () {
      expect(SiloAudiobookSessionRules.isSessionMissing(404, {'code': 'playback_session_not_found'}), isTrue);
      expect(
        SiloAudiobookSessionRules.isSessionMissing(404, {
          'type': 'https://siloserver.org/docs/api/v2/problems/playback_session_not_found',
        }),
        isTrue,
      );
      expect(SiloAudiobookSessionRules.isSessionMissing(404, {'detail': 'Playback session not found'}), isTrue);
      expect(SiloAudiobookSessionRules.isSessionMissing(404, {'detail': 'Source media file is missing'}), isFalse);
      expect(SiloAudiobookSessionRules.isSessionMissing(410, {'code': 'playback_session_not_found'}), isFalse);
      expect(SiloAudiobookSessionRules.isSessionEnded(410, {'code': 'playback_session_ended'}), isTrue);
      expect(SiloAudiobookSessionRules.isSessionEnded(410, {'code': 'gone'}), isFalse);
    });

    test('progress answers decide what happens to the session', () {
      const missing = {'code': 'playback_session_not_found'};
      SiloAudiobookSessionAction action(int status, Object? problem, {bool paused = false, int renewals = 0}) =>
          SiloAudiobookSessionRules.progressAction(
            status: status,
            problem: problem,
            paused: paused,
            renewals: renewals,
          );
      expect(action(204, null), SiloAudiobookSessionAction.none);
      expect(action(410, {'code': 'playback_session_ended'}), SiloAudiobookSessionAction.ended);
      expect(action(404, missing), SiloAudiobookSessionAction.renew);
      expect(action(404, missing, paused: true), SiloAudiobookSessionAction.renewOnPlay);
      expect(action(404, missing, renewals: 3), SiloAudiobookSessionAction.stopReporting);
      expect(action(404, {'detail': 'Source media file is missing'}), SiloAudiobookSessionAction.stopReporting);
      expect(action(410, {'code': 'other'}), SiloAudiobookSessionAction.stopReporting);
      expect(action(500, null), SiloAudiobookSessionAction.none);
      expect(action(0, null), SiloAudiobookSessionAction.none);
    });

    test('Play retries after an error unless the server ended the session', () {
      expect(SiloAudiobookSessionRules.canRetry(hasError: true, endedByServer: false, closing: false), isTrue);
      expect(SiloAudiobookSessionRules.canRetry(hasError: true, endedByServer: true, closing: false), isFalse);
      expect(SiloAudiobookSessionRules.canRetry(hasError: true, endedByServer: false, closing: true), isFalse);
      expect(SiloAudiobookSessionRules.canRetry(hasError: false, endedByServer: false, closing: false), isFalse);
    });
  });

  group('client', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late List<http.Request> requests;

    setUp(() {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      SiloApiCache.initialize(db);
      requests = [];
    });

    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    SiloClient client(Future<http.Response> Function(http.Request request) handler) => SiloClient.forTesting(
      SiloConnection(
        id: 'srv-1/1/p-owner',
        baseUrl: 'https://silo.example.com',
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
      ),
      headers: const SiloDeviceHeaders(
        deviceId: 'dev-1',
        deviceName: 'Test',
        platform: 'linux',
        clientFamily: 'desktop',
        clientVersion: '1.0',
      ),
      httpClient: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
    );

    test('libraries list audiobooks next to video, without music or reading', () async {
      final c = client(
        (_) async => json({
          'items': [
            {'id': '1', 'name': 'Movies', 'type': 'movies'},
            {'id': '3', 'name': 'Music', 'type': 'music'},
            {'id': '4', 'name': 'Audiobooks', 'type': 'audiobooks'},
            {'id': '5', 'name': 'Books', 'type': 'ebooks'},
            {'id': '6', 'name': 'Manga', 'type': 'manga'},
            {'id': '7', 'name': 'Podcasts', 'type': 'podcasts'},
          ],
        }),
      );
      final libraries = await c.fetchLibraries();
      expect(libraries.map((l) => l.title), ['Movies', 'Audiobooks']);
      expect(libraries.last.kind, MediaKind.album);
    });

    test('an audiobook library browses type=audiobook and maps the books', () async {
      final c = client(
        (_) async => json({
          'items': [
            {'content_id': 'audiobook:orbit', 'type': 'audiobook', 'title': 'The Long Orbit'},
          ],
          'page': {'has_more': false},
          'total': 1,
        }),
      );
      final page = await c.fetchLibraryPagedContent(
        '4',
        query: const LibraryQuery(offset: 0, limit: 50),
        libraryKind: MediaKind.album,
      );
      expect(requests.single.url.queryParameters['type'], 'audiobook');
      expect(page.items.single.kind, MediaKind.album);
    });

    test('a part starts with client-owned progress and the original audio stream', () async {
      Map<String, dynamic>? startBody;
      final c = client((request) async {
        final path = request.url.path;
        if (path.endsWith('/playback/capabilities')) {
          return json({
            'state': 'available',
            'allowed': true,
            'installation_id': 'inst-1',
            'protocol_versions': [3],
            'features': ['sequenced_progress_v1'],
          });
        }
        if (path.endsWith('/playback/start')) {
          startBody = jsonDecode(request.body) as Map<String, dynamic>;
          return json({
            'outcome': 'playable',
            'session_id': 'sess-a',
            'playback_plan': {
              'delivery': 'original_http',
              'stream': {'url': '/api/v2/stream/sess-a?st=sig'},
            },
          }, 201);
        }
        if (path.endsWith('/playback/sess-a/progress')) {
          return http.Response(
            jsonEncode({'code': 'playback_session_not_found', 'status': 404}),
            404,
            headers: {'content-type': 'application/problem+json'},
          );
        }
        if (path.endsWith('/sync/progress')) return json({'items': []});
        if (path.endsWith('/catalog/items/audiobook%3Aorbit') || path.endsWith('/catalog/items/audiobook:orbit')) {
          return json(_bookDetail(position: 42));
        }
        return json({}, 204);
      });
      final backend = c.audiobooks;

      final detail = await backend.fetchAudiobook('audiobook:orbit');
      expect(detail.timeline!.parts.length, 2);
      expect(detail.positionSeconds, 42);

      final stream = await backend.startPart('b11', localStartSeconds: 120);
      expect(startBody!['file_id'], 'b11');
      expect(startBody!['progress_persistence'], 'client');
      expect(startBody!['quality_preference'], 'original');
      expect(startBody!['start_position'], 0);
      expect((startBody!['client_capabilities'] as Map)['containers'], containsAll(['m4b', 'mp3', 'flac']));
      final original = ((startBody!['client_playback_context'] as Map)['deliveries'] as Map)['original_http'] as Map;
      expect(original['containers'], contains('m4b'));
      expect(stream.sessionId, 'sess-a');
      expect(stream.url, 'https://silo.example.com/api/v2/stream/sess-a?st=sig');
      expect(stream.headers['Authorization'], 'Bearer acc-1');

      final answer = await backend.sendProgress(stream, 130.5, paused: false);
      expect(answer.status, 404);
      expect(SiloAudiobookSessionRules.isSessionMissing(answer.status, answer.problem), isTrue);
      final progress = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(progress, {'installation_id': 'inst-1', 'sequence': 1, 'position': 130.5, 'is_paused': false});

      await backend.syncBookProgress('audiobook:orbit', 430.5, 700);
      final sync = jsonDecode(requests.last.body) as Map<String, dynamic>;
      final entry = (sync['items'] as List).single as Map;
      expect(requests.last.url.path, endsWith('/sync/progress'));
      expect(entry['media_item_id'], 'audiobook:orbit');
      expect(entry['position_ms'], 430500);
      expect(entry['duration_ms'], 700000);

      await backend.stopPart(stream, 131);
      expect(requests.last.method, 'DELETE');
      final stop = jsonDecode(requests.last.body) as Map<String, dynamic>;
      expect(stop['position'], 131);
      expect(stop['stop_id'], isNotEmpty);
    });
  });

  group('player', () {
    late FakeSiloAudiobookBackend backend;
    late FakeSiloAudiobookEngine engine;

    SiloAudiobookPlayer player({double position = 0}) {
      backend = FakeSiloAudiobookBackend(_detail(position: position));
      engine = FakeSiloAudiobookEngine();
      return SiloAudiobookPlayer(
        backend: backend,
        detail: backend.detail,
        engineFactory: () => engine,
        claimAudio: () async {},
      );
    }

    test('starts the part holding the resume point at its local time', () {
      fakeAsync((async) {
        final p = player(position: 450);
        p.start();
        async.flushMicrotasks();
        expect(backend.starts, [('b12', 150.0)]);
        expect(engine.opened.single, ('https://silo/b12/1', const Duration(seconds: 150), true));
        expect(p.isPlaying, isTrue);
        expect(p.bookSeconds, 450);
        engine.positionTo(const Duration(seconds: 160));
        expect(p.bookSeconds, 460);
        expect(p.currentChapter!.title, 'Chapter 3');
        p.dispose();
        async.flushMicrotasks();
      });
    });

    test('reports part-local progress and the whole-book position every 10 s', () {
      fakeAsync((async) {
        final p = player(position: 450);
        p.start();
        async.flushMicrotasks();
        engine.positionTo(const Duration(seconds: 155));
        async.elapse(const Duration(seconds: 10));
        expect(backend.progress.single, ('sess-1', 155.0, false));
        expect(backend.syncs.last, (455.0, 700.0));
        p.dispose();
        async.flushMicrotasks();
        // Closing stops the session at the position.
        expect(backend.stops.last, ('sess-1', 155.0));
      });
    });

    test('a session forgotten while playing is replaced at the position', () {
      fakeAsync((async) {
        final p = player(position: 450);
        p.start();
        async.flushMicrotasks();
        engine.positionTo(const Duration(seconds: 170));
        backend.nextProgress = const SiloAudiobookProgressAnswer(404, {'code': 'playback_session_not_found'});
        async.elapse(const Duration(seconds: 10));
        expect(backend.starts, [('b12', 150.0), ('b12', 170.0)]);
        expect(engine.opened.last.$2, const Duration(seconds: 170));
        expect(p.renewals, 1);
        // The expired session is not stopped: the server has forgotten it.
        expect(backend.stops, isEmpty);
        // A good answer resets the count.
        async.elapse(const Duration(seconds: 10));
        expect(p.renewals, 0);
        p.dispose();
        async.flushMicrotasks();
      });
    });

    test('renewing stops after three fresh sessions in a row', () {
      fakeAsync((async) {
        final p = player(position: 450);
        p.start();
        async.flushMicrotasks();
        backend.alwaysProgress = const SiloAudiobookProgressAnswer(404, {'code': 'playback_session_not_found'});
        async.elapse(const Duration(seconds: 50));
        expect(backend.starts.length, 4); // the first + 3 renewals
        expect(p.renewals, 3);
        final reports = backend.progress.length;
        async.elapse(const Duration(seconds: 30));
        expect(backend.progress.length, reports); // no more reports
        p.dispose();
        async.flushMicrotasks();
      });
    });

    test('a session forgotten while paused is replaced when Play is pressed', () {
      fakeAsync((async) {
        final p = player(position: 450);
        p.start();
        async.flushMicrotasks();
        engine.positionTo(const Duration(seconds: 180));
        backend.nextProgress = const SiloAudiobookProgressAnswer(404, {'code': 'playback_session_not_found'});
        p.pause();
        async.flushMicrotasks();
        expect(backend.progress.last, ('sess-1', 180.0, true));
        expect(p.sessionExpired, isTrue);
        expect(backend.starts.length, 1);
        p.play();
        async.flushMicrotasks();
        expect(backend.starts.last, ('b12', 180.0));
        expect(p.isPlaying, isTrue);
        expect(p.sessionExpired, isFalse);
        p.dispose();
        async.flushMicrotasks();
      });
    });

    test('a session an administrator ended stops playback and is never restarted', () {
      fakeAsync((async) {
        final p = player(position: 450);
        p.start();
        async.flushMicrotasks();
        backend.nextProgress = const SiloAudiobookProgressAnswer(410, {'code': 'playback_session_ended'});
        async.elapse(const Duration(seconds: 10));
        expect(p.endedByServer, isTrue);
        expect(p.error, isNotNull);
        expect(p.isPlaying, isFalse);
        expect(p.canRetry, isFalse);
        expect(engine.stopped, isTrue);
        p.play();
        p.seekTo(10);
        async.flushMicrotasks();
        expect(backend.starts.length, 1);
        p.dispose();
        async.flushMicrotasks();
        expect(backend.stops, isEmpty); // no DELETE: it is already over
      });
    });

    test('after a playback error Play starts again where playback was', () {
      fakeAsync((async) {
        final p = player(position: 450);
        p.start();
        async.flushMicrotasks();
        engine.positionTo(const Duration(seconds: 200));
        engine.fail('stream broke');
        async.flushMicrotasks();
        expect(p.error, isNotNull);
        expect(p.canRetry, isTrue);
        expect(p.bookSeconds, 500);
        p.play();
        async.flushMicrotasks();
        expect(backend.starts.last, ('b12', 200.0));
        expect(p.error, isNull);
        p.dispose();
        async.flushMicrotasks();
      });
    });

    test('a failed start can be retried from the same position', () {
      fakeAsync((async) {
        final p = player(position: 450);
        backend.failNextStart = true;
        p.start();
        async.flushMicrotasks();
        expect(p.canRetry, isTrue);
        expect(p.bookSeconds, 450);
        p.togglePlay();
        async.flushMicrotasks();
        expect(backend.starts.last, ('b12', 150.0));
        expect(p.isPlaying, isTrue);
        p.dispose();
        async.flushMicrotasks();
      });
    });

    test('the end of a part opens the next one; the end of the book finishes it', () {
      fakeAsync((async) {
        final p = player(position: 250);
        p.start();
        async.flushMicrotasks();
        expect(backend.starts.single, ('b11', 250.0));
        engine.complete();
        async.flushMicrotasks();
        expect(backend.starts.last, ('b12', 0.0));
        expect(backend.stops.last.$1, 'sess-1');
        engine.complete();
        async.flushMicrotasks();
        expect(p.isFinished, isTrue);
        expect(p.bookSeconds, 700);
        expect(backend.syncs.last, (700.0, 700.0));
        p.play(); // listen again from the start
        async.flushMicrotasks();
        expect(backend.starts.last, ('b11', 0.0));
        p.dispose();
        async.flushMicrotasks();
      });
    });

    test('seeks stay in the part or move to another part; chapters and speed', () {
      fakeAsync((async) {
        final p = player(position: 50);
        p.start();
        async.flushMicrotasks();
        p.seekTo(200);
        async.flushMicrotasks();
        expect(engine.seeks.last, const Duration(seconds: 200));
        expect(backend.starts.length, 1);
        p.nextChapter(); // from 200 (chapter 2) to 300: part 2
        async.flushMicrotasks();
        expect(backend.starts.last, ('b12', 0.0));
        expect(p.bookSeconds, 300);
        p.setSpeed(1.5);
        async.flushMicrotasks();
        expect(engine.rate, 1.5);
        p.previousChapter(); // at the chapter start: the previous chapter, back in part 1
        async.flushMicrotasks();
        expect(backend.starts.last, ('b11', 100.0));
        expect(engine.rate, 1.5); // speed survives a new part
        p.jumpToChapter(3);
        async.flushMicrotasks();
        expect(backend.starts.last, ('b12', 250.0));
        p.skip(-30);
        async.flushMicrotasks();
        expect(engine.seeks.last, const Duration(seconds: 220));
        p.dispose();
        async.flushMicrotasks();
      });
    });
  });
}
