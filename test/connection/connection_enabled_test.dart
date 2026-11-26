import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_browser_dialect.dart';
import 'package:plezy/services/plex_auth_service.dart';

import '../services/tofa/tofa_fixtures.dart';
import '../test_helpers/prefs.dart';

/// The per-connection on/off switch: stored on the connection row, absent
/// (= on) for rows saved before it existed, kept by every token update.

final _created = DateTime.fromMillisecondsSinceEpoch(1_000_000);

List<Connection> _oneOfEach() => [
  PlexAccountConnection(
    id: 'plex-1',
    accountToken: 'plex-token',
    clientIdentifier: 'client-1',
    accountLabel: 'Plex',
    servers: [
      PlexServer(
        name: 'Plex Server',
        clientIdentifier: 'plex-machine',
        accessToken: 'server-token',
        connections: [
          PlexConnection(
            protocol: 'https',
            address: 'plex.example.com',
            port: 443,
            uri: 'https://plex.example.com',
            local: false,
            relay: false,
            ipv6: false,
          ),
        ],
        owned: true,
      ),
    ],
    createdAt: _created,
  ),
  JellyfinConnection(
    id: 'jf/u',
    baseUrl: 'https://jellyfin.example.com',
    serverName: 'Jellyfin',
    serverMachineId: 'jf',
    userId: 'u',
    userName: 'laura',
    accessToken: 'jf-token',
    deviceId: 'dev',
    createdAt: _created,
    dialect: MediaBrowserDialect.emby,
  ),
  SiloConnection(
    id: 'silo/1/p',
    baseUrl: 'https://silo.example.com',
    serverName: 'Silo',
    serverId: 'silo',
    userId: '1',
    userName: 'laura',
    accessToken: 'silo-acc',
    refreshToken: 'silo-ref',
    deviceId: 'dev',
    profileId: 'p',
    profileName: 'Laura',
    createdAt: _created,
  ),
  tofaConnection(),
];

void main() {
  late AppDatabase db;
  late ConnectionRegistry registry;

  setUp(() {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    registry = ConnectionRegistry(db);
  });

  tearDown(() => db.close());

  test('a new connection of every kind is on, and its config carries no switch key', () {
    for (final connection in _oneOfEach()) {
      expect(connection.enabled, isTrue, reason: connection.kind.id);
      expect(connection.toConfigJson().containsKey(Connection.enabledKey), isFalse, reason: connection.kind.id);
    }
  });

  test('switching off persists for every kind and survives a fresh registry (a restart)', () async {
    for (final connection in _oneOfEach()) {
      await registry.upsert(connection);
      final off = await registry.setEnabled(connection.id, false);
      expect(off?.enabled, isFalse, reason: connection.kind.id);
    }
    final restarted = ConnectionRegistry(db);
    for (final connection in await restarted.list()) {
      expect(connection.enabled, isFalse, reason: connection.kind.id);
    }
    for (final connection in _oneOfEach()) {
      expect((await restarted.setEnabled(connection.id, true))?.enabled, isTrue);
    }
    expect((await ConnectionRegistry(db).list()).every((c) => c.enabled), isTrue);
  });

  test('switching keeps the saved sign-in, creation order and every other field', () async {
    final tofa = tofaConnection(profileToken: 'ptok');
    await registry.upsert(tofa);
    await registry.setEnabled(tofa.id, false);
    final stored = (await registry.get(tofa.id))! as TofaConnection;
    expect(stored.accessToken, 'acc-1');
    expect(stored.refreshToken, 'ref-1');
    expect(stored.profileToken, 'ptok');
    expect(stored.createdAt, tofa.createdAt);
    final row = await db.select(db.connections).getSingle();
    expect(row.configJson, isNot(contains('acc-1')), reason: 'tokens stay encrypted');
    expect(jsonDecode(row.configJson)[Connection.enabledKey], isFalse);
  });

  test('a row saved before the switch existed reads as on', () async {
    final tofa = tofaConnection();
    await registry.upsert(tofa);
    final row = await db.select(db.connections).getSingle();
    final legacy = Map<String, Object?>.from(jsonDecode(row.configJson) as Map)..remove(Connection.enabledKey);
    await (db.update(
      db.connections,
    )..where((t) => t.id.equals(tofa.id))).write(ConnectionsCompanion(configJson: Value(jsonEncode(legacy))));
    expect((await registry.get(tofa.id))!.enabled, isTrue);
    expect(Connection.enabledFromConfig(const {}), isTrue);
    expect(Connection.enabledFromConfig(const {'enabled': 'yes'}), isTrue, reason: 'only false switches off');
  });

  test('a token rotation keeps a switched-off connection off', () async {
    final tofa = tofaConnection();
    await registry.upsert(tofa);
    await registry.setEnabled(tofa.id, false);
    final rotated = tofa.copyWith(accessToken: 'acc-2', refreshToken: 'ref-2');
    expect(await registry.updateTofaSession(rotated, ownsRefreshToken: (t) => t == 'ref-1'), isTrue);
    final stored = (await registry.get(tofa.id))! as TofaConnection;
    expect(stored.refreshToken, 'ref-2');
    expect(stored.enabled, isFalse);
  });

  test('switching an unknown connection does nothing', () async {
    expect(await registry.setEnabled('missing', false), isNull);
    expect(await registry.list(), isEmpty);
  });
}
