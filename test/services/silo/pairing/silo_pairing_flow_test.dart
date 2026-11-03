import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/silo/pairing/silo_pairing_flow.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_protocol.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_receiver.dart';
import 'package:plezy/services/silo/silo_auth_service.dart';
import 'package:plezy/services/silo/silo_device_sign_in.dart';

import '../../../test_helpers/silo_auth_fake.dart';

SiloDeviceCode _code(String deviceCode) => SiloDeviceCode(
  deviceCode: deviceCode,
  userCode: '48217731',
  matchCode: 'brave-otter',
  verificationUri: 'https://silo.example.com/activate',
  expiresAt: DateTime(2030),
  interval: const Duration(seconds: 5),
);

SiloDeviceSignInState _state(SiloDeviceSignInStatus status, [String? deviceCode]) =>
    SiloDeviceSignInState(status, code: deviceCode == null ? null : _code(deviceCode));

void main() {
  group('siloPairingFirstCode', () {
    test('waits for the first live code', () async {
      final state = ValueNotifier(_state(SiloDeviceSignInStatus.gettingCode));
      final future = siloPairingFirstCode(state);
      state.value = _state(SiloDeviceSignInStatus.waiting, 'dev-1');
      final code = await future;
      expect(code.deviceCode, 'dev-1');
      expect(code.userCode, '48217731');
      expect(code.matchCode, 'brave-otter');
    });

    test('settled states without a code map to wire failures', () async {
      final cases = {
        SiloDeviceSignInStatus.noDeviceSignIn: SiloPairingFailureCode.authFailed,
        SiloDeviceSignInStatus.failed: SiloPairingFailureCode.authFailed,
        SiloDeviceSignInStatus.updateRequired: SiloPairingFailureCode.updateRequired,
        SiloDeviceSignInStatus.unreachable: SiloPairingFailureCode.unreachable,
      };
      for (final MapEntry(key: status, value: wire) in cases.entries) {
        final state = ValueNotifier(_state(status));
        await expectLater(
          siloPairingFirstCode(state),
          throwsA(isA<SiloPairingAttemptFailure>().having((f) => f.code, 'code', wire)),
          reason: status.name,
        );
      }
    });

    test('times out as unreachable', () async {
      final state = ValueNotifier(_state(SiloDeviceSignInStatus.gettingCode));
      await expectLater(
        siloPairingFirstCode(state, timeout: const Duration(milliseconds: 20)),
        throwsA(isA<SiloPairingAttemptFailure>().having((f) => f.code, 'code', SiloPairingFailureCode.unreachable)),
      );
    });
  });

  group('siloPairingOutcome', () {
    test('signed in after the approval became a session', () async {
      final state = ValueNotifier(_state(SiloDeviceSignInStatus.waiting, 'dev-1'));
      final signedIn = Completer<bool>();
      final outcome = siloPairingOutcome(state, 'dev-1', signedIn.future);
      state.value = _state(SiloDeviceSignInStatus.opened, 'dev-1');
      state.value = const SiloDeviceSignInState(SiloDeviceSignInStatus.approved);
      signedIn.complete(true);
      expect(await outcome, isNull);
    });

    test('an approval that could not finish is auth_failed', () async {
      final state = ValueNotifier(_state(SiloDeviceSignInStatus.waiting, 'dev-1'));
      final signedIn = Completer<bool>();
      final outcome = siloPairingOutcome(state, 'dev-1', signedIn.future);
      state.value = const SiloDeviceSignInState(SiloDeviceSignInStatus.approved);
      signedIn.complete(false);
      expect(await outcome, SiloPairingFailureCode.authFailed);
    });

    test('a flow left before approval is expired', () async {
      final state = ValueNotifier(_state(SiloDeviceSignInStatus.waiting, 'dev-1'));
      final signedIn = Completer<bool>();
      final outcome = siloPairingOutcome(state, 'dev-1', signedIn.future);
      signedIn.complete(false);
      expect(await outcome, SiloPairingFailureCode.expired);
    });

    test('declined, renewed, paused and update-required codes', () async {
      Future<SiloPairingFailureCode?> run(SiloDeviceSignInState next) {
        final state = ValueNotifier(_state(SiloDeviceSignInStatus.waiting, 'dev-1'));
        final outcome = siloPairingOutcome(state, 'dev-1', Completer<bool>().future);
        state.value = next;
        return outcome;
      }

      expect(await run(_state(SiloDeviceSignInStatus.denied)), SiloPairingFailureCode.denied);
      expect(await run(_state(SiloDeviceSignInStatus.newCode, 'dev-2')), SiloPairingFailureCode.expired);
      expect(await run(_state(SiloDeviceSignInStatus.paused)), SiloPairingFailureCode.expired);
      expect(await run(_state(SiloDeviceSignInStatus.gettingCode)), SiloPairingFailureCode.expired);
      expect(await run(_state(SiloDeviceSignInStatus.updateRequired)), SiloPairingFailureCode.updateRequired);
      expect(await run(_state(SiloDeviceSignInStatus.failed)), SiloPairingFailureCode.authFailed);
    });

    test('an unreachable spell with the same code keeps waiting', () async {
      final state = ValueNotifier(_state(SiloDeviceSignInStatus.waiting, 'dev-1'));
      final signedIn = Completer<bool>();
      final outcome = siloPairingOutcome(state, 'dev-1', signedIn.future);
      state.value = _state(SiloDeviceSignInStatus.unreachable, 'dev-1');
      state.value = _state(SiloDeviceSignInStatus.waiting, 'dev-1');
      signedIn.complete(true);
      expect(await outcome, isNull);
    });
  });

  group('SiloAuthService.probeIdentity', () {
    test('reads server_id, a legacy 404 and everything else', () async {
      final server = FakeSiloAuthServer();
      final auth = server.service();
      expect(await auth.probeIdentity('https://silo.example.com/'), isA<SiloIdentityAnswer>());
      expect(((await auth.probeIdentity('https://silo.example.com')) as SiloIdentityAnswer).serverId, 'srv-1');
      expect(server.paths(), everyElement('/api/v2/system/identity'));

      server.identityAnswer = () => http.Response('404 page not found', 404);
      expect(await auth.probeIdentity('https://silo.example.com'), isA<SiloIdentityUnsupported>());

      server.identityAnswer = () => http.Response('<html>proxy</html>', 502);
      expect(await auth.probeIdentity('https://silo.example.com'), isA<SiloIdentityUnreachable>());

      server.identityAnswer = () => siloJson({'server_id': ' '});
      expect(await auth.probeIdentity('https://silo.example.com'), isA<SiloIdentityUnreachable>());

      expect(await auth.probeIdentity(''), isA<SiloIdentityUnreachable>());
    });

    test('the device code carries the match code', () async {
      final server = FakeSiloAuthServer();
      final code = await server.service().startDeviceLogin(siloTestServer);
      expect(code.matchCode, 'brave-otter-1');
    });
  });
}
