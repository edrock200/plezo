import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/screens/settings/add_iptv_screen.dart';
import 'package:plezy/services/iptv/iptv_store.dart';
import 'package:plezy/services/iptv/iptv_sync_service.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../../services/iptv/fake_iptv_server.dart';
import '../../services/iptv/iptv_test_helpers.dart';
import '../../test_helpers/prefs.dart';

Widget _app(Widget home) => MaterialApp(
  theme: monoTheme(MonoPalette.dark),
  home: InputModeTracker(child: home),
);

void main() {
  late FakeIptvServer server;
  late IptvStore store;
  late IptvSyncService sync;
  late List<IptvConnection> saved;

  setUp(() {
    resetSharedPreferencesForTest();
    server = FakeIptvServer();
    store = memoryIptvStore();
    sync = IptvSyncService(
      storeOverride: store,
      useIsolate: false,
      httpClientFactory: () => fakeIptvHttpClient(server),
    );
    saved = [];
  });

  tearDown(() async {
    await store.db.close();
  });

  /// A tall window: the whole form fits, so taps never miss.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget screen() => AddIptvScreen(syncService: sync, onSaved: (c) async => saved.add(c));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('asks for nothing but the source: no provider is named or suggested', (tester) async {
    tall(tester);
    await tester.pumpWidget(_app(screen()));
    await tester.pumpAndSettle();
    expect(find.text('Add IPTV Source'), findsOneWidget);
    expect(find.text('M3U playlist'), findsOneWidget);
    expect(find.text('Xtream login'), findsOneWidget);
    expect(find.text('Playlist (M3U) address'), findsOneWidget);
    expect(find.text('Guide (XMLTV) addresses'), findsOneWidget);
    expect(find.text('Add source'), findsOneWidget);
  });

  testWidgets('an M3U address is read before it is saved', (tester) async {
    tall(tester);
    await tester.pumpWidget(_app(screen()));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Playlist (M3U) address'), '${server.base}/playlist.m3u');
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Home playlist');
    await tester.ensureVisible(find.text('Add source'));
    await tester.tap(find.text('Add source'));
    await settle(tester);
    expect(saved, hasLength(1));
    expect(saved.single.name, 'Home playlist');
    expect(saved.single.sourceType, IptvSourceType.m3u);
    expect(await tester.runAsync(() => store.channelCount(saved.single.id)), 6);
  });

  testWidgets('a refused Xtream login is reported and nothing is saved', (tester) async {
    server.refuseLogin = true;
    tall(tester);
    await tester.pumpWidget(_app(screen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xtream login'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Server address'), server.base);
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'demo');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'wrong');
    await tester.ensureVisible(find.text('Add source'));
    await tester.tap(find.text('Add source'));
    await settle(tester);
    expect(saved, isEmpty);
    expect(find.text('The server refused this username and password.'), findsOneWidget);
    expect(await tester.runAsync(() => store.storedSourceIds()), isEmpty, reason: 'the partial import is dropped');
  });

  testWidgets('an Xtream login is saved with its movies and series', (tester) async {
    tall(tester);
    await tester.pumpWidget(_app(screen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xtream login'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Server address'), server.base);
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'demo');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret');
    await tester.ensureVisible(find.text('Add source'));
    await tester.tap(find.text('Add source'));
    await settle(tester);
    expect(saved.single.sourceType, IptvSourceType.xtream);
    expect(saved.single.name, 'iptv.test', reason: 'named after the host when no name is given');
    expect(await tester.runAsync(() => store.vodCount(saved.single.id, IptvGroupKind.movie)), 4);
  });

  testWidgets('an Xtream get.php address is offered as a login', (tester) async {
    tall(tester);
    await tester.pumpWidget(_app(screen()));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Playlist (M3U) address'),
      'http://x.example:8080/get.php?username=u1&password=p1&type=m3u_plus',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('This is an Xtream address: use it as a login'));
    await tester.tap(find.text('This is an Xtream address: use it as a login'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Server address'), findsOneWidget);
    expect(find.text('http://x.example:8080'), findsOneWidget);
    expect(find.text('u1'), findsOneWidget);
  });

  testWidgets('an empty M3U form says what is missing', (tester) async {
    tall(tester);
    await tester.pumpWidget(_app(screen()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add source'));
    await tester.tap(find.text('Add source'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the playlist address or choose a file.'), findsOneWidget);
  });

  testWidgets('the D-pad walks the form from the type tabs to the Add button', (tester) async {
    tall(tester);
    await tester.pumpWidget(_app(screen()));
    await tester.pumpAndSettle();
    String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
    expect(focused(), 'AddIptv:M3uTab');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focused(), 'AddIptv:XtreamTab');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Server address'), findsOneWidget, reason: 'Select switched the form');
    final seen = <String?>[];
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      seen.add(focused());
    }
    expect(seen, containsAllInOrder(['AddIptv:Name', 'AddIptv:Server', 'AddIptv:User', 'AddIptv:Password']));
    expect(seen.last, 'AddIptv:Add');
  });
}
