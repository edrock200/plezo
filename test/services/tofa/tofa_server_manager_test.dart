import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/tofa/tofa_client.dart';

import 'tofa_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTofa fake;
  late MultiServerManager manager;
  late List<TofaClient> built;

  setUp(() {
    fake = FakeTofa();
    built = [];
    fake.on(
      'GET',
      '/api/v1/users/me',
      (request) =>
          request.headers['Authorization'] == 'Bearer acc-1' || request.headers['Authorization'] == 'Bearer acc-2'
          ? jsonResponse({'id': 'u-1', 'username': 'laura', 'is_admin': true, 'disabled': false, 'preferences': {}})
          : tofaError(401, 'unauthorized'),
    );
    fake.on('GET', '/api/v1/auth/image-token', (_) => jsonResponse({'token': 'img', 'expires_in': 3600}));
    manager = MultiServerManager(
      connectivityChanges: () => const Stream.empty(),
      tofaClientFactory: (connection) async {
        final client = TofaClient.forTesting(connection, httpClient: fake.client);
        built.add(client);
        return client;
      },
    );
  });

  tearDown(() => manager.dispose());

  test('a Tofa connection becomes the server\'s client and goes online', () async {
    expect(await manager.addTofaConnection(tofaConnection()), isTrue);
    final client = manager.getClient(ServerId('srv-1'));
    expect(client, isA<TofaClient>());
    expect(manager.onlineServerIds, contains('srv-1'));
    expect(manager.isOwnerOrAdmin(ServerId('srv-1')), isTrue, reason: 'users/me said is_admin');
  });

  test('an unchanged re-add keeps the live client', () async {
    await manager.addTofaConnection(tofaConnection());
    await manager.addTofaConnection(tofaConnection());
    expect(built, hasLength(1));
  });

  test('a new sign-in (another refresh token) replaces the client', () async {
    await manager.addTofaConnection(tofaConnection());
    await manager.addTofaConnection(tofaConnection(accessToken: 'acc-2', refreshToken: 'ref-9'));
    expect(built, hasLength(2));
    expect(identical(manager.getClient(ServerId('srv-1')), built.last), isTrue);
  });

  test('a rotated pair is handed to the persistence callback with its ownership check', () async {
    TofaConnection? persisted;
    bool Function(String)? owns;
    manager.onTofaConnectionUpdated = (connection, ownsRefreshToken) {
      persisted = connection;
      owns = ownsRefreshToken;
    };
    fake.on(
      'GET',
      '/api/v1/libraries',
      (request) =>
          request.headers['Authorization'] == 'Bearer acc-2' ? jsonResponse(<Object>[]) : tofaError(401, 'expired'),
    );
    fake.on('POST', '/servers/srv-1/device-token/refresh', (request) {
      expect(jsonDecode(request.body), {'refresh_token': 'ref-1'});
      return jsonResponse({
        'access_token': 'acc-2',
        'refresh_token': 'ref-2',
        'token_type': 'Bearer',
        'expires_in': 60,
      });
    });
    await manager.addTofaConnection(tofaConnection());
    await (manager.getClient(ServerId('srv-1'))! as TofaClient).fetchLibraries();
    expect(persisted!.refreshToken, 'ref-2');
    expect(owns!('ref-1'), isTrue, reason: 'the row may still hold the token it rotated from');
    expect(owns!('ref-other'), isFalse);
  });

  test('removing the connection forgets its server', () async {
    final connection = tofaConnection();
    await manager.addTofaConnection(connection);
    manager.removeTofaConnection(connection);
    expect(manager.getClient(ServerId('srv-1')), isNull);
  });

  test('a signed-out server is an auth refusal, not offline', () async {
    fake.on('GET', '/api/v1/users/me', (_) => tofaError(401, 'unauthorized'));
    fake.on('POST', '/servers/srv-1/device-token/refresh', (_) => http.Response('{"error":"invalid_grant"}', 401));
    expect(await manager.addTofaConnection(tofaConnection()), isFalse);
    expect(manager.refusedServerIds, contains('srv-1'));
  });
}
