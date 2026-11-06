import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/focusable_button.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/add_silo_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/device_identity.dart';
import 'package:plezy/widgets/auth_error_banner.dart';
import 'package:provider/provider.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/silo_auth_fake.dart';

/// An expired Silo session's banner opens "Sign in again" on that connection.

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'Linux', deviceName: 'Test'));
  });

  tearDown(() => DeviceIdentityService.debugOverride(null));

  testWidgets('D-pad Select on Sign in again opens it for the Silo connection whose session expired', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
    final manager = MultiServerManager(
      siloClientFactory: (connection) async => SiloClient.forTesting(
        connection,
        headers: siloTestHeaders,
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'id': '1', 'role': 'member'}),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      ),
    );
    final provider = testMultiServerProvider(manager);
    final connections = ConnectionRegistry(db);
    final joins = ProfileConnectionRegistry(db);
    final storage = await StorageService.getInstance();
    final plexHome = PlexHomeService(connections: connections, profileConnections: joins, storage: storage);
    final active = ActiveProfileProvider(
      registry: ProfileRegistry(db),
      plexHome: plexHome,
      connections: connections,
      profileConnections: joins,
      storage: storage,
    );
    addTearDown(() async {
      active.dispose();
      await plexHome.dispose();
      provider.dispose();
      manager.dispose();
      await db.close();
    });
    await tester.runAsync(() => manager.addSiloConnection(_silo));
    manager.debugMarkAuthErrorForTesting(ServerId('srv-1'));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: active),
        ],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: const Scaffold(body: AuthErrorBanner()),
        ),
      ),
    );
    expect(find.text(t.connections.signInAgain), findsOneWidget);

    Focus.of(tester.element(find.byType(FilledButton))).requestFocus();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      Focus.of(tester.element(find.byType(FilledButton))),
      reason: 'the banner button takes D-pad focus',
    );
    expect(find.byType(FocusableButton), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final screen = tester.widget<AddSiloScreen>(find.byType(AddSiloScreen));
    expect(screen.editConnection?.id, _silo.id);
    expect(screen.signInAgain, isTrue);
    expect(find.text('Sign in to Home Silo again'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
