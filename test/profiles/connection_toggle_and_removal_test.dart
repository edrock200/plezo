import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_cleanup.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/api_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/services/tofa/tofa_api_cache.dart';
import 'package:plezy/services/tofa/tofa_client.dart';

import '../services/tofa/tofa_fixtures.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

/// Removing a Tofa connection (also after a Tofa profile switch left a
/// sibling connection of the same sign-in behind), and switching connections
/// off and on again, against the real registries, binder and server manager.

TofaConnection _tofaProfile(String profileId) => TofaConnection(
  id: TofaConnection.compoundId(serverId: 'srv-1', userId: 'u-1', profileId: profileId),
  baseUrl: tofaBase,
  serverName: 'tofa.example.com',
  serverId: 'srv-1',
  connectUrl: tofaCloud,
  userId: 'u-1',
  userName: 'laura',
  accessToken: 'acc-1',
  refreshToken: 'ref-1',
  profileId: profileId,
  profileName: 'Profile $profileId',
  createdAt: DateTime(2026),
);

JellyfinConnection _jellyfin() => JellyfinConnection(
  id: 'jf/u',
  baseUrl: 'https://jellyfin.example.com',
  serverName: 'Jellyfin',
  serverMachineId: 'jf',
  userId: 'u',
  userName: 'laura',
  accessToken: 'jf-token',
  deviceId: 'dev',
  createdAt: DateTime(2026),
);

SiloConnection _silo() => SiloConnection(
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
  createdAt: DateTime(2026),
);

/// Jellyfin and Silo answer without a network; Tofa goes through [FakeTofa].
class _Manager extends MultiServerManager {
  _Manager({super.tofaClientFactory}) : super(connectivityChanges: () => const Stream.empty());

  final addedJellyfin = <String>[];
  final addedSilo = <String>[];

  @override
  Future<bool> addJellyfinConnection(JellyfinConnection connection) async {
    addedJellyfin.add(connection.id);
    updateServerStatus(ServerId(connection.serverMachineId), true);
    return true;
  }

  @override
  Future<bool> addSiloConnection(SiloConnection connection) async {
    addedSilo.add(connection.id);
    updateServerStatus(ServerId(connection.serverId), true);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late ConnectionRegistry connections;
  late ProfileConnectionRegistry joins;
  late ProfileRegistry profiles;
  late StorageService storage;
  late PlexHomeService plexHome;
  late ActiveProfileProvider active;
  late FakeTofa fake;
  late List<TofaClient> built;
  late _Manager manager;
  late MultiServerProvider servers;
  late ActiveProfileBinder binder;

  _Manager newManager() => _Manager(
    tofaClientFactory: (connection) async {
      final client = TofaClient.forTesting(connection, httpClient: fake.client);
      built.add(client);
      return client;
    },
  );

  ActiveProfileBinder newBinder() => ActiveProfileBinder(
    activeProfile: active,
    connections: connections,
    profileConnections: joins,
    serverManager: manager,
    multiServerProvider: servers,
    pinPrompt: (_, {String? errorMessage}) async => null,
    shouldDeferInitialBind: (_) async => false,
  );

  ProfileConnectionCleanup cleanup() => ProfileConnectionCleanup(
    profileConnections: joins,
    connections: connections,
    storage: storage,
    serverManager: manager,
  );

  setUp(() async {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    TofaApiCache.initialize(db);
    connections = ConnectionRegistry(db);
    joins = ProfileConnectionRegistry(db);
    profiles = ProfileRegistry(db);
    storage = await StorageService.getInstance();
    plexHome = PlexHomeService(
      connections: connections,
      profileConnections: joins,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    active = ActiveProfileProvider(
      registry: profiles,
      plexHome: plexHome,
      connections: connections,
      profileConnections: joins,
      storage: storage,
    );
    fake = FakeTofa()
      ..on(
        'GET',
        '/api/v1/users/me',
        (_) =>
            jsonResponse({'id': 'u-1', 'username': 'laura', 'is_admin': false, 'disabled': false, 'preferences': {}}),
      )
      ..on('GET', '/api/v1/auth/image-token', (_) => jsonResponse({'token': 'img', 'expires_in': 3600}));
    built = [];
    manager = newManager();
    servers = testMultiServerProvider(manager);
    binder = newBinder();
    final owner = Profile.local(id: 'owner', displayName: 'Owner', createdAt: DateTime(2026));
    await profiles.upsert(owner);
    await storage.setActiveProfileId(owner.id);
    await active.initialize();
  });

  tearDown(() async {
    binder.dispose();
    servers.dispose();
    manager.dispose();
    await active.resetForTesting();
    active.dispose();
    await plexHome.dispose();
    await db.close();
  });

  Future<void> link(String profileId, Connection connection) async {
    await connections.upsert(connection);
    await joins.upsert(ProfileConnection(profileId: profileId, connectionId: connection.id, userIdentifier: 'u'));
  }

  /// Settles the client's background reads (image token, Live TV probe).
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

  group('removing a Tofa connection', () {
    test('removes the row, the link and the client, and stays gone after a restart', () async {
      final tofa = _tofaProfile('p-1');
      await link('owner', tofa);
      await binder.rebindActive();
      expect(manager.getClient(ServerId('srv-1')), isA<TofaClient>());

      await cleanup().removeProfileConnection(profileId: 'owner', connection: tofa);
      await binder.rebindIfActive('owner');

      expect(await connections.list(), isEmpty, reason: 'the row (and the encrypted tokens in it) is gone');
      expect(await db.select(db.connections).get(), isEmpty);
      expect(await joins.listAll(), isEmpty);
      expect(manager.getClient(ServerId('srv-1')), isNull);
      expect(manager.getClientByScope(tofa.id), isNull);
      expect(manager.registeredServerIds, isEmpty);

      // A restart: fresh registry over the same database, start-up prune, bind.
      final restarted = ConnectionRegistry(db);
      expect(await restarted.list(), isEmpty);
      await binder.rebindActive();
      expect(built, hasLength(1), reason: 'no client is built for it again');
    });

    test('after a Tofa profile switch, the previous profile\'s connection goes with it', () async {
      // The switch screen's old behaviour: the first Tofa profile's row and
      // client outlive the switch, only its link moves to the new profile.
      final first = _tofaProfile('p-1');
      final second = _tofaProfile('p-2');
      await link('owner', first);
      await binder.rebindActive();
      await link('owner', second);
      await joins.remove('owner', first.id);
      await binder.rebindIfActive('owner');
      expect(manager.getClientByScope(first.id), isA<TofaClient>(), reason: 'the orphan the bug left running');
      await settle();

      await cleanup().removeProfileConnection(profileId: 'owner', connection: second);
      await binder.rebindIfActive('owner');

      expect(await connections.list(), isEmpty, reason: 'the sibling of the same sign-in is removed too');
      expect(await joins.listAll(), isEmpty);
      expect(manager.getClientByScope(first.id), isNull);
      expect(manager.getClientByScope(second.id), isNull);
      await settle();
      final calls = fake.requests.length;
      await manager.checkServerHealth();
      await settle();
      expect(fake.requests.length, calls, reason: 'neither client makes calls after the removal');
    });

    test('a sibling another Plezilo profile still links is kept', () async {
      final kids = Profile.local(id: 'kids', displayName: 'Kids', createdAt: DateTime(2026));
      await profiles.upsert(kids);
      final first = _tofaProfile('p-1');
      final second = _tofaProfile('p-2');
      await link('kids', first);
      await link('owner', second);

      await cleanup().removeProfileConnection(profileId: 'owner', connection: second);

      expect((await connections.list()).map((c) => c.id), [first.id]);
      expect((await joins.listAll()).map((r) => r.profileId), ['kids']);
    });

    test('clears the connection\'s cached pages but keeps pinned offline metadata', () async {
      final tofa = _tofaProfile('p-1');
      await link('owner', tofa);
      final cache = TofaApiCache.instance;
      final scope = ServerId(tofa.id);
      await cache.put(scope, 'tofa:item/volatile', {'a': 1});
      await cache.put(scope, 'tofa:item/offline', {'b': 2});
      await cache.pin(scope, 'tofa:item/offline');
      await cache.put(ServerId('other/u/p'), 'tofa:item/volatile', {'c': 3});

      await cleanup().removeProfileConnection(profileId: 'owner', connection: tofa);

      expect(await cache.get(scope, 'tofa:item/volatile'), isNull);
      expect(await cache.get(scope, 'tofa:item/offline'), isNotNull);
      expect(await cache.get(ServerId('other/u/p'), 'tofa:item/volatile'), isNotNull);
    });

    test('Jellyfin and Silo connections are removed the same way', () async {
      final jellyfin = _jellyfin();
      final silo = _silo();
      await link('owner', jellyfin);
      await link('owner', silo);
      await cleanup().removeProfileConnection(profileId: 'owner', connection: jellyfin);
      await cleanup().removeProfileConnection(profileId: 'owner', connection: silo);
      expect(await ConnectionRegistry(db).list(), isEmpty);
      expect(await joins.listAll(), isEmpty);
    });
  });

  group('switching a connection off and on', () {
    Future<void> switchTo(Connection connection, bool enabled) async {
      final updated = await connections.setEnabled(connection.id, enabled);
      if (!enabled) manager.disconnectConnection(updated!);
      await binder.rebindActive();
    }

    test('off: the link and sign-in stay saved, no client and no calls; on: back without signing in', () async {
      final tofa = _tofaProfile('p-1');
      await link('owner', tofa);
      await binder.rebindActive();
      expect(servers.onlineServerIds, ['srv-1']);
      await settle();

      await switchTo(tofa, false);
      expect(active.lastBindingSucceeded, isTrue, reason: 'nothing switched on is a settled bind');
      expect(manager.getClient(ServerId('srv-1')), isNull);
      expect(manager.getClientByScope(tofa.id), isNull);
      expect(servers.onlineServerIds, isEmpty);
      expect(servers.expectedServerIds, isEmpty);
      expect(await joins.listForProfile('owner'), hasLength(1), reason: 'the link stays');
      final saved = (await connections.get(tofa.id))! as TofaConnection;
      expect(saved.refreshToken, 'ref-1', reason: 'the sign-in stays');
      await settle();

      final calls = fake.requests.length;
      await binder.rebindActive();
      await manager.checkServerHealth();
      await settle();
      expect(fake.requests.length, calls, reason: 'a switched-off connection is never contacted');
      expect(built, hasLength(1));

      await switchTo(tofa, true);
      expect(built, hasLength(2));
      expect(built.last.connection.refreshToken, 'ref-1', reason: 'the saved sign-in is used again');
      expect(servers.onlineServerIds, ['srv-1']);
      expect(fake.requests.length, greaterThan(calls));
    });

    test('a switched-off connection stays off after a restart, and is not pruned', () async {
      final tofa = _tofaProfile('p-1');
      await link('owner', tofa);
      await connections.setEnabled(tofa.id, false);

      expect(await cleanup().pruneUnreferencedJellyfinConnections(), 0);
      final restarted = ConnectionRegistry(db);
      expect((await restarted.get(tofa.id))!.enabled, isFalse);
      await binder.rebindActive();
      expect(built, isEmpty);
      expect(fake.requests, isEmpty);
    });

    test('only the switched-off connection is left out; the others still bind', () async {
      final jellyfin = _jellyfin();
      final silo = _silo();
      await link('owner', jellyfin);
      await link('owner', silo);
      await binder.rebindActive();
      expect(servers.onlineServerIds.toSet(), {'jf', 'silo'});

      await switchTo(jellyfin, false);
      expect(servers.onlineServerIds, ['silo']);
      expect(manager.getClient(ServerId('jf')), isNull);
      manager.addedJellyfin.clear();
      await binder.rebindActive();
      expect(manager.addedJellyfin, isEmpty);

      await switchTo(jellyfin, true);
      expect(manager.addedJellyfin, [jellyfin.id]);
      expect(servers.onlineServerIds.toSet(), {'jf', 'silo'});
    });

    test('disconnecting closes the client without signing out', () async {
      final tofa = _tofaProfile('p-1');
      await link('owner', tofa);
      await binder.rebindActive();
      manager.disconnectConnection(tofa);
      expect(manager.getClientByScope(tofa.id), isNull);
      expect(manager.getClient(ServerId('srv-1')), isNull);
      expect(await connections.get(tofa.id), isNotNull);
      expect(ApiCache.forBackend(tofa.kind), isA<TofaApiCache>());
    });
  });
}
