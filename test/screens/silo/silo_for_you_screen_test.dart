import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/silo/silo_for_you_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/focusable_media_card.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection(String serverId, String name, String profile) => SiloConnection(
  id: '$serverId/1/p-$profile',
  baseUrl: 'https://$serverId.example.com',
  serverName: name,
  serverId: serverId,
  userId: '1',
  userName: 'laura',
  accessToken: 'acc-$serverId',
  refreshToken: 'ref-$serverId',
  deviceId: 'dev-1',
  profileId: 'p-$profile',
  profileName: profile,
  createdAt: DateTime(2026),
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _card(String id, String title, {String type = 'movie'}) => {
  'content_id': '$type:$id',
  'type': type,
  'title': title,
};

/// A Silo server answering the For You routes: `/recommendations/discover`
/// and `/catalog?source=favorites|watchlist`.
class _FakeSilo {
  List<Map<String, dynamic>> discoverRows = [
    {
      'type': 'cluster',
      'kind': 'for-you-main',
      'title': 'For You',
      'items': [_card('heat', 'Heat'), _card('ronin', 'Ronin')],
    },
    {
      'type': 'popular',
      'kind': 'popular',
      'title': 'Popular on This Server',
      'items': [_card('alien', 'Alien')],
    },
  ];

  /// The Discover answer's status (500 = a failed read).
  int discoverStatus = 200;
  List<Map<String, dynamic>> favorites = [_card('gattaca', 'Gattaca'), _card('fargo', 'Fargo', type: 'series')];
  List<Map<String, dynamic>> watchlist = [_card('dune', 'Dune')];
  int listStatus = 200;

  final requests = <Uri>[];

  List<Uri> catalogReads(String source) => [
    for (final uri in requests)
      if (uri.path == '/api/v2/catalog' && uri.queryParameters['source'] == source) uri,
  ];

  int get discoverReads => requests.where((u) => u.path == '/api/v2/recommendations/discover').length;

  SiloClient client(String serverId, {String name = 'Home Silo', String profile = 'Laura'}) => SiloClient.forTesting(
    _connection(serverId, name, profile),
    headers: _headers,
    httpClient: MockClient((request) async => _answer(request)),
  );

  http.Response _answer(http.Request request) {
    requests.add(request.url);
    final q = request.url.queryParameters;
    switch (request.url.path) {
      case '/api/v2/recommendations/discover':
        if (discoverStatus != 200) return _json({'type': 'server_error', 'status': discoverStatus}, discoverStatus);
        return _json({'items': discoverRows});
      case '/api/v2/catalog':
        if (listStatus != 200) return _json({'type': 'server_error', 'status': listStatus}, listStatus);
        var rows = q['source'] == 'favorites' ? favorites : watchlist;
        if (q['type'] case final type?) {
          rows = [
            for (final row in rows)
              if (row['type'] == type) row,
          ];
        }
        return _json({
          'items': rows,
          'page': {'has_more': false},
          'total': rows.length,
          'total_exact': true,
        });
      case '/api/v2/capabilities/ratings':
        return _json({'state': 'available', 'sources': <Object>[]});
    }
    return _json({'type': 'not_found'}, 404);
  }
}

Future<SiloForYouScreenState> _pump(WidgetTester tester, List<SiloClient> clients) async {
  final servers = testMultiServer(clients: clients).provider;
  await tester.pumpWidget(
    TranslationProvider(
      child: ChangeNotifierProvider<MultiServerProvider>.value(
        value: servers,
        child: InputModeTracker(
          child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const SiloForYouScreen()),
        ),
      ),
    ),
  );
  await _settle(tester);
  return tester.state<SiloForYouScreenState>(find.byType(SiloForYouScreen));
}

/// Bounded pumps: real HTTP mocks answer on the event loop.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await _settle(tester);
}

String? _focusedLabel() => FocusManager.instance.primaryFocus?.debugLabel;

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  setUp(() async {
    SiloApiCache.initialize(AppDatabase.forTesting(NativeDatabase.memory()));
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  testWidgets('opens on Recommendations with the Discover rows', (tester) async {
    final silo = _FakeSilo();
    final page = await _pump(tester, [silo.client('srv-1')]);
    expect(page.tab, SiloForYouTab.recommendations);
    expect(find.byType(HubSection), findsNWidgets(2));
    expect(find.text('For You'), findsWidgets);
    expect(find.text('Popular on This Server'), findsOneWidget);
    expect(silo.catalogReads('favorites'), isEmpty);
  });

  testWidgets('TV: Left and Right switch tabs from the tab row; Down reaches the content', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
    final silo = _FakeSilo();
    final page = await _pump(tester, [silo.client('srv-1')]);

    // D-pad: focus starts on the first tab.
    expect(_focusedLabel(), 'SiloForYouTab_recommendations');

    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(page.tab, SiloForYouTab.favorites);
    expect(_focusedLabel(), 'SiloForYouTab_favorites');
    expect(silo.catalogReads('favorites'), hasLength(1));
    expect(find.text('Gattaca'), findsOneWidget);
    expect(find.text('2 titles'), findsOneWidget);

    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(page.tab, SiloForYouTab.watchlist);
    expect(find.text('Dune'), findsOneWidget);

    // Right at the last tab stays put.
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(page.tab, SiloForYouTab.watchlist);

    // Down: the media filter, then the first card; Up goes back.
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedLabel(), 'SiloForYouKind_all');
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedLabel(), 'SiloForYouCard_0');
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusedLabel(), 'SiloForYouKind_all');
    await _key(tester, LogicalKeyboardKey.arrowUp);
    expect(_focusedLabel(), 'SiloForYouTab_watchlist');

    await _key(tester, LogicalKeyboardKey.arrowLeft);
    await _key(tester, LogicalKeyboardKey.arrowLeft);
    expect(page.tab, SiloForYouTab.recommendations);
    await _key(tester, LogicalKeyboardKey.arrowDown);
    expect(
      find.ancestor(
        of: find.byWidget(FocusManager.instance.primaryFocus!.context!.widget),
        matching: find.byType(HubSection),
      ),
      findsOneWidget,
      reason: 'Down from the tabs focuses the first recommendation row',
    );
  });

  testWidgets('tapping a tab and a media filter reads the list with type', (tester) async {
    final silo = _FakeSilo();
    final page = await _pump(tester, [silo.client('srv-1')]);
    await tester.tap(find.text(t.siloForYou.favorites));
    await _settle(tester);
    expect(page.tab, SiloForYouTab.favorites);
    expect(find.text('Fargo'), findsOneWidget);

    await tester.tap(find.text(t.siloForYou.movies));
    await _settle(tester);
    expect(silo.catalogReads('favorites').last.queryParameters['type'], 'movie');
    expect(find.text('Fargo'), findsNothing);
    expect(find.text('Gattaca'), findsOneWidget);

    await tester.tap(find.text(t.siloForYou.shows));
    await _settle(tester);
    expect(silo.catalogReads('favorites').last.queryParameters['type'], 'series');
    expect(find.text('Fargo'), findsOneWidget);
    expect(find.byType(FocusableMediaCard), findsOneWidget);
  });

  testWidgets('an empty feed shows the Watchlist with the saved-titles caption', (tester) async {
    final silo = _FakeSilo()..discoverRows = [];
    final page = await _pump(tester, [silo.client('srv-1')]);
    expect(page.tab, SiloForYouTab.watchlist);
    expect(find.text(t.siloForYou.savedFallback), findsOneWidget);
    expect(find.text('Dune'), findsOneWidget);

    // Picking a tab yourself drops the caption.
    await tester.tap(find.text(t.siloForYou.favorites));
    await _settle(tester);
    expect(find.text(t.siloForYou.savedFallback), findsNothing);
  });

  testWidgets('an empty feed and an empty Watchlist fall back to Favorites', (tester) async {
    final silo = _FakeSilo()
      ..discoverRows = []
      ..watchlist = [];
    final page = await _pump(tester, [silo.client('srv-1')]);
    expect(page.tab, SiloForYouTab.favorites);
    expect(find.text(t.siloForYou.savedFallback), findsOneWidget);
  });

  testWidgets('nothing anywhere: Not enough data yet, and Check again reads the feed again', (tester) async {
    final silo = _FakeSilo()
      ..discoverRows = []
      ..watchlist = []
      ..favorites = [];
    final page = await _pump(tester, [silo.client('srv-1')]);
    expect(page.tab, SiloForYouTab.recommendations);
    expect(find.text(t.siloForYou.notEnoughData), findsOneWidget);
    expect(find.text(t.siloForYou.notEnoughDataBody), findsOneWidget);
    final reads = silo.discoverReads;

    silo.discoverRows = [
      {
        'type': 'popular',
        'kind': 'popular',
        'title': 'Popular on This Server',
        'items': [_card('alien', 'Alien')],
      },
    ];
    await tester.tap(find.text(t.siloForYou.checkAgain));
    await _settle(tester);
    expect(silo.discoverReads, reads + 1);
    expect(find.text('Popular on This Server'), findsOneWidget);
    expect(find.text(t.siloForYou.notEnoughData), findsNothing);
  });

  testWidgets('a failed feed shows the error with Retry', (tester) async {
    final silo = _FakeSilo()..discoverStatus = 500;
    await _pump(tester, [silo.client('srv-1')]);
    expect(find.textContaining(t.siloForYou.loadFailed), findsOneWidget);
    expect(find.byType(HubSection), findsNothing);

    silo.discoverStatus = 200;
    await tester.tap(find.text(t.common.retry));
    await _settle(tester);
    expect(find.byType(HubSection), findsNWidgets(2));
  });

  testWidgets('showing the page again re-reads it and keeps the rows when that fails', (tester) async {
    final silo = _FakeSilo();
    final page = await _pump(tester, [silo.client('srv-1')]);
    final reads = silo.discoverReads;

    silo.discoverStatus = 500;
    page.refreshShown();
    await _settle(tester);
    expect(silo.discoverReads, reads + 1);
    expect(find.byType(HubSection), findsNWidgets(2), reason: 'a failed re-read keeps the drawn rows');
    expect(find.textContaining(t.siloForYou.loadFailed), findsNothing);

    // A list re-read that fails keeps its cards too.
    silo.discoverStatus = 200;
    await tester.tap(find.text(t.siloForYou.watchlist));
    await _settle(tester);
    expect(find.text('Dune'), findsOneWidget);
    silo.listStatus = 500;
    page.refreshShown();
    await _settle(tester);
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text(t.siloForYou.listLoadFailed), findsNothing);
  });

  testWidgets('a failed list shows Retry', (tester) async {
    final silo = _FakeSilo()..listStatus = 500;
    await _pump(tester, [silo.client('srv-1')]);
    await tester.tap(find.text(t.siloForYou.favorites));
    await _settle(tester);
    expect(find.text(t.siloForYou.listLoadFailed), findsOneWidget);
    silo.listStatus = 200;
    await tester.tap(find.text(t.common.retry));
    await _settle(tester);
    expect(find.text('Gattaca'), findsOneWidget);
  });

  testWidgets('several Silo servers: chips pick the connection and the pick is remembered', (tester) async {
    final home = _FakeSilo();
    final cabin = _FakeSilo()
      ..discoverRows = [
        {
          'type': 'popular',
          'kind': 'popular',
          'title': 'Cabin Picks',
          'items': [_card('jaws', 'Jaws')],
        },
      ];
    final clients = [home.client('srv-a', name: 'Home'), cabin.client('srv-b', name: 'Cabin', profile: 'Sam')];
    await _pump(tester, clients);
    expect(find.text('Home · Laura'), findsOneWidget);
    expect(find.text('Cabin · Sam'), findsOneWidget);
    expect(find.text('Popular on This Server'), findsOneWidget);
    expect(cabin.discoverReads, 0);

    await tester.tap(find.text('Cabin · Sam'));
    await _settle(tester);
    expect(find.text('Cabin Picks'), findsOneWidget);
    expect(find.text('Popular on This Server'), findsNothing);
    expect(SettingsService.instance.read(SettingsService.siloForYouServerId), 'srv-b');

    // Opened again later: the remembered server comes first.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, clients);
    expect(find.text('Cabin Picks'), findsOneWidget);
  });

  testWidgets('one Silo server: no server chips', (tester) async {
    await _pump(tester, [_FakeSilo().client('srv-1')]);
    expect(find.text('Home Silo · Laura'), findsNothing);
  });
}
