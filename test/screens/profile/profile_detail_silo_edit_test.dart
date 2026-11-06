import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/screens/profile/profile_detail_screen.dart';
import 'package:plezy/screens/settings/add_silo_screen.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/device_identity.dart';
import 'package:plezy/widgets/app_menu.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';

/// The Silo connection row's "Sign in again" and "Edit address" on the
/// profile page, reached with the D-pad.

final _profile = Profile.local(id: 'local-laura', displayName: 'Laura', createdAt: DateTime(2025));

final _silo = SiloConnection(
  id: 'srv-1/1/p-owner',
  baseUrl: 'https://silo.example.com',
  serverName: 'Home Silo',
  serverId: 'srv-1',
  userId: '1',
  userName: 'laura',
  accessToken: 'acc',
  refreshToken: 'ref',
  deviceId: 'dev-1',
  profileId: 'p-owner',
  profileName: 'Laura',
  createdAt: DateTime(2025),
);

class _Connections extends ConnectionRegistry {
  _Connections(super.db);

  @override
  Future<List<Connection>> list() async => [_silo];

  @override
  Stream<List<Connection>> watchConnections() => Stream.value([_silo]);
}

class _Profiles extends ProfileRegistry {
  _Profiles(super.db);

  @override
  Stream<List<Profile>> watchProfiles() => Stream.value([_profile]);
}

class _Joins extends ProfileConnectionRegistry {
  _Joins(super.db);

  @override
  Stream<List<ProfileConnection>> watchForProfile(String profileId) => Stream.value(const [
    // Not the default, so "Make default" leads the menu.
    ProfileConnection(profileId: 'local-laura', connectionId: 'srv-1/1/p-owner', userIdentifier: '1'),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'Linux', deviceName: 'Test'));
  });

  tearDown(() => DeviceIdentityService.debugOverride(null));

  Future<void> pumpDetail(WidgetTester tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final connections = _Connections(db);
    final joins = _Joins(db);
    final profiles = _Profiles(db);
    final storage = await StorageService.getInstance();
    final plexHome = PlexHomeService(
      connections: connections,
      profileConnections: joins,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    final active = ActiveProfileProvider(
      registry: profiles,
      plexHome: plexHome,
      connections: connections,
      profileConnections: joins,
      storage: storage,
    );
    addTearDown(() async {
      active.dispose();
      await plexHome.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            Provider<ProfileRegistry>.value(value: profiles),
            Provider<ProfileConnectionRegistry>.value(value: joins),
            Provider<ConnectionRegistry>.value(value: connections),
            Provider<PlexHomeService>.value(value: plexHome),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: active),
          ],
          child: InputModeTracker(
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: ProfileDetailScreen(profile: _profile),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Focus the Silo row's menu button and open it with Select, as a remote does.
  Future<void> openMenuWithDpad(WidgetTester tester) async {
    Focus.of(tester.element(find.byType(AppMenuButton<String>))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  Future<AddSiloScreen> pressAfter(WidgetTester tester, int downs) async {
    for (var i = 0; i < downs; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return tester.widget<AddSiloScreen>(find.byType(AddSiloScreen));
  }

  testWidgets('the Silo row offers Sign in again and Edit address, in that order after Make default', (tester) async {
    await pumpDetail(tester);
    await openMenuWithDpad(tester);
    final labels = [t.profiles.makeDefault, 'Sign in again', 'Edit address', t.profiles.removeConnection];
    final tops = [for (final label in labels) tester.getTopLeft(find.text(label).last).dy];
    expect(tops, orderedEquals([...tops]..sort()));
  });

  testWidgets('D-pad: Down once then Select opens Sign in again for this connection and profile', (tester) async {
    await pumpDetail(tester);
    await openMenuWithDpad(tester);
    final screen = await pressAfter(tester, 1);
    expect(screen.editConnection?.id, _silo.id);
    expect(screen.signInAgain, isTrue);
    expect(screen.targetProfile?.id, _profile.id);
    expect(find.text('Sign in to Home Silo again'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('D-pad: Down twice then Select opens Edit address at the saved address', (tester) async {
    await pumpDetail(tester);
    await openMenuWithDpad(tester);
    final screen = await pressAfter(tester, 2);
    expect(screen.editConnection?.id, _silo.id);
    expect(screen.signInAgain, isFalse);
    expect(find.text('Edit Home Silo'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'AddSilo:Url');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
