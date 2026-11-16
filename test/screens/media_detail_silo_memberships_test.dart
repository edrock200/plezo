import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/watch_state_store.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:provider/provider.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection() => SiloConnection(
  id: 'srv-1/1/p-owner',
  baseUrl: 'https://silo.example.com',
  serverName: 'Home Silo',
  serverId: 'srv-1',
  userId: '1',
  userName: 'laura',
  accessToken: 'acc-1',
  refreshToken: 'ref-1',
  deviceId: 'dev-1',
  profileId: 'p-owner',
  profileName: 'Laura',
  createdAt: DateTime(2026),
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// Siku's DetailScreen Watchlist and Favorites toggles on a Silo title page:
/// optimistic, rolled back with the server's reason when refused.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late List<String> writes;
  late http.Response Function(http.Request) writeAnswer;

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(false);
    LocaleSettings.setLocaleSync(AppLocale.en);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    JellyfinApiCache.initialize(db);
    SiloApiCache.initialize(db);
    writes = [];
    writeAnswer = (_) => http.Response('', 204);
  });

  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

  SiloClient server() => SiloClient.forTesting(
    _connection(),
    headers: _headers,
    httpClient: MockClient((request) async {
      final path = Uri.decodeComponent(request.url.path);
      if (path.endsWith('/catalog/items/movie:m1') && request.method == 'GET') {
        return _json({
          'content_id': 'movie:m1',
          'type': 'movie',
          'title': 'Heat',
          'overview': 'The full overview.',
          'user_state': {'played': false, 'in_watchlist': false, 'is_favorite': true},
        });
      }
      if (path.startsWith('/api/v2/watchlist/') || path.startsWith('/api/v2/favorites/')) {
        writes.add('${request.method} $path');
        return writeAnswer(request);
      }
      return _json({}, 404);
    }),
  );

  final card = MediaItem.silo(
    id: 'movie:m1',
    kind: MediaKind.movie,
    title: 'Heat',
    serverId: 'srv-1',
    serverName: 'Home Silo',
  );

  Future<void> pumpDetail(WidgetTester tester) async {
    await SettingsService.getInstance();
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final downloadManager = DownloadManagerService(
      database: db,
      storageService: DownloadStorageService.instance,
      clientResolver: (serverId, {clientScopeId}) => null,
    );
    downloadManager.recoveryFuture = Future<void>.value();
    final downloadProvider = DownloadProvider.forTesting(downloadManager: downloadManager, database: db);
    await downloadProvider.ensureInitialized();
    final multi = testMultiServer(clients: [server()]);
    final store = WatchStateStore();
    final offlineWatch = OfflineWatchSyncService(database: db, serverManager: multi.manager);
    addTearDown(() async {
      store.dispose();
      offlineWatch.dispose();
      downloadProvider.dispose();
      downloadManager.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
            ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
            ChangeNotifierProvider<WatchStateStore>.value(value: store),
            ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: withProfileNavigationScope(child: MediaDetailScreen(metadata: card)),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Finder button(String tooltip) => find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip);

  testWidgets('the toggles show the item state and a press writes it at once', (tester) async {
    await tester.runAsync(() async {
      await pumpDetail(tester);

      expect(button(t.explore.addToWatchlist), findsOneWidget);
      expect(button(t.siloMemberships.removeFromFavorites), findsOneWidget, reason: 'is_favorite: true');

      await tester.tap(button(t.explore.addToWatchlist));
      await tester.pump();
      expect(button(t.explore.removeFromWatchlist), findsOneWidget, reason: 'optimistic');
      await settle(tester);

      expect(writes, ['PUT /api/v2/watchlist/movie:m1']);
      expect(find.text(t.explore.addedToWatchlist), findsOneWidget);

      await tester.tap(button(t.siloMemberships.removeFromFavorites));
      await settle(tester);
      expect(writes.last, 'DELETE /api/v2/favorites/movie:m1');
      expect(button(t.siloMemberships.addToFavorites), findsOneWidget);
    });
  });

  testWidgets("a refused write rolls back and shows the server's reason", (tester) async {
    await tester.runAsync(() async {
      await pumpDetail(tester);
      writeAnswer = (_) => http.Response(
        jsonEncode({'type': 'https://siloserver.org/problems/conflict', 'detail': 'Watchlist is full'}),
        409,
        headers: {'content-type': 'application/problem+json'},
      );

      await tester.tap(button(t.explore.addToWatchlist));
      await settle(tester);

      expect(button(t.explore.addToWatchlist), findsOneWidget, reason: 'back to the confirmed state');
      expect(find.text("Couldn't add to Watchlist. Watchlist is full"), findsOneWidget);
    });
  });

  testWidgets('each toggle has its own focus node for the D-pad', (tester) async {
    await tester.runAsync(() async {
      await pumpDetail(tester);
      final labels = [
        for (final node in FocusManager.instance.rootScope.descendants)
          if (node.debugLabel != null) node.debugLabel!,
      ];
      expect(labels, containsAll(['detail_silo_watchlist', 'detail_silo_favorite']));
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
