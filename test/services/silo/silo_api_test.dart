import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_auth_service.dart';

SiloDeviceHeaders _headers(String family) =>
    SiloDeviceHeaders(deviceId: 'd', deviceName: 'n', platform: 'android', clientFamily: family, clientVersion: '1');

void main() {
  group('server address candidates', () {
    test('a bare host tries https, http, then Silo\'s default port', () {
      expect(SiloAuthService.candidatesFor('Silo.Local'), [
        'https://silo.local',
        'http://silo.local',
        'http://silo.local:8090',
      ]);
    });

    test('an explicit port or scheme is kept as typed', () {
      expect(SiloAuthService.candidatesFor('silo.local:9000/prefix/'), [
        'https://silo.local:9000/prefix',
        'http://silo.local:9000/prefix',
      ]);
      expect(SiloAuthService.candidatesFor('http://10.0.0.5:8090'), ['http://10.0.0.5:8090']);
    });
  });

  test('plain HTTP is recognised for the sign-in warning', () {
    expect(siloUsesPlainHttp('http://silo.local:8090'), isTrue);
    expect(siloUsesPlainHttp('HTTP://silo.local'), isTrue);
    expect(siloUsesPlainHttp('https://silo.local'), isFalse);
    expect(siloHostLabel('http://silo.local:8090/base'), 'silo.local:8090');
    expect(siloHostLabel('https://silo.local/base'), 'silo.local');
  });

  group('form factor', () {
    test('tablets report their own client family but play as mobile', () {
      expect(_headers('tablet').toHeaders()['X-Silo-Client-Family'], 'tablet');
      expect(_headers('tablet').formFactor.playbackFormFactor, 'mobile');
      expect(_headers('mobile').formFactor.playbackFormFactor, 'mobile');
      expect(_headers('tv').formFactor.playbackFormFactor, 'tv');
      expect(_headers('desktop').formFactor.playbackFormFactor, 'desktop');
    });
  });

  test('problem codes come from the last segment of the type URI', () {
    expect(siloProblemCode({'type': 'https://siloserver.org/docs/api/v2/problems/session_expired'}), 'session_expired');
    expect(siloProblemCode('not json'), isNull);
  });

  test('phone or tablet follows the 600 dp shortest side', () {
    expect(SiloFormFactor.classify(const Size(400, 800)), SiloFormFactor.mobile);
    expect(SiloFormFactor.classify(const Size(1280, 800)), SiloFormFactor.tablet);
  });

  test('only a 400 or 401 with Silo\'s problem body refuses a refresh', () {
    final problem = {'type': 'https://siloserver.org/docs/api/v2/problems/session_expired'};
    expect(SiloApi.isRefreshRefusal(401, problem), isTrue);
    expect(SiloApi.isRefreshRefusal(400, problem), isTrue);
    expect(SiloApi.isRefreshRefusal(401, '<html>proxy login</html>'), isFalse);
    expect(SiloApi.isRefreshRefusal(403, problem), isFalse);
    expect(SiloApi.isRefreshRefusal(502, problem), isFalse);
  });

  test('a token with most of its persisted lifetime left is not rotated before playback', () async {
    var refreshes = 0;
    SiloApi api(int? lifetime) => SiloApi(
      baseUrl: 'https://silo.example.com',
      device: _headers('desktop'),
      tokens: SiloTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
        lifetimeSeconds: lifetime,
      ),
      client: MockClient((request) async {
        refreshes++;
        return http.Response('{}', 500, headers: {'content-type': 'application/json'});
      }),
    );
    await api(900).refreshTokensIfHalfSpent();
    expect(refreshes, 0);
    // Unknown lifetime is taken as an hour: ten minutes left is less than half.
    await api(null).refreshTokensIfHalfSpent();
    expect(refreshes, 1);
  });

  group('DELETE with a body (playback stop)', () {
    SiloApi api(List<http.Request> sent) => SiloApi(
      baseUrl: 'https://silo.example.com',
      device: _headers('desktop'),
      tokens: const SiloTokens(accessToken: 'a', refreshToken: 'r'),
      client: MockClient((request) async {
        sent.add(request);
        return http.Response('{"outcome":"stopped"}', 200, headers: {'content-type': 'application/json'});
      }),
    );

    test('sends the JSON body through the shared client', () async {
      final sent = <http.Request>[];
      final response = await api(sent).request('DELETE', '/api/v2/playback/s1', body: {'position_ms': 5});
      expect(response.statusCode, 200);
      expect((response.data as Map)['outcome'], 'stopped');
      expect(sent.single.method, 'DELETE');
      expect(sent.single.body, '{"position_ms":5}');
      expect(sent.single.headers['content-type'], startsWith('application/json'));
      expect(sent.single.headers['Authorization'], 'Bearer a');
    });

    test('is refused once the client is closing, like every other request', () async {
      final sent = <http.Request>[];
      final a = api(sent);
      a.close();
      await expectLater(
        a.request('DELETE', '/api/v2/playback/s1', body: {'position_ms': 5}),
        throwsA(isA<Exception>()),
      );
      expect(sent, isEmpty);
    });
  });
}
