import 'dart:convert';

import 'package:flutter/material.dart';
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
    // Nothing is drawn before the settings answer: Plezy's indicator shows.
    expect(find.byType(SiloCardOverlayLayer), findsNothing);
    expect(indicators(tester).single.showWatchStatus, isTrue);

    await tester.pumpAndSettle();
    expect(find.byType(SiloCardOverlayLayer), findsOneWidget);
    // Classic look, defaults: resolution, HDR and audio top left, release type bottom left.
    expect(find.text('4K'), findsOneWidget);
    expect(find.text('DV'), findsOneWidget);
    expect(find.text('ATMOS'), findsOneWidget);
    expect(find.text('REMUX'), findsOneWidget);
    expect(find.textContaining('IMDB'), findsNothing, reason: 'ratings are off by default');
    expect(indicators(tester).single.showWatchStatus, isFalse);
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

  testWidgets('a profile with overlays off keeps Plezy\'s indicator', (tester) async {
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
    expect(find.byType(SiloCardOverlayLayer), findsNothing);
    expect(indicators(tester).single.showWatchStatus, isTrue);
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
