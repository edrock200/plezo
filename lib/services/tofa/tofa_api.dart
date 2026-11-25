import 'dart:async';

import 'package:http/http.dart' as http;

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import '../../utils/app_version.dart';
import '../../utils/device_identity.dart';
import '../../utils/media_server_http_client.dart';

/// Where tofa's account service lives: device-flow sign-in, the account's
/// server list, server sessions, token refresh and the cloud relay.
const String tofaCloudBaseUrl = 'https://api.tofa.tv';

/// The `X-Tofa-*` identity headers this install sends on every request, so
/// the server's playback dashboard names the device.
class TofaClientHeaders {
  final String deviceId;
  final String deviceName;
  final String deviceModel;
  final String platform;
  final String clientVersion;

  const TofaClientHeaders({
    required this.deviceId,
    required this.deviceName,
    required this.deviceModel,
    required this.platform,
    required this.clientVersion,
  });

  static const clientName = 'Plezilo';

  /// Never throws: tests and non-platform contexts fall back to generic values.
  static Future<TofaClientHeaders> resolve(String deviceId) async {
    var version = '1.0';
    var platform = 'unknown';
    String? name;
    String? model;
    try {
      version = (await AppVersion.current()).version ?? version;
      final identity = await DeviceIdentityService.resolve();
      platform = identity.isTv && identity.platform.toLowerCase() == 'android'
          ? 'android-tv'
          : identity.platform.toLowerCase();
      name = identity.deviceName;
      model = identity.deviceModel;
    } catch (_) {}
    return TofaClientHeaders(
      deviceId: deviceId,
      deviceName: _ascii(name ?? model ?? clientName),
      deviceModel: _ascii(model ?? ''),
      platform: _ascii(platform),
      clientVersion: _ascii(version),
    );
  }

  /// Header values must be ASCII; device names are user-chosen text.
  static String _ascii(String value) => value.replaceAll(RegExp(r'[^\x20-\x7e]'), '').trim();

  Map<String, String> toHeaders() => {
    'X-Tofa-Client': clientName,
    'X-Tofa-Client-Version': clientVersion,
    'X-Tofa-Platform': platform,
    if (deviceName.isNotEmpty) 'X-Tofa-Device-Name': deviceName,
    if (deviceModel.isNotEmpty) 'X-Tofa-Device-Model': deviceModel,
    'X-Tofa-Device-Id': deviceId,
  };
}

/// A server-scoped token pair as tofa's account service grants it.
class TofaTokens {
  final String accessToken;
  final String refreshToken;
  final DateTime? expiresAt;

  const TofaTokens({required this.accessToken, required this.refreshToken, this.expiresAt});

  factory TofaTokens.fromGrant(Map<String, dynamic> grant, {String? previousRefreshToken}) {
    final expiresIn = grant['expires_in'];
    final refresh = grant['refresh_token']?.toString();
    return TofaTokens(
      accessToken: grant['access_token']?.toString() ?? '',
      // A young refresh token comes back unchanged or not at all; keep the
      // one we hold rather than dropping it.
      refreshToken: refresh == null || refresh.isEmpty ? (previousRefreshToken ?? '') : refresh,
      expiresAt: expiresIn is num ? DateTime.now().add(Duration(seconds: expiresIn.toInt())) : null,
    );
  }
}

/// HTTP access to one tofa server's `/api/v1`, acting as one profile.
///
/// Requests carry `Authorization: Bearer`, the `X-Tofa-*` identity and the
/// profile headers. A 401 on a device-flow token refreshes it once through
/// the account service and retries; [onTokensRefreshed] persists the new pair
/// before anything else uses it (tofa revokes a reused refresh token).
class TofaApi {
  TofaApi({
    required String baseUrl,
    required this.serverId,
    required TofaClientHeaders headers,
    required TofaTokens tokens,
    required this.isApiKey,
    this.profileId = '',
    this.profileToken,
    this.onTokensRefreshed,
    http.Client? httpClient,
  }) : _tokens = tokens, // ignore: prefer_initializing_formals
       _headers = headers, // ignore: prefer_initializing_formals
       _http = MediaServerHttpClient(client: httpClient, baseUrl: baseUrl),
       _cloud = MediaServerHttpClient(client: httpClient, baseUrl: tofaCloudBaseUrl);

  final String serverId;
  final bool isApiKey;
  final TofaClientHeaders _headers;
  final MediaServerHttpClient _http;
  final MediaServerHttpClient _cloud;
  String profileId;
  String? profileToken;
  final Future<void> Function(TofaTokens tokens)? onTokensRefreshed;

  TofaTokens _tokens;
  TofaTokens get tokens => _tokens;

  Future<TofaTokens>? _refreshing;
  bool _closed = false;

  /// Set when the account service refused our refresh token: the user has
  /// to sign in again.
  bool sessionExpired = false;

  String get baseUrl => _http.baseUrl;
  set baseUrl(String value) => _http.baseUrl = value;

  /// The token streaming URLs fall back to when nothing better is known.
  String get accessToken => _tokens.accessToken;

  Map<String, String> _requestHeaders({bool profile = true}) => {
    ..._headers.toHeaders(),
    'Accept': 'application/json',
    if (_tokens.accessToken.isNotEmpty) 'Authorization': 'Bearer ${_tokens.accessToken}',
    if (profile && profileToken != null && profileToken!.isNotEmpty) 'X-Profile-Token': profileToken!,
    if (profile && (profileToken == null || profileToken!.isEmpty) && profileId.isNotEmpty) 'X-Profile-Id': profileId,
  };

  /// Absolute URL for a server path, joined by concatenation so a base with a
  /// path of its own (the relay) keeps it.
  String resolveUrl(String pathOrUrl) {
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) return pathOrUrl;
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return '$base/${pathOrUrl.startsWith('/') ? pathOrUrl.substring(1) : pathOrUrl}';
  }

  Future<MediaServerResponse> request(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    bool profile = true,
    Duration? timeout,
    AbortController? abort,
  }) async {
    var response = await _send(method, path, query, body, profile, timeout, abort);
    if (response.statusCode == 401 && !isApiKey && _tokens.refreshToken.isNotEmpty) {
      final before = _tokens.accessToken;
      try {
        await refresh(ifStillUsing: before);
      } catch (e) {
        appLogger.w('tofa: token refresh failed', error: e.runtimeType);
        return response;
      }
      response = await _send(method, path, query, body, profile, timeout, abort);
    }
    return response;
  }

  Future<MediaServerResponse> _send(
    String method,
    String path,
    Map<String, dynamic>? query,
    Object? body,
    bool profile,
    Duration? timeout,
    AbortController? abort,
  ) {
    final headers = _requestHeaders(profile: profile);
    return switch (method) {
      'GET' => _http.get(path, queryParameters: query, headers: headers, timeout: timeout, abort: abort),
      'POST' => _http.post(path, queryParameters: query, headers: headers, body: body, timeout: timeout, abort: abort),
      'PUT' => _http.put(path, queryParameters: query, headers: headers, body: body, timeout: timeout, abort: abort),
      'PATCH' => _http.patch(path, queryParameters: query, headers: headers, body: body, timeout: timeout, abort: abort),
      'DELETE' => _http.delete(
        path,
        queryParameters: query,
        headers: headers,
        body: body,
        timeout: timeout,
        abort: abort,
      ),
      _ => throw ArgumentError('Unsupported method $method'),
    };
  }

  /// GET [path] and return its JSON body; non-2xx throws.
  Future<dynamic> getJson(String path, {Map<String, dynamic>? query, bool profile = true, AbortController? abort}) async {
    final response = await request('GET', path, query: query, profile: profile, abort: abort);
    throwIfHttpError(response);
    return response.data;
  }

  Future<dynamic> sendJson(String method, String path, {Object? body, Map<String, dynamic>? query}) async {
    final response = await request(method, path, body: body, query: query);
    throwIfHttpError(response);
    return response.data;
  }

  /// Renew the server-scoped token. Concurrent callers share one refresh;
  /// [ifStillUsing] skips it when another request already rotated the token.
  Future<TofaTokens> refresh({String? ifStillUsing}) {
    if (ifStillUsing != null && ifStillUsing != _tokens.accessToken) return Future.value(_tokens);
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<TofaTokens> _doRefresh() async {
    if (_closed) throw StateError('closed');
    final response = await _cloud.post(
      '/servers/${Uri.encodeComponent(serverId)}/device-token/refresh',
      headers: {..._headers.toHeaders(), 'Accept': 'application/json'},
      body: {'refresh_token': _tokens.refreshToken},
    );
    if (response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403) {
      sessionExpired = true;
    }
    throwIfHttpError(response);
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'tofa: bad refresh answer');
    }
    final next = TofaTokens.fromGrant(data, previousRefreshToken: _tokens.refreshToken);
    _tokens = next;
    sessionExpired = false;
    // Persist before anything else uses the pair: a reused refresh token can
    // revoke the whole session family.
    await onTokensRefreshed?.call(next);
    return next;
  }

  void close() {
    _closed = true;
    _http.close();
    _cloud.close();
  }

  Future<void> closeGracefully({Duration drainTimeout = const Duration(seconds: 2)}) async {
    _closed = true;
    await _http.closeGracefully(drainTimeout: drainTimeout);
    _cloud.close();
  }
}
