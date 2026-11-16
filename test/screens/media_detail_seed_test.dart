import 'dart:async';
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
import 'package:plezy/utils/media_navigation_helper.dart';
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

/// Silo Android #971 / Siku's `Nav_detailSeed`: a detail page opened from a
/// card draws the card at once and waits for the full item without a
/// loading screen; Play reads "Loading..." until the item arrives.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Completer<http.Response> detailAnswer;

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(false);
    LocaleSettings.setLocaleSync(AppLocale.en);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    JellyfinApiCache.initialize(db);
    SiloApiCache.initialize(db);
    detailAnswer = Completer<http.Response>();
  });

  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

  SiloClient server() => SiloClient.forTesting(
    _connection(),
    headers: _headers,
    httpClient: MockClient((request) async {
      final path = Uri.decodeComponent(request.url.path);
      if (path.endsWith('/catalog/items/movie:m1')) return detailAnswer.future;
      return _json({}, 404);
    }),
  );

  final card = MediaItem.silo(
    id: 'movie:m1',
    kind: MediaKind.movie,
    title: 'Heat',
    year: 1995,
    summary: 'The card overview.',
    serverId: 'srv-1',
    serverName: 'Home Silo',
  );

  Future<void> pumpDetail(WidgetTester tester, {required bool seeded, bool tv = false}) async {
    await SettingsService.getInstance();
    tester.view.physicalSize = tv ? const Size(1920, 1080) : const Size(1100, 2400);
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
      if (!detailAnswer.isCompleted) detailAnswer.complete(_json({}, 404));
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
            home: withProfileNavigationScope(
              child: MediaDetailScreen(metadata: card, seededFromCard: seeded),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Finder watchedButton() => find.byWidgetPredicate(
    (w) => w is IconButton && (w.tooltip == t.tooltips.markAsWatched || w.tooltip == t.tooltips.markAsUnwatched),
  );

  testWidgets('a seeded page draws the card at once and waits for the item with a loading Play', (tester) async {
    await tester.runAsync(() async {
      await pumpDetail(tester, seeded: true);

      expect(find.text('Heat'), findsWidgets);
      expect(find.text('The card overview.'), findsOneWidget);
      expect(find.byKey(mediaDetailSeedPlayKey), findsOneWidget);
      expect(watchedButton(), findsNothing, reason: 'actions that need the full item wait for it');

      detailAnswer.complete(
        _json({
          'content_id': 'movie:m1',
          'type': 'movie',
          'title': 'Heat',
          'year': 1995,
          'overview': 'The full overview.',
          'runtime': 170,
        }),
      );
      await settle(tester);

      expect(find.byKey(mediaDetailSeedPlayKey), findsNothing);
      expect(find.text('The full overview.'), findsOneWidget);
      expect(find.text('The card overview.'), findsNothing);
      expect(watchedButton(), findsOneWidget);
    });
  });

  testWidgets('without a seed the page keeps its loading screen until the item arrives', (tester) async {
    await tester.runAsync(() async {
      await pumpDetail(tester, seeded: false);

      expect(find.text('The card overview.'), findsNothing);
      expect(find.byKey(mediaDetailSeedPlayKey), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      detailAnswer.complete(
        _json({'content_id': 'movie:m1', 'type': 'movie', 'title': 'Heat', 'overview': 'The full overview.'}),
      );
      await settle(tester);

      expect(find.text('The full overview.'), findsOneWidget);
    });
  });

  Finder retryButton() => find.descendant(of: find.byKey(mediaDetailSeedErrorKey), matching: find.text(t.common.retry));

  bool retryHasFocus() => FocusManager.instance.primaryFocus?.debugLabel == 'media_detail_seed_retry';

  testWidgets('a failed read clears the card and shows an error with Retry', (tester) async {
    await tester.runAsync(() async {
      await pumpDetail(tester, seeded: true);
      expect(find.byKey(mediaDetailSeedPlayKey), findsOneWidget);

      detailAnswer.complete(_json({'title': 'Server error'}, 500));
      await settle(tester);

      expect(find.byKey(mediaDetailSeedErrorKey), findsOneWidget);
      expect(find.text(t.messages.detailLoadFailed), findsOneWidget);
      expect(retryButton(), findsOneWidget);
      expect(find.text('The card overview.'), findsNothing, reason: "the card's copy is cleared");
      expect(find.byKey(mediaDetailSeedPlayKey), findsNothing);
      expect(watchedButton(), findsNothing);
    });
  });

  testWidgets('Retry shows the loading look again and hands over to the full item', (tester) async {
    await tester.runAsync(() async {
      await pumpDetail(tester, seeded: true);
      detailAnswer.complete(_json({'title': 'Server error'}, 500));
      await settle(tester);
      expect(find.byKey(mediaDetailSeedErrorKey), findsOneWidget);

      detailAnswer = Completer<http.Response>();
      await tester.tap(retryButton());
      await settle(tester);

      expect(find.byKey(mediaDetailSeedErrorKey), findsNothing);
      expect(find.byKey(mediaDetailSeedPlayKey), findsOneWidget);
      expect(find.text('The card overview.'), findsOneWidget);

      detailAnswer.complete(
        _json({'content_id': 'movie:m1', 'type': 'movie', 'title': 'Heat', 'overview': 'The full overview.'}),
      );
      await settle(tester);

      expect(find.byKey(mediaDetailSeedPlayKey), findsNothing);
      expect(find.text('The full overview.'), findsOneWidget);
      expect(watchedButton(), findsOneWidget);
    });
  });

  testWidgets('without a seed a failed read still falls back to the given item', (tester) async {
    await tester.runAsync(() async {
      await pumpDetail(tester, seeded: false);

      detailAnswer.complete(_json({'title': 'Server error'}, 500));
      await settle(tester);

      expect(find.byKey(mediaDetailSeedErrorKey), findsNothing);
      expect(find.text('The card overview.'), findsOneWidget);
      expect(watchedButton(), findsOneWidget);
    });
  });

  testWidgets('on TV a failed read shows the error in front, with Retry focused', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    await tester.runAsync(() async {
      await pumpDetail(tester, seeded: true, tv: true);

      detailAnswer.complete(_json({'title': 'Server error'}, 500));
      await settle(tester);

      expect(find.byKey(mediaDetailSeedErrorKey), findsOneWidget);
      expect(find.byKey(tvDetailRevealGateKey), findsNothing, reason: 'the error is not behind the reveal gate');
      expect(find.byKey(tvDetailSeedPreviewKey), findsNothing);
      expect(retryHasFocus(), isTrue);
    });
  });

  testWidgets('on TV the card shows over the hidden hero until the page is revealed', (tester) async {
    TvDetectionService.debugSetAppleTVOverride(true);
    await tester.runAsync(() async {
      await pumpDetail(tester, seeded: true, tv: true);

      double previewOpacity() => tester.widget<AnimatedOpacity>(find.byKey(tvDetailSeedPreviewKey)).opacity;
      double revealOpacity() => tester.widget<AnimatedOpacity>(find.byKey(tvDetailRevealGateKey)).opacity;
      expect(previewOpacity(), 1);
      expect(revealOpacity(), 0);
      // The preview, and the hidden hero the gate builds once the route settles.
      expect(find.text('The card overview.'), findsWidgets);
      expect(find.byKey(mediaDetailSeedPlayKey), findsWidgets);

      detailAnswer.complete(
        _json({'content_id': 'movie:m1', 'type': 'movie', 'title': 'Heat', 'overview': 'The full overview.'}),
      );
      await settle(tester);
      await settle(tester);

      expect(revealOpacity(), 1);
      expect(find.byKey(tvDetailSeedPreviewKey), findsNothing, reason: 'the preview is dropped once it has faded');
      expect(find.byKey(mediaDetailSeedPlayKey), findsNothing);
      expect(find.text('The full overview.'), findsOneWidget);
    });
  });

  group('detailSeedable', () {
    test('movies and shows opened as themselves online are seeded', () {
      expect(detailSeedable(card), isTrue);
      expect(detailSeedable(card.copyWith(kind: MediaKind.show)), isTrue);
    });

    test('downloads, overrides, episodes and seasons are not', () {
      expect(detailSeedable(card, isOffline: true), isFalse);
      expect(detailSeedable(card, metadataOverride: card), isFalse);
      expect(detailSeedable(card.copyWith(kind: MediaKind.episode)), isFalse);
      expect(detailSeedable(card.copyWith(kind: MediaKind.season)), isFalse);
    });
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
