import 'dart:io';

import 'package:flutter/services.dart';
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
    final entry = templates.single.subscriptions.first;
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

  group('series rules', () {
    /// "Nightly" airs on channel 5 at +2 h (episode 1, new), +3 h (episode 1
    /// again: a repeat), +4 h (episode 2), and on channel 6 at +5 h
    /// (episode 3, new) and +6 h (episode 2 again).
    Future<void> loadSeriesGuide() async {
      final base = DateTime.utc(server.now.year, server.now.month, server.now.day, server.now.hour);
      String at(int h) => FakeIptvServer.xmltvTime(base.add(Duration(hours: h)));
      String show(int ch, int h, int ep, {bool isNew = false}) =>
          '<programme start="${at(h)}" stop="${at(h + 1)}" channel="ch$ch.fake"><title>Nightly</title>'
          '<sub-title>Part $ep</sub-title><episode-num system="xmltv_ns">0.$ep.</episode-num>'
          '${isNew ? '<new/>' : ''}</programme>\n';
      server.hourlyGuideChannels = 4;
      server.extraGuide = [
        show(5, 2, 1, isNew: true),
        show(5, 3, 1),
        show(5, 4, 2),
        show(6, 5, 3, isNew: true),
        show(6, 6, 2),
      ].join();
      final worker = IptvSyncWorker(store: store, now: () => server.now);
      await worker.importEpg(client.connection);
      worker.close();
    }

    Future<MediaSubscription> seriesEntry({int hour = 2, int channel = 0}) async {
      final programmes = await client.liveTv.fetchSchedule(
        from: server.now.add(Duration(hours: hour)),
        to: server.now.add(Duration(hours: hour + 1)),
      );
      final airing = programmes.firstWhere((p) => p.grandparentTitle == 'Nightly');
      final templates = await client.liveTvDvr!.getSubscriptionTemplate(airing.guid!);
      final entries = templates.single.subscriptions;
      expect(entries.map((e) => e.type), [MediaSubscription.typeEpisode, MediaSubscription.typeSeries]);
      return entries.last;
    }

    Future<List<IptvRecordingRow>> pending() async => [
      for (final r in await store.recordings())
        if (r.state == IptvRecordingState.scheduled) r,
    ]..sort((a, b) => a.start.compareTo(b.start));

    test('one channel: each episode once, a repeat skipped', () async {
      await loadSeriesGuide();
      final dvr = client.liveTvDvr!;
      await dvr.createRecordingRule(MediaSubscriptionCreateRequest.fromTemplate(await seriesEntry()));
      final rows = await pending();
      expect(rows.map((r) => r.title), ['Nightly: Part 1', 'Nightly: Part 2']);
      expect(rows.map((r) => r.episode), ['ep:s01e02', 'ep:s01e03']);
      expect(rows.every((r) => r.ruleId != null), isTrue);

      final rules = await dvr.fetchRecordingRules();
      expect(rules.single.key, startsWith('iptvrule:'));
      expect(rules.single.grabOperations, hasLength(2));

      // Expanding again (a guide refresh) schedules nothing new.
      expect(await client.expandRecordingRules(), 0);

      // The guide tags the scheduled airings with the rule.
      final tagged = (await client.liveTv.fetchSchedule(
        from: server.now.add(const Duration(hours: 2)),
        to: server.now.add(const Duration(hours: 5)),
      )).where((p) => p.recordingRuleKey != null);
      expect(tagged.map((p) => p.recordingRuleKey).toSet(), {rules.single.key});
    });

    test('any channel and new only', () async {
      await loadSeriesGuide();
      final dvr = client.liveTvDvr!;
      final request = MediaSubscriptionCreateRequest.fromTemplate(await seriesEntry());
      await dvr.createRecordingRule(
        MediaSubscriptionCreateRequest(
          type: request.type,
          parameters: request.parameters,
          prefs: {...request.prefs, 'any_channel': true},
        ),
      );
      expect((await pending()).map((r) => r.episode), ['ep:s01e02', 'ep:s01e03', 'ep:s01e04']);

      final rule = (await dvr.fetchRecordingRules()).single;
      await dvr.updateRecordingRule(rule.key, {'new_only': true});
      final rows = await pending();
      expect(rows.map((r) => r.episode), ['ep:s01e02', 'ep:s01e04']);
      expect(rows.map((r) => r.channelId).toSet(), hasLength(2));

      await dvr.deleteRecordingRule(rule.key);
      expect(await dvr.fetchRecordingRules(), isEmpty);
      expect(await pending(), isEmpty);
    });

    test('keep latest N deletes older recordings of the rule', () async {
      final rule = IptvRecordingRule(
        id: 'r1',
        sourceId: client.connection.id,
        title: 'Nightly',
        channelId: 'c',
        keepLast: 2,
        createdAt: 0,
      );
      await store.putRule(rule);
      for (var i = 0; i < 4; i++) {
        final file = File('${dir.path}/$i.ts')..writeAsBytesSync([1]);
        await store.putRecording(
          IptvRecordingRow(
            id: 'rec$i',
            sourceId: rule.sourceId,
            channelId: 'c',
            title: 'Nightly $i',
            start: 1000 + i * 100,
            stop: 1050 + i * 100,
            state: IptvRecordingState.completed,
            path: file.path,
            bytes: 1,
            ruleId: 'r1',
          ),
        );
      }
      expect(await recorder.enforceKeepLast(rule), 2);
      final left = await store.recordings();
      expect(left.map((r) => r.id).toSet(), {'rec2', 'rec3'});
      expect(File('${dir.path}/0.ts').existsSync(), isFalse);
      expect(await recorder.enforceKeepLast(rule.copyWith(keepLast: 0)), 0);
    });
  });

  test('tells the Android service what records now and what is next', () async {
    final channel = _FakeServiceChannel();
    final calls = channel.calls;
    final reporting = IptvRecorder(store: store, directory: () async => dir, backgroundChannel: channel)
      ..resolver = (sourceId, channelId) => client.recordingTarget(channelId);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final row = await reporting.schedule(
      sourceId: client.connection.id,
      channelId: (await client.liveTv.fetchChannels()).first.key,
      title: 'Later',
      start: now + 3600,
      stop: now + 7200,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls.last['active'], isEmpty);
    expect(calls.last['nextAtMs'], (now + 3600) * 1000);
    expect(calls.last['nextTitle'], 'Later');
    await reporting.cancel(row.id);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls.last['nextAtMs'], isNull);
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

/// Records what the recorder sends the Android service, without a binding
/// (a test binding would block the fake server's sockets).
class _FakeServiceChannel extends MethodChannel {
  _FakeServiceChannel() : super('test/iptv_recording');
  final calls = <Map<Object?, Object?>>[];

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (method == 'setState') calls.add(arguments as Map<Object?, Object?>);
    return null;
  }
}
