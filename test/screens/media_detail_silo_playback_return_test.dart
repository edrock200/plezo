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
import 'package:plezy/utils/watch_state_notifier.dart';
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

/// Silo Android #955: back from the player, the detail page shows the
/// server's resume point once the stop has landed, not the player's exit
/// position (Silo ignores a stop under its minimum resume share).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late int detailReads;
  late double serverPosition;

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(false);
    LocaleSettings.setLocaleSync(AppLocale.en);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    JellyfinApiCache.initialize(db);
    SiloApiCache.initialize(db);
    detailReads = 0;
    serverPosition = 2617;
  });

  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

  SiloClient server() => SiloClient.forTesting(
    _connection(),
    headers: _headers,
    httpClient: MockClient((request) async {
      final path = Uri.decodeComponent(request.url.path);
      if (path.endsWith('/catalog/items/movie:m1')) {
        detailReads++;
        return _json({
          'content_id': 'movie:m1',
          'type': 'movie',
          'title': 'Heat',
          'runtime': 170,
          'user_data': {'played': false, 'position_seconds': serverPosition, 'duration_seconds': 10200},
        });
      }
      return _json({}, 404);
    }),
  );

  Future<({WatchStateStore store, MediaItem movie})> pumpDetail(WidgetTester tester, SiloClient client) async {
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
    final multi = testMultiServer(clients: [client]);
    final store = WatchStateStore();
    final offlineWatch = OfflineWatchSyncService(database: db, serverManager: multi.manager);
    addTearDown(() async {
      store.dispose();
      offlineWatch.dispose();
      downloadProvider.dispose();
      downloadManager.dispose();
      await db.close();
    });

    final movie = MediaItem.silo(
      id: 'movie:m1',
      kind: MediaKind.movie,
      title: 'Heat',
      serverId: 'srv-1',
      serverName: 'Home Silo',
      durationMs: 10200000,
    );
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
            home: withProfileNavigationScope(child: MediaDetailScreen(metadata: movie)),
          ),
        ),
      ),
    );
    await settle(tester);
    return (store: store, movie: movie);
  }

  int? patchedOffset(WatchStateStore store) => store.patchForGlobalKey('srv-1:movie:m1')?.viewOffsetMs;

  testWidgets('an accepted stop is replaced by the resume point the server kept', (tester) async {
    await tester.runAsync(() async {
      final (:store, :movie) = await pumpDetail(tester, server());
      final readsBefore = detailReads;

      // The player stopped at 0:57; Silo kept its earlier 43:37.
      WatchStateNotifier().notifyProgress(
        item: movie,
        viewOffset: 57000,
        duration: 10200000,
        cacheServerId: 'srv-1',
        serverAcknowledged: true,
      );
      await settle(tester);

      expect(detailReads, greaterThan(readsBefore), reason: 'the page reads the item again after the stop');
      expect(patchedOffset(store), 2617000);
    });
  });

  testWidgets('a stop under the minimum share with no earlier resume point leaves none', (tester) async {
    await tester.runAsync(() async {
      serverPosition = 0;
      final (:store, :movie) = await pumpDetail(tester, server());

      WatchStateNotifier().notifyProgress(
        item: movie,
        viewOffset: 40000,
        duration: 10200000,
        cacheServerId: 'srv-1',
        serverAcknowledged: true,
      );
      await settle(tester);

      expect(patchedOffset(store), 0);
    });
  });

  testWidgets('a stop the server has not accepted keeps the exit position', (tester) async {
    await tester.runAsync(() async {
      final (:store, :movie) = await pumpDetail(tester, server());
      final readsBefore = detailReads;

      WatchStateNotifier().notifyProgress(item: movie, viewOffset: 57000, duration: 10200000, cacheServerId: 'srv-1');
      await settle(tester);

      expect(detailReads, readsBefore);
      expect(patchedOffset(store), 57000);
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
