import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/silo/silo_live_subtitles.dart';

String _event(String name, Map<String, Object?> payload) =>
    jsonEncode({'type': 'event', 'session_id': 'sess-1', 'name': name, 'payload': payload});

void main() {
  group('cue track', () {
    test('keeps playhead-first batches in time order and finds the line on screen', () {
      final track = SiloLiveCueTrack();
      // The server translates from the playhead (100 s), then wraps to the start.
      track.addAll(const [SiloLiveCue(start: 100, end: 102, text: 'C'), SiloLiveCue(start: 103, end: 105, text: 'D')]);
      track.addAll(const [SiloLiveCue(start: 1, end: 3, text: 'A'), SiloLiveCue(start: 50, end: 52, text: 'B')]);
      expect(track.length, 4);
      expect(track.textAt(1.5), 'A');
      expect(track.textAt(51), 'B');
      expect(track.textAt(101), 'C');
      expect(track.textAt(104.9), 'D');
      expect(track.textAt(102.5), isNull);
      expect(track.textAt(0), isNull);
      expect(track.textAt(200), isNull);
    });

    test('overlapping cues show together and a repeated batch adds nothing', () {
      final track = SiloLiveCueTrack();
      const batch = [SiloLiveCue(start: 10, end: 14, text: 'first'), SiloLiveCue(start: 12, end: 13, text: 'second')];
      expect(track.addAll(batch), 2);
      expect(track.addAll(batch), 0);
      expect(track.textAt(12.5), 'first\nsecond');
      expect(track.textAt(13.5), 'first');
    });

    test('malformed cues are dropped and long text is cut', () {
      expect(SiloLiveCue.fromJson({'start': 5, 'end': 4, 'text': 'x'}), isNull);
      expect(SiloLiveCue.fromJson({'start': 1, 'end': 2, 'text': '  '}), isNull);
      expect(SiloLiveCue.fromJson({'start': -1, 'end': 2, 'text': 'x'}), isNull);
      expect(SiloLiveCue.fromJson({'start': 1, 'end': 2}), isNull);
      final long = SiloLiveCue.fromJson({'start': 1, 'end': 2, 'text': 'a' * 900})!;
      expect(long.text.length, SiloLiveCue.maxTextLength);
    });
  });

  group('events', () {
    test('parses the four live translation events', () {
      final started = SiloLiveSubtitleEvent.parse(
        _event('subtitle_translation_started', {'file_id': 42, 'job_id': 7, 'track_key': 'k', 'total_cues': 900}),
      );
      expect(started, isA<SiloLiveStarted>().having((e) => e.totalCues, 'totalCues', 900));
      expect(started!.jobId, '7');
      expect(started.fileId, '42');

      final cues = SiloLiveSubtitleEvent.parse(
        _event('subtitle_translation_cues', {
          'file_id': 42,
          'job_id': 7,
          'track_key': 'k',
          'cues': [
            {'start': 1.0, 'end': 2.0, 'text': 'Bonjour'},
            {'start': 'bad'},
          ],
          'done': 40,
          'total': 900,
        }),
      );
      expect(cues, isA<SiloLiveCues>().having((e) => e.cues.single.text, 'text', 'Bonjour'));

      final done = SiloLiveSubtitleEvent.parse(
        _event('subtitle_translation_completed', {'file_id': 42, 'job_id': 7, 'track_key': 'k', 'subtitle_id': 11}),
      );
      expect(done, isA<SiloLiveCompleted>().having((e) => e.subtitleId, 'subtitleId', '11'));

      final failed = SiloLiveSubtitleEvent.parse(
        _event('subtitle_translation_failed', {'file_id': 42, 'job_id': 7, 'track_key': 'k', 'message': 'boom'}),
      );
      expect(failed, isA<SiloLiveFailed>().having((e) => e.message, 'message', 'boom'));
    });

    test('ignores commands, other events and junk', () {
      expect(SiloLiveSubtitleEvent.parse(jsonEncode({'type': 'command', 'command_id': 'c', 'name': 'pause'})), isNull);
      expect(SiloLiveSubtitleEvent.parse(_event('markers_updated', {'file_id': 42, 'job_id': 1})), isNull);
      expect(SiloLiveSubtitleEvent.parse('not json'), isNull);
      expect(SiloLiveSubtitleEvent.parse(_event('subtitle_translation_cues', {'cues': []})), isNull);
    });
  });

  test('socket URL keeps a path prefix and switches the scheme', () {
    expect(
      SiloLiveSubtitleSocket.socketUrl('https://silo.example.com', '/api/v2/playback/sessions/s/control/ws').toString(),
      'wss://silo.example.com/api/v2/playback/sessions/s/control/ws',
    );
    expect(
      SiloLiveSubtitleSocket.socketUrl('http://10.0.0.2:8097/silo/', '/api/v2/x').toString(),
      'ws://10.0.0.2:8097/silo/api/v2/x',
    );
  });

  group('socket', () {
    late HttpServer server;
    late List<String> offered;
    late List<String> received;
    late Completer<WebSocket> serverSide;

    setUp(() async {
      offered = [];
      received = [];
      serverSide = Completer();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        offered = (request.headers['sec-websocket-protocol'] ?? const [])
            .expand((v) => v.split(','))
            .map((v) => v.trim())
            .toList();
        final ws = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (_) => SiloLiveSubtitleSocket.protocol,
        );
        ws.listen((m) => received.add(m as String));
        serverSide.complete(ws);
      });
    });

    tearDown(() => server.close(force: true));

    Uri url() => Uri.parse('ws://127.0.0.1:${server.port}/api/v2/playback/sessions/sess-1/control/ws');

    test('offers the ticket as a subprotocol, says hello and forwards live events', () async {
      final socket = await SiloLiveSubtitleSocket.connect(
        url: url(),
        ticket: 'tkt',
        sessionId: 'sess-1',
        clientVersion: '2.25.18',
      );
      expect(socket, isNotNull);
      expect(offered, ['silo.playback-control.v2', 'silo.ticket.tkt']);
      final ws = await serverSide.future;
      addTearDown(ws.close);
      final events = <SiloLiveSubtitleEvent>[];
      socket!.events.listen(events.add);
      ws.add(jsonEncode({'type': 'command', 'command_id': 'c1', 'session_id': 'sess-1', 'name': 'pause'}));
      ws.add(
        _event('subtitle_translation_cues', {
          'file_id': 42,
          'job_id': 7,
          'track_key': 'k',
          'cues': [
            {'start': 1, 'end': 2, 'text': 'Hola'},
          ],
          'done': 1,
          'total': 2,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events.single, isA<SiloLiveCues>());
      final hello = jsonDecode(received.first) as Map;
      expect(hello['type'], 'hello');
      expect(hello['session_id'], 'sess-1');
      expect((hello['capabilities'] as Map)['commands'], isEmpty);
      // The command was not answered.
      expect(received, hasLength(1));
      await socket.close();
      expect(socket.isClosed, isTrue);
    });

    test('a closed server reports done', () async {
      final socket = await SiloLiveSubtitleSocket.connect(
        url: url(),
        ticket: 'tkt',
        sessionId: 'sess-1',
        clientVersion: '1',
      );
      final ws = await serverSide.future;
      await ws.close();
      await socket!.done.timeout(const Duration(seconds: 2));
      expect(socket.isClosed, isTrue);
    });
  });
}
