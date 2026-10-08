import 'dart:async';

import 'package:http/http.dart' as http;

import '../../connection/connection.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_server_http_client.dart';
import '../../utils/url_utils.dart';
import 'silo_api.dart';

/// What a reachable Silo server told us about itself before sign-in.
class SiloServerInfo {
  final String baseUrl;
  final String serverId;
  final String serverName;
  final String? serverVersion;

  /// Whether `/api/v2/auth/device/capability` says device-code sign-in works.
  final bool deviceLoginAvailable;

  /// Whether the server offers username/password sign-in.
  final bool passwordLoginAvailable;

  const SiloServerInfo({
    required this.baseUrl,
    required this.serverId,
    required this.serverName,
    this.serverVersion,
    this.deviceLoginAvailable = false,
    this.passwordLoginAvailable = true,
  });
}

/// The signed-in account, from `/auth/login`, the device poll or `/account/me`.
class SiloAccount {
  final String id;
  final String username;
  final bool isAdministrator;

  const SiloAccount({required this.id, required this.username, this.isAdministrator = false});

  static SiloAccount? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id == null) return null;
    return SiloAccount(
      id: id.toString(),
      username: (json['username'] as String?) ?? '',
      isAdministrator: json['role'] == 'admin',
    );
  }
}

/// One Silo profile from `GET /api/v2/profiles`.
class SiloProfile {
  final String id;
  final String name;
  final String? avatarUrl;
  final bool hasPin;
  final bool isChild;
  final bool isPrimary;

  const SiloProfile({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.hasPin = false,
    this.isChild = false,
    this.isPrimary = false,
  });

  static SiloProfile? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id == null) return null;
    final avatar = json['avatar_url'];
    return SiloProfile(
      id: id.toString(),
      name: (json['name'] as String?) ?? '',
      avatarUrl: avatar is String && avatar.isNotEmpty ? avatar : null,
      hasPin: json['has_pin'] == true,
      isChild: json['is_child'] == true,
      isPrimary: json['is_primary'] == true,
    );
  }
}

/// A started device-code sign-in (`POST /api/v2/auth/device/start`).
class SiloDeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String? verificationUriComplete;
  final DateTime expiresAt;
  final Duration interval;

  const SiloDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresAt,
    required this.interval,
    this.verificationUriComplete,
  });

  /// `48217730` → `4821 7730`, as Silo's own TV apps display it.
  String get displayCode {
    final digits = userCode.replaceAll(RegExp(r'[^0-9A-Za-z]'), '');
    if (digits.length != 8) return userCode;
    return '${digits.substring(0, 4)} ${digits.substring(4)}';
  }
}

enum SiloDevicePollStatus { pending, approved, gone }

class SiloDevicePollResult {
  final SiloDevicePollStatus status;
  final Duration? pollAfter;
  final bool opened;
  final DateTime? expiresAt;
  final SiloTokens? tokens;
  final SiloAccount? account;

  /// Set when the approval already bound the session to a profile.
  final String? profileId;
  final String? profileToken;

  const SiloDevicePollResult({
    required this.status,
    this.pollAfter,
    this.opened = false,
    this.expiresAt,
    this.tokens,
    this.account,
    this.profileId,
    this.profileToken,
  });
}

/// A signed-in session that has not yet chosen a profile.
class SiloSignIn {
  final SiloServerInfo server;
  final SiloTokens tokens;
  final SiloAccount account;
  final String deviceId;

  /// Profile the device-code approval already bound, if any.
  final String? presetProfileId;
  final String? presetProfileToken;

  const SiloSignIn({
    required this.server,
    required this.tokens,
    required this.account,
    required this.deviceId,
    this.presetProfileId,
    this.presetProfileToken,
  });
}

/// Thrown for a Silo server that is reachable but cannot be used.
class SiloServerUnsupportedException implements Exception {
  final String message;
  const SiloServerUnsupportedException(this.message);

  @override
  String toString() => message;
}

/// Sign-in operations that run before a [SiloConnection] exists: probing a
/// server address, password and device-code login, listing profiles and
/// verifying a profile PIN. Uses the Silo v2 API only.
class SiloAuthService {
  SiloAuthService({required this.deviceId, this._clientFactory});

  final String deviceId;
  final http.Client Function()? _clientFactory;
  SiloDeviceHeaders? _headers;

  Future<SiloApi> _api(String baseUrl, {SiloTokens? tokens, String? profileId, String? profileToken}) async {
    final headers = _headers ??= await SiloDeviceHeaders.resolve(deviceId);
    return SiloApi(
      baseUrl: baseUrl,
      device: headers,
      tokens: tokens,
      profileId: profileId,
      profileToken: profileToken,
      client: _clientFactory?.call(),
    );
  }

  /// Silo's default listening port, tried last for a bare host.
  static const defaultPort = 8090;

  /// Candidate base URLs for what the user typed: an explicit scheme is kept;
  /// otherwise `https://` is tried before `http://`, and a bare host with no
  /// port also gets `http://host:8090`, as Silo's own apps do.
  static List<String> candidatesFor(String input) {
    final trimmed = canonicalizeBaseUrl(input.trim());
    if (trimmed.isEmpty) return const [];
    if (hasUrlScheme(trimmed)) return [_normalize(trimmed)];
    final candidates = [_normalize('https://$trimmed'), _normalize('http://$trimmed')];
    final parsed = Uri.tryParse('http://$trimmed');
    if (parsed != null && parsed.host.isNotEmpty && !parsed.hasPort) {
      candidates.add(_normalize(parsed.replace(port: defaultPort).toString()));
    }
    return candidates.toSet().toList();
  }

  /// Lower-case scheme and host; keep port, path prefix and query as typed.
  static String _normalize(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    return canonicalizeBaseUrl(uri.replace(scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase()).toString());
  }

  /// Probe [input] and return the first candidate that is a Silo v2 server.
  /// Throws [SiloServerUnsupportedException] for a Silo server too old for
  /// the v2 API, and [MediaServerHttpException] when nothing answers.
  Future<SiloServerInfo> probe(String input) async {
    final candidates = candidatesFor(input);
    if (candidates.isEmpty) throw const MediaServerUrlException('Empty server address');
    Object? lastError;
    for (final candidate in candidates) {
      try {
        return await _probeOne(candidate);
      } on SiloServerUnsupportedException {
        rethrow;
      } catch (e) {
        lastError = e;
        appLogger.d('Silo probe failed for a candidate', error: e.runtimeType);
      }
    }
    if (lastError is MediaServerException) throw lastError;
    if (lastError is SiloServerUnsupportedException) throw lastError;
    throw MediaServerHttpException(type: MediaServerHttpErrorType.connectionError, message: 'Server unreachable');
  }

  Future<SiloServerInfo> _probeOne(String baseUrl) async {
    final api = await _api(baseUrl);
    try {
      const probeTimeout = Duration(seconds: 8);
      final info = await api.request('GET', '/api/v2/system/info', auth: false, timeout: probeTimeout);
      if (info.statusCode == 404 && info.data is String && (info.data as String).trim() == '404 page not found') {
        throw const SiloServerUnsupportedException('This Silo server is too old: update it to a release with API v2');
      }
      throwIfHttpError(info);
      final data = info.data;
      if (data is! Map || data['api_major'] == null) {
        throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'Not a Silo server');
      }
      if (data['api_major'] != 2) {
        throw SiloServerUnsupportedException('Unsupported Silo API version ${data['api_major']}');
      }
      final identity = await api.getJson('/api/v2/system/identity', profile: false, timeout: probeTimeout);
      final serverId = identity['server_id']?.toString() ?? '';
      if (serverId.isEmpty) {
        throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'Silo server has no id');
      }
      final name = await _serverName(api, baseUrl);
      final deviceLogin = await _deviceLoginAvailable(api);
      final passwordLogin = await _passwordLoginAvailable(api);
      return SiloServerInfo(
        baseUrl: baseUrl,
        serverId: serverId,
        serverName: name,
        serverVersion: data['server_version']?.toString(),
        deviceLoginAvailable: deviceLogin,
        passwordLoginAvailable: passwordLogin,
      );
    } finally {
      api.close();
    }
  }

  Future<String> _serverName(SiloApi api, String baseUrl) async {
    try {
      final response = await api.request('GET', '/api/v2/theme/branding', auth: false);
      final data = response.data;
      if (response.statusCode == 200 && data is Map) {
        for (final key in const ['server_name', 'name', 'app_name', 'title']) {
          final value = data[key];
          if (value is String && value.trim().isNotEmpty) return value.trim();
        }
      }
    } catch (_) {
      // Branding is decorative.
    }
    return Uri.tryParse(baseUrl)?.host ?? 'Silo';
  }

  Future<bool> _deviceLoginAvailable(SiloApi api) async {
    try {
      final response = await api.request('GET', '/api/v2/auth/device/capability', auth: false);
      final data = response.data;
      return response.statusCode == 200 && data is Map && data['state'] == 'available';
    } catch (_) {
      return false;
    }
  }

  Future<bool> _passwordLoginAvailable(SiloApi api) async {
    try {
      final response = await api.request('GET', '/api/v2/auth/providers', auth: false);
      final data = response.data;
      if (response.statusCode == 200 && data is Map) {
        // Also honour a `credentials` provider (LDAP and the like), as Silo's
        // apps do for servers that predate `password_login`.
        final items = data['items'];
        final credentialsProvider = items is List && items.whereType<Map>().any((p) => p['mode'] == 'credentials');
        if (data['password_login'] is bool) return data['password_login'] as bool || credentialsProvider;
        if (credentialsProvider) return true;
      }
    } catch (_) {
      // Older servers lack the route; assume the password form works.
    }
    return true;
  }

  /// `POST /api/v2/auth/login`. Throws [MediaServerAuthException] with the
  /// server's message on refusal.
  Future<SiloSignIn> signInWithPassword(
    SiloServerInfo server, {
    required String username,
    required String password,
  }) async {
    final api = await _api(server.baseUrl);
    try {
      final response = await api.request(
        'POST',
        '/api/v2/auth/login',
        auth: false,
        body: {'username': username, 'password': password},
      );
      if (response.statusCode == 200) {
        final tokens = SiloTokens.fromJson(response.data);
        final account = SiloAccount.fromJson((response.data as Map)['user']);
        if (tokens != null && account != null) {
          return SiloSignIn(server: server, tokens: tokens, account: account, deviceId: deviceId);
        }
      }
      if (response.statusCode == 401 || response.statusCode == 403 || response.statusCode == 429) {
        throw MediaServerAuthException(
          siloProblemDetail(response.data) ?? 'Sign-in refused',
          statusCode: response.statusCode,
          display: siloProblemDetail(response.data),
        );
      }
      throwIfHttpError(response);
      throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'Malformed sign-in response');
    } finally {
      api.close();
    }
  }

  /// `POST /api/v2/auth/device/start`.
  Future<SiloDeviceCode> startDeviceLogin(SiloServerInfo server) async {
    final api = await _api(server.baseUrl);
    try {
      final response = await api.send(
        'POST',
        '/api/v2/auth/device/start',
        auth: false,
        body: {'device_name': api.device.deviceName, 'device_platform': api.device.platform},
      );
      final data = response.data;
      if (data is! Map || data['device_code'] is! String || data['user_code'] is! String) {
        throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'Malformed device start');
      }
      final interval = (data['interval'] as num?)?.toInt() ?? 5;
      final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 900;
      final complete = data['verification_uri_complete'];
      return SiloDeviceCode(
        deviceCode: data['device_code'] as String,
        userCode: data['user_code'] as String,
        verificationUri: (data['verification_uri'] as String?) ?? '${server.baseUrl}/activate',
        verificationUriComplete: complete is String && complete.isNotEmpty ? complete : null,
        expiresAt:
            DateTime.tryParse(data['expires_at']?.toString() ?? '') ?? DateTime.now().add(Duration(seconds: expiresIn)),
        interval: Duration(seconds: interval.clamp(1, 30)),
      );
    } finally {
      api.close();
    }
  }

  /// `POST /api/v2/auth/device/poll`. Transport failures throw so the caller
  /// can back off; a vanished request reports [SiloDevicePollStatus.gone].
  Future<SiloDevicePollResult> pollDeviceLogin(SiloServerInfo server, SiloDeviceCode code) async {
    final api = await _api(server.baseUrl);
    try {
      final response = await api.request(
        'POST',
        '/api/v2/auth/device/poll',
        auth: false,
        body: {'device_code': code.deviceCode},
      );
      if (response.statusCode == 429 || response.statusCode >= 500) throwIfHttpError(response);
      final data = response.data;
      if (response.statusCode != 200 || data is! Map) {
        return const SiloDevicePollResult(status: SiloDevicePollStatus.gone);
      }
      final pollAfter = (data['poll_after'] as num?)?.toInt();
      final expiresAt = DateTime.tryParse(data['expires_at']?.toString() ?? '');
      switch (data['status']) {
        case 'pending':
          return SiloDevicePollResult(
            status: SiloDevicePollStatus.pending,
            pollAfter: pollAfter == null ? null : Duration(seconds: pollAfter.clamp(1, 30)),
            opened: data['opened'] == true,
            expiresAt: expiresAt,
          );
        case 'approved':
          final tokensJson = data['tokens'];
          final tokens = SiloTokens.fromJson(tokensJson);
          final account = tokensJson is Map ? SiloAccount.fromJson(tokensJson['user']) : null;
          if (tokens == null) return const SiloDevicePollResult(status: SiloDevicePollStatus.gone);
          final profileId = data['profile_id'];
          final profileToken = data['profile_token'];
          return SiloDevicePollResult(
            status: SiloDevicePollStatus.approved,
            tokens: tokens,
            account: account,
            profileId: profileId is String && profileId.isNotEmpty ? profileId : null,
            profileToken: profileToken is String && profileToken.isNotEmpty ? profileToken : null,
          );
        default:
          return const SiloDevicePollResult(status: SiloDevicePollStatus.gone);
      }
    } finally {
      api.close();
    }
  }

  /// `POST /api/v2/auth/device/cancel`. Best effort; a 404 is harmless.
  Future<void> cancelDeviceLogin(SiloServerInfo server, SiloDeviceCode code) async {
    try {
      final api = await _api(server.baseUrl);
      try {
        await api.request('POST', '/api/v2/auth/device/cancel', auth: false, body: {'device_code': code.deviceCode});
      } finally {
        api.close();
      }
    } catch (_) {
      // Leaving the screen must not fail on a cancel.
    }
  }

  /// Finish a device-code approval: resolve the account when the poll did
  /// not include it.
  Future<SiloSignIn> completeDeviceLogin(SiloServerInfo server, SiloDevicePollResult result) async {
    final tokens = result.tokens!;
    var account = result.account;
    if (account == null) {
      final api = await _api(server.baseUrl, tokens: tokens);
      try {
        account = SiloAccount.fromJson(await api.getJson('/api/v2/account/me', profile: false));
      } finally {
        api.close();
      }
    }
    if (account == null) throw const MediaServerAuthException('Silo did not return the signed-in account');
    return SiloSignIn(
      server: server,
      tokens: tokens,
      account: account,
      deviceId: deviceId,
      presetProfileId: result.profileId,
      presetProfileToken: result.profileToken,
    );
  }

  /// `GET /api/v2/profiles` for a fresh sign-in.
  Future<List<SiloProfile>> fetchProfiles(SiloSignIn signIn) async {
    final api = await _api(signIn.server.baseUrl, tokens: signIn.tokens);
    try {
      final data = await api.getJson('/api/v2/profiles', profile: false);
      final items = data['items'];
      if (items is! List) return const [];
      return items.map(SiloProfile.fromJson).nonNulls.map((p) {
        final avatar = p.avatarUrl;
        return avatar == null
            ? p
            : SiloProfile(
                id: p.id,
                name: p.name,
                avatarUrl: api.resolveUrl(avatar),
                hasPin: p.hasPin,
                isChild: p.isChild,
                isPrimary: p.isPrimary,
              );
      }).toList();
    } finally {
      api.close();
    }
  }

  /// `POST /api/v2/profiles/{id}/verify-pin`. Returns the profile token, or
  /// `null` when the PIN is wrong.
  Future<String?> verifyPin(SiloSignIn signIn, SiloProfile profile, String pin) async {
    final api = await _api(signIn.server.baseUrl, tokens: signIn.tokens);
    try {
      final response = await api.request(
        'POST',
        '/api/v2/profiles/${Uri.encodeComponent(profile.id)}/verify-pin',
        profile: false,
        body: {'pin': pin},
      );
      if (response.statusCode == 429) {
        throw MediaServerAuthException(siloProblemDetail(response.data) ?? 'Too many attempts', statusCode: 429);
      }
      if (response.statusCode >= 500) throwIfHttpError(response);
      final data = response.data;
      if (response.statusCode == 200 && data is Map && data['valid'] == true) {
        final token = data['profile_token'];
        if (token is String && token.isNotEmpty) return token;
      }
      return null;
    } finally {
      api.close();
    }
  }

  /// Build the persisted connection for [signIn] acting as [profile].
  SiloConnection buildConnection(SiloSignIn signIn, SiloProfile profile, {String? profileToken}) {
    final now = DateTime.now();
    return SiloConnection(
      id: SiloConnection.compoundId(serverId: signIn.server.serverId, userId: signIn.account.id, profileId: profile.id),
      baseUrl: signIn.server.baseUrl,
      serverName: signIn.server.serverName,
      serverId: signIn.server.serverId,
      userId: signIn.account.id,
      userName: signIn.account.username,
      isAdministrator: signIn.account.isAdministrator,
      accessToken: signIn.tokens.accessToken,
      refreshToken: signIn.tokens.refreshToken,
      accessTokenExpiresAt: signIn.tokens.expiresAt,
      deviceId: signIn.deviceId,
      profileId: profile.id,
      profileName: profile.name.isEmpty ? signIn.account.username : profile.name,
      profileAvatarUrl: profile.avatarUrl,
      profileToken: profileToken ?? (profile.id == signIn.presetProfileId ? signIn.presetProfileToken : null),
      profileHasPin: profile.hasPin,
      createdAt: now,
      lastAuthenticatedAt: now,
    );
  }
}
