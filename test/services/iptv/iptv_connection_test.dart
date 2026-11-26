import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/iptv/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_recorder.dart';
import 'package:plezy/services/iptv/iptv_source_cleanup.dart';
import 'package:plezy/services/iptv/iptv_store.dart';
import 'package:plezy/services/iptv/iptv_sync_service.dart';
import 'package:plezy/services/multi_server_manager.dart';

import '../../test_helpers/prefs.dart';
import 'iptv_test_helpers.dart';

IptvConnection fullSource() => IptvConnection(
  id: 'iptv-abc',
  sourceType: IptvSourceType.xtream,
  name: 'My source',
  m3uUrl: 'http://m.example/get.php?username=u&password=p',
  xtreamServer: 'http://x.example:8080',
  xtreamUsername: 'user1',
  xtreamPassword: 'pass1',
  xtreamOutput: 'm3u8',
  epgUrls: ['http://g.example/a.xml.gz?token=t', 'http://g.example/b.xml'],
  useSourceEpg: false,
  userAgent: 'UA/1',
  referrer: 'http://ref.example/',
  playlistRefreshHours: 6,
  epgRefreshHours: 3,
  epgShiftMinutes: -30,
  epgPastDays: 4,
  epgFutureDays: 5,
  numbering: IptvChannelNumbering.automatic,
  includeVod: false,
  lockedGroups: ['Adults'],
  createdAt: DateTime(2026, 1, 2),
);

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  test('ids hold no colon and the source is its own server', () {
    final id = IptvConnection.newId();
    expect(id, startsWith('iptv-'));
    expect(id.contains(':'), isFalse);
    expect(IptvConnection.newId(), isNot(id));
    final c = fullSource();
    expect(c.kind, MediaBackend.iptv);
    expect(c.serverId, c.id);
    expect(c.displaySubtitle, 'Xtream · x.example');
  });

  test('IPTV titles are never offered for download, and no other backend lost downloads', () {
    expect(MediaBackend.iptv.supportsDownloads, isFalse);
    for (final backend in MediaBackend.values.where((b) => b != MediaBackend.iptv)) {
      expect(backend.supportsDownloads, isTrue, reason: backend.id);
    }
    expect(MediaBackend.fromId('iptv'), MediaBackend.iptv);
    expect(MediaBackend.fromString('iptv'), MediaBackend.iptv);
    expect(MediaBackend.iptv.usesMediaBrowserApi, isFalse);
  });

  test('config JSON round-trips every field', () {
    final original = fullSource();
    final restored = IptvConnection.fromConfigJson(
      id: original.id,
      json: original.toConfigJson(),
      createdAt: original.createdAt,
    );
    expect(restored.toConfigJson(), original.toConfigJson());
    expect(restored.epgUrls, original.epgUrls);
    expect(restored.lockedGroups, ['Adults']);
    expect(restored.numbering, IptvChannelNumbering.automatic);
    final off = IptvConnection.fromConfigJson(
      id: original.id,
      json: original.copyWith(enabled: false).toConfigJson(),
      createdAt: original.createdAt,
    );
    expect(off.enabled, isFalse);
  });

  test('the vault encrypts the playlist address, login and guide addresses', () async {
    final config = fullSource().toConfigJson();
    final protected = await CredentialVault.protectConnectionConfig('iptv', config);
    for (final key in ['m3uUrl', 'xtreamServer', 'xtreamUsername', 'xtreamPassword', 'epgUrls']) {
      expect(CredentialVault.isProtected(protected[key] as String), isTrue, reason: key);
    }
    expect(protected['name'], 'My source');
    final revealed = await CredentialVault.revealConnectionConfig('iptv', protected.cast<String, dynamic>());
    expect(revealed.config['xtreamPassword'], 'pass1');
    expect(revealed.config['epgUrls'], 'http://g.example/a.xml.gz?token=t\nhttp://g.example/b.xml');
  });

  test('the registry stores and reads an IPTV source with its secrets encrypted', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final registry = ConnectionRegistry(db);
    await registry.upsert(fullSource());
    final rows = await db.select(db.connections).get();
    expect(rows.single.kind, 'iptv');
    expect(rows.single.configJson.contains('pass1'), isFalse);
    final back = (await registry.list()).single as IptvConnection;
    expect(back.xtreamPassword, 'pass1');
    expect(back.epgUrls, hasLength(2));
    await db.close();
  });

  test('removing a source deletes its stored data and recordings, leaving other sources', () async {
    final store = memoryIptvStore();
    IptvRecorder.testInstance = IptvRecorder(store: store);
    final gone = fullSource();
    const kept = 'iptv-kept';
    for (final id in [gone.id, kept]) {
      await store.replaceChannels(id, [
        IptvChannel(sourceId: id, id: 'c', name: 'C', sortIndex: 0, url: 'u'),
      ], const []);
      await store.setFavoriteChannelIds(id, ['c']);
      await store.saveProgress(id, 'm1', positionMs: 1, durationMs: 2, watched: false);
      await store.addReminder(IptvReminder(sourceId: id, channelId: 'c', start: 1, stop: 2, title: 't'));
    }
    await store.putRecording(
      IptvRecordingRow(
        id: 'r1',
        sourceId: gone.id,
        channelId: 'c',
        title: 'T',
        start: 1,
        stop: 2,
        state: IptvRecordingState.completed,
      ),
    );
    await IptvSourceCleanup.remove(gone);
    expect(await store.channelCount(gone.id), 0);
    expect(await store.favoriteChannelIds(gone.id), isEmpty);
    expect(await store.progress(gone.id, 'm1'), isNull);
    expect(await store.recordings(sourceId: gone.id), isEmpty);
    expect(await store.reminders(sourceId: gone.id), isEmpty);
    expect(await store.channelCount(kept), 1);
    expect(await store.favoriteChannelIds(kept), ['c']);
    IptvRecorder.testInstance = null;
    await store.db.close();
  });

  test('the server manager adds, reuses and removes an IPTV client and stops refreshing it', () async {
    final store = memoryIptvStore();
    IptvSyncService.testInstance = IptvSyncService(storeOverride: store, useIsolate: false);
    final built = <IptvClient>[];
    final manager = MultiServerManager(
      connectivityChanges: () => const Stream.empty(),
      iptvClientFactory: (c) async {
        final client = IptvClient(c, store: store);
        built.add(client);
        return client;
      },
    );
    final source = m3uSource('http://127.0.0.1:9', id: 'iptv-mgr');
    expect(await manager.addIptvConnection(source), isTrue, reason: 'an M3U source is always online');
    expect(manager.getClient(ServerId(source.id)), isA<IptvClient>());
    expect(manager.iptvClient(source.id), same(built.single));
    expect(await manager.addIptvConnection(source.copyWith(name: 'Renamed')), isTrue);
    expect(built, hasLength(1), reason: 'an edit reuses the client');
    expect(built.single.connection.name, 'Renamed');
    manager.removeIptvConnection(source);
    expect(manager.getClient(ServerId(source.id)), isNull);
    expect(manager.iptvClients, isEmpty);
    manager.dispose();
    IptvSyncService.testInstance = null;
    // Let the background refresh attempt of the unreachable address settle.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await store.db.close();
  });
}
