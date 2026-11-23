import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/player/player_base.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/providers/shader_provider.dart';
import 'package:plezy/screens/video_player/widgets/player_prompt_overlays.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/video_player_navigation.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/hdr_startup.dart';
import '../../test_helpers/io_fakes.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/playback_report_fakes.dart';
import '../../test_helpers/pump.dart';
import '../../test_helpers/stub_music_playback_service.dart';

/// Silo restarts a stream by starting a fresh session (a seek before the
/// stream's origin, a track or quality change, recovery, Retry). A session the
/// server ended for good (an administrator's stop, a pause past its limit:
/// Silo Android #1043) must not be replaced that way: the player confirms the
/// playing session first and leaves with the server's notice instead. One
/// test per file (see [installHdrStartupHarness]).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase db;

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    tmpRoot = await Directory.systemTemp.createTemp('server_ended_restart_test_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    await installHdrStartupHarness();
    DownloadStorageService.resetForTesting();
    await DownloadStorageService.instance.initialize(SettingsService.instance);
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  testWidgets('a restart of a session the server ended leaves the player instead of replacing it', (tester) async {
    final client = _GuardedClient();
    final multi = testMultiServer(clients: [client]);
    final offlineWatch = OfflineWatchSyncService(database: db, serverManager: multi.manager);
    final accountPreferences = AccountPreferencesController();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('window_manager');
    // The flow runs through first frame and shutdown, which activates and
    // cancels the OS media-controls event stream; an unmocked EventChannel
    // reports its MissingPluginException as a test failure.
    const mediaControlMethods = MethodChannel('com.edde746.os_media_controls/methods');
    const mediaControlEvents = MethodChannel('com.edde746.os_media_controls/events');
    messenger.setMockMethodCallHandler(windowChannel, (call) async => call.method.startsWith('is') ? false : null);
    messenger.setMockMethodCallHandler(mediaControlMethods, (call) async => null);
    messenger.setMockMethodCallHandler(mediaControlEvents, (call) async => null);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(mediaControlMethods, null);
      messenger.setMockMethodCallHandler(mediaControlEvents, null);
      tester.view.reset();
      offlineWatch.dispose();
      accountPreferences.dispose();
    });

    final navigator = GlobalKey<NavigatorState>();
    final key = GlobalKey<VideoPlayerScreenState>();
    final loadfileUrls = <String>[];

    PlayerBase player() => key.currentState!.player! as PlayerBase;

    ValueListenable<bool>? revealed() {
      final overlays = find.byType(VideoPlayerBufferingOverlay).evaluate();
      if (overlays.isEmpty) return null;
      return (overlays.single.widget as VideoPlayerBufferingOverlay).hasFirstFrame;
    }

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method != 'command') return null;
        final args = (call.arguments as Map?)?['args'];
        if (args is! List || args.isEmpty || args.first != 'loadfile') return null;
        loadfileUrls.add(args[1] as String);
        final source = loadfileUrls.length;
        if (source > 1) player().handlePlayerEvent('end-file', {'sourceId': source - 1, 'reason': 2});
        player().handlePlayerEvent('start-file', {'sourceId': source});
        player().handlePlayerEvent('file-loaded', {'sourceId': source});
        player().handlePlayerEvent('playback-restart', {'sourceId': source, 'positionSeconds': 0.0});
        return null;
      },
      testBody: () async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
              ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
              ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
              ChangeNotifierProvider<AccountPreferencesController>.value(value: accountPreferences),
              ChangeNotifierProvider(create: (_) => CompanionRemoteProvider()),
              ChangeNotifierProvider(create: (_) => WatchTogetherProvider()),
              ChangeNotifierProvider(create: (_) => ShaderProvider()),
              ChangeNotifierProvider<MusicPlaybackService>(create: (_) => StubMusicPlaybackService()),
              Provider<AppDatabase>.value(value: db),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              home: const Scaffold(body: Text('Browse')),
            ),
          ),
        );
        unawaited(
          VideoPlayerRoute(
            builder: (_) => VideoPlayerScreen(
              key: key,
              metadata: testMediaItem(
                id: 'paused-movie',
                serverId: 'srv-1',
                title: 'Paused movie',
                backend: MediaBackend.jellyfin,
              ),
              selectedQualityPreset: TranscodeQualityPreset.original,
            ),
          ).push(navigator.currentState!),
        );

        await pumpUntil(
          tester,
          () => revealed()?.value == true,
          describe: () => 'loadfiles=$loadfileUrls, first frame never revealed',
        );

        Future<void> seekAndSettle(Duration target) async {
          var done = false;
          final seeking = key.currentState!.debugSeekPlaybackForTesting(target).whenComplete(() => done = true);
          // Drift/database work needs real-event-loop yields.
          for (var i = 0; i < 400 && !done; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            if (!done) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
          }
          await seeking;
          await tester.pump();
        }

        // A seek before the stream's origin restarts it there; the playing
        // session is confirmed first and, while live, replaced.
        await seekAndSettle(const Duration(minutes: 1));
        expect(client.confirmed, ['sess-1']);
        expect(client.initializations, 2);
        expect(loadfileUrls, hasLength(2));
        await pumpUntil(tester, () => revealed()?.value == true, describe: () => 'the restarted stream never showed');

        // The server ended the new session after a long pause: the next
        // restart leaves the player with the paused-too-long notice, opens
        // no fresh session and offers no Retry.
        client.ended = PlaybackSessionTerminatedException(
          code: 410,
          reason: 'playback_session_paused_timeout',
          leavePlayback: true,
          leaveNotice: 'Playback stopped because it was paused for too long.',
        );
        await seekAndSettle(const Duration(minutes: 1));
        await tester.pump(const Duration(milliseconds: 100));
        expect(client.confirmed, ['sess-1', 'sess-2']);
        expect(client.initializations, 2, reason: 'no fresh session replaces one the server ended');
        expect(loadfileUrls, hasLength(2));
        expect(find.text('Playback stopped because it was paused for too long.'), findsOneWidget);
        expect(find.text(t.common.retry), findsNothing);
        expect(find.text(t.common.back), findsOneWidget);

        var shutdownDone = false;
        final shutdown = PlaybackCoordinator.instance.shutdownVideo().whenComplete(() => shutdownDone = true);
        await pumpUntil(tester, () => shutdownDone);
        await shutdown;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}

/// A server whose stream starts part-way in (a resumed remux), so a seek
/// before its origin restarts it, and whose sessions the restart guard
/// confirms: [ended] makes the guard report the server's end.
class _GuardedClient with PlaybackReportRecorder implements MediaServerClient, PlaybackSessionRestartGuard {
  int initializations = 0;
  final confirmed = <String>[];
  PlaybackSessionTerminatedException? ended;

  @override
  ServerId get serverId => ServerId('srv-1');
  @override
  String get serverName => 'Server';
  @override
  MediaBackend get backend => MediaBackend.jellyfin;
  @override
  ServerCapabilities get capabilities => ServerCapabilities.jellyfin;
  @override
  double get watchedThreshold => 0.9;
  @override
  bool get marksWatchedOnPlaybackStopped => true;
  @override
  Map<String, String> get streamHeaders => const {};

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    initializations++;
    final url = 'https://example.invalid/${options.metadata.id}/$initializations';
    return PlaybackInitializationResult(
      availableVersions: const [],
      videoUrl: url,
      playSessionId: 'sess-$initializations',
      mediaInfo: MediaSourceInfo(
        videoUrl: url,
        audioTracks: const [],
        subtitleTracks: const [],
        chapters: const [],
        timelineOffset: const Duration(minutes: 10),
      ),
    );
  }

  @override
  Future<void> confirmPlaybackSessionBeforeRestart(String playSessionId) async {
    confirmed.add(playSessionId);
    final end = ended;
    if (end != null) throw end;
  }

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async => PlaybackExtras(chapters: const [], markers: const []);

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async => null;

  @override
  Future<void> onPlaybackReport(PlaybackReportCall call) async {}

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
