import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/screens/settings/add_silo_screen.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/silo_auth_fake.dart';

Widget _testApp(Widget home) => MaterialApp(theme: monoTheme(MonoPalette.dark), home: home);

/// Bounded frames: the code panel hosts a perpetual spinner, so
/// pumpAndSettle would never settle.
Future<void> _frames(WidgetTester tester, {int count = 6}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _openCodePanel(WidgetTester tester, FakeSiloAuthServer server) async {
  resetSharedPreferencesForTest();
  await tester.pumpWidget(_testApp(AddSiloScreen(authService: server.service())));
  await tester.pump();
  await tester.enterText(find.byType(TextField).first, 'https://silo.example.com');
  await tester.testTextInput.receiveAction(TextInputAction.go);
  await _frames(tester);
  await tester.tap(find.text('Sign in with a code'));
  await _frames(tester);
}

/// Unmount so the flow withdraws its code and stops its timers.
Future<void> _leave(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _frames(tester);
}

void main() {
  testWidgets('shows the code with spoken and QR labels for screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    final server = FakeSiloAuthServer();
    await _openCodePanel(tester, server);

    expect(find.text('4821 7731'), findsOneWidget);
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.bySemanticsLabel('Sign-in code: 4 8 2 1 7 7 3 1'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Sign-in QR code\. Or go to silo\.example\.com/activate')), findsOneWidget);

    await _leave(tester);
    expect(server.bodiesFor('/api/v2/auth/device/cancel'), [contains('dev-1')]);
    semantics.dispose();
  });

  testWidgets('a declined code shows Denied and "Show a new code" starts another', (tester) async {
    final server = FakeSiloAuthServer();
    server.pollAnswer = (_) => siloJson({'status': 'denied'});
    await _openCodePanel(tester, server);

    expect(find.text('Sign-in was declined on the other device.'), findsOneWidget);
    expect(find.text('4821 7731'), findsNothing);
    expect(server.countOf('/api/v2/auth/device/start'), 1, reason: 'no silent re-mint');

    server.pollAnswer = (_) => siloJson({'status': 'pending'});
    await tester.tap(find.text('Show a new code'));
    await _frames(tester);
    expect(find.text('4821 7732'), findsOneWidget);
    expect(find.text('Waiting for approval'), findsOneWidget);

    await _leave(tester);
  });

  testWidgets('polls failing for 30 s say the server cannot be reached, keeping the code', (tester) async {
    final server = FakeSiloAuthServer();
    server.pollAnswer = (_) => http.Response('down', 503);
    await _openCodePanel(tester, server);

    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text("Can't reach silo.example.com. Check this device's connection."), findsOneWidget);
    expect(find.text('4821 7731'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await _leave(tester);
  });

  for (final size in const [Size(960, 540), Size(400, 800)]) {
    testWidgets('the struggling code panel lays out on a ${size.width.toInt()}x${size.height.toInt()} screen', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = FakeSiloAuthServer();
      server.pollAnswer = (_) => http.Response('down', 503);
      await _openCodePanel(tester, server);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('4821 7731'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _leave(tester);
    });
  }

  testWidgets('approval leads to the profiles; Change server logs the unused session out', (tester) async {
    final server = FakeSiloAuthServer();
    server.pollAnswer = (_) => FakeSiloAuthServer.approved();
    await _openCodePanel(tester, server);
    await _frames(tester);

    expect(find.text("Who's watching?"), findsOneWidget);
    expect(find.text('Kids profile'), findsOneWidget);
    expect(server.countOf('/api/v2/auth/device/cancel'), 0, reason: 'an approved code is spent, never cancelled');

    await tester.ensureVisible(find.text('Change server'));
    await tester.tap(find.text('Change server'));
    await _frames(tester);
    expect(server.countOf('/api/v2/auth/logout'), 1);
    expect(find.text('Server URL'), findsOneWidget);

    await _leave(tester);
    expect(server.countOf('/api/v2/auth/logout'), 1, reason: 'logged out once');
  });

  testWidgets('leaving at the profile step logs the session out', (tester) async {
    final server = FakeSiloAuthServer();
    server.pollAnswer = (_) => FakeSiloAuthServer.approved();
    await _openCodePanel(tester, server);
    await _frames(tester);
    expect(find.text("Who's watching?"), findsOneWidget);

    await _leave(tester);
    expect(server.countOf('/api/v2/auth/logout'), 1);
    expect(server.countOf('/api/v2/auth/device/cancel'), 0);
  });

  testWidgets('a bound profile with a PIN but no token opens at its PIN', (tester) async {
    final server = FakeSiloAuthServer();
    server.pollAnswer = (_) => FakeSiloAuthServer.approved(profileId: 'p-kids');
    await _openCodePanel(tester, server);
    await _frames(tester);

    expect(find.text("Who's watching?"), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget, reason: 'PIN entry for the bound Kids profile');

    await _leave(tester);
  });
}
