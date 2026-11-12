import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_auth_service.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_connection_edit.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/silo_auth_fake.dart';

/// "Edit" / "Sign in again" on a saved Silo connection: what a sign-in does to
/// it, and how the editor saves an address or a new session.

SiloConnection _connection({
  String userId = '1',
  String profileId = 'p-owner',
  String accessToken = 'old-acc',
  String refreshToken = 'old-ref',
  String baseUrl = 'https://silo.example.com',
}) => SiloConnection(
  id: SiloConnection.compoundId(serverId: 'srv-1', userId: userId, profileId: profileId),
  baseUrl: baseUrl,
  serverName: 'Home Silo',
  serverId: 'srv-1',
  userId: userId,
  userName: 'laura',
  accessToken: accessToken,
  refreshToken: refreshToken,
  deviceId: 'dev-1',
  profileId: profileId,
  profileName: 'Laura',
  createdAt: DateTime(2025, 3, 4),
);

http.Response _json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ConnectionRegistry registry;

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
    registry = ConnectionRegistry(db);
  });

  tearDown(() => db.close());

  group('what a sign-in does to the edited connection', () {
    test('the same server, user and Silo profile is the same connection', () {
      expect(siloEditKind(_connection(), _connection(accessToken: 'new')), SiloEditKind.sameConnection);
    });

    test('another Silo profile of the account, or another account, is another connection', () {
      expect(siloEditKind(_connection(), _connection(profileId: 'p-kids')), SiloEditKind.otherProfile);
      expect(siloEditKind(_connection(), _connection(userId: '2')), SiloEditKind.otherAccount);
    });

    test('only the saved server identity is accepted at a new address', () {
      const same = SiloServerInfo(baseUrl: 'https://new.example.com', serverId: 'srv-1', serverName: 'Home Silo');
      const other = SiloServerInfo(baseUrl: 'https://new.example.com', serverId: 'srv-9', serverName: 'Elsewhere');
      expect(siloIsSameServer(_connection(), same), isTrue);
      expect(siloIsSameServer(_connection(), other), isFalse);
    });

    test('an address differs only when its canonical form does', () {
      expect(siloAddressChanged(_connection(), 'https://silo.example.com/'), isFalse);
      expect(siloAddressChanged(_connection(), 'https://silo.example.com:8443'), isTrue);
    });
  });

  group('SiloConnectionEditor', () {
    test('a new address keeps the stored session, including a pair rotated since the screen opened', () async {
      await registry.upsert(_connection());
      // The live client rotated the pair after the screen read the row.
      await registry.upsert(_connection(accessToken: 'acc-rotated', refreshToken: 'ref-rotated'));
      final fake = FakeSiloAuthServer();
      final editor = SiloConnectionEditor(registry: registry, auth: fake.service());

      await editor.changeAddress(_connection().id, 'https://new.example.com');

      final saved = await registry.get(_connection().id) as SiloConnection;
      expect(saved.baseUrl, 'https://new.example.com');
      expect(saved.refreshToken, 'ref-rotated');
      expect(saved.createdAt, DateTime(2025, 3, 4));
      expect(fake.countOf('/api/v2/auth/logout'), 0, reason: 'the session is kept');
    });

    test('a new session replaces the row in place and logs the old one out with the old token', () async {
      await registry.upsert(_connection());
      final fake = FakeSiloAuthServer();
      final editor = SiloConnectionEditor(registry: registry, auth: fake.service());

      await editor.replaceSession(_connection(accessToken: 'acc', refreshToken: 'ref'));
      await pumpEventQueue();

      final all = await registry.list();
      expect(all, hasLength(1));
      final saved = all.single as SiloConnection;
      expect(saved.id, _connection().id);
      expect(saved.accessToken, 'acc');
      expect(saved.createdAt, DateTime(2025, 3, 4));
      final logouts = fake.requests.where((r) => r.url.path == '/api/v2/auth/logout').toList();
      expect(logouts.map((r) => r.headers['Authorization']), ['Bearer old-acc']);
    });

    test('with a live client, the old session leaves the manager and is revoked with its newest token', () async {
      final logouts = <String?>[];
      final m = MultiServerManager(
        siloClientFactory: (connection) async => SiloClient.forTesting(
          connection,
          headers: siloTestHeaders,
          httpClient: MockClient((request) async {
            if (request.url.path == '/api/v2/auth/logout') {
              logouts.add(request.headers['Authorization']);
              return http.Response('', 204);
            }
            return _json({'id': '1', 'role': 'member', 'items': <Object>[]});
          }),
        ),
      );
      addTearDown(m.dispose);
      await registry.upsert(_connection());
      expect(await m.addSiloConnection(_connection()), isTrue);
      final editor = SiloConnectionEditor(registry: registry, auth: FakeSiloAuthServer().service(), serverManager: m);

      await editor.replaceSession(_connection(accessToken: 'acc', refreshToken: 'ref'));
      await pumpEventQueue();

      expect(m.getClient(ServerId('srv-1')), isNull, reason: 'the old client can no longer persist its session');
      expect(logouts, ['Bearer old-acc']);
      expect((await registry.get(_connection().id) as SiloConnection).accessToken, 'acc');

      // The rebind brings a client up on the new session.
      expect(await m.addSiloConnection(_connection(accessToken: 'acc', refreshToken: 'ref')), isTrue);
      expect((m.getClient(ServerId('srv-1')) as SiloClient).connection.accessToken, 'acc');
    });

    test('saving the session the row already holds revokes nothing', () async {
      await registry.upsert(_connection());
      final fake = FakeSiloAuthServer();
      await SiloConnectionEditor(registry: registry, auth: fake.service()).replaceSession(_connection());
      await pumpEventQueue();
      expect(fake.countOf('/api/v2/auth/logout'), 0);
    });
  });

  group('ConnectionRegistry.updateSiloSession (rotated tokens of a live client)', () {
    SiloConnection rotated(SiloConnection from) => from.copyWith(
      accessToken: 'acc-2',
      refreshToken: 'ref-2',
      accessTokenExpiresAt: DateTime(2030),
      accessTokenLifetimeSeconds: 900,
      isAdministrator: true,
    );

    test('stores only the tokens and admin role, keeping an address edited meanwhile, encrypted', () async {
      final client = _connection();
      await registry.upsert(client.copyWith(baseUrl: 'https://new.example.com'));

      final written = await registry.updateSiloSession(
        rotated(client),
        ownsRefreshToken: (t) => t == 'old-ref' || t == 'ref-2',
      );

      expect(written, isTrue);
      final stored = await registry.get(client.id) as SiloConnection;
      expect(stored.baseUrl, 'https://new.example.com', reason: 'the edit is not undone by the stale snapshot');
      expect(stored.accessToken, 'acc-2');
      expect(stored.refreshToken, 'ref-2');
      expect(stored.accessTokenLifetimeSeconds, 900);
      expect(stored.isAdministrator, isTrue);
      expect(stored.createdAt, client.createdAt);
      final row = (await db.select(db.connections).get()).single;
      expect(row.configJson, isNot(contains('ref-2')), reason: 'tokens are encrypted at rest');
      expect(row.configJson, isNot(contains('acc-2')));
    });

    test('a removed row stays removed', () async {
      final written = await registry.updateSiloSession(rotated(_connection()), ownsRefreshToken: (_) => true);
      expect(written, isFalse);
      expect(await registry.get(_connection().id), isNull);
    });

    test('a row a new sign-in replaced keeps the new session', () async {
      await registry.upsert(_connection(accessToken: 'new-acc', refreshToken: 'new-ref'));

      final written = await registry.updateSiloSession(
        rotated(_connection()),
        ownsRefreshToken: (t) => t == 'old-ref' || t == 'ref-2',
      );

      expect(written, isFalse);
      final stored = await registry.get(_connection().id) as SiloConnection;
      expect(stored.refreshToken, 'new-ref');
      expect(stored.accessToken, 'new-acc');
    });
  });
}
