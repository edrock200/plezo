import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../../utils/app_logger.dart';
import 'silo_pairing_protocol.dart';
import 'silo_pairing_receiver.dart';
import 'silo_pairing_transport.dart';

/// Publishes the pairing service on the LAN and terminates its TLS.
abstract interface class SiloPairingAdvertiser {
  /// Advertise `_silopair._tcp` as [serviceName] with [txt] and accept phone
  /// connections; each accepted connection's plaintext is relayed to
  /// `127.0.0.1:bridgePort`, opened by writing [bridgeSecret] first. Replaces
  /// an earlier advertisement. False when nothing could be published.
  Future<bool> start({
    required String serviceName,
    required Map<String, String> txt,
    required int bridgePort,
    required Uint8List bridgeSecret,
  });

  /// Stop advertising and accepting. Connections already relayed keep going
  /// until the Dart side closes them.
  Future<void> stop();
}

/// Android: `com.plezy/silo_pairing` (`SiloPairingChannel.kt`), which
/// registers the service with `NsdManager` and runs the TLS-PSK handshake
/// Silo's phone app expects from an Android TV (BouncyCastle, PSK
/// `silo-companion-pairing-v1`, identity `silo-pairing`).
class MethodChannelSiloPairingAdvertiser implements SiloPairingAdvertiser {
  static const _channel = MethodChannel('com.plezy/silo_pairing');

  @override
  Future<bool> start({
    required String serviceName,
    required Map<String, String> txt,
    required int bridgePort,
    required Uint8List bridgeSecret,
  }) async {
    try {
      final port = await _channel.invokeMethod<int>('start', {
        'serviceName': serviceName,
        'serviceType': SiloPairingProtocol.serviceType,
        'txt': txt,
        'bridgePort': bridgePort,
        'bridgeSecret': bridgeSecret,
      });
      appLogger.i('[silo-pair] advertising on port $port st=${txt['st']}');
      return port != null && port > 0;
    } on PlatformException catch (e) {
      appLogger.w('[silo-pair] could not advertise: ${e.code}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      appLogger.d('[silo-pair] stop failed: ${e.code}');
    } on MissingPluginException {
      // Nothing was started.
    }
  }
}

/// The pairing receiver's network side: a loopback listener for the
/// platform's relayed connections, plus the advertisement. One phone at a
/// time; the advertisement changes only between sessions.
class SiloPairingHost {
  SiloPairingHost({
    required this.receiver,
    required this.advertiser,
    required this.serviceName,
    required this.deviceId,
    this.secretTimeout = const Duration(seconds: 5),
  });

  /// Whether phones can sign this platform in: Android only (the TLS-PSK
  /// listener and NSD registration live in `SiloPairingChannel.kt`).
  static bool get supported => Platform.isAndroid;

  static const secretLength = 32;

  final SiloPairingReceiver receiver;
  final SiloPairingAdvertiser? advertiser;
  final String serviceName;
  final String deviceId;
  final Duration secretTimeout;

  ServerSocket? _server;
  Uint8List? _secret;
  SiloPairingAdvertisement? _wanted;
  SiloPairingAdvertisement? _published;
  Future<void> _applying = Future.value();
  bool _disposed = false;

  /// The loopback port relayed connections arrive at (tests dial it).
  int? get bridgePort => _server?.port;

  /// The one-time secret a relayed connection opens with (tests send it).
  Uint8List? get bridgeSecret => _secret;

  /// Advertise [advertisement], or stop advertising with null. While a phone
  /// holds a session the change waits for that session to end.
  Future<void> advertise(SiloPairingAdvertisement? advertisement) {
    _wanted = advertisement;
    return _apply();
  }

  Future<void> _apply() {
    final next = _applying.then((_) => _applyNow()).catchError((Object e, StackTrace st) {
      appLogger.w('[silo-pair] advertisement update failed', error: e, stackTrace: st);
    });
    _applying = next;
    return next;
  }

  Future<void> _applyNow() async {
    if (_disposed) return;
    if (receiver.hasSession) return; // re-applied when the session ends
    final wanted = _wanted;
    if (wanted == _published && (wanted == null || _server != null)) return;
    if (wanted == null) {
      _published = null;
      receiver.setIdle();
      await advertiser?.stop();
      return;
    }
    await _ensureServer();
    receiver.advertisement = wanted;
    final txt = {
      ...wanted.txt(),
      'name': serviceName,
      'id': deviceId,
      // A fresh nonce per advertisement, as Silo's TVs send.
      'sid': const Uuid().v4(),
    };
    final ok =
        await advertiser?.start(
          serviceName: serviceName,
          txt: txt,
          bridgePort: _server!.port,
          bridgeSecret: _secret!,
        ) ??
        true;
    if (_disposed) return;
    _published = wanted;
    if (ok) receiver.setAdvertising();
  }

  Future<void> _ensureServer() async {
    if (_server != null) return;
    final random = Random.secure();
    _secret = Uint8List.fromList(List.generate(secretLength, (_) => random.nextInt(256)));
    final server = _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_onConnection, onError: (Object e) => appLogger.d('[silo-pair] listener error', error: e));
  }

  void _onConnection(Socket socket) {
    if (_disposed || receiver.hasSession) {
      socket.destroy();
      return;
    }
    unawaited(_serve(socket));
  }

  /// Read the secret, then hand the rest of the stream to the receiver.
  Future<void> _serve(Socket socket) async {
    final secret = _secret;
    if (secret == null) {
      socket.destroy();
      return;
    }
    final rest = StreamController<List<int>>();
    final opened = Completer<bool>();
    final head = BytesBuilder();
    late final StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (data) {
        if (opened.isCompleted) {
          rest.add(data);
          return;
        }
        head.add(data);
        if (head.length < secretLength) return;
        final bytes = head.takeBytes();
        var diff = 0;
        for (var i = 0; i < secretLength; i++) {
          diff |= bytes[i] ^ secret[i];
        }
        if (diff != 0) {
          opened.complete(false);
          return;
        }
        opened.complete(true);
        if (bytes.length > secretLength) rest.add(Uint8List.sublistView(bytes, secretLength));
      },
      onError: (Object e) {
        if (!opened.isCompleted) opened.complete(false);
        rest.addError(e);
      },
      onDone: () {
        if (!opened.isCompleted) opened.complete(false);
        rest.close();
      },
      cancelOnError: true,
    );
    rest.onCancel = () => sub.cancel();
    final ok = await opened.future.timeout(secretTimeout, onTimeout: () => false);
    if (!ok || _disposed || receiver.hasSession) {
      await sub.cancel();
      socket.destroy();
      return;
    }
    await receiver.run(SiloPairingStreamTransport.socket(socket, input: rest.stream));
    // The session is over: publish what the screen wants now.
    await _apply();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await advertiser?.stop();
    await receiver.dispose();
    await _server?.close();
    _server = null;
  }
}
