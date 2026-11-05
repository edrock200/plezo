import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:plezy/services/silo/pairing/silo_pairing_host.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_protocol.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_receiver.dart';
import 'package:plezy/services/silo/pairing/silo_pairing_transport.dart';
import 'package:plezy/services/silo/silo_auth_service.dart';

/// Silo's phone signing a TV in to several accounts in one session (Silo
/// Android #810, `CompanionPairingCoordinator`): pushes each of [pushes]
/// after the previous one's `serverResult`, calls [onPushed] after each push
/// (the TV person allowing it, say), [approve] for each `deviceStarted` (the
/// phone approving that code on the server), and sends `done` at the end
/// unless [sendDone] is false. Returns every `serverResult`, in order.
Future<List<SiloPairingServerResult>> siloPhoneSignInAccounts({
  required void Function(SiloPairingMessage message) send,
  required Future<SiloPairingMessage?> Function() next,
  required List<SiloPairingPushServer> pushes,
  required FutureOr<void> Function(int index, SiloPairingDeviceStarted started) approve,
  FutureOr<void> Function(int index)? onPushed,
  bool sendDone = true,
}) async {
  final results = <SiloPairingServerResult>[];
  for (final (i, push) in pushes.indexed) {
    send(push);
    await onPushed?.call(i);
    while (true) {
      final message = await next();
      if (message == null) throw StateError('the TV ended the session during push $i');
      if (message is SiloPairingDeviceStarted) {
        await approve(i, message);
      } else if (message is SiloPairingServerResult) {
        results.add(message);
        break;
      }
    }
  }
  if (sendDone) send(const SiloPairingDone());
  return results;
}

/// Plays Silo's phone app (`CompanionPairingCoordinator`) against a
/// [SiloPairingHost]: dials the loopback bridge the platform relays to, sends
/// the bridge secret (what `SiloPairingChannel.kt` writes after the TLS-PSK
/// handshake), then speaks the protocol in frames.
class SiloPairingPhone {
  SiloPairingPhone._(this._socket, this._transport) : _queue = MessageQueue(_transport.incoming);

  final Socket _socket;
  final SiloPairingStreamTransport _transport;
  final MessageQueue _queue;

  static Future<SiloPairingPhone> connect(int port, Uint8List secret) async {
    // Closed by [close], through the transport.
    // ignore: close_sinks
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    socket.add(secret);
    await socket.flush();
    return SiloPairingPhone._(socket, SiloPairingStreamTransport.socket(socket));
  }

  /// The phone's connection to [host] (secret included).
  static Future<SiloPairingPhone> dial(SiloPairingHost host) => connect(host.bridgePort!, host.bridgeSecret!);

  Future<void> send(SiloPairingMessage message) => _transport.send(message);

  /// [siloPhoneSignInAccounts] over this connection.
  Future<List<SiloPairingServerResult>> signInAccounts(
    List<SiloPairingPushServer> pushes, {
    required FutureOr<void> Function(int index, SiloPairingDeviceStarted started) approve,
    FutureOr<void> Function(int index)? onPushed,
    bool sendDone = true,
  }) => siloPhoneSignInAccounts(
    send: (m) => unawaited(send(m)),
    next: _queue.next,
    pushes: pushes,
    approve: approve,
    onPushed: onPushed,
    sendDone: sendDone,
  );

  /// The next message from the TV, which must be a [T].
  Future<T> next<T extends SiloPairingMessage>({Duration timeout = const Duration(seconds: 5)}) async {
    final message = await _queue.next().timeout(timeout);
    if (message is! T) throw StateError('expected $T, got ${message?.encode() ?? 'the end'}');
    return message;
  }

  /// True once the TV closed the connection (any message left unread first).
  Future<bool> closedByTv({Duration timeout = const Duration(seconds: 5)}) async {
    try {
      while (true) {
        if (await _queue.next().timeout(timeout) == null) return true;
      }
    } on TimeoutException {
      return false;
    }
  }

  Future<void> close() async {
    await _transport.close();
    _socket.destroy();
  }
}

/// An in-memory [SiloPairingTransport] for the state machine tests.
class FakePairingTransport implements SiloPairingTransport {
  final _toTv = StreamController<SiloPairingMessage>();
  final _toPhone = StreamController<SiloPairingMessage>();
  late final MessageQueue _phoneQueue = MessageQueue(_toPhone.stream);
  bool closed = false;

  /// Everything the TV sent, in order.
  final List<SiloPairingMessage> sent = [];

  @override
  Stream<SiloPairingMessage> get incoming => _toTv.stream;

  @override
  Future<void> send(SiloPairingMessage message) async {
    if (closed) throw const SocketException('closed');
    sent.add(message);
    _toPhone.add(message);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    unawaited(_toTv.close());
    unawaited(_toPhone.close());
  }

  /// The phone sends [message].
  void phoneSends(SiloPairingMessage message) {
    if (!closed) _toTv.add(message);
  }

  /// The phone hangs up.
  void phoneHangsUp() => close();

  Future<T> next<T extends SiloPairingMessage>({Duration timeout = const Duration(seconds: 5)}) async {
    final message = await _phoneQueue.next().timeout(timeout);
    if (message is! T) throw StateError('expected $T, got ${message?.encode() ?? 'the end'}');
    return message;
  }

  /// [siloPhoneSignInAccounts] over this transport.
  Future<List<SiloPairingServerResult>> signInAccounts(
    List<SiloPairingPushServer> pushes, {
    required FutureOr<void> Function(int index, SiloPairingDeviceStarted started) approve,
    FutureOr<void> Function(int index)? onPushed,
    bool sendDone = true,
  }) => siloPhoneSignInAccounts(
    send: phoneSends,
    next: _phoneQueue.next,
    pushes: pushes,
    approve: approve,
    onPushed: onPushed,
    sendDone: sendDone,
  );
}

/// Messages in arrival order; [next] yields null once the stream ended.
class MessageQueue {
  MessageQueue(Stream<SiloPairingMessage> stream) {
    stream.listen(_push, onError: (Object _) => _end(), onDone: _end);
  }

  final List<SiloPairingMessage> _buffer = [];
  final List<Completer<SiloPairingMessage?>> _waiting = [];
  bool _ended = false;

  void _push(SiloPairingMessage message) {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete(message);
    } else {
      _buffer.add(message);
    }
  }

  void _end() {
    _ended = true;
    for (final waiter in _waiting) {
      waiter.complete(null);
    }
    _waiting.clear();
  }

  Future<SiloPairingMessage?> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    if (_ended) return Future.value(null);
    final waiter = Completer<SiloPairingMessage?>();
    _waiting.add(waiter);
    return waiter.future;
  }
}

/// A scripted sign-in screen for the receiver. A code's outcome comes from
/// [outcomesByCode] when scripted there, else [outcomeCompleter].
class FakePairingPort implements SiloPairingSignInPort {
  final List<SiloPairingTarget> setupTargets = [];

  /// The session binding handed to each [startSetup].
  final List<SiloDeviceLoginBinding?> setupBindings = [];

  /// Codes for successive [startSetup] calls; [code] once they run out.
  final List<SiloPairingCode> nextCodes = [];
  final Map<String, Completer<SiloPairingFailureCode?>> outcomesByCode = {};
  final List<String?> abandoned = [];
  Object? startError;
  SiloPairingCode code = const SiloPairingCode(deviceCode: 'dev-1', userCode: '48217731', matchCode: 'brave-otter');
  SiloPairingCode? screenCode = const SiloPairingCode(
    deviceCode: 'dev-9',
    userCode: '11112222',
    matchCode: 'calm-heron',
  );
  Completer<SiloPairingFailureCode?> outcomeCompleter = Completer();
  final List<String> outcomeCodes = [];

  @override
  Future<SiloPairingCode> startSetup(SiloPairingTarget target, {SiloDeviceLoginBinding? binding}) async {
    setupTargets.add(target);
    setupBindings.add(binding);
    final error = startError;
    if (error != null) throw error;
    return nextCodes.isNotEmpty ? nextCodes.removeAt(0) : code;
  }

  @override
  Future<SiloPairingCode?> currentCode() async => screenCode;

  @override
  Future<SiloPairingFailureCode?> outcome(String deviceCode) {
    outcomeCodes.add(deviceCode);
    return (outcomesByCode[deviceCode] ?? outcomeCompleter).future;
  }

  @override
  void abandonSetup(String? deviceCode) => abandoned.add(deviceCode);
}

/// An advertiser that records what would be published.
class FakePairingAdvertiser implements SiloPairingAdvertiser {
  final List<Map<String, String>> started = [];
  int stops = 0;

  @override
  Future<bool> start({
    required String serviceName,
    required Map<String, String> txt,
    required int bridgePort,
    required Uint8List bridgeSecret,
  }) async {
    started.add({...txt, '_service': serviceName});
    return true;
  }

  @override
  Future<void> stop() async => stops++;
}
