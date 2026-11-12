import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/add_silo_screen.dart'
    show siloIsTransientStatus, siloPinErrorMessage, siloSignInErrorMessage;
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_auth_service.dart';

import '../../test_helpers/silo_auth_fake.dart';

void main() {
  late FakeSiloAuthServer server;

  setUp(() => server = FakeSiloAuthServer());

  final signIn = SiloSignIn(
    server: siloTestServer,
    tokens: const SiloTokens(accessToken: 'acc', refreshToken: 'ref'),
    account: const SiloAccount(id: '1', username: 'laura'),
    deviceId: 'dev-1',
  );
  const kids = SiloProfile(id: 'p-kids', name: 'Kids', hasPin: true, isChild: true);

  group('verifyPin', () {
    test('returns the token for a valid PIN and null for a wrong one', () async {
      server.verifyPinAnswer = (pin) =>
          pin == '1234' ? siloJson({'valid': true, 'profile_token': 'pt'}) : siloJson({'valid': false});
      final auth = server.service();
      expect(await auth.verifyPin(signIn, kids, '1234'), 'pt');
      expect(await auth.verifyPin(signIn, kids, '0000'), isNull);
    });

    test('429 throws pinRateLimited', () async {
      server.verifyPinAnswer = (_) => siloProblem(429, 'Try again in 30 seconds.');
      await expectLater(
        server.service().verifyPin(signIn, kids, '1234'),
        throwsA(
          isA<SiloSignInException>()
              .having((e) => e.failure, 'failure', SiloSignInFailure.pinRateLimited)
              .having((e) => e.statusCode, 'statusCode', 429),
        ),
      );
    });

    test('another refusal throws pinRefused with the problem detail', () async {
      server.verifyPinAnswer = (_) => siloProblem(403, 'This profile is locked.');
      await expectLater(
        server.service().verifyPin(signIn, kids, '1234'),
        throwsA(
          isA<SiloSignInException>()
              .having((e) => e.failure, 'failure', SiloSignInFailure.pinRefused)
              .having((e) => e.detail, 'detail', 'This profile is locked.'),
        ),
      );
    });

    test('5xx throws an HTTP error', () async {
      server.verifyPinAnswer = (_) => http.Response('boom', 502);
      await expectLater(
        server.service().verifyPin(signIn, kids, '1234'),
        throwsA(isA<MediaServerHttpException>().having((e) => e.statusCode, 'statusCode', 502)),
      );
    });
  });

  group('siloPinErrorMessage', () {
    test('maps each failure to a message', () {
      expect(
        siloPinErrorMessage(const SiloSignInException(SiloSignInFailure.pinRateLimited, detail: 'server words')),
        t.addServer.siloTooManyPinAttempts,
      );
      expect(
        siloPinErrorMessage(const SiloSignInException(SiloSignInFailure.pinRefused, detail: 'This profile is locked.')),
        'This profile is locked.',
      );
      expect(
        siloPinErrorMessage(const SiloSignInException(SiloSignInFailure.pinRefused)),
        t.profiles.failedToVerifyPin,
      );
      expect(
        siloPinErrorMessage(MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: 500)),
        t.profiles.failedToVerifyPin,
      );
      expect(
        siloPinErrorMessage(MediaServerHttpException(type: MediaServerHttpErrorType.connectionError)),
        t.addServer.siloPinNetworkError,
      );
    });
  });

  group('pollDeviceLogin', () {
    final code = SiloDeviceCode(
      deviceCode: 'dev-1',
      userCode: '48217730',
      verificationUri: 'https://silo.example.com/activate',
      expiresAt: DateTime(2030),
      interval: const Duration(seconds: 5),
    );

    Future<SiloDevicePollStatus> statusFor(http.Response response) async {
      server.pollAnswer = (_) => response;
      return (await server.service().pollDeviceLogin(siloTestServer, code)).status;
    }

    test('maps the server statuses', () async {
      expect(await statusFor(siloJson({'status': 'pending'})), SiloDevicePollStatus.pending);
      expect(await statusFor(FakeSiloAuthServer.approved()), SiloDevicePollStatus.approved);
      expect(await statusFor(siloJson({'status': 'denied'})), SiloDevicePollStatus.denied);
      expect(await statusFor(siloJson({'status': 'expired'})), SiloDevicePollStatus.gone);
      expect(await statusFor(siloJson({'status': 'consumed'})), SiloDevicePollStatus.gone);
      expect(await statusFor(siloJson({'status': 'canceled'})), SiloDevicePollStatus.gone);
      expect(await statusFor(http.Response('', 404)), SiloDevicePollStatus.gone);
      expect(await statusFor(siloJson({'status': 'approved'})), SiloDevicePollStatus.failed, reason: 'no tokens');
      expect(await statusFor(siloJson({'status': 'mystery'})), SiloDevicePollStatus.failed);
    });

    test('429 and 5xx throw so the caller backs off', () async {
      server.pollAnswer = (_) => http.Response('', 429);
      await expectLater(
        server.service().pollDeviceLogin(siloTestServer, code),
        throwsA(isA<MediaServerHttpException>()),
      );
    });
  });

  group('session binding (Silo Android #810)', () {
    final code = SiloDeviceCode(
      deviceCode: 'dev-1',
      userCode: '48217730',
      verificationUri: 'https://silo.example.com/activate',
      expiresAt: DateTime(2030),
      interval: const Duration(seconds: 5),
    );
    final binding = SiloDeviceLoginBinding.of(List.generate(32, (i) => i));

    test('the binding is the unpadded base64url SHA-256 of the 32-byte secret', () {
      // silo-android PairingSessionBindingTest's secret (bytes 0..31).
      expect(binding.secret, 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8');
      expect(binding.binding, 'Yw3NKWbEM2aRElRIu7JbT_QSpJxzLbLIq8G4WBvXEN0');
      expect(binding.toString(), isNot(contains(binding.secret)));
      expect(() => SiloDeviceLoginBinding.of(const [1, 2, 3]), throwsArgumentError);
      final fresh = SiloDeviceLoginBinding.generate();
      expect(fresh.secret, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(fresh.secret, isNot(SiloDeviceLoginBinding.generate().secret));
    });

    test('it goes only to an https server whose capability says session_binding', () {
      const https = SiloServerInfo(baseUrl: 'https://s.example', serverId: 's', serverName: 'S');
      const httpsBound = SiloServerInfo(
        baseUrl: 'https://s.example',
        serverId: 's',
        serverName: 'S',
        deviceSessionBinding: true,
      );
      const plainBound = SiloServerInfo(
        baseUrl: 'http://192.168.1.5:8090',
        serverId: 's',
        serverName: 'S',
        deviceSessionBinding: true,
      );
      expect(siloSessionBindingFor(httpsBound, binding), same(binding));
      expect(siloSessionBindingFor(https, binding), isNull);
      expect(siloSessionBindingFor(plainBound, binding), isNull);
      expect(siloSessionBindingFor(httpsBound, null), isNull);
    });

    test('the probe reads session_binding from the device capability', () async {
      expect((await server.service().probe('https://silo.example.com')).deviceSessionBinding, isFalse);
      server.sessionBinding = true;
      expect((await server.service().probe('https://silo.example.com')).deviceSessionBinding, isTrue);
    });

    test('start sends binding and poll binding_secret only when given', () async {
      final auth = server.service();
      await auth.startDeviceLogin(siloTestServer);
      await auth.startDeviceLogin(siloTestServer, binding: binding);
      await auth.pollDeviceLogin(siloTestServer, code);
      await auth.pollDeviceLogin(siloTestServer, code, binding: binding);
      final starts = [for (final b in server.bodiesFor('/api/v2/auth/device/start')) jsonDecode(b) as Map];
      final polls = [for (final b in server.bodiesFor('/api/v2/auth/device/poll')) jsonDecode(b) as Map];
      expect(starts.first.containsKey('binding'), isFalse);
      expect(starts.last['binding'], binding.binding);
      expect(polls.first.containsKey('binding_secret'), isFalse);
      expect(polls.last['binding_secret'], binding.secret);
    });

    test('a 403 device_binding_mismatch poll is bindingRefused', () async {
      server.pollAnswer = (_) => siloCodedProblem(403, 'device_binding_mismatch');
      final result = await server.service().pollDeviceLogin(siloTestServer, code, binding: binding);
      expect(result.status, SiloDevicePollStatus.bindingRefused);
    });
  });

  test('the spoken code is read one character at a time', () {
    final code = SiloDeviceCode(
      deviceCode: 'd',
      userCode: '4821-7730',
      verificationUri: 'u',
      expiresAt: DateTime(2030),
      interval: const Duration(seconds: 5),
    );
    expect(code.spokenCode, '4 8 2 1 7 7 3 0');
    expect(code.displayCode, '4821 7730');
  });

  test('probe reads info, identity and the optional routes; a non-Silo answer is typed', () async {
    final info = await server.service().probe('https://silo.example.com');
    expect(info.serverName, 'Home Silo');
    expect(info.deviceLoginAvailable, isTrue);
    expect(info.passwordLoginAvailable, isTrue);

    final notSilo = SiloAuthService(
      deviceId: 'dev-1',
      headers: siloTestHeaders,
      clientFactory: () => MockClient((_) async => siloJson({'name': 'something else'})),
    );
    await expectLater(
      notSilo.probe('https://other.example.com'),
      throwsA(isA<SiloSignInException>().having((e) => e.failure, 'failure', SiloSignInFailure.notSiloServer)),
    );
  });

  test('logout posts to /auth/logout with the session token', () async {
    await server.service().logout(siloTestServer, const SiloTokens(accessToken: 'acc', refreshToken: 'ref'));
    final logout = server.requests.singleWhere((r) => r.url.path == '/api/v2/auth/logout');
    expect(logout.method, 'POST');
    expect(logout.headers['Authorization'] ?? logout.headers['authorization'], 'Bearer acc');
  });

  group('a refresh during a sign-in step is kept (the old refresh token is spent)', () {
    // The access token is in its last minute, so the next call refreshes first.
    SiloSignIn expiring() => SiloSignIn(
      server: siloTestServer,
      tokens: SiloTokens(
        accessToken: 'acc',
        refreshToken: 'ref',
        expiresAt: DateTime.now().add(const Duration(seconds: 10)),
        lifetimeSeconds: 3600,
      ),
      account: const SiloAccount(id: '1', username: 'laura'),
      deviceId: 'dev-1',
    );
    String? bearer(http.Request r) => r.headers['Authorization'] ?? r.headers['authorization'];

    test('fetchProfiles writes the rotated pair back, and the saved connection and PIN check use it', () async {
      final auth = server.service();
      final signIn = expiring();
      await auth.fetchProfiles(signIn);
      expect(signIn.tokens.accessToken, 'acc-1');
      expect(signIn.tokens.refreshToken, 'ref-1');

      server.verifyPinAnswer = (_) => siloJson({'valid': true, 'profile_token': 'pt'});
      expect(await auth.verifyPin(signIn, kids, '1234'), 'pt');
      final pinCheck = server.requests.lastWhere((r) => r.url.path.endsWith('/verify-pin'));
      expect(bearer(pinCheck), 'Bearer acc-1');
      expect(server.requests.where((r) => r.url.path == '/api/v2/auth/refresh'), hasLength(1));

      final connection = auth.buildConnection(signIn, kids, profileToken: 'pt');
      expect(connection.refreshToken, 'ref-1');
      expect(connection.accessToken, 'acc-1');
    });

    test('verifyPin writes the rotated pair back', () async {
      final signIn = expiring();
      server.verifyPinAnswer = (_) => siloJson({'valid': false});
      await server.service().verifyPin(signIn, kids, '0000');
      expect(signIn.tokens.refreshToken, 'ref-1');
    });

    test('the temporary-password session writes the rotated pair back and reports it', () async {
      final signIn = expiring();
      final reported = <SiloTokens>[];
      final session = await server.service().temporaryPasswordSession(signIn, onTokensRefreshed: reported.add);
      addTearDown(session.close);
      expect(await session.refreshSessionAfterPasswordChange(), isTrue);
      expect(signIn.tokens.refreshToken, 'ref-1');
      expect(reported.single.refreshToken, 'ref-1');
    });

    test('completeDeviceLogin keeps a pair rotated while reading account/me', () async {
      final result = SiloDevicePollResult(
        status: SiloDevicePollStatus.approved,
        tokens: SiloTokens(
          accessToken: 'acc',
          refreshToken: 'ref',
          expiresAt: DateTime.now().add(const Duration(seconds: 10)),
          lifetimeSeconds: 3600,
        ),
      );
      final signIn = await server.service().completeDeviceLogin(siloTestServer, result);
      expect(signIn.account.username, 'laura');
      expect(signIn.tokens.accessToken, 'acc-1');
      expect(signIn.tokens.refreshToken, 'ref-1');
    });
  });

  group('sign-in error messages', () {
    test('5xx, 408 and 429 are a busy server, not "no Silo server here"', () {
      for (final status in [500, 502, 503, 504, 408, 429]) {
        expect(siloIsTransientStatus(status), isTrue, reason: '$status');
        expect(
          siloSignInErrorMessage(MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: status)),
          t.addServer.siloServerBusy,
        );
      }
      for (final status in [400, 401, 403, 404, 422]) {
        expect(siloIsTransientStatus(status), isFalse, reason: '$status');
      }
    });

    test('other failures show a localized reason, never the exception text', () {
      final message = siloSignInErrorMessage(
        MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'SocketException: refused'),
      );
      expect(message, t.addServer.signInFailed(error: t.errors.reasonUnreachable));
      expect(message, isNot(contains('MediaServerHttpException')));
      expect(message, isNot(contains('SocketException')));
      expect(siloSignInErrorMessage(StateError('db')), t.addServer.signInFailed(error: t.errors.reasonUnexpected));
    });

    test('probe reports the first candidate where something answered, else the https one', () {
      final httpsDown = MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'https');
      final httpDown = MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'http');
      final busy = MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: 502);
      expect(SiloAuthService.probeErrorToReport([httpsDown, httpDown]), same(httpsDown));
      expect(SiloAuthService.probeErrorToReport([busy, httpDown, httpDown]), same(busy));
      expect(SiloAuthService.probeErrorToReport([httpsDown, busy, httpDown]), same(busy));
      expect(SiloAuthService.probeErrorToReport(const []), isNull);
    });

    test('a proxy answering 502 over https is reported as busy, not hidden by the plain-HTTP fallbacks', () async {
      final auth = SiloAuthService(
        deviceId: 'dev-1',
        headers: siloTestHeaders,
        clientFactory: () => MockClient((request) async {
          if (request.url.scheme == 'https') return http.Response('Bad Gateway', 502);
          throw http.ClientException('Connection refused', request.url);
        }),
      );
      await expectLater(
        auth.probe('silo.example.com'),
        throwsA(isA<MediaServerHttpException>().having((e) => e.statusCode, 'statusCode', 502)),
      );
    });
  });
}
