import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_protocol.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_receiver.dart';

Map<String, Object?> _json(String s) => (jsonDecode(s) as Map).cast<String, Object?>();

void main() {
  const url = 'https://media.example.com';

  group('golden frames (silo-android PairingProtocolGoldenFramesTest)', () {
    // Copied verbatim from silo-android, which shares them with silo-apple.
    final frames = <String, SiloPairingMessage>{
      '{"type":"hello","v":1,"tvName":"Living Room","tvDeviceId":"ABC-123","state":"setup","supportedVersions":[1]}':
          const SiloPairingHello(tvName: 'Living Room', tvDeviceId: 'ABC-123', state: SiloPairingReceiverState.setup),
      '{"type":"pushServer","v":1,"serverURL":"https://media.example.com","serverName":"Home"}':
          const SiloPairingPushServer(serverUrl: url, serverName: 'Home'),
      '{"type":"deviceStarted","v":1,"serverURL":"https://media.example.com","userCode":"WXYZ-12","matchCode":"brave-otter"}':
          const SiloPairingDeviceStarted(serverUrl: url, userCode: 'WXYZ-12', matchCode: 'brave-otter'),
      '{"type":"serverResult","v":1,"serverURL":"https://media.example.com","status":"signedIn"}':
          const SiloPairingServerResult(serverUrl: url, status: SiloPairingServerStatus.signedIn),
      '{"type":"serverResult","v":1,"serverURL":"https://media.example.com","status":"failed","error":"unreachable"}':
          const SiloPairingServerResult(serverUrl: url, status: SiloPairingServerStatus.failed, error: 'unreachable'),
      '{"type":"done","v":1}': const SiloPairingDone(),
      '{"type":"cancel","v":1,"reason":"user_declined"}': const SiloPairingCancel('user_declined'),
      '{"type":"hello","v":1,"tvName":"Den","tvDeviceId":"id-9","state":"login","supportedVersions":[1]}':
          const SiloPairingHello(tvName: 'Den', tvDeviceId: 'id-9', state: SiloPairingReceiverState.login),
      '{"type":"pushServer","v":1,"serverURL":"https://media.example.com","serverName":"Home",'
              '"serverIdentity":"96c1bd08-b839-4d47-980e-57d4e7a44cfa","endpoints":['
              '{"url":"https://media.example.com","kind":"public"},'
              '{"url":"https://media.overlay.example","kind":"provider","provider":"tailscale","displayName":"Tailscale"}]}':
          SiloPairingPushServer(
            serverUrl: url,
            serverName: 'Home',
            serverIdentity: '96c1bd08-b839-4d47-980e-57d4e7a44cfa',
            endpoints: [
              SiloPairingEndpoint(url: url, kind: SiloPairingEndpointKind.public),
              SiloPairingEndpoint(
                url: 'https://media.overlay.example',
                kind: SiloPairingEndpointKind.provider,
                provider: 'tailscale',
                displayName: 'Tailscale',
              ),
            ],
          ),
      '{"type":"serverResult","v":1,"serverURL":"https://media.example.com","status":"failed","error":"identity_mismatch"}':
          const SiloPairingServerResult(
            serverUrl: url,
            status: SiloPairingServerStatus.failed,
            error: 'identity_mismatch',
          ),
    };

    test('encode to the same JSON objects', () {
      for (final MapEntry(key: frame, value: message) in frames.entries) {
        expect(_json(message.encode()), _json(frame), reason: frame);
      }
    });

    test('decode back to the same fields', () {
      for (final MapEntry(key: frame, value: message) in frames.entries) {
        final decoded = SiloPairingMessage.decode(frame);
        expect(decoded.runtimeType, message.runtimeType, reason: frame);
        expect(_json(decoded.encode()), _json(frame), reason: frame);
      }
      final push = SiloPairingMessage.decode(frames.keys.elementAt(8)) as SiloPairingPushServer;
      expect(push.endpoints, hasLength(2));
      expect(push.endpoints![1].kind, SiloPairingEndpointKind.provider);
      expect(push.endpoints![1].displayName, 'Tailscale');
    });

    test('optional pushServer fields are left out, endpoint URLs lose a trailing slash', () {
      final legacy = _json(const SiloPairingPushServer(serverUrl: url).encode());
      expect(legacy.containsKey('serverName'), isFalse);
      expect(legacy.containsKey('serverIdentity'), isFalse);
      expect(legacy.containsKey('endpoints'), isFalse);
      final endpoint = SiloPairingEndpoint(
        url: 'https://media.overlay.example/ ',
        kind: SiloPairingEndpointKind.public,
      );
      expect(endpoint.url, 'https://media.overlay.example');
    });
  });

  group('message validation', () {
    test('a payload that is not a JSON object is refused', () {
      expect(() => SiloPairingMessage.decode('[1]'), throwsA(isA<SiloPairingMessageException>()));
      expect(() => SiloPairingMessage.decode('not json'), throwsA(isA<SiloPairingMessageException>()));
    });

    test('missing required fields are refused', () {
      expect(() => SiloPairingMessage.decode('{"v":1}'), throwsA(isA<SiloPairingMessageException>()));
      expect(
        () => SiloPairingMessage.decode('{"type":"pushServer","v":1}'),
        throwsA(isA<SiloPairingMessageException>()),
      );
      expect(() => SiloPairingMessage.decode('{"type":"cancel","v":1}'), throwsA(isA<SiloPairingMessageException>()));
      expect(
        () => SiloPairingMessage.decode('{"type":"pushServer","v":1,"serverURL":{"a":1}}'),
        throwsA(isA<SiloPairingMessageException>()),
      );
      expect(
        () => SiloPairingMessage.decode('{"type":"pushServer","v":1,"serverURL":"x","endpoints":["x"]}'),
        throwsA(isA<SiloPairingMessageException>()),
      );
    });

    test('an unknown receiver state or server status is refused', () {
      expect(
        () => SiloPairingMessage.decode(
          '{"type":"hello","v":1,"tvName":"a","tvDeviceId":"b","state":"busy","supportedVersions":[1]}',
        ),
        throwsA(isA<SiloPairingMessageException>()),
      );
      expect(
        () => SiloPairingMessage.decode('{"type":"serverResult","v":1,"serverURL":"x","status":"maybe"}'),
        throwsA(isA<SiloPairingMessageException>()),
      );
    });

    test('an unknown type decodes to an ignorable message; unknown keys are ignored', () {
      expect(SiloPairingMessage.decode('{"type":"ping","v":1}'), isA<SiloPairingUnknownMessage>());
      final done = SiloPairingMessage.decode('{"type":"done","v":2,"extra":true}');
      expect(done, isA<SiloPairingDone>());
    });

    test('an unknown failure code reads as auth_failed', () {
      expect(SiloPairingFailureCode.fromWire('melted'), SiloPairingFailureCode.authFailed);
      expect(SiloPairingFailureCode.fromWire(null), SiloPairingFailureCode.authFailed);
      expect(SiloPairingFailureCode.fromWire('identity_mismatch'), SiloPairingFailureCode.identityMismatch);
    });

    test('displayName falls back to the normalised address', () {
      expect(
        const SiloPairingPushServer(serverUrl: 'https://a.example/', serverName: ' ').displayName,
        'https://a.example',
      );
      expect(const SiloPairingPushServer(serverUrl: 'https://a.example', serverName: 'Home').displayName, 'Home');
    });
  });

  group('framing', () {
    test('a frame is a 4-byte big-endian length and the payload', () {
      final frame = const SiloPairingDone().toFrame();
      final payload = utf8.encode('{"type":"done","v":1}');
      expect(frame.sublist(0, 4), [0, 0, 0, payload.length]);
      expect(utf8.decode(frame.sublist(4)), '{"type":"done","v":1}');
    });

    test('frames split across reads and several in one read are reassembled', () {
      final a = const SiloPairingDone().toFrame();
      final b = const SiloPairingCancel('x').toFrame();
      final all = Uint8List.fromList([...a, ...b]);
      final buffer = SiloPairingFrameBuffer();
      final out = <String>[];
      for (var i = 0; i < all.length; i += 3) {
        out.addAll(buffer.append(all.sublist(i, i + 3 > all.length ? all.length : i + 3)).map(utf8.decode));
      }
      expect(out, ['{"type":"done","v":1}', '{"type":"cancel","v":1,"reason":"x"}']);
      expect(buffer.pendingBytes, 0);

      final together = SiloPairingFrameBuffer().append(all);
      expect(together, hasLength(2));
    });

    test('an oversized or high-bit length is refused', () {
      expect(() => SiloPairingFrameBuffer().append([0x80, 0, 0, 0]), throwsA(isA<SiloPairingFrameTooLargeException>()));
      expect(() => SiloPairingFrameBuffer().append([0, 0x10, 0, 1]), throwsA(isA<SiloPairingFrameTooLargeException>()));
      expect(
        () => SiloPairingFrame.encode(Uint8List(SiloPairingProtocol.maxFrameBytes + 1)),
        throwsA(isA<SiloPairingFrameTooLargeException>()),
      );
      // Exactly the limit is fine.
      expect(SiloPairingFrame.encode(Uint8List(SiloPairingProtocol.maxFrameBytes)).length, (1 << 20) + 4);
    });
  });

  group('advertisement', () {
    test('setup and login TXT', () {
      expect(SiloPairingAdvertisement.setup.txt(), {'v': '1', 'st': 'setup'});
      expect(const SiloPairingAdvertisement.login('srv-1').txt(), {'v': '1', 'st': 'login', 'srv': 'srv-1'});
      expect(SiloPairingProtocol.serviceType, '_silopair._tcp');
    });

    test('service names are cut to 63 UTF-8 bytes without splitting a character', () {
      expect(SiloPairingProtocol.fittedServiceName(null), 'Plezilo');
      expect(SiloPairingProtocol.fittedServiceName('   '), 'Plezilo');
      expect(SiloPairingProtocol.fittedServiceName(' Living Room '), 'Living Room');
      final long = SiloPairingProtocol.fittedServiceName('é' * 40);
      expect(utf8.encode(long).length, 62);
      expect(long, 'é' * 31);
    });
  });
}
