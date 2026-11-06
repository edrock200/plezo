import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/silo/silo_calendar_screen.dart';
import 'package:plezy/screens/silo/silo_feature_entries.dart';
import 'package:plezy/screens/silo/silo_request_detail_screen.dart';
import 'package:plezy/screens/silo/silo_request_search_section.dart';
import 'package:plezy/screens/silo/silo_requests_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/app_menu.dart';
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

SiloConnection _connection(String serverId, String name) => SiloConnection(
  id: '$serverId/1/p-owner',
  baseUrl: 'https://$serverId.example.com',
  serverName: name,
  serverId: serverId,
  userId: '1',
  userName: 'laura',
  accessToken: 'acc-$serverId',
  refreshToken: 'ref-$serverId',
  deviceId: 'dev-1',
  profileId: 'p-owner',
  profileName: 'Laura',
  createdAt: DateTime(2026),
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// A Silo server answering the request and calendar routes.
class _FakeSilo {
  _FakeSilo({this.requestsEnabled = true, this.removeSupported = false, this.withFailed = false});

  bool requestsEnabled;

  /// `remove_failed_supported` on the status (Silo Android #792).
  bool removeSupported;

  /// My requests also lists two failed requests: "Gattaca" delivered
  /// nothing, "Alien" delivered 1080p before its 4K copy failed.
  bool withFailed;

  /// The answer to `DELETE /requests/{id}`: 204, or a problem's status.
  int deleteStatus = 204;
  final paths = <String>[];
  final posts = <String>[];
  final deletes = <String>[];
  final _removed = <String>{};

  int get mineReads => paths.where((p) => p == 'GET /api/v2/requests/mine').length;

  static Map<String, dynamic> _failedRecord(String id, int tmdbId, String title, {bool delivered = false}) => {
    'id': id,
    'media_type': 'movie',
    'tmdb_id': tmdbId,
    'title': title,
    'status': 'failed',
    'outcome': 'failed',
    'state': 'failed',
    'targets': [
      if (delivered) {'quality': '1080p', 'status': 'completed'},
      {'quality': '4k', 'status': 'failed'},
    ],
    'created_at': '2026-10-0${id.length}T00:00:00Z',
    'updated_at': '2026-10-01T00:00:00Z',
  };

  SiloClient client(String serverId, {String name = 'Home Silo'}) => SiloClient.forTesting(
    _connection(serverId, name),
    headers: _headers,
    httpClient: MockClient((request) async => _answer(request)),
  );

  http.Response _answer(http.Request request) {
    final path = Uri.decodeComponent(request.url.path);
    paths.add('${request.method} $path');
    if (request.method == 'POST') posts.add(path);
    if (request.method == 'DELETE') {
      deletes.add(path);
      if (deleteStatus != 204) {
        return _json({'type': 'conflict', 'title': 'conflict', 'status': deleteStatus}, deleteStatus);
      }
      _removed.add(path.split('/').last);
      return http.Response('', 204);
    }
    switch (path) {
      case '/api/v2/requests/status':
        return _json({
          'requests_enabled': requestsEnabled,
          'allowed': requestsEnabled,
          'state': requestsEnabled ? 'available' : 'disabled',
          if (removeSupported) 'remove_failed_supported': true,
        });
      case '/api/v2/requests/search':
        return _json({
          'page': 1,
          'total_pages': 1,
          'total_results': 2,
          'results': [
            {
              'media_type': 'movie',
              'tmdb_id': 1,
              'title': 'Starfall',
              'year': 2026,
              'availability': 'missing',
              'request': {'requestable': true},
            },
            {
              'media_type': 'series',
              'tmdb_id': 2,
              'title': 'Northern Lights',
              'availability': 'available',
              'library_content_id': 'series:northern',
              'request': {'requestable': false, 'reason': 'already_available'},
            },
            if (withFailed)
              {
                'media_type': 'movie',
                'tmdb_id': 21,
                'title': 'Gattaca',
                'availability': 'missing',
                'request': _removed.contains('21')
                    ? {'requestable': true}
                    : {'requestable': false, 'status': 'failed', 'state': 'failed', 'request_id': '21'},
              },
          ],
        });
      case '/api/v2/requests/mine':
        return _json({
          'items': [
            {
              'id': '7',
              'media_type': 'movie',
              'tmdb_id': 9,
              'title': 'Heat',
              'status': 'pending',
              'outcome': 'active',
              'state': 'pending',
              'created_at': '2026-11-01T00:00:00Z',
              'updated_at': '2026-11-01T00:00:00Z',
            },
            if (withFailed) ...[
              if (!_removed.contains('21')) _failedRecord('21', 21, 'Gattaca'),
              _failedRecord('22', 22, 'Alien', delivered: true),
            ],
          ],
          'page': {'has_more': false},
        });
      case '/api/v2/requests/detail/movie/21':
        return _json({
          'media_type': 'movie',
          'tmdb_id': 21,
          'title': 'Gattaca',
          'genres': [],
          'cast': [],
          'availability': 'missing',
          'request': _removed.contains('21')
              ? {'requestable': true}
              : {'requestable': false, 'status': 'failed', 'state': 'failed', 'request_id': '21'},
        });
      case '/api/v2/requests/detail/movie/1':
        return _json({
          'media_type': 'movie',
          'tmdb_id': 1,
          'title': 'Starfall',
          'year': 2026,
          'genres': [],
          'cast': [],
          'availability': 'missing',
          'request': {'requestable': true},
        });
      case '/api/v2/requests':
        return _json({
          'id': '8',
          'media_type': 'movie',
          'tmdb_id': 1,
          'title': 'Starfall',
          'status': 'pending',
          'outcome': 'active',
          'state': 'pending',
          'created_at': '2026-11-06T00:00:00Z',
          'updated_at': '2026-11-06T00:00:00Z',
        }, 201);
      case '/api/v2/calendar':
        return _json({
          'events': [
            {
              'date': '2026-11-04',
              'items': [
                {
                  'content_id': 'episode:severance-s02e01',
                  'type': 'episode',
                  'title': 'Severance',
                  'episode_title': 'Hello, Ms. Cobel',
                  'series_id': 'series:severance',
                  'season_number': 2,
                  'episode_number': 1,
                  'air_date': '2026-11-04',
                  'air_time': '21:00',
                  'local_air_date': '2026-11-04',
                  'watched': false,
                  'badges': ['season_premiere'],
                },
                {
                  'content_id': 'movie:heat',
                  'type': 'movie',
                  'title': 'Heat',
                  'air_date': '2026-11-04',
                  'local_air_date': '2026-11-04',
                  'watched': false,
                  'badges': ['digital'],
                },
              ],
            },
          ],
        });
    }
    return _json({'type': 'not_found'}, 404);
  }
}

Widget _app(MultiServerProvider servers, Widget home) => TranslationProvider(
  child: ChangeNotifierProvider<MultiServerProvider>.value(
    value: servers,
    child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: home),
  ),
);

/// The profile menu as the Discover screen builds it: Silo rows ahead of
/// the app's own.
class _Menu extends StatelessWidget {
  const _Menu();

  @override
  Widget build(BuildContext context) {
    final servers = Provider.of<MultiServerProvider>(context, listen: false);
    return Scaffold(
      body: Center(
        child: AppMenuButton<String>(
          icon: const Icon(Icons.person),
          entriesBuilder: (_) => [
            ...siloFeatureMenuEntries(servers),
            AppMenuItem<String>(value: 'settings', label: t.common.settings),
          ],
          onSelected: (value) => handleSiloFeatureMenuValue(context, servers, value),
        ),
      ),
    );
  }
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

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  group('profile menu rows', () {
    test('no Silo server: no rows', () {
      final servers = testMultiServer().provider;
      expect(siloFeatureMenuEntries(servers), isEmpty);
    });

    test('Calendar for an online Silo server; Requests only once its status enables them', () async {
      final silo = _FakeSilo(requestsEnabled: false);
      final client = silo.client('srv-1');
      final servers = testMultiServer(clients: [client]).provider;
      expect(_labels(siloFeatureMenuEntries(servers)), [t.siloCalendar.menuEntry]);

      warmSiloFeatureEntries(servers);
      await client.requests.refreshStatus();
      expect(_labels(siloFeatureMenuEntries(servers)), [t.siloCalendar.menuEntry]);

      silo.requestsEnabled = true;
      await client.requests.refreshStatus(force: true);
      expect(_labels(siloFeatureMenuEntries(servers)), [t.siloCalendar.menuEntry, t.siloRequests.menuEntry]);
    });

    test('an offline Silo server has no rows', () async {
      final client = _FakeSilo().client('srv-1');
      await client.requests.refreshStatus();
      final servers = testMultiServer(clients: [client], offline: [client]).provider;
      expect(siloFeatureMenuEntries(servers), isEmpty);
    });

    test('several Silo servers: each row names its server', () async {
      final a = _FakeSilo().client('srv-a', name: 'Home');
      final b = _FakeSilo(requestsEnabled: false).client('srv-b', name: 'Cabin');
      await a.requests.refreshStatus();
      await b.requests.refreshStatus();
      final servers = testMultiServer(clients: [a, b]).provider;
      expect(_labels(siloFeatureMenuEntries(servers)), [
        t.siloCalendar.menuEntryOnServer(server: 'Home'),
        t.siloCalendar.menuEntryOnServer(server: 'Cabin'),
        t.siloRequests.menuEntryOnServer(server: 'Home'),
      ]);
    });
  });

  testWidgets('the menu shows Requests only while enabled and opens the pages', (tester) async {
    final silo = _FakeSilo(requestsEnabled: false);
    final client = silo.client('srv-1');
    final servers = testMultiServer(clients: [client]).provider;
    await tester.runAsync(() => client.requests.refreshStatus());
    await tester.pumpWidget(_app(servers, const _Menu()));

    await tester.tap(find.byIcon(Icons.person));
    await tester.pumpAndSettle();
    expect(find.text(t.siloCalendar.menuEntry), findsOneWidget);
    expect(find.text(t.siloRequests.menuEntry), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    silo.requestsEnabled = true;
    await tester.runAsync(() => client.requests.refreshStatus(force: true));
    await tester.tap(find.byIcon(Icons.person));
    await tester.pumpAndSettle();
    expect(find.text(t.siloRequests.menuEntry), findsOneWidget);

    await tester.tap(find.text(t.siloRequests.menuEntry));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byType(SiloRequestsScreen), findsOneWidget);
    expect(find.text('Heat'), findsOneWidget, reason: 'My requests');
    expect(find.text(t.siloRequests.myRequests), findsOneWidget);
  });

  testWidgets('Calendar lists the week with badges, captions and air times', (tester) async {
    final silo = _FakeSilo();
    final client = silo.client('srv-1');
    final servers = testMultiServer(clients: [client]).provider;
    await tester.pumpWidget(_app(servers, SiloCalendarScreen(client: client, now: DateTime(2026, 11, 4, 10))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(silo.paths.where((p) => p.contains('/calendar')), hasLength(1));
    expect(find.text(t.siloCalendar.today), findsOneWidget);
    expect(find.text('Severance'), findsOneWidget);
    expect(find.text('S2 · E1 · Hello, Ms. Cobel'), findsOneWidget);
    expect(find.text(t.siloCalendar.badgeNewSeason), findsOneWidget);
    expect(find.text(t.siloCalendar.badgeDigital), findsOneWidget);
    expect(find.text(t.siloCalendar.movie), findsOneWidget);
    expect(find.textContaining('9:00'), findsOneWidget);
    expect(find.text(t.siloCalendar.nothingScheduled), findsWidgets);

    // Another view asks again.
    await tester.tap(find.text(t.siloCalendar.all));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(silo.paths.where((p) => p.contains('/calendar')), hasLength(2));
  });

  testWidgets('Calendar works with the D-pad: filters, week arrows, then the events', (tester) async {
    final client = _FakeSilo().client('srv-1');
    final servers = testMultiServer(clients: [client]).provider;
    await tester.pumpWidget(_app(servers, SiloCalendarScreen(client: client, now: DateTime(2026, 11, 4, 10))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    String? focused() => FocusManager.instance.primaryFocus?.debugLabel;
    // A key press switches to keyboard mode; then start on the first filter.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    tester
        .widget<Focus>(
          find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'SiloCalendarFilter_following'),
        )
        .focusNode!
        .requestFocus();
    await tester.pumpAndSettle();
    expect(focused(), 'SiloCalendarFilter_following');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused(), 'SiloCalendarPrevWeek');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused(), 'SiloCalendarFirstEvent');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focused(), 'SiloCalendarPrevWeek');
  });

  testWidgets('Calendar hides an unwatched episode title while Hide spoilers is on', (tester) async {
    await SettingsService.instance.write(SettingsService.hideSpoilers, true);
    final client = _FakeSilo().client('srv-1');
    final servers = testMultiServer(clients: [client]).provider;
    await tester.pumpWidget(_app(servers, SiloCalendarScreen(client: client, now: DateTime(2026, 11, 4, 10))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('S2 · E1'), findsOneWidget);
    expect(find.textContaining('Hello, Ms. Cobel'), findsNothing);
  });

  group('search "Available to request"', () {
    Future<void> pumpSection(WidgetTester tester, MultiServerProvider servers, String query) async {
      await tester.pumpWidget(
        _app(
          servers,
          Scaffold(
            body: CustomScrollView(slivers: [SiloRequestSearchSection(query: query)]),
          ),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    testWidgets('lists only titles the library does not have (#773)', (tester) async {
      final silo = _FakeSilo();
      final client = silo.client('srv-1');
      await tester.runAsync(() => client.requests.refreshStatus());
      await pumpSection(tester, testMultiServer(clients: [client]).provider, 'star');
      expect(find.text(t.siloRequests.availableToRequest), findsOneWidget);
      expect(find.text('Starfall'), findsOneWidget);
      expect(find.text('Northern Lights'), findsNothing);
    });

    testWidgets('absent while requests are off, and for one-letter queries', (tester) async {
      final silo = _FakeSilo(requestsEnabled: false);
      final client = silo.client('srv-1');
      await tester.runAsync(() => client.requests.refreshStatus());
      await pumpSection(tester, testMultiServer(clients: [client]).provider, 'star');
      expect(find.text(t.siloRequests.availableToRequest), findsNothing);
      expect(silo.paths.where((p) => p.contains('/requests/search')), isEmpty);

      final on = _FakeSilo();
      final onClient = on.client('srv-2');
      await tester.runAsync(() => onClient.requests.refreshStatus());
      await pumpSection(tester, testMultiServer(clients: [onClient]).provider, 's');
      expect(find.text(t.siloRequests.availableToRequest), findsNothing);
      expect(on.paths.where((p) => p.contains('/requests/search')), isEmpty);
    });
  });

  group('removing a failed request (#792)', () {
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
    }

    Future<SiloClient> pumpRequests(WidgetTester tester, _FakeSilo silo) async {
      final client = silo.client('srv-1');
      final servers = testMultiServer(clients: [client]).provider;
      await tester.pumpWidget(_app(servers, SiloRequestsScreen(key: UniqueKey(), client: client)));
      await settle(tester);
      return client;
    }

    Finder removeOf(String id) => find.byKey(ValueKey('silo-request-remove-$id'));

    testWidgets('Remove only on a failed request that delivered nothing, and only when supported', (tester) async {
      await pumpRequests(tester, _FakeSilo(withFailed: true));
      expect(find.text('Gattaca'), findsOneWidget);
      expect(find.text(t.siloRequests.removeRequest), findsNothing, reason: 'older server: no remove_failed_supported');

      await pumpRequests(tester, _FakeSilo(withFailed: true, removeSupported: true));
      expect(removeOf('21'), findsOneWidget);
      expect(removeOf('22'), findsNothing, reason: 'Alien delivered 1080p before failing');
      expect(removeOf('7'), findsNothing, reason: 'pending');
    });

    testWidgets('confirms naming the title, sends one DELETE and drops the row', (tester) async {
      final silo = _FakeSilo(withFailed: true, removeSupported: true);
      await pumpRequests(tester, silo);

      await tester.tap(removeOf('21'));
      await tester.pumpAndSettle();
      expect(find.text(t.siloRequests.removeConfirmTitle), findsOneWidget);
      expect(find.text(t.siloRequests.removeConfirmMessage(title: 'Gattaca')), findsOneWidget);
      await tester.tap(find.text(t.siloRequests.keepRequest));
      await tester.pumpAndSettle();
      expect(silo.deletes, isEmpty);
      expect(find.text('Gattaca'), findsOneWidget);

      await tester.tap(removeOf('21'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, t.siloRequests.removeRequest).last);
      await settle(tester);
      expect(silo.deletes, ['/api/v2/requests/21']);
      expect(find.text('Gattaca'), findsNothing);
      expect(find.text(t.siloRequests.requestRemoved), findsOneWidget);
      expect(find.text('Alien'), findsOneWidget);
    });

    testWidgets('a 409 re-reads the list and says why nothing was removed', (tester) async {
      final silo = _FakeSilo(withFailed: true, removeSupported: true)..deleteStatus = 409;
      await pumpRequests(tester, silo);
      final reads = silo.mineReads;

      await tester.tap(removeOf('21'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, t.siloRequests.removeRequest).last);
      await settle(tester);
      expect(silo.deletes, ['/api/v2/requests/21'], reason: 'sent once, never retried');
      expect(silo.mineReads, reads + 1);
      expect(find.text(t.siloRequests.removeConflict), findsOneWidget);
      expect(find.text('Gattaca'), findsOneWidget);
    });

    testWidgets('D-pad: RIGHT from the row reaches Remove, Keep has focus, focus moves on after', (tester) async {
      final silo = _FakeSilo(withFailed: true, removeSupported: true);
      await pumpRequests(tester, silo);
      String? focused() => FocusManager.instance.primaryFocus?.debugLabel;

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      tester
          .widget<Focus>(find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'SiloMyRequest.21'))
          .focusNode!
          .requestFocus();
      await tester.pumpAndSettle();
      expect(focused(), 'SiloMyRequest.21');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(focused(), 'SiloMyRequest.21.remove');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(focused(), 'SiloMyRequest.21');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text(t.siloRequests.removeConfirmTitle), findsOneWidget);
      // Keep request has focus: a stray Select deletes nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(silo.deletes, isEmpty);
      expect(focused(), 'SiloMyRequest.21.remove');

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settle(tester);
      expect(silo.deletes, ['/api/v2/requests/21']);
      expect(find.text('Gattaca'), findsNothing);
      expect(focused(), 'SiloMyRequest.22', reason: 'the row that took its place');
    });

    testWidgets('search: the removed title is requestable again', (tester) async {
      final silo = _FakeSilo(withFailed: true, removeSupported: true);
      final client = silo.client('srv-1');
      await tester.runAsync(() => client.requests.refreshStatus());
      await tester.pumpWidget(
        _app(
          testMultiServer(clients: [client]).provider,
          const Scaffold(
            body: CustomScrollView(slivers: [SiloRequestSearchSection(query: 'gat')]),
          ),
        ),
      );
      await settle(tester);
      expect(find.text('Gattaca'), findsOneWidget);
      expect(find.text(t.siloRequests.failed), findsOneWidget);
      final searches = silo.paths.where((p) => p.contains('/requests/search')).length;

      final record = (await tester.runAsync(client.requests.mine))!.firstWhere((r) => r.id == '21');
      await tester.runAsync(() => client.requests.removeFailed(record));
      await settle(tester);
      expect(find.text('Gattaca'), findsOneWidget);
      expect(find.text(t.siloRequests.failed), findsNothing);
      expect(silo.paths.where((p) => p.contains('/requests/search')), hasLength(searches), reason: 'patched in place');
    });

    testWidgets('detail: Remove request, then Request is offered again', (tester) async {
      final silo = _FakeSilo(withFailed: true, removeSupported: true);
      final client = silo.client('srv-1');
      final servers = testMultiServer(clients: [client]).provider;
      await tester.pumpWidget(
        _app(servers, SiloRequestDetailScreen(client: client, mediaType: 'movie', tmdbId: 21, initialTitle: 'Gattaca')),
      );
      await settle(tester);
      expect(find.text(t.siloRequests.removeRequest), findsOneWidget);
      expect(find.text(t.siloRequests.request), findsNothing);

      await tester.tap(find.text(t.siloRequests.removeRequest));
      await tester.pumpAndSettle();
      expect(find.text(t.siloRequests.removeConfirmMessage(title: 'Gattaca')), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, t.siloRequests.removeRequest).last);
      await settle(tester);
      expect(silo.deletes, ['/api/v2/requests/21']);
      expect(find.text(t.siloRequests.requestRemoved), findsOneWidget);
      expect(find.text(t.siloRequests.removeRequest), findsNothing);
      expect(find.text(t.siloRequests.request), findsOneWidget);
    });
  });

  testWidgets('request detail submits once and shows the pending state', (tester) async {
    final silo = _FakeSilo();
    final client = silo.client('srv-1');
    final servers = testMultiServer(clients: [client]).provider;
    await tester.pumpWidget(
      _app(servers, SiloRequestDetailScreen(client: client, mediaType: 'movie', tmdbId: 1, initialTitle: 'Starfall')),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text(t.siloRequests.request), findsOneWidget);

    await tester.tap(find.text(t.siloRequests.request));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(silo.posts, ['/api/v2/requests']);
    expect(find.text(t.siloRequests.detailPending), findsOneWidget);
    expect(find.text(t.siloRequests.request), findsNothing);
    expect(find.text(t.siloRequests.cancelRequest), findsOneWidget);
  });
}
