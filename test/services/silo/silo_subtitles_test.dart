import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_subtitles.dart';
import 'package:plezy/widgets/video_controls/models/silo_subtitle_tools.dart';
import 'package:plezy/widgets/video_controls/models/track_controls_state.dart';
import 'package:plezy/widgets/video_controls/silo/silo_ai_subtitle_controller.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection() => SiloConnection(
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
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

http.Response _problem(int status, String code, {String? detail}) => http.Response(
  jsonEncode({
    'type': 'https://siloserver.org/docs/api/v2/problems/$code',
    'title': code,
    'status': status,
    'detail': ?detail,
  }),
  status,
  headers: {'content-type': 'application/problem+json'},
);

Map<String, Object?> _job(String status, {double progress = 0, String? result}) => {
  'job': {'id': 'j1', 'status': status, 'progress': progress, 'result_subtitle_id': result},
};

final _movie = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie, serverId: 'srv-1');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;
  // Answers for paths the playback fake does not know; null → 404.
  late FutureOr<http.Response?> Function(http.Request request, String path) extra;

  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
    requests = [];
    extra = (_, _) => null;
  });

  SiloClient client() => SiloClient.forTesting(
    _connection(),
    headers: _headers,
    httpClient: MockClient((request) async {
      requests.add(request);
      final path = Uri.decodeComponent(request.url.path);
      if (path.endsWith('/watch/movie:m1')) {
        return _json({
          'content_id': 'movie:m1',
          'type': 'movie',
          'versions': [
            {
              'file_id': '42',
              'audio_tracks': [
                {'index': 0, 'language': 'eng', 'codec': 'eac3', 'channels': 6, 'default': true},
                {'index': 1, 'language': 'jpn', 'codec': 'aac', 'channels': 2},
              ],
              'subtitle_tracks': [
                {'index': 0, 'language': 'eng', 'codec': 'srt', 'external': true},
                {'index': 1, 'language': 'eng', 'codec': 'hdmv_pgs_subtitle'},
              ],
            },
          ],
        });
      }
      if (path.endsWith('/playback/capabilities')) {
        return _json({
          'state': 'available',
          'allowed': true,
          'installation_id': 'inst-1',
          'protocol_versions': [3],
          'features': ['sequenced_progress_v1'],
        });
      }
      if (path.endsWith('/playback/start')) {
        return _json({
          'protocol_version': 3,
          'outcome': 'playable',
          'session_id': 'sess-1',
          'playback_plan': {
            'delivery': 'original_http',
            'stream': {'url': '/api/v2/stream/sess-1?st=sig'},
            'selected_tracks': {
              'audio': {'index': 1},
            },
            'subtitle': {
              'inventory': [
                {
                  'combined_index': 0,
                  'source': 'external',
                  'codec': 'srt',
                  'language': 'eng',
                  'delivery': 'sidecar',
                  'url': '/api/v2/stream/sess-1/subtitles/0.vtt?file_id=42&external_subtitle_key=abc',
                },
                {
                  'combined_index': 1,
                  'source': 'embedded',
                  'codec': 'hdmv_pgs_subtitle',
                  'language': 'eng',
                  'delivery': 'sidecar',
                  'url': '/api/v2/stream/sess-1/subtitles/1.sup?file_id=42',
                },
                {
                  'combined_index': 2,
                  'source': 'downloaded',
                  'codec': 'srt',
                  'language': 'fr',
                  'label': 'Movie.FR (opensubtitles)',
                  'sync_key': 'stored-7',
                  'delivery': 'sidecar',
                  'url': '/api/v2/stream/sess-1/subtitles/2.vtt?file_id=42&downloaded_subtitle_id=7',
                },
              ],
            },
          },
        }, 201);
      }
      final answer = await extra(request, path);
      return answer ?? _json({}, 404);
    }),
  );

  Future<SiloClient> playing() async {
    final c = client();
    await c.getPlaybackInitialization(PlaybackInitializationOptions(metadata: _movie, selectedMediaIndex: 0));
    return c;
  }

  Map<String, dynamic> body(http.Request request) => jsonDecode(request.body) as Map<String, dynamic>;

  group('rules', () {
    test('stored subtitle ids come from the sync key or the sidecar URL', () {
      expect(SiloSubtitleRules.storedId({'sync_key': 'stored-12'}), '12');
      expect(SiloSubtitleRules.storedId({'url': '/s/3.vtt?file_id=1&downloaded_subtitle_id=9&x=1'}), '9');
      expect(SiloSubtitleRules.storedId({'sync_key': 'external-abc'}), isNull);
      expect(SiloSubtitleRules.storedTrackId('7'), SiloSubtitleRules.storedTrackIdBase + 7);
      expect(SiloSubtitleRules.storedTrackId('abc'), isNull);
      expect(SiloSubtitleRules.storedTrackId('0'), isNull);
    });

    test('translatable tracks: embedded text, external and stored SRT/VTT', () {
      expect(SiloSubtitleRules.isTranslatable({'source': 'embedded', 'codec': 'subrip'}), isTrue);
      expect(SiloSubtitleRules.isTranslatable({'source': 'embedded', 'codec': 'ass'}), isTrue);
      expect(SiloSubtitleRules.isTranslatable({'source': 'embedded', 'codec': 'hdmv_pgs_subtitle'}), isFalse);
      expect(SiloSubtitleRules.isTranslatable({'source': 'external', 'codec': 'srt'}), isTrue);
      expect(SiloSubtitleRules.isTranslatable({'source': 'external', 'codec': 'ass'}), isFalse);
      expect(SiloSubtitleRules.isTranslatable({'source': 'downloaded', 'codec': 'webvtt'}), isTrue);
    });

    test('transcribe kind: no translation when the audio is already in the target', () {
      expect(
        SiloSubtitleRules.transcribeKind(audioLanguage: 'eng', target: 'en', canTranslate: true),
        SiloAiJobKind.transcribe,
      );
      expect(
        SiloSubtitleRules.transcribeKind(audioLanguage: 'jpn', target: 'en', canTranslate: true),
        SiloAiJobKind.transcribeTranslate,
      );
      expect(
        SiloSubtitleRules.transcribeKind(audioLanguage: 'jpn', target: 'en', canTranslate: false),
        SiloAiJobKind.transcribe,
      );
      expect(SiloSubtitleRules.twoLetter('en-US'), 'en');
      expect(SiloSubtitleRules.twoLetter('ger'), 'de');
    });
  });

  group('playback', () {
    test('subtitles stored on the server are offered on direct play under a stable id', () async {
      final c = client();
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: _movie, selectedMediaIndex: 0),
      );
      final storedTrackId = SiloSubtitleRules.storedTrackIdBase + 7;
      final stored = result.mediaInfo!.subtitleTracks.where((t) => t.id == storedTrackId).single;
      expect(stored.language, 'fr');
      expect(stored.title, 'Movie.FR (opensubtitles)');
      expect(stored.usesExternalDelivery, isTrue);
      // The external file and the stored one are sidecars; the embedded
      // bitmap track is in the file.
      expect(result.subtitleSidecars.map((s) => s.sourceStreamId), [1, storedTrackId]);
      expect(result.subtitleSidecars.last.track.uri, contains('downloaded_subtitle_id=7'));
    });

    test('the AI sheet sees the playing session, its translatable tracks and audio', () async {
      final c = await playing();
      final context = c.aiPlaybackContext('movie:m1')!;
      expect(context.sessionId, 'sess-1');
      expect(context.fileId, '42');
      expect(context.subtitleSources.map((s) => s.combinedIndex), [0, 2]);
      expect(context.audioSources.map((a) => a.index), [0, 1]);
      expect(context.selectedAudioIndex, 1);
      expect(c.aiPlaybackContext('movie:other'), isNull);
    });
  });

  group('AI jobs', () {
    test('a job names the playback session (Silo Android #726)', () async {
      extra = (request, path) => path.endsWith('/subtitles/ai/translate') ? _json(_job('pending'), 202) : null;
      final c = await playing();
      final started = await c.startAiJob(
        context: c.aiPlaybackContext('movie:m1')!,
        kind: SiloAiJobKind.transcribeTranslate,
        sourceIndex: 1,
        sourceLanguage: 'jpn',
        targetLanguage: 'en',
        startPositionSeconds: 12.5,
      );
      expect(started.id, 'j1');
      final sent = requests.where((r) => r.url.path.endsWith('/subtitles/ai/translate')).toList();
      expect(sent, hasLength(1));
      expect(body(sent.single), {
        'media_file_id': '42',
        'kind': 'transcribe_translate',
        'source_index': 1,
        'source_language': 'jpn',
        'target_language': 'en',
        'start_position': 12.5,
        'session_id': 'sess-1',
      });
    });

    test('a 404 for the session is sent once more without it', () async {
      extra = (request, path) {
        if (!path.endsWith('/subtitles/ai/translate')) return null;
        return body(request).containsKey('session_id')
            ? _problem(404, 'playback_session_not_found')
            : _json(_job('pending'), 202);
      };
      final c = await playing();
      await c.startAiJob(
        context: c.aiPlaybackContext('movie:m1')!,
        kind: SiloAiJobKind.translate,
        sourceIndex: 0,
        sourceLanguage: 'eng',
        targetLanguage: 'fr',
        startPositionSeconds: 0,
      );
      final sent = requests.where((r) => r.url.path.endsWith('/subtitles/ai/translate')).map(body).toList();
      expect(sent.map((b) => b['session_id']), ['sess-1', null]);
    });

    test('other refusals are not resent and carry the server detail', () async {
      extra = (request, path) => path.endsWith('/subtitles/ai/translate')
          ? _problem(422, 'ai_not_configured', detail: 'AI subtitle processing is not configured')
          : null;
      final c = await playing();
      await expectLater(
        c.startAiJob(
          context: c.aiPlaybackContext('movie:m1')!,
          kind: SiloAiJobKind.translate,
          sourceIndex: 0,
          sourceLanguage: 'eng',
          targetLanguage: 'fr',
          startPositionSeconds: 0,
        ),
        throwsA(
          isA<SiloSubtitleException>()
              .having((e) => e.statusCode, 'status', 422)
              .having((e) => e.message, 'message', 'AI subtitle processing is not configured'),
        ),
      );
      expect(requests.where((r) => r.url.path.endsWith('/subtitles/ai/translate')), hasLength(1));
    });

    test('a job that is gone reads as null', () async {
      final c = client();
      expect(await c.fetchAiJob('j9'), isNull);
    });

    test('status: off unless available, allowed and enabled; a failed read is asked again', () async {
      var answers = 0;
      extra = (request, path) {
        if (!path.endsWith('/subtitles/ai/status')) return null;
        answers++;
        return answers == 1
            ? _problem(500, 'internal')
            : _json({'state': 'available', 'allowed': true, 'enabled': false, 'transcribe_enabled': true});
      };
      final c = client();
      expect((await c.aiStatus()).available, isFalse);
      final status = await c.aiStatus();
      expect(status.translate, isFalse);
      expect(status.transcribe, isTrue);
      await c.aiStatus();
      expect(answers, 2);
    });
  });

  group('search and download', () {
    test('search lists hits and warnings; download returns the stored id', () async {
      extra = (request, path) {
        if (path.endsWith('/subtitles/search')) {
          return _json({
            'results': [
              {
                'id': 's1',
                'provider': 'opensubtitles',
                'language': 'fr',
                'release_name': 'Movie.FR',
                'score': 92.5,
                'hearing_impaired': true,
              },
              {'id': '', 'provider': 'x'},
            ],
            'warnings': [
              {'detail': 'podnapisi is not configured'},
            ],
          });
        }
        if (path.endsWith('/subtitles/download')) {
          return _json({
            'subtitle': {'id': '7', 'format': 'srt'},
          });
        }
        return null;
      };
      final c = client();
      final results = await c.searchServerSubtitles(fileId: '42', languages: ['fr']);
      expect(results.hits.single.key, 'opensubtitles:s1');
      expect(results.warnings, ['podnapisi is not configured']);
      expect(body(requests.last), {
        'media_file_id': '42',
        'languages': ['fr'],
      });

      expect(await c.downloadServerSubtitle(fileId: '42', hit: results.hits.single), '7');
      expect(body(requests.last), {
        'media_file_id': '42',
        'provider': 'opensubtitles',
        'subtitle_id': 's1',
        'language': 'fr',
        'release_name': 'Movie.FR',
        'score': 92.5,
        'hearing_impaired': true,
      });
    });
  });

  group('controller', () {
    test('runs a job to completion and loads its subtitle into the player', () async {
      var reads = 0;
      extra = (request, path) {
        if (path.endsWith('/subtitles/ai/status')) {
          return _json({'state': 'available', 'allowed': true, 'enabled': true, 'transcribe_enabled': true});
        }
        if (path.endsWith('/subtitles/ai/quota')) return _json({'limited': false});
        if (path.endsWith('/subtitles/ai/translate')) return _json(_job('pending'), 202);
        if (path.endsWith('/subtitles/ai/jobs/j1')) {
          reads++;
          return _json(reads < 2 ? _job('running', progress: 0.4) : _job('completed', progress: 1, result: '11'));
        }
        return null;
      };
      final c = await playing();
      fakeAsync((async) {
        final applied = <String>[];
        final messages = <String>[];
        final tools = SiloSubtitleTools(
          client: c,
          itemId: 'movie:m1',
          position: () => const Duration(seconds: 30),
          isCurrent: () => true,
          applyStored: (id) async {
            applied.add(id);
            return SubtitleDownloadApplyOutcome.applied;
          },
          notify: (message, {error = false}) => messages.add(message),
        );
        final controller = SiloAiSubtitleController.of(tools);
        controller.open(preferredTarget: 'fr');
        async.flushMicrotasks();
        expect(controller.targetCode, 'fr');
        expect(controller.fromSubtitles, isTrue);

        controller.submit();
        async.flushMicrotasks();
        expect(controller.phase, SiloAiPhase.running);
        final sent = body(requests.lastWhere((r) => r.url.path.endsWith('/subtitles/ai/translate')));
        expect(sent['session_id'], 'sess-1');
        expect(sent['start_position'], 30.0);
        expect(sent['kind'], 'translate');

        async.elapse(SiloAiSubtitleController.pollInterval);
        expect(controller.job?.progress, 0.4);
        async.elapse(SiloAiSubtitleController.pollInterval);
        expect(applied, ['11']);
        expect(controller.phase, SiloAiPhase.idle);
        expect(messages, hasLength(1));
        controller.dispose();
      });
    });
  });
}
