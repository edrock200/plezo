import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'silo_pairing_protocol.dart';

/// One pairing connection carrying decoded messages both ways. The receiver
/// state machine runs over this, so tests can use an in-memory fake.
abstract interface class SiloPairingTransport {
  /// Inbound messages. Done on EOF or [close]; an error for a frame or
  /// message that breaks the wire schema. Listen once.
  Stream<SiloPairingMessage> get incoming;

  /// Send one message as one frame. Throws once the connection is closed.
  Future<void> send(SiloPairingMessage message);

  /// Close the connection. Idempotent.
  Future<void> close();
}

/// [SiloPairingTransport] over a byte stream and sink: on Android the
/// plaintext side of the TLS-PSK bridge (`SiloPairingChannel.kt`), in tests a
/// plain loopback socket.
class SiloPairingStreamTransport implements SiloPairingTransport {
  SiloPairingStreamTransport(Stream<List<int>> input, this._sink, {this._onClose}) {
    final buffer = SiloPairingFrameBuffer();
    // `map` first: a Socket is a Stream<Uint8List>, which a
    // List<int> transformer cannot take as is.
    _incoming = input
        .map<List<int>>((bytes) => bytes)
        .transform(
          StreamTransformer<List<int>, SiloPairingMessage>.fromHandlers(
            handleData: (bytes, sink) {
              try {
                for (final payload in buffer.append(bytes)) {
                  sink.add(SiloPairingMessage.decode(utf8.decode(payload)));
                }
              } catch (e, st) {
                // A broken frame ends the session: nothing after it can be trusted.
                sink.addError(e, st);
                sink.close();
                unawaited(close());
              }
            },
          ),
        );
  }

  /// A connected [Socket] (Nagle off: frames are small and interactive).
  factory SiloPairingStreamTransport.socket(Socket socket, {Stream<List<int>>? input}) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    return SiloPairingStreamTransport(input ?? socket, socket, onClose: socket.destroy);
  }

  final IOSink _sink;
  final void Function()? _onClose;
  late final Stream<SiloPairingMessage> _incoming;
  bool _closed = false;
  Future<void> _writes = Future.value();

  @override
  Stream<SiloPairingMessage> get incoming => _incoming;

  bool get isClosed => _closed;

  @override
  Future<void> send(SiloPairingMessage message) {
    if (_closed) return Future.error(const SocketException('Pairing connection closed'));
    final Uint8List frame = message.toFrame();
    // Serialised: two sends never interleave their bytes.
    final write = _writes.then((_) async {
      if (_closed) throw const SocketException('Pairing connection closed');
      _sink.add(frame);
      await _sink.flush();
    });
    _writes = write.catchError((_) {});
    return write;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _sink.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Already gone.
    }
    _onClose?.call();
  }
}
