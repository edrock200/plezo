import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/live_tv_group_bar.dart';
import 'package:plezy/screens/livetv/live_tv_screen.dart';
import 'package:plezy/screens/livetv/tabs/channels_tab.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/iptv/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_store.dart';
import 'package:plezy/services/iptv/iptv_sync_worker.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../services/iptv/fake_iptv_server.dart';
import '../../services/iptv/iptv_test_helpers.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

/// The Live TV screens with an IPTV source: the Channels tab, the group bar
/// and its filter, on touch and the D-pad.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late IptvStore store;
  late FakeIptvServer server;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.liveTvDefaultFavorites, false);
    store = memoryIptvStore();
    server = FakeIptvServer()..logos = false;
  });

  tearDown(() async => store.db.close());

  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<({MultiServerManager manager, MultiServerProvider provider})> pumpScreen(WidgetTester tester) async {
    final source = m3uSource(server.base);
    await tester.runAsync(() async {
      final worker = IptvSyncWorker(store: store, client: fakeIptvHttpClient(server), now: () => server.now);
      await worker.importPlaylist(source);
      await worker.importEpg(source);
    });
    final client = IptvClient(source, store: store, now: () => server.now);
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    final provider = testMultiServerProvider(manager);
    provider.debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: source.id, dvrKey: 'iptv')]);
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: ChangeNotifierProvider<MultiServerProvider>.value(
            value: provider,
            child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const LiveTvScreen()),
          ),
        ),
      ),
    );
    await settle(tester);
    return (manager: manager, provider: provider);
  }

  List<LiveTvChannel> guideChannels(WidgetTester tester) => tester.widget<GuideTab>(find.byType(GuideTab)).channels;

  testWidgets('an IPTV source adds the Channels tab and a group bar that filters the guide', (tester) async {
    final h = await pumpScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      h.provider.dispose();
      h.manager.dispose();
    });

    expect(find.text(t.liveTv.channels), findsWidgets);
    expect(find.byType(LiveTvGroupBar), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('News'), findsOneWidget);
    expect(find.text('Sport'), findsOneWidget);
    expect(guideChannels(tester), hasLength(6));

    await tester.tap(find.text('Sport'));
    await settle(tester, rounds: 3);
    expect(guideChannels(tester).map((c) => c.group).toSet(), {'Sport'});
    expect(guideChannels(tester), hasLength(3));

    await tester.tap(find.text('All'));
    await settle(tester, rounds: 3);
    expect(guideChannels(tester), hasLength(6));
  });

  testWidgets('the Channels tab lists numbers, now and next, and filters by search', (tester) async {
    final h = await pumpScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      h.provider.dispose();
      h.manager.dispose();
    });

    await tester.tap(find.text(t.liveTv.channels).first);
    await settle(tester);
    expect(find.byType(ChannelsTab), findsOneWidget);
    expect(find.text('101'), findsOneWidget);
    expect(find.text('Channel 1 HD'), findsOneWidget);
    expect(find.textContaining('Now: Show 6 on'), findsWidgets);
    expect(find.textContaining('Next: '), findsWidgets);

    await tester.enterText(find.byType(TextField), '102');
    await settle(tester, rounds: 3);
    expect(find.text('Channel 2 HD'), findsOneWidget);
    expect(find.text('Channel 1 HD'), findsNothing);
  });

  testWidgets('the D-pad moves across the group bar and down into the guide', (tester) async {
    final h = await pumpScreen(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      h.provider.dispose();
      h.manager.dispose();
    });

    final bar = tester.state<LiveTvGroupBarState>(find.byType(LiveTvGroupBar));
    bar.focusSelected();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'live_tv_group_0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'live_tv_group_1');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester, rounds: 3);
    expect(guideChannels(tester).map((c) => c.group).toSet(), {'News'});
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester, rounds: 3);
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot(startsWith('live_tv_group_')));
  });
}
