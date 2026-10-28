import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/add_silo_screen.dart' show siloPinErrorMessage;
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
}
