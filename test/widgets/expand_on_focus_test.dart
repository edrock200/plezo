import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/focus/locked_hub_controller.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/expand_on_focus.dart';
import 'package:plezy/widgets/hub_section.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/tv_browse_rail.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
  });

  final withArt = testMediaItem(
    id: 'movie_art',
    kind: MediaKind.movie,
    title: 'Wide Movie',
    thumbPath: '/poster/1',
    artPath: '/art/1',
  );
  final secondWithArt = testMediaItem(
    id: 'movie_art_2',
    kind: MediaKind.movie,
    title: 'Second Movie',
    thumbPath: '/poster/2',
    artPath: '/art/2',
  );
  final withoutArt = testMediaItem(id: 'movie_plain', kind: MediaKind.movie, title: 'Plain Movie', thumbPath: '/p/3');

  Finder cardOf(MediaItem item) => find.byWidgetPredicate((w) => w is MediaCard && identical(w.item, item));

  group('setting', () {
    test('is off by default and persists on the device', () async {
      expect(SettingsService.instance.read(SettingsService.expandOnFocus), isFalse);

      await SettingsService.instance.write(SettingsService.expandOnFocus, true);
      BaseSharedPreferencesService.resetForTesting();
      SettingsService.resetForTesting();
      final reloaded = await SettingsService.getInstance();

      expect(reloaded.read(SettingsService.expandOnFocus), isTrue);
    });
  });

  group('wide art', () {
    test('movies use their backdrop, then inherited art', () {
      expect(ExpandOnFocus.wideArtPath(withArt), '/art/1');
      expect(ExpandOnFocus.wideArtPath(withoutArt), isNull);
    });

    test('episodes use their still, the series backdrop when spoilers are hidden', () {
      final episode = testMediaItem(
        id: 'ep',
        kind: MediaKind.episode,
        thumbPath: '/still',
        grandparentArtPath: '/series-art',
        grandparentThumbPath: '/series-poster',
        viewCount: 0,
      );
      expect(ExpandOnFocus.wideArtPath(episode), '/still');
      expect(ExpandOnFocus.wideArtPath(episode, hideSpoilers: true), '/series-art');
    });

    test('music, wide cards and offline items never expand', () {
      final album = testMediaItem(id: 'al', kind: MediaKind.album, artPath: '/art');
      final clip = testMediaItem(id: 'cl', kind: MediaKind.clip, thumbPath: '/t', artPath: '/art');
      final episode = testMediaItem(id: 'ep', kind: MediaKind.episode, thumbPath: '/still');
      const mode = EpisodePosterMode.seriesPoster;
      expect(ExpandOnFocus.canExpand(album, episodePosterMode: mode), isFalse);
      expect(ExpandOnFocus.canExpand(clip, episodePosterMode: mode), isFalse);
      expect(ExpandOnFocus.canExpand(withArt, episodePosterMode: mode, isOffline: true), isFalse);
      expect(ExpandOnFocus.canExpand(withArt, episodePosterMode: mode), isTrue);
      // Already 16:9 in thumbnail mode; a portrait series poster can widen.
      expect(ExpandOnFocus.canExpand(episode, episodePosterMode: EpisodePosterMode.episodeThumbnail), isFalse);
      expect(ExpandOnFocus.canExpand(episode, episodePosterMode: mode), isTrue);
    });
  });

  group('hub row', () {
    Future<GlobalKey<HubSectionState>> pumpHub(WidgetTester tester, {required bool enabled}) async {
      await SettingsService.instance.write(SettingsService.expandOnFocus, enabled);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      final hubKey = GlobalKey<HubSectionState>();
      await tester.pumpWidget(
        InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Scaffold(
              body: ListView(
                children: [
                  HubSection(
                    key: hubKey,
                    hub: MediaHub(
                      id: 'movies',
                      title: 'Movies',
                      type: 'movie',
                      items: [withArt, secondWithArt, withoutArt],
                      size: 3,
                    ),
                    focusMemory: HubFocusMemory(),
                    icon: Symbols.movie_rounded,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      // D-pad/keyboard mode: rows draw focus (and expand) only then.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      hubKey.currentState!.requestFocusAt(0);
      await tester.pumpAndSettle();
      return hubKey;
    }

    testWidgets('a focused poster widens to 16:9 and shrinks back on blur', (tester) async {
      await pumpHub(tester, enabled: true);

      final collapsed = tester.getSize(cardOf(secondWithArt));
      final focused = tester.getSize(cardOf(withArt));
      final posterHeight = collapsed.width - MediaCard.gridCardPadding.horizontal;
      final expectedWidth = ExpandOnFocus.expandedCardWidth(
        artworkHeight: posterHeight * 1.5,
        horizontalInset: MediaCard.gridCardPadding.horizontal,
      );
      expect(focused.width, closeTo(expectedWidth, 0.5));
      expect(focused.height, collapsed.height, reason: 'the card keeps its height');
      expect(find.descendant(of: cardOf(withArt), matching: find.byKey(ExpandedArtLayer.layerKey)), findsOneWidget);

      // Halfway through the motion the card is between both widths.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(ExpandOnFocus.duration ~/ 2);
      final midWidth = tester.getSize(cardOf(withArt)).width;
      expect(midWidth, lessThan(expectedWidth));
      expect(midWidth, greaterThan(collapsed.width));

      await tester.pumpAndSettle();
      expect(tester.getSize(cardOf(withArt)).width, closeTo(collapsed.width, 0.01));
      expect(find.descendant(of: cardOf(withArt), matching: find.byKey(ExpandedArtLayer.layerKey)), findsNothing);
      expect(tester.getSize(cardOf(secondWithArt)).width, closeTo(expectedWidth, 0.5));
    });

    testWidgets('cards stay put with the setting off', (tester) async {
      await pumpHub(tester, enabled: false);

      final focused = tester.getSize(cardOf(withArt));
      final other = tester.getSize(cardOf(secondWithArt));
      expect(focused.width, other.width);
      expect(find.byKey(ExpandedArtLayer.layerKey), findsNothing);
    });

    testWidgets('a poster without wide art does not expand', (tester) async {
      final hubKey = await pumpHub(tester, enabled: true);
      final collapsedWidth = tester.getSize(cardOf(secondWithArt)).width;

      hubKey.currentState!.requestFocusAt(2);
      await tester.pumpAndSettle();

      expect(tester.getSize(cardOf(withoutArt)).width, closeTo(collapsedWidth, 0.01));
      expect(find.byKey(ExpandedArtLayer.layerKey), findsNothing);
    });
  });

  testWidgets('TV rail: the focused poster widens and neighbours move aside', (tester) async {
    await SettingsService.instance.write(SettingsService.expandOnFocus, true);
    await SettingsService.instance.write(SettingsService.tvFullCardLayout, false);
    TvDetectionService.debugSetAppleTVOverride(true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final hub = MediaHub(
      id: 'movies',
      title: 'Movies',
      type: 'movie',
      items: [withArt, secondWithArt, withoutArt],
      size: 3,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<MultiServerProvider>(
        create: (_) => testMultiServerProvider(MultiServerManager()),
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Scaffold(
              body: SizedBox(
                width: 1280,
                height: 720,
                child: TvBrowseRail(
                  focusMemory: HubFocusMemory(),
                  hubs: [hub],
                  autofocus: true,
                  iconForHub: (_, _) => Icons.movie_rounded,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final focused = tester.getRect(cardOf(withArt));
    final neighbour = tester.getRect(cardOf(secondWithArt));
    final expandedWidth = tester.getSize(cardOf(withArt)).width;
    expect(expandedWidth, greaterThan(neighbour.width * 1.5));
    // The focused card is also scaled up slightly (the focus zoom).
    expect(neighbour.left, greaterThan(focused.right - focused.width * 0.02), reason: 'neighbours move aside');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(tester.getSize(cardOf(withArt)).width, closeTo(neighbour.width, 0.01));
    expect(tester.getSize(cardOf(secondWithArt)).width, closeTo(expandedWidth, 0.01));
    final rail = tester.getRect(find.byType(TvBrowseRail));
    final expanded = tester.getRect(cardOf(secondWithArt));
    expect(expanded.left, greaterThanOrEqualTo(rail.left));
    expect(expanded.right, lessThanOrEqualTo(rail.right), reason: 'the focused card stays in view');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(tester.getSize(cardOf(withoutArt)).width, closeTo(neighbour.width, 0.01));
  });
}
