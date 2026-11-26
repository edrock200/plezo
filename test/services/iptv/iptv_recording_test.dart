import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/media_subscription.dart';
import 'package:plezy/services/iptv/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_recorder.dart';
import 'package:plezy/services/iptv/iptv_store.dart';
import 'package:plezy/services/iptv/iptv_sync_worker.dart';
import 'package:plezy/services/playback_initialization_types.dart';

import 'fake_iptv_server.dart';
import 'iptv_test_helpers.dart';

void main() {
  late FakeIptvServer server;
  late IptvStore store;
  late Directory dir;
  late IptvRecorder recorder;
  late IptvClient client;

  setUp(() async {
    server = await FakeIptvServer().start();
    store = memoryIptvStore();
    dir = await Directory.systemTemp.createTemp('iptv-rec');
    final source = m3uSource(server.base);
    final worker = IptvSyncWorker(store: store, now: () => server.now);
    await worker.importPlaylist(source);
    await worker.importEpg(source);
    worker.close();
    client = IptvClient(source, store: store, now: () => server.now);
    recorder = IptvRecorder(store: store, directory: () async => dir)
      ..resolver = (sourceId, channelId) => client.recordingTarget(channelId);
    IptvRecorder.testInstance = recorder;
  });

  tearDown(() async {
    IptvRecorder.testInstance = null;
    await server.close();
    await store.db.close();
    await dir.delete(recursive: true);
  });

  test('records a channel to a file until the stop time, then lists and plays it', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final row = await recorder.schedule(
      sourceId: client.connection.id,
      channelId: (await client.liveTv.fetchChannels()).first.key,
      channelName: 'Channel 1 HD',
      title: 'A test recording',
      start: now,
      stop: now + 2,
    );
    expect(recorder.isRecording(row.id), isTrue);
    await Future<void>.delayed(const Duration(seconds: 4));
    final done = (await store.recordings()).single;
    expect(done.state, IptvRecordingState.completed);
    expect(done.bytes, greaterThan(0));
    expect(File(done.path!).existsSync(), isTrue);
    expect(server.requests.any((u) => u.path == '/stream/1.ts'), isTrue);

    final live = client.liveTv as LiveTvRecordedItems;
    final listed = await live.fetchRecordings();
    expect(listed.single.title, 'A test recording');
    final item = (await live.recordingItem(listed.single))!;
    final init = await client.getPlaybackInitialization(
      PlaybackInitializationOptions(metadata: item, selectedMediaIndex: 0),
    );
    expect(init.videoUrl, Uri.file(done.path!).toString());
    expect(init.isOffline, isTrue);

    expect(await client.deleteMediaItem(item), isTrue);
    expect(await store.recordings(), isEmpty);
    expect(File(done.path!).existsSync(), isFalse);
  });

  test('the guide schedules a future airing, lists it and cancels it', () async {
    final dvr = client.liveTvDvr!;
    final programmes = await client.liveTv.fetchSchedule(
      from: server.now.add(const Duration(hours: 2)),
      to: server.now.add(const Duration(hours: 3)),
    );
    final future = programmes.firstWhere((p) => p.beginsAt! > server.now.millisecondsSinceEpoch ~/ 1000);
    final templates = await dvr.getSubscriptionTemplate(future.guid!);
    final entry = templates.single.subscriptions.single;
    expect(entry.type, MediaSubscription.typeEpisode);
    await dvr.createRecordingRule(MediaSubscriptionCreateRequest.fromTemplate(entry));
    final scheduled = await dvr.fetchScheduledRecordings();
    expect(scheduled.single.status, 'scheduled');
    expect(scheduled.single.program?.title, future.title);
    await expectLater(
      dvr.createRecordingRule(MediaSubscriptionCreateRequest.fromTemplate(entry)),
      throwsA(anything),
      reason: 'the same airing twice is refused',
    );
    await dvr.cancelGrab(scheduled.single.id);
    expect(await dvr.fetchScheduledRecordings(), isEmpty);
    expect((await store.recordings()).single.state, IptvRecordingState.cancelled);
  });

  test('an ended programme cannot be recorded', () async {
    final past = (await client.liveTv.fetchSchedule(
      from: server.now.subtract(const Duration(hours: 3)),
      to: server.now.subtract(const Duration(hours: 2)),
    )).first;
    expect(await client.liveTvDvr!.getSubscriptionTemplate(past.guid!), isEmpty);
  });

  test('restore marks a recording cut off by an exit as failed and a missed one too', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final (id, state, stop) in [
      ('a', IptvRecordingState.recording, now + 600),
      ('b', IptvRecordingState.scheduled, now - 10),
    ]) {
      await store.putRecording(
        IptvRecordingRow(id: id, sourceId: 's', channelId: 'c', title: id, start: now - 60, stop: stop, state: state),
      );
    }
    await recorder.restore();
    final rows = {for (final r in await store.recordings()) r.id: r};
    expect(rows['a']!.error, 'interrupted');
    expect(rows['b']!.error, 'missed');
    expect(rows.values.every((r) => r.state == IptvRecordingState.failed), isTrue);
  });

  test('HLS playlists: the best variant, then new segments', () {
    final master = IptvRecorder.parseHlsPlaylist(
      '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=3000000\nhigh.m3u8\n',
      Uri.parse('http://h.example/live/ch/index.m3u8'),
    );
    expect(master.variant.toString(), 'http://h.example/live/ch/high.m3u8');
    final media = IptvRecorder.parseHlsPlaylist(
      '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nseg1.ts\n#EXTINF:4,\nhttp://cdn.example/seg2.ts\n',
      Uri.parse('http://h.example/live/ch/high.m3u8'),
    );
    expect(media.segments.map((u) => u.toString()), ['http://h.example/live/ch/seg1.ts', 'http://cdn.example/seg2.ts']);
    expect(media.targetDuration, 4);
    expect(media.ended, isFalse);
  });
}
