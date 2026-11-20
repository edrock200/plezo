import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';
import 'package:plezy/widgets/video_controls/models/silo_subtitle_tools.dart';
import 'package:plezy/widgets/video_controls/models/track_controls_state.dart';
import 'package:plezy/widgets/video_controls/silo/silo_subtitle_footer.dart';

import '../test_helpers/theme.dart';

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

final _canSearch = _json({
  'state': 'available',
  'allowed': true,
  'enabled': true,
  'providers': ['opensubtitles'],
});
final _noProvider = _json({'state': 'available', 'allowed': true, 'enabled': false, 'providers': <String>[]});
final _missing = _json({'type': 'not_found', 'status': 404}, 404);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int statusReads;
  // The provider-status answer for the next read.
  late FutureOr<http.Response> Function() status;
  late bool aiOn;

  setUp(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
    statusReads = 0;
    status = () => _canSearch;
    aiOn = false;
  });

  SiloClient client() => SiloClient.forTesting(
    _connection(),
    headers: _headers,
    httpClient: MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v2/subtitles/providers/status') {
        statusReads++;
        return status();
      }
      if (path == '/api/v2/subtitles/ai/status') {
        return _json({'state': 'available', 'allowed': true, 'enabled': aiOn, 'transcribe_enabled': false});
      }
      return _json({}, 404);
    }),
  );

  SiloSubtitleTools toolsFor(SiloClient c) => SiloSubtitleTools(
    client: c,
    itemId: 'movie:m1',
    position: () => Duration.zero,
    isCurrent: () => true,
    applyStored: (_) async => SubtitleDownloadApplyOutcome.applied,
    notify: (_, {error = false}) {},
  );

  // Opens the subtitle sheet's Silo rows (a new widget, as each sheet open
  // builds one), with a row above them for D-pad focus to fall back on.
  Future<void> open(WidgetTester tester, SiloClient c, {int generation = 0}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: Scaffold(
          body: Column(
            children: [
              FocusableListTile(title: const Text('Off'), onTap: () {}),
              SiloSubtitleFooterTiles(key: ValueKey(generation), tools: toolsFor(c)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final search = find.text('Search Subtitles');
  final translate = find.text('Translate with AI');

  testWidgets('search shows only when the server can search a provider', (tester) async {
    final c = client();
    status = () => _noProvider;
    aiOn = true;
    await open(tester, c);
    expect(statusReads, 1);
    expect(search, findsNothing);
    expect(translate, findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);

    status = () => _canSearch;
    await open(tester, c, generation: 1);
    expect(statusReads, 2, reason: 'every sheet open reads the status again');
    expect(search, findsOneWidget);
  });

  testWidgets('a failed check offers search before any answer, then keeps the last answer', (tester) async {
    final c = client();
    status = () => _missing;
    await open(tester, c);
    expect(search, findsOneWidget, reason: 'older servers without the check keep search');

    status = () => _noProvider;
    await open(tester, c, generation: 1);
    expect(search, findsNothing);
    expect(find.byType(Divider), findsNothing, reason: 'no Silo rows, no divider');

    status = () => _missing;
    await open(tester, c, generation: 2);
    expect(search, findsNothing, reason: 'a failed check keeps "no provider"');

    status = () => _canSearch;
    await open(tester, c, generation: 3);
    expect(search, findsOneWidget);
  });

  testWidgets('a check that stalls past 5 s keeps the last answer', (tester) async {
    final c = client();
    status = () => _noProvider;
    await open(tester, c);
    expect(search, findsNothing);

    final stalled = Completer<http.Response>();
    status = () => stalled.future;
    await open(tester, c, generation: 1);
    await tester.pump(const Duration(seconds: 6));
    expect(search, findsNothing);
    stalled.complete(_canSearch);
    await tester.pumpAndSettle();
    expect(search, findsNothing, reason: 'the late answer belongs to a read that already timed out');
  });

  testWidgets('D-pad focus on Search moves to Translate with AI when search hides', (tester) async {
    final c = client();
    aiOn = true;
    final answer = Completer<http.Response>();
    status = () => answer.future;
    await open(tester, c);
    expect(search, findsOneWidget);

    final searchTile = tester.widget<FocusableListTile>(find.widgetWithText(FocusableListTile, 'Search Subtitles'));
    searchTile.focusNode!.requestFocus();
    await tester.pump();
    expect(searchTile.focusNode!.hasFocus, isTrue);

    answer.complete(_noProvider);
    await tester.pumpAndSettle();
    expect(search, findsNothing);
    final translateTile = tester.widget<FocusableListTile>(find.widgetWithText(FocusableListTile, 'Translate with AI'));
    expect(translateTile.focusNode!.hasFocus, isTrue);
  });

  testWidgets('D-pad focus on Search moves to the row above when no Silo row is left', (tester) async {
    final c = client();
    final answer = Completer<http.Response>();
    status = () => answer.future;
    await open(tester, c);

    final searchTile = tester.widget<FocusableListTile>(find.widgetWithText(FocusableListTile, 'Search Subtitles'));
    searchTile.focusNode!.requestFocus();
    await tester.pump();

    answer.complete(_noProvider);
    await tester.pumpAndSettle();
    expect(search, findsNothing);
    final primary = FocusManager.instance.primaryFocus;
    expect(primary, isNotNull);
    expect(
      find.ancestor(
        of: find.text('Off'),
        matching: find.byWidgetPredicate((w) => w is Focus && w.focusNode == primary),
      ),
      findsWidgets,
    );
  });
}
