import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/services/iptv/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_store.dart';
import 'package:plezy/services/iptv/iptv_sync_service.dart';
import 'package:plezy/services/iptv/iptv_sync_worker.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import 'fake_iptv_server.dart';
import 'iptv_test_helpers.dart';

/// Notes how many programmes were stored when movies started to be written.
class _OrderStore extends IptvStore {
  _OrderStore(super.db);
  int? programmesWhenVodStarted;

  @override
  Future<void> stageVod(String sourceId, IptvGroupKind kind, List<IptvVodRow> rows) async {
    programmesWhenVodStarted ??= await programmeCount(sourceId);
    return super.stageVod(sourceId, kind, rows);
  }
}

void main() {
  late FakeIptvServer server;
  late _OrderStore store;
  late AppDatabase appDb;

  setUp(() async {
    server = await FakeIptvServer().start();
    store = _OrderStore(IptvDatabase(NativeDatabase.memory()));
    IptvStore.testInstance = store;
    appDb = memoryAppDatabaseWithIptvCache();
  });

  tearDown(() async {
    await server.close();
    await store.db.close();
    await appDb.close();
    IptvStore.testInstance = null;
  });

  Future<String?> refresh(IptvConnection source) async {
    final worker = IptvSyncWorker(store: store, now: () => server.now);
    try {
      return await runIptvRefreshSteps(worker, source, playlist: true, epg: true, vod: true);
    } finally {
      worker.close();
    }
  }

  Future<Map<String, Object?>> guideState(String id) async =>
      (jsonDecode((await store.meta(id, IptvMetaKeys.guideState))!) as Map).cast<String, Object?>();

  test('the guide comes from the Xtream login, before movies and series are read', () async {
    final source = xtreamSource(server.base);
    expect(await refresh(source), isNull);
    expect(store.programmesWhenVodStarted, 6 * 24, reason: 'the guide is stored before VOD');
    expect(await store.vodCount(source.id, IptvGroupKind.movie), 4);
    expect((await guideState(source.id))['own'], 'ok');
    expect((await store.syncRecord(source.id, IptvSyncWorker.epgKind)).lastSuccess, isNotNull);
    expect((await store.syncRecord(source.id, IptvSyncWorker.vodKind)).lastSuccess, isNotNull);
    expect(server.requests.any((u) => u.path == '/xmltv.php'), isTrue);
  });

  test('a gzip guide without a gzip content type', () async {
    server.xmltvGzipNoHeader = true;
    final source = xtreamSource(server.base);
    expect(await refresh(source), isNull);
    expect(await store.programmeCount(source.id), 6 * 24);
    expect((await guideState(source.id))['own'], 'ok');
  });

  for (final (label, setup, own) in [
    ('404', (FakeIptvServer s) => s.xmltvStatus = 404, 'failed'),
    ('empty', (FakeIptvServer s) => s.xmltvEmpty = true, 'empty'),
  ]) {
    test('xmltv.php $label: channels read their guide from the provider when shown', () async {
      setup(server);
      final source = xtreamSource(server.base);
      await refresh(source);
      expect((await guideState(source.id))['own'], own);
      expect(await store.programmeCount(source.id), 0);
      expect(await store.vodCount(source.id, IptvGroupKind.movie), 4, reason: 'a failed guide does not stop VOD');

      final client = IptvClient(source, store: store, now: () => server.now);
      // Now and next (banner, channel list, mini guide) fill from the table.
      final nn = await client.nowNext('x1001');
      expect(nn.now?.title, 'Table 1001 at 0');
      expect(nn.next?.title, 'Table 1001 at 1');
      expect(server.requests.where((u) => u.queryParameters['action'] == 'get_simple_data_table'), hasLength(1));
      // Fresh for 2 h: asked once.
      await client.nowNext('x1001');
      expect(server.requests.where((u) => u.queryParameters['action'] == 'get_simple_data_table'), hasLength(1));

      // The grid: rows on screen are filled in the background, then shown.
      final live = client.liveTv;
      final onDemand = live as LiveTvGuideOnDemand;
      var filled = 0;
      void onFilled() => filled++;
      onDemand.guideFilled.addListener(onFilled);
      addTearDown(() => onDemand.guideFilled.removeListener(onFilled));
      onDemand.channelsShown(['x1002', 'x1003'], from: server.now, to: server.now.add(const Duration(hours: 3)));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (filled == 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(filled, greaterThan(0));
      final grid = await live.fetchSchedule(from: server.now, to: server.now.add(const Duration(hours: 2)));
      final titles = {for (final p in grid) p.channelIdentifier: p.title};
      expect(titles['x1002'], startsWith('Table 1002'));
      expect(titles['x1003'], startsWith('Table 1003'));
      client.close();
    });
  }

  test('listings with only local start/end times use the server offset', () {
    final entries = XtreamApi.parseListings({
      'epg_listings': [
        {'title': base64.encode(utf8.encode('A')), 'start': '2026-11-27 10:00:00', 'end': '2026-11-27 11:00:00'},
      ],
    }, serverOffset: const Duration(hours: 1));
    expect(entries.single.title, 'A');
    expect(entries.single.start, DateTime.utc(2026, 11, 27, 9).millisecondsSinceEpoch ~/ 1000);
    expect(entries.single.stop - entries.single.start, 3600);
  });
}
