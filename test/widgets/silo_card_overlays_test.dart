import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/silo/silo_card_overlay_store.dart';
import 'package:plezy/services/silo/silo_card_overlays.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/silo_card_overlays.dart';
import 'package:plezy/widgets/silo_overlay_icons.dart';
import 'package:plezy/widgets/watched_indicator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

const _summary = {'resolution': '2160p', 'hdr': 'DV', 'audio': 'Atmos', 'release_type': 'REMUX'};

MediaItem _movie(MediaBackend backend, {bool watched = false}) => testMediaItem(
  id: 'movie:heat-1995',
  backend: backend,
  kind: MediaKind.movie,
  title: 'Heat',
  viewCount: watched ? 1 : 0,
  raw: {'overlay_summary': _summary, 'rating_imdb': 8.3},
);

SiloCardOverlayStore _store(Map<String, dynamic>? config, {Map<String, dynamic>? values}) =>
    SiloCardOverlayStore(cacheKey: 'srv/u/p', readConfig: () async => config, readValues: () async => values);

Widget _app(Widget child) => MaterialApp(
  theme: monoTheme(MonoPalette.dark),
  home: Scaffold(body: Center(child: child)),
);

Widget _card(MediaItem item) =>
    MediaCard(item: item, width: 191, height: 279, viewModeOverride: ViewMode.grid, isOffline: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    SiloCardOverlayStore.resetKnownForTesting();
    SiloOverlayLayout.clearCaches();
  });

  tearDown(() {
    CardArtworkOverlays.debugStoreResolver = null;
    CardArtworkOverlays.debugImageUrlResolver = null;
  });

  Iterable<WatchedIndicator> indicators(WidgetTester tester) =>
      tester.widgetList<WatchedIndicator>(find.byType(WatchedIndicator));

  testWidgets("a Silo card draws its profile's badges and Silo's watch status instead of Plezy's", (tester) async {
    final store = _store({'enabled': true});
    final requested = <MediaItem>[];
    CardArtworkOverlays.debugStoreResolver = (context, item) {
      requested.add(item);
      return item is SiloMediaItem ? store : null;
    };
    await tester.pumpWidget(_app(_card(_movie(MediaBackend.silo, watched: true))));
    // Before the settings answer no badge is drawn, but the poster's corner
    // is already Silo's watch status.
    expect(find.text('4K'), findsNothing);
    expect(find.byType(SiloWatchedCheck), findsOneWidget);
    expect(indicators(tester).single.showWatchStatus, isFalse);

    await tester.pumpAndSettle();
    expect(find.byType(SiloCardOverlayLayer), findsOneWidget);
    // Classic look, defaults: resolution, HDR and audio top left, release type bottom left.
    expect(find.text('4K'), findsOneWidget);
    expect(find.text('DV'), findsOneWidget);
    expect(find.text('ATMOS'), findsOneWidget);
    expect(find.text('REMUX'), findsOneWidget);
    expect(find.textContaining('IMDB'), findsNothing, reason: 'ratings are off by default');
    expect(indicators(tester).single.showWatchStatus, isFalse);
    expect(find.byType(SiloWatchedCheck), findsOneWidget, reason: 'one watched indicator, Silo\'s');
    final layer = tester.widget<SiloCardOverlayLayer>(find.byType(SiloCardOverlayLayer));
    expect(layer.watched, isTrue);
    expect(layer.shape, SiloOverlayCardShape.poster);
    expect(requested.single, isA<SiloMediaItem>());
  });

  testWidgets('the combined badge replaces the badges it covers on the card', (tester) async {
    final store = _store({
      'enabled': true,
      'defaults': jsonEncode({
        'version': 2,
        'preset': 'pill',
        'items': {
          'resolution_hdr_audio': {'enabled': true},
          'rating_imdb': {'enabled': true},
        },
      }),
    });
    CardArtworkOverlays.debugStoreResolver = (context, item) => store;
    await tester.pumpWidget(_app(_card(_movie(MediaBackend.silo))));
    await tester.pumpAndSettle();
    expect(find.text('4K DV ATMOS'), findsOneWidget);
    expect(find.text('4K'), findsNothing);
    expect(find.text('IMDB 8.3'), findsOneWidget);
  });

  testWidgets("a profile with overlays off draws no badges but keeps Silo's watch status on posters", (tester) async {
    final store = _store(
      {'enabled': true},
      values: {
        'items': [
          {'key': 'ui.card_overlays_enabled', 'source': 'profile', 'value': false},
        ],
      },
    );
    CardArtworkOverlays.debugStoreResolver = (context, item) => store;
    await tester.pumpWidget(_app(_card(_movie(MediaBackend.silo, watched: true))));
    await tester.pumpAndSettle();
    expect(store.value!.enabled, isFalse);
    expect(find.text('4K'), findsNothing);
    expect(find.byType(SiloOverlayBadgeView), findsNothing);
    expect(find.byType(SiloWatchedCheck), findsOneWidget);
    expect(indicators(tester).single.showWatchStatus, isFalse);
  });

  testWidgets("a wide Silo card keeps Plezy's check, the one indicator it has, with Silo's badges", (tester) async {
    final store = _store({'enabled': true});
    CardArtworkOverlays.debugStoreResolver = (context, item) => store;
    await tester.pumpWidget(
      _app(
        MediaCard(
          item: _movie(MediaBackend.silo, watched: true),
          width: 320,
          height: 180,
          viewModeOverride: ViewMode.grid,
          cardShapeOverride: CardShape.wide,
          isOffline: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('4K'), findsOneWidget);
    expect(find.byType(SiloWatchedCheck), findsNothing, reason: 'Silo draws no watch status on landscape artwork');
    expect(indicators(tester).single.showWatchStatus, isTrue);

    // Badges off: a wide card is Plezy's own.
    store.dispose();
    final off = _store({'enabled': false});
    CardArtworkOverlays.debugStoreResolver = (context, item) => off;
    await tester.pumpWidget(_app(const SizedBox()));
    await tester.pumpWidget(
      _app(
        MediaCard(
          item: _movie(MediaBackend.silo, watched: true),
          width: 320,
          height: 180,
          viewModeOverride: ViewMode.grid,
          cardShapeOverride: CardShape.wide,
          isOffline: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SiloCardOverlayLayer), findsNothing);
    expect(indicators(tester).single.showWatchStatus, isTrue);
  });

  testWidgets("a card whose client closed its store switches to the replacement client's store", (tester) async {
    final old = SiloCardOverlayStore(
      cacheKey: 'srv/u/old',
      readConfig: () async => {'enabled': true},
      readValues: () async => null,
    );
    final replacement = SiloCardOverlayStore(
      cacheKey: 'srv/u/new',
      readConfig: () async => {'enabled': false},
      readValues: () async => null,
    );
    var current = old;
    CardArtworkOverlays.debugStoreResolver = (context, item) => current;
    await tester.pumpWidget(_app(_card(_movie(MediaBackend.silo))));
    await tester.pumpAndSettle();
    expect(find.byType(SiloCardOverlayLayer), findsOneWidget);

    // The client is replaced: the old one disposes its store on close.
    current = replacement;
    old.dispose();
    await tester.pumpAndSettle();
    expect(replacement.value, isNotNull, reason: 'the card loaded the new store');
    expect(find.byType(SiloOverlayBadgeView), findsNothing, reason: 'it draws what the new store says');
  });

  testWidgets('Plex, Jellyfin and Emby cards are unchanged', (tester) async {
    final store = _store({'enabled': true});
    var asked = 0;
    CardArtworkOverlays.debugStoreResolver = (context, item) {
      asked++;
      return store;
    };
    for (final backend in [MediaBackend.plex, MediaBackend.jellyfin, MediaBackend.emby]) {
      await tester.pumpWidget(_app(_card(_movie(backend, watched: true))));
      await tester.pumpAndSettle();
      expect(find.byType(SiloCardOverlayLayer), findsNothing, reason: backend.name);
      expect(find.text('4K'), findsNothing, reason: backend.name);
      expect(indicators(tester).single.showWatchStatus, isTrue, reason: backend.name);
    }
    expect(asked, 0, reason: 'only Silo items look for overlay settings');
    expect(store.value, isNull);
  });

  testWidgets('a started series shows the episodes left in the watch-status corner', (tester) async {
    final settings = SiloCardOverlaySettings.settle(null, {'enabled': true});
    final series = testMediaItem(
      id: 'series:x',
      backend: MediaBackend.silo,
      kind: MediaKind.show,
      serverId: 'srv',
      leafCount: 10,
      viewedLeafCount: 4,
      raw: const {},
    );
    expect(siloEpisodesLeftOf(series), 6);
    final untouched = testMediaItem(
      id: 'series:y',
      backend: MediaBackend.silo,
      kind: MediaKind.show,
      raw: const {
        'user_state': {'played': false, 'watched_count': 0, 'unplayed_count': 9},
      },
    );
    expect(siloEpisodesLeftOf(untouched), 0);
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 185,
          height: 277,
          child: SiloCardOverlayLayer(
            settings: settings,
            data: SiloOverlayData.ofRaw(series.raw),
            shape: SiloOverlayCardShape.poster,
            episodesLeft: siloEpisodesLeftOf(series),
            imageUrl: (_) => null,
          ),
        ),
      ),
    );
    expect(find.text('6'), findsOneWidget);
  });

  test('layout: poster lengths scale with width; the top row stops short of the watch-status corner', () {
    final settings = SiloCardOverlaySettings.settle(null, {'enabled': true});
    final data = SiloOverlayData.fromJson({'overlay_summary': _summary});
    final poster = SiloOverlayLayout.compute(
      settings: settings,
      data: data,
      width: 370,
      height: 555,
      shape: SiloOverlayCardShape.poster,
      watched: true,
    );
    expect(poster.k, 2);
    final badges = poster.parts.whereType<SiloOverlayBadgePart>().toList();
    expect([for (final b in badges) b.plan.badge.id], ['resolution', 'hdr', 'audio', 'release_type']);
    final first = badges.first.rect;
    expect(first.left, 16);
    expect(first.top, 16);
    final check = poster.parts.whereType<SiloOverlayCheckPart>().single.rect;
    expect(check, const Rect.fromLTWH(370 - 16 - 44, 16, 44, 44));
    for (final b in badges) {
      expect(b.rect.right, lessThanOrEqualTo(370 - 16 - 44 - 16 + 0.5));
    }
    final release = badges.last.rect;
    expect(release.bottom, 555 - 16);

    final wide = SiloOverlayLayout.compute(
      settings: settings,
      data: data,
      width: 300,
      height: 169,
      shape: SiloOverlayCardShape.wide,
      progress: true,
    );
    expect(wide.k, 1);
    final lifted = wide.parts.whereType<SiloOverlayBadgePart>().last.rect;
    expect(lifted.bottom, 169 - 16, reason: 'a wide card lifts its bottom row over the progress bar');
  });

  test('layout: a poster with a progress bar lifts its bottom row one inset; the count is sized like the web', () {
    final settings = SiloCardOverlaySettings.settle(null, {'enabled': true});
    final data = SiloOverlayData.fromJson({'overlay_summary': _summary});
    final lifted = SiloOverlayLayout.compute(
      settings: settings,
      data: data,
      width: 185,
      height: 277,
      shape: SiloOverlayCardShape.poster,
      progress: true,
      episodesLeft: 12,
    );
    final release = lifted.parts.whereType<SiloOverlayBadgePart>().last;
    expect(release.plan.badge.id, 'release_type');
    expect(release.rect.bottom, 277 - 16);
    final count = lifted.parts.whereType<SiloOverlayCountPart>().single;
    expect(count.fontSize, 11);
    expect(count.rect.height, 22);
    expect(count.rect.top, 8);
    expect(count.rect.right, 185 - 8);
    expect(count.rect.width, greaterThanOrEqualTo(22));
    expect(lifted.parts.whereType<SiloOverlayCheckPart>(), isEmpty, reason: 'the count wins over the check');
  });

  test('layout: with badges off a poster draws only its watch status', () {
    final layout = SiloOverlayLayout.compute(
      settings: SiloCardOverlaySettings.off,
      data: SiloOverlayData.fromJson({'overlay_summary': _summary}),
      width: 185,
      height: 277,
      shape: SiloOverlayCardShape.poster,
      watched: true,
    );
    expect(layout.parts.whereType<SiloOverlayBadgePart>(), isEmpty);
    expect(layout.parts.whereType<SiloOverlayCheckPart>().single.rect, const Rect.fromLTWH(185 - 8 - 22, 8, 22, 22));
  });

  test('layout: an uploaded icon is capped at the badge content width; wordmarks size at 10/12, ATMOS 9/12', () {
    final ref = '${'c' * 64}.webp';
    final settings = SiloCardOverlaySettings.settle(
      SiloOverlayProfileValues(
        document: {
          'version': 2,
          'preset': 'pill',
          'items': {
            'release_type': {'enabled': true, 'image': ref},
          },
        },
      ),
      {
        'enabled': true,
        'images': [
          {'ref': ref, 'width': 600, 'height': 20},
        ],
      },
    );
    final layout = SiloOverlayLayout.compute(
      settings: settings,
      data: SiloOverlayData.fromJson({'overlay_summary': _summary}),
      width: 185,
      height: 277,
      shape: SiloOverlayCardShape.poster,
    );
    final plans = {for (final p in layout.parts.whereType<SiloOverlayBadgePart>()) p.plan.badge.id: p.plan};
    final release = plans['release_type']!;
    expect(release.lead, SiloLeadKind.image);
    // 169 available, minus the 1 px borders and 10 px padding either side.
    expect(release.leadW, 169 - 2 - 20);
    expect(release.w, lessThanOrEqualTo(169));
    final audio = plans['audio']!;
    expect(audio.lead, SiloLeadKind.mark);
    expect(audio.markFontSize, 12 * 9 / 12);
    expect(siloWordmarkFontSize('hdr10', 12), 10);
  });

  testWidgets('a look that prefers icons draws Lucide glyphs', (tester) async {
    final settings = SiloCardOverlaySettings.settle(
      SiloOverlayProfileValues(
        document: {
          'version': 2,
          'preset': 'pill',
          'items': {
            'runtime': {'enabled': true},
          },
        },
      ),
      {'enabled': true},
    );
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 185,
          height: 277,
          child: SiloCardOverlayLayer(
            settings: settings,
            data: SiloOverlayData.fromJson({'overlay_summary': _summary, 'runtime': 170}),
            shape: SiloOverlayCardShape.poster,
            imageUrl: (_) => null,
          ),
        ),
      ),
    );
    final glyphs = tester.widgetList<SiloOverlayGlyph>(find.byType(SiloOverlayGlyph)).map((g) => g.icon).toList();
    expect(glyphs, containsAll(['monitor', 'dolby-vision', 'clock']));
    expect(find.text('2H 50M'), findsOneWidget);
  });

  testWidgets("badge text keeps its measured spacing whatever the theme's text style says", (tester) async {
    // A theme style with letter spacing used to leak into the drawn text, so a
    // label came out wider than measured and ellipsized ("1080p" as "108…").
    final settings = SiloCardOverlaySettings.settle(
      SiloOverlayProfileValues(
        document: {
          'version': 2,
          'preset': 'pill',
          'items': {
            'runtime': {'enabled': true},
          },
        },
      ),
      {'enabled': true},
    );
    await tester.pumpWidget(
      _app(
        DefaultTextStyle.merge(
          style: const TextStyle(letterSpacing: 3, wordSpacing: 4),
          child: SizedBox(
            width: 185,
            height: 277,
            child: SiloCardOverlayLayer(
              settings: settings,
              data: SiloOverlayData.fromJson({'overlay_summary': _summary, 'runtime': 170}),
              shape: SiloOverlayCardShape.poster,
              imageUrl: (_) => null,
            ),
          ),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(find.text('2H 50M'));
    final style = (paragraph.text as TextSpan).style!;
    expect(style.letterSpacing, isNot(3), reason: "the preset's spacing, not the theme's");
    expect(style.letterSpacing, closeTo(0.25, 0.01));
    expect(style.wordSpacing, 0);
    expect(paragraph.overflow, TextOverflow.visible, reason: 'a label measured to fit never ellipsizes');
  });

  group('badges follow the system text size, held to 1-1.35x (Silo Android #912)', () {
    final settings = SiloCardOverlaySettings.settle(
      SiloOverlayProfileValues(
        document: {
          'version': 2,
          'preset': 'pill',
          'items': {
            'runtime': {'enabled': true},
          },
        },
      ),
      {'enabled': true},
    );

    Future<void> pumpAt(WidgetTester tester, double textScale) async {
      await tester.pumpWidget(
        _app(
          MediaQuery.withClampedTextScaling(
            minScaleFactor: textScale,
            maxScaleFactor: textScale,
            child: SizedBox(
              width: 185,
              height: 277,
              child: SiloCardOverlayLayer(
                settings: settings,
                data: SiloOverlayData.fromJson({'overlay_summary': _summary, 'runtime': 170}),
                shape: SiloOverlayCardShape.poster,
                watched: true,
                imageUrl: (_) => null,
              ),
            ),
          ),
        ),
      );
    }

    ({double font, Size badge, Size check, TextScaler scaler}) measured(WidgetTester tester) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text('2H 50M'));
      return (
        font: (paragraph.text as TextSpan).style!.fontSize!,
        badge: tester.getSize(find.ancestor(of: find.text('2H 50M'), matching: find.byType(SiloOverlayBadgeView))),
        check: tester.getSize(find.byType(SiloWatchedCheck)),
        scaler: paragraph.textScaler,
      );
    }

    testWidgets('a 2.0 text scale draws badges and the watch status at 1.35x; 0.8 at 1x', (tester) async {
      await pumpAt(tester, 1);
      final base = measured(tester);
      expect(base.font, 10, reason: "the pill look's 10 px at the 185 px reference");
      expect(base.check, const Size(22, 22));

      // No cache reset between pumps: the text factor is part of the layout's cache key.
      await pumpAt(tester, 2);
      final large = measured(tester);
      expect(large.font, closeTo(13.5, 1e-9), reason: 'exact pixels from the overlay scale');
      expect(large.scaler, TextScaler.noScaling, reason: 'the text size counts once, not again in the paragraph');
      expect(large.check.width, closeTo(22 * 1.35, 1e-9));
      expect(large.badge.height, closeTo(base.badge.height * 1.35, 0.01));
      expect(large.badge.width, greaterThan(base.badge.width * 1.3));
      final paragraph = tester.renderObject<RenderParagraph>(find.text('2H 50M'));
      expect(paragraph.overflow, TextOverflow.visible, reason: 'measured with the drawn style, so it still fits');
      expect(paragraph.didExceedMaxLines, isFalse);

      await pumpAt(tester, 0.8);
      final small = measured(tester);
      expect(small.font, 10, reason: 'smaller text never shrinks badges');
      expect(small.check, const Size(22, 22));
      expect(small.badge, base.badge);
    });
  });

  testWidgets("a wide Silo card's check follows the library density and text size", (tester) async {
    await SettingsService.instance.write(SettingsService.libraryDensity, 5);
    final store = _store({'enabled': true});
    CardArtworkOverlays.debugStoreResolver = (context, item) => store;
    await tester.pumpWidget(
      _app(
        MediaQuery.withClampedTextScaling(
          minScaleFactor: 1.1,
          maxScaleFactor: 1.1,
          child: MediaCard(
            item: _movie(MediaBackend.silo, watched: true),
            width: 320,
            height: 180,
            viewModeOverride: ViewMode.grid,
            cardShapeOverride: CardShape.wide,
            isOffline: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(indicators(tester).single.checkScale, closeTo(1.2 * 1.1, 1e-9));
    expect(tester.widget<SiloCardOverlayLayer>(find.byType(SiloCardOverlayLayer)).wideScale, 1.2);
  });

  test('layout: a band look draws scrims and dividers', () {
    final settings = SiloCardOverlaySettings.settle(
      SiloOverlayProfileValues(
        document: {
          'version': 2,
          'preset': 'band',
          'items': {
            'year': {'enabled': true},
          },
        },
      ),
      {'enabled': true},
    );
    final layout = SiloOverlayLayout.compute(
      settings: settings,
      data: SiloOverlayData.fromJson({'overlay_summary': _summary, 'year': 1995}),
      width: 185,
      height: 277,
      shape: SiloOverlayCardShape.poster,
    );
    expect(layout.parts.whereType<SiloOverlayScrimPart>().length, 2);
    expect(layout.parts.whereType<SiloOverlayDividerPart>(), isNotEmpty);
  });
}
