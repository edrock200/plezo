import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../connection/connection.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_server_http_client.dart';
import '../../utils/media_server_timeouts.dart';
import '../../utils/url_utils.dart';
import 'tofa_api.dart';
import 'tofa_endpoints.dart';

/// The OAuth grant type of Tofa's device flow.
const tofaDeviceCodeGrantType = 'urn:ietf:params:oauth:grant-type:device_code';

/// A Tofa server as its unauthenticated `GET /api/v1/auth/status` describes it.
@immutable
class TofaServerInfo {
  /// The address that answered, normalised, without a trailing slash.
  final String baseUrl;

  /// Shown name: the host (Tofa's API gives a device-flow client no server
  /// name).
  final String serverName;
  final bool claimed;
  final bool claimPending;

  /// The server id the token is scoped to; null on an unclaimed server.
  final String? serverId;

  /// The cloud service that signs this server's devices in.
  final String connectUrl;

  const TofaServerInfo({
    required this.baseUrl,
    required this.serverName,
    required this.claimed,
    required this.claimPending,
    required this.serverId,
    required this.connectUrl,
  });

  /// Whether a device can sign in: the server is claimed by an account and
  /// names its id and cloud service. Anything else is never guessed.
  bool get canSignIn => claimed && (serverId?.isNotEmpty ?? false) && connectUrl.isNotEmpty;

  static TofaServerInfo? fromJson(String baseUrl, Object? data) {
    if (data is! Map) return null;
    final claimed = data['claimed'];
    final connectUrl = data['connect_url'];
    if (claimed is! bool || connectUrl is! String) return null;
    final serverId = data['server_id'];
    final host = Uri.tryParse(baseUrl)?.host;
    return TofaServerInfo(
      baseUrl: baseUrl,
      serverName: host == null || host.isEmpty ? 'Tofa' : host,
      claimed: claimed,
      claimPending: data['claim_pending'] == true,
      serverId: serverId is String && serverId.isNotEmpty ? serverId : null,
      connectUrl: connectUrl.trim(),
    );
  }
}

/// A live device code (`DeviceCodeResponse`).
@immutable
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

  /// The code read character by character ("A B C D, 1 2 3 4").
  String get spokenCode => userCode.split('-').map((part) => part.split('').join(' ')).join(', ');

  static TofaDeviceCode? fromJson(Object? data) {
    if (data is! Map) return null;
    final deviceCode = data['device_code'];
    final userCode = data['user_code'];
    final uri = data['verification_uri'];
    if (deviceCode is! String || deviceCode.isEmpty || userCode is! String || userCode.isEmpty || uri is! String) {
      return null;
    }
    final complete = data['verification_uri_complete'];
    final expiresIn = data['expires_in'];
    final interval = data['interval'];
    return TofaDeviceCode(
      deviceCode: deviceCode,
      userCode: userCode,
      verificationUri: uri,
      verificationUriComplete: complete is String && complete.isNotEmpty ? complete : uri,
      expiresIn: Duration(seconds: expiresIn is int && expiresIn > 0 ? expiresIn : 600),
      // The spec's minimum is 5 s; never poll faster than that.
      interval: Duration(seconds: interval is int && interval >= 5 ? interval : 5),
    );
  }
}

/// One answer of the token poll.
sealed class TofaPollResult {
  const TofaPollResult();
}

class TofaPollPending extends TofaPollResult {
  const TofaPollPending();
}

/// `slow_down`: wait 5 s longer between polls from now on.
class TofaPollSlowDown extends TofaPollResult {
  const TofaPollSlowDown();
}

class TofaPollApproved extends TofaPollResult {
  final TofaTokens tokens;
  const TofaPollApproved(this.tokens);
}

/// Any other OAuth error (`expired_token`, `access_denied`, …): the flow ends.
class TofaPollRefused extends TofaPollResult {
  final String error;
  const TofaPollRefused(this.error);
}

/// A profile as `GET /api/v1/profiles` lists it.
@immutable
class TofaProfile {
  final String id;
  final String userId;
  final String name;
  final bool isKids;
  final bool isLocked;
  final bool isPrimary;
  final String? avatarImageUrl;

  const TofaProfile({
    required this.id,
    required this.userId,
    required this.name,
    this.isKids = false,
    this.isLocked = false,
    this.isPrimary = false,
    this.avatarImageUrl,
  });

  static TofaProfile? fromJson(Object? data) {
    if (data is! Map) return null;
    final id = data['id'];
    final name = data['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final userId = data['user_id'];
    final avatar = data['avatar_image_url'];
    return TofaProfile(
      id: id,
      userId: userId is String ? userId : '',
      name: name,
      isKids: data['is_kids'] == true,
      isLocked: data['is_locked'] == true,
      isPrimary: data['is_primary'] == true,
      avatarImageUrl: avatar is String && avatar.isNotEmpty ? avatar : null,
    );
  }
}

/// The signed-in account (`GET /api/v1/users/me`).
@immutable
class TofaAccount {
  final String id;
  final String username;
  final bool isAdmin;
  const TofaAccount({required this.id, required this.username, this.isAdmin = false});

  static TofaAccount? fromJson(Object? data) {
    if (data is! Map) return null;
    final id = data['id'];
    final username = data['username'];
    if (id is! String || id.isEmpty) return null;
    return TofaAccount(id: id, username: username is String ? username : '', isAdmin: data['is_admin'] == true);
  }
}

/// One server of the account (`ServerListEntry` of `GET {cloud}/servers`).
@immutable
class TofaCloudServer {
  final String id;
  final String name;
  final bool online;
  final String role;

  /// `connect_url`: the server's direct address, absent when it never
  /// connected.
  final String? connectUrl;

  const TofaCloudServer({required this.id, required this.name, this.online = false, this.role = '', this.connectUrl});

  static TofaCloudServer? fromJson(Object? data) {
    if (data is! Map) return null;
    final id = data['id'];
    final name = data['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final url = data['connect_url'];
    return TofaCloudServer(
      id: id,
      name: name.isEmpty ? id : name,
      online: data['online'] == true,
      role: data['role'] is String ? data['role'] as String : '',
      connectUrl: url is String && (url.startsWith('https://') || url.startsWith('http://')) ? url : null,
    );
  }

  /// The server as a sign-in target: its direct address, else its relay
  /// (the client races the others once signed in).
  TofaServerInfo toServerInfo(String cloudUrl) => TofaServerInfo(
    baseUrl: canonicalizeBaseUrl(connectUrl ?? tofaRelayUrl(cloudUrl, id)),
    serverName: name,
    claimed: true,
    claimPending: false,
    serverId: id,
    connectUrl: cloudUrl,
  );
}

/// A finished device sign-in on one server, not yet saved as a connection.
@immutable
class TofaSignIn {
  final TofaServerInfo server;
  final TofaTokens tokens;
  final TofaAccount? account;
  const TofaSignIn({required this.server, required this.tokens, this.account});
}

/// What a PIN check answered.
sealed class TofaPinResult {
  const TofaPinResult();
}

class TofaPinAccepted extends TofaPinResult {
  final String profileToken;
  final DateTime? expiresAt;
  const TofaPinAccepted(this.profileToken, this.expiresAt);
}

class TofaPinWrong extends TofaPinResult {
  const TofaPinWrong();
}

/// 429: too many tries; wait before the next.
class TofaPinTooManyTries extends TofaPinResult {
  const TofaPinTooManyTries();
}

/// A sign-in step failed in a way the person should read.
class TofaSignInException implements Exception {
  final String code;
  final String? message;
  const TofaSignInException(this.code, [this.message]);

  @override
  String toString() => 'TofaSignInException($code)';
}

/// Unauthenticated and freshly-authenticated calls of the sign-in screen:
/// the server probe, the device flow at the cloud service, the account and
/// its profiles.
class TofaAuthService {
  TofaAuthService({http.Client? client, TofaClientHeaders? headers})
    : _headers = headers ?? const TofaClientHeaders(clientVersion: '1.0', platform: 'android', deviceName: 'Plezilo'),
      _http = MediaServerHttpClient(client: client, defaultHeaders: const {'Accept': 'application/json'});

  static Future<TofaAuthService> create() async => TofaAuthService(headers: await TofaClientHeaders.resolve());

  final MediaServerHttpClient _http;
  final TofaClientHeaders _headers;

  void close() => _http.close();

  /// The addresses tried for what the person typed: as typed when it names a
  /// scheme, else https first, then http.
  @visibleForTesting
  static List<String> candidateUrls(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) return [canonicalizeBaseUrl(trimmed)];
    return [canonicalizeBaseUrl('https://$trimmed'), canonicalizeBaseUrl('http://$trimmed')];
  }

  /// Find the Tofa server at [input] (`GET /api/v1/auth/status`). Throws
  /// [MediaServerUrlException] when nothing there answers like Tofa.
  Future<TofaServerInfo> probeServer(String input) async {
    Object? lastError;
    for (final url in candidateUrls(input)) {
      try {
        final response = await _http.get('$url/api/v1/auth/status', timeout: const Duration(seconds: 10));
        final info = response.statusCode == 200 ? TofaServerInfo.fromJson(url, response.data) : null;
        if (info != null) {
          appLogger.i(
            '[tofa] server found claimed=${info.claimed} pending=${info.claimPending} '
            'server_id=${info.serverId != null} cloud=${Uri.tryParse(info.connectUrl)?.host}',
          );
          return info;
        }
        lastError = 'HTTP ${response.statusCode}';
      } catch (e) {
        lastError = e;
      }
    }
    appLogger.d('[tofa] no Tofa server at the address', error: lastError);
    throw const MediaServerUrlException('No Tofa server at this address');
  }

  /// `POST {connect_url}/device/code` with this server's id, so the grant is
  /// a 30-day token for it.
  Future<TofaDeviceCode> startDeviceCode(TofaServerInfo server) async {
    if (!server.canSignIn) throw const TofaSignInException('unclaimed');
    return _startCode(server.connectUrl, serverId: server.serverId);
  }

  /// Account-first sign-in: `POST {cloud}/device/code` WITHOUT a server id,
  /// whose grant is a 15-minute cloud token for [listServers] and
  /// [serverSession].
  Future<TofaDeviceCode> startAccountDeviceCode(String cloudUrl) => _startCode(cloudUrl);

  Future<TofaDeviceCode> _startCode(String cloudUrl, {String? serverId}) async {
    final response = await _http.post(
      '$cloudUrl/device/code',
      headers: const {'Content-Type': 'application/json'},
      body: {'server_id': ?serverId, 'client_name': TofaClientHeaders.clientName, 'client_type': _clientType},
      timeout: MediaServerTimeouts.receive,
    );
    if (response.statusCode != 200) {
      final error = tofaErrorCode(response.data);
      appLogger.w('[tofa] device code refused HTTP ${response.statusCode} error=${error ?? '-'}');
      throw TofaSignInException(error ?? 'http_${response.statusCode}', tofaErrorMessage(response.data));
    }
    final code = TofaDeviceCode.fromJson(response.data);
    if (code == null) throw const TofaSignInException('bad_code');
    appLogger.i('[tofa] device code issued expires_in=${code.expiresIn.inSeconds} interval=${code.interval.inSeconds}');
    return code;
  }

  /// "kodi", "script", …: free-form per the spec; Plezilo names its form.
  String get _clientType => _headers.platform == 'tvos' ? 'tv' : 'app';

  /// One poll of `POST {connect_url}/device/token`, form-encoded (JSON gets a
  /// 415). Transport failures throw [MediaServerHttpException].
  Future<TofaPollResult> pollDeviceToken(TofaServerInfo server, TofaDeviceCode code) =>
      pollDeviceTokenAt(server.connectUrl, code);

  /// [pollDeviceToken] at the cloud service [cloudUrl].
  Future<TofaPollResult> pollDeviceTokenAt(String cloudUrl, TofaDeviceCode code) async {
    final body =
        'grant_type=${Uri.encodeQueryComponent(tofaDeviceCodeGrantType)}'
        '&device_code=${Uri.encodeQueryComponent(code.deviceCode)}';
    final response = await _http.post(
      '$cloudUrl/device/token',
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
      timeout: MediaServerTimeouts.receive,
    );
    return parsePollResponse(response.statusCode, response.data);
  }

  /// The poll answer for a status and body.
  @visibleForTesting
  static TofaPollResult parsePollResponse(int statusCode, Object? data) {
    if (statusCode == 200) {
      final tokens = TofaTokens.fromJson(data);
      return tokens == null ? const TofaPollRefused('bad_token_response') : TofaPollApproved(tokens);
    }
    final error = tofaErrorCode(data);
    if (statusCode == 400 && error == 'authorization_pending') return const TofaPollPending();
    if (statusCode == 400 && error == 'slow_down') return const TofaPollSlowDown();
    if (statusCode >= 500 || statusCode == 429) {
      throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: statusCode);
    }
    return TofaPollRefused(error ?? 'http_$statusCode');
  }

  /// `GET {cloud}/servers` with a cloud token: the servers this account owns
  /// or was invited to.
  Future<List<TofaCloudServer>> listServers(String cloudUrl, TofaTokens cloudTokens) async {
    final response = await _http.get(
      '$cloudUrl/servers',
      queryParameters: {'limit': '100'},
      headers: {'Authorization': 'Bearer ${cloudTokens.accessToken}'},
    );
    TofaApi.throwIfTofaError(response);
    final data = response.data;
    final items = data is Map ? data['items'] : null;
    final servers = [
      if (items is List)
        for (final row in items) ?TofaCloudServer.fromJson(row),
    ];
    appLogger.i('[tofa] account lists ${servers.length} server(s)');
    return servers;
  }

  /// `POST {cloud}/servers/{id}/server-session`: the 30-day server token pair
  /// for [server], from the cloud token.
  Future<TofaTokens> serverSession(String cloudUrl, TofaTokens cloudTokens, TofaCloudServer server) async {
    final response = await _http.post(
      '$cloudUrl/servers/${Uri.encodeComponent(server.id)}/server-session',
      headers: {'Authorization': 'Bearer ${cloudTokens.accessToken}'},
    );
    TofaApi.throwIfTofaError(response);
    final tokens = TofaTokens.fromJson(response.data);
    if (tokens == null) throw const TofaSignInException('bad_token_response');
    return tokens;
  }

  /// The address of a server picked from the account's list that answers
  /// from this device. `connect_url` alone is the server's direct internet
  /// address, which many servers (no port forward, a seedbox behind its own
  /// domain) never answer on, so the sign-in hung on it and failed. Like the
  /// client, race what `GET {cloud}/servers/{id}/connection-info` lists
  /// (lan-direct, wan-direct including custom access URLs, relay; the guide's
  /// order and staggers), then `connect_url`, then the documented relay base.
  /// Null when nothing answers.
  Future<TofaServerInfo?> resolveServerAddress(String cloudUrl, TofaCloudServer server, TofaTokens tokens) async {
    TofaConnectionInfo? info;
    try {
      final response = await _http.get(
        '$cloudUrl/servers/${Uri.encodeComponent(server.id)}/connection-info',
        headers: {'Authorization': 'Bearer ${tokens.accessToken}'},
        timeout: const Duration(seconds: 10),
      );
      if (response.statusCode == 200) {
        info = TofaConnectionInfo.fromJson(response.data);
      } else {
        appLogger.d('[tofa] connection-info answered ${response.statusCode} at sign-in');
      }
    } catch (e) {
      appLogger.d('[tofa] connection-info unavailable at sign-in', error: e.runtimeType);
    }
    final candidates = signInCandidates(cloudUrl, server, info);
    appLogger.i('[tofa] sign-in address race: ${candidates.map((c) => c.kind.name).join(',')}');
    final winner = await raceTofaEndpoints(candidates, (c) => probeAddress(c.url, server.id, tokens));
    if (winner == null) {
      appLogger.w('[tofa] no address of the picked server answered');
      return null;
    }
    appLogger.i('[tofa] sign-in reaches the server via ${winner.kind.name}');
    return TofaServerInfo(
      baseUrl: canonicalizeBaseUrl(winner.url),
      serverName: server.name,
      claimed: true,
      claimPending: false,
      serverId: server.id,
      connectUrl: cloudUrl,
    );
  }

  /// The race order for [resolveServerAddress]: the cloud's candidates as
  /// given, then `connect_url` (a wan-direct path), then the relay base
  /// when the cloud listed none. Duplicates are dropped by the race.
  @visibleForTesting
  static List<TofaEndpointCandidate> signInCandidates(
    String cloudUrl,
    TofaCloudServer server,
    TofaConnectionInfo? info,
  ) {
    final cloud = info?.candidates ?? const <TofaEndpointCandidate>[];
    final last = cloud.isEmpty ? Duration.zero : cloud.last.stagger;
    final direct = server.connectUrl;
    return [
      ...cloud,
      if (direct != null)
        TofaEndpointCandidate(
          url: canonicalizeBaseUrl(direct),
          kind: TofaEndpointKind.wanDirect,
          stagger: last + const Duration(milliseconds: 100),
        ),
      if (!cloud.any((c) => c.kind == TofaEndpointKind.relay))
        TofaEndpointCandidate(
          url: tofaRelayUrl(cloudUrl, server.id),
          kind: TofaEndpointKind.relay,
          stagger: last + const Duration(milliseconds: 300),
        ),
    ];
  }

  /// Whether the Tofa server [serverId] answers at [baseUrl]
  /// (`GET /api/v1/auth/status`). Asked without credentials first; when that
  /// is refused (unverified: the relay may want the bearer on every route),
  /// asked again with the server token, which only goes to addresses Tofa's
  /// cloud listed for this server.
  @visibleForTesting
  Future<bool> probeAddress(String baseUrl, String serverId, TofaTokens tokens) async {
    for (final withBearer in const [false, true]) {
      try {
        final response = await _http.get(
          '$baseUrl/api/v1/auth/status',
          headers: withBearer ? {'Authorization': 'Bearer ${tokens.accessToken}'} : const {},
          timeout: const Duration(seconds: 6),
        );
        if (response.statusCode == 200 && response.data is Map) {
          final id = (response.data as Map)['server_id'];
          return id == null || id == serverId;
        }
        if (response.statusCode != 401 && response.statusCode != 403) return false;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  Map<String, String> _bearer(TofaTokens tokens) => {
    ..._headers.toHeaders(),
    'Authorization': 'Bearer ${tokens.accessToken}',
  };

  /// The account the token belongs to, or null when the server cannot say.
  Future<TofaAccount?> fetchAccount(TofaServerInfo server, TofaTokens tokens) async {
    try {
      final response = await _http.get('${server.baseUrl}/api/v1/users/me', headers: _bearer(tokens));
      return response.statusCode == 200 ? TofaAccount.fromJson(response.data) : null;
    } catch (e) {
      appLogger.d('[tofa] account read failed', error: e.runtimeType);
      return null;
    }
  }

  /// The account's profiles (`GET /api/v1/profiles`).
  Future<List<TofaProfile>> fetchProfiles(TofaSignIn signIn) async {
    final response = await _http.get('${signIn.server.baseUrl}/api/v1/profiles', headers: _bearer(signIn.tokens));
    TofaApi.throwIfTofaError(response);
    final data = response.data;
    if (data is! List) {
      throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'Expected a profile list');
    }
    return [for (final row in data) ?TofaProfile.fromJson(row)];
  }

  /// `POST /api/v1/profiles/{id}/verify-pin`. Unverified: which status a
  /// wrong PIN answers (the spec lists 400, 401 and 403); all three count as
  /// a wrong PIN, 429 as too many tries, anything else throws.
  Future<TofaPinResult> verifyPin(TofaSignIn signIn, TofaProfile profile, String pin) async {
    final response = await _http.post(
      '${signIn.server.baseUrl}/api/v1/profiles/${Uri.encodeComponent(profile.id)}/verify-pin',
      headers: {..._bearer(signIn.tokens), 'X-Profile-Id': profile.id, 'Content-Type': 'application/json'},
      body: {'pin': pin, 'remember_device': true},
    );
    if (response.statusCode == 200) {
      final data = response.data;
      final token = data is Map ? data['profile_token'] : null;
      if (token is! String || token.isEmpty) return const TofaPinWrong();
      final expires = data is Map ? data['expires_at'] : null;
      return TofaPinAccepted(token, expires is String ? DateTime.tryParse(expires) : null);
    }
    if (response.statusCode == 429) return const TofaPinTooManyTries();
    if (response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403) {
      appLogger.d('[tofa] PIN refused HTTP ${response.statusCode} error=${tofaErrorCode(response.data) ?? '-'}');
      return const TofaPinWrong();
    }
    TofaApi.throwIfTofaError(response);
    return const TofaPinWrong();
  }

  /// The connection for [profile] of [signIn].
  static TofaConnection buildConnection(TofaSignIn signIn, TofaProfile profile, {TofaPinAccepted? pin, DateTime? now}) {
    final server = signIn.server;
    final userId = signIn.account?.id ?? profile.userId;
    final at = now ?? DateTime.now();
    return TofaConnection(
      id: TofaConnection.compoundId(serverId: server.serverId!, userId: userId, profileId: profile.id),
      baseUrl: server.baseUrl,
      serverName: server.serverName,
      serverId: server.serverId!,
      connectUrl: server.connectUrl,
      userId: userId,
      userName: signIn.account?.username ?? '',
      isAdministrator: signIn.account?.isAdmin ?? false,
      accessToken: signIn.tokens.accessToken,
      refreshToken: signIn.tokens.refreshToken,
      accessTokenExpiresAt: signIn.tokens.expiresAt,
      profileId: profile.id,
      profileName: profile.name,
      profileAvatarUrl: profile.avatarImageUrl,
      profileToken: pin?.profileToken,
      profileTokenExpiresAt: pin?.expiresAt,
      profileIsLocked: profile.isLocked,
      createdAt: at,
      lastAuthenticatedAt: at,
    );
  }
}

/// What the device-code panel shows.
enum TofaDeviceSignInStatus {
  /// Asking the cloud for a code.
  gettingCode,

  /// A live code; polling.
  waiting,

  /// Polls have failed (network, 5xx) for a while. Still polling.
  unreachable,

  /// Approved: the tokens are in [TofaDeviceSignInState.tokens].
  approved,

  /// The code expired before it was approved. Waits for "Show a new code".
  expired,

  /// The approver declined, or the cloud ended the flow.
  denied,

  /// Getting a code failed.
  failed;

  bool get isSettled => switch (this) {
    approved || expired || denied || failed => true,
    _ => false,
  };
}

@immutable
class TofaDeviceSignInState {
  final TofaDeviceSignInStatus status;
  final TofaDeviceCode? code;
  final TofaTokens? tokens;

  /// The refusal's error code or message, for [TofaDeviceSignInStatus.denied]
  /// and [TofaDeviceSignInStatus.failed].
  final String? error;

  const TofaDeviceSignInState(this.status, {this.code, this.tokens, this.error});

  @override
  String toString() => 'TofaDeviceSignInState(${status.name}, code: ${code != null})';
}

/// The device flow: gets a code, polls every `interval` seconds (5 s longer
/// after each `slow_down`), keeps polling through transient failures, and
/// stops at approval, a refusal or the code's expiry.
class TofaDeviceSignIn extends ValueNotifier<TofaDeviceSignInState> {
  TofaDeviceSignIn({
    required this.auth,
    required TofaServerInfo this.server,
    Future<void> Function(Duration delay)? wait,
    DateTime Function()? now,
    this.unreachableAfter = const Duration(seconds: 30),
  }) : _wait = wait ?? ((delay) => Future<void>.delayed(delay)),
       _now = now ?? DateTime.now,
       cloudUrl = server.connectUrl,
       super(const TofaDeviceSignInState(TofaDeviceSignInStatus.gettingCode));

  /// Account-first sign-in at [cloudUrl]: the grant is a cloud token.
  TofaDeviceSignIn.account({
    required this.auth,
    required this.cloudUrl,
    Future<void> Function(Duration delay)? wait,
    DateTime Function()? now,
    this.unreachableAfter = const Duration(seconds: 30),
  }) : server = null,
       _wait = wait ?? ((delay) => Future<void>.delayed(delay)),
       _now = now ?? DateTime.now,
       super(const TofaDeviceSignInState(TofaDeviceSignInStatus.gettingCode));

  final TofaAuthService auth;

  /// The server signed in to; null for an account-first sign-in.
  final TofaServerInfo? server;
  final String cloudUrl;
  final Future<void> Function(Duration delay) _wait;
  final DateTime Function() _now;
  final Duration unreachableAfter;

  int _run = 0;
  bool _disposed = false;

  /// The poll interval in force (after `slow_down`s).
  @visibleForTesting
  Duration? currentInterval;

  /// Get a code and poll until the flow settles. Calling it again (Show a
  /// new code) abandons the previous code.
  Future<void> start() async {
    final run = ++_run;
    _set(const TofaDeviceSignInState(TofaDeviceSignInStatus.gettingCode));
    final TofaDeviceCode code;
    try {
      final target = server;
      code = target == null ? await auth.startAccountDeviceCode(cloudUrl) : await auth.startDeviceCode(target);
    } catch (e) {
      if (!_current(run)) return;
      appLogger.w('[tofa] device code failed', error: e is TofaSignInException ? e.code : e.runtimeType);
      _set(
        TofaDeviceSignInState(
          TofaDeviceSignInStatus.failed,
          error: e is TofaSignInException ? (e.message ?? e.code) : null,
        ),
      );
      return;
    }
    if (!_current(run)) return;
    _set(TofaDeviceSignInState(TofaDeviceSignInStatus.waiting, code: code));
    await _poll(run, code);
  }

  Future<void> _poll(int run, TofaDeviceCode code) async {
    final deadline = _now().add(code.expiresIn);
    var interval = code.interval;
    currentInterval = interval;
    DateTime? failingSince;
    while (true) {
      await _wait(interval);
      if (!_current(run)) return;
      if (!_now().isBefore(deadline)) {
        appLogger.i('[tofa] device code expired before approval');
        _set(TofaDeviceSignInState(TofaDeviceSignInStatus.expired, code: code));
        return;
      }
      final TofaPollResult result;
      try {
        result = await auth.pollDeviceTokenAt(cloudUrl, code);
      } catch (e) {
        if (!_current(run)) return;
        failingSince ??= _now();
        if (_now().difference(failingSince) >= unreachableAfter && value.status != TofaDeviceSignInStatus.unreachable) {
          appLogger.w('[tofa] device token poll failing', error: e.runtimeType);
          _set(TofaDeviceSignInState(TofaDeviceSignInStatus.unreachable, code: code));
        }
        continue;
      }
      if (!_current(run)) return;
      failingSince = null;
      switch (result) {
        case TofaPollPending():
          if (value.status != TofaDeviceSignInStatus.waiting) {
            _set(TofaDeviceSignInState(TofaDeviceSignInStatus.waiting, code: code));
          }
        case TofaPollSlowDown():
          interval += const Duration(seconds: 5);
          currentInterval = interval;
          appLogger.d('[tofa] slow_down: polling every ${interval.inSeconds} s');
        case TofaPollApproved(:final tokens):
          appLogger.i('[tofa] device sign-in approved');
          _set(TofaDeviceSignInState(TofaDeviceSignInStatus.approved, code: code, tokens: tokens));
          return;
        case TofaPollRefused(:final error):
          appLogger.i('[tofa] device sign-in ended error=$error');
          _set(
            TofaDeviceSignInState(
              error == 'expired_token' ? TofaDeviceSignInStatus.expired : TofaDeviceSignInStatus.denied,
              code: code,
              error: error,
            ),
          );
          return;
      }
    }
  }

  bool _current(int run) => !_disposed && run == _run;

  void _set(TofaDeviceSignInState state) {
    if (!_disposed) value = state;
  }

  /// Stop polling (leaving the screen, changing server).
  void cancel() => _run++;

  @override
  void dispose() {
    _disposed = true;
    _run++;
    super.dispose();
  }
}
