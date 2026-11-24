import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/services/jellyfin_mappers.dart';
import 'package:plezy/services/silo/silo_mappers.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/widgets/video_controls_header.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  testWidgets('title-less mapped movie builds with localized fallback in both layouts', (tester) async {
    final item = _mappedItem({'Id': 'movie-without-name', 'Type': 'Movie'});

    for (final style in VideoHeaderStyle.values) {
      await _pumpHeader(tester, metadata: item, style: style);

      expect(find.text(t.common.unknown), findsOneWidget, reason: style.name);
      expect(tester.takeException(), isNull, reason: style.name);
    }
  });

  testWidgets('title-less mapped episode keeps series identity and uses fallback in both layouts', (tester) async {
    final item = _mappedItem({
      'Id': 'episode-without-name',
      'Type': 'Episode',
      'SeriesName': 'Mapped Series',
      'ParentIndexNumber': 2,
      'IndexNumber': 3,
    });

    for (final style in VideoHeaderStyle.values) {
      await _pumpHeader(tester, metadata: item, style: style);

      final expectedEpisodeLine = switch (style) {
        VideoHeaderStyle.singleLine => 'Mapped Series · S2E3 · ${t.common.unknown}',
        VideoHeaderStyle.multiLine => 'S2 · E3 · ${t.common.unknown}',
      };
      expect(find.text(expectedEpisodeLine), findsOneWidget, reason: style.name);
      expect(tester.takeException(), isNull, reason: style.name);
    }
  });

  testWidgets('ordinary mapped episode wording remains unchanged in both layouts', (tester) async {
    final item = _mappedItem({
      'Id': 'titled-episode',
      'Type': 'Episode',
      'Name': 'The Arrival',
      'SeriesName': 'Mapped Series',
      'ParentIndexNumber': 1,
      'IndexNumber': 4,
    });

    for (final style in VideoHeaderStyle.values) {
      await _pumpHeader(tester, metadata: item, style: style);

      final expectedEpisodeLine = switch (style) {
        VideoHeaderStyle.singleLine => 'Mapped Series · S1E4 · The Arrival',
        VideoHeaderStyle.multiLine => 'S1 · E4 · The Arrival',
      };
      expect(find.text(expectedEpisodeLine), findsOneWidget, reason: style.name);
      expect(find.text(t.common.unknown), findsNothing, reason: style.name);
    }
  });

  testWidgets('a Silo sports episode names itself by its air date in both layouts', (tester) async {
    final item = SiloMappers.item({
      'content_id': 'episode:nba-2026-296',
      'type': 'episode',
      'title': 'Lakers at Celtics',
      'series_title': 'NBA',
      'series_id': 'series:nba',
      'season_number': 2026,
      'episode_number': 296,
      'episode_labels': 'air_date',
      'air_date': '2026-11-20',
    }, _siloCtx)!;

    for (final style in VideoHeaderStyle.values) {
      await _pumpHeader(tester, metadata: item, style: style);

      final expectedEpisodeLine = switch (style) {
        VideoHeaderStyle.singleLine => 'NBA · Nov 20, 2026 · Lakers at Celtics',
        VideoHeaderStyle.multiLine => 'Nov 20, 2026 · Lakers at Celtics',
      };
      expect(find.text(expectedEpisodeLine), findsOneWidget, reason: style.name);
      expect(find.textContaining('S2026'), findsNothing, reason: style.name);
    }
  });
}

final _siloCtx = SiloMappingContext(serverId: 'srv-1', serverName: 'Home Silo', resolveUrl: (url) => url);

MediaItem _mappedItem(Map<String, dynamic> json) {
  return JellyfinMappers.mediaItem(
    json,
    serverId: ServerId('header-test-server'),
    serverName: 'Test Server',
    absolutizer: null,
  )!;
}

Future<void> _pumpHeader(WidgetTester tester, {required MediaItem metadata, required VideoHeaderStyle style}) async {
  final watchTogether = WatchTogetherProvider();
  addTearDown(watchTogether.dispose);

  await tester.pumpWidget(
    TranslationProvider(
      child: ChangeNotifierProvider<WatchTogetherProvider>.value(
        value: watchTogether,
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: SizedBox(
              width: 900,
              child: VideoControlsHeader(metadata: metadata, style: style, onBack: () {}),
            ),
          ),
        ),
      ),
    ),
  );
}
