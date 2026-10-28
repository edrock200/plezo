import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/silo/silo_device_sign_in.dart';

import '../../test_helpers/silo_auth_fake.dart';

void main() {
  late FakeSiloAuthServer server;
  late List<SiloDeviceSignInStatus> seen;

  SiloDeviceSignIn machine({SiloDeviceSignInConfig config = const SiloDeviceSignInConfig()}) {
    final flow = SiloDeviceSignIn(auth: server.service(), server: siloTestServer, config: config);
    seen = [flow.state.value.status];
    flow.state.addListener(() {
      if (seen.last != flow.state.value.status) seen.add(flow.state.value.status);
    });
    return flow;
  }

  setUp(() => server = FakeSiloAuthServer());

  test('shows a code and polls at once', () {
    fakeAsync((async) {
      final flow = machine();
      flow.start();
      async.flushMicrotasks();
      expect(flow.state.value.status, SiloDeviceSignInStatus.waiting);
      expect(flow.state.value.code?.deviceCode, 'dev-1');
      expect(server.countOf('/api/v2/auth/device/poll'), 1);
      async.elapse(const Duration(seconds: 5));
      expect(server.countOf('/api/v2/auth/device/poll'), 2);
      flow.dispose();
      async.flushMicrotasks();
    });
  });

  test('an expired code is withdrawn and renewed in place', () {
    server = FakeSiloAuthServer(expiresIn: 12, interval: 5);
    fakeAsync((async) {
      final flow = machine();
      flow.start();
      async.elapse(const Duration(seconds: 13));
      expect(server.bodiesFor('/api/v2/auth/device/cancel'), [contains('dev-1')]);
      expect(server.countOf('/api/v2/auth/device/start'), 2);
      expect(flow.state.value.status, SiloDeviceSignInStatus.newCode);
      expect(flow.state.value.code?.deviceCode, 'dev-2');
      flow.dispose();
      async.flushMicrotasks();
    });
  });

  test('renewals pause after the budget and a new start shows a fresh code', () {
    server = FakeSiloAuthServer(expiresIn: 10, interval: 5);
    fakeAsync((async) {
      final flow = machine(config: const SiloDeviceSignInConfig(pauseAfter: Duration(seconds: 25)));
      flow.start();
      async.elapse(const Duration(seconds: 40));
      expect(flow.state.value.status, SiloDeviceSignInStatus.paused);
      expect(flow.state.value.code, isNull);
      final starts = server.countOf('/api/v2/auth/device/start');
      async.elapse(const Duration(minutes: 5));
      expect(server.countOf('/api/v2/auth/device/start'), starts, reason: 'paused: no more codes');

      flow.start();
      async.flushMicrotasks();
      expect(flow.state.value.status, SiloDeviceSignInStatus.waiting);
      flow.dispose();
      async.flushMicrotasks();
    });
  });

  test('a declined code reports denied and does not mint a new one by itself', () {
    server.pollAnswer = (_) => siloJson({'status': 'denied'});
    fakeAsync((async) {
      final flow = machine();
      flow.start();
      async.elapse(const Duration(minutes: 1));
      expect(flow.state.value.status, SiloDeviceSignInStatus.denied);
      expect(server.countOf('/api/v2/auth/device/start'), 1);
      expect(server.countOf('/api/v2/auth/device/cancel'), 0);

      server.pollAnswer = (_) => siloJson({'status': 'pending'});
      flow.start(); // "Show a new code"
      async.flushMicrotasks();
      expect(flow.state.value.status, SiloDeviceSignInStatus.waiting);
      expect(flow.state.value.code?.deviceCode, 'dev-2');
      flow.dispose();
      async.flushMicrotasks();
    });
  });

  test('a vanished code is replaced, but codes lost at once repeatedly fail', () {
    server.pollAnswer = (_) => siloJson({'status': 'expired'});
    fakeAsync((async) {
      final flow = machine();
      flow.start();
      async.elapse(const Duration(seconds: 1));
      expect(flow.state.value.status, SiloDeviceSignInStatus.failed);
      expect(server.countOf('/api/v2/auth/device/start'), 4);
      flow.dispose();
      async.flushMicrotasks();
    });
  });

  test('failed polls show unreachable after 30 s, keep polling, and recover', () {
    var failing = true;
    server.pollAnswer = (_) => failing ? http.Response('down', 503) : siloJson({'status': 'pending'});
    fakeAsync((async) {
      final flow = machine();
      flow.start();
      async.elapse(const Duration(seconds: 20));
      expect(flow.state.value.status, SiloDeviceSignInStatus.waiting);
      async.elapse(const Duration(seconds: 30));
      expect(flow.state.value.status, SiloDeviceSignInStatus.unreachable);
      expect(flow.state.value.code?.deviceCode, 'dev-1', reason: 'the live code stays on screen');
      final polls = server.countOf('/api/v2/auth/device/poll');
      failing = false;
      async.elapse(const Duration(seconds: 31));
      expect(server.countOf('/api/v2/auth/device/poll'), greaterThan(polls));
      expect(flow.state.value.status, SiloDeviceSignInStatus.waiting);
      flow.dispose();
      async.flushMicrotasks();
    });
  });

  test('sustained 429s show too many attempts while still polling', () {
    server.pollAnswer = (_) => http.Response('slow down', 429);
    fakeAsync((async) {
      final flow = machine();
      flow.start();
      async.elapse(const Duration(seconds: 45));
      expect(flow.state.value.status, isNot(SiloDeviceSignInStatus.tooManyRequests));
      async.elapse(const Duration(seconds: 45));
      expect(flow.state.value.status, SiloDeviceSignInStatus.tooManyRequests);
      expect(flow.state.value.status.isSettled, isFalse);
      final polls = server.countOf('/api/v2/auth/device/poll');
      async.elapse(const Duration(seconds: 31));
      expect(server.countOf('/api/v2/auth/device/poll'), greaterThan(polls));
      flow.dispose();
      async.flushMicrotasks();
    });
  });

  test('an approved code is never cancelled, even on dispose', () {
    server.pollAnswer = (_) => FakeSiloAuthServer.approved();
    fakeAsync((async) {
      final flow = machine();
      flow.start();
      async.flushMicrotasks();
      expect(flow.state.value.status, SiloDeviceSignInStatus.approved);
      expect(flow.state.value.approval?.tokens?.accessToken, 'acc');
      flow.dispose();
      async.flushMicrotasks();
      expect(server.countOf('/api/v2/auth/device/cancel'), 0);
    });
  });

  test('abandoning withdraws the live code', () {
    fakeAsync((async) {
      final flow = machine();
      flow.start();
      async.flushMicrotasks();
      flow.abandon();
      async.flushMicrotasks();
      expect(server.bodiesFor('/api/v2/auth/device/cancel'), [contains('dev-1')]);
      async.elapse(const Duration(minutes: 1));
      expect(server.countOf('/api/v2/auth/device/poll'), 1, reason: 'no polling after abandon');
      flow.dispose();
      async.flushMicrotasks();
    });
  });

  test('a start the server does not offer reports password-only; 410 needs an update', () {
    server.startAnswer = () => http.Response('', 404);
    fakeAsync((async) {
      final flow = machine();
      flow.start();
      async.flushMicrotasks();
      expect(flow.state.value.status, SiloDeviceSignInStatus.noDeviceSignIn);
      server.startAnswer = () => http.Response('', 410);
      flow.start();
      async.flushMicrotasks();
      expect(flow.state.value.status, SiloDeviceSignInStatus.updateRequired);
      flow.dispose();
      async.flushMicrotasks();
    });
  });
}
