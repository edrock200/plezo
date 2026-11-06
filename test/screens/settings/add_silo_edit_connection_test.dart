import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/screens/settings/add_silo_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/silo_auth_fake.dart';

/// "Edit" / "Sign in again" on a saved Silo connection, with the real
/// persistence: the same account keeps its id, bindings and downloads scope;
/// a new address is checked against the saved server identity; another
/// account or Silo profile follows the multi-account rule after saying so.

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
  @override
  Future<void> rebindIfActive(String profileId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _laura = Profile.local(id: 'local-laura', displayName: 'Laura', createdAt: DateTime(2025));

SiloConnection _saved() => SiloConnection(
  id: 'srv-1/1/p-owner',
  baseUrl: 'https://silo.example.com',
  serverName: 'Home Silo',
  serverId: 'srv-1',
  userId: '1',
  userName: 'laura',
  accessToken: 'old-acc',
  refreshToken: 'old-ref',
  deviceId: 'dev-1',
  profileId: 'p-owner',
  profileName: 'Laura',
  createdAt: DateTime(2025, 3, 4),
);

final _binding = ProfileConnection(
  profileId: 'local-laura',
  connectionId: 'srv-1/1/p-owner',
  userIdentifier: '1',
  isDefault: true,
  lastUsedAt: DateTime(2026, 10, 1),
);

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

  Widget app(Widget Function(BuildContext context) home) => MultiProvider(
    providers: [
      Provider<AppDatabase>.value(value: db),
      Provider<StorageService>.value(value: storage),
      Provider<ProfileRegistry>.value(value: profiles),
      Provider<ConnectionRegistry>.value(value: connections),
      Provider<ProfileConnectionRegistry>.value(value: joins),
      ChangeNotifierProvider<ActiveProfileProvider>.value(value: active),
      Provider<ActiveProfileBinder>.value(value: _Binder()),
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

String? _focused() => FocusManager.instance.primaryFocus?.debugLabel;

typedef _Saved = ({List<String> profiles, List<ProfileConnection> joins, List<SiloConnection> connections});

void main() {
  late _Harness harness;
  late FakeSiloAuthServer server;
  late Future<bool?> route;

  setUp(() async {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
    harness = _Harness(AppDatabase.forTesting(NativeDatabase.memory()), await StorageService.getInstance());
    server = FakeSiloAuthServer()
      ..hostIdentities = {'silo.example.com': 'srv-1', 'new.example.com': 'srv-1', 'other.example.com': 'srv-9'};
  });

  tearDown(() => harness.dispose());

  /// Read the database in the test's zone while real time and frames go by:
  /// a save the screen started may still hold it.
  Future<T> read<T>(WidgetTester tester, Future<T> Function() body) async {
    final pending = body();
    T? value;
    var done = false;
    unawaited(
      pending.then((v) {
        value = v;
        done = true;
      }),
    );
    for (var i = 0; i < 200 && !done; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(done, isTrue, reason: 'the database read finished');
    return value as T;
  }

  Future<_Saved> saved(WidgetTester tester) => read(tester, () async {
    final profiles = await harness.profiles.list();
    return (
      profiles: [for (final p in profiles) p.displayName],
      joins: await harness.joins.listAll(),
      connections: (await harness.connections.list()).cast<SiloConnection>(),
    );
  });

  /// Saves (vault encryption) need real time.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await _frames(tester, count: 4);
    }
  }

  Future<void> open(WidgetTester tester, {bool signInAgain = false}) async {
    await tester.runAsync(() async {
      await harness.profiles.upsert(_laura);
      await harness.connections.upsert(_saved());
      await harness.joins.upsert(_binding);
    });
    await tester.pumpWidget(
      harness.app(
        (context) => TextButton(
          onPressed: () => route = Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => AddSiloScreen(
                editConnection: _saved(),
                targetProfile: _laura,
                signInAgain: signInAgain,
                authService: server.service(),
                phoneSignIn: false,
              ),
            ),
          ),
          child: const Text('Open route'),
        ),
      ),
    );
    await tester.tap(find.text('Open route'));
    await _frames(tester, count: 10);
  }

  Future<void> probeAt(WidgetTester tester, String url) async {
    await tester.enterText(find.byType(TextField).first, url);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await _frames(tester);
  }

  Future<void> signInWithPassword(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).last, 'secret');
    await tester.tap(find.text('Sign in'));
    await _frames(tester);
  }

  Iterable<String?> logoutBearers() =>
      server.requests.where((r) => r.url.path == '/api/v2/auth/logout').map((r) => r.headers['Authorization']);

  testWidgets('signing in again as the same account keeps the id, the bindings and the downloads scope', (
    tester,
  ) async {
    await open(tester, signInAgain: true);
    // "Sign in again" checks the saved address at once and fills in the account.
    expect(find.text('Sign in to Home Silo again'), findsOneWidget);
    expect(find.text('laura'), findsOneWidget);
    expect(_focused(), 'AddSilo:Password');

    await signInWithPassword(tester);
    expect(find.text("Who's watching?"), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    await tester.tap(find.text('Laura'));
    await settle(tester);

    expect(await route, isTrue);
    final rows = await saved(tester);
    expect(rows.profiles, ['Laura'], reason: 'no new Plezilo profile');
    expect(rows.connections, hasLength(1));
    final connection = rows.connections.single;
    expect(connection.id, 'srv-1/1/p-owner');
    expect(connection.accessToken, 'acc');
    expect(connection.refreshToken, 'ref');
    expect(connection.createdAt, DateTime(2025, 3, 4));
    // The binding is untouched, so the download scope (the connection id the
    // default binding names) is the same.
    expect(rows.joins, [_binding]);
    // The replaced session is revoked with its own token, never the new one.
    expect(logoutBearers(), ['Bearer old-acc']);
  });

  testWidgets('a new address of the same server is saved keeping the sign-in', (tester) async {
    await open(tester);
    expect(find.text('Edit Home Silo'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'https://silo.example.com',
      reason: 'the saved address is filled in',
    );

    await probeAt(tester, 'https://new.example.com');
    expect(find.text('Save the new address'), findsOneWidget);
    expect(_focused(), 'AddSilo:EditSaveAddress');
    await tester.tap(find.text('Save the new address'));
    await settle(tester);

    expect(await route, isTrue);
    final rows = await saved(tester);
    expect(rows.connections.single.baseUrl, 'https://new.example.com');
    expect(rows.connections.single.accessToken, 'old-acc');
    expect(rows.joins, [_binding]);
    expect(logoutBearers(), isEmpty);
  });

  testWidgets("another server's identity at the new address is refused", (tester) async {
    await open(tester);
    await probeAt(tester, 'https://other.example.com');

    expect(find.text(t.siloEditConnection.wrongServer(server: 'Home Silo')), findsOneWidget);
    expect(find.text('Save the new address'), findsNothing);
    expect(find.text('Sign in with a code'), findsNothing, reason: 'still on the address step');
    final rows = await saved(tester);
    expect(rows.connections.single.baseUrl, 'https://silo.example.com');
  });

  testWidgets('another account says it goes to a new Plezilo profile, then saves it there', (tester) async {
    server.profilesByToken = {
      'acc-sam': [
        {'id': 'p-sam', 'name': 'Sam', 'has_pin': false},
      ],
    };
    server.pollAnswer = (_) => FakeSiloAuthServer.approved(userId: 'u-sam', username: 'sam', accessToken: 'acc-sam');
    await open(tester, signInAgain: true);
    await tester.tap(find.text('Sign in with a code'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await settle(tester);

    expect(find.text('This is another account'), findsOneWidget);
    expect(
      find.text(
        t.siloEditConnection.otherNewProfile(
          account: 'Sam (sam)',
          previous: 'Laura (laura)',
          profile: 'Sam',
          current: 'Laura',
        ),
      ),
      findsOneWidget,
    );
    final before = await saved(tester);
    expect(before.connections, hasLength(1), reason: 'nothing is saved before Continue');

    await tester.tap(find.text('Add this account'));
    await settle(tester);

    expect(await route, isTrue);
    final rows = await saved(tester);
    expect(rows.profiles, unorderedEquals(['Laura', 'Sam']));
    final byId = {for (final c in rows.connections) c.id: c};
    expect(byId['srv-1/1/p-owner']!.accessToken, 'old-acc', reason: 'the edited connection stays as it is');
    expect(byId['srv-1/u-sam/p-sam']!.accessToken, 'acc-sam');
    expect(rows.joins.where((j) => j.profileId == 'local-laura').map((j) => j.connectionId), ['srv-1/1/p-owner']);
    expect(logoutBearers(), isEmpty);
  });

  testWidgets('another Silo profile of the account asks first; Choose again goes back to the profiles', (tester) async {
    server.profiles = [
      {'id': 'p-owner', 'name': 'Laura', 'has_pin': false},
      {'id': 'p-theo', 'name': 'Theo', 'has_pin': false},
    ];
    await open(tester, signInAgain: true);
    await signInWithPassword(tester);
    await tester.tap(find.text('Theo'));
    await settle(tester);

    expect(find.text('This is another Silo profile'), findsOneWidget);
    expect(find.textContaining('a new Plezilo profile, Theo'), findsOneWidget);
    expect(_focused(), 'AddSilo:EditConfirm');
    // D-pad: Add this account, then Choose again, and back up.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_focused(), 'AddSilo:EditConfirmBack');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_focused(), 'AddSilo:EditConfirm');

    await tester.tap(find.text('Choose again'));
    await _frames(tester);
    expect(find.text("Who's watching?"), findsOneWidget);
    expect((await saved(tester)).connections, hasLength(1));

    // Leaving logs the unsaved session out (its own token), not the saved one.
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    expect(logoutBearers(), ['Bearer acc']);
  });

  testWidgets('D-pad: the address step, then the sign-in step with a new address', (tester) async {
    await open(tester);
    expect(_focused(), 'AddSilo:Url');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_focused(), 'AddSilo:FindServer');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_focused(), 'AddSilo:Url');

    await probeAt(tester, 'https://new.example.com');
    expect(_focused(), 'AddSilo:EditSaveAddress');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_focused(), 'AddSilo:Code');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_focused(), 'AddSilo:EditSaveAddress');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_focused(), 'AddSilo:ChangeServer');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_focused(), 'AddSilo:EditSaveAddress');

    await tester.pumpWidget(const SizedBox());
    await _frames(tester);
  });
}
