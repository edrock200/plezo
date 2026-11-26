import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/screens/video_player/live_channel_zapper.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/video_controls/iptv/live_channel_osd.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en'));
  final channels = [
    for (var i = 1; i <= 8; i++)
      LiveTvChannel(key: 'c$i', title: 'Channel $i', number: '${100 + i}', catchupDays: i == 1 ? 2 : 0),
  ];

  late List<int> tuned;
  late LiveChannelZapper zapper;
  late LiveChannelOsdController osd;
  late ValueNotifier<bool> controls;
  var controlsShown = 0;

  setUp(() {
    tuned = [];
    controlsShown = 0;
    zapper = LiveChannelZapper(
      channels: channels,
      currentIndex: 2,
      onZap: (i) async {
        tuned.add(i);
        return true;
      },
    );
    osd = LiveChannelOsdController(
      zapper: zapper,
      nowNext: (c) async => LiveChannelNowNext(
        nowTitle: 'Now on ${c.title}',
        nowStart: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 600,
        nowEnd: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
        nextTitle: 'Next on ${c.title}',
      ),
      onShowControls: () => controlsShown++,
    );
    controls = ValueNotifier(false);
  });

  tearDown(() {
    osd.dispose();
    zapper.dispose();
    controls.dispose();
  });

  KeyEventResult key(LogicalKeyboardKey k, {bool visible = false, bool canSeek = false}) {
    final down = osd.handleKey(
      KeyDownEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero),
      controlsVisible: visible,
      canSeek: canSeek,
    );
    osd.handleKey(
      KeyUpEvent(physicalKey: PhysicalKeyboardKey.keyA, logicalKey: k, timeStamp: Duration.zero),
      controlsVisible: visible,
      canSeek: canSeek,
    );
    return down;
  }

  test('with the controls down: Up/Down zap, OK opens the mini guide, Menu raises the controls', () async {
    expect(key(LogicalKeyboardKey.arrowUp), KeyEventResult.handled);
    await Future<void>.delayed(Duration.zero);
    expect(tuned, [3]);
    key(LogicalKeyboardKey.arrowDown);
    await Future<void>.delayed(Duration.zero);
    expect(tuned, [3, 2]);
    key(LogicalKeyboardKey.channelUp);
    key(LogicalKeyboardKey.pageDown);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(tuned, [3, 2, 3, 2]);
    expect(osd.bannerVisible, isTrue, reason: 'a zap shows the banner');
    key(LogicalKeyboardKey.contextMenu);
    expect(controlsShown, 1);
    key(LogicalKeyboardKey.select);
    expect(osd.miniGuideOpen, isTrue);
  });

  test('with the controls up the arrows and OK stay with them; digits and Channel± still zap', () async {
    expect(key(LogicalKeyboardKey.arrowUp, visible: true), KeyEventResult.ignored);
    expect(key(LogicalKeyboardKey.select, visible: true), KeyEventResult.ignored);
    expect(key(LogicalKeyboardKey.channelUp, visible: true), KeyEventResult.handled);
    expect(key(LogicalKeyboardKey.digit5, visible: true), KeyEventResult.handled);
    expect(zapper.pendingDigits, '5');
    zapper.cancelEntry();
  });

  test('Left seeks on a channel with an archive and opens the mini guide otherwise', () {
    expect(key(LogicalKeyboardKey.arrowLeft, canSeek: true), KeyEventResult.ignored);
    expect(key(LogicalKeyboardKey.arrowLeft), KeyEventResult.handled);
    expect(osd.miniGuideOpen, isTrue);
  });

  test('OK commits a number being typed; Last recalls the previous channel', () async {
    key(LogicalKeyboardKey.digit1);
    key(LogicalKeyboardKey.numpad0);
    key(LogicalKeyboardKey.digit7);
    expect(zapper.pendingDigits, '107');
    key(LogicalKeyboardKey.enter);
    await Future<void>.delayed(Duration.zero);
    expect(tuned, [6]);
    expect(osd.miniGuideOpen, isFalse);
    key(LogicalKeyboardKey.mediaLast);
    await Future<void>.delayed(Duration.zero);
    expect(tuned, [6, 2]);
  });

  Widget app() => MaterialApp(
    theme: monoTheme(MonoPalette.dark),
    home: InputModeTracker(
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: LiveChannelOsd(controller: osd, controlsVisible: controls),
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('the number overlay and the banner show what will be tuned', (tester) async {
    await tester.pumpWidget(app());
    osd.showBanner();
    await tester.pump();
    await tester.pump();
    expect(find.text('103  Channel 3'), findsOneWidget);
    expect(find.textContaining('Now on Channel 3'), findsOneWidget);
    expect(find.textContaining('Next on Channel 3'), findsOneWidget);
    await zapper.digit(1);
    await zapper.digit(0);
    await zapper.digit(5);
    await tester.pump();
    expect(find.text('105'), findsOneWidget);
    expect(find.text('Channel 5'), findsOneWidget);
    zapper.cancelEntry();
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('the mini guide focuses the current channel, moves with the D-pad, tunes on OK and closes on Back', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    osd.openMiniGuide();
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'MiniGuide:Row2');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'MiniGuide:Row3');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tuned, [3]);
    expect(osd.miniGuideOpen, isFalse);

    osd.openMiniGuide();
    await tester.pumpAndSettle();
    expect(find.text('Player controls'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(osd.miniGuideOpen, isFalse);
  });

  testWidgets('with the controls up, a touch button opens the mini guide', (tester) async {
    await tester.pumpWidget(app());
    controls.value = true;
    await tester.pump();
    await tester.tap(find.byTooltip('Channels'));
    await tester.pumpAndSettle();
    expect(osd.miniGuideOpen, isTrue);
    expect(find.text('Channel 8'), findsOneWidget);
  });
}
