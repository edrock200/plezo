import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/screens/settings/add_silo_screen.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_host.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_protocol.dart';
import 'package:plezy/utils/device_identity.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/silo_auth_fake.dart';
import '../../test_helpers/silo_pairing_phone.dart';

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

  group('temporary password (Silo Android #790)', () {
    FakeSiloAuthServer temporary() {
      final server = FakeSiloAuthServer()
        ..temporaryPassword = true
        ..restrictedTokens.add('acc');
      server.pollAnswer = (_) => FakeSiloAuthServer.approved();
      return server;
    }

    Finder field(String label) => find.widgetWithText(TextField, label);

    testWidgets('a phone chooses a new password, then reaches the profiles', (tester) async {
      final server = temporary();
      await _openCodePanel(tester, server);
      await _frames(tester);

      expect(find.text('Choose a new password'), findsOneWidget);
      expect(find.text('An admin set a temporary password for laura. Choose your own to continue.'), findsOneWidget);
      expect(find.text('At least 10 characters'), findsOneWidget, reason: "the server's minimum");
      expect(find.text("Who's watching?"), findsNothing);

      await tester.enterText(field('Temporary password'), 'temp-pass');
      await tester.enterText(field('New password'), 'a-new-password');
      await tester.enterText(field('Confirm new password'), 'a-new-password');
      await tester.ensureVisible(find.text('Save password'));
      await tester.tap(find.text('Save password'));
      await _frames(tester);

      expect(find.text("Who's watching?"), findsOneWidget);
      final change = server.requests.singleWhere((r) => r.url.path == '/api/v2/account/password');
      expect(change.headers.containsKey('X-Profile-Id'), isFalse);
      expect(server.countOf('/api/v2/auth/refresh'), 1);
      final profileReads = server.requests.where((r) => r.url.path == '/api/v2/profiles').toList();
      expect(profileReads.last.headers['Authorization'], 'Bearer acc-1');

      await _leave(tester);
      final logout = server.requests.singleWhere((r) => r.url.path == '/api/v2/auth/logout');
      expect(logout.headers['Authorization'], 'Bearer acc-1', reason: 'the live session is the one logged out');
    });

    testWidgets('a wrong temporary password stays on the form', (tester) async {
      final server = temporary();
      await _openCodePanel(tester, server);
      await _frames(tester);

      await tester.enterText(field('Temporary password'), 'wrong');
      await tester.enterText(field('New password'), 'a-new-password');
      await tester.enterText(field('Confirm new password'), 'a-new-password');
      await tester.ensureVisible(find.text('Save password'));
      await tester.tap(find.text('Save password'));
      await _frames(tester);

      expect(find.text('That temporary password is incorrect.'), findsOneWidget);
      expect(find.text('Choose a new password'), findsOneWidget);
      expect(server.countOf('/api/v2/auth/refresh'), 0);

      await tester.ensureVisible(find.text('Sign out'));
      await tester.tap(find.text('Sign out'));
      await _frames(tester);
      expect(server.countOf('/api/v2/auth/logout'), 1);
      expect(find.text('Sign in with a code'), findsOneWidget);
      await _leave(tester);
    });

    testWidgets('a TV says where to change it, with Sign out focused', (tester) async {
      addTearDown(() => TvDetectionService.debugSetAppleTVOverride(null));
      final server = temporary();
      server.pollAnswer = (_) => siloJson({'status': 'pending', 'opened': false});
      await _openCodePanel(tester, server);
      TvDetectionService.debugSetAppleTVOverride(true);
      server.pollAnswer = (_) => FakeSiloAuthServer.approved();
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await _frames(tester);

      expect(
        find.text(
          "Your password needs to be reset. Use Silo's mobile app or website to set a new one, then sign in again.",
        ),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'Temporary password'), findsNothing);
      final focused = FocusManager.instance.primaryFocus;
      expect(focused?.debugLabel, 'AddSilo:TvSignOut');

      await tester.tap(find.text('Sign out'));
      await _frames(tester);
      expect(server.countOf('/api/v2/auth/logout'), 1);
      expect(server.countOf('/api/v2/account/password'), 0);
      await _leave(tester);
    });
  });

  group('sign in from a phone', () {
    tearDown(() => DeviceIdentityService.debugOverride(null));

    Future<SiloPairingHost> openWithPairing(WidgetTester tester, FakeSiloAuthServer server) async {
      resetSharedPreferencesForTest();
      // Inside the test's zone, so the screen's await completes under fake time.
      DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'Android', deviceName: 'Den TV'));
      SiloPairingHost? host;
      await tester.pumpWidget(
        _testApp(
          AddSiloScreen(
            authService: server.service(),
            phoneSignIn: true,
            pairingAdvertiser: FakePairingAdvertiser(),
            onPairingHost: (h) => host = h,
          ),
        ),
      );
      await _frames(tester);
      expect(host, isNotNull);
      return host!;
    }

    testWidgets('a phone pushes the server, the TV allows it and signs in with the device code', (tester) async {
      final server = FakeSiloAuthServer();
      final host = await openWithPairing(tester, server);
      expect(find.text('Sign in with your phone'), findsOneWidget);

      final phone = FakePairingTransport();
      unawaited(host.receiver.run(phone));
      await _frames(tester, count: 2);
      final hello = phone.sent.first as SiloPairingHello;
      expect(hello.tvName, 'Den TV');
      expect(hello.state, SiloPairingReceiverState.setup);

      phone.phoneSends(
        const SiloPairingPushServer(serverUrl: 'https://silo.example.com', serverName: 'Home', serverIdentity: 'srv-1'),
      );
      await _frames(tester, count: 2);
      expect(find.text('Allow this setup?'), findsOneWidget);
      expect(find.text('A nearby phone or tablet wants to sign Plezilo in to Home.'), findsOneWidget);
      expect(server.countOf('/api/v2/auth/device/start'), 0, reason: 'nothing starts before Allow');

      await tester.tap(find.text('Allow'));
      await _frames(tester);
      expect(find.text('4821 7731'), findsOneWidget);
      expect(find.text('Check that your phone or tablet shows this code, then approve it there.'), findsOneWidget);
      final started = phone.sent.whereType<SiloPairingDeviceStarted>().single;
      expect(started.userCode, '48217731');
      expect(started.matchCode, 'brave-otter-1');
      expect(started.serverUrl, 'https://silo.example.com');

      // The phone approves on the server; the next poll collects the tokens.
      server.pollAnswer = (_) => FakeSiloAuthServer.approved();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(find.text("Who's watching?"), findsOneWidget);
      final result = phone.sent.whereType<SiloPairingServerResult>().single;
      expect(result.status, SiloPairingServerStatus.signedIn);

      phone.phoneSends(const SiloPairingDone());
      await _frames(tester, count: 2);
      // The session's teardown finishes outside fake time.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await _frames(tester, count: 2);
      expect(phone.closed, isTrue);
      expect(find.text("Who's watching?"), findsOneWidget);
      await _leave(tester);
    });

    testWidgets("Don't allow tells the phone and keeps the address form", (tester) async {
      final server = FakeSiloAuthServer();
      final host = await openWithPairing(tester, server);
      final phone = FakePairingTransport();
      unawaited(host.receiver.run(phone));
      await _frames(tester, count: 2);
      phone.phoneSends(const SiloPairingPushServer(serverUrl: 'http://192.168.1.5:8090', serverName: 'NAS'));
      await _frames(tester, count: 2);
      expect(
        find.text('The connection to NAS is not encrypted. Only allow this on a network you trust.'),
        findsOneWidget,
      );
      await tester.tap(find.text("Don't allow"));
      await _frames(tester, count: 2);
      expect((phone.sent.last as SiloPairingCancel).reason, 'consent_denied');
      expect(find.text('Allow this setup?'), findsNothing);
      expect(find.text('Find server'), findsOneWidget);
      expect(server.countOf('/api/v2/auth/device/start'), 0);
      await _leave(tester);
    });

    testWidgets('a phone that leaves mid-approval takes its code with it', (tester) async {
      final server = FakeSiloAuthServer();
      final host = await openWithPairing(tester, server);
      final phone = FakePairingTransport();
      unawaited(host.receiver.run(phone));
      await _frames(tester, count: 2);
      phone.phoneSends(
        const SiloPairingPushServer(serverUrl: 'https://silo.example.com', serverName: 'Home', serverIdentity: 'srv-1'),
      );
      await _frames(tester, count: 2);
      await tester.tap(find.text('Allow'));
      await _frames(tester);
      expect(find.text('4821 7731'), findsOneWidget);

      phone.phoneSends(const SiloPairingCancel('user-cancelled'));
      await _frames(tester);
      expect(find.text('4821 7731'), findsNothing);
      expect(find.text('Find server'), findsOneWidget);
      expect(server.bodiesFor('/api/v2/auth/device/cancel'), [contains('dev-1')]);
      await _leave(tester);
    });

    testWidgets('another server at the pushed address is refused and explained', (tester) async {
      final server = FakeSiloAuthServer();
      server.identityAnswer = () => siloJson({'server_id': 'someone-else'});
      final host = await openWithPairing(tester, server);
      final phone = FakePairingTransport();
      unawaited(host.receiver.run(phone));
      await _frames(tester, count: 2);
      phone.phoneSends(
        const SiloPairingPushServer(serverUrl: 'https://silo.example.com', serverName: 'Home', serverIdentity: 'srv-1'),
      );
      await _frames(tester, count: 2);
      await tester.tap(find.text('Allow'));
      await _frames(tester);
      expect(find.text("Setup didn't finish"), findsOneWidget);
      expect((phone.sent.last as SiloPairingServerResult).error, 'identity_mismatch');
      await tester.tap(find.text('OK'));
      await _frames(tester, count: 2);
      expect(find.text('Find server'), findsOneWidget);
      await _leave(tester);
    });
  });
}
