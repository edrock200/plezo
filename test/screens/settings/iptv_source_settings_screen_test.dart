import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/screens/settings/iptv_group_editor_screen.dart';
import 'package:plezy/screens/settings/iptv_source_settings_screen.dart';
import 'package:plezy/services/iptv/iptv_store.dart';
import 'package:plezy/services/iptv/iptv_sync_service.dart';
import 'package:plezy/services/iptv/iptv_sync_worker.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../services/iptv/fake_iptv_server.dart';
import '../../services/iptv/iptv_test_helpers.dart';
import '../../test_helpers/prefs.dart';

void main() {
  late FakeIptvServer server;
  late IptvStore store;
  late IptvSyncService sync;
  late AppDatabase db;
  late ConnectionRegistry registry;

  setUp(() {
    resetSharedPreferencesForTest();
    server = FakeIptvServer();
    store = memoryIptvStore();
    sync = IptvSyncService(
      storeOverride: store,
      useIsolate: false,
      httpClientFactory: () => fakeIptvHttpClient(server),
    );
    db = AppDatabase.forTesting(NativeDatabase.memory());
    registry = ConnectionRegistry(db);
  });

  tearDown(() async {
    await store.db.close();
    await db.close();
  });

  Widget app(Widget home) => Provider<ConnectionRegistry>.value(
    value: registry,
    child: MaterialApp(
      theme: monoTheme(MonoPalette.dark),
      home: InputModeTracker(child: home),
    ),
  );

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('shows the source settings and saves a changed setting', (tester) async {
    tall(tester);
    final source = xtreamSource(server.base);
    await tester.runAsync(() async {
      await registry.upsert(source);
      final worker = IptvSyncWorker(store: store, client: fakeIptvHttpClient(server));
      await worker.importPlaylist(source);
    });
    await tester.pumpWidget(app(IptvSourceSettingsScreen(connection: source, store: store, syncService: sync)));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('Status'), findsOneWidget);
    expect(find.text('Stream format'), findsOneWidget);
    expect(find.text('Guide time shift'), findsOneWidget);
    expect(find.text('Channel numbers'), findsOneWidget);

    await tester.tap(find.text('Channel numbers'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Automatic (1, 2, 3…)'));
    await tester.pumpAndSettle();
    expect(find.text('Automatic (1, 2, 3…)'), findsOneWidget, reason: 'the row shows the new choice');
    expect(find.text('From the playlist where given'), findsNothing);
  });

  testWidgets('the D-pad reaches every row', (tester) async {
    tall(tester);
    final source = m3uSource(server.base);
    await tester.runAsync(() => registry.upsert(source));
    await tester.pumpWidget(app(IptvSourceSettingsScreen(connection: source, store: store, syncService: sync)));
    await tester.pumpAndSettle();
    final labels = <String>{};
    for (var i = 0; i < 25; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus;
      if (focus?.context case final context?) {
        final tile = context.findAncestorWidgetOfExactType<ListTile>();
        final title = tile?.title;
        if (title is Text && title.data != null) labels.add(title.data!);
      }
    }
    expect(labels, containsAll(<String>['Name', 'Playlist refresh', 'User-agent', 'Guide time shift', 'Groups']));
  });

  testWidgets('the group editor hides a group and locks one', (tester) async {
    final source = m3uSource(server.base);
    await tester.runAsync(() async {
      final worker = IptvSyncWorker(store: store, client: fakeIptvHttpClient(server));
      await worker.importPlaylist(source);
    });
    List<String>? locked;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              locked = await Navigator.of(context).push<List<String>>(
                MaterialPageRoute(
                  builder: (_) => IptvGroupEditorScreen(sourceId: source.id, lockedGroups: const [], store: store),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('News'), findsOneWidget);
    expect(find.text('Sport'), findsOneWidget);

    await tester.tap(find.text('Sport'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide group'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    final groups = await tester.runAsync(() => store.groups(source.id, IptvGroupKind.live));
    expect(groups!.firstWhere((g) => g.name == 'Sport').hidden, isTrue);

    await tester.tap(find.text('News'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lock (parental filter)'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(locked, ['News']);
  });
}
