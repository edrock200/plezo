import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import '../../utils/app_version.dart';
import '../../utils/device_identity.dart';
import '../../utils/media_server_http_client.dart';
import '../../utils/media_server_timeouts.dart';

/// Client identification Tofa reads on playback negotiation (`X-Tofa-*`).
/// Sent on every request: they cost nothing and describe this device on the
/// server's session list.
class TofaClientHeaders {
  final String clientVersion;
  final String platform;
  final String deviceName;
  final String? deviceModel;

  const TofaClientHeaders({
    required this.clientVersion,
    required this.platform,
    required this.deviceName,
    this.deviceModel,
  });

  static const clientName = 'Plezilo';

  /// The headers for this install. Never throws.
  static Future<TofaClientHeaders> resolve() async {
    final version = (await AppVersion.current()).version ?? '1.0';
    final identity = await DeviceIdentityService.resolve();
    final name = [
      identity.deviceName,
      identity.deviceModel,
      identity.platform,
    ].nonNulls.map(asciiHeaderValue).firstWhere((value) => value.isNotEmpty, orElse: () => clientName);
    return TofaClientHeaders(
      clientVersion: version,
      platform: platformValue(identity),
      deviceName: name,
      deviceModel: identity.deviceModel == null ? null : asciiHeaderValue(identity.deviceModel!),
    );
  }

  /// `X-Tofa-Platform`. Tofa's own apps send `android`, `ios`, `tvos` and
  /// `web` (seen in the spec's examples; the set is not enumerated, so this is
  /// unverified for the desktop values). Android TV sends `android`.
  @visibleForTesting
  static String platformValue(DeviceIdentity identity) => switch (identity.platform.toLowerCase()) {
    'android' => 'android',
    'ios' => 'ios',
    'tvos' => 'tvos',
    'macos' => 'macos',
    'windows' => 'windows',
    'linux' => 'linux',
    final other => asciiHeaderValue(other),
  };

  /// Header values must be Latin-1; device names are user-chosen text.
  static String asciiHeaderValue(String value) => value.replaceAll(RegExp(r'[^\x20-\x7e]'), '').trim();

  Map<String, String> toHeaders() => {
    'X-Tofa-Client': clientName,
    'X-Tofa-Client-Version': clientVersion,
    'X-Tofa-Platform': platform,
    'X-Tofa-Device-Name': deviceName,
    if (deviceModel != null && deviceModel!.isNotEmpty) 'X-Tofa-Device-Model': deviceModel!,
  };
}

/// An access/refresh token pair from the cloud's `TokenResponse`.
class TofaTokens {
  final String accessToken;
  final String refreshToken;

  /// When [accessToken] expires (from `expires_in`), or `null` when unknown.
  final DateTime? expiresAt;

  const TofaTokens({required this.accessToken, required this.refreshToken, this.expiresAt});

  /// Parse a `TokenResponse` (`access_token`, `refresh_token`, `expires_in`).
  static TofaTokens? fromJson(Object? data, {DateTime? now}) {
    if (data is! Map) return null;
    final access = data['access_token'];
    final refresh = data['refresh_token'];
    if (access is! String || access.isEmpty || refresh is! String || refresh.isEmpty) return null;
    final expiresIn = data['expires_in'];
    return TofaTokens(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresIn is int && expiresIn > 0 ? (now ?? DateTime.now()).add(Duration(seconds: expiresIn)) : null,
    );
  }
}

/// Tofa's `ErrorResponse.error` code, or null when [data] is not one.
String? tofaErrorCode(Object? data) {
  if (data is Map) {
    final error = data['error'];
    if (error is String && error.isNotEmpty) return error;
  }
  return null;
}

/// Tofa's readable `ErrorResponse.message` (or an `admin_stopped` refusal's
/// `stop_message`), or null.
String? tofaErrorMessage(Object? data) {
  if (data is Map) {
    for (final key in const ['stop_message', 'message', 'error_description']) {
      final value = data[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
  }
  return null;
}

/// HTTP layer of one Tofa connection: the media server at its base URL plus
/// the token refresh at the cloud service ([connectUrl]).
///
/// Every server request carries the bearer, `X-Profile-Id` (and
/// `X-Profile-Token` for a locked profile) and the `X-Tofa-*` headers. A 401
/// refreshes the pair once and resends.
///
/// Refresh tokens rotate, and reusing a retired one revokes the whole
/// session, so a refreshed pair is handed to [onTokensRefreshed] (which
/// persists it) **before** the client starts using it, and concurrent
/// refreshes share one in-flight future.
class TofaApi {
  TofaApi({
    required String baseUrl,
    required this.connectUrl,
    required this.serverId,
    required this.headers,
    this._tokens,
    this.profileId,
    this.profileToken,
    this.onTokensRefreshed,
    this.onSessionExpired,
    http.Client? client,
  }) : _http = MediaServerHttpClient(
         client: client,
         baseUrl: baseUrl,
         defaultHeaders: {'Accept': 'application/json', ...headers.toHeaders()},
         connectTimeout: MediaServerTimeouts.connect,
       );

  final MediaServerHttpClient _http;
  final TofaClientHeaders headers;
  final String connectUrl;
  final String serverId;
  TofaTokens? _tokens;
  String? profileId;
  String? profileToken;

  /// Persists a refreshed pair. Awaited before the pair is used.
  FutureOr<void> Function(TofaTokens tokens)? onTokensRefreshed;

  /// Called when the cloud refused the refresh token (401): the sign-in is
  /// gone and the user has to sign in again.
  void Function()? onSessionExpired;

  Future<TofaTokens?>? _refreshInFlight;
  String? _refusedRefreshToken;

  String get baseUrl => _http.baseUrl;
  TofaTokens? get tokens => _tokens;
  String? get accessToken => _tokens?.accessToken;

  /// The bare transport, for requests that must go out without Tofa's
  /// headers.
  http.Client get rawHttpClient => _http.inner;

  void close() => _http.close();
  Future<void> closeGracefully({Duration drainTimeout = const Duration(seconds: 2)}) =>
      _http.closeGracefully(drainTimeout: drainTimeout);

  /// Use a pair another client of this sign-in obtained.
  void replaceTokens(TofaTokens value) => _tokens = value;

  /// Resolve a server-provided URL: absolute URLs stay as they are, others
  /// are joined to the base URL. The query is never re-encoded.
  ///
  /// Unverified: whether Tofa's relative URLs (`stream_url`, avatar URLs) are
  /// root-relative to the origin or relative to a path-prefixed base. They
  /// are joined to the base URL as typed, which is the same thing for a
  /// server at the root of its host.
  String resolveUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    if (url.startsWith('//')) return '${Uri.parse(base).scheme}:$url';
    return url.startsWith('/') ? '$base$url' : '$base/$url';
  }

  Map<String, String> authHeaders({bool includeProfile = true}) {
    final token = _tokens?.accessToken;
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (includeProfile && profileId != null && profileId!.isNotEmpty) 'X-Profile-Id': profileId!,
      if (includeProfile && profileToken != null && profileToken!.isNotEmpty) 'X-Profile-Token': profileToken!,
    };
  }

  /// Send one request to the media server. Returns the raw response; use
  /// [send] to throw on a non-2xx status. Every path must start with
  /// `/api/v1/`.
  Future<MediaServerResponse> request(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    bool auth = true,
    bool profile = true,
    Duration? timeout,
    AbortController? abort,
  }) async {
    if (!path.startsWith('/api/v1/')) {
      throw ArgumentError.value(path, 'path', 'Tofa requests must target /api/v1/');
    }
    if (auth) await _refreshIfExpiring();
    final usedToken = _tokens?.accessToken;
    var response = await _send(method, path, query, body, auth, profile, timeout, abort);
    // A missing or expired profile token is a 403, not a 401.
    if (auth && response.statusCode == 401 && _tokens != null) {
      final current = _tokens?.accessToken;
      final refreshed = current != usedToken ? _tokens : await refreshTokens();
      if (refreshed != null) {
        response = await _send(method, path, query, body, auth, profile, timeout, abort);
      }
    }
    return response;
  }

  /// [request], throwing [MediaServerHttpException] on any status >= 400.
  /// The exception's `display` carries Tofa's readable `message`.
  Future<MediaServerResponse> send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    bool profile = true,
    Duration? timeout,
    AbortController? abort,
  }) async {
    final response = await request(
      method,
      path,
      query: query,
      body: body,
      profile: profile,
      timeout: timeout,
      abort: abort,
    );
    throwIfTofaError(response);
    return response;
  }

  /// GET returning the decoded JSON body (an object or a list), or throwing.
  Future<Object> getJson(String path, {Map<String, dynamic>? query, AbortController? abort, Duration? timeout}) async {
    final response = await send('GET', path, query: query, abort: abort, timeout: timeout);
    final data = response.data;
    if (data is Map<String, dynamic> || data is List) return data as Object;
    throw MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      statusCode: response.statusCode,
      requestUri: response.requestUri,
      message: 'Expected JSON from $path',
    );
  }

  /// Throw for a non-2xx answer, logging Tofa's error code and keeping its
  /// readable message for the UI.
  static void throwIfTofaError(MediaServerResponse response) {
    if (response.statusCode < 400) return;
    final code = tofaErrorCode(response.data);
    if (code != null) appLogger.d('[tofa] HTTP ${response.statusCode} error=$code');
    throw MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      statusCode: response.statusCode,
      responseData: response.data,
      requestUri: response.requestUri,
      message: 'HTTP ${response.statusCode}${code == null ? '' : ' $code'}',
      display: tofaErrorMessage(response.data),
    );
  }

  Future<MediaServerResponse> _send(
    String method,
    String path,
    Map<String, dynamic>? query,
    Object? body,
    bool auth,
    bool profile,
    Duration? timeout,
    AbortController? abort,
  ) {
    final headers = auth ? authHeaders(includeProfile: profile) : const <String, String>{};
    return switch (method) {
      'GET' => _http.get(path, queryParameters: query, headers: headers, timeout: timeout, abort: abort),
      'POST' => _http.post(path, queryParameters: query, headers: headers, body: body, timeout: timeout, abort: abort),
      'PUT' => _http.put(path, queryParameters: query, headers: headers, body: body, timeout: timeout, abort: abort),
      'DELETE' => _http.delete(path, queryParameters: query, headers: headers, timeout: timeout, abort: abort),
      _ => throw ArgumentError.value(method, 'method'),
    };
  }

  /// Refresh ahead of a request once the 30-day token has a day or less left.
  Future<void> _refreshIfExpiring() async {
    final expiresAt = _tokens?.expiresAt;
    if (expiresAt == null) return;
    if (DateTime.now().isAfter(expiresAt.subtract(const Duration(days: 1)))) await refreshTokens();
  }

  /// Exchange the refresh token for a new pair at
  /// `POST {connectUrl}/servers/{serverId}/device-token/refresh`.
  /// Single-flight. Returns `null` when the pair could not be refreshed.
  Future<TofaTokens?> refreshTokens() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final future = _doRefresh().whenComplete(() => _refreshInFlight = null);
    _refreshInFlight = future;
    return future;
  }

  Future<TofaTokens?> _doRefresh() async {
    final current = _tokens;
    if (current == null || current.refreshToken.isEmpty || connectUrl.isEmpty || serverId.isEmpty) return null;
    // A refused token stays refused: resending it could only hurt.
    if (current.refreshToken == _refusedRefreshToken) return null;
    try {
      final response = await _http.post(
        '$connectUrl/servers/${Uri.encodeComponent(serverId)}/device-token/refresh',
        // The cloud route is public: the refresh token is the credential.
        headers: const {'Content-Type': 'application/json'},
        body: {'refresh_token': current.refreshToken},
        timeout: MediaServerTimeouts.receive,
      );
      if (response.statusCode == 200) {
        final next = TofaTokens.fromJson(response.data);
        if (next == null) {
          appLogger.w('[tofa] token refresh answered without a usable pair; keeping the session');
          return null;
        }
        // Persist first: the old refresh token is retired once this answer
        // exists, and losing the new one would end the sign-in.
        try {
          await onTokensRefreshed?.call(next);
        } catch (e, st) {
          appLogger.w('[tofa] persisting the refreshed token pair failed', error: e, stackTrace: st);
        }
        _tokens = next;
        appLogger.i('[tofa] token refreshed');
        return next;
      }
      if (response.statusCode == 401) {
        appLogger.w('[tofa] refresh refused (${tofaErrorCode(response.data) ?? 'no code'}); signed out');
        _refusedRefreshToken = current.refreshToken;
        onSessionExpired?.call();
      } else {
        appLogger.w('[tofa] token refresh failed (HTTP ${response.statusCode}); keeping the session');
      }
      return null;
    } on MediaServerHttpException catch (e) {
      appLogger.d('[tofa] token refresh failed', error: e.type);
      return null;
    }
  }
}
