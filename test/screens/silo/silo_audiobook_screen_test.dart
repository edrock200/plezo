import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/screens/silo/silo_audiobook_player_screen.dart';
import 'package:plezy/screens/silo/silo_audiobook_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/silo/silo_audiobook.dart';
import 'package:plezy/services/silo/silo_audiobook_player.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/silo_audiobook_fakes.dart';

SiloAudiobookDetail _detail({double position = 0}) => SiloAudiobookDetail.parse({
  'content_id': 'audiobook:orbit',
  'type': 'audiobook',
  'title': 'The Long Orbit',
  'versions': [
    for (var part = 1; part <= 2; part++)
      {
        'file_id': 'b$part',
        'codec_audio': 'aac',
        'duration': 300,
        'presentation_kind': 'audiobook_part',
        'presentation_part_index': part,
        'chapters': [
          {'title': 'Part $part start', 'start_seconds': 0, 'end_seconds': 150},
          {'title': 'Part $part end', 'start_seconds': 150, 'end_seconds': 300},
        ],
      },
  ],
  'user_data': {'position_seconds': position},
  'audiobook': {
    'authors': [
      {'name': 'Ava Thornton'},
    ],
    'narrators': [
      {'name': 'Ben Ode'},
    ],
  },
}, resolveUrl: (u) => u);

const _item = MediaItem.silo(
  id: 'audiobook:orbit',
  kind: MediaKind.album,
  title: 'The Long Orbit',
  serverId: 'srv-1',
  raw: {'type': 'audiobook'},
);

Widget _wrap(Widget child) => TranslationProvider(
  child: InputModeTracker(
    child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: child),
  ),
);

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('the book page shows Resume, Start over and the chapters, reachable with the D-pad', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final backend = FakeSiloAudiobookBackend(_detail(position: 400));
    await tester.pumpWidget(_wrap(SiloAudiobookScreen(item: _item, backendOverride: backend)));
    await tester.pumpAndSettle();

    expect(find.text('The Long Orbit'), findsWidgets);
    expect(find.text(t.siloAudio.byAuthors(names: 'Ava Thornton')), findsOneWidget);
    expect(find.text(t.siloAudio.narratedBy(names: 'Ben Ode')), findsOneWidget);
    expect(find.text(t.siloAudio.resumeAt(time: '6:40')), findsOneWidget);
    expect(find.text(t.siloAudio.startOver), findsOneWidget);
    expect(find.text('Part 1 start'), findsOneWidget);
    expect(find.text('Part 2 end'), findsOneWidget);

    FocusNode? focused() => FocusManager.instance.primaryFocus;
    expect(focused()?.debugLabel, 'audiobook_play');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focused()?.debugLabel, 'audiobook_start_over');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused()?.debugLabel, 'audiobook_chapter_0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focused()?.debugLabel, 'audiobook_chapter_1');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focused()?.debugLabel, 'audiobook_play');
  });

  testWidgets('a book that never played offers Play and no Start over', (tester) async {
    final backend = FakeSiloAudiobookBackend(_detail());
    await tester.pumpWidget(_wrap(SiloAudiobookScreen(item: _item, backendOverride: backend)));
    await tester.pumpAndSettle();
    expect(find.text(t.siloAudio.play), findsOneWidget);
    expect(find.text(t.siloAudio.startOver), findsNothing);
  });

  testWidgets('the player shows the chapter, plays and pauses, and says when an administrator ended it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final backend = FakeSiloAudiobookBackend(_detail(position: 400));
    final engine = FakeSiloAudiobookEngine();
    final player = SiloAudiobookPlayer(
      backend: backend,
      detail: backend.detail,
      engineFactory: () => engine,
      claimAudio: () async {},
    );
    await tester.pumpWidget(_wrap(SiloAudiobookPlayerScreen(player: player)));
    await tester.pump();
    await tester.pump();

    expect(backend.starts.single, ('b2', 100.0));
    expect(find.text('Part 2 start'), findsOneWidget);
    expect(find.text(t.siloAudio.chapterOf(n: 3, total: 4)), findsOneWidget);
    expect(player.isPlaying, isTrue);

    await tester.tap(find.byTooltip(t.siloAudio.playPause));
    await tester.pump();
    expect(player.isPlaying, isFalse);

    await tester.tap(find.byTooltip(t.siloAudio.playPause));
    await tester.pump();
    expect(player.isPlaying, isTrue);

    backend.nextProgress = const SiloAudiobookProgressAnswer(410, {'code': 'playback_session_ended'});
    await player.reportProgress();
    await tester.pump();
    expect(find.text(t.siloAudio.sessionEnded), findsOneWidget);
    expect(find.text(t.siloAudio.retry), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
