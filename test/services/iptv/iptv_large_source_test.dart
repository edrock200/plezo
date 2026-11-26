import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_store.dart';
import 'package:plezy/services/iptv/iptv_sync_service.dart';
import 'package:plezy/services/iptv/iptv_sync_worker.dart';

import 'fake_iptv_server.dart';
import 'iptv_test_helpers.dart';

/// Records how the import writes: the largest batch ever handed over.
class _SpyStore extends IptvStore {
  _SpyStore(super.db);
  int largestVodBatch = 0;
  int largestChannelBatch = 0;
  int vodBatches = 0;

  @override
  Future<void> stageVod(String sourceId, IptvGroupKind kind, List<IptvVodRow> rows) {
    vodBatches++;
    if (rows.length > largestVodBatch) largestVodBatch = rows.length;
    return super.stageVod(sourceId, kind, rows);
  }

  @override
  Future<void> stageChannels(String sourceId, List<IptvChannel> channels) {
    if (channels.length > largestChannelBatch) largestChannelBatch = channels.length;
    return super.stageChannels(sourceId, channels);
  }
}

void main() {
  late FakeIptvServer server;
  late _SpyStore store;

  setUp(() async {
    server = await FakeIptvServer().start();
    store = _SpyStore(IptvDatabase(NativeDatabase.memory()));
    IptvStore.testInstance = store;
  });

  tearDown(() async {
    await server.close();
    await store.db.close();
    IptvStore.testInstance = null;
  });

  test('200k movies import in batches, never as one list', () async {
    server.syntheticMovies = 200000;
    final source = xtreamSource(server.base);
    final worker = IptvSyncWorker(store: store, now: () => server.now);
    await worker.importPlaylist(source);
    worker.close();
    expect(await store.vodCount(source.id, IptvGroupKind.movie), 200000);
    // A batch holds about 2000 rows (plus what one network chunk completed).
    expect(store.largestVodBatch, lessThan(IptvSyncWorker.importBatch + 500));
    expect(store.vodBatches, greaterThan(200000 ~/ (IptvSyncWorker.importBatch + 1500)));
    final groups = await store.groups(source.id, IptvGroupKind.movie);
    expect({for (final g in groups) g.id: g.count}, {'10': 100000, '11': 100000});
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a list cut off half way keeps the stored channels and movies', () async {
    final source = xtreamSource(server.base);
    final worker = IptvSyncWorker(store: store, now: () => server.now);
    await worker.importPlaylist(source);
    final channels = await store.channelCount(source.id);
    final movies = await store.vodCount(source.id, IptvGroupKind.movie);
    expect(channels, greaterThan(0));
    expect(movies, greaterThan(0));

    server.truncateLists = true;
    await expectLater(worker.importPlaylist(source), throwsA(isA<IptvSyncException>()));
    worker.close();
    expect(await store.channelCount(source.id), channels, reason: 'the swap never happened');
    expect(await store.vodCount(source.id, IptvGroupKind.movie), movies);
  });

  group('crash-loop guard', () {
    IptvSyncService service() =>
        IptvSyncService(storeOverride: store, useIsolate: false, httpClientFactory: () => fakeIptvHttpClient(server));

    test('a refresh the app died in skips the next automatic one, twice backs off to the interval', () async {
      final source = m3uSource(server.base);
      // The app died during a refresh: the marker is still there.
      await store.putMeta(source.id, IptvSyncService.runningSinceKey, '1');

      var sync = service();
      sync.watch(source);
      await sync.check(source.id);
      expect(sync.isRunning(source.id), isFalse, reason: 'automatic refresh skipped');
      expect(server.requests, isEmpty);
      expect(await store.meta(source.id, IptvSyncService.runningSinceKey), isNull);
      expect(await store.meta(source.id, IptvSyncService.interruptedKey), '1');
      final record = await store.syncRecord(source.id, IptvSyncWorker.playlistKind);
      expect(record.error, IptvSyncService.interruptedError);
      expect(await store.meta(source.id, IptvSyncService.holdUntilKey), isNull);

      // Died again in the next run's refresh: wait for the next interval.
      await store.putMeta(source.id, IptvSyncService.runningSinceKey, '2');
      sync = service();
      sync.watch(source);
      await sync.check(source.id);
      expect(server.requests, isEmpty);
      expect(await store.meta(source.id, IptvSyncService.interruptedKey), '2');
      expect(await store.meta(source.id, IptvSyncService.holdUntilKey), isNotNull);
      // A later run still waits.
      sync = service();
      sync.watch(source);
      await sync.check(source.id);
      expect(server.requests, isEmpty);

      // Refreshing by hand works, and a finished refresh clears the guard.
      await sync.refresh(source.id);
      expect(await store.channelCount(source.id), greaterThan(0));
      expect(await store.meta(source.id, IptvSyncService.runningSinceKey), isNull);
      expect(await store.meta(source.id, IptvSyncService.interruptedKey), isNull);
      expect(await store.meta(source.id, IptvSyncService.holdUntilKey), isNull);
    });

    test('a refresh that fails normally clears its marker', () async {
      server.failEverything = true;
      final source = m3uSource(server.base);
      final sync = service();
      await sync.refresh(source.id, connection: source);
      expect(await store.meta(source.id, IptvSyncService.runningSinceKey), isNull);
      expect(await store.meta(source.id, IptvSyncService.interruptedKey), isNull);
    });

    test('automatic refreshes wait for the start delay and Home', () async {
      final source = m3uSource(server.base);
      final sync = IptvSyncService(
        storeOverride: store,
        useIsolate: false,
        httpClientFactory: () => fakeIptvHttpClient(server),
        startDelay: const Duration(milliseconds: 50),
        startDeadline: const Duration(seconds: 30),
      );
      sync.watch(source);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sync.automaticStarted, isFalse, reason: 'Home has not loaded');
      expect(server.requests, isEmpty);
      sync.homeLoaded();
      expect(sync.automaticStarted, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sync.refresh(source.id); // shares the running one
      expect(await store.channelCount(source.id), greaterThan(0));
    });
  });
}
