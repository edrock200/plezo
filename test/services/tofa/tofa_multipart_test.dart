import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/tofa/tofa_api.dart';
import 'package:plezy/services/tofa/tofa_api_cache.dart';
import 'package:plezy/services/tofa/tofa_client.dart';
import 'package:plezy/services/tofa/tofa_mappers.dart';

import 'tofa_fixtures.dart';

Map<String, dynamic> _part(String id, int number, int ms, {String? edition}) => mediaFile(id, durationMs: ms)
  ..['part_number'] = number
  ..['part_count'] = 2
  ..['edition'] = edition;

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

  void serve(Map<String, Map<String, dynamic>> progress) {
    fake.on(
      'GET',
      '/api/v1/media/m-1',
      (_) => jsonResponse(movieDetail(files: [_part('f-p2', 2, 30000), _part('f-p1', 1, 60000)])),
    );
    fake.on('POST', '/api/v1/media/progress/batch', (r) {
      final ids = (jsonDecode(r.body) as Map)['media_file_ids'] ?? (jsonDecode(r.body) as Map)['ids'];
      expect(ids, containsAll(['f-p1', 'f-p2']), reason: 'progress is read for every part');
      return jsonResponse({
        'items': [
          for (final e in progress.entries) {'media_file_id': e.key, ...e.value},
        ],
      });
    });
  }

  test('a multi-part set is one version over its parts, resuming in the part with progress', () async {
    serve({
      'f-p1': {'completed': true, 'position_ms': 60000, 'updated_at': '2026-11-20T10:00:00Z'},
      'f-p2': {'completed': false, 'position_ms': 10000, 'updated_at': '2026-11-21T10:00:00Z'},
    });
    final item = await client().fetchItem('m-1');
    final version = item!.mediaVersions!.single;
    expect(version.parts.map((p) => p.id), ['f-p1', 'f-p2']);
    expect(item.durationMs, 90000);
    expect(item.viewOffsetMs, 70000);
    expect(item.isWatched, isFalse);
    expect(TofaMappers.partFileIdsOf(item), ['f-p2']);
  });

  test('the set counts watched once its last part is completed', () async {
    serve({
      'f-p2': {'completed': true, 'position_ms': 30000},
    });
    final item = await client().fetchItem('m-1');
    expect(item!.isWatched, isTrue);
  });

  test('a set with a part missing plays part 1 alone', () {
    final files = [_part('f-p1', 1, 60000)];
    expect(TofaMappers.partSet(files.first, files), hasLength(1));
    final other = [_part('f-p1', 1, 60000), _part('f-x2', 2, 30000, edition: "Director's Cut")];
    expect(TofaMappers.partSet(other.first, other), hasLength(1), reason: 'another edition is no member');
  });

  test('playback opens the part holding the start, reports per file and marks the set watched', () async {
    serve(const {});
    fake.on('GET', '/api/v1/stream/f-p2/info', (r) {
      expect(r.url.queryParameters['resume_ticks'], '${const Duration(seconds: 10).inMicroseconds * 10}');
      return jsonResponse(playbackInfo());
    });
    fake.onPrefix('POST', '/api/v1/stream/s/sid-1/', (_) => jsonResponse(const {}));
    fake.on('POST', '/api/v1/media/watched/batch', (_) => jsonResponse(const {}));
    final c = client();
    final movie = await c.fetchItem('m-1');
    final result = await c.getPlaybackInitialization(
      PlaybackInitializationOptions(
        metadata: movie!,
        selectedMediaIndex: 0,
        startPosition: const Duration(seconds: 70),
      ),
    );
    final timeline = result.mediaInfo!.partTimeline!;
    expect(timeline.currentIndex, 1);
    expect(timeline.current.start, const Duration(seconds: 60));
    expect(result.mediaInfo!.mediaSourceId, 'f-p1');

    await c.reportPlaybackStopped(
      itemId: 'm-1',
      position: const Duration(seconds: 89),
      duration: const Duration(seconds: 90),
      playSessionId: 'sid-1',
    );
    final progress = jsonDecode(fake.to('POST', '/api/v1/stream/s/sid-1/progress').last.body) as Map;
    expect(progress['position_ticks'], const Duration(seconds: 29).inMicroseconds * 10);
    expect(progress['ended'], isTrue);
    final marked = jsonDecode(fake.to('POST', '/api/v1/media/watched/batch').single.body) as Map;
    expect([for (final i in marked['items'] as List) (i as Map)['media_file_id']], ['f-p1', 'f-p2']);
  });
}
