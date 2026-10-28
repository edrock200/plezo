import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection({String accessToken = 'acc-1', String refreshToken = 'ref-1', String? profileToken}) =>
    SiloConnection(
      id: 'srv-1/1/p-owner',
      baseUrl: 'https://silo.example.com',
      serverName: 'Home Silo',
      serverId: 'srv-1',
      userId: '1',
      userName: 'laura',
      accessToken: accessToken,
      refreshToken: refreshToken,
      deviceId: 'dev-1',
      profileId: 'p-owner',
      profileName: 'Laura',
      profileToken: profileToken,
      createdAt: DateTime(2026),
    );

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// A tiny Silo server: one login session whose refresh token rotates on use.
class _FakeSilo {
  String access = 'acc-1';
  String refresh = 'ref-1';
  int rotations = 0;
  bool down = false;
  bool refuseRefresh = false;
  Future<void>? refreshGate;
  final logouts = <String?>[];

  Future<http.Response> handle(http.Request request) async {
    if (down) throw http.ClientException('connection refused', request.url);
    final path = request.url.path;
    if (path == '/api/v2/auth/refresh') {
      await refreshGate;
      final sent = (jsonDecode(request.body) as Map)['refresh_token'];
      if (refuseRefresh || sent != refresh) return _json({'type': 'x/session_expired', 'status': 401}, 401);
      rotations++;
      access = 'acc-${rotations + 1}';
      refresh = 'ref-${rotations + 1}';
      return _json({'access_token': access, 'refresh_token': refresh, 'expires_in': 3600});
    }
    if (path == '/api/v2/auth/logout') {
      logouts.add(request.headers['Authorization']);
      return http.Response('', 204);
    }
    if (request.headers['Authorization'] != 'Bearer $access') return http.Response('', 401);
    if (path == '/api/v2/account/me') return _json({'id': '1', 'role': 'member'});
    return _json({'items': <Object>[]});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
  });

  late _FakeSilo server;
  late List<SiloClient> built;

  MultiServerManager manager() {
    server = _FakeSilo();
    built = [];
    final m = MultiServerManager(
      siloClientFactory: (connection) async {
        final client = SiloClient.forTesting(connection, headers: _headers, httpClient: MockClient(server.handle));
        built.add(client);
        return client;
      },
    );
    return m;
  }

  Future<void> quietly(Future<Object?> Function() call) async {
    try {
      await call();
    } catch (_) {}
  }

  group('Silo server status', () {
    test('repeated connection failures flip the server offline, and it comes back on its own', () {
      fakeAsync((async) {
        final m = manager();
        m.addSiloConnection(_connection());
        async.flushMicrotasks();
        expect(m.isServerOnline(ServerId('srv-1')), isTrue);

        server.down = true;
        final client = m.getClient(ServerId('srv-1'))!;
        quietly(client.fetchLibraries);
        async.flushMicrotasks();
        quietly(client.fetchLibraries);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        expect(m.isServerOnline(ServerId('srv-1')), isFalse);

        server.down = false;
        async.elapse(const Duration(seconds: 12));
        expect(m.isServerOnline(ServerId('srv-1')), isTrue, reason: 'a failed probe re-arms the check');
        m.dispose();
      });
    });

    test('a single failure that the next request does not repeat changes nothing', () {
      fakeAsync((async) {
        final m = manager();
        m.addSiloConnection(_connection());
        async.flushMicrotasks();
        final client = m.getClient(ServerId('srv-1'))!;
        server.down = true;
        quietly(client.fetchLibraries);
        async.flushMicrotasks();
        server.down = false;
        quietly(client.fetchLibraries);
        async.flushMicrotasks();
        server.down = true;
        quietly(client.fetchLibraries);
        async.flushMicrotasks();
        server.down = false;
        async.elapse(const Duration(seconds: 6));
        expect(m.isServerOnline(ServerId('srv-1')), isTrue);
        expect(m.authErrorServerIds, isEmpty);
        m.dispose();
      });
    });

    test('a 401 that a refresh cannot cure publishes an auth error', () {
      fakeAsync((async) {
        final m = manager();
        m.addSiloConnection(_connection());
        async.flushMicrotasks();
        expect(m.isServerOnline(ServerId('srv-1')), isTrue);

        // Signed out elsewhere: the access token stops working, the refresh is refused.
        server.access = 'revoked';
        server.refuseRefresh = true;
        quietly(m.getClient(ServerId('srv-1'))!.fetchLibraries);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 6));
        expect(m.isServerOnline(ServerId('srv-1')), isFalse);
        expect(m.authErrorServerIds, {'srv-1'});
        m.dispose();
      });
    });
  });

  group('Silo client replacement keeps the login session', () {
    test('a changed connection row with a rotated-away refresh token uses the live tokens', () async {
      final m = manager();
      addTearDown(m.dispose);
      final persisted = <SiloConnection>[];
      m.onSiloConnectionUpdated = persisted.add;

      await m.addSiloConnection(_connection());
      // The live client rotates (ref-1 → ref-2) on a 401.
      server.access = 'acc-x';
      server.refresh = 'ref-1';
      server.rotations = 0;
      final first = built.single;
      await first.fetchLibraries();
      expect(first.connection.refreshToken, 'ref-2');

      // A re-bind arrives from a row read before that rotation was persisted,
      // with a new PIN token (so the client must be rebuilt).
      expect(await m.addSiloConnection(_connection(profileToken: 'pin-2')), isTrue);
      final second = built.last;
      expect(second, isNot(same(first)));
      expect(second.connection.refreshToken, 'ref-2');
      expect(second.connection.accessToken, 'acc-2');
      expect(second.connection.profileToken, 'pin-2');
      expect(second.ownsRefreshToken('ref-1'), isTrue, reason: 'older rows still describe this session');
      expect(server.rotations, 1, reason: 'the dead ref-1 was never sent again');
    });

    test('a refresh the replaced client had in flight reaches its replacement', () async {
      final m = manager();
      addTearDown(m.dispose);
      final persisted = <SiloConnection>[];
      m.onSiloConnectionUpdated = persisted.add;

      await m.addSiloConnection(_connection());
      final first = built.single;

      // The old client's request gets a 401 and starts a refresh that is
      // still on the wire when the client is replaced.
      final gate = Completer<void>();
      server.refreshGate = gate.future;
      server.access = 'acc-x';
      final pending = first.fetchLibraries();
      await pumpEventQueue();
      server.access = 'acc-1'; // the replacement's own health probe still gets in
      await m.addSiloConnection(_connection(profileToken: 'pin-2'));
      final second = built.last;
      expect(second.connection.refreshToken, 'ref-1');

      gate.complete();
      server.refreshGate = null;
      await pending.catchError((_) => <MediaLibrary>[]);
      await pumpEventQueue();
      expect(server.refresh, 'ref-2');

      expect(second.connection.refreshToken, 'ref-2', reason: 'ref-1 is dead after the rotation');
      expect(second.connection.profileToken, 'pin-2');
      expect(persisted.last.refreshToken, 'ref-2');
      expect(persisted.last.profileToken, 'pin-2', reason: 'the replacement row is persisted, not the old one');
      await second.fetchLibraries();
      expect(server.rotations, 1);
    });

    test('a new sign-in (unknown refresh token) does not inherit the old session', () async {
      final m = manager();
      addTearDown(m.dispose);
      await m.addSiloConnection(_connection());
      server.access = 'acc-new';
      server.refresh = 'ref-new';
      await m.addSiloConnection(_connection(accessToken: 'acc-new', refreshToken: 'ref-new'));
      expect(built.last.connection.refreshToken, 'ref-new');
      expect(built.last.ownsRefreshToken('ref-1'), isFalse);
    });
  });

  group('removing a Silo connection', () {
    test('revokes the login session with the live access token', () async {
      final m = manager();
      addTearDown(m.dispose);
      await m.addSiloConnection(_connection());
      m.removeSiloConnection(_connection());
      expect(m.getClient(ServerId('srv-1')), isNull, reason: 'removal does not wait for the logout');
      await pumpEventQueue();
      expect(server.logouts, ['Bearer acc-1']);
    });

    test('without a live client, uses the stored tokens; a failure never throws', () async {
      final m = manager();
      addTearDown(m.dispose);
      server.down = true;
      m.removeSiloConnection(_connection());
      await pumpEventQueue();
      expect(server.logouts, isEmpty);
      server.down = false;
      m.removeSiloConnection(_connection());
      await pumpEventQueue();
      expect(server.logouts, ['Bearer acc-1']);
    });
  });
}
