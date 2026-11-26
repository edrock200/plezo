import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/home_watch_state.dart';
import 'package:plezy/services/tofa/tofa_api.dart';
import 'package:plezy/services/tofa/tofa_client.dart';
import 'package:plezy/services/tofa/tofa_events.dart';

import 'tofa_fixtures.dart';

class _FakeConnection implements TofaEventsConnection {
  final controller = StreamController<String>();
  final sent = <String>[];
  bool closed = false;

  @override
  Stream<String> get frames => controller.stream;

  @override
  void send(String text) => sent.add(text);

  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) await controller.close();
  }

  void push(Map<String, Object?> frame) => controller.add(jsonEncode(frame));
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('the socket URL keeps the relay path and switches the scheme', () {
    expect(
      TofaEvents.socketUrl('https://cloud.example.com/servers/s1/relay').toString(),
      'wss://cloud.example.com/servers/s1/relay/api/v1/ws',
    );
    expect(TofaEvents.socketUrl('http://192.168.1.5:33333').toString(), 'ws://192.168.1.5:33333/api/v1/ws');
  });

  group('watcher', () {
    late List<_FakeConnection> connections;
    late List<HomeWatchStateSignal> signals;
    late List<Map<String, String>> headersSeen;

    TofaHomeEventsWatcher watcher({bool? supported = true}) => TofaHomeEventsWatcher(
      url: Uri.parse('wss://tofa.example.com/api/v1/ws'),
      profileId: 'p-1',
      token: () => 'acc-token',
      headers: () => {'X-Profile-Id': 'p-1'},
      connect: (url, headers) async {
        headersSeen.add(headers);
        final c = _FakeConnection();
        connections.add(c);
        return c;
      },
      onSignal: signals.add,
      supported: () async => supported,
      initialBackoff: Duration.zero,
      maxBackoff: Duration.zero,
    );

    setUp(() {
      connections = [];
      signals = [];
      headersSeen = [];
    });

    test("signs in with the token frame, then reports this profile's changes", () async {
      final w = watcher()..start();
      await _settle();
      final c = connections.single;
      expect(jsonDecode(c.sent.single), {'type': 'auth', 'token': 'acc-token'});
      expect(headersSeen.single.containsKey('Authorization'), isFalse);
      c.push({'type': 'WatchStateChanged', 'profile_id': 'p-1', 'change': 'watched'});
      await _settle();
      expect(signals, isEmpty, reason: 'nothing counts before auth_ok');
      c.push({'type': 'auth_ok'});
      c.push({'type': 'WatchStateChanged', 'profile_id': 'p-2', 'change': 'watched'});
      c.push({'type': 'WatchStateChanged', 'profile_id': 'p-1', 'change': 'watched'});
      c.push({'type': 'StreamProgress', 'session_id': 's'});
      c.push({'type': 'EventsMissed', 'missed': 3});
      await _settle();
      expect(signals, [HomeWatchStateSignal.changed, HomeWatchStateSignal.changed]);
      expect(w.isLive, isTrue);

      // A drop reconnects and catches up once signed in again.
      await c.controller.close();
      await _settle();
      final again = connections.last;
      expect(connections, hasLength(2));
      again.push({'type': 'auth_ok'});
      await _settle();
      expect(signals.last, HomeWatchStateSignal.reconnected);
      w.stop();
      await _settle();
      expect(again.closed, isTrue);
    });

    test('a refused sign-in or a server without the event falls back to checks', () async {
      final refused = watcher()..start();
      await _settle();
      connections.single.push({'error': 'unauthorized'});
      await _settle();
      expect(refused.isPollOnly, isTrue);
      expect(connections, hasLength(1), reason: 'no retry loop against a refusing server');
      refused.stop();

      final unsupported = watcher(supported: false)..start();
      await _settle();
      expect(unsupported.isPollOnly, isTrue);
      expect(connections, hasLength(1));
      unsupported.stop();
    });
  });

  test('a client watches through its connector and reads the capability once', () async {
    final fake = FakeTofa();
    fake.on(
      'GET',
      '/api/v1/system/info',
      (_) => jsonResponse({
        'version': '0.14.0',
        'capabilities': ['ws.watch_state_changed'],
      }),
    );
    final seen = <Uri>[];
    final c =
        TofaClient.forTesting(
            tofaConnection(),
            headers: const TofaClientHeaders(clientVersion: '1.0', platform: 'android', deviceName: 'Test device'),
            httpClient: fake.client,
          )
          ..eventsConnector = (url, headers) async {
            seen.add(url);
            return null;
          };
    final watch = c.watchHomeWatchState((_) {});
    expect(watch, isNotNull);
    await _settle();
    watch!.stop();
    expect(seen.single.path, '/api/v1/ws');
    expect(fake.to('GET', '/api/v1/system/info'), hasLength(1));
    expect(c.lastHomeReadIncomplete, isFalse);
  });
}
