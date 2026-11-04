import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';

import '../../test_helpers/prefs.dart';

/// Silo Android #795: several accounts signed in on one server. Each account
/// (and each Silo profile of it) is its own connection, client, token pair
/// and cache scope.

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _account(String user, {String token = '1'}) => SiloConnection(
  id: SiloConnection.compoundId(serverId: 'srv-1', userId: user, profileId: 'p-$user'),
  baseUrl: 'https://silo.example.com',
  serverName: 'Home Silo',
  serverId: 'srv-1',
  userId: user,
  userName: user,
  accessToken: 'acc-$user-$token',
  refreshToken: 'ref-$user-$token',
  deviceId: 'dev-1',
  profileId: 'p-$user',
  profileName: user,
  createdAt: DateTime(2026),
);

/// One Silo server with a login session per account.
class _FakeSilo {
  final sessions = <String>{'acc-laura-1', 'acc-sam-1'};
  final logouts = <String?>[];

  Future<http.Response> handle(http.Request request) async {
    final auth = request.headers['Authorization'];
    final path = request.url.path;
    if (path == '/api/v2/auth/logout') {
      logouts.add(auth);
      sessions.remove(auth?.replaceFirst('Bearer ', ''));
      return http.Response('', 204);
    }
    if (auth == null || !sessions.contains(auth.replaceFirst('Bearer ', ''))) return http.Response('', 401);
    if (path == '/api/v2/account/me') {
      return http.Response(
        jsonEncode({'id': 'x', 'role': 'member'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response(jsonEncode({'items': <Object>[]}), 200, headers: {'content-type': 'application/json'});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _FakeSilo server;
  late List<SiloClient> built;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
    server = _FakeSilo();
    built = [];
  });

  tearDown(() => db.close());

  MultiServerManager manager() => MultiServerManager(
    siloClientFactory: (connection) async {
      final client = SiloClient.forTesting(connection, headers: _headers, httpClient: MockClient(server.handle));
      built.add(client);
      return client;
    },
  );

  test('two accounts on one server get their own clients, tokens and cache scopes', () async {
    final m = manager();
    addTearDown(m.dispose);
    final laura = _account('laura');
    final sam = _account('sam');
    expect(laura.id, isNot(sam.id));

    expect(await m.addSiloConnection(laura), isTrue);
    expect(await m.addSiloConnection(sam), isTrue, reason: 'the second account does not replace the first');

    final lauraClient = m.getClientByScope(laura.id) as SiloClient;
    final samClient = m.getClientByScope(sam.id) as SiloClient;
    expect(identical(lauraClient, samClient), isFalse);
    expect(lauraClient.connection.accessToken, 'acc-laura-1');
    expect(samClient.connection.accessToken, 'acc-sam-1');
    expect(lauraClient.cacheServerId, laura.id);
    expect(samClient.cacheServerId, sam.id);
    expect(m.getClient(ServerId('srv-1')), same(samClient), reason: 'one active client per server');

    // Switching back (another Plezilo profile binds Laura) reuses her client.
    expect(await m.addSiloConnection(laura), isTrue);
    expect(built, hasLength(2));
    expect(m.getClient(ServerId('srv-1')), same(lauraClient));
  });

  test('the cache keeps one account\'s rows out of the other account\'s scope', () async {
    final cache = SiloApiCache.instance;
    final laura = _account('laura');
    final sam = _account('sam');
    await cache.put(ServerId(laura.id), 'silo:item/42', {'watched': true});
    expect(await cache.get(ServerId(laura.id), 'silo:item/42'), isNotNull);
    expect(await cache.get(ServerId(sam.id), 'silo:item/42'), isNull);
  });

  test('re-adding the same account (same server user id) updates its connection in place', () async {
    final m = manager();
    addTearDown(m.dispose);
    await m.addSiloConnection(_account('laura'));
    await m.addSiloConnection(_account('sam'));
    server.sessions.add('acc-laura-2');
    final readded = _account('laura', token: '2');
    expect(await m.addSiloConnection(readded), isTrue);
    final client = m.getClientByScope(readded.id) as SiloClient;
    expect(client.connection.refreshToken, 'ref-laura-2');
    expect((m.getClientByScope(_account('sam').id) as SiloClient).connection.accessToken, 'acc-sam-1');
  });

  test('removing one account signs out only that account', () async {
    final m = manager();
    addTearDown(m.dispose);
    final laura = _account('laura');
    final sam = _account('sam');
    await m.addSiloConnection(laura);
    await m.addSiloConnection(sam);

    m.removeSiloConnection(laura);
    await pumpEventQueue();
    expect(server.logouts, ['Bearer acc-laura-1']);
    expect(m.getClientByScope(laura.id), isNull);
    expect(m.getClient(ServerId('srv-1')), same(m.getClientByScope(sam.id)), reason: 'Sam stays active');
    expect(m.isServerOnline(ServerId('srv-1')), isTrue);
  });

  test('the registry keeps both accounts, encrypted, and updates one in place', () async {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    final registry = ConnectionRegistry(db);
    await registry.upsert(_account('laura'));
    await registry.upsert(_account('sam'));
    await registry.upsert(_account('laura', token: '2'));

    final stored = (await registry.list()).whereType<SiloConnection>().toList();
    expect(stored.map((c) => c.id).toSet(), {_account('laura').id, _account('sam').id});
    expect(stored.firstWhere((c) => c.userId == 'laura').refreshToken, 'ref-laura-2');
    expect(stored.firstWhere((c) => c.userId == 'sam').refreshToken, 'ref-sam-1');

    final rows = await db.select(db.connections).get();
    for (final row in rows) {
      expect(row.configJson, isNot(contains('ref-')), reason: 'tokens are encrypted at rest');
    }
  });
}
