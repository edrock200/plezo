import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/profile/pin_entry_dialog.dart';
import 'package:plezy/screens/settings/add_tofa_screen.dart';
import 'package:plezy/services/tofa/tofa_auth_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/tofa/tofa_fixtures.dart';
import '../../test_helpers/prefs.dart';

Widget _app(Widget home) => MaterialApp(theme: monoTheme(MonoPalette.dark), home: home);

/// Bounded frames: the code panel can hold a spinner.
Future<void> _frames(WidgetTester tester, {int count = 6}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Map<String, dynamic> _profile(String id, String name, {bool locked = false}) => {
  'id': id,
  'user_id': 'u-1',
  'name': name,
  'is_kids': false,
  'is_locked': locked,
  'is_primary': id == 'p-1',
  'avatar_color': '#336699',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-01T00:00:00Z',
  'record_watch_history': true,
};

void main() {
  late FakeTofa fake;
  late StreamController<void> polls;

  setUp(() {
    resetSharedPreferencesForTest();
    fake = FakeTofa();
    polls = StreamController<void>.broadcast();
    fake.on(
      'GET',
      '/api/v1/auth/status',
      (_) => jsonResponse({'claimed': true, 'claim_pending': false, 'server_id': 'srv-1', 'connect_url': tofaCloud}),
    );
    fake.on(
      'POST',
      '/device/code',
      (_) => jsonResponse({
        'device_code': 'dc-1',
        'user_code': 'WXYZ-9876',
        'verification_uri': 'https://link.example.com/device',
        'verification_uri_complete': 'https://link.example.com/device?code=WXYZ-9876',
        'expires_in': 600,
        'interval': 5,
      }),
    );
    fake.on('POST', '/device/token', (_) => tofaError(400, 'authorization_pending'));
    fake.on(
      'GET',
      '/api/v1/users/me',
      (_) => jsonResponse({'id': 'u-1', 'username': 'laura', 'disabled': false, 'preferences': {}}),
    );
    fake.on(
      'GET',
      '/api/v1/profiles',
      (_) => jsonResponse([_profile('p-1', 'Laura'), _profile('p-2', 'Kids', locked: true)]),
    );
  });

  tearDown(() => polls.close());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        AddTofaScreen(
          authService: TofaAuthService(client: fake.client),
          pollWait: (_) => polls.stream.first.catchError((_) {}),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> findServer(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).first, tofaBase);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await _frames(tester);
  }

  Future<void> approve(WidgetTester tester) async {
    fake.on(
      'POST',
      '/device/token',
      (_) => jsonResponse({
        'access_token': 'acc-1',
        'refresh_token': 'ref-1',
        'token_type': 'Bearer',
        'expires_in': 2592000,
      }),
    );
    polls.add(null);
    await _frames(tester, count: 10);
  }

  testWidgets('the address goes to the device code: the code, the link and a QR code of the full link', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    expect(find.text('Add Tofa server'), findsOneWidget);
    await findServer(tester);

    expect(find.text('WXYZ-9876'), findsOneWidget);
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.textContaining('link.example.com/device'), findsOneWidget);
    expect(tester.widget<QrImageView>(find.byType(QrImageView)), isNotNull);
    expect(find.bySemanticsLabel('Sign-in code: W X Y Z, 9 8 7 6'), findsOneWidget);
    expect(fake.to('POST', '/device/code'), hasLength(1));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unclaimed server says so and offers no code', (tester) async {
    fake.on(
      'GET',
      '/api/v1/auth/status',
      (_) => jsonResponse({'claimed': false, 'claim_pending': false, 'server_id': null, 'connect_url': tofaCloud}),
    );
    await open(tester);
    await findServer(tester);
    expect(find.textContaining("isn't set up for sign-in yet"), findsOneWidget);
    expect(fake.to('POST', '/device/code'), isEmpty);
  });

  testWidgets('an address with no Tofa server says so', (tester) async {
    fake.on('GET', '/api/v1/auth/status', (_) => tofaError(404, 'not_found'));
    await open(tester);
    await findServer(tester);
    expect(find.text('No Tofa server answered at this address.'), findsOneWidget);
  });

  testWidgets('approval lists the profiles; a locked one asks for its PIN', (tester) async {
    await open(tester);
    await findServer(tester);
    await approve(tester);

    expect(find.text("Who's watching?"), findsOneWidget);
    expect(find.text('Laura'), findsOneWidget);
    expect(find.text('Kids'), findsOneWidget);
    expect(fake.to('GET', '/api/v1/profiles').single.headers['Authorization'], 'Bearer acc-1');

    await tester.tap(find.text('Kids'));
    await _frames(tester);
    expect(find.byType(PinEntryDialog), findsOneWidget);
  });

  testWidgets('an expired code offers a new one', (tester) async {
    fake.on('POST', '/device/token', (_) => tofaError(400, 'expired_token'));
    await open(tester);
    await findServer(tester);
    polls.add(null);
    await _frames(tester);
    expect(find.text('The code expired before it was used.'), findsOneWidget);
    fake.on('POST', '/device/token', (_) => tofaError(400, 'authorization_pending'));
    await tester.tap(find.text('Show a new code'));
    await _frames(tester);
    expect(find.text('WXYZ-9876'), findsOneWidget);
    expect(fake.to('POST', '/device/code'), hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Change server goes back to the address with the D-pad', (tester) async {
    await open(tester);
    await findServer(tester);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'AddTofa:CodeChangeServer');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _frames(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'AddTofa:Url');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'AddTofa:FindServer');
  });

  testWidgets('account-first: the account\'s servers, pick one, then its profiles', (tester) async {
    fake.on(
      'GET',
      '/servers',
      (_) => jsonResponse({
        'items': [
          {
            'id': 'srv-1',
            'name': 'Home server',
            'online': true,
            'role': 'owner',
            'connect_url': tofaBase,
            'connection_type': 'direct',
            'libraries': <String>[],
            'library_ids': <String>[],
          },
        ],
        'limit': 100,
        'offset': 0,
        'total': 1,
      }),
    );
    fake.on(
      'POST',
      '/servers/srv-1/server-session',
      (_) => jsonResponse({
        'access_token': 'srv-acc',
        'refresh_token': 'srv-ref',
        'token_type': 'Bearer',
        'expires_in': 2592000,
      }),
    );
    await tester.pumpWidget(
      _app(
        AddTofaScreen(
          authService: TofaAuthService(client: fake.client),
          pollWait: (_) => polls.stream.first.catchError((_) {}),
          cloudUrl: tofaCloud,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Sign in with your Tofa account'));
    await _frames(tester);
    expect(find.text('WXYZ-9876'), findsOneWidget);
    expect((jsonDecode(fake.to('POST', '/device/code').single.body) as Map).containsKey('server_id'), isFalse);
    await approve(tester);

    expect(find.text('Choose a server'), findsOneWidget);
    expect(find.text('Home server'), findsOneWidget);
    await tester.tap(find.text('Home server'));
    await _frames(tester, count: 10);
    expect(find.text("Who's watching?"), findsOneWidget);
    expect(fake.to('GET', '/api/v1/profiles').single.headers['Authorization'], 'Bearer srv-acc');
  });
}
