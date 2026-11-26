import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/focusable_button.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/screens/profile/profile_detail_screen.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/app_menu.dart';
import 'package:provider/provider.dart';

import '../../services/tofa/tofa_fixtures.dart';
import '../../test_helpers/prefs.dart';

/// The on/off switch on each connection row of the profile page: dimmed and
/// labelled when off, reachable with the D-pad and by touch, Remove kept.

final _profile = Profile.local(id: 'local-laura', displayName: 'Laura', createdAt: DateTime(2025));
final _off = tofaConnection().withEnabled(false);
final _on = JellyfinConnection(
  id: 'jf/u',
  baseUrl: 'https://jellyfin.example.com',
  serverName: 'Home Jellyfin',
  serverMachineId: 'jf',
  userId: 'u',
  userName: 'laura',
  accessToken: 'jf-token',
  deviceId: 'dev',
  createdAt: DateTime(2025),
);

class _Connections extends ConnectionRegistry {
  _Connections(super.db);

  @override
  Future<List<Connection>> list() async => [_off, _on];

  @override
  Stream<List<Connection>> watchConnections() => Stream.value([_off, _on]);
}

class _Profiles extends ProfileRegistry {
  _Profiles(super.db);

  @override
  Stream<List<Profile>> watchProfiles() => Stream.value([_profile]);
}

class _Joins extends ProfileConnectionRegistry {
  _Joins(super.db);

  @override
  Stream<List<ProfileConnection>> watchForProfile(String profileId) => Stream.value([
    ProfileConnection(profileId: _profile.id, connectionId: _off.id, userIdentifier: 'u-1', isDefault: true),
    ProfileConnection(profileId: _profile.id, connectionId: _on.id, userIdentifier: 'u'),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('a switched-off connection is labelled Disabled and keeps its menu with Remove', (tester) async {
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

    expect(find.text(t.profiles.connectionDisabled), findsOneWidget, reason: 'only the switched-off row');
    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches.map((s) => s.value), [false, true]);
    final offRow = find.byKey(ValueKey('connection-row:${_off.id}'));
    expect(
      find.descendant(of: offRow, matching: find.byType(Opacity)),
      findsWidgets,
      reason: 'dimmed',
    );

    await tester.tap(find.descendant(of: offRow, matching: find.byType(AppMenuButton<String>)));
    await tester.pumpAndSettle();
    expect(find.text(t.profiles.removeConnection), findsOneWidget);
  });

  group('ConnectionListRow', () {
    Future<List<bool>> pumpRow(WidgetTester tester, Connection connection) async {
      final changes = <bool>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: Scaffold(
                body: ConnectionListRow(
                  connection: connection,
                  subtitle: null,
                  onEnabledChanged: (enabled) async => changes.add(enabled),
                  onMenuSelected: (_) {},
                  menuItems: () => [AppMenuItem(value: 'remove', label: t.profiles.removeConnection)],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return changes;
    }

    FocusNode switchNode(WidgetTester tester, Connection connection) =>
        tester.widget<FocusableButton>(find.byKey(ValueKey('connection-switch:${connection.id}'))).focusNode!;

    testWidgets('D-pad: Left from the menu reaches the switch, Select turns it off, Right returns', (tester) async {
      final changes = await pumpRow(tester, _on);
      Focus.of(tester.element(find.byType(AppMenuButton<String>))).requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(switchNode(tester, _on).hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(changes, [false]);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(Focus.of(tester.element(find.byType(AppMenuButton<String>))).hasFocus, isTrue);
    });

    testWidgets('touch: tapping the switch of a switched-off connection turns it on', (tester) async {
      final changes = await pumpRow(tester, _off);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(changes, [true]);
      expect(find.text(t.profiles.connectionDisabled), findsOneWidget);
    });
  });
}
