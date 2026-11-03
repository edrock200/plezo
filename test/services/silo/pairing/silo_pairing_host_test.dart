import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_host.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_protocol.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_receiver.dart';

import '../../../test_helpers/silo_pairing_phone.dart';

const _url = 'https://silo.example.com';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The phone side over real sockets: what Silo's phone app does once the
/// platform finished the TLS-PSK handshake and relayed the connection.
void main() {
  late FakePairingPort port;
  late FakePairingAdvertiser advertiser;
  late SiloPairingReceiver receiver;
  late SiloPairingHost host;

  setUp(() async {
    port = FakePairingPort();
    advertiser = FakePairingAdvertiser();
    receiver = SiloPairingReceiver(
      port: port,
      identityProbe: (url) async => url == _url ? const SiloIdentityAnswer('srv-1') : const SiloIdentityUnreachable(),
      deviceName: 'Living Room',
      deviceId: 'tv-1',
    );
    host = SiloPairingHost(
      receiver: receiver,
      advertiser: advertiser,
      serviceName: 'Living Room',
      deviceId: 'tv-1',
      secretTimeout: const Duration(milliseconds: 300),
    );
    await host.advertise(SiloPairingAdvertisement.setup);
  });

  tearDown(() => host.dispose());

  test('advertises _silopair._tcp TXT like Silo\'s TVs', () {
    final txt = advertiser.started.single;
    expect(txt['v'], '1');
    expect(txt['st'], 'setup');
    expect(txt['name'], 'Living Room');
    expect(txt['id'], 'tv-1');
    expect(txt['sid'], isNotEmpty);
    expect(txt.containsKey('srv'), isFalse);
    expect(txt['_service'], 'Living Room');
    expect(receiver.status.value, isA<SiloPairingAdvertising>());
  });

  test('a phone signs the TV in over the bridge', () async {
    final phone = await SiloPairingPhone.dial(host);
    final hello = await phone.next<SiloPairingHello>();
    expect(hello.state, SiloPairingReceiverState.setup);
    expect(hello.supportedVersions, contains(SiloPairingProtocol.version));

    await phone.send(
      SiloPairingPushServer(
        serverUrl: _url,
        serverName: 'Home',
        serverIdentity: 'srv-1',
        endpoints: [SiloPairingEndpoint(url: _url, kind: SiloPairingEndpointKind.public)],
      ),
    );
    await _until(() => receiver.status.value is SiloPairingConsentRequested);
    receiver.allowPendingServer();

    final started = await phone.next<SiloPairingDeviceStarted>();
    expect(started.serverUrl, _url);
    expect(started.userCode, '48217731');
    expect(started.matchCode, 'brave-otter');

    // The phone looks the code up, compares the match code and approves on the server.
    port.outcomeCompleter.complete(null);
    final result = await phone.next<SiloPairingServerResult>();
    expect(result.status, SiloPairingServerStatus.signedIn);

    await phone.send(const SiloPairingDone());
    expect(await phone.closedByTv(), isTrue);
    await _until(() => receiver.status.value is SiloPairingCompleted);
    await phone.close();
  });

  test('a connection without the bridge secret is dropped', () async {
    final wrong = await SiloPairingPhone.connect(host.bridgePort!, Uint8List(SiloPairingHost.secretLength));
    expect(await wrong.closedByTv(), isTrue);
    await wrong.close();

    // Saying nothing at all times out too.
    final silent = await Socket.connect(InternetAddress.loopbackIPv4, host.bridgePort!);
    final ended = silent.drain<void>().then((_) => true);
    expect(await ended.timeout(const Duration(seconds: 3)), isTrue);
    silent.destroy();
    expect(receiver.hasSession, isFalse);

    // The right secret still works afterwards.
    final phone = await SiloPairingPhone.dial(host);
    await phone.next<SiloPairingHello>();
    await phone.close();
  });

  test('one phone at a time', () async {
    final first = await SiloPairingPhone.dial(host);
    await first.next<SiloPairingHello>();
    final second = await SiloPairingPhone.dial(host);
    expect(await second.closedByTv(), isTrue);
    expect(receiver.hasSession, isTrue);
    await second.close();
    await first.close();
  });

  test('a malformed frame ends the session', () async {
    final phone = await SiloPairingPhone.dial(host);
    await phone.next<SiloPairingHello>();
    final raw = await Socket.connect(InternetAddress.loopbackIPv4, host.bridgePort!);
    raw.destroy();
    await phone.close();
    await _until(() => !receiver.hasSession);

    final socket = await Socket.connect(InternetAddress.loopbackIPv4, host.bridgePort!);
    socket.add(host.bridgeSecret!);
    socket.add(SiloPairingFrame.encode('{"type":"pushServer","v":1}'.codeUnits));
    final ended = socket.drain<void>().then((_) => true);
    expect(await ended.timeout(const Duration(seconds: 3)), isTrue);
    socket.destroy();
    await _until(() => !receiver.hasSession);
  });

  test('the advertisement changes only between sessions', () async {
    final phone = await SiloPairingPhone.dial(host);
    await phone.next<SiloPairingHello>();
    await host.advertise(const SiloPairingAdvertisement.login('srv-1'));
    expect(advertiser.started, hasLength(1));
    await phone.close();
    await _until(() => advertiser.started.length == 2);
    expect(advertiser.started.last['st'], 'login');
    expect(advertiser.started.last['srv'], 'srv-1');
    expect(advertiser.started.last['sid'], isNot(advertiser.started.first['sid']));

    await host.advertise(null);
    expect(advertiser.stops, 1);
    expect(receiver.status.value, isA<SiloPairingIdle>());
  });
}
