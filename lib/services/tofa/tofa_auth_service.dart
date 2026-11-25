import 'dart:async';

import 'package:http/http.dart' as http;

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/media_server_http_client.dart';
import 'tofa_api.dart';

/// A pairing code from `POST https://api.tofa.tv/device/code`.
class TofaDeviceCode {
  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String verificationUriComplete;
  final Duration expiresIn;
  final Duration interval;

  const TofaDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.expiresIn,
    required this.interval,
  });
}

/// One server from the account's `GET https://api.tofa.tv/servers` list.
class TofaAccountServer {
  final String id;
  final String name;
  final String? connectUrl;
  final String? localUrl;

  const TofaAccountServer({required this.id, required this.name, this.connectUrl, this.localUrl});

  /// The cloud relay for this server: the API proxied through tofa.
  String get relayUrl => '$tofaCloudBaseUrl/servers/$id/relay';

  /// Addresses to try, best first: the LAN, the server's own direct host,
  /// then the relay.
  List<String> get candidateUrls => [?localUrl, ?connectUrl, relayUrl];
}

/// What a finished sign-in hands to the connection layer.
class TofaSignInResult {
  final String serverId;
  final String serverName;
  final String baseUrl;
  final List<String> fallbackUrls;
  final TofaTokens tokens;
  final bool isApiKey;
  final String userId;
  final String userName;
  final bool isAdministrator;

  const TofaSignInResult({
    required this.serverId,
    required this.serverName,
    required this.baseUrl,
    required this.fallbackUrls,
    required this.tokens,
    required this.isApiKey,
    required this.userId,
    required this.userName,
    required this.isAdministrator,
  });
}

/// A tofa profile from `GET /api/v1/profiles`.
class TofaProfile {
  final String id;
  final String name;
  final bool isLocked;
  final bool isPrimary;
  final bool isKids;
  final String? avatarUrl;

  const TofaProfile({
    required this.id,
    required this.name,
    required this.isLocked,
    required this.isPrimary,
    required this.isKids,
    this.avatarUrl,
  });

  factory TofaProfile.fromJson(Map<String, dynamic> json) => TofaProfile(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    isLocked: json['is_locked'] == true,
    isPrimary: json['is_primary'] == true,
    isKids: json['is_kids'] == true,
    avatarUrl: json['avatar_image_url']?.toString(),
  );
}

/// Why a sign-in step failed, for the sign-in screen.
enum TofaSignInFailure { expired, denied, network, notTofa, unauthorized, noServers, unknown }

class TofaSignInException implements Exception {
  final TofaSignInFailure reason;
  final String? detail;
  const TofaSignInException(this.reason, [this.detail]);

  @override
  String toString() => 'TofaSignInException($reason${detail == null ? '' : ': $detail'})';
}

/// Signing in to tofa: the account-first device flow through
/// `api.tofa.tv` (the way tofa's own apps and its Kodi add-on do it), or an
/// admin API key on a server address. See the `tofa-backend` skill.
class TofaAuthService {
  TofaAuthService({required this.headers, http.Client? httpClient})
    : _cloud = MediaServerHttpClient(client: httpClient, baseUrl: tofaCloudBaseUrl),
      _httpClient = httpClient;

  final TofaClientHeaders headers;
  final MediaServerHttpClient _cloud;
  final http.Client? _httpClient;

  static const _deviceGrant = 'urn:ietf:params:oauth:grant-type:device_code';

  Map<String, String> get _json => {...headers.toHeaders(), 'Accept': 'application/json'};

  /// Start pairing. No `server_id`: the grant is an account token that can
  /// list the account's servers.
  Future<TofaDeviceCode> startDeviceFlow() async {
    final response = await _call(
      () => _cloud.post(
        '/device/code',
        headers: _json,
        body: {'client_name': TofaClientHeaders.clientName, 'client_type': headers.platform},
      ),
    );
    final data = response.data;
    if (data is! Map<String, dynamic> || data['device_code'] == null) {
      throw const TofaSignInException(TofaSignInFailure.unknown, 'no device code');
    }
    final interval = data['interval'];
    final expires = data['expires_in'];
    final uri = data['verification_uri']?.toString() ?? 'https://app.tofa.tv/link';
    return TofaDeviceCode(
      deviceCode: data['device_code'].toString(),
      userCode: data['user_code']?.toString() ?? '',
      verificationUri: uri,
      verificationUriComplete: data['verification_uri_complete']?.toString() ?? uri,
      expiresIn: Duration(seconds: expires is num ? expires.toInt() : 600),
      interval: Duration(seconds: interval is num && interval > 0 ? interval.toInt() : 5),
    );
  }

  /// Poll until the code is approved, refused or expires, honouring
  /// `slow_down`. Returns the account-token grant (`access_token`,
  /// `refresh_token`). [isCancelled] stops the loop between polls.
  Future<Map<String, dynamic>> waitForApproval(TofaDeviceCode code, {required bool Function() isCancelled}) async {
    var interval = code.interval;
    final deadline = DateTime.now().add(code.expiresIn);
    while (!isCancelled()) {
      await Future<void>.delayed(interval);
      if (isCancelled()) break;
      if (DateTime.now().isAfter(deadline)) throw const TofaSignInException(TofaSignInFailure.expired);
      final MediaServerResponse response;
      try {
        response = await _cloud.post(
          '/device/token',
          headers: {..._json, 'content-type': 'application/x-www-form-urlencoded'},
          body: 'grant_type=${Uri.encodeQueryComponent(_deviceGrant)}'
              '&device_code=${Uri.encodeQueryComponent(code.deviceCode)}',
        );
      } on MediaServerHttpException catch (e) {
        if (e.isCancellation) rethrow;
        continue; // A dropped poll is retried at the next interval.
      }
      final data = response.data;
      if (response.statusCode == 200 && data is Map<String, dynamic> && data['access_token'] != null) {
        return data;
      }
      final error = data is Map ? data['error']?.toString() : null;
      switch (error) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
          continue;
        case 'expired_token':
          throw const TofaSignInException(TofaSignInFailure.expired);
        case 'access_denied':
        case 'invalid_grant':
          throw const TofaSignInException(TofaSignInFailure.denied);
        default:
          if (response.statusCode >= 500) continue;
          throw TofaSignInException(TofaSignInFailure.unknown, error ?? 'HTTP ${response.statusCode}');
      }
    }
    throw const TofaSignInException(TofaSignInFailure.unknown, 'cancelled');
  }

  /// The account's servers that have come online at least once.
  Future<List<TofaAccountServer>> listServers(String accountToken) async {
    final response = await _call(
      () => _cloud.get('/servers', headers: {..._json, 'Authorization': 'Bearer $accountToken'}),
    );
    final data = response.data;
    final items = data is Map ? data['items'] : data;
    if (items is! List) return const [];
    final servers = <TofaAccountServer>[];
    for (final raw in items.whereType<Map>()) {
      final id = raw['id']?.toString();
      final connect = raw['connect_url']?.toString();
      if (id == null || id.isEmpty || connect == null || connect.isEmpty) continue;
      final connection = raw['connection'];
      String? local;
      if (connection is Map && connection['local_ip'] != null && connection['port'] != null) {
        local = 'http://${connection['local_ip']}:${connection['port']}';
      }
      servers.add(
        TofaAccountServer(
          id: id,
          name: raw['name']?.toString().trim().isNotEmpty == true ? raw['name'].toString() : 'tofa',
          connectUrl: connect.replaceAll(RegExp(r'/+$'), ''),
          localUrl: local,
        ),
      );
    }
    return servers;
  }

  /// Trade the account token for the durable token pair scoped to [server],
  /// pick the first address that answers, and read who signed in.
  Future<TofaSignInResult> signInToServer(String accountToken, TofaAccountServer server) async {
    final response = await _call(
      () => _cloud.post(
        '/servers/${Uri.encodeComponent(server.id)}/server-session',
        headers: {..._json, 'Authorization': 'Bearer $accountToken'},
      ),
    );
    final data = response.data;
    if (data is! Map<String, dynamic> || data['access_token'] == null) {
      throw const TofaSignInException(TofaSignInFailure.unknown, 'no server session');
    }
    final tokens = TofaTokens.fromGrant(data);
    final reachable = <String>[];
    for (final url in server.candidateUrls) {
      if (await probe(url)) reachable.add(url);
    }
    final ordered = [...reachable, ...server.candidateUrls.where((u) => !reachable.contains(u))];
    final me = await _me(ordered.first, tokens.accessToken);
    return TofaSignInResult(
      serverId: server.id,
      serverName: server.name,
      baseUrl: ordered.first,
      fallbackUrls: ordered.skip(1).toList(),
      tokens: tokens,
      isApiKey: false,
      userId: me.id,
      userName: me.name,
      isAdministrator: me.isAdmin,
    );
  }

  /// Sign in to [baseUrl] with an admin API key (`tofa_…`). Keys only work on
  /// direct connections, never through the relay.
  Future<TofaSignInResult> signInWithApiKey(String baseUrl, String apiKey) async {
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final status = await _status(base);
    final me = await _me(base, apiKey.trim());
    return TofaSignInResult(
      serverId: status.serverId,
      serverName: Uri.tryParse(base)?.host ?? 'tofa',
      baseUrl: base,
      fallbackUrls: const [],
      tokens: TofaTokens(accessToken: apiKey.trim(), refreshToken: ''),
      isApiKey: true,
      userId: me.id,
      userName: me.name,
      isAdministrator: me.isAdmin,
    );
  }

  /// The account's profiles on [baseUrl].
  Future<List<TofaProfile>> fetchProfiles(String baseUrl, String token) async {
    final api = _server(baseUrl);
    try {
      final response = await _call(
        () => api.get('/api/v1/profiles', headers: {..._json, 'Authorization': 'Bearer $token'}),
      );
      final data = response.data;
      if (data is! List) return const [];
      return data.whereType<Map<String, dynamic>>().map(TofaProfile.fromJson).toList();
    } finally {
      api.close();
    }
  }

  /// Unlock a PIN-protected profile; returns its `X-Profile-Token`.
  Future<String> verifyPin(String baseUrl, String token, String profileId, String pin) async {
    final api = _server(baseUrl);
    try {
      final response = await api.post(
        '/api/v1/profiles/${Uri.encodeComponent(profileId)}/verify-pin',
        headers: {..._json, 'Authorization': 'Bearer $token'},
        body: {'pin': pin},
      );
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const TofaSignInException(TofaSignInFailure.unauthorized);
      }
      throwIfHttpError(response);
      final data = response.data;
      final value = data is Map
          ? (data['token'] ?? data['profile_token'])?.toString()
          : response.headers['x-profile-token'];
      if (value == null || value.isEmpty) throw const TofaSignInException(TofaSignInFailure.unknown, 'no token');
      return value;
    } finally {
      api.close();
    }
  }

  /// Does [baseUrl] answer as a tofa server? `/auth/status` needs no token.
  Future<bool> probe(String baseUrl) async {
    final api = _server(baseUrl);
    try {
      final response = await api.get('/api/v1/auth/status', headers: _json, timeout: const Duration(seconds: 3));
      return response.statusCode < 500 && response.statusCode != 404;
    } catch (_) {
      return false;
    } finally {
      api.close();
    }
  }

  Future<({String serverId})> _status(String base) async {
    final api = _server(base);
    try {
      final response = await _call(() => api.get('/api/v1/auth/status', headers: _json));
      final data = response.data;
      final id = data is Map ? data['server_id']?.toString() : null;
      if (id == null || id.isEmpty) throw const TofaSignInException(TofaSignInFailure.notTofa);
      return (serverId: id);
    } finally {
      api.close();
    }
  }

  Future<({String id, String name, bool isAdmin})> _me(String base, String token) async {
    final api = _server(base);
    try {
      final response = await api.get('/api/v1/users/me', headers: {..._json, 'Authorization': 'Bearer $token'});
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const TofaSignInException(TofaSignInFailure.unauthorized);
      }
      throwIfHttpError(response);
      final data = response.data;
      if (data is! Map) throw const TofaSignInException(TofaSignInFailure.notTofa);
      return (
        id: data['id']?.toString() ?? '',
        name: (data['username'] ?? data['name'] ?? '').toString(),
        isAdmin: data['is_admin'] == true || data['role'] == 'admin',
      );
    } finally {
      api.close();
    }
  }

  MediaServerHttpClient _server(String base) => MediaServerHttpClient(client: _httpClient, baseUrl: base);

  Future<MediaServerResponse> _call(Future<MediaServerResponse> Function() send) async {
    final MediaServerResponse response;
    try {
      response = await send();
    } on MediaServerHttpException catch (e) {
      if (e.isCancellation) rethrow;
      throw TofaSignInException(TofaSignInFailure.network, e.type.name);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const TofaSignInException(TofaSignInFailure.unauthorized);
    }
    if (response.statusCode >= 400) {
      throw TofaSignInException(TofaSignInFailure.unknown, 'HTTP ${response.statusCode}');
    }
    return response;
  }

  void close() => _cloud.close();
}
