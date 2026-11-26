import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/tofa/tofa_feature_entries.dart';
import 'package:plezy/screens/tofa/tofa_history_screen.dart';
import 'package:plezy/screens/tofa/tofa_title_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/tofa/tofa_api.dart';
import 'package:plezy/services/tofa/tofa_client.dart';
import 'package:plezy/services/tofa/tofa_extras.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/app_menu.dart';
import 'package:provider/provider.dart';

import '../../services/tofa/tofa_fixtures.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

Widget _app(MultiServerProvider servers, Widget home) => TranslationProvider(
  child: ChangeNotifierProvider<MultiServerProvider>.value(
    value: servers,
    child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: home),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pumpAndSettle();
}

List<String> _labels(List<AppMenuEntry<String>> entries) => [
  for (final entry in entries)
    if (entry is AppMenuItem<String>) entry.label!,
];

void main() {
  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  late FakeTofa fake;
  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    fake = FakeTofa();
  });

  TofaClient client() => TofaClient.forTesting(
    tofaConnection(),
    headers: const TofaClientHeaders(clientVersion: '1.0', platform: 'android', deviceName: 'Test device'),
    httpClient: fake.client,
  )..raceWait = (_) async {};

  test('the profile menu lists Discover, Requests (when on), History and Switch profile', () async {
    fake.on(
      'GET',
      '/api/v1/system/info',
      (_) => jsonResponse({'version': '0.14', 'requests_available': true, 'discover_enabled': true}),
    );
    final c = client();
    final servers = testMultiServer(clients: [c]).provider;
    expect(_labels(tofaFeatureMenuEntries(servers)), [
      t.tofaExtras.discover,
      t.tofaExtras.history,
      t.tofaExtras.switchProfile,
    ], reason: 'Requests waits for the server to say it is on');
    warmTofaFeatureEntries(servers);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(_labels(tofaFeatureMenuEntries(servers)), [
      t.tofaExtras.discover,
      t.tofaExtras.requests,
      t.tofaExtras.history,
      t.tofaExtras.switchProfile,
    ]);
  });

  testWidgets('a Discover title offers Request where the rights allow, then shows it requested', (tester) async {
    fake.on(
      'GET',
      '/api/v1/discovery/detail/movie/12',
      (_) => jsonResponse({
        'in_library': false,
        'requests_available': true,
        'request_blocked': false,
        'request_status': null,
        'is4k_capable': false,
        'seen': false,
        'not_interested': false,
        'overview': 'A film',
      }),
    );
    fake.on(
      'GET',
      '/api/v1/requests/rights',
      (_) => jsonResponse({
        'requests_available': true,
        'rights': {'movie': 'ask', 'tv': 'off', 'movie_4k': 'off', 'tv_4k': 'off'},
        'quota': {'movie': null, 'tv': null},
      }),
    );
    fake.on(
      'POST',
      '/api/v1/requests',
      (_) => jsonResponse({
        'request': {'id': 'r-1', 'title': 'Found', 'tmdb_id': 12, 'media_type': 'movie', 'status': 'pending_approval'},
      }, 201),
    );
    fake.on('PUT', '/api/v1/users/me/seen/movie/12', (_) => http.Response('', 204));
    final c = client();
    final servers = testMultiServer(clients: [c]).provider;
    await tester.pumpWidget(
      _app(
        servers,
        TofaTitleScreen(
          client: c,
          item: const TofaDiscoverItem(tmdbId: 12, type: 'movie', title: 'Found'),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('A film'), findsOneWidget);
    expect(find.text(t.tofaExtras.request4k), findsNothing);
    await tester.tap(find.text(t.tofaExtras.request));
    await _settle(tester);
    expect(fake.to('POST', '/api/v1/requests'), hasLength(1));
    expect(find.text(t.tofaExtras.request), findsNothing, reason: 'requested: no second request');
    await tester.tap(find.text(t.tofaExtras.markSeen));
    await _settle(tester);
    expect(find.text(t.tofaExtras.unmarkSeen), findsOneWidget);
  });

  testWidgets('History removes an entry and clears all after confirming', (tester) async {
    fake.on(
      'GET',
      '/api/v1/watch/history',
      (_) => jsonResponse({
        'has_more': false,
        'items': [
          for (final id in ['h-1', 'h-2'])
            {
              'id': id,
              'title': 'Title $id',
              'started_at': '2026-11-25T10:00:00Z',
              'play_method': 'DirectPlay',
              'position_ms': 0,
              'progress_percent': 10,
              'seconds_watched': 1,
            },
        ],
      }),
    );
    fake.on('DELETE', '/api/v1/watch/history/h-1', (_) => http.Response('', 204));
    fake.on('DELETE', '/api/v1/watch/history', (_) => http.Response('', 204));
    final c = client();
    final servers = testMultiServer(clients: [c]).provider;
    await tester.pumpWidget(_app(servers, TofaHistoryScreen(client: c)));
    await _settle(tester);
    expect(find.text('Title h-1'), findsOneWidget);
    await tester.tap(find.byTooltip(t.tofaExtras.removeFromHistory).first);
    await _settle(tester);
    expect(find.text('Title h-1'), findsNothing);
    expect(find.text('Title h-2'), findsOneWidget);
    await tester.tap(find.text(t.tofaExtras.clearHistory));
    await _settle(tester);
    expect(find.text(t.tofaExtras.clearHistoryTitle), findsOneWidget);
    await tester.tap(find.text(t.tofaExtras.clearHistory).last);
    await _settle(tester);
    expect(fake.to('DELETE', '/api/v1/watch/history'), hasLength(1));
    expect(find.text(t.tofaExtras.historyEmpty), findsOneWidget);
  });
}
