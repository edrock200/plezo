import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/silo/silo_mappers.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/media_progress_bar.dart';
import 'package:plezy/widgets/unwatched_count_badge.dart';
import 'package:plezy/widgets/watched_indicator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  Future<void> pump(WidgetTester tester, WatchedIndicator indicator) => tester.pumpWidget(
    MaterialApp(
      theme: monoTheme(MonoPalette.dark),
      home: SizedBox(width: 200, height: 300, child: indicator),
    ),
  );

  final watchedMovie = testMediaItem(id: 'movie', kind: MediaKind.movie, viewCount: 1);

  testWidgets('shows the watched checkmark by default', (tester) async {
    await pump(tester, WatchedIndicator(item: watchedMovie));

    expect(find.byIcon(Symbols.check_rounded), findsOneWidget);
  });

  testWidgets('hides only the checkmark when watched indicators are off (#1998)', (tester) async {
    await SettingsService.instance.write(SettingsService.showWatchedIndicators, false);
    final partiallyWatchedShow = testMediaItem(id: 'show', kind: MediaKind.show, leafCount: 10, viewedLeafCount: 4);
    final inProgressMovie = testMediaItem(
      id: 'movie-2',
      kind: MediaKind.movie,
      durationMs: 100000,
      viewOffsetMs: 50000,
    );

    await pump(tester, WatchedIndicator(item: watchedMovie));
    expect(find.byIcon(Symbols.check_rounded), findsNothing);

    await pump(tester, WatchedIndicator(item: partiallyWatchedShow));
    expect(find.byType(UnwatchedCountBadge), findsOneWidget, reason: 'unwatched counts are a separate pref');

    await pump(tester, WatchedIndicator(item: inProgressMovie));
    expect(find.byType(MediaProgressBar), findsOneWidget, reason: 'progress bars are not indicators');
  });

  group('Silo items as the server sends them', () {
    final ctx = SiloMappingContext(serverId: 'silo', serverName: 'Silo', resolveUrl: (url) => url);

    testWidgets('a played movie detail shows the checkmark (watched_count is always 0 on leaves)', (tester) async {
      final movie = SiloMappers.item({
        'content_id': 'movie:heat-1995',
        'type': 'movie',
        'title': 'Heat',
        'user_data': {'played': true, 'watched_count': 0, 'unplayed_count': 0, 'in_progress_count': 0},
      }, ctx)!;
      await pump(tester, WatchedIndicator(item: movie));
      expect(find.byIcon(Symbols.check_rounded), findsOneWidget);
    });

    testWidgets('a season and a series detail show their unwatched episode counts', (tester) async {
      final season = SiloMappers.item({
        'content_id': 'season:orbital-s01',
        'type': 'season',
        'series_id': 'series:orbital',
        'season_number': 1,
        'episode_count': 10,
        'user_data': {'played': false, 'watched_count': 3, 'unplayed_count': 7, 'in_progress_count': 0},
      }, ctx)!;
      await pump(tester, WatchedIndicator(item: season));
      expect(tester.widget<UnwatchedCountBadge>(find.byType(UnwatchedCountBadge)).count, 7);

      final series = SiloMappers.item({
        'content_id': 'series:orbital',
        'type': 'series',
        'title': 'Orbital',
        'user_data': {'played': false, 'watched_count': 11, 'unplayed_count': 5, 'in_progress_count': 0},
      }, ctx)!;
      await pump(tester, WatchedIndicator(item: series));
      expect(tester.widget<UnwatchedCountBadge>(find.byType(UnwatchedCountBadge)).count, 5);
    });
  });
}
