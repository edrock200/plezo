import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_stream_auth.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection({DateTime? expiresAt, int? lifetime}) => SiloConnection(
  id: 'srv-1/1/p-owner',
  baseUrl: 'https://silo.example.com',
  serverName: 'Home Silo',
  serverId: 'srv-1',
  userId: '1',
  userName: 'laura',
  accessToken: 'acc-1',
  refreshToken: 'ref-1',
  accessTokenExpiresAt: expiresAt,
  accessTokenLifetimeSeconds: lifetime,
  deviceId: 'dev-1',
  profileId: 'p-owner',
  profileName: 'Laura',
  createdAt: DateTime(2026),
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  group('delayFor', () {
    final now = DateTime(2026, 11, 12, 20);

    test('waits until half of the token life is spent', () {
      final tokens = SiloTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: now.add(const Duration(minutes: 60)),
        lifetimeSeconds: 3600,
      );
      expect(SiloStreamAuth.delayFor(tokens, now), const Duration(minutes: 30, seconds: 1));
    });

    test('a token already half spent is checked soon, never at once', () {
      final tokens = SiloTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: now.add(const Duration(minutes: 5)),
        lifetimeSeconds: 3600,
      );
      expect(SiloStreamAuth.delayFor(tokens, now), SiloStreamAuth.minDelay);
    });

    test('an unknown expiry plans nothing', () {
      expect(SiloStreamAuth.delayFor(const SiloTokens(accessToken: 'a', refreshToken: 'r'), now), isNull);
      expect(SiloStreamAuth.delayFor(null, now), isNull);
    });
  });

  group('client', () {
    late int refreshes;

    SiloClient build({required DateTime expiresAt, bool failRefresh = false}) {
      refreshes = 0;
      return SiloClient.forTesting(
        _connection(expiresAt: expiresAt, lifetime: 3600),
        headers: _headers,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            refreshes++;
            if (failRefresh) return http.Response('busy', 503);
            return _json({
              'access_token': 'acc-${refreshes + 1}',
              'refresh_token': 'ref-${refreshes + 1}',
              'expires_in': 3600,
            });
          }
          return _json({}, 404);
        }),
      );
    }

    test('a held stream gets the refreshed Authorization header at half life', () {
      fakeAsync((async) {
        // Ten minutes left of an hour: the first check refreshes.
        final client = build(expiresAt: DateTime.now().add(const Duration(minutes: 10)));
        final pushed = <Map<String, String>>[];
        final release = client.streamAuth.hold(pushed.add);
        expect(client.streamAuth.isScheduled, isTrue);

        async.elapse(SiloStreamAuth.minDelay);
        expect(refreshes, 1);
        expect(pushed.single['Authorization'], 'Bearer acc-2');
        expect(pushed.single.containsKey('X-Profile-Id'), isFalse, reason: 'stream headers carry no profile');
        expect(client.connection.accessToken, 'acc-2');
        // The fresh token is checked again at its own half life.
        expect(client.streamAuth.isScheduled, isTrue);

        release();
        expect(client.streamAuth.isScheduled, isFalse);
        client.close();
      });
    });

    test('a failed refresh keeps the header and tries again later', () {
      fakeAsync((async) {
        final client = build(expiresAt: DateTime.now().add(const Duration(minutes: 10)), failRefresh: true);
        final pushed = <Map<String, String>>[];
        client.streamAuth.hold(pushed.add);
        async.elapse(SiloStreamAuth.minDelay);
        expect(refreshes, 1);
        expect(pushed, isEmpty);
        async.elapse(SiloStreamAuth.retryDelay);
        expect(refreshes, 2);
        client.close();
        expect(client.streamAuth.isScheduled, isFalse);
      });
    });

    test('nothing is refreshed while no stream holds it', () {
      fakeAsync((async) {
        final client = build(expiresAt: DateTime.now().add(const Duration(minutes: 10)));
        async.elapse(const Duration(minutes: 5));
        expect(refreshes, 0);
        expect(client.streamAuth.isScheduled, isFalse);
        client.close();
      });
    });

    test('a pair adopted from a replaced client reaches the stream too', () {
      final client = build(expiresAt: DateTime.now().add(const Duration(minutes: 50)));
      final pushed = <Map<String, String>>[];
      final release = client.streamAuth.hold(pushed.add);
      client.adoptTokens(
        client.connection.copyWith(
          accessToken: 'acc-9',
          refreshToken: 'ref-9',
          accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
        ),
      );
      expect(pushed.single['Authorization'], 'Bearer acc-9');
      release();
      client.close();
    });

    test('a refused stream request refreshes at once', () async {
      final client = build(expiresAt: DateTime.now().add(const Duration(minutes: 50)));
      final pushed = <Map<String, String>>[];
      client.streamAuth.hold(pushed.add);
      expect(await client.streamAuth.refreshAfterRefusal(), isTrue);
      expect(pushed.single['Authorization'], 'Bearer acc-2');
      client.close();
    });
  });
}
