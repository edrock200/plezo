import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import '../../utils/device_identity.dart';
import '../../utils/media_server_http_client.dart';
import '../../utils/media_server_timeouts.dart';

/// Identification headers every Silo request carries (`X-Silo-*`).
///
/// None is required for authentication, but device-scoped settings and the
/// server's device list key off them, so they go on every request, signed in
/// or not.
class SiloDeviceHeaders {
  final String deviceId;
  final String deviceName;
  final String platform;
  final String clientFamily;
  final String clientVersion;

  const SiloDeviceHeaders({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.clientFamily,
    required this.clientVersion,
  });

  static const clientName = 'Plezy';

  /// Resolve the headers for this install. Never throws: tests and
  /// non-platform contexts fall back to generic values.
  static Future<SiloDeviceHeaders> resolve(String deviceId) async {
    var version = '1.0';
    try {
      final pkg = await PackageInfo.fromPlatform();
      if (pkg.version.isNotEmpty) version = pkg.version;
    } catch (_) {
      // Keep the fallback version.
    }
    final identity = await DeviceIdentityService.resolve();
    final platform = identity.platform.toLowerCase();
    final name = [
      identity.deviceName,
      identity.deviceModel,
      identity.platform,
    ].nonNulls.map(_asciiHeaderValue).firstWhere((value) => value.isNotEmpty, orElse: () => clientName);
    return SiloDeviceHeaders(
      deviceId: deviceId,
      deviceName: name,
      platform: identity.isTv && platform == 'android' ? 'android-tv' : _asciiHeaderValue(platform),
      clientFamily: identity.isTv
          ? 'tv'
          : switch (platform) {
              'android' || 'ios' => 'mobile',
              _ => 'desktop',
            },
      clientVersion: version,
    );
  }

  /// Header values must be Latin-1; device names are user-chosen text.
  static String _asciiHeaderValue(String value) => value.replaceAll(RegExp(r'[^\x20-\x7e]'), '').trim();

  Map<String, String> toHeaders() => {
    'X-Silo-Device-Id': deviceId,
    'X-Silo-Device-Name': deviceName,
    'X-Silo-Device-Platform': platform,
    'X-Silo-Client': clientName,
    'X-Silo-Client-Version': clientVersion,
    'X-Silo-Client-Family': clientFamily,
  };
}

/// A token pair as `/auth/login`, `/auth/refresh` and the device-code poll
/// return it.
class SiloTokens {
  final String accessToken;
  final String refreshToken;
  final DateTime? expiresAt;

  /// Seconds the token was valid for when issued, used for the proactive
  /// refresh margin.
  final int? lifetimeSeconds;

  const SiloTokens({required this.accessToken, required this.refreshToken, this.expiresAt, this.lifetimeSeconds});

  static SiloTokens? fromJson(Object? json) {
    if (json is! Map) return null;
    final access = json['access_token'];
    final refresh = json['refresh_token'];
    if (access is! String || access.isEmpty || refresh is! String || refresh.isEmpty) return null;
    final expiresIn = json['expires_in'];
    final seconds = expiresIn is num ? expiresIn.toInt() : null;
    return SiloTokens(
      accessToken: access,
      refreshToken: refresh,
      lifetimeSeconds: seconds,
      expiresAt: seconds == null ? null : DateTime.now().add(Duration(seconds: seconds)),
    );
  }
}

/// The machine code of a Silo RFC 7807 problem: the last path segment of its
/// `type` (`invalid_token`, `session_expired`, `profile_verification_required`).
String? siloProblemCode(Object? data) {
  if (data is! Map) return null;
  final type = data['type'];
  if (type is! String || type.isEmpty) return null;
  final slash = type.lastIndexOf('/');
  return slash < 0 ? type : type.substring(slash + 1);
}

/// Human-readable detail of a Silo problem response, if any.
String? siloProblemDetail(Object? data) {
  if (data is! Map) return null;
  for (final key in const ['detail', 'title']) {
    final value = data[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

/// Thin HTTP layer over the Silo `/api/v2` contract.
///
/// Adds the device headers, `Authorization: Bearer`, and the profile headers
/// (`X-Profile-Id`, `X-Profile-Token`) to each request, and keeps the access
/// token fresh: proactively when it is about to expire, and reactively on a
/// 401 under a single-flight lock, so N parallel 401s cause one refresh. Silo
/// refresh tokens rotate, so every refreshed pair is reported through
/// [onTokensRefreshed] for persistence.
///
/// Every path must start with `/api/v2/`: the client never speaks the legacy
/// v1 surface.
class SiloApi {
  SiloApi({
    required String baseUrl,
    required this.device,
    this._tokens,
    this.profileId,
    this.profileToken,
    this.onTokensRefreshed,
    this.onSessionExpired,
    http.Client? client,
  }) : _http = MediaServerHttpClient(
         client: client,
         baseUrl: baseUrl,
         defaultHeaders: {'Accept': 'application/json', ...device.toHeaders()},
         connectTimeout: MediaServerTimeouts.connect,
       );

  final MediaServerHttpClient _http;
  final SiloDeviceHeaders device;
  SiloTokens? _tokens;
  String? profileId;
  String? profileToken;

  /// Called with each refreshed token pair. The old refresh token is dead
  /// once this fires, so the caller must persist the new one.
  FutureOr<void> Function(SiloTokens tokens)? onTokensRefreshed;

  /// Called once when a refresh is refused: the login session is gone and
  /// the user has to sign in again.
  void Function()? onSessionExpired;

  Future<SiloTokens?>? _refreshInFlight;

  String get baseUrl => _http.baseUrl;
  set baseUrl(String value) => _http.baseUrl = value;

  SiloTokens? get tokens => _tokens;
  String? get accessToken => _tokens?.accessToken;

  /// `scheme://host[:port]` of the base URL. Root-relative artwork and stream
  /// URLs resolve against the origin, not the (possibly path-prefixed) base.
  String get origin {
    final uri = Uri.parse(baseUrl);
    return uri.hasPort ? '${uri.scheme}://${uri.host}:${uri.port}' : '${uri.scheme}://${uri.host}';
  }

  /// Resolve a server-provided URL: absolute URLs stay as they are,
  /// root-relative ones are joined to [origin]. The query is never re-encoded.
  String resolveUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    if (url.startsWith('//')) return '${Uri.parse(baseUrl).scheme}:$url';
    return url.startsWith('/') ? '$origin$url' : '$origin/$url';
  }

  void close() => _http.close();
  Future<void> closeGracefully({Duration drainTimeout = const Duration(seconds: 2)}) =>
      _http.closeGracefully(drainTimeout: drainTimeout);

  Map<String, String> authHeaders({bool includeProfile = true}) {
    final token = _tokens?.accessToken;
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (includeProfile && profileId != null && profileId!.isNotEmpty) 'X-Profile-Id': profileId!,
      if (includeProfile && profileToken != null && profileToken!.isNotEmpty) 'X-Profile-Token': profileToken!,
    };
  }

  /// Send one request. Returns the raw response (callers decide which
  /// statuses are errors); use [send] to throw on any non-2xx status.
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
    if (!path.startsWith('/api/v2/')) {
      throw ArgumentError.value(path, 'path', 'Silo requests must target /api/v2/');
    }
    if (auth) await _refreshIfExpiring();
    var response = await _send(method, path, query, body, auth, profile, timeout, abort);
    if (auth && response.statusCode == 401 && _tokens != null) {
      final code = siloProblemCode(response.data);
      if (code != 'profile_verification_required') {
        final refreshed = await refreshTokens();
        if (refreshed != null) {
          response = await _send(method, path, query, body, auth, profile, timeout, abort);
        }
      }
    }
    return response;
  }

  /// [request], throwing [MediaServerHttpException] on any status >= 400.
  Future<MediaServerResponse> send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    bool auth = true,
    bool profile = true,
    Duration? timeout,
    AbortController? abort,
  }) async {
    final response = await request(
      method,
      path,
      query: query,
      body: body,
      auth: auth,
      profile: profile,
      timeout: timeout,
      abort: abort,
    );
    throwIfHttpError(response);
    return response;
  }

  /// GET returning the decoded JSON object, or throwing.
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? query,
    bool profile = true,
    Duration? timeout,
    AbortController? abort,
  }) async {
    final response = await send('GET', path, query: query, profile: profile, timeout: timeout, abort: abort);
    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    throw MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      statusCode: response.statusCode,
      requestUri: response.requestUri,
      message: 'Expected a JSON object from $path',
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
      'DELETE' => _deleteWithBody(path, query, headers, body, timeout, abort),
      _ => throw ArgumentError.value(method, 'method'),
    };
  }

  /// `DELETE /playback/{session}` carries a JSON body, which the shared
  /// client's `delete` does not take; route it through a raw request.
  Future<MediaServerResponse> _deleteWithBody(
    String path,
    Map<String, dynamic>? query,
    Map<String, String> headers,
    Object? body,
    Duration? timeout,
    AbortController? abort,
  ) async {
    if (body == null) {
      return _http.delete(path, queryParameters: query, headers: headers, timeout: timeout, abort: abort);
    }
    final uri = _http.buildUri(path, queryParameters: query);
    final request = http.Request('DELETE', uri)
      ..headers.addAll(_http.defaultHeaders)
      ..headers.addAll(headers)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);
    try {
      final streamed = await _http.inner.send(request).timeout(timeout ?? MediaServerTimeouts.receive);
      final response = await http.Response.fromStream(streamed);
      Object? data;
      if (response.body.isNotEmpty && (response.headers['content-type'] ?? '').contains('json')) {
        try {
          data = jsonDecode(response.body);
        } catch (_) {
          data = response.body;
        }
      }
      return MediaServerResponse(
        statusCode: response.statusCode,
        data: data,
        headers: response.headers,
        requestUri: uri,
      );
    } on TimeoutException {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.receiveTimeout,
        requestUri: uri,
        message: 'Timeout',
      );
    } catch (e) {
      if (e is MediaServerHttpException) rethrow;
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.connectionError,
        requestUri: uri,
        message: e.runtimeType.toString(),
      );
    }
  }

  /// Refresh before a request when the token's remaining life is at most
  /// min(60 s, lifetime / 2), as Silo's own clients do.
  Future<void> _refreshIfExpiring() async {
    final tokens = _tokens;
    final expiresAt = tokens?.expiresAt;
    if (tokens == null || expiresAt == null) return;
    final lifetime = tokens.lifetimeSeconds;
    var margin = const Duration(seconds: 60);
    if (lifetime != null && lifetime > 0 && lifetime ~/ 2 < 60) margin = Duration(seconds: lifetime ~/ 2);
    if (DateTime.now().isAfter(expiresAt.subtract(margin))) await refreshTokens();
  }

  /// Refresh when less than half of the access token's life is left, so a
  /// URL or header handed to the player now stays valid for as long as
  /// possible. No-op when the expiry is unknown.
  Future<void> refreshTokensIfHalfSpent() async {
    final tokens = _tokens;
    final expiresAt = tokens?.expiresAt;
    final lifetime = tokens?.lifetimeSeconds;
    if (tokens == null || expiresAt == null) return;
    final remaining = expiresAt.difference(DateTime.now());
    final half = Duration(seconds: (lifetime ?? 3600) ~/ 2);
    if (remaining < half) await refreshTokens();
  }

  /// Exchange the refresh token for a new pair. Single-flight: concurrent
  /// callers share one request. Returns `null` when the session cannot be
  /// refreshed (signed out, or no network).
  Future<SiloTokens?> refreshTokens() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final future = _doRefresh().whenComplete(() => _refreshInFlight = null);
    _refreshInFlight = future;
    return future;
  }

  Future<SiloTokens?> _doRefresh() async {
    final current = _tokens;
    if (current == null || current.refreshToken.isEmpty) return null;
    try {
      final response = await _http.post(
        '/api/v2/auth/refresh',
        body: {'refresh_token': current.refreshToken},
        timeout: MediaServerTimeouts.receive,
      );
      if (response.statusCode == 200) {
        final next = SiloTokens.fromJson(response.data);
        if (next == null) return null;
        _tokens = next;
        try {
          await onTokensRefreshed?.call(next);
        } catch (e, st) {
          appLogger.w('Silo: persisting refreshed tokens failed', error: e, stackTrace: st);
        }
        return next;
      }
      if (response.statusCode == 401 || response.statusCode == 400 || response.statusCode == 403) {
        appLogger.w('Silo: refresh refused (${siloProblemCode(response.data) ?? response.statusCode}); signed out');
        onSessionExpired?.call();
      }
      return null;
    } on MediaServerHttpException catch (e) {
      appLogger.d('Silo: token refresh failed', error: e);
      return null;
    }
  }
}
