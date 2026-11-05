import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/screens/settings/add_silo_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_host.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_protocol.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/device_identity.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/silo_auth_fake.dart';
import '../../test_helpers/silo_pairing_phone.dart';

/// Several accounts from one phone session (Silo Android #810), saved with
/// the real persistence: the same-server rule, the summary, and the exit.

class _NoTimerPlexHomeService extends PlexHomeService {
  _NoTimerPlexHomeService({required super.connections, required super.profileConnections, required super.storage});

  @override
  Future<void> start() async {}

  @override
  Future<void> reloadFromStorage() async {}
}

class _NoWatchActiveProfileProvider extends ActiveProfileProvider {
  _NoWatchActiveProfileProvider({
    required super.registry,
    required super.plexHome,
    required super.connections,
    required super.profileConnections,
    required super.storage,
  });

  @override
  Future<void> initialize() async {}
}

class _Binder implements ActiveProfileBinder {
  int rebinds = 0;

  @override
  Future<void> rebindIfActive(String profileId) async => rebinds++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness(this.db, this.storage)
    : profiles = ProfileRegistry(db),
      connections = ConnectionRegistry(db),
      joins = ProfileConnectionRegistry(db) {
    plexHome = _NoTimerPlexHomeService(connections: connections, profileConnections: joins, storage: storage);
    active = _NoWatchActiveProfileProvider(
      registry: profiles,
      plexHome: plexHome,
      connections: connections,
      profileConnections: joins,
      storage: storage,
    );
  }

  final AppDatabase db;
  final StorageService storage;
  final ProfileRegistry profiles;
  final ConnectionRegistry connections;
  final ProfileConnectionRegistry joins;
  late final PlexHomeService plexHome;
  late final ActiveProfileProvider active;
  final binder = _Binder();

  Widget app(Widget Function(BuildContext context) home) => MultiProvider(
    providers: [
      Provider<AppDatabase>.value(value: db),
      Provider<StorageService>.value(value: storage),
      Provider<ProfileRegistry>.value(value: profiles),
      Provider<ConnectionRegistry>.value(value: connections),
      Provider<ProfileConnectionRegistry>.value(value: joins),
      ChangeNotifierProvider<ActiveProfileProvider>.value(value: active),
      Provider<ActiveProfileBinder>.value(value: binder),
    ],
    child: MaterialApp(
      theme: monoTheme(MonoPalette.dark),
      home: Builder(builder: home),
    ),
  );

  Future<void> dispose() async {
    await active.resetForTesting();
    active.dispose();
    await plexHome.dispose();
    await db.close();
  }
}

Future<void> _frames(WidgetTester tester, {int count = 6}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late _Harness harness;
  late FakeSiloAuthServer server;
  late SiloPairingHost host;
  late Future<bool?> route;

  setUp(() async {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    harness = _Harness(AppDatabase.forTesting(NativeDatabase.memory()), await StorageService.getInstance());
    server = FakeSiloAuthServer()
      ..hostIdentities = {'silo.example.com': 'srv-1', 'cabin.example.com': 'srv-2'}
      ..hostNames = {'silo.example.com': 'Home', 'cabin.example.com': 'Cabin'}
      ..profilesByToken = {
        'acc-laura': [
          {'id': 'p-laura', 'name': 'Laura', 'has_pin': false},
        ],
        'acc-sam': [
          {'id': 'p-sam', 'name': 'Sam', 'has_pin': false},
        ],
      };
  });

  tearDown(() async {
    DeviceIdentityService.debugOverride(null);
    await harness.dispose();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
    DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'Android', deviceName: 'Den TV'));
    SiloPairingHost? opened;
    await tester.pumpWidget(
      harness.app(
        (context) => TextButton(
          onPressed: () => route = Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => AddSiloScreen(
                authService: server.service(),
                phoneSignIn: true,
                pairingAdvertiser: FakePairingAdvertiser(),
                onPairingHost: (h) => opened = h,
              ),
            ),
          ),
          child: const Text('Open route'),
        ),
      ),
    );
    await tester.tap(find.text('Open route'));
    await _frames(tester, count: 10);
    host = opened!;
  }

  /// Silo's phone signs in each of [pushes] as [users] (null: the code is
  /// declined), then sends `done`.
  Future<List<SiloPairingServerResult>> phoneSignsIn(
    WidgetTester tester,
    FakePairingTransport phone,
    List<SiloPairingPushServer> pushes,
    List<String?> users, {
    bool sendDone = true,
  }) async {
    unawaited(host.receiver.run(phone));
    await _frames(tester, count: 2);
    expect(phone.sent.first, isA<SiloPairingHello>());
    return phone.signInAccounts(
      pushes,
      sendDone: sendDone,
      onPushed: (i) async {
        await _frames(tester, count: 2);
        if (find.text('Allow').evaluate().isNotEmpty) await tester.tap(find.text('Allow'));
        await _frames(tester);
      },
      approve: (i, started) async {
        final deviceCode = 'dev-${started.userCode.substring(7)}';
        final user = users[i];
        final previous = server.pollAnswer;
        server.pollAnswer = (code) => code != deviceCode
            ? previous(code)
            : user == null
            ? siloJson({'status': 'denied'})
            : FakeSiloAuthServer.approved(userId: 'u-$user', username: user, accessToken: 'acc-$user');
        for (var j = 0; j < 8; j++) {
          await tester.pump(const Duration(seconds: 1));
        }
      },
    );
  }

  /// The session's teardown and the saves (vault encryption) need real time.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await _frames(tester, count: 4);
    }
  }

  Future<({List<String> profiles, Map<String, String> joins})> saved(WidgetTester tester) async {
    // Read in the test's zone while real time and frames go by: a save the
    // screen started there may still hold the database.
    final pending = () async {
      final profiles = await harness.profiles.list();
      final joins = await harness.joins.listAll();
      final connections = {for (final c in await harness.connections.list()) c.id: c};
      return (
        profiles: [for (final p in profiles) p.displayName],
        joins: {
          for (final j in joins)
            (connections[j.connectionId]! as SiloConnection).userName: profiles
                .firstWhere((p) => p.id == j.profileId)
                .displayName,
        },
      );
    }();
    ({List<String> profiles, Map<String, String> joins})? read;
    unawaited(pending.then((value) => read = value));
    for (var i = 0; i < 200 && read == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    return read!;
  }

  testWidgets('two accounts on two servers share the profile; a summary names where they went', (tester) async {
    await open(tester);
    final phone = FakePairingTransport();
    final results = await phoneSignsIn(
      tester,
      phone,
      const [
        SiloPairingPushServer(serverUrl: 'https://silo.example.com', serverName: 'Home', serverIdentity: 'srv-1'),
        SiloPairingPushServer(
          serverUrl: 'https://cabin.example.com',
          serverName: 'Cabin',
          serverIdentity: 'srv-2',
          accountName: 'sam',
        ),
      ],
      ['laura', 'sam'],
    );
    expect(results.map((r) => r.status), everyElement(SiloPairingServerStatus.signedIn));
    // One consent for the session.
    expect(server.countOf('/api/v2/auth/device/start'), 2);
    await settle(tester);

    expect(find.text('2 accounts added'), findsOneWidget);
    expect(find.text('Laura (laura) on Home, in the profile Laura'), findsOneWidget);
    expect(find.text('Sam (sam) on Cabin, in the profile Laura'), findsOneWidget);
    final rows = await saved(tester);
    expect(rows.profiles, ['Laura']);
    expect(rows.joins, {'laura': 'Laura', 'sam': 'Laura'});
    expect(server.countOf('/api/v2/auth/logout'), 0);

    await tester.tap(find.text('Done'));
    await _frames(tester, count: 10);
    expect(await route, isTrue);
  });

  testWidgets('a second account on the same server goes into a new profile', (tester) async {
    await open(tester);
    final phone = FakePairingTransport();
    await phoneSignsIn(
      tester,
      phone,
      const [
        SiloPairingPushServer(serverUrl: 'https://silo.example.com', serverName: 'Home', serverIdentity: 'srv-1'),
        SiloPairingPushServer(serverUrl: 'https://silo.example.com', serverName: 'Home', serverIdentity: 'srv-1'),
      ],
      ['laura', 'sam'],
    );
    await settle(tester);

    expect(find.text('2 accounts added'), findsOneWidget);
    expect(find.text('Sam (sam) on Home, in a new profile, Sam'), findsOneWidget);
    expect(find.text('Switch profiles to use an account that is in another profile.'), findsOneWidget);
    final rows = await saved(tester);
    expect(rows.profiles, unorderedEquals(['Laura', 'Sam']));
    expect(rows.joins, {'laura': 'Laura', 'sam': 'Sam'});
    expect(harness.active.active?.displayName, 'Laura', reason: 'the first account stays the open one');

    await tester.tap(find.text('Done'));
    await _frames(tester, count: 10);
    expect(await route, isTrue);
  });

  testWidgets('a failed account then a good one: the session goes on and the good one is saved', (tester) async {
    await open(tester);
    final phone = FakePairingTransport();
    final results = await phoneSignsIn(
      tester,
      phone,
      const [
        SiloPairingPushServer(serverUrl: 'https://silo.example.com', serverName: 'Home', serverIdentity: 'srv-1'),
        SiloPairingPushServer(serverUrl: 'https://cabin.example.com', serverName: 'Cabin', serverIdentity: 'srv-2'),
      ],
      [null, 'sam'],
    );
    expect(results.map((r) => r.error), ['denied', null]);
    await settle(tester);

    // One account: saved and left, as any sign-in.
    expect(await route, isTrue);
    final rows = await saved(tester);
    expect(rows.joins, {'sam': 'Sam'});
  });

  testWidgets('leaving before the session ends signs the held accounts out', (tester) async {
    await open(tester);
    final phone = FakePairingTransport();
    await phoneSignsIn(
      tester,
      phone,
      const [SiloPairingPushServer(serverUrl: 'https://silo.example.com', serverName: 'Home', serverIdentity: 'srv-1')],
      ['laura'],
      sendDone: false,
    );
    // The phone has not sent done: the TV holds the account and waits.
    expect(find.text('Signed in'), findsOneWidget);
    expect(server.countOf('/api/v2/auth/logout'), 0);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    expect(server.countOf('/api/v2/auth/logout'), greaterThanOrEqualTo(1));
    final rows = await saved(tester);
    expect(rows.joins, isEmpty);
  });
}
