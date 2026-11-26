import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/media_subscription.dart';
import 'package:plezy/services/favorite_channels_repository.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/tofa/tofa_api.dart';
import 'package:plezy/services/tofa/tofa_client.dart';

import 'tofa_fixtures.dart';

class _MemoryFavorites implements FavoriteChannelsRepository {
  final Map<String, List<FavoriteChannel>> store = {};

  @override
  Future<List<FavoriteChannel>> read({
    required String key,
    required String legacyKey,
    bool migrate = true,
    void Function()? checkCurrent,
  }) async => List.of(store[key] ?? const []);

  @override
  Future<void> write(String key, List<FavoriteChannel> channels, {void Function()? checkCurrent}) async =>
      store[key] = List.of(channels);
}

Map<String, dynamic> _entry(
  String id, {
  required String start,
  required String end,
  bool recordable = true,
  Map<String, dynamic>? recording,
}) => {
  'id': id,
  'title': 'News $id',
  'episode_title': id == 'a-2' ? 'Evening edition' : null,
  'episode_number': id == 'a-2' ? 4 : null,
  'season_number': id == 'a-2' ? 1 : null,
  'synopsis': 'Today',
  'start_at': start,
  'end_at': end,
  'kind': 'programme',
  'children': <Object>[],
  'episode_id': null,
  'media_id': null,
  'unavailable': false,
  'recordable': recordable,
  'recording': recording,
  'is_new': true,
  'image_url': 'https://img.example.com/$id.jpg',
};

Map<String, dynamic> _channel(String id, int major) => {
  'id': id,
  'name': 'Channel $major',
  'number': {'display': '$major', 'major': major, 'minor': null},
  'logo': null,
  'logo_image_url': '/api/v1/live/logos/$id.png',
  'group': null,
  'category_ids': <String>[],
  'now': null,
  'next': null,
  'remote_available': true,
  'revision': 7,
  'source_kind': 'library',
};

void main() {
  late FakeTofa fake;
  setUp(() => fake = FakeTofa());

  TofaClient client() =>
      TofaClient.forTesting(
          tofaConnection(),
          headers: const TofaClientHeaders(
            clientVersion: '1.0',
            platform: 'android',
            deviceName: 'Test device',
            deviceId: 'dev-1',
          ),
          httpClient: fake.client,
        )
        ..raceWait = (_) async {}
        ..favoritesRepository = _MemoryFavorites();

  test('Tofa offers Live TV and recording', () {
    expect(ServerCapabilities.tofa.liveTv, isTrue);
    expect(ServerCapabilities.tofa.liveTvDvr, isTrue);
  });

  group('availability', () {
    test('channels mean Live TV; no access or no Live means none', () async {
      fake.on(
        'GET',
        '/api/v1/live/channels',
        (_) => jsonResponse({
          'channels': [_channel('ch-1', 1)],
          'next_cursor': null,
        }),
      );
      expect(await client().liveTv.isAvailable(), isTrue);
      fake.on('GET', '/api/v1/live/channels', (_) => tofaError(403, 'live_access_denied'));
      expect(await client().liveTv.isAvailable(), isFalse);
      fake.on('GET', '/api/v1/live/channels', (_) => jsonResponse({'channels': <Object>[], 'next_cursor': null}));
      expect(await client().liveTv.isAvailable(), isFalse);
    });

    test('a server error is not taken for "no Live TV"', () async {
      fake.on('GET', '/api/v1/live/channels', (_) => tofaError(500, 'boom'));
      await expectLater(client().liveTv.isAvailable(), throwsA(isA<MediaServerHttpException>()));
    });
  });

  test('channels page through the cursor', () async {
    fake.on('GET', '/api/v1/live/channels', (r) {
      final cursor = r.url.queryParameters['cursor'];
      return jsonResponse(
        cursor == null
            ? {
                'channels': [_channel('ch-1', 1)],
                'next_cursor': 'c2',
              }
            : {
                'channels': [_channel('ch-2', 2)],
                'next_cursor': null,
              },
      );
    });
    final channels = await client().liveTv.fetchChannels();
    expect(channels.map((c) => c.key), ['ch-1', 'ch-2']);
    expect(channels.first.number, '1');
    expect(channels.first.title, 'Channel 1');
    expect(channels.first.thumb, '/api/v1/live/logos/ch-1.png');
  });

  test('the guide maps entries, splits windows over 24 hours and keeps recording keys', () async {
    final windows = <(int, int)>[];
    fake.on('GET', '/api/v1/live/guide', (r) {
      final from = int.parse(r.url.queryParameters['from']!);
      final to = int.parse(r.url.queryParameters['to']!);
      windows.add((from, to));
      return jsonResponse({
        'from': '',
        'to': '',
        'next_cursor': null,
        'channels': [
          {
            'channel_id': 'ch-1',
            'revision': 9,
            'remote_available': true,
            'source_kind': 'library',
            'entries': [
              _entry('a-1', start: '2026-11-26T10:00:00Z', end: '2026-11-26T11:00:00Z'),
              _entry(
                'a-2',
                start: '2026-11-26T11:00:00Z',
                end: '2026-11-26T12:00:00Z',
                recording: {'id': 'r-1', 'rule_id': 'rule-1', 'state': 'scheduled'},
              ),
              _entry('a-3', start: '2026-11-26T12:00:00Z', end: '2026-11-26T13:00:00Z', recordable: false),
            ],
          },
        ],
      });
    });
    final from = DateTime.utc(2026, 11, 26, 10);
    final programs = await client().liveTv.fetchSchedule(from: from, to: from.add(const Duration(hours: 30)));
    expect(windows, hasLength(2));
    expect(windows.first.$2 - windows.first.$1, const Duration(hours: 24).inMilliseconds);
    expect(programs.map((p) => p.key), ['a-1', 'a-2', 'a-3'], reason: 'entries in both windows appear once');
    final first = programs.first;
    expect(first.channelIdentifier, 'ch-1');
    expect(first.beginsAt, from.millisecondsSinceEpoch ~/ 1000);
    expect(first.guid, isNotNull);
    final second = programs[1];
    expect(second.title, 'Evening edition');
    expect(second.grandparentTitle, 'News a-2');
    expect(second.recordingRuleKey, 'rule:rule-1');
    expect(programs[2].guid, isNull, reason: 'not recordable: no record action');
  });

  group('playing a channel', () {
    test('negotiates the channel with the viewer id and revision, heartbeats and stops', () async {
      fake.on(
        'GET',
        '/api/v1/live/channels',
        (_) => jsonResponse({
          'channels': [_channel('ch-1', 1)],
          'next_cursor': null,
        }),
      );
      fake.on('GET', '/api/v1/stream/ch-1/info', (r) {
        expect(r.url.queryParameters['live_viewer_id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
        expect(r.url.queryParameters['live_revision'], '7');
        expect(r.url.queryParameters.containsKey('resume_ticks'), isTrue);
        return jsonResponse(
          playbackInfo(playMethod: 'Transcode', streamUrl: '/api/v1/stream/s/sid-1/master.m3u8?st=sess-tok'),
        );
      });
      fake.onPrefix('POST', '/api/v1/stream/s/sid-1/', (_) => http.Response('', 204));
      final c = client();
      await c.liveTv.fetchChannels();
      final session = await c.liveTv.startPlayback('ch-1');
      expect(session, isNotNull);
      expect(session!.canTimeShift, isFalse);
      expect(await session.streamUrlAt(), endsWith('/api/v1/stream/s/sid-1/master.m3u8?st=sess-tok'));
      expect(await session.streamUrlAt(offsetSeconds: 30), isNull);
      await session.reportTimeline(state: 'playing', positionMs: 5000, durationMs: 0);
      final progress = fake.to('POST', '/api/v1/stream/s/sid-1/progress').single;
      expect(progress.url.queryParameters['st'], 'sess-tok');
      expect(progress.headers.containsKey('Authorization'), isFalse);
      expect((jsonDecode(progress.body) as Map)['is_paused'], isFalse);
      await session.reportTimeline(state: 'stopped', positionMs: 6000, durationMs: 0);
      expect(fake.to('POST', '/api/v1/stream/s/sid-1/stopped'), hasLength(1));
      await session.discard();
      expect(fake.to('POST', '/api/v1/stream/s/sid-1/stopped'), hasLength(1), reason: 'stopped once');
    });

    test("a refusal shows the server's message", () async {
      fake.on(
        'GET',
        '/api/v1/stream/ch-1/info',
        (_) => tofaError(403, 'live_home_only', 'This channel plays only on your home network.'),
      );
      await expectLater(
        client().liveTv.startPlayback('ch-1'),
        throwsA(
          isA<PlaybackException>().having((e) => e.message, 'message', 'This channel plays only on your home network.'),
        ),
      );
    });
  });

  test('favourite channels are kept on the device, per sign-in', () async {
    final c = client();
    final live = c.liveTv;
    final source = await live.buildFavoriteChannelSource();
    final channel = LiveTvChannel(key: 'ch-1', title: 'One', number: '1');
    await live.setFavoriteChannels([FavoriteChannel.fromLiveTvChannel(channel, source)]);
    expect((await live.fetchFavoriteChannels()).single.id, 'ch-1');
    expect(fake.requests, isEmpty);
  });

  group('recording', () {
    test('this programme: POST scheduled; an existing one reads as already set', () async {
      var status = 201;
      fake.on('POST', '/api/v1/live/recordings/scheduled', (r) {
        expect(jsonDecode(r.body), {'airing_id': 'a-1', 'channel_id': 'ch-1'});
        return jsonResponse({'id': 'r-9'}, status);
      });
      final dvr = client().liveTvDvr!;
      final templates = await dvr.getSubscriptionTemplate('tofa-airing:ch-1/a-1');
      final entries = templates.single.subscriptions;
      expect(entries.map((e) => e.type), [MediaSubscription.typeEpisode, MediaSubscription.typeSeries]);
      await dvr.createRecordingRule(MediaSubscriptionCreateRequest.fromTemplate(entries.first));
      status = 200;
      await expectLater(
        dvr.createRecordingRule(MediaSubscriptionCreateRequest.fromTemplate(entries.first)),
        throwsA(isA<RecordingConflictException>()),
      );
    });

    test('a tuner conflict (409) is a failure, not "already scheduled"', () async {
      fake.on(
        'POST',
        '/api/v1/live/recordings/scheduled',
        (_) => tofaError(409, 'tuners_busy', 'Every tuner is busy.'),
      );
      final dvr = client().liveTvDvr!;
      final entry = (await dvr.getSubscriptionTemplate('tofa-airing:ch-1/a-1')).single.subscriptions.first;
      await expectLater(
        dvr.createRecordingRule(MediaSubscriptionCreateRequest.fromTemplate(entry)),
        throwsA(isA<MediaServerHttpException>().having((e) => e.statusCode, 'statusCode', isNull)),
      );
    });

    test('every airing: a rule from the airing with its settings', () async {
      fake.on('POST', '/api/v1/live/recording-rules', (r) {
        expect(jsonDecode(r.body), {'from_airing_id': 'a-1', 'any_channel': true, 'new_only': true, 'keep_last': 5});
        return jsonResponse({'id': 'rule-2'}, 201);
      });
      final dvr = client().liveTvDvr!;
      final series = (await dvr.getSubscriptionTemplate('tofa-airing:ch-1/a-1')).single.subscriptions.last;
      await dvr.createRecordingRule(
        MediaSubscriptionCreateRequest.fromTemplate(
          series,
          prefs: {'new_only': true, 'any_channel': true, 'keep_last': 5},
        ),
      );
      expect(fake.to('POST', '/api/v1/live/recording-rules'), hasLength(1));
    });

    test('rules and pending recordings; editing, deleting, and no single-recording cancel', () async {
      fake.on(
        'GET',
        '/api/v1/live/recording-rules',
        (_) => jsonResponse({
          'rules': [
            {
              'id': 'rule-1',
              'name': 'The News',
              'channel_id': 'ch-1',
              'channel_name': 'One',
              'enabled': true,
              'new_only': true,
              'keep_last': 3,
              'conflicts': 0,
              'recorded': 1,
              'upcoming': 1,
              'created_at': '',
              'match': {'kind': 'series', 'pattern': null, 'phrase': null, 'series_title': 'The News'},
              'next': null,
            },
          ],
        }),
      );
      fake.on('GET', '/api/v1/live/recordings', (r) {
        expect(r.url.queryParameters['include'], 'scheduled');
        Map<String, dynamic> rec(String id, {String? actualStart, String? actualEnd, String? missed}) => {
          'id': id,
          'title': 'The News',
          'episode_title': null,
          'channel_id': 'ch-1',
          'channel_name': 'One',
          'rule_id': 'rule-1',
          'requested_start': '2026-11-27T10:00:00Z',
          'requested_end': '2026-11-27T11:00:00Z',
          'scheduled_for': '2026-11-27T10:01:00Z',
          'actual_start': actualStart,
          'actual_end': actualEnd,
          'missed_reason': missed,
          'error': null,
          'description': null,
          'state': 'x',
        };
        return jsonResponse({
          'recordings': [
            rec('r-1'),
            rec('r-2', actualStart: '2026-11-26T10:00:00Z'),
            rec('r-3', actualStart: '2026-11-25T10:00:00Z', actualEnd: '2026-11-25T11:00:00Z'),
            rec('r-4', missed: 'no_tuner'),
          ],
        });
      });
      fake.on('PATCH', '/api/v1/live/recording-rules/rule-1', (r) {
        expect(jsonDecode(r.body), {'new_only': false, 'keep_all': true});
        return jsonResponse({'id': 'rule-1', 'name': 'The News', 'new_only': false, 'channel_id': 'ch-1'});
      });
      fake.on('DELETE', '/api/v1/live/recording-rules/rule-1', (_) => http.Response('', 204));
      final dvr = client().liveTvDvr!;
      final grabs = await dvr.fetchScheduledRecordings();
      expect(grabs.map((g) => g.id), ['rec:r-1', 'rec:r-2']);
      expect(grabs.map((g) => g.status), ['scheduled', 'grabbing']);
      expect(grabs.first.program?.title, 'The News');
      expect(grabs.first.program?.channelIdentifier, 'ch-1');
      final rules = await dvr.fetchRecordingRules();
      expect(rules.single.key, 'rule:rule-1');
      expect(rules.single.grabOperations, hasLength(2));
      final keep = rules.single.settings.firstWhere((s) => s.id == 'keep_last');
      expect(keep.value, 3);
      await dvr.updateRecordingRule('rule:rule-1', {'new_only': false, 'keep_last': 0});
      await dvr.deleteRecordingRule('rule:rule-1');
      expect(fake.to('DELETE', '/api/v1/live/recording-rules/rule-1'), hasLength(1));
      await expectLater(dvr.cancelGrab('rec:r-1'), throwsA(isA<UnsupportedError>()));
      await expectLater(dvr.deleteRecordingRule('rec:r-1'), throwsA(isA<UnsupportedError>()));
    });
  });
}
