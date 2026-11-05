import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_protocol.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_receiver.dart';

import '../../../test_helpers/silo_pairing_phone.dart';

const _url = 'https://silo.example.com';

/// Waits until [receiver]'s status is a [T].
Future<T> _status<T extends SiloPairingStatus>(SiloPairingReceiver receiver) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (receiver.status.value is! T) {
    if (DateTime.now().isAfter(deadline)) throw StateError('status stayed ${receiver.status.value.runtimeType}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return receiver.status.value as T;
}

void main() {
  late FakePairingPort port;
  late Map<String, SiloIdentityProbeResult> identities;
  late List<String> probed;
  late SiloPairingReceiver receiver;
  late FakePairingTransport phone;

  SiloPairingReceiver build({Duration idleTimeout = const Duration(seconds: 180)}) {
    return SiloPairingReceiver(
      port: port,
      identityProbe: (url) async {
        probed.add(url);
        return identities[url] ?? const SiloIdentityUnreachable();
      },
      deviceName: 'Living Room',
      deviceId: 'tv-1',
      idleTimeout: idleTimeout,
    );
  }

  setUp(() {
    port = FakePairingPort();
    identities = {_url: const SiloIdentityAnswer('srv-1')};
    probed = [];
    receiver = build()..setAdvertising();
    phone = FakePairingTransport();
  });

  tearDown(() async {
    await phone.close();
    await receiver.dispose();
  });

  Future<void> run() => receiver.run(phone);

  test('the TV speaks first: hello with its name, id, state and versions', () async {
    final session = run();
    final hello = await phone.next<SiloPairingHello>();
    expect(hello.tvName, 'Living Room');
    expect(hello.tvDeviceId, 'tv-1');
    expect(hello.state, SiloPairingReceiverState.setup);
    expect(hello.supportedVersions, [1]);
    expect(receiver.status.value, isA<SiloPairingConnected>());
    phone.phoneHangsUp();
    await session;
    expect(receiver.status.value, isA<SiloPairingAdvertising>());
  });

  group('setup', () {
    test('consent, identity check, device code, approval, done', () async {
      final session = run();
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverName: 'Home', serverIdentity: 'srv-1'));
      final consent = await _status<SiloPairingConsentRequested>(receiver);
      expect(consent.serverName, 'Home');
      expect(consent.unencrypted, isFalse);
      expect(consent.signIn, isFalse);
      // Nothing is checked or started before the person allows it.
      expect(probed, isEmpty);
      expect(port.setupTargets, isEmpty);

      receiver.allowPendingServer();
      final started = await phone.next<SiloPairingDeviceStarted>();
      expect(started.serverUrl, _url);
      expect(started.userCode, '48217731');
      expect(started.matchCode, 'brave-otter');
      expect(probed, [_url]);
      expect(port.setupTargets.single.url, _url);
      expect(port.setupTargets.single.verifiedServerId, 'srv-1');
      expect(port.outcomeCodes, ['dev-1']);
      expect(receiver.status.value, isA<SiloPairingAwaitingApproval>());

      port.outcomeCompleter.complete(null);
      final result = await phone.next<SiloPairingServerResult>();
      expect(result.status, SiloPairingServerStatus.signedIn);
      expect(result.error, isNull);
      expect(receiver.status.value, isA<SiloPairingSignedIn>());

      phone.phoneSends(const SiloPairingDone());
      await session;
      expect((receiver.status.value as SiloPairingCompleted).serverNames, ['Home']);
      expect(port.abandoned, isEmpty);
      expect(phone.closed, isTrue);
    });

    test('a push without an identity (older phones) is used as is', () async {
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: 'https://other.example/', serverName: 'Old'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      await phone.next<SiloPairingDeviceStarted>();
      expect(probed, isEmpty);
      expect(port.setupTargets.single.url, 'https://other.example/');
      expect(port.setupTargets.single.verifiedServerId, isNull);
    });

    test('Don\'t allow tells the phone and ends the session', () async {
      final session = run();
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.denyPendingServer();
      final cancel = await phone.next<SiloPairingCancel>();
      expect(cancel.reason, 'consent_denied');
      await session;
      expect(phone.closed, isTrue);
      expect(receiver.status.value, isA<SiloPairingAdvertising>());
      expect(port.setupTargets, isEmpty);
    });

    test('another server at the pushed address is refused as identity_mismatch', () async {
      identities[_url] = const SiloIdentityAnswer('someone-else');
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverName: 'Home', serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      final result = await phone.next<SiloPairingServerResult>();
      expect(result.status, SiloPairingServerStatus.failed);
      expect(result.error, 'identity_mismatch');
      expect(port.setupTargets, isEmpty);
      final failed = receiver.status.value as SiloPairingFailed;
      expect(failed.code, SiloPairingFailureCode.identityMismatch);
      expect(port.abandoned, [null]);
    });

    test('a v1-only server at the pushed address is identity_mismatch too', () async {
      identities[_url] = const SiloIdentityUnsupported();
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      expect((await phone.next<SiloPairingServerResult>()).error, 'identity_mismatch');
    });

    test('an unreachable address offers a verified alternate, never takes it on its own', () async {
      identities = {
        'https://wrong.example': const SiloIdentityAnswer('not-it'),
        'https://ts.example': const SiloIdentityAnswer('srv-1'),
      };
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(
        SiloPairingPushServer(
          serverUrl: _url,
          serverName: 'Home',
          serverIdentity: 'srv-1',
          endpoints: [
            SiloPairingEndpoint(url: _url, kind: SiloPairingEndpointKind.provider, displayName: 'Tailscale'),
            SiloPairingEndpoint(url: 'https://wrong.example', kind: SiloPairingEndpointKind.public),
            SiloPairingEndpoint(url: 'https://ts.example/', kind: SiloPairingEndpointKind.public),
          ],
        ),
      );
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      final unreachable = await _status<SiloPairingUnreachable>(receiver);
      expect(unreachable.alternateUrl, 'https://ts.example');
      expect(unreachable.providerName, 'Tailscale');
      expect(port.setupTargets, isEmpty);

      receiver.useAlternateAddress();
      final started = await phone.next<SiloPairingDeviceStarted>();
      // Frames always name the pushed address.
      expect(started.serverUrl, _url);
      expect(port.setupTargets.single.url, 'https://ts.example');
      expect(port.setupTargets.single.verifiedServerId, 'srv-1');
    });

    test('Try again probes the pushed address again', () async {
      identities = {};
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      final unreachable = await _status<SiloPairingUnreachable>(receiver);
      expect(unreachable.alternateUrl, isNull);
      receiver.useAlternateAddress(); // nothing to use: ignored
      identities[_url] = const SiloIdentityAnswer('srv-1');
      receiver.retryPushedAddress();
      await phone.next<SiloPairingDeviceStarted>();
      expect(probed, [_url, _url]);
    });

    test('a failed code is reported with its wire code and the code screen is left', () async {
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverName: 'Home', serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      await phone.next<SiloPairingDeviceStarted>();
      port.outcomeCompleter.complete(SiloPairingFailureCode.denied);
      final result = await phone.next<SiloPairingServerResult>();
      expect(result.error, 'denied');
      expect(port.abandoned, ['dev-1']);
      expect((receiver.status.value as SiloPairingFailed).code, SiloPairingFailureCode.denied);
    });

    test('a start failure is reported as such', () async {
      port.startError = const SiloPairingAttemptFailure(SiloPairingFailureCode.updateRequired);
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      expect((await phone.next<SiloPairingServerResult>()).error, 'update_required');
    });

    test('the phone hanging up mid-approval abandons the code', () async {
      final session = run();
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      await phone.next<SiloPairingDeviceStarted>();
      phone.phoneHangsUp();
      await session;
      await Future<void>.delayed(Duration.zero);
      expect(port.abandoned, ['dev-1']);
      expect(receiver.status.value, isA<SiloPairingAdvertising>());
    });

    test('a phone cancel mid-approval abandons the code, nothing is reported', () async {
      final session = run();
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      await phone.next<SiloPairingDeviceStarted>();
      phone.phoneSends(const SiloPairingCancel('match-code-mismatch'));
      await session;
      await Future<void>.delayed(Duration.zero);
      expect(port.abandoned, ['dev-1']);
      expect(receiver.status.value, isA<SiloPairingAdvertising>());
    });

    test('a newer push replaces one in flight without asking again', () async {
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      await phone.next<SiloPairingDeviceStarted>();
      port.code = const SiloPairingCode(deviceCode: 'dev-2', userCode: '48217732', matchCode: 'quiet-fox');
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      final second = await phone.next<SiloPairingDeviceStarted>();
      expect(second.userCode, '48217732');
      expect(port.abandoned, ['dev-1']);
    });

    group('several accounts in one session (Silo Android #810)', () {
      const cabin = 'https://cabin.example';

      setUp(() {
        identities[cabin] = const SiloIdentityAnswer('srv-2');
        port.nextCodes.addAll(const [
          SiloPairingCode(deviceCode: 'dev-1', userCode: '48217731', matchCode: 'brave-otter'),
          SiloPairingCode(deviceCode: 'dev-2', userCode: '48217732', matchCode: 'quiet-fox'),
          SiloPairingCode(deviceCode: 'dev-3', userCode: '48217733', matchCode: 'calm-wren'),
        ]);
        for (final code in ['dev-1', 'dev-2', 'dev-3']) {
          port.outcomesByCode[code] = Completer();
        }
      });

      test('two accounts on two servers: each signs in, consent asked once, one binding', () async {
        var ended = 0;
        receiver.onSessionEnd = () => ended++;
        final session = run();
        await phone.next<SiloPairingHello>();
        final results = await phone.signInAccounts(
          const [
            SiloPairingPushServer(serverUrl: _url, serverName: 'Home', serverIdentity: 'srv-1', accountName: 'laura'),
            SiloPairingPushServer(serverUrl: cabin, serverName: 'Cabin', serverIdentity: 'srv-2', accountName: 'sam'),
          ],
          onPushed: (i) async {
            if (i == 0) {
              await _status<SiloPairingConsentRequested>(receiver);
              receiver.allowPendingServer();
            }
          },
          approve: (i, started) {
            if (i == 1) {
              final working = receiver.status.value;
              expect(working, isA<SiloPairingAwaitingApproval>());
            }
            port.outcomesByCode[i == 0 ? 'dev-1' : 'dev-2']!.complete(null);
          },
        );
        expect(results.map((r) => r.status), [SiloPairingServerStatus.signedIn, SiloPairingServerStatus.signedIn]);
        expect(results.map((r) => r.serverUrl), [_url, cabin]);
        await session;
        expect((receiver.status.value as SiloPairingCompleted).serverNames, ['Home', 'Cabin']);
        expect(port.setupTargets.map((t) => t.verifiedServerId), ['srv-1', 'srv-2']);
        // One binding for the whole session, handed to every attempt.
        expect(port.setupBindings, hasLength(2));
        expect(port.setupBindings.first, isNotNull);
        expect(identical(port.setupBindings.first, port.setupBindings.last), isTrue);
        expect(receiver.signedInCount, 2);
        expect(ended, 1);
      });

      test('the same server again is another account; the status counts them', () async {
        final session = run();
        await phone.next<SiloPairingHello>();
        phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverName: 'Home', serverIdentity: 'srv-1'));
        await _status<SiloPairingConsentRequested>(receiver);
        receiver.allowPendingServer();
        await phone.next<SiloPairingDeviceStarted>();
        port.outcomesByCode['dev-1']!.complete(null);
        await phone.next<SiloPairingServerResult>();
        expect((receiver.status.value as SiloPairingSignedIn).count, 1);

        phone.phoneSends(
          const SiloPairingPushServer(serverUrl: _url, serverName: 'Home', serverIdentity: 'srv-1', accountName: 'sam'),
        );
        await phone.next<SiloPairingDeviceStarted>();
        port.outcomesByCode['dev-2']!.complete(null);
        expect((await phone.next<SiloPairingServerResult>()).status, SiloPairingServerStatus.signedIn);
        expect((receiver.status.value as SiloPairingSignedIn).count, 2);

        // Continue on the TV ends the session with both kept.
        receiver.finishSession();
        await session;
        expect((receiver.status.value as SiloPairingCompleted).serverNames, ['Home', 'Home']);
      });

      test('a failed account does not end the session; the next one signs in', () async {
        final session = run();
        await phone.next<SiloPairingHello>();
        final results = await phone.signInAccounts(
          const [
            SiloPairingPushServer(serverUrl: _url, serverName: 'Home', serverIdentity: 'srv-1'),
            SiloPairingPushServer(serverUrl: cabin, serverName: 'Cabin', serverIdentity: 'srv-2'),
          ],
          onPushed: (i) async {
            if (i == 0) {
              await _status<SiloPairingConsentRequested>(receiver);
              receiver.allowPendingServer();
            }
          },
          approve: (i, started) => port.outcomesByCode[started.userCode == '48217731' ? 'dev-1' : 'dev-2']!.complete(
            i == 0 ? SiloPairingFailureCode.denied : null,
          ),
        );
        expect(results.map((r) => r.error), ['denied', null]);
        expect(results.last.status, SiloPairingServerStatus.signedIn);
        await session;
        expect((receiver.status.value as SiloPairingCompleted).serverNames, ['Cabin']);
        expect(port.abandoned, ['dev-1']);
      });

      test('each phone session gets its own binding', () async {
        final first = run();
        await phone.next<SiloPairingHello>();
        phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
        await _status<SiloPairingConsentRequested>(receiver);
        receiver.allowPendingServer();
        await phone.next<SiloPairingDeviceStarted>();
        phone.phoneHangsUp();
        await first;

        phone = FakePairingTransport();
        final second = run();
        await phone.next<SiloPairingHello>();
        phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
        await _status<SiloPairingConsentRequested>(receiver);
        receiver.allowPendingServer();
        await phone.next<SiloPairingDeviceStarted>();
        expect(port.setupBindings, hasLength(2));
        expect(port.setupBindings.first!.binding, isNot(port.setupBindings.last!.binding));
        phone.phoneHangsUp();
        await second;
      });
    });

    test('a plain-HTTP address is flagged unencrypted on the consent screen', () async {
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: 'http://192.168.1.5:8090', serverName: 'NAS'));
      final consent = await _status<SiloPairingConsentRequested>(receiver);
      expect(consent.unencrypted, isTrue);
    });

    test('Cancel on the TV ends the session and the attempt', () async {
      final session = run();
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      await phone.next<SiloPairingDeviceStarted>();
      receiver.cancelActiveSession();
      await session;
      await Future<void>.delayed(Duration.zero);
      expect(phone.closed, isTrue);
      expect(port.abandoned, ['dev-1']);
      expect(receiver.status.value, isA<SiloPairingAdvertising>());
    });
  });

  group('login', () {
    setUp(() => receiver.advertisement = const SiloPairingAdvertisement.login('srv-1'));

    test('the advertised server gets the code already on screen', () async {
      final session = run();
      final hello = await phone.next<SiloPairingHello>();
      expect(hello.state, SiloPairingReceiverState.login);
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverName: 'Home', serverIdentity: 'srv-1'));
      final consent = await _status<SiloPairingConsentRequested>(receiver);
      expect(consent.signIn, isTrue);
      receiver.allowPendingServer();
      final started = await phone.next<SiloPairingDeviceStarted>();
      expect(started.userCode, '11112222');
      expect(started.matchCode, 'calm-heron');
      expect(port.outcomeCodes, ['dev-9']);
      // No probe and no second request: the screen's own code is lent.
      expect(probed, isEmpty);
      expect(port.setupTargets, isEmpty);
      port.outcomeCompleter.complete(null);
      expect((await phone.next<SiloPairingServerResult>()).status, SiloPairingServerStatus.signedIn);
      phone.phoneSends(const SiloPairingDone());
      await session;
      expect(receiver.status.value, isA<SiloPairingCompleted>());
    });

    test('the sign-in screen keeps one account: a later push is limit_reached', () async {
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      await phone.next<SiloPairingDeviceStarted>();
      port.outcomeCompleter.complete(null);
      await phone.next<SiloPairingServerResult>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1', accountName: 'sam'));
      final result = await phone.next<SiloPairingServerResult>();
      expect(result.status, SiloPairingServerStatus.failed);
      expect(result.error, 'limit_reached');
      expect(port.outcomeCodes, ['dev-9']);
    });

    test('another server, or one without an identity, is identity_mismatch', () async {
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-2'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      expect((await phone.next<SiloPairingServerResult>()).error, 'identity_mismatch');
      final failed = receiver.status.value as SiloPairingFailed;
      expect(failed.signIn, isTrue);
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url));
      expect((await phone.next<SiloPairingServerResult>()).error, 'identity_mismatch');
      expect(port.abandoned, isEmpty);
    });

    test('no code on screen answers expired', () async {
      port.screenCode = null;
      unawaited(run());
      await phone.next<SiloPairingHello>();
      phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
      await _status<SiloPairingConsentRequested>(receiver);
      receiver.allowPendingServer();
      expect((await phone.next<SiloPairingServerResult>()).error, 'expired');
    });
  });

  test('a silent phone is dropped after the idle timeout', () async {
    receiver = build(idleTimeout: const Duration(milliseconds: 100))..setAdvertising();
    final session = run();
    await phone.next<SiloPairingHello>();
    await session.timeout(const Duration(seconds: 2));
    expect(phone.closed, isTrue);
    expect(receiver.status.value, isA<SiloPairingAdvertising>());
  });

  test('a second connection while one is served is closed at once', () async {
    unawaited(run());
    await phone.next<SiloPairingHello>();
    final other = FakePairingTransport();
    await receiver.run(other);
    expect(other.closed, isTrue);
    expect(phone.closed, isFalse);
  });

  test('a lone failure stays on screen after the phone leaves until closed', () async {
    identities[_url] = const SiloIdentityAnswer('other');
    final session = run();
    await phone.next<SiloPairingHello>();
    phone.phoneSends(const SiloPairingPushServer(serverUrl: _url, serverIdentity: 'srv-1'));
    await _status<SiloPairingConsentRequested>(receiver);
    receiver.allowPendingServer();
    await phone.next<SiloPairingServerResult>();
    phone.phoneHangsUp();
    await session;
    expect(receiver.status.value, isA<SiloPairingFailed>());
    receiver.cancelActiveSession();
    expect(receiver.status.value, isA<SiloPairingAdvertising>());
  });
}
