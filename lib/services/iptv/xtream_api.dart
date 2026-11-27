import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import 'iptv_catchup.dart';
import 'json_array_splitter.dart';

/// The provider refused the username and password (`user_info.auth` 0, or
/// HTTP 401/403).
class XtreamAuthException implements Exception {
  const XtreamAuthException([this.status]);
  final String? status;
  @override
  String toString() => 'XtreamAuthException(${status ?? 'refused'})';
}

/// An Xtream request failed (transport, HTTP status or unreadable answer).
class XtreamRequestException implements Exception {
  const XtreamRequestException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'XtreamRequestException($message${statusCode == null ? '' : ', HTTP $statusCode'})';
}

/// Server address and login of an Xtream Codes compatible service.
class XtreamCredentials {
  XtreamCredentials({required String baseUrl, required this.username, required this.password})
    : baseUrl = normaliseBaseUrl(baseUrl);

  final String baseUrl;
  final String username;
  final String password;

  /// `host`, `host:port/`, `http://host/player_api.php?…` or `…/get.php?…`
  /// → `http(s)://host[:port][/prefix]` without a trailing slash.
  static String normaliseBaseUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return text;
    if (!text.contains('://')) text = 'http://$text';
    final uri = Uri.tryParse(text);
    if (uri == null) return text;
    var segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty && segments.last.endsWith('.php')) segments = segments.sublist(0, segments.length - 1);
    final path = segments.isEmpty ? '' : '/${segments.join('/')}';
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port$path';
  }

  /// The login of an M3U address of the `get.php?username=&password=` form
  /// Xtream services hand out, or null.
  static XtreamCredentials? fromM3uUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.path.endsWith('get.php')) return null;
    final user = uri.queryParameters['username'];
    final pass = uri.queryParameters['password'];
    if (user == null || user.isEmpty || pass == null || pass.isEmpty) return null;
    return XtreamCredentials(baseUrl: uri.toString(), username: user, password: pass);
  }
}

/// `player_api.php` without an action: `user_info` and `server_info`.
class XtreamAccount {
  const XtreamAccount({
    this.auth = true,
    this.status,
    this.expiresAt,
    this.isTrial = false,
    this.maxConnections,
    this.activeConnections,
    this.createdAt,
    this.allowedOutputFormats = const [],
    this.message,
    this.serverTimezone,
    this.serverUrl,
    this.port,
    this.httpsPort,
    this.serverProtocol,
    this.serverOffset,
  });

  final bool auth;

  /// `Active`, `Expired`, `Banned`, `Disabled`…
  final String? status;
  final DateTime? expiresAt;
  final bool isTrial;
  final int? maxConnections;
  final int? activeConnections;
  final DateTime? createdAt;
  final List<String> allowedOutputFormats;
  final String? message;
  final String? serverTimezone;
  final String? serverUrl;
  final String? port;
  final String? httpsPort;
  final String? serverProtocol;

  /// The server clock's offset from UTC (from `time_now` against
  /// `timestamp_now`), for archive URLs written in its local time.
  final Duration? serverOffset;

  bool get isActive => auth && (status == null || status!.toLowerCase() == 'active');

  factory XtreamAccount.fromJson(Map<String, dynamic> json) {
    final user = json['user_info'] is Map ? (json['user_info'] as Map).cast<String, dynamic>() : const {};
    final server = json['server_info'] is Map ? (json['server_info'] as Map).cast<String, dynamic>() : const {};
    final authRaw = user['auth'];
    final auth = !(authRaw == 0 || authRaw == '0' || authRaw == false);
    Duration? offset;
    final nowTs = xtreamInt(server['timestamp_now']);
    final nowText = server['time_now'];
    if (nowTs != null && nowText is String) {
      final local = DateTime.tryParse('${nowText.replaceFirst(' ', 'T')}Z');
      if (local != null) {
        final minutes = ((local.millisecondsSinceEpoch ~/ 1000 - nowTs) / 60).round();
        // Round to quarter hours: the two values are read a moment apart.
        offset = Duration(minutes: (minutes / 15).round() * 15);
      }
    }
    return XtreamAccount(
      auth: auth,
      status: xtreamString(user['status']),
      expiresAt: xtreamEpoch(user['exp_date']),
      isTrial: xtreamBool(user['is_trial']),
      maxConnections: xtreamInt(user['max_connections']),
      activeConnections: xtreamInt(user['active_cons']),
      createdAt: xtreamEpoch(user['created_at']),
      allowedOutputFormats: [
        if (user['allowed_output_formats'] is List)
          for (final f in user['allowed_output_formats'] as List)
            if (f is String && f.isNotEmpty) f,
      ],
      message: xtreamString(user['message']),
      serverTimezone: xtreamString(server['timezone']),
      serverUrl: xtreamString(server['url']),
      port: xtreamString(server['port']),
      httpsPort: xtreamString(server['https_port']),
      serverProtocol: xtreamString(server['server_protocol']),
      serverOffset: offset,
    );
  }

  Map<String, Object?> toJson() => {
    'auth': auth,
    'status': status,
    'expiresAt': expiresAt?.millisecondsSinceEpoch,
    'isTrial': isTrial,
    'maxConnections': maxConnections,
    'activeConnections': activeConnections,
    'createdAt': createdAt?.millisecondsSinceEpoch,
    'allowedOutputFormats': allowedOutputFormats,
    'serverTimezone': serverTimezone,
    'serverOffsetMinutes': serverOffset?.inMinutes,
  };

  static XtreamAccount? fromStoredJson(Object? raw) {
    if (raw is! Map) return null;
    DateTime? ms(Object? v) => v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;
    final offset = raw['serverOffsetMinutes'];
    return XtreamAccount(
      auth: raw['auth'] != false,
      status: raw['status'] as String?,
      expiresAt: ms(raw['expiresAt']),
      isTrial: raw['isTrial'] == true,
      maxConnections: raw['maxConnections'] as int?,
      activeConnections: raw['activeConnections'] as int?,
      createdAt: ms(raw['createdAt']),
      allowedOutputFormats: [
        if (raw['allowedOutputFormats'] is List) ...(raw['allowedOutputFormats'] as List).whereType<String>(),
      ],
      serverTimezone: raw['serverTimezone'] as String?,
      serverOffset: offset is int ? Duration(minutes: offset) : null,
    );
  }
}

class XtreamCategory {
  const XtreamCategory({required this.id, required this.name, this.parentId});
  final String id;
  final String name;
  final String? parentId;
}

/// One `get_short_epg` / `get_simple_data_table` listing (times epoch seconds).
class XtreamEpgEntry {
  const XtreamEpgEntry({
    required this.title,
    required this.start,
    required this.stop,
    this.description,
    this.hasArchive = false,
    this.epgId,
  });
  final String title;
  final int start;
  final int stop;
  final String? description;
  final bool hasArchive;
  final String? epgId;
}

String? xtreamString(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty || s == 'null' ? null : s;
}

int? xtreamInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v.trim()) ?? double.tryParse(v.trim())?.round();
  return null;
}

double? xtreamDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

bool xtreamBool(Object? v) => v == true || v == 1 || v == '1' || v == 'true';

DateTime? xtreamEpoch(Object? v) {
  final n = xtreamInt(v);
  return n == null || n <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(n * 1000);
}

/// Base64 text (Xtream encodes EPG titles and descriptions); plain text
/// passes through when it does not decode.
String xtreamMaybeBase64(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  try {
    final decoded = utf8.decode(base64.decode(base64.normalize(raw.trim())), allowMalformed: false);
    return decoded;
  } catch (_) {
    return raw;
  }
}

/// HTTP client for an Xtream Codes compatible `player_api.php`.
///
/// Never logs a URL: every request carries the login in its query string.
class XtreamApi {
  XtreamApi(
    this.credentials, {
    http.Client? client,
    this.userAgent,
    this.timeout = const Duration(seconds: 30),
    this.maxListRows = defaultMaxListRows,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final XtreamCredentials credentials;
  final http.Client _client;
  final bool _ownsClient;
  final String? userAgent;
  final Duration timeout;

  Map<String, String> get _headers => {'Accept': 'application/json', 'User-Agent': ?userAgent};

  Uri apiUri([Map<String, String> params = const {}]) => Uri.parse(
    '${credentials.baseUrl}/player_api.php',
  ).replace(queryParameters: {'username': credentials.username, 'password': credentials.password, ...params});

  Uri xmltvUri() => Uri.parse(
    '${credentials.baseUrl}/xmltv.php',
  ).replace(queryParameters: {'username': credentials.username, 'password': credentials.password});

  Future<Object?> _get(Map<String, String> params, {Duration? timeout}) async {
    final action = params['action'] ?? 'account';
    http.Response response;
    try {
      response = await _client.get(apiUri(params), headers: _headers).timeout(timeout ?? this.timeout);
    } on TimeoutException {
      appLogger.w('[iptv] xtream $action timed out');
      throw const XtreamRequestException('timeout');
    } catch (e) {
      appLogger.w('[iptv] xtream $action failed (${e.runtimeType})');
      throw XtreamRequestException(e.runtimeType.toString());
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      appLogger.w('[iptv] xtream $action refused HTTP ${response.statusCode}');
      throw XtreamAuthException('HTTP ${response.statusCode}');
    }
    if (response.statusCode >= 400) {
      appLogger.w('[iptv] xtream $action answered HTTP ${response.statusCode}');
      throw XtreamRequestException('http', statusCode: response.statusCode);
    }
    final body = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      appLogger.w('[iptv] xtream $action answered something other than JSON');
      throw const XtreamRequestException('not json');
    }
  }

  /// Account and server details. Throws [XtreamAuthException] when the login
  /// is refused.
  Future<XtreamAccount> account() async {
    final data = await _get(const {});
    if (data is! Map) throw const XtreamAuthException('no user_info');
    final account = XtreamAccount.fromJson(data.cast<String, dynamic>());
    if (!account.auth) throw XtreamAuthException(account.status);
    return account;
  }

  Future<List<XtreamCategory>> _categories(String action) async {
    final data = await _get({'action': action});
    return [
      if (data is List)
        for (final row in data.whereType<Map>())
          if (xtreamString(row['category_id']) case final id?)
            XtreamCategory(
              id: id,
              name: xtreamString(row['category_name']) ?? id,
              parentId: xtreamString(row['parent_id']),
            ),
    ];
  }

  Future<List<XtreamCategory>> liveCategories() => _categories('get_live_categories');
  Future<List<XtreamCategory>> vodCategories() => _categories('get_vod_categories');
  Future<List<XtreamCategory>> seriesCategories() => _categories('get_series_categories');

  /// The most rows a list may hold: far above any real catalogue (the largest
  /// seen have a few hundred thousand), it only stops an endless answer.
  static const defaultMaxListRows = 5000000;
  static const _sliceBytes = 32 * 1024;
  final int maxListRows;

  /// Rows of a large list (`get_live_streams`, `get_vod_streams`,
  /// `get_series`), handed to [onBatch] about [batchSize] at a time while the
  /// answer downloads: the list is never held whole, as bytes, text or rows
  /// ([JsonArraySplitter] decodes one row at a time). Returns the row count.
  /// An answer that ends early throws, so the caller keeps its old data.
  Future<int> forEachRow(
    String action,
    Future<void> Function(List<Map<String, dynamic>> rows) onBatch, {
    String? categoryId,
    int batchSize = 2000,
    Duration timeout = const Duration(minutes: 15),
  }) async {
    final request = http.Request('GET', apiUri({'action': action, 'category_id': ?categoryId}))
      ..headers.addAll(_headers);
    http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      appLogger.w('[iptv] xtream $action timed out');
      throw const XtreamRequestException('timeout');
    } catch (e) {
      appLogger.w('[iptv] xtream $action failed (${e.runtimeType})');
      throw XtreamRequestException(e.runtimeType.toString());
    }
    if (response.statusCode >= 400) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      if (response.statusCode == 401 || response.statusCode == 403) {
        appLogger.w('[iptv] xtream $action refused HTTP ${response.statusCode}');
        throw XtreamAuthException('HTTP ${response.statusCode}');
      }
      appLogger.w('[iptv] xtream $action answered HTTP ${response.statusCode}');
      throw XtreamRequestException('http', statusCode: response.statusCode);
    }
    final splitter = JsonArraySplitter();
    var batch = <Map<String, dynamic>>[];
    var rows = 0;
    final deadline = DateTime.now().add(timeout);
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
        final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        // A network chunk can be megabytes: split it so a batch stays near
        // [batchSize] rows.
        for (var at = 0; at < bytes.length && !splitter.done; at += _sliceBytes) {
          final end = at + _sliceBytes > bytes.length ? bytes.length : at + _sliceBytes;
          for (final element in splitter.add(Uint8List.sublistView(bytes, at, end))) {
            if (element is! Map) continue;
            batch.add(element.cast<String, dynamic>());
            rows++;
          }
          if (rows > maxListRows) throw const XtreamRequestException('too many rows');
          if (batch.length >= batchSize) {
            final full = batch;
            batch = [];
            await onBatch(full);
          }
        }
        if (DateTime.now().isAfter(deadline)) throw TimeoutException('list');
        if (splitter.done) break;
      }
      splitter.close();
      if (batch.isNotEmpty) await onBatch(batch);
      return rows;
    } on XtreamRequestException catch (e) {
      appLogger.w('[iptv] xtream $action stopped: ${e.message} after $rows rows');
      rethrow;
    } on XtreamAuthException {
      rethrow;
    } on TimeoutException {
      appLogger.w('[iptv] xtream $action timed out after $rows rows');
      throw const XtreamRequestException('timeout');
    } on FormatException {
      appLogger.w('[iptv] xtream $action answered something other than a JSON list (after $rows rows)');
      throw const XtreamRequestException('not json');
    }
  }

  Future<List<Map<String, dynamic>>> _rows(String action, {String? categoryId}) async {
    final all = <Map<String, dynamic>>[];
    await forEachRow(action, (rows) async => all.addAll(rows), categoryId: categoryId);
    return all;
  }

  /// The whole list at once: only for small lists (one category) and tests;
  /// imports use [forEachRow].
  Future<List<Map<String, dynamic>>> liveStreams({String? categoryId}) =>
      _rows('get_live_streams', categoryId: categoryId);
  Future<List<Map<String, dynamic>>> vodStreams({String? categoryId}) =>
      _rows('get_vod_streams', categoryId: categoryId);
  Future<List<Map<String, dynamic>>> series({String? categoryId}) => _rows('get_series', categoryId: categoryId);

  Future<Map<String, dynamic>?> vodInfo(String vodId) async {
    final data = await _get({'action': 'get_vod_info', 'vod_id': vodId});
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  Future<Map<String, dynamic>?> seriesInfo(String seriesId) async {
    final data = await _get({'action': 'get_series_info', 'series_id': seriesId});
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  /// `epg_listings` rows. Times are `start_timestamp`/`stop_timestamp`
  /// (UTC epoch), else `start`/`end` (`YYYY-MM-DD hh:mm:ss`, the server's
  /// local time: [serverOffset] from the account answer).
  static List<XtreamEpgEntry> parseListings(Object? data, {Duration serverOffset = Duration.zero}) {
    final rows = data is Map && data['epg_listings'] is List ? data['epg_listings'] as List : const [];
    final out = <XtreamEpgEntry>[];
    int? local(Object? v) {
      final text = xtreamString(v);
      if (text == null) return null;
      final parsed = DateTime.tryParse('${text.replaceFirst(' ', 'T')}Z');
      if (parsed == null) return null;
      return parsed.subtract(serverOffset).millisecondsSinceEpoch ~/ 1000;
    }

    for (final row in rows.whereType<Map>()) {
      final start = xtreamInt(row['start_timestamp']) ?? local(row['start']);
      final stop =
          xtreamInt(row['stop_timestamp']) ??
          xtreamInt(row['end_timestamp']) ??
          local(row['end']) ??
          local(row['stop']);
      if (start == null || stop == null) continue;
      out.add(
        XtreamEpgEntry(
          title: xtreamMaybeBase64(xtreamString(row['title'])),
          description: xtreamString(row['description']) == null
              ? null
              : xtreamMaybeBase64(xtreamString(row['description'])),
          start: start,
          stop: stop,
          hasArchive: xtreamBool(row['has_archive']),
          epgId: xtreamString(row['epg_id']) ?? xtreamString(row['channel_id']),
        ),
      );
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  Future<List<XtreamEpgEntry>> shortEpg(
    String streamId, {
    int limit = 4,
    Duration serverOffset = Duration.zero,
  }) async => parseListings(
    await _get({'action': 'get_short_epg', 'stream_id': streamId, 'limit': '$limit'}),
    serverOffset: serverOffset,
  );

  /// A channel's full listing (the provider's per-channel guide).
  Future<List<XtreamEpgEntry>> simpleDataTable(String streamId, {Duration serverOffset = Duration.zero}) async =>
      parseListings(await _get({'action': 'get_simple_data_table', 'stream_id': streamId}), serverOffset: serverOffset);

  String _u() => Uri.encodeComponent(credentials.username);
  String _p() => Uri.encodeComponent(credentials.password);

  String liveUrl(String streamId, {String extension = 'ts'}) =>
      '${credentials.baseUrl}/live/${_u()}/${_p()}/$streamId.$extension';

  String movieUrl(String streamId, String extension) =>
      '${credentials.baseUrl}/movie/${_u()}/${_p()}/$streamId.${extension.isEmpty ? 'mp4' : extension}';

  String seriesUrl(String episodeId, String extension) =>
      '${credentials.baseUrl}/series/${_u()}/${_p()}/$episodeId.${extension.isEmpty ? 'mp4' : extension}';

  String timeshiftUrl(
    String streamId, {
    required DateTime start,
    required Duration duration,
    Duration serverOffset = Duration.zero,
    bool phpRoute = false,
  }) => IptvCatchup.xtreamTimeshiftUrl(
    base: credentials.baseUrl,
    username: credentials.username,
    password: credentials.password,
    streamId: streamId,
    start: start,
    duration: duration,
    serverOffset: serverOffset,
    phpRoute: phpRoute,
  );

  void close() {
    if (_ownsClient) _client.close();
  }
}
