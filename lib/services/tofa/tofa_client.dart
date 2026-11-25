import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../../connection/connection.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../i18n/strings.g.dart';
import '../../media/artist_discography.dart';
import '../../media/download_resolution.dart';
import '../../media/ids.dart';
import '../../media/library_change_event.dart';
import '../../media/library_filter_result.dart';
import '../../media/library_genre.dart';
import '../../media/library_query.dart';
import '../../media/live_tv_support.dart';
import '../../media/lyrics.dart';
import '../../media/media_backend.dart';
import '../../media/media_file_info.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_person.dart';
import '../../media/media_playlist.dart';
import '../../media/media_server_client.dart';
import '../../media/media_sort.dart';
import '../../media/media_source_info.dart';
import '../../media/playback_report_metadata.dart';
import '../../media/server_capabilities.dart';
import '../../models/livetv_channel.dart';
import '../../models/livetv_program.dart';
import '../../models/transcode_quality_preset.dart';
import '../../mpv/mpv.dart';
import '../../utils/app_logger.dart';
import '../../utils/external_ids.dart';
import '../../utils/log_redaction_manager.dart';
import '../../utils/media_server_http_client.dart';
import '../../utils/url_utils.dart';
import '../api_cache.dart';
import '../playback_initialization_types.dart';
import '../scrub_preview_source.dart';
import 'tofa_api.dart';
import 'tofa_api_cache.dart';
import 'tofa_mappers.dart';
import 'tofa_playback_caps.dart';

/// One live Tofa stream session (`/stream/{file}/info`'s `session_id`).
class _TofaStreamSession {
  _TofaStreamSession({required this.sessionId, required this.token, required this.itemId, required this.fileId});

  final String sessionId;

  /// The session's `st` token for its `/stream/s/{sid}/…` routes.
  final String token;
  final String itemId;
  final String fileId;

  /// The server answered 410: the session is over and nothing more is sent.
  bool gone = false;
  bool stopped = false;
}

/// [MediaServerClient] for a Tofa media server, spoken over `/api/v1`.
///
/// One client is one [TofaConnection]: an account signed in on one server,
/// acting as one Tofa profile (`X-Profile-Id`, plus `X-Profile-Token` for a
/// locked profile). Browsing, watched state and playback are real; what
/// Tofa's public spec does not cover, or Plezilo's first Tofa version leaves
/// out (playlists, collections, people, live TV, downloads, sort and filter
/// lists whose values the spec does not enumerate), answers empty or throws
/// [UnsupportedError] as the other clients do.
class TofaClient implements MediaServerClient, ScopedMediaServerClient, GracefullyCloseable {
  TofaClient._({required this._connection, required this._api});

  /// Build a client for [connection]. Network I/O stays lazy.
  static Future<TofaClient> create(TofaConnection connection, {http.Client? httpClient}) async =>
      _build(connection, await TofaClientHeaders.resolve(), httpClient);

  @visibleForTesting
  static TofaClient forTesting(
    TofaConnection connection, {
    TofaClientHeaders headers = const TofaClientHeaders(
      clientVersion: '1.0',
      platform: 'android',
      deviceName: 'Test device',
    ),
    http.Client? httpClient,
  }) => _build(connection, headers, httpClient);

  static TofaClient _build(TofaConnection connection, TofaClientHeaders headers, http.Client? httpClient) {
    LogRedactionManager.registerRotatingToken(connection.accessToken);
    LogRedactionManager.registerRotatingToken(connection.refreshToken);
    LogRedactionManager.registerToken(connection.profileToken);
    LogRedactionManager.registerServerUrl(connection.baseUrl);
    final api = TofaApi(
      baseUrl: connection.baseUrl,
      connectUrl: connection.connectUrl,
      serverId: connection.serverId,
      headers: headers,
      tokens: TofaTokens(
        accessToken: connection.accessToken,
        refreshToken: connection.refreshToken,
        expiresAt: connection.accessTokenExpiresAt,
      ),
      profileId: connection.profileId,
      profileToken: connection.profileToken,
      client: httpClient,
    );
    final client = TofaClient._(connection: connection, api: api);
    api.onTokensRefreshed = client._handleTokensRefreshed;
    api.onSessionExpired = () => client._sessionExpired = true;
    return client;
  }

  TofaConnection _connection;
  TofaConnection get connection => _connection;
  final TofaApi _api;

  bool _offlineMode = false;
  bool _sessionExpired = false;
  bool _closed = false;

  /// Persists connection changes (rotated tokens, admin role). Wired by
  /// `MultiServerManager`, which writes only the tokens of a row this
  /// sign-in still owns. Awaited before a refreshed pair is used.
  FutureOr<void> Function(TofaConnection connection)? onConnectionUpdated;

  /// Every refresh token this client has held: a row read before a rotation
  /// was persisted still names this sign-in.
  late final Set<String> _knownRefreshTokens = {_connection.refreshToken};

  bool ownsRefreshToken(String refreshToken) => _knownRefreshTokens.contains(refreshToken);

  /// Take over the sign-in of [previous], the client this one replaces: its
  /// current pair (newer than a row read before a rotation was stored) and
  /// every refresh token it held. Call before the first request.
  void inheritSession(TofaClient previous) {
    _knownRefreshTokens.addAll(previous._knownRefreshTokens);
    final current = previous.connection;
    if (current.refreshToken != _connection.refreshToken) {
      _knownRefreshTokens.add(current.refreshToken);
      _api.replaceTokens(
        TofaTokens(
          accessToken: current.accessToken,
          refreshToken: current.refreshToken,
          expiresAt: current.accessTokenExpiresAt,
        ),
      );
      _connection = _connection.copyWith(
        accessToken: current.accessToken,
        refreshToken: current.refreshToken,
        accessTokenExpiresAt: current.accessTokenExpiresAt,
      );
    }
  }

  Future<void> _handleTokensRefreshed(TofaTokens tokens) async {
    LogRedactionManager.registerRotatingToken(tokens.accessToken);
    LogRedactionManager.registerRotatingToken(tokens.refreshToken);
    _sessionExpired = false;
    _knownRefreshTokens.add(tokens.refreshToken);
    _connection = _connection.copyWith(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      accessTokenExpiresAt: tokens.expiresAt,
    );
    await onConnectionUpdated?.call(_connection);
  }

  TofaMappingContext get _ctx => TofaMappingContext(serverId: serverId.value, serverName: serverName);

  static String _seg(String id) => Uri.encodeComponent(id);

  // ---------------------------------------------------------------------------
  // Identity and lifecycle
  // ---------------------------------------------------------------------------

  @override
  ServerId get serverId => ServerId(connection.serverId);

  @override
  String get scopedServerId => connection.id;

  @override
  String? get serverName => connection.serverName;

  @override
  MediaBackend get backend => MediaBackend.tofa;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.tofa;

  @override
  final Object authenticationSessionId = Object();

  @override
  LibraryEventChannel? createLibraryEventChannel() => null;

  @override
  void close() {
    _closed = true;
    _imageTokenTimer?.cancel();
    _api.close();
  }

  @override
  Future<void> closeGracefully({Duration drainTimeout = const Duration(seconds: 2)}) async {
    _closed = true;
    _imageTokenTimer?.cancel();
    await _api.closeGracefully(drainTimeout: drainTimeout);
  }

  @override
  bool get isOfflineMode => _offlineMode;

  @override
  void setOfflineMode(bool offline) => _offlineMode = offline;

  @override
  ApiCache get cache => TofaApiCache.instance;

  TofaApiCache? get _tofaCache {
    try {
      return TofaApiCache.instance;
    } catch (_) {
      return null;
    }
  }

  /// Authenticated round-trip on `/api/v1/users/me`. Only a refused refresh
  /// (or a 401 with no refresh token) is [HealthStatus.authError]; a 403 is
  /// [HealthStatus.accessDenied] (the account or the profile is refused).
  @override
  Future<HealthStatus> checkHealth() async {
    try {
      final response = await _api.request('GET', '/api/v1/users/me', timeout: const Duration(seconds: 10));
      if (response.statusCode == 200) {
        _sessionExpired = false;
        final data = response.data;
        if (data is Map && data['is_admin'] is bool && data['is_admin'] != _connection.isAdministrator) {
          _connection = _connection.copyWith(isAdministrator: data['is_admin'] as bool);
          try {
            await onConnectionUpdated?.call(_connection);
          } catch (e, st) {
            appLogger.w('[tofa] persisting the connection update failed', error: e, stackTrace: st);
          }
        }
        unawaited(_ensureImageToken().catchError((_) => null));
        return HealthStatus.online;
      }
      if (_sessionExpired || (response.statusCode == 401 && (_api.tokens?.refreshToken ?? '').isEmpty)) {
        return HealthStatus.authError;
      }
      if (response.statusCode == 403) {
        appLogger.w('[tofa] server refused the account or profile (${tofaErrorCode(response.data) ?? 'no code'})');
        return HealthStatus.accessDenied;
      }
      return HealthStatus.offline;
    } on MediaServerHttpException catch (e) {
      if (_sessionExpired) return HealthStatus.authError;
      return e.statusCode == 403 ? HealthStatus.accessDenied : HealthStatus.offline;
    } catch (_) {
      return HealthStatus.offline;
    }
  }

  @override
  Future<String?> getMachineIdentifier() async => connection.serverId;

  // ---------------------------------------------------------------------------
  // Artwork (`/api/v1/artwork/{media_id}/{kind}?st=`)
  // ---------------------------------------------------------------------------

  ({String token, DateTime expiresAt})? _imageToken;
  Future<void>? _imageTokenInFlight;
  Timer? _imageTokenTimer;

  /// The image token (`GET /api/v1/auth/image-token`), renewed once 80% of
  /// its life is spent, one request in flight. Players and image views cannot
  /// send headers, so artwork URLs carry it as `st`.
  Future<void> _ensureImageToken() {
    final current = _imageToken;
    if (current != null && DateTime.now().isBefore(current.expiresAt)) return Future.value();
    return _imageTokenInFlight ??= _fetchImageToken().whenComplete(() => _imageTokenInFlight = null);
  }

  Future<void> _fetchImageToken() async {
    if (_closed || _offlineMode) return;
    final data = await _api.getJson('/api/v1/auth/image-token');
    final token = data is Map ? data['token'] : null;
    final expiresIn = data is Map ? data['expires_in'] : null;
    if (token is! String || token.isEmpty) return;
    LogRedactionManager.registerRotatingToken(token);
    final life = Duration(seconds: expiresIn is int && expiresIn > 0 ? expiresIn : 3600);
    final renewAt = Duration(milliseconds: life.inMilliseconds * 4 ~/ 5);
    _imageToken = (token: token, expiresAt: DateTime.now().add(renewAt));
    _imageTokenTimer?.cancel();
    _imageTokenTimer = Timer(renewAt, () {
      if (!_closed) unawaited(_ensureImageToken().catchError((_) => null));
    });
  }

  @visibleForTesting
  Future<void> ensureImageTokenForTesting() => _ensureImageToken();

  /// Artwork URL for a mapped item's path: a `tofa-artwork:` path becomes
  /// the artwork route with the image token; an absolute URL stays as is;
  /// anything else (an undocumented raw path) is not guessed at and draws
  /// nothing. Never carries the bearer.
  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    if (path == null || path.isEmpty) return '';
    if (path.startsWith('https://') || path.startsWith('http://')) return path;
    final art = TofaMappers.parseArtworkPath(path);
    if (art == null) return '';
    final token = _imageToken?.token;
    if (token == null) {
      // Draw nothing rather than a URL the server would refuse; the token is
      // read at the next health check, or now.
      unawaited(_ensureImageToken().catchError((_) => null));
      return '';
    }
    final query = <String, String>{
      'st': token,
      if (width != null && width > 0) 'w': '$width',
      if (height != null && height > 0) 'h': '$height',
    };
    return _api.resolveUrl('/api/v1/artwork/${_seg(art.mediaId)}/${art.kind}?${encodeQueryParameters(query)}');
  }

  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;

  /// Tofa's stream URLs carry their own `st` token: the player gets no
  /// header, never the bearer.
  @override
  Map<String, String> get streamHeaders => const {};

  // ---------------------------------------------------------------------------
  // Libraries
  // ---------------------------------------------------------------------------

  final Map<String, String> _libraryTitles = {};

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    final data = await _api.getJson('/api/v1/libraries');
    final libraries = <MediaLibrary>[];
    if (data is List) {
      final rows = data.whereType<Map<String, dynamic>>().toList()
        ..sort((a, b) => ((a['sort_order'] as num?) ?? 0).compareTo((b['sort_order'] as num?) ?? 0));
      for (final row in rows) {
        final library = TofaMappers.library(row, _ctx);
        if (library == null) continue;
        _libraryTitles[library.id] = library.title;
        libraries.add(library);
      }
    }
    return libraries;
  }

  /// Unverified: the spec leaves `sort` / `order` free strings, so no sort is
  /// offered and the server's default order is used.
  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => const [];

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async =>
      LibraryFilterResult.empty;

  @override
  Future<List<LibraryGenre>> fetchLibraryGenres(String libraryId, {required MediaKind libraryKind}) async => const [];

  @override
  Future<void> refreshLibraryMetadata(String libraryId) =>
      throw UnsupportedError('Tofa library scans are started from the server.');

  @override
  Future<void> scanLibrary(String libraryId) =>
      throw UnsupportedError('Tofa library scans are started from the server.');

  /// Map Plezilo's offset paging onto Tofa's `page` / `per_page`: the pages
  /// of size [limit] that cover `[offset, offset + limit)`, sliced.
  @visibleForTesting
  static List<({int page, int skip})> pagesFor(int offset, int limit) {
    final first = offset ~/ limit + 1;
    final skip = offset % limit;
    return [(page: first, skip: skip), if (skip > 0) (page: first + 1, skip: 0)];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    final limit = query.limit <= 0 ? 50 : query.limit;
    final prefix = query.nameStartsWith;
    String? letter;
    if (prefix != null && prefix.isNotEmpty) {
      // Unverified: `letter`'s format. A single letter is sent as is; "#"
      // (not a letter) and longer prefixes are not guessed at: an empty page
      // beats a list that claims to be filtered and is not.
      if (!RegExp(r'^[A-Za-z]$').hasMatch(prefix)) {
        appLogger.d('[tofa] letter filter "$prefix" not sent (format unverified); empty page');
        return LibraryPage(items: const [], totalCount: 0, offset: query.offset);
      }
      letter = prefix.toUpperCase();
    }
    final kind = query.kind ?? (query.includeKinds.length == 1 ? query.includeKinds.single : null);
    final params = <String, String>{
      'library_id': libraryId,
      if (kind == MediaKind.movie) 'media_type': 'movie',
      if (kind == MediaKind.show) 'media_type': 'tv',
      if (query.search case final q? when q.trim().isNotEmpty) 'q': q.trim(),
      'letter': ?letter,
    };
    final items = <MediaItem>[];
    var total = 0;
    var any = false;
    for (final (:page, :skip) in pagesFor(query.offset, limit)) {
      final data = await _api.getJson(
        '/api/v1/media',
        query: {...params, 'page': '$page', 'per_page': '$limit'},
        abort: abort,
      );
      if (data is! Map) break;
      any = true;
      total = (data['total'] as num?)?.toInt() ?? total;
      final rows = data['items'] is List
          ? (data['items'] as List).whereType<Map<String, dynamic>>().toList()
          : const [];
      final mapped = [for (final row in rows) ?TofaMappers.summary(row, _ctx, libraryTitle: _libraryTitles[libraryId])];
      items.addAll(mapped.skip(skip));
      if (rows.length < limit) break;
    }
    final pageItems = items.take(limit).toList();
    return LibraryPage(
      items: pageItems,
      totalCount: any ? total : fallbackPageTotal(offset: query.offset, itemCount: pageItems.length),
      offset: query.offset,
    );
  }

  // ---------------------------------------------------------------------------
  // Items
  // ---------------------------------------------------------------------------

  /// Recent `/media/{id}` details with their files' watch progress, so a
  /// detail page's season and episode reads reuse the one tree a series
  /// detail carries. [fetchItem] always reads fresh.
  final LinkedHashMap<String, ({DateTime at, Map<String, dynamic> json, Map<String, Map<String, dynamic>> progress})>
  _details = LinkedHashMap();
  final Map<String, Future<({Map<String, dynamic> json, Map<String, Map<String, dynamic>> progress})?>> _detailFetches =
      {};
  static const _maxDetails = 12;
  static const _detailFreshness = Duration(minutes: 2);

  /// A title's detail and its files' progress, sharing one in-flight read.
  /// Null on a 404.
  Future<({Map<String, dynamic> json, Map<String, Map<String, dynamic>> progress})?> _detail(
    String mediaId, {
    bool fresh = false,
  }) {
    if (!fresh) {
      final row = _details[mediaId];
      if (row != null && DateTime.now().difference(row.at) < _detailFreshness) {
        return Future.value((json: row.json, progress: row.progress));
      }
    }
    final pending = _detailFetches[mediaId];
    if (pending != null && !fresh) return pending;
    final future = () async {
      final response = await _api.request('GET', '/api/v1/media/${_seg(mediaId)}');
      if (response.statusCode == 404) return null;
      TofaApi.throwIfTofaError(response);
      final json = response.data;
      if (json is! Map<String, dynamic>) {
        throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, message: 'Expected a media detail');
      }
      final progress = await _progressFor(_allFileIds(json));
      _details.remove(mediaId);
      _details[mediaId] = (at: DateTime.now(), json: json, progress: progress);
      while (_details.length > _maxDetails) {
        _details.remove(_details.keys.first);
      }
      return (json: json, progress: progress);
    }();
    _detailFetches[mediaId] = future;
    return future.whenComplete(() {
      if (identical(_detailFetches[mediaId], future)) _detailFetches.remove(mediaId);
    });
  }

  static List<String> _allFileIds(Map<String, dynamic> detail) {
    final ids = <String>[for (final f in TofaMappers.playableFiles(detail['files'])) f['id'] as String];
    final seasons = detail['seasons'];
    if (seasons is List) {
      for (final season in seasons.whereType<Map>()) {
        final episodes = season['episodes'];
        if (episodes is! List) continue;
        for (final episode in episodes.whereType<Map>()) {
          ids.addAll([for (final f in TofaMappers.playableFiles(episode['files'])) f['id'] as String]);
        }
      }
    }
    return ids;
  }

  /// `POST /api/v1/media/progress/batch` (at most 500 file ids per request,
  /// read in parallel). A failed read leaves the watch state unknown rather
  /// than failing the detail.
  Future<Map<String, Map<String, dynamic>>> _progressFor(List<String> fileIds) async {
    if (fileIds.isEmpty) return const {};
    final chunks = [
      for (var i = 0; i < fileIds.length; i += 500) fileIds.sublist(i, (i + 500).clamp(0, fileIds.length)),
    ];
    try {
      final answers = await Future.wait([
        for (final chunk in chunks) _api.send('POST', '/api/v1/media/progress/batch', body: {'media_file_ids': chunk}),
      ]);
      final out = <String, Map<String, dynamic>>{};
      for (final response in answers) {
        final data = response.data;
        final items = data is Map ? data['items'] : null;
        if (items is! List) continue;
        for (final row in items.whereType<Map<String, dynamic>>()) {
          final id = row['media_file_id'];
          if (id is String) out[id] = row;
        }
      }
      return out;
    } on MediaServerHttpException catch (e) {
      if (e.isCancellation) rethrow;
      appLogger.w('[tofa] watch progress read failed (HTTP ${e.statusCode}); watch state unknown');
      return const {};
    }
  }

  TofaMediaItem? _mapDetail(
    String mediaId,
    ({Map<String, dynamic> json, Map<String, Map<String, dynamic>> progress}) d,
  ) {
    final libraryId = d.json['library_id'];
    return TofaMappers.detail(
      d.json,
      _ctx,
      progress: d.progress,
      libraryTitle: libraryId is String ? _libraryTitles[libraryId] : null,
    );
  }

  @override
  Future<MediaItem?> fetchItem(String id) => _fetchItem(id, fresh: true);

  Future<MediaItem?> _fetchItem(String id, {bool fresh = false}) async {
    final mediaId = TofaMappers.mediaIdOf(id);
    final d = await _detail(mediaId, fresh: fresh);
    if (d == null) return null;
    final title = _mapDetail(mediaId, d);
    if (title == null) return null;
    final MediaItem? item;
    if (TofaMappers.parseSeasonId(id) case final ref?) {
      item = _findSeason(d, title, ref.childId);
    } else if (TofaMappers.parseEpisodeId(id) case final ref?) {
      item = _findEpisode(d, title, ref.childId);
    } else {
      item = title;
    }
    if (item != null) unawaited(_tofaCache?.putItem(ServerId(cacheServerId), item).catchError((_) {}));
    return item;
  }

  TofaMediaItem? _findSeason(
    ({Map<String, dynamic> json, Map<String, Map<String, dynamic>> progress}) d,
    TofaMediaItem show,
    String seasonId,
  ) {
    final seasons = d.json['seasons'];
    if (seasons is! List) return null;
    for (final season in seasons.whereType<Map<String, dynamic>>()) {
      if (season['id'] == seasonId) return TofaMappers.season(season, show, _ctx, progress: d.progress);
    }
    return null;
  }

  TofaMediaItem? _findEpisode(
    ({Map<String, dynamic> json, Map<String, Map<String, dynamic>> progress}) d,
    TofaMediaItem show,
    String episodeId,
  ) {
    final seasons = d.json['seasons'];
    if (seasons is! List) return null;
    for (final season in seasons.whereType<Map<String, dynamic>>()) {
      for (final episode in TofaMappers.episodes(season, show, _ctx, progress: d.progress)) {
        if (episode.raw?[TofaRaw.episodeId] == episodeId) return episode;
      }
    }
    return null;
  }

  /// Every episode of a series in season and episode order; specials
  /// (season 0) last.
  List<TofaMediaItem> _allEpisodes(
    ({Map<String, dynamic> json, Map<String, Map<String, dynamic>> progress}) d,
    TofaMediaItem show, {
    bool includeSpecials = true,
  }) {
    final seasons = d.json['seasons'];
    if (seasons is! List) return const [];
    final bySeason = <int, List<TofaMediaItem>>{};
    for (final season in seasons.whereType<Map<String, dynamic>>()) {
      final number = (season['season_number'] as num?)?.toInt();
      if (number == null || (!includeSpecials && number == 0)) continue;
      bySeason[number] = TofaMappers.episodes(season, show, _ctx, progress: d.progress);
    }
    final numbers = bySeason.keys.toList()..sort((a, b) => a == 0 ? 1 : (b == 0 ? -1 : a.compareTo(b)));
    return [for (final n in numbers) ...bySeason[n]!];
  }

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async {
    final item = await fetchItem(id);
    if (item == null || item.kind != MediaKind.show) return (item: item, onDeckEpisode: null);
    final d = await _detail(id);
    if (d == null || item is! TofaMediaItem) return (item: item, onDeckEpisode: null);
    final nextUp = d.json['next_up'];
    final episodeId = nextUp is Map ? nextUp['episode_id'] : null;
    TofaMediaItem? onDeck = episodeId is String ? _findEpisode(d, item, episodeId) : null;
    // A resume point Tofa names that the progress read did not carry.
    final position = nextUp is Map ? (nextUp['position_ms'] as num?)?.toInt() : null;
    if (onDeck != null && nextUp is Map && nextUp['kind'] == 'resume' && position != null && position > 0) {
      onDeck = onDeck.copyWith(viewOffsetMs: position);
    }
    return (item: item, onDeckEpisode: onDeck);
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    final mediaId = TofaMappers.mediaIdOf(parentId);
    final d = await _detail(mediaId);
    if (d == null) return const [];
    final show = _mapDetail(mediaId, d);
    if (show == null) return const [];
    if (TofaMappers.parseSeasonId(parentId) case final ref?) {
      final seasons = d.json['seasons'];
      if (seasons is! List) return const [];
      for (final season in seasons.whereType<Map<String, dynamic>>()) {
        if (season['id'] == ref.childId) return TofaMappers.episodes(season, show, _ctx, progress: d.progress);
      }
      return const [];
    }
    if (show.kind == MediaKind.show) return TofaMappers.seasons(d.json, show, _ctx, progress: d.progress);
    return const [];
  }

  LibraryPage<MediaItem> _pageOf(List<MediaItem> all, int? start, int? size) {
    final from = (start ?? 0).clamp(0, all.length);
    final to = size == null ? all.length : (from + size).clamp(from, all.length);
    return LibraryPage(items: all.sublist(from, to), totalCount: all.length, offset: from);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _pageOf(await fetchChildren(parentId), start, size);

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async {
    if (TofaMappers.parseSeasonId(parentId) != null) return fetchChildren(parentId);
    final d = await _detail(parentId);
    if (d == null) return const [];
    final show = _mapDetail(parentId, d);
    if (show == null) return const [];
    if (show.kind == MediaKind.movie) return [show];
    return _allEpisodes(d, show);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _pageOf(await fetchPlayableDescendants(parentId), start, size);

  /// Every episode in playback order, specials left out when the series has
  /// numbered seasons.
  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) async {
    final mediaId = TofaMappers.mediaIdOf(seriesId);
    final d = await _detail(mediaId);
    if (d == null) return const [];
    final show = _mapDetail(mediaId, d);
    if (show == null) return const [];
    final numbered = _allEpisodes(d, show, includeSpecials: false);
    return numbered.isNotEmpty ? numbered : _allEpisodes(d, show);
  }

  @override
  Future<List<MediaItem>> fetchLibraryFolders(
    String libraryId, {
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async => const [];

  @override
  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) async => const [];

  @override
  Future<List<MediaItem>> fetchArtistAlbums(MediaItem artist) async => const [];

  @override
  Future<List<ArtistDiscographyGroup>> fetchArtistDiscography(MediaItem artist) async => const [];

  @override
  Future<List<MediaItem>> fetchAlbumTracks(String albumId) async => const [];

  @override
  Future<List<MediaItem>> fetchInstantMix(String itemId, {int limit = 100}) async => const [];

  @override
  Future<Lyrics?> fetchLyrics(MediaItem track) async => null;

  // ---------------------------------------------------------------------------
  // Search and Home
  // ---------------------------------------------------------------------------

  /// `GET /api/v1/search`: its `movies` list (movies and series). Actors,
  /// collections and `discover` (titles not in the library) are left out.
  /// Rows carry `library_id`, so the caller drops hidden libraries.
  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final data = await _api.getJson(
      '/api/v1/search',
      query: {'q': q, 'limit': '$limit', 'movie_limit': '$limit', 'actor_limit': '0', 'discover_limit': '0'},
      abort: abort,
    );
    final rows = data is Map && data['movies'] is List ? data['movies'] as List : const [];
    return [
      for (final row in rows.whereType<Map<String, dynamic>>())
        ?TofaMappers.summary(row, _ctx, libraryTitle: _libraryTitles[row['library_id']]),
    ];
  }

  /// People search is not offered: Plezilo cannot list a person's titles
  /// on Tofa yet ([fetchPersonMediaPage]), and every person returned must
  /// open a non-empty page.
  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async => const [];

  /// `GET /api/v1/users/me/continue`, in the server's order.
  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async {
    final data = await _api.getJson('/api/v1/users/me/continue');
    final rows = data is List ? data.whereType<Map<String, dynamic>>() : const <Map<String, dynamic>>[];
    final items = continueWatchingInServerOrder([for (final row in rows) ?TofaMappers.continueWatching(row, _ctx)]);
    // Rows carry no library id: hidden libraries cannot be left out here.
    if (excludedLibraryIds.isNotEmpty) {
      appLogger.d('[tofa] Continue Watching rows carry no library; hidden libraries are not filtered');
    }
    return count == null ? items : items.take(count).toList();
  }

  /// Keeps the server's order in the shelf, which re-sorts by recency: each
  /// row's key is its own `updated_at`, kept a second below the row above.
  @visibleForTesting
  static List<MediaItem> continueWatchingInServerOrder(List<MediaItem> items, {int? now}) {
    int? previous;
    return [
      for (final item in items)
        () {
          final own = item.lastViewedAt;
          final key = previous == null
              ? (own ?? now ?? DateTime.now().millisecondsSinceEpoch ~/ 1000)
              : ((own ?? previous! - 1) < previous! - 1 ? own! : previous! - 1);
          previous = key;
          return item.copyWith(raw: {...?item.raw, MediaItem.continueWatchingRecencyKey: key});
        }(),
    ];
  }

  /// Home rows beyond Continue Watching: none yet. Tofa documents no
  /// "recently added" list (`/media`'s sort values are not enumerated), and
  /// Continue Watching is read through [fetchContinueWatching].
  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async => const [];

  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) async => const [];

  /// `GET /api/v1/media/{id}/similar`'s `owned` titles as "More Like This".
  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) async {
    if (TofaMappers.parseSeasonId(id) != null || TofaMappers.parseEpisodeId(id) != null) return const [];
    final response = await _api.request('GET', '/api/v1/media/${_seg(id)}/similar');
    if (response.statusCode == 404 || response.statusCode == 503) return const [];
    TofaApi.throwIfTofaError(response);
    final data = response.data;
    final rows = data is Map && data['owned'] is List ? data['owned'] as List : const [];
    final items = [
      for (final row in rows.whereType<Map<String, dynamic>>()) ?TofaMappers.summary(row, _ctx),
    ].take(count).toList();
    if (items.isEmpty) return const [];
    return [
      MediaHub(
        id: 'tofa:similar:$id',
        identifier: 'item.$id.similar',
        title: t.discover.moreLikeThis,
        type: 'mixed',
        items: items,
        size: items.length,
        serverId: serverId.value,
        serverName: serverName,
      ),
    ];
  }

  @override
  Future<List<MediaItem>> fetchExtras(String id) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPersonDetails> fetchPersonDetails(String personId, {AbortController? abort}) async =>
      MediaPersonDetails.empty;

  @override
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(
    String hubId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  // ---------------------------------------------------------------------------
  // Watch state
  // ---------------------------------------------------------------------------

  /// Watched / unwatched, per Tofa's id kinds: a movie's or episode's files
  /// (`PUT /media/{file_id}/watched`), a season (`PUT /seasons/{id}/watched`),
  /// a series (`PUT /shows/{id}/watched`). Tofa marks every version of a
  /// title together, and clears the resume point of a watched file.
  Future<void> _setWatched(MediaItem item, bool watched) async {
    final body = {'watched': watched};
    switch (item.kind) {
      case MediaKind.show:
        await _api.send('PUT', '/api/v1/shows/${_seg(item.id)}/watched', body: body);
      case MediaKind.season:
        final seasonId = TofaMappers.parseSeasonId(item.id)?.childId;
        if (seasonId == null) throw StateError('Not a Tofa season id');
        await _api.send('PUT', '/api/v1/seasons/${_seg(seasonId)}/watched', body: body);
      default:
        final files = await _fileIdsForWrite(item);
        if (files.isEmpty) {
          appLogger.w('[tofa] not marked: no file is known for ${item.kind.id}');
          throw StateError('No Tofa file to mark');
        }
        await Future.wait([
          for (final file in files) _api.send('PUT', '/api/v1/media/${_seg(file)}/watched', body: body),
        ]);
    }
    _details.remove(TofaMappers.mediaIdOf(item.id));
    appLogger.d('[tofa] marked ${item.kind.id} watched=$watched');
  }

  /// The file ids a write acts on: the item's own, else those of a fresh read
  /// of it (a Continue Watching card names only the file it resumes).
  Future<List<String>> _fileIdsForWrite(MediaItem item) async {
    final known = TofaMappers.fileIdsOf(item);
    if (known.isNotEmpty) return known;
    final fresh = await _fetchItem(item.id);
    return fresh == null ? const [] : TofaMappers.fileIdsOf(fresh);
  }

  @override
  Future<void> markWatched(MediaItem item) => _setWatched(item, true);

  @override
  Future<void> markUnwatched(MediaItem item) => _setWatched(item, false);

  /// `POST /api/v1/users/me/dismiss/{media_id}`: the title leaves Continue
  /// Watching and recommendations (an episode card dismisses its series).
  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {
    final mediaId = item.raw?[TofaRaw.mediaId] as String? ?? TofaMappers.mediaIdOf(item.id);
    await _api.send('POST', '/api/v1/users/me/dismiss/${_seg(mediaId)}');
  }

  @override
  Future<void> rate(MediaItem item, double rating) => throw UnsupportedError('Tofa has no user ratings in Plezilo.');

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) => throw UnsupportedError('Tofa has no favorites.');

  // ---------------------------------------------------------------------------
  // Playlists and collections (not in Plezilo's first Tofa version)
  // ---------------------------------------------------------------------------

  static Never _unsupported(String what) => throw UnsupportedError('Plezilo does not support $what on Tofa.');

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) async => null;

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) async =>
      const LibraryPage(items: [], totalCount: 0);

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) =>
      _unsupported('playlists');

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) => _unsupported('playlists');

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) => _unsupported('playlists');

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) => _unsupported('playlists');

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) => _unsupported('playlists');

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<List<CollectionMembership>> fetchCollectionMemberships(Set<String> itemIds, {AbortController? abort}) async =>
      const [];

  @override
  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
  }) => _unsupported('editing collections');

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) =>
      _unsupported('editing collections');

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) =>
      _unsupported('editing collections');

  @override
  Future<bool> deleteCollection(MediaItem collection) => _unsupported('editing collections');

  @override
  Future<bool> deleteMediaItem(MediaItem item) => _unsupported('deleting media');

  @override
  Future<MediaFileInfo?> getFileInfo(MediaItem item) async => null;

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    if (TofaMappers.parseSeasonId(itemId) != null || TofaMappers.parseEpisodeId(itemId) != null) {
      return const ExternalIds();
    }
    final item = await fetchItem(itemId);
    final raw = item?.raw;
    if (raw == null) return const ExternalIds();
    final imdb = raw[TofaRaw.imdbId];
    final tvdb = raw['tvdb_id'];
    return ExternalIds(
      imdb: imdb is String && imdb.isNotEmpty ? imdb : null,
      tmdb: raw[TofaRaw.tmdbId] is int ? raw[TofaRaw.tmdbId] as int : null,
      tvdb: tvdb is String ? int.tryParse(tvdb) : null,
    );
  }

  /// Not supported yet: Tofa's TMDB lookup (`/media/by-tmdb/{tmdb_id}`) is a
  /// follow-up. Null means "this backend cannot run the query".
  @override
  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async => null;

  // ---------------------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------------------

  /// Live sessions by `session_id`.
  final Map<String, _TofaStreamSession> _sessions = {};

  /// The file playback last opened for each item, for reports without a
  /// session (offline sync, external players).
  final Map<String, String> _playingFileIds = {};

  @override
  double get watchedThreshold => 0.9;

  /// The server marks a file watched from progress past its own threshold
  /// (end credits or 90%), so the player does not mark it again.
  @override
  bool get marksWatchedOnPlaybackStopped => true;

  @override
  LiveTvSupport get liveTv => const _TofaNoLiveTv();

  /// The file to play for [item]: [requestedFileId] when it is one of the
  /// item's files, else the one `GET /media/{id}/versions` recommends for
  /// this device, else the only file. Never the first of several by
  /// position. Throws [PlaybackException] when no file can be chosen.
  @visibleForTesting
  Future<String> chooseFile(MediaItem item, {String? requestedFileId}) async {
    var files = TofaMappers.fileIdsOf(item);
    if (files.isEmpty) {
      final fresh = await _fetchItem(item.id, fresh: true);
      files = fresh == null ? const [] : TofaMappers.fileIdsOf(fresh);
    }
    if (files.isEmpty) {
      throw PlaybackException(t.messages.playbackNoMediaSources, reason: PlaybackFailureReason.noPlayableSource);
    }
    if (requestedFileId != null && files.contains(requestedFileId)) return requestedFileId;
    if (files.length == 1) return files.single;
    final recommended = await _recommendedFile(item);
    if (recommended != null && files.contains(recommended)) {
      appLogger.d('[tofa] playing the recommended file of ${files.length}');
      return recommended;
    }
    appLogger.w('[tofa] no recommended file among ${files.length}; not picking one by position');
    throw PlaybackException(t.messages.playbackNoMediaSources, reason: PlaybackFailureReason.noPlayableSource);
  }

  /// `recommended_media_file_id` of `GET /media/{id}/versions` (for an
  /// episode: the series with `season` and `episode`), or null.
  Future<String?> _recommendedFile(MediaItem item) async {
    final raw = item.raw ?? const {};
    final mediaId = raw[TofaRaw.mediaId] as String? ?? TofaMappers.mediaIdOf(item.id);
    final season = raw[TofaRaw.seasonNumber];
    final episode = raw[TofaRaw.episodeNumber];
    try {
      final data = await _api.getJson(
        '/api/v1/media/${_seg(mediaId)}/versions',
        query: {
          ...TofaPlaybackCaps.query(),
          if (item.kind == MediaKind.episode && season is int && episode is int) ...{
            'season': '$season',
            'episode': '$episode',
          },
        },
      );
      final id = data is Map ? data['recommended_media_file_id'] : null;
      return id is String && id.isNotEmpty ? id : null;
    } on MediaServerHttpException catch (e) {
      if (e.isCancellation) rethrow;
      appLogger.w('[tofa] versions read failed (HTTP ${e.statusCode})');
      return null;
    }
  }

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final metadata = options.metadata;
    final String fileId;
    final Map<String, dynamic> info;
    try {
      fileId = await chooseFile(metadata, requestedFileId: options.selectedMediaSourceId);
      final audioIndex = switch (options.selectedAudioStreamId) {
        final id? when id > 0 => id - 1,
        _ => null,
      };
      final response = await _api.request(
        'GET',
        '/api/v1/stream/${_seg(fileId)}/info',
        query: TofaPlaybackCaps.streamQuery(
          preset: options.qualityPreset,
          resumeTicks: tofaTicksFromDuration(options.startPosition ?? Duration.zero),
          audioStreamIndex: audioIndex,
          forceTranscode: options.forceTranscode,
        ),
      );
      if (response.statusCode == 503) {
        final message = tofaErrorMessage(response.data);
        appLogger.w('[tofa] stream refused 503 error=${tofaErrorCode(response.data) ?? '-'}');
        throw PlaybackException(message ?? t.messages.playbackFailed, reason: PlaybackFailureReason.serverUnavailable);
      }
      TofaApi.throwIfTofaError(response);
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw PlaybackException(t.messages.playbackDataInvalid, reason: PlaybackFailureReason.invalidPlaybackData);
      }
      info = data;
    } on PlaybackException {
      rethrow;
    } catch (error, stackTrace) {
      if (error is MediaServerHttpException && error.statusCode == 403 && error.display != null) {
        Error.throwWithStackTrace(
          PlaybackException(error.display!, reason: PlaybackFailureReason.playbackNotAllowed),
          stackTrace,
        );
      }
      Error.throwWithStackTrace(classifyPlaybackFailure(error), stackTrace);
    }

    final rawUrl = info['stream_url'];
    final sessionId = info['session_id'];
    final sessionToken = info['session_token'];
    if (rawUrl is! String || rawUrl.isEmpty || sessionId is! String || sessionToken is! String) {
      throw PlaybackException(t.messages.playbackDataInvalid, reason: PlaybackFailureReason.invalidPlaybackData);
    }
    LogRedactionManager.registerRotatingToken(sessionToken);
    final playMethod = info['play_method'] is String ? info['play_method'] as String : 'DirectPlay';
    final isOriginal = playMethod == 'DirectPlay';
    _sessions[sessionId] = _TofaStreamSession(
      sessionId: sessionId,
      token: sessionToken,
      itemId: metadata.id,
      fileId: fileId,
    );
    _playingFileIds[metadata.id] = fileId;

    final startTicks = (info['start_position_ticks'] as num?)?.toInt() ?? 0;
    appLogger.i(
      '[tofa] playback play_method=$playMethod decision=${info['decision_mode']} '
      'trace=${info['decision_trace_id']} reasons=${info['transcode_reason_codes']} '
      'start=${tofaDurationFromTicks(startTicks).inSeconds}s',
    );

    final sidecars = <PlaybackSubtitleSidecar>[];
    final subtitleTracks = <MediaSubtitleTrack>[];
    final rawSubs = info['subtitle_tracks'];
    if (rawSubs is List) {
      for (final track in rawSubs.whereType<Map>()) {
        final index = (track['index'] as num?)?.toInt();
        if (index == null) continue;
        final codec = track['codec']?.toString();
        final isText = track['render'] != 'bitmap';
        final external = track['external'] == true;
        // An original file carries its embedded tracks itself; a remux or
        // transcode carries none, so every text track comes as a sidecar.
        final asSidecar = isText && (external || !isOriginal);
        if (!isOriginal && !isText) continue;
        final id = index + 1;
        subtitleTracks.add(
          MediaSubtitleTrack(
            id: id,
            index: index,
            codec: codec,
            language: track['language']?.toString(),
            languageCode: track['language']?.toString(),
            title: track['title']?.toString(),
            selected: false,
            forced: track['forced'] == true,
            external: external,
            usesExternalDelivery: asSidecar,
          ),
        );
        if (asSidecar) {
          sidecars.add(
            PlaybackSubtitleSidecar(
              sourceStreamId: id,
              track: SubtitleTrack.uri(
                subtitleSidecarUrl(sessionId, index, sessionToken),
                title: track['title']?.toString(),
                language: track['language']?.toString(),
                codec: 'webvtt',
                isDefault: track['default_disposition'] == true,
                isForced: track['forced'] == true,
              ),
            ),
          );
        }
      }
    }
    final selectedAudio = (info['selected_audio_stream_index'] as num?)?.toInt();
    final audioTracks = <MediaAudioTrack>[
      for (final track in (info['audio_tracks'] is List ? info['audio_tracks'] as List : const []).whereType<Map>())
        if ((track['index'] as num?)?.toInt() case final index?)
          MediaAudioTrack(
            id: index + 1,
            index: index,
            codec: track['codec']?.toString(),
            language: track['language']?.toString(),
            languageCode: track['language']?.toString(),
            title: track['title']?.toString(),
            channels: (track['channels'] as num?)?.toInt(),
            selected: selectedAudio == index,
          ),
    ];
    final versions = (metadata.mediaVersions ?? const []).where((v) => v.parts.isNotEmpty).toList();
    final versionIndex = versions.indexWhere((v) => v.id == fileId);
    final videoUrl = _api.resolveUrl(rawUrl);
    return PlaybackInitializationResult(
      availableVersions: versions,
      videoUrl: videoUrl,
      mediaInfo: MediaSourceInfo(
        videoUrl: videoUrl,
        audioTracks: audioTracks,
        subtitleTracks: subtitleTracks,
        chapters: const [],
        mediaSourceId: fileId,
        mediaIndex: versionIndex < 0 ? 0 : versionIndex,
        defaultAudioStreamIndex: selectedAudio == null ? null : selectedAudio + 1,
      ),
      subtitleSidecars: sidecars,
      isTranscoding: playMethod == 'Transcode',
      activeAudioStreamId: selectedAudio == null ? null : selectedAudio + 1,
      playSessionId: sessionId,
      playMethod: playMethod,
      selectedMediaIndex: versionIndex < 0 ? 0 : versionIndex,
      selectedMediaSourceId: fileId,
    );
  }

  /// `…/stream/s/{sid}/subtitles/{index}/full.vtt?st=` on this server.
  @visibleForTesting
  String subtitleSidecarUrl(String sessionId, int index, String sessionToken) => _api.resolveUrl(
    '/api/v1/stream/s/${_seg(sessionId)}/subtitles/$index/full.vtt?st=${Uri.encodeQueryComponent(sessionToken)}',
  );

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async => PlaybackExtras(chapters: const [], markers: const []);

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async => null;

  @override
  Future<MediaSourceInfo?> fetchCachedMediaSourceInfo(
    String itemId, {
    int mediaIndex = 0,
    String? mediaSourceId,
    String? preferredVersionSignature,
    TranscodeQualityPreset? qualityPreset,
  }) async => null;

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({
    required MediaItem item,
    required MediaSourceInfo mediaSource,
  }) async => null;

  /// One progress post. A 410 means the server ended the session: nothing
  /// more is sent for it, and it is not restarted behind the viewer's back.
  Future<void> _sendProgress(
    _TofaStreamSession session,
    Duration position, {
    bool paused = false,
    bool ended = false,
  }) async {
    if (session.gone || session.stopped) return;
    final response = await _api.request(
      'POST',
      '/api/v1/stream/s/${_seg(session.sessionId)}/progress',
      query: {'st': session.token},
      body: {'position_ticks': tofaTicksFromDuration(position), 'is_paused': paused, 'ended': ended},
      auth: false,
    );
    if (response.statusCode == 410) {
      session.gone = true;
      appLogger.i('[tofa] stream session ended on the server (410); progress reports stop');
      return;
    }
    if (response.statusCode >= 400) {
      appLogger.d(
        '[tofa] progress report answered ${response.statusCode} error=${tofaErrorCode(response.data) ?? '-'}',
      );
    }
  }

  /// Whether a session is still reported to (the server has not ended it).
  @visibleForTesting
  bool isSessionLive(String sessionId) {
    final session = _sessions[sessionId];
    return session != null && !session.gone && !session.stopped;
  }

  /// Progress outside a stream session: `PUT /media/{file_id}/progress`.
  Future<void> _putProgress(String itemId, Duration position, Duration? duration) async {
    final file = _playingFileIds[itemId] ?? (await _fileIdForReport(itemId));
    if (file == null) {
      appLogger.w('[tofa] progress not saved: no file is known for the item');
      return;
    }
    await _api.send(
      'PUT',
      '/api/v1/media/${_seg(file)}/progress',
      body: {'position_ms': position.inMilliseconds, 'ended': _isEnd(position, duration)},
    );
  }

  Future<String?> _fileIdForReport(String itemId) async {
    final item = await _fetchItem(itemId);
    if (item == null) return null;
    try {
      return await chooseFile(item);
    } on PlaybackException {
      return null;
    }
  }

  /// Heuristic: the stream ended when the position is within 2 s of the
  /// length (the server's own threshold still decides "watched").
  static bool _isEnd(Duration position, Duration? duration) =>
      duration != null && duration > Duration.zero && position >= duration - const Duration(seconds: 2);

  @override
  Future<void> reportPlaybackStarted({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    final session = playSessionId == null ? null : _sessions[playSessionId];
    if (session == null) return;
    await _sendProgress(session, position);
  }

  @override
  Future<void> reportPlaybackProgress({
    required String itemId,
    required Duration position,
    required Duration duration,
    bool isPaused = false,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    final session = playSessionId == null ? null : _sessions[playSessionId];
    if (session == null) {
      if (playSessionId == null) await _putProgress(itemId, position, duration);
      return;
    }
    await _sendProgress(session, position, paused: isPaused);
  }

  /// The last position, then `POST …/stopped` (idempotent), on every close.
  @override
  Future<void> reportPlaybackStopped({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    PlaybackReportMetadata report = const PlaybackReportMetadata.live(),
  }) async {
    final session = playSessionId == null ? null : _sessions[playSessionId];
    if (session == null) {
      // A report without a session (offline replay, external player) saves
      // the position on the file.
      if (playSessionId == null) await _putProgress(itemId, position, duration);
      return;
    }
    try {
      await _sendProgress(session, position, ended: _isEnd(position, duration));
    } finally {
      session.stopped = true;
      _sessions.remove(session.sessionId);
      _details.remove(TofaMappers.mediaIdOf(itemId));
      final response = await _api.request(
        'POST',
        '/api/v1/stream/s/${_seg(session.sessionId)}/stopped',
        query: {'st': session.token},
        auth: false,
      );
      appLogger.d('[tofa] stream stopped answered ${response.statusCode}');
    }
  }

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) =>
      _unsupported('downloads');

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async {
    if (item.libraryId != null) return item;
    return item;
  }

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) => const [];

  /// Not offered yet: an external player cannot report to a Tofa stream
  /// session, and Tofa's download links are a follow-up.
  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async => null;
}

/// Tofa's live TV is not wired in Plezilo.
class _TofaNoLiveTv implements LiveTvSupport {
  const _TofaNoLiveTv();

  @override
  LiveTvDvrSupport? get dvr => null;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) async => const [];

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async => const [];

  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async => null;

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => '';

  @override
  String get favoriteStoreKey => 'tofa';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) async =>
      const [];

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) async {}
}
