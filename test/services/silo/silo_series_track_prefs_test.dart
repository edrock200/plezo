import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/mpv/player/player_stream_controllers.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_series_track_choices.dart';
import 'package:plezy/services/silo/silo_track_prefs.dart';
import 'package:plezy/services/source_track_pick_sink.dart';
import 'package:plezy/services/track_manager.dart';
import 'package:plezy/services/track_selection_service.dart';

import '../../test_helpers/media_items.dart';
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

final _episode = MediaItem.silo(id: 'episode:e1', kind: MediaKind.episode, serverId: 'srv-1');
final _movie = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie, serverId: 'srv-1');

const _externalEnglish = {
  'source': 'external',
  'language': 'eng',
  'codec': 'srt',
  'label': 'English',
  'forced': false,
  'hearing_impaired': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SiloTrackPrefs', () {
    test('only episodes of a series have a key', () {
      expect(SiloTrackPrefs.seriesKey({'type': 'episode', 'series_id': 'series:s1'}), 'series:s1');
      expect(SiloTrackPrefs.seriesKey({'type': 'movie', 'content_id': 'movie:m1'}), isNull);
      expect(SiloTrackPrefs.seriesKey({'type': 'episode'}), isNull);
      expect(SiloTrackPrefs.seriesKey(null), isNull);
      expect(SiloTrackPrefs.audioPath('series:s1'), '/api/v2/audio-prefs/series%3As1');
      expect(SiloTrackPrefs.subtitlePath('series:s1'), '/api/v2/subtitle-prefs/series%3As1');
    });

    test('bodies follow the server contract', () {
      expect(
        SiloTrackPrefs.audioBody({
          'language': 'jpn',
          'codec': 'aac',
          'channels': 2,
          'layout': 'stereo',
          'title': ' ',
          'default': false,
        }, 1),
        {
          'audio_track_index': 1,
          'audio_language': 'jpn',
          'track_signature': {'language': 'jpn', 'codec': 'aac', 'layout': 'stereo', 'channels': 2},
        },
      );
      // Unknown languages are never sent as a language (the server refuses them).
      expect(SiloTrackPrefs.audioBody({'language': 'und'}, 0), {
        'audio_track_index': 0,
        'track_signature': {'language': 'und'},
      });
      expect(SiloTrackPrefs.serverLanguageTag('English'), 'en');
      expect(SiloTrackPrefs.serverLanguageTag('Português'), isNull);
      expect(SiloTrackPrefs.subtitleOffBody(), {
        'subtitle_language': '',
        'subtitle_track_index': -1,
        'subtitle_mode': 'off',
      });
      expect(
        SiloTrackPrefs.subtitleBody({
          'combined_index': 3,
          'source': 'external',
          'language': 'eng',
          'codec': 'srt',
          'label': 'English SDH',
        }),
        {
          'subtitle_language': 'eng',
          'subtitle_track_index': 3,
          'subtitle_mode': 'always',
          'track_signature': {
            'source': 'external',
            'language': 'eng',
            'codec': 'srt',
            'label': 'English SDH',
            'forced': false,
            'hearing_impaired': true,
          },
        },
      );
    });

    test('an unsent audio choice resolves by signature, then position, then language', () {
      final tracks = [
        {'language': 'en', 'codec': 'eac3', 'channels': 6},
        {'language': 'ja', 'codec': 'aac', 'channels': 2},
        {'language': 'ja', 'codec': 'flac', 'channels': 2},
      ];
      final body = SiloTrackPrefs.audioBody({'language': 'jpn', 'codec': 'flac', 'channels': 2}, 0);
      expect(SiloTrackPrefs.resolveAudioBody(body, tracks), 2);
      expect(SiloTrackPrefs.resolveAudioBody({'audio_track_index': 1, 'audio_language': 'ja'}, tracks), 1);
      expect(SiloTrackPrefs.resolveAudioBody({'audio_track_index': 0, 'audio_language': 'ja'}, tracks), 1);
      expect(SiloTrackPrefs.resolveAudioBody({'audio_track_index': 0}, tracks), isNull);
    });

    const english = SiloSubtitleCandidate(id: 1, source: 'external', language: 'eng', codec: 'srt', label: 'English');
    const englishSdh = SiloSubtitleCandidate(
      id: 2,
      source: 'embedded',
      language: 'en',
      codec: 'subrip',
      label: 'English SDH',
      hearingImpaired: true,
    );
    const forcedEnglish = SiloSubtitleCandidate(
      id: 3,
      source: 'embedded',
      language: 'en',
      codec: 'subrip',
      forced: true,
    );
    const french = SiloSubtitleCandidate(id: 4, source: 'embedded', language: 'fr', codec: 'subrip');
    final candidates = [english, englishSdh, forcedEnglish, french];

    test('the series signature wins over the language rules, unless subtitles are off', () {
      final start = SiloTrackPrefs.resolveSubtitle(
        candidates,
        const SiloSubtitleStartPrefs(language: 'fr', mode: 'always', signature: _externalEnglish),
        audioLanguage: 'en',
      );
      expect(start.trackId, 1);
      final off = SiloTrackPrefs.resolveSubtitle(
        candidates,
        const SiloSubtitleStartPrefs(mode: 'off', signature: _externalEnglish),
        audioLanguage: 'en',
      );
      expect(off.off, isTrue);
    });

    test('off still shows the forced track in the audio language when forced subtitles are on', () {
      final start = SiloTrackPrefs.resolveSubtitle(
        candidates,
        const SiloSubtitleStartPrefs(mode: 'off', showForced: true),
        audioLanguage: 'eng',
      );
      expect(start.trackId, 3);
    });

    test('auto: off when the audio is already in the language; else the best track in it', () {
      expect(
        SiloTrackPrefs.resolveSubtitle(
          candidates,
          const SiloSubtitleStartPrefs(language: 'en', mode: 'auto'),
          audioLanguage: 'en',
        ).off,
        isTrue,
      );
      // Embedded before external, plain before SDH.
      expect(
        SiloTrackPrefs.resolveSubtitle(
          [english, englishSdh, french],
          const SiloSubtitleStartPrefs(language: 'en', mode: 'auto'),
          audioLanguage: 'ja',
        ).trackId,
        1,
      );
      // A signature that matches no track exactly still ranks by its traits.
      expect(
        SiloTrackPrefs.resolveSubtitle(
          [english, englishSdh, french],
          const SiloSubtitleStartPrefs(
            language: 'en',
            mode: 'always',
            signature: {'source': 'embedded', 'language': 'en', 'codec': 'ass', 'hearing_impaired': true},
          ),
        ).trackId,
        2,
      );
      // No language and mode auto: Plezy's own ladder decides.
      expect(SiloTrackPrefs.resolveSubtitle(candidates, const SiloSubtitleStartPrefs()).isNoChange, isTrue);
      expect(SiloTrackPrefs.resolveSubtitle(const [], const SiloSubtitleStartPrefs(mode: 'off')).isNoChange, isTrue);
    });

    test('an unsent pick is laid over the effective fields', () {
      final watch = {
        'effective_subtitle_language': 'en',
        'effective_subtitle_mode': 'always',
        'effective_subtitle_track_signature': _externalEnglish,
      };
      final off = SiloTrackPrefs.subtitlePrefs(watch, pending: SiloTrackPrefs.subtitleOffBody());
      expect(off.mode, 'off');
      expect(off.signature, isNull);
      final french = SiloTrackPrefs.subtitlePrefs(
        watch,
        pending: SiloTrackPrefs.subtitleBody({
          'combined_index': 4,
          'source': 'embedded',
          'language': 'fr',
          'codec': 'srt',
        }),
      );
      expect(french.language, 'fr');
      expect(french.signature?['source'], 'embedded');
    });
  });

  group('SiloSeriesTrackChoices', () {
    test('picks are debounced: only the last one is sent, once', () {
      fakeAsync((async) {
        final sent = <(String, Map<String, Object?>)>[];
        final choices = SiloSeriesTrackChoices(send: (path, body) async => sent.add((path, body)));
        choices.saveAudio('series:s1', {'audio_track_index': 0});
        async.elapse(const Duration(milliseconds: 500));
        choices.saveAudio('series:s1', {'audio_track_index': 1});
        expect(choices.pendingAudio('series:s1'), {'audio_track_index': 1});
        async.elapse(const Duration(milliseconds: 1400));
        expect(sent, isEmpty);
        async.elapse(const Duration(milliseconds: 200));
        expect(sent.single.$1, '/api/v2/audio-prefs/series%3As1');
        expect(sent.single.$2, {'audio_track_index': 1});
        expect(choices.pendingAudio('series:s1'), isNull);
        async.elapse(const Duration(minutes: 1));
        expect(sent, hasLength(1));
      });
    });

    test('a pick made while one is in flight goes out after it', () {
      fakeAsync((async) {
        final sent = <Map<String, Object?>>[];
        final gate = Completer<void>();
        final choices = SiloSeriesTrackChoices(
          send: (path, body) async {
            sent.add(body);
            if (sent.length == 1) await gate.future;
          },
        );
        choices.saveSubtitle('series:s1', SiloTrackPrefs.subtitleOffBody());
        async.elapse(const Duration(seconds: 2));
        choices.saveSubtitle('series:s1', {'subtitle_mode': 'always', 'subtitle_track_index': 2});
        async.elapse(const Duration(seconds: 2));
        expect(sent, hasLength(1));
        gate.complete();
        async.flushMicrotasks();
        expect(sent, hasLength(2));
        expect(sent.last['subtitle_track_index'], 2);
        expect(choices.pendingSubtitle('series:s1'), isNull);
      });
    });

    test('a transient failure is kept and retried once; a refusal is dropped', () {
      fakeAsync((async) {
        var calls = 0;
        final choices = SiloSeriesTrackChoices(
          send: (path, body) async {
            calls++;
            if (path.contains('audio')) {
              throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: 503, message: 'x');
            }
            throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: 422, message: 'x');
          },
        );
        choices.saveAudio('series:s1', {'audio_track_index': 1});
        choices.saveSubtitle('series:s1', SiloTrackPrefs.subtitleOffBody());
        async.elapse(const Duration(seconds: 2));
        expect(calls, 2);
        expect(choices.pendingAudio('series:s1'), isNotNull);
        expect(choices.pendingSubtitle('series:s1'), isNull);
        async.elapse(const Duration(seconds: 15));
        expect(calls, 3);
        async.elapse(const Duration(minutes: 5));
        expect(calls, 3);
        // Still offered to the next start until it expires.
        expect(choices.pendingAudio('series:s1'), isNotNull);
        async.elapse(const Duration(minutes: 6));
        expect(choices.pendingAudio('series:s1'), isNull);
      });
    });
  });

  group('SiloSeriesTrackChoices hand-over and close', () {
    test('closeGracefully sends a pick still in its debounce, then nothing more', () {
      fakeAsync((async) {
        final sent = <Map<String, Object?>>[];
        final choices = SiloSeriesTrackChoices(send: (path, body) async => sent.add(body));
        choices.saveAudio('series:s1', {'audio_track_index': 1});
        async.elapse(const Duration(milliseconds: 200));
        unawaited(choices.closeGracefully(timeout: const Duration(seconds: 2)));
        async.flushMicrotasks();
        expect(sent, [
          {'audio_track_index': 1},
        ]);
        choices.saveAudio('series:s1', {'audio_track_index': 2});
        async.elapse(const Duration(minutes: 1));
        expect(sent, hasLength(1));
      });
    });

    test('takePending moves picks to a successor, which sends them; its own newer pick wins', () {
      fakeAsync((async) {
        final oldSent = <Map<String, Object?>>[];
        final newSent = <(String, Map<String, Object?>)>[];
        final previous = SiloSeriesTrackChoices(send: (path, body) async => oldSent.add(body));
        final next = SiloSeriesTrackChoices(send: (path, body) async => newSent.add((path, body)));
        previous.saveAudio('series:s1', {'audio_track_index': 1});
        previous.saveSubtitle('series:s1', SiloTrackPrefs.subtitleOffBody());
        next.saveSubtitle('series:s1', {'subtitle_mode': 'always', 'subtitle_track_index': 3});
        next.adopt(previous.takePending());
        expect(previous.hasPending, isFalse);
        unawaited(previous.closeGracefully());
        async.elapse(const Duration(seconds: 2));
        expect(oldSent, isEmpty);
        expect(newSent.map((s) => s.$2), [
          {'subtitle_mode': 'always', 'subtitle_track_index': 3},
          {'audio_track_index': 1},
        ]);
      });
    });
  });

  group('SiloClient playback', () {
    late List<http.Request> requests;
    late String type;
    late Map<String, Object?> effective;
    late int putStatus;

    setUp(() {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      SiloApiCache.initialize(db);
      requests = [];
      type = 'episode';
      putStatus = 204;
      effective = {
        'effective_subtitle_language': 'en',
        'effective_subtitle_mode': 'always',
        'effective_show_forced_subtitles': false,
        'effective_subtitle_track_signature': _externalEnglish,
      };
    });

    SiloClient client() => SiloClient.forTesting(
      _connection(),
      headers: _headers,
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = Uri.decodeComponent(request.url.path);
        if (path.contains('/watch/')) {
          return _json({
            'content_id': type == 'episode' ? 'episode:e1' : 'movie:m1',
            'type': type,
            if (type == 'episode') 'series_id': 'series:s1',
            ...effective,
            'versions': [
              {
                'file_id': '42',
                'effective_audio_track_index': 1,
                'audio_tracks': [
                  {'language': 'en', 'codec': 'eac3', 'channels': 6, 'default': true},
                  {'language': 'ja', 'codec': 'aac', 'channels': 2, 'title': 'Japanese'},
                ],
                'subtitle_tracks': [
                  {'index': 0, 'language': 'eng', 'codec': 'srt', 'external': true, 'title': 'English'},
                  {'index': 1, 'language': 'eng', 'codec': 'subrip', 'title': 'English SDH', 'hearing_impaired': true},
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
            'session_id': 'sess-${requests.length}',
            'playback_plan': {
              'delivery': 'original_http',
              'stream': {'url': '/api/v2/stream/s?st=sig'},
              'subtitle': {
                'inventory': [
                  {
                    'combined_index': 0,
                    'source': 'external',
                    'codec': 'srt',
                    'language': 'eng',
                    'label': 'English',
                    'delivery': 'sidecar',
                    'url': '/api/v2/stream/s/subtitles/0.vtt?file_id=42',
                  },
                  {
                    'combined_index': 1,
                    'source': 'embedded',
                    'codec': 'subrip',
                    'language': 'eng',
                    'label': 'English SDH',
                    'hearing_impaired': true,
                    'delivery': 'sidecar',
                    'url': '/api/v2/stream/s/subtitles/1.vtt?file_id=42',
                  },
                ],
              },
            },
          }, 201);
        }
        if (request.method == 'PUT' && path.contains('-prefs/')) return http.Response('', putStatus);
        return _json({}, 404);
      }),
    );

    List<http.Request> puts() => requests.where((r) => r.method == 'PUT').toList();

    test('an episode starts with the series audio and subtitle choice', () async {
      final c = client();
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: _episode, selectedMediaIndex: 0),
      );
      final info = result.mediaInfo!;
      expect(info.audioTracks.map((t) => t.selected), [false, true]);
      expect(result.activeAudioStreamId, 2);
      expect(info.subtitleTracks.where((t) => t.selected).map((t) => t.id), [1]);
      // The player's ladder takes the server's selection.
      final service = TrackSelectionService(metadata: _episode, plexMediaInfo: info);
      final picked = service.selectSubtitleTrack(
        [
          const SubtitleTrack(id: '1', language: 'eng', codec: 'srt', title: 'English', isExternal: true),
          const SubtitleTrack(id: '2', language: 'eng', codec: 'subrip', title: 'English SDH'),
        ],
        null,
        null,
      );
      expect(picked?.priority, TrackSelectionPriority.serverSelected);
      c.close();
    });

    test('a series set to Off starts with subtitles off', () async {
      effective = {'effective_subtitle_mode': 'off', 'effective_show_forced_subtitles': false};
      final c = client();
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: _episode, selectedMediaIndex: 0),
      );
      final info = result.mediaInfo!;
      expect(info.defaultSubtitleStreamIndex, -1);
      final picked = TrackSelectionService(
        metadata: _episode,
        plexMediaInfo: info,
      ).selectSubtitleTrack([const SubtitleTrack(id: '1', language: 'eng', codec: 'srt', isDefault: true)], null, null);
      expect(picked?.track.id, SubtitleTrack.off.id);
      c.close();
    });

    test("a movie starts with the profile's effective audio and subtitle, with no series to write", () async {
      type = 'movie';
      final c = client();
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: _movie, selectedMediaIndex: 0),
      );
      final info = result.mediaInfo!;
      // The same effective fields an episode gets (the profile's defaults on a movie).
      expect(info.audioTracks.map((t) => t.selected), [false, true]);
      expect(info.subtitleTracks.where((t) => t.selected).map((t) => t.id), [1]);
      c.seriesTrackPickSink(_movie.id).audioPicked(2);
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(puts(), isEmpty, reason: 'a movie has no series preference to write');
      c.close();
    });

    test('a movie whose profile says Off starts with subtitles off', () async {
      type = 'movie';
      effective = {'effective_subtitle_mode': 'off', 'effective_show_forced_subtitles': false};
      final c = client();
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: _movie, selectedMediaIndex: 0),
      );
      expect(result.mediaInfo!.defaultSubtitleStreamIndex, -1);
      c.close();
    });

    test('a pick in the player is written to the series once', () async {
      final c = client();
      await c.getPlaybackInitialization(PlaybackInitializationOptions(metadata: _episode, selectedMediaIndex: 0));
      final sink = c.seriesTrackPickSink(_episode.id);
      sink.audioPicked(1);
      sink.audioPicked(2);
      sink.subtitlePicked(2);
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      final sent = puts();
      expect(sent.map((r) => r.url.path), ['/api/v2/audio-prefs/series%3As1', '/api/v2/subtitle-prefs/series%3As1']);
      expect(sent.first.headers['x-profile-id'], 'p-owner');
      expect(jsonDecode(sent.first.body), {
        'audio_track_index': 1,
        'audio_language': 'ja',
        'track_signature': {'language': 'ja', 'title': 'Japanese', 'codec': 'aac', 'channels': 2},
      });
      final subtitle = jsonDecode(sent.last.body) as Map<String, dynamic>;
      expect(subtitle['subtitle_track_index'], 1);
      expect(subtitle['subtitle_mode'], 'always');
      expect((subtitle['track_signature'] as Map)['hearing_impaired'], isTrue);
      c.close();
    });

    test('a pick still queued when the client closes gracefully is sent before the API closes', () async {
      final c = client();
      await c.getPlaybackInitialization(PlaybackInitializationOptions(metadata: _episode, selectedMediaIndex: 0));
      c.seriesTrackPickSink(_episode.id).audioPicked(1);
      await c.closeGracefully();
      expect(puts().map((r) => r.url.path), ['/api/v2/audio-prefs/series%3As1']);
    });

    test('a successor on the same login session sends the queued pick instead of the closing client', () async {
      final c = client();
      await c.getPlaybackInitialization(PlaybackInitializationOptions(metadata: _episode, selectedMediaIndex: 0));
      c.seriesTrackPickSink(_episode.id).audioPicked(1);
      final successor = client();
      successor.inheritSession(c);
      await c.closeGracefully();
      expect(puts(), isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(puts().map((r) => r.url.path), ['/api/v2/audio-prefs/series%3As1']);
      successor.close();
    });

    test('a failing write never affects playback, and the unsent pick still applies', () async {
      putStatus = 500;
      final c = client();
      await c.getPlaybackInitialization(PlaybackInitializationOptions(metadata: _episode, selectedMediaIndex: 0));
      c.seriesTrackPickSink(_episode.id).subtitlePicked(null);
      await Future<void>.delayed(const Duration(milliseconds: 1700));
      expect(puts(), hasLength(1));
      // The next episode starts (the start resends the pick first, which
      // fails again) and still plays, with the pick laid over the answer.
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: _episode, selectedMediaIndex: 0),
      );
      expect(result.videoUrl, isNotEmpty);
      expect(puts(), hasLength(2));
      expect(result.mediaInfo!.defaultSubtitleStreamIndex, -1);
      expect(result.mediaInfo!.subtitleTracks.any((t) => t.selected), isFalse);
      c.close();
    });
  });

  group('TrackManager', () {
    setUp(resetSharedPreferencesForTest);

    MediaSourceInfo info() => MediaSourceInfo(
      videoUrl: 'https://example.com/v',
      audioTracks: [
        MediaAudioTrack(id: 1, index: 0, language: 'en', languageCode: 'en', codec: 'eac3', selected: true),
        MediaAudioTrack(id: 2, index: 1, language: 'ja', languageCode: 'ja', codec: 'aac', selected: false),
      ],
      subtitleTracks: [
        MediaSubtitleTrack(id: 1, index: 0, language: 'eng', languageCode: 'eng', selected: false, forced: false),
      ],
      chapters: const [],
    );

    const nativeAudio = [
      AudioTrack(id: '1', language: 'en', codec: 'eac3'),
      AudioTrack(id: '2', language: 'ja', codec: 'aac'),
    ];

    TrackManager manager(_FakePlayer player, _Sink? sink, {MediaBackend backend = MediaBackend.silo}) => TrackManager(
      player: player,
      isActive: () => true,
      sourceTrackPickSink: sink,
      getProfileSettings: () => null,
      waitForProfileSettings: () async {},
      metadata: testMediaItem(id: 'episode:e1', backend: backend, kind: MediaKind.episode),
      mediaInfo: info(),
    );

    test('only explicit picks reach the sink, as source ids', () async {
      await SettingsService.getInstance();
      final sink = _Sink();
      final player = _FakePlayer(const Tracks(audio: nativeAudio));
      final tm = manager(player, sink);
      await tm.applyTrackSelection();
      expect(sink.events, isEmpty);
      await tm.onAudioTrackSelectedByUser(nativeAudio[1]);
      await tm.onSubtitleTrackSelectedByUser(SubtitleTrack.off);
      await tm.onSubtitleTrackSelectedByUser(const SubtitleTrack(id: '5', language: 'eng'), sourceStreamId: 1);
      tm.recordSourceTrackPick(audioStreamId: 1);
      await pumpEventQueue();
      expect(sink.events, ['audio 2', 'subtitle null', 'subtitle 1', 'audio 1']);
      tm.dispose();
    });

    test('"Remember track selections" off keeps picks local', () async {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.rememberTrackSelections, false);
      final sink = _Sink();
      final tm = manager(_FakePlayer(const Tracks(audio: nativeAudio)), sink);
      await tm.onAudioTrackSelectedByUser(nativeAudio[1]);
      await pumpEventQueue();
      expect(sink.events, isEmpty);
      tm.dispose();
    });

    test('other backends have no sink and nothing changes for them', () async {
      await SettingsService.getInstance();
      final player = _FakePlayer(const Tracks(audio: nativeAudio));
      final tm = manager(player, null, backend: MediaBackend.jellyfin);
      await tm.onAudioTrackSelectedByUser(nativeAudio[1]);
      tm.recordSourceTrackPick(audioStreamId: 1, subtitlesOff: true);
      await pumpEventQueue();
      tm.dispose();
      // A Jellyfin source with -1 is still MediaBrowser's own "off", and a
      // Plex source with it is unaffected by the Silo branch.
      final plex = testMediaItem(id: 'p', backend: MediaBackend.plex);
      final plexInfo = MediaSourceInfo(
        videoUrl: 'v',
        audioTracks: const [],
        subtitleTracks: [MediaSubtitleTrack(id: 7, language: 'en', languageCode: 'en', selected: true, forced: false)],
        chapters: const [],
        defaultSubtitleStreamIndex: -1,
      );
      final picked = TrackSelectionService(
        metadata: plex,
        plexMediaInfo: plexInfo,
      ).selectSubtitleTrack([const SubtitleTrack(id: '7', language: 'en')], null, null);
      expect(picked?.track.id, '7');
    });
  });
}

class _Sink implements SourceTrackPickSink {
  final events = <String>[];

  @override
  void audioPicked(int sourceAudioId) => events.add('audio $sourceAudioId');

  @override
  void subtitlePicked(int? sourceSubtitleId) => events.add('subtitle $sourceSubtitleId');
}

class _FakePlayer with PlayerStreamControllersMixin implements Player {
  _FakePlayer(Tracks tracks) : _state = PlayerState(tracks: tracks);

  final PlayerState _state;

  @override
  PlayerState get state => _state;

  late final PlayerStreams _streams = createStreams();

  @override
  PlayerStreams get streams => _streams;

  @override
  bool get disposed => false;

  @override
  bool get supportsSecondarySubtitles => false;

  @override
  Future<void> selectAudioTrack(AudioTrack t) async {}

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack t) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
