import 'dart:convert';
import 'dart:typed_data';

/// Sign in from a phone ("companion pairing"): the LAN protocol Silo's phone
/// app speaks to a TV on its server-setup or sign-in screen. A port of
/// silo-android `shared/.../pairing/PairingProtocol.kt`, `PairingFrame.kt`
/// and `PairingMessage.kt` (byte-compatible with silo-apple).
///
/// No token ever crosses the LAN: the phone approves the TV's device code on
/// the server, and the server hands the TV its tokens over HTTPS.
abstract final class SiloPairingProtocol {
  /// Wire protocol version (`v` in every message and the TXT record).
  static const version = 1;

  /// The DNS-SD type an Apple TV or Android TV advertises. Silo's phone app
  /// dials it over TLS-PSK (see `SiloPairingChannel.kt`); the Roku's
  /// `_silopair-roku._tcp` is plain TCP and would make the phone treat this
  /// device as a Roku (one server, "Roku" in its copy).
  static const serviceType = '_silopair._tcp';

  /// Largest frame encoded or accepted (1 MiB, as Silo's apps).
  static const maxFrameBytes = 1 << 20;

  /// A DNS-SD instance name holds at most 63 UTF-8 bytes (Silo's `TvDeviceName`).
  static const maxServiceNameBytes = 63;

  /// [name] trimmed and cut to [maxServiceNameBytes] UTF-8 bytes without
  /// splitting a character; [fallback] when nothing is left.
  static String fittedServiceName(String? name, {String fallback = 'Plezilo'}) {
    final trimmed = (name ?? '').trim();
    var bytes = 0;
    final out = StringBuffer();
    for (final rune in trimmed.runes) {
      final size = utf8.encode(String.fromCharCode(rune)).length;
      if (bytes + size > maxServiceNameBytes) break;
      bytes += size;
      out.writeCharCode(rune);
    }
    final fitted = out.toString().trimRight();
    return fitted.isEmpty ? fallback : fitted;
  }
}

/// A frame's declared length is over [SiloPairingProtocol.maxFrameBytes].
class SiloPairingFrameTooLargeException implements Exception {
  final int length;
  const SiloPairingFrameTooLargeException(this.length);

  @override
  String toString() => 'Pairing frame too large: $length bytes (max ${SiloPairingProtocol.maxFrameBytes})';
}

/// A message does not match the wire schema.
class SiloPairingMessageException implements Exception {
  final String message;
  const SiloPairingMessageException(this.message);

  @override
  String toString() => 'SiloPairingMessageException: $message';
}

/// Length-prefixed framing: a 4-byte big-endian unsigned length, then that
/// many bytes of UTF-8 JSON.
abstract final class SiloPairingFrame {
  static Uint8List encode(List<int> payload) {
    if (payload.length > SiloPairingProtocol.maxFrameBytes) {
      throw SiloPairingFrameTooLargeException(payload.length);
    }
    final out = Uint8List(4 + payload.length);
    ByteData.sublistView(out).setUint32(0, payload.length, Endian.big);
    out.setRange(4, out.length, payload);
    return out;
  }
}

/// Collects bytes from a stream and yields each complete frame payload.
/// One per connection; not shared.
class SiloPairingFrameBuffer {
  final BytesBuilder _pending = BytesBuilder(copy: false);
  Uint8List _buffer = Uint8List(0);

  /// Append [bytes]; returns every payload now complete (maybe none). Throws
  /// [SiloPairingFrameTooLargeException] when a declared length is too big.
  List<Uint8List> append(List<int> bytes) {
    if (bytes.isEmpty) return const [];
    _pending
      ..add(_buffer)
      ..add(bytes);
    _buffer = _pending.takeBytes();
    final payloads = <Uint8List>[];
    var offset = 0;
    while (_buffer.length - offset >= 4) {
      // Unsigned: a high-bit length must be refused, not wrap negative.
      final length = ByteData.sublistView(_buffer, offset, offset + 4).getUint32(0, Endian.big);
      if (length > SiloPairingProtocol.maxFrameBytes) throw SiloPairingFrameTooLargeException(length);
      if (_buffer.length - offset < 4 + length) break;
      payloads.add(Uint8List.fromList(_buffer.sublist(offset + 4, offset + 4 + length)));
      offset += 4 + length;
    }
    if (offset > 0) _buffer = Uint8List.fromList(_buffer.sublist(offset));
    return payloads;
  }

  /// Bytes held for an incomplete frame.
  int get pendingBytes => _buffer.length;
}

/// The receiver's advertised state (TXT `st` and hello `state`).
enum SiloPairingReceiverState {
  /// No server yet: the phone chooses which server to push.
  setup('setup'),

  /// On the sign-in screen of one server (TXT `srv`): the phone pushes only that one.
  login('login');

  const SiloPairingReceiverState(this.wire);
  final String wire;

  static SiloPairingReceiverState fromWire(String value) => values.firstWhere(
    (s) => s.wire == value,
    orElse: () => throw SiloPairingMessageException('Unknown receiver state: $value'),
  );
}

enum SiloPairingServerStatus {
  signedIn('signedIn'),
  failed('failed');

  const SiloPairingServerStatus(this.wire);
  final String wire;

  static SiloPairingServerStatus fromWire(String value) => values.firstWhere(
    (s) => s.wire == value,
    orElse: () => throw SiloPairingMessageException('Unknown server status: $value'),
  );
}

/// Why a pushed server failed (`serverResult.error`). Unknown values read as
/// [authFailed], the legacy catch-all.
enum SiloPairingFailureCode {
  authFailed('auth_failed'),
  denied('denied'),
  expired('expired'),
  unreachable('unreachable'),
  identityMismatch('identity_mismatch'),
  updateRequired('update_required');

  const SiloPairingFailureCode(this.wire);
  final String wire;

  static SiloPairingFailureCode fromWire(String? value) =>
      values.firstWhere((c) => c.wire == value, orElse: () => SiloPairingFailureCode.authFailed);
}

/// The URL as both platforms compare addresses: trimmed, no trailing slash.
String normalizeSiloPairingUrl(String url) => url.trim().replaceFirst(RegExp(r'/+$'), '');

enum SiloPairingEndpointKind {
  public('public'),
  provider('provider');

  const SiloPairingEndpointKind(this.wire);
  final String wire;

  /// Unknown kinds read as public (silo-apple parity).
  static SiloPairingEndpointKind fromWire(String? value) =>
      values.firstWhere((k) => k.wire == value, orElse: () => SiloPairingEndpointKind.public);
}

/// Another address the pushed deployment offers (`pushServer.endpoints[]`).
class SiloPairingEndpoint {
  final String url;
  final SiloPairingEndpointKind kind;

  /// Provider slug for [SiloPairingEndpointKind.provider], e.g. `tailscale`.
  final String? provider;

  /// Provider display name from its manifest.
  final String? displayName;

  SiloPairingEndpoint({required String url, required this.kind, this.provider, this.displayName})
    : url = normalizeSiloPairingUrl(url);

  Map<String, Object?> toJson() => {'url': url, 'kind': kind.wire, 'provider': ?provider, 'displayName': ?displayName};

  @override
  bool operator ==(Object other) =>
      other is SiloPairingEndpoint &&
      other.url == url &&
      other.kind == kind &&
      other.provider == provider &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(url, kind, provider, displayName);
}

/// One message on the wire: a JSON object with `type` and `v`, the fields
/// flattened beside them. Optional fields are omitted when null.
sealed class SiloPairingMessage {
  const SiloPairingMessage();

  String get type;
  Map<String, Object?> fields();

  Map<String, Object?> toJson() => {'type': type, 'v': SiloPairingProtocol.version, ...fields()};

  String encode() => jsonEncode(toJson());

  /// The message as one length-prefixed frame.
  Uint8List toFrame() => SiloPairingFrame.encode(utf8.encode(encode()));

  /// Decode one frame payload. Throws [SiloPairingMessageException] for a
  /// payload that is not a JSON object or misses a required field. A `type`
  /// this build does not know decodes to [SiloPairingUnknownMessage] so a
  /// newer phone's extra message does not end the session.
  static SiloPairingMessage decode(String payload) {
    final Object? json;
    try {
      json = jsonDecode(payload);
    } on FormatException catch (e) {
      throw SiloPairingMessageException('Not JSON: ${e.message}');
    }
    if (json is! Map) throw const SiloPairingMessageException('Pairing message must be a JSON object');
    final obj = json.cast<String, Object?>();
    final type = _requireString(obj, 'type');
    return switch (type) {
      'hello' => SiloPairingHello(
        tvName: _requireString(obj, 'tvName'),
        tvDeviceId: _requireString(obj, 'tvDeviceId'),
        state: SiloPairingReceiverState.fromWire(_requireString(obj, 'state')),
        supportedVersions: _requireIntList(obj, 'supportedVersions'),
      ),
      'pushServer' => SiloPairingPushServer(
        serverUrl: _requireString(obj, 'serverURL'),
        serverName: _optionalString(obj, 'serverName'),
        serverIdentity: _optionalString(obj, 'serverIdentity'),
        endpoints: _endpoints(obj['endpoints']),
      ),
      'deviceStarted' => SiloPairingDeviceStarted(
        serverUrl: _requireString(obj, 'serverURL'),
        userCode: _requireString(obj, 'userCode'),
        matchCode: _requireString(obj, 'matchCode'),
      ),
      'serverResult' => SiloPairingServerResult(
        serverUrl: _requireString(obj, 'serverURL'),
        status: SiloPairingServerStatus.fromWire(_requireString(obj, 'status')),
        error: _optionalString(obj, 'error'),
      ),
      'done' => const SiloPairingDone(),
      'cancel' => SiloPairingCancel(_requireString(obj, 'reason')),
      _ => SiloPairingUnknownMessage(type),
    };
  }

  static String _requireString(Map<String, Object?> obj, String key) {
    final value = obj[key];
    if (value == null || value is Map || value is List) throw SiloPairingMessageException('Missing field: $key');
    return value.toString();
  }

  static String? _optionalString(Map<String, Object?> obj, String key) {
    final value = obj[key];
    if (value == null || value is Map || value is List) return null;
    return value.toString();
  }

  static List<int> _requireIntList(Map<String, Object?> obj, String key) {
    final value = obj[key];
    if (value is! List) throw SiloPairingMessageException('Missing field: $key');
    return [
      for (final v in value)
        if (v is int) v else throw SiloPairingMessageException('$key must hold integers'),
    ];
  }

  static List<SiloPairingEndpoint>? _endpoints(Object? value) {
    if (value is! List) return null;
    return [
      for (final e in value)
        if (e is Map)
          SiloPairingEndpoint(
            url: _requireString(e.cast<String, Object?>(), 'url'),
            kind: SiloPairingEndpointKind.fromWire(_requireString(e.cast<String, Object?>(), 'kind')),
            provider: _optionalString(e.cast<String, Object?>(), 'provider'),
            displayName: _optionalString(e.cast<String, Object?>(), 'displayName'),
          )
        else
          throw const SiloPairingMessageException('endpoints must hold objects'),
    ];
  }
}

/// TV → phone, first message once the connection opens.
class SiloPairingHello extends SiloPairingMessage {
  final String tvName;
  final String tvDeviceId;
  final SiloPairingReceiverState state;
  final List<int> supportedVersions;

  const SiloPairingHello({
    required this.tvName,
    required this.tvDeviceId,
    required this.state,
    this.supportedVersions = const [SiloPairingProtocol.version],
  });

  @override
  String get type => 'hello';

  @override
  Map<String, Object?> fields() => {
    'tvName': tvName,
    'tvDeviceId': tvDeviceId,
    'state': state.wire,
    'supportedVersions': supportedVersions,
  };
}

/// Phone → TV, one per chosen server. [serverIdentity] is the deployment
/// identity the phone verified at [serverUrl]; [endpoints] the other
/// addresses it offers. Older phones send neither.
class SiloPairingPushServer extends SiloPairingMessage {
  final String serverUrl;
  final String? serverName;
  final String? serverIdentity;
  final List<SiloPairingEndpoint>? endpoints;

  const SiloPairingPushServer({required this.serverUrl, this.serverName, this.serverIdentity, this.endpoints});

  /// What the TV calls the server: its name, else its address.
  String get displayName {
    final name = serverName?.trim();
    return name == null || name.isEmpty ? normalizeSiloPairingUrl(serverUrl) : name;
  }

  @override
  String get type => 'pushServer';

  @override
  Map<String, Object?> fields() => {
    'serverURL': serverUrl,
    'serverName': ?serverName,
    'serverIdentity': ?serverIdentity,
    if (endpoints case final list?) 'endpoints': [for (final e in list) e.toJson()],
  };
}

/// TV → phone: the TV started device sign-in for a pushed server. The phone
/// looks the code up on the server and refuses when the match codes differ.
class SiloPairingDeviceStarted extends SiloPairingMessage {
  final String serverUrl;
  final String userCode;
  final String matchCode;

  const SiloPairingDeviceStarted({required this.serverUrl, required this.userCode, required this.matchCode});

  @override
  String get type => 'deviceStarted';

  @override
  Map<String, Object?> fields() => {'serverURL': serverUrl, 'userCode': userCode, 'matchCode': matchCode};
}

/// TV → phone: a pushed server's outcome. [serverUrl] always echoes the
/// pushed address, whatever address the TV signed in at.
class SiloPairingServerResult extends SiloPairingMessage {
  final String serverUrl;
  final SiloPairingServerStatus status;
  final String? error;

  const SiloPairingServerResult({required this.serverUrl, required this.status, this.error});

  @override
  String get type => 'serverResult';

  @override
  Map<String, Object?> fields() => {'serverURL': serverUrl, 'status': status.wire, 'error': ?error};
}

/// Phone → TV: no more servers.
class SiloPairingDone extends SiloPairingMessage {
  const SiloPairingDone();

  @override
  String get type => 'done';

  @override
  Map<String, Object?> fields() => const {};
}

/// Either direction: abort. The TV sends `consent_denied` when its user
/// declines; the phone sends e.g. `match-code-mismatch` or `user-cancelled`.
class SiloPairingCancel extends SiloPairingMessage {
  final String reason;
  const SiloPairingCancel(this.reason);

  @override
  String get type => 'cancel';

  @override
  Map<String, Object?> fields() => {'reason': reason};
}

/// A message type this build does not know; ignored by the receiver.
class SiloPairingUnknownMessage extends SiloPairingMessage {
  @override
  final String type;
  const SiloPairingUnknownMessage(this.type);

  @override
  Map<String, Object?> fields() => const {};
}
