import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/download_resolution.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/playback_report_metadata.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_end_credits.dart';

/// Silo Android #1038 (silo-android 137fca310): a downloaded stop in the end
/// credits is sent as played to the end, so the server stores it as watched.
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

MediaMarker _credits(int i, double startSeconds) => MediaMarker(
  id: i,
  type: 'credits',
  startTimeOffset: (startSeconds * 1000).round(),
  endTimeOffset: ((startSeconds + 20) * 1000).round(),
);

Map<String, dynamic> _watch({
  String type = 'episode',
  Object fileId = 7,
  num duration = 1304,
  List<double> creditsStarts = const [1080],
}) => {
  'content_id': 'episode:e1',
  'type': type,
  'versions': [
    {
      'file_id': fileId,
      'duration_seconds': duration,
      'marker_segments': [
        for (final start in creditsStarts) {'kind': 'credits', 'start_seconds': start, 'end_seconds': start + 20},
      ],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the end-credits rule (the server end window)', () {
    Duration? start(bool isEpisode, List<double> starts, {double duration = 1304}) => SiloEndCredits.start(
      markers: [for (var i = 0; i < starts.length; i++) _credits(i, starts[i])],
      duration: Duration(milliseconds: (duration * 1000).round()),
      isEpisode: isEpisode,
    );

    test('matches Silo Android OfflineTracksTest', () {
      // An episode's window is its last 450 s, from 854 s; the last credits in it win.
      expect(start(true, [300, 900, 1080]), const Duration(seconds: 1080));
      // Credits placed before the window never finish the title early.
      expect(start(true, [300]), isNull);
      // Anything not an episode uses the movie window, its last 25% from 978 s.
      expect(start(false, [900]), isNull);
      expect(start(false, [1080]), const Duration(seconds: 1080));
    });

    test('a short file uses its share; credits at or after the end, other kinds and no length give none', () {
      // 600 s episode: 40% (240 s) is shorter than 450 s, so the window opens at 360 s.
      expect(start(true, [350], duration: 600), isNull);
      expect(start(true, [360], duration: 600), const Duration(seconds: 360));
      expect(start(true, [1304]), isNull);
      expect(
        SiloEndCredits.start(
          markers: [MediaMarker(id: 0, type: 'intro', startTimeOffset: 1100000, endTimeOffset: 1200000)],
          duration: const Duration(seconds: 1304),
          isEpisode: true,
        ),
        isNull,
      );
      expect(start(true, [1080], duration: 0), isNull);
    });

    test('reads the downloaded version of a watch detail, its kind from the item or the payload', () {
      expect(SiloEndCredits.fromWatchDetail(_watch(), fileId: '7'), const Duration(seconds: 1080));
      expect(SiloEndCredits.fromWatchDetail(_watch(), fileId: '8'), isNull, reason: 'another file');
      // Movie window from 978 s: 900 s is outside it, unless the item is an episode.
      final movie = _watch(type: 'movie', creditsStarts: [900]);
      expect(SiloEndCredits.fromWatchDetail(movie, fileId: '7'), isNull);
      expect(
        SiloEndCredits.fromWatchDetail(
          movie,
          fileId: '7',
          item: MediaItem.silo(id: 'episode:e1', kind: MediaKind.episode, serverId: 'srv-1'),
        ),
        const Duration(seconds: 900),
      );
      expect(SiloEndCredits.fromWatchDetail(_watch(duration: 0), fileId: '7'), isNull);
      // The singular credits object stands in when a version has no segments.
      final singular = {
        'type': 'episode',
        'versions': [
          {
            'file_id': 7,
            'duration_seconds': 1304,
            'credits': {'start_seconds': 1080, 'end_seconds': 1290},
          },
        ],
      };
      expect(SiloEndCredits.fromWatchDetail(singular, fileId: '7'), const Duration(seconds: 1080));
    });

    test('a position at or past the start is sent as the full duration', () {
      const end = Duration(seconds: 1080);
      const duration = Duration(seconds: 1304);
      Duration sent(int s) => SiloEndCredits.reportedPosition(
        position: Duration(seconds: s),
        duration: duration,
        endCreditsStart: end,
      );
      expect(sent(1079), const Duration(seconds: 1079));
      expect(sent(1080), duration);
      expect(sent(1160), duration);
      expect(
        SiloEndCredits.reportedPosition(
          position: const Duration(seconds: 1160),
          duration: duration,
          endCreditsStart: null,
        ),
        const Duration(seconds: 1160),
      );
    });
  });

  group('SiloClient', () {
    late List<http.Request> requests;
    late List<Map<String, dynamic>> syncBodies;
    late Map<String, dynamic>? fileWatch;
    var watchStatus = 200;

    setUp(() {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      SiloApiCache.initialize(db);
      requests = [];
      syncBodies = [];
      fileWatch = _watch();
      watchStatus = 200;
    });

    SiloClient client() => SiloClient.forTesting(
      _connection(),
      headers: _headers,
      httpClient: MockClient((request) async {
        requests.add(request);
        final path = Uri.decodeComponent(request.url.path);
        if (path.endsWith('/api/v2/watch/episode:e1')) {
          if (watchStatus != 200) return _json({}, watchStatus);
          return _json(fileWatch ?? {});
        }
        if (path.endsWith('/sync/progress')) {
          syncBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _json({
            'items': [
              {'index': 0, 'media_item_id': 'episode:e1', 'status': 'success'},
            ],
          });
        }
        return http.Response('', 204);
      }),
    );

    final episode = MediaItem.silo(id: 'episode:e1', kind: MediaKind.episode, serverId: 'srv-1');

    test('is a download completion recorder', () {
      expect(client(), isA<DownloadCompletionRecorder>());
    });

    test('a completed download records its file\'s end credits from the per-file watch detail', () async {
      final c = client();
      await c.recordDownloadedFile(episode, mediaSourceId: '7');
      final watchRequest = requests.single;
      expect(watchRequest.url.queryParameters['file_id'], '7');
      final record = await SiloApiCache.instance.getEndCredits(ServerId(c.cacheServerId), 'episode:e1');
      expect(record!.fileId, '7');
      expect(record.start, const Duration(seconds: 1080));
      expect(
        await SiloApiCache.instance.isPinned(ServerId(c.cacheServerId), SiloApiCache.endCreditsEndpoint('episode:e1')),
        isTrue,
      );

      // Removing the download drops the record with the rest of its rows.
      await SiloApiCache.instance.deleteForItem(ServerId(c.cacheServerId), 'episode:e1');
      expect(await SiloApiCache.instance.getEndCredits(ServerId(c.cacheServerId), 'episode:e1'), isNull);
    });

    test('without an answer it falls back to the watch detail pinned with the download', () async {
      final c = client();
      await SiloApiCache.instance.put(
        ServerId(c.cacheServerId),
        SiloApiCache.watchEndpoint('episode:e1'),
        _watch(creditsStarts: [1100]),
      );
      watchStatus = 503;
      await c.recordDownloadedFile(episode, mediaSourceId: '7');
      final record = await SiloApiCache.instance.getEndCredits(ServerId(c.cacheServerId), 'episode:e1');
      expect(record!.start, const Duration(seconds: 1100));
    });

    test('a file with no credits in its end window is recorded as none; an unknown file records nothing', () async {
      final c = client();
      fileWatch = _watch(creditsStarts: [300]);
      await c.recordDownloadedFile(episode, mediaSourceId: '7');
      final record = await SiloApiCache.instance.getEndCredits(ServerId(c.cacheServerId), 'episode:e1');
      expect(record!.fileId, '7');
      expect(record.start, isNull);

      fileWatch = _watch(fileId: 9);
      await SiloApiCache.instance.deleteForItem(ServerId(c.cacheServerId), 'episode:e1');
      await c.recordDownloadedFile(episode, mediaSourceId: '7');
      expect(await SiloApiCache.instance.getEndCredits(ServerId(c.cacheServerId), 'episode:e1'), isNull);
    });

    Future<SiloClient> recorded() async {
      final c = client();
      await c.recordDownloadedFile(episode, mediaSourceId: '7');
      requests.clear();
      return c;
    }

    test('an offline stop in the end credits syncs as played to the end', () async {
      final c = await recorded();
      await c.reportPlaybackStopped(
        itemId: 'episode:e1',
        position: const Duration(seconds: 1160),
        duration: const Duration(seconds: 1304),
        report: PlaybackReportMetadata.offlineReplay(recordedAt: DateTime.utc(2026, 11, 23)),
      );
      final item = (syncBodies.single['items'] as List).single as Map;
      expect(item['position_ms'], 1304000);
      expect(item['duration_ms'], 1304000);
      expect(requests.where((r) => r.url.path.contains('/watched/')), isEmpty);
    });

    test('an offline stop before the end credits keeps its real position', () async {
      final c = await recorded();
      await c.reportPlaybackStopped(
        itemId: 'episode:e1',
        position: const Duration(seconds: 1000),
        duration: const Duration(seconds: 1304),
        report: PlaybackReportMetadata.offlineReplay(recordedAt: DateTime.utc(2026, 11, 23)),
      );
      final item = (syncBodies.single['items'] as List).single as Map;
      expect(item['position_ms'], 1000000);
    });

    test('a download without a record keeps the server\'s percentage', () async {
      final c = client();
      await c.reportPlaybackStopped(
        itemId: 'episode:e1',
        position: const Duration(seconds: 1160),
        duration: const Duration(seconds: 1304),
        report: PlaybackReportMetadata.offlineReplay(recordedAt: DateTime.utc(2026, 11, 23)),
      );
      final item = (syncBodies.single['items'] as List).single as Map;
      expect(item['position_ms'], 1160000);
    });

    test('a downloaded file played online and stopped in its end credits is marked watched', () async {
      final c = await recorded();
      // 1160 of 1304 s is below Plezilo's 90%, but past the credits start.
      await c.reportPlaybackStopped(
        itemId: 'episode:e1',
        position: const Duration(seconds: 1160),
        duration: const Duration(seconds: 1304),
      );
      expect(syncBodies, isEmpty);
      expect(Uri.decodeComponent(requests.single.url.path), endsWith('/api/v2/watched/episode:e1'));
      expect(requests.single.method, 'POST');
    });
  });
}
