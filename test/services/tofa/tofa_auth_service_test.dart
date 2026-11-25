import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/services/tofa/tofa_api.dart';
import 'package:plezy/services/tofa/tofa_auth_service.dart';

import 'tofa_fixtures.dart';

const _server = TofaServerInfo(
  baseUrl: tofaBase,
  serverName: 'tofa.example.com',
  claimed: true,
  claimPending: false,
  serverId: 'srv-1',
  connectUrl: tofaCloud,
);

Map<String, dynamic> _code({int interval = 5, int expiresIn = 600}) => {
  'device_code': 'dc-1',
  'user_code': 'ABCD-1234',
  'verification_uri': 'https://tofa.example.com/link',
  'verification_uri_complete': 'https://tofa.example.com/link?code=ABCD-1234',
  'expires_in': expiresIn,
  'interval': interval,
};

Map<String, dynamic> _tokens() => {
  'access_token': 'acc-1',
  'refresh_token': 'ref-1',
  'token_type': 'Bearer',
  'expires_in': 2592000,
};

void main() {
  late FakeTofa fake;
  late TofaAuthService auth;
  setUp(() {
    fake = FakeTofa();
    auth = TofaAuthService(client: fake.client);
  });

  group('server probe', () {
    test('a typed host is tried over https first, then http', () {
      expect(TofaAuthService.candidateUrls('tofa.example.com:8096'), [
        'https://tofa.example.com:8096',
        'http://tofa.example.com:8096',
      ]);
      expect(TofaAuthService.candidateUrls('http://10.0.0.5:8096/'), ['http://10.0.0.5:8096']);
    });

    test('a claimed server names its id and cloud service', () async {
      fake.on('GET', '/api/v1/auth/status', (request) {
        expect(request.headers['Authorization'], isNull);
        return jsonResponse({'claimed': true, 'claim_pending': false, 'server_id': 'srv-1', 'connect_url': tofaCloud});
      });
      final info = await auth.probeServer(tofaBase);
      expect(info.canSignIn, isTrue);
      expect(info.serverId, 'srv-1');
      expect(info.connectUrl, tofaCloud);
      expect(info.serverName, 'tofa.example.com');
    });

    test('an unclaimed server, or one without an id, cannot sign in', () async {
      fake.on(
        'GET',
        '/api/v1/auth/status',
        (_) => jsonResponse({'claimed': false, 'claim_pending': true, 'server_id': null, 'connect_url': tofaCloud}),
      );
      expect((await auth.probeServer(tofaBase)).canSignIn, isFalse);
      fake.on(
        'GET',
        '/api/v1/auth/status',
        (_) => jsonResponse({'claimed': true, 'claim_pending': false, 'server_id': null, 'connect_url': tofaCloud}),
      );
      expect((await auth.probeServer(tofaBase)).canSignIn, isFalse);
    });

    test('something that is not Tofa is refused', () async {
      fake.on(
        'GET',
        '/api/v1/auth/status',
        (_) => http.Response('<html>', 200, headers: {'content-type': 'text/html'}),
      );
      await expectLater(auth.probeServer(tofaBase), throwsA(isA<MediaServerUrlException>()));
    });
  });

  group('device flow requests', () {
    test('the code is requested at the cloud for this server', () async {
      fake.on('POST', '/device/code', (request) {
        expect(request.url.toString(), '$tofaCloud/device/code');
        final body = jsonDecode(request.body) as Map;
        expect(body['server_id'], 'srv-1');
        expect(body['client_name'], 'Plezilo');
        return jsonResponse(_code());
      });
      final code = await auth.startDeviceCode(_server);
      expect(code.userCode, 'ABCD-1234');
      expect(code.verificationUriComplete, 'https://tofa.example.com/link?code=ABCD-1234');
      expect(code.interval, const Duration(seconds: 5));
      expect(code.spokenCode, 'A B C D, 1 2 3 4');
    });

    test('the poll is form-encoded, never JSON', () async {
      fake.on('POST', '/device/token', (request) {
        expect(request.headers['content-type'], startsWith('application/x-www-form-urlencoded'));
        expect(Uri.splitQueryString(request.body), {
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'device_code': 'dc-1',
        });
        return jsonResponse(_tokens());
      });
      final result = await auth.pollDeviceToken(_server, TofaDeviceCode.fromJson(_code())!);
      expect(result, isA<TofaPollApproved>().having((r) => r.tokens.refreshToken, 'refresh', 'ref-1'));
    });

    test('poll answers: pending, slow_down, refusals and transient failures', () {
      expect(TofaAuthService.parsePollResponse(400, {'error': 'authorization_pending'}), isA<TofaPollPending>());
      expect(TofaAuthService.parsePollResponse(400, {'error': 'slow_down'}), isA<TofaPollSlowDown>());
      expect(
        TofaAuthService.parsePollResponse(400, {'error': 'expired_token'}),
        isA<TofaPollRefused>().having((r) => r.error, 'error', 'expired_token'),
      );
      expect(TofaAuthService.parsePollResponse(400, {'error': 'access_denied'}), isA<TofaPollRefused>());
      expect(() => TofaAuthService.parsePollResponse(502, null), throwsA(isA<MediaServerHttpException>()));
    });
  });

  group('device flow states', () {
    test('pending, slow_down (+5 s), then approved', () async {
      final waits = <Duration>[];
      final answers = [
        tofaError(400, 'authorization_pending'),
        tofaError(400, 'slow_down'),
        tofaError(400, 'authorization_pending'),
        jsonResponse(_tokens()),
      ];
      fake.on('POST', '/device/code', (_) => jsonResponse(_code()));
      fake.on('POST', '/device/token', (_) => answers.removeAt(0));
      final flow = TofaDeviceSignIn(auth: auth, server: _server, wait: (d) async => waits.add(d));
      final statuses = <TofaDeviceSignInStatus>[];
      flow.addListener(() => statuses.add(flow.value.status));
      await flow.start();
      expect(waits, [
        const Duration(seconds: 5),
        const Duration(seconds: 5),
        const Duration(seconds: 10),
        const Duration(seconds: 10),
      ]);
      expect(flow.value.status, TofaDeviceSignInStatus.approved);
      expect(flow.value.tokens!.accessToken, 'acc-1');
      expect(statuses.first, TofaDeviceSignInStatus.waiting);
      flow.dispose();
    });

    test('the code expiring before approval ends the flow', () async {
      var now = DateTime(2026, 1, 1, 12);
      fake.on('POST', '/device/code', (_) => jsonResponse(_code(expiresIn: 12)));
      fake.on('POST', '/device/token', (_) => tofaError(400, 'authorization_pending'));
      final flow = TofaDeviceSignIn(auth: auth, server: _server, now: () => now, wait: (d) async => now = now.add(d));
      await flow.start();
      expect(flow.value.status, TofaDeviceSignInStatus.expired);
      expect(fake.to('POST', '/device/token'), hasLength(2));
      flow.dispose();
    });

    test('a refusal from the cloud ends the flow', () async {
      fake.on('POST', '/device/code', (_) => jsonResponse(_code()));
      fake.on('POST', '/device/token', (_) => tofaError(400, 'access_denied'));
      final flow = TofaDeviceSignIn(auth: auth, server: _server, wait: (_) async {});
      await flow.start();
      expect(flow.value.status, TofaDeviceSignInStatus.denied);
      flow.dispose();
    });

    test('transient poll failures keep polling and show "unreachable" after a while', () async {
      var now = DateTime(2026, 1, 1, 12);
      var calls = 0;
      fake.on('POST', '/device/code', (_) => jsonResponse(_code()));
      fake.on('POST', '/device/token', (_) => ++calls < 8 ? http.Response('busy', 503) : jsonResponse(_tokens()));
      final flow = TofaDeviceSignIn(auth: auth, server: _server, now: () => now, wait: (d) async => now = now.add(d));
      final statuses = <TofaDeviceSignInStatus>{};
      flow.addListener(() => statuses.add(flow.value.status));
      await flow.start();
      expect(statuses, contains(TofaDeviceSignInStatus.unreachable));
      expect(flow.value.status, TofaDeviceSignInStatus.approved);
      flow.dispose();
    });

    test('a code the cloud refuses to issue fails the flow', () async {
      fake.on('POST', '/device/code', (_) => jsonResponse({'error': 'server_not_found'}, 404));
      final flow = TofaDeviceSignIn(auth: auth, server: _server, wait: (_) async {});
      await flow.start();
      expect(flow.value.status, TofaDeviceSignInStatus.failed);
      flow.dispose();
    });

    test('cancelling stops the polling', () async {
      final gate = Completer<void>();
      fake.on('POST', '/device/code', (_) => jsonResponse(_code()));
      fake.on('POST', '/device/token', (_) => tofaError(400, 'authorization_pending'));
      final flow = TofaDeviceSignIn(auth: auth, server: _server, wait: (_) => gate.future);
      final run = flow.start();
      await Future<void>.delayed(Duration.zero);
      flow.cancel();
      gate.complete();
      await run;
      expect(fake.to('POST', '/device/token'), isEmpty);
      flow.dispose();
    });
  });

  group('profiles', () {
    const signIn = TofaSignIn(
      server: _server,
      tokens: TofaTokens(accessToken: 'acc-1', refreshToken: 'ref-1'),
      account: TofaAccount(id: 'u-1', username: 'laura'),
    );

    test('profiles are listed with the bearer', () async {
      fake.on('GET', '/api/v1/profiles', (request) {
        expect(request.headers['Authorization'], 'Bearer acc-1');
        return jsonResponse([
          {
            'id': 'p-1',
            'user_id': 'u-1',
            'name': 'Laura',
            'is_kids': false,
            'is_locked': false,
            'is_primary': true,
            'avatar_color': '#fff',
            'created_at': '',
            'updated_at': '',
            'record_watch_history': true,
          },
          {
            'id': 'p-2',
            'user_id': 'u-1',
            'name': 'Kids',
            'is_kids': true,
            'is_locked': true,
            'is_primary': false,
            'avatar_color': '#000',
            'created_at': '',
            'updated_at': '',
            'record_watch_history': true,
          },
        ]);
      });
      final profiles = await auth.fetchProfiles(signIn);
      expect(profiles.map((p) => p.name), ['Laura', 'Kids']);
      expect(profiles.last.isLocked, isTrue);
      expect(profiles.last.isKids, isTrue);
    });

    test('verify-pin: a token, a wrong PIN, too many tries', () async {
      var status = 200;
      fake.on('POST', '/api/v1/profiles/p-2/verify-pin', (request) {
        expect(jsonDecode(request.body), {'pin': '1234', 'remember_device': true});
        expect(request.headers['X-Profile-Id'], 'p-2');
        return status == 200
            ? jsonResponse({'profile_token': 'ptok', 'expires_at': '2026-12-01T00:00:00Z'})
            : tofaError(status, 'invalid_pin');
      });
      const kids = TofaProfile(id: 'p-2', userId: 'u-1', name: 'Kids', isLocked: true);
      final ok = await auth.verifyPin(signIn, kids, '1234');
      expect(ok, isA<TofaPinAccepted>().having((r) => r.profileToken, 'token', 'ptok'));
      status = 401;
      expect(await auth.verifyPin(signIn, kids, '1234'), isA<TofaPinWrong>());
      status = 429;
      expect(await auth.verifyPin(signIn, kids, '1234'), isA<TofaPinTooManyTries>());
    });

    test('the connection holds the account, the profile, the tokens and the cloud service', () {
      const kids = TofaProfile(id: 'p-2', userId: 'u-1', name: 'Kids', isLocked: true);
      final connection = TofaAuthService.buildConnection(
        signIn,
        kids,
        pin: TofaPinAccepted('ptok', DateTime.utc(2026, 12)),
        now: DateTime(2026, 11, 25),
      );
      expect(connection.id, 'srv-1/u-1/p-2');
      expect(connection.connectUrl, tofaCloud);
      expect(connection.profileToken, 'ptok');
      expect(connection.profileIsLocked, isTrue);
      expect(connection.userName, 'laura');
      expect(connection.refreshToken, 'ref-1');
    });
  });
}
