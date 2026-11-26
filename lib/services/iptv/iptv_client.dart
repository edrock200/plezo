import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueNotifier, visibleForTesting;
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
import '../../media/media_filter.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_library.dart';
import '../../media/media_person.dart';
import '../../media/media_playlist.dart';
import '../../media/media_role.dart';
import '../../media/media_server_client.dart';
import '../../media/media_sort.dart';
import '../../media/media_source_info.dart';
import '../../media/playback_report_metadata.dart';
import '../../media/remote_trailer.dart';
import '../../media/server_capabilities.dart';
import '../../models/livetv_capture_buffer.dart';
import '../../models/livetv_channel.dart';
import '../../models/livetv_dvr.dart';
import '../../models/livetv_program.dart';
import '../../models/media_grab_operation.dart';
import '../../models/media_subscription.dart';
import '../../models/transcode_quality_preset.dart';
import '../../utils/app_logger.dart';
import '../../utils/external_ids.dart';
import '../../utils/log_redaction_manager.dart';
import '../../utils/media_server_http_client.dart' show AbortController;
import '../api_cache.dart';
import '../download_artwork_helpers.dart';
import '../playback_initialization_types.dart';
import '../scrub_preview_source.dart';
import 'iptv_api_cache.dart';
import 'iptv_catchup.dart';
import 'iptv_ids.dart';
import 'iptv_parental.dart';
import 'iptv_recorder.dart';
import 'iptv_store.dart';
import 'iptv_sync_worker.dart';
import 'xtream_api.dart';

part 'iptv_client_live.dart';
part 'iptv_client_dvr.dart';

/// [MediaServerClient] for one IPTV source: an M3U playlist or an Xtream
/// login, with its guides.
///
/// There is no media server: channels, guide, movies and series are imported
/// into the IPTV database by `IptvSyncService`, and this client reads them
/// from there. Xtream details (`get_vod_info`, `get_series_info`) are read on
/// demand. Watch state is kept on the device ([IptvStore] progress), as
/// Xtream has none server-side.
///
/// Stream addresses can carry the Xtream login, so they are registered with
/// the log redaction and never logged.
class IptvClient implements MediaServerClient, RemoteTrailerClient {
  IptvClient(this._connection, {IptvStore? store, http.Client? httpClient, DateTime Function()? now})
    : store = store ?? IptvStore.instance,
      _http = httpClient ?? http.Client(),
      _ownsHttp = httpClient == null,
      _now = now ?? DateTime.now {
    _registerSecrets(_connection);
    if (_connection.isXtream) _xtream = _buildXtream(_connection);
  }

  static Future<IptvClient> create(IptvConnection connection) async => IptvClient(connection);

  IptvConnection _connection;
  IptvConnection get connection => _connection;
  final IptvStore store;
  final http.Client _http;
  final bool _ownsHttp;
  final DateTime Function() _now;
  XtreamApi? _xtream;

  /// The Xtream API of this source, or null for an M3U playlist.
  XtreamApi? get xtream => _xtream;

  Object _authSession = Object();
  bool _offline = false;

  /// Shown channels, rebuilt when the parental gate or the stored data
  /// changes (see `iptv_client_live.dart`).
  ({int revision, int dataRevision, List<IptvShownChannel> channels})? _channelCache;

  /// The Xtream server clock's offset from UTC (archive addresses).
  Duration? _serverOffset;
  bool _closed = false;

  static void _registerSecrets(IptvConnection c) {
    LogRedactionManager.registerToken(c.xtreamPassword.isEmpty ? null : c.xtreamPassword);
    if (c.xtreamUsername.length >= 3) LogRedactionManager.registerToken(c.xtreamUsername);
    LogRedactionManager.registerServerUrl(c.xtreamServer.isEmpty ? null : c.xtreamServer);
    if (c.m3uUrl.isNotEmpty) {
      LogRedactionManager.registerServerUrl(c.m3uUrl);
      LogRedactionManager.registerCustomValue(c.m3uUrl);
    }
    for (final url in c.epgUrls) {
      LogRedactionManager.registerCustomValue(url);
    }
  }

  XtreamApi _buildXtream(IptvConnection c) => XtreamApi(
    XtreamCredentials(baseUrl: c.xtreamServer, username: c.xtreamUsername, password: c.xtreamPassword),
    client: _http,
    userAgent: c.userAgent,
  );

  /// Adopt edited settings of the same source (name, guide addresses, …)
  /// without a new client.
  void updateConnection(IptvConnection updated) {
    if (updated.id != _connection.id) return;
    final loginChanged =
        updated.xtreamServer != _connection.xtreamServer ||
        updated.xtreamUsername != _connection.xtreamUsername ||
        updated.xtreamPassword != _connection.xtreamPassword ||
        updated.m3uUrl != _connection.m3uUrl;
    _connection = updated;
    _registerSecrets(updated);
    if (updated.isXtream) _xtream = _buildXtream(updated);
    if (loginChanged) _authSession = Object();
    _channelCache = null;
  }

  @override
  ServerId get serverId => ServerId(_connection.id);

  @override
  String? get serverName => _connection.name;

  @override
  MediaBackend get backend => MediaBackend.iptv;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.iptv;

  @override
  Object get authenticationSessionId => _authSession;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsHttp) _http.close();
  }

  @override
  LibraryEventChannel? createLibraryEventChannel() => null;

  /// Xtream: the account answer (refused login → [HealthStatus.authError]).
  /// The data is on the device, so an unreachable provider still lets the
  /// app show channels and the guide; their streams fail on their own.
  @override
  Future<HealthStatus> checkHealth() async {
    final api = _xtream;
    if (api == null) return HealthStatus.online;
    try {
      final account = await api.account().timeout(const Duration(seconds: 15));
      await store.putMeta(_connection.id, IptvMetaKeys.account, jsonEncode(account.toJson()));
      if (!account.isActive) {
        appLogger.w('[iptv] xtream account status=${account.status ?? '-'}');
      }
      return HealthStatus.online;
    } on XtreamAuthException catch (e) {
      appLogger.w('[iptv] xtream login refused (${e.status ?? '-'})');
      return HealthStatus.authError;
    } catch (e) {
      final hasData = await store.channelCount(_connection.id).catchError((_) => 0) > 0;
      appLogger.i(
        '[iptv] xtream account unreachable (${e.runtimeType}); ${hasData ? 'using stored data' : 'no data yet'}',
      );
      return hasData ? HealthStatus.online : HealthStatus.offline;
    }
  }

  /// The stored Xtream account answer, for the source's settings page.
  Future<XtreamAccount?> storedAccount() async {
    final raw = await store.meta(_connection.id, IptvMetaKeys.account);
    if (raw == null) return null;
    try {
      return XtreamAccount.fromStoredJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> getMachineIdentifier() async => _connection.id;

  @override
  bool get isOfflineMode => _offline;

  @override
  void setOfflineMode(bool offline) => _offline = offline;

  @override
  ApiCache get cache => IptvApiCache.instance;

  // ---------------------------------------------------------------------------
  // Libraries: Xtream movies and series
  // ---------------------------------------------------------------------------

  bool get _hasVod => _connection.isXtream && _connection.includeVod;

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    if (!_hasVod) return const [];
    final movies = await store.vodCount(_connection.id, IptvGroupKind.movie);
    final series = await store.vodCount(_connection.id, IptvGroupKind.series);
    return [
      if (movies > 0)
        MediaLibrary(
          id: IptvLibraryIds.movies,
          backend: MediaBackend.iptv,
          title: t.iptv.moviesLibrary,
          kind: MediaKind.movie,
          defaultBrowseKinds: const [MediaKind.movie],
          serverId: serverId.value,
          serverName: serverName,
        ),
      if (series > 0)
        MediaLibrary(
          id: IptvLibraryIds.series,
          backend: MediaBackend.iptv,
          title: t.iptv.seriesLibrary,
          kind: MediaKind.show,
          defaultBrowseKinds: const [MediaKind.show],
          serverId: serverId.value,
          serverName: serverName,
        ),
    ];
  }

  static IptvGroupKind? _libraryKind(String libraryId) => switch (libraryId) {
    IptvLibraryIds.movies => IptvGroupKind.movie,
    IptvLibraryIds.series => IptvGroupKind.series,
    _ => null,
  };

  String _libraryTitle(IptvGroupKind kind) => kind == IptvGroupKind.movie ? t.iptv.moviesLibrary : t.iptv.seriesLibrary;

  /// Categories hidden by the user or locked by the parental filter.
  Future<Set<String>> _hiddenCategoryIds(IptvGroupKind kind) async {
    final groups = await store.groups(_connection.id, kind);
    final locked = _lockedNames;
    return {
      for (final g in groups)
        if (g.hidden || locked.contains(g.name)) g.id,
    };
  }

  Set<String> get _lockedNames =>
      IptvParentalGate.isUnlocked(_connection.id) ? const {} : _connection.lockedGroups.toSet();

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    final kind = _libraryKind(libraryId);
    if (kind == null) return const LibraryPage(items: [], totalCount: 0);
    final categories = <String>{};
    for (final filter in query.filters) {
      if (filter.field == MediaFilterField.genre && !filter.op.isNegated) categories.addAll(filter.values);
    }
    final unwatchedOnly = query.filters.any((f) => f.field == MediaFilterField.unwatched && !f.op.isNegated);
    final sort = query.sort;
    final page = await store.vodPage(
      _connection.id,
      kind,
      offset: query.offset,
      limit: unwatchedOnly ? query.limit * 3 : query.limit,
      categoryIds: categories.isEmpty ? null : categories,
      search: query.search,
      nameStartsWith: query.nameStartsWith,
      sort: sort?.field,
      descending: sort?.direction == LibrarySortDirection.descending,
      hiddenCategoryIds: await _hiddenCategoryIds(kind),
    );
    var items = await _vodItems(page.rows);
    if (unwatchedOnly) items = items.where((i) => (i.viewCount ?? 0) == 0).take(query.limit).toList();
    return LibraryPage(items: items, totalCount: page.total, offset: query.offset);
  }

  Future<List<MediaItem>> _vodItems(List<IptvVodRow> rows) async {
    final ids = [for (final r in rows) _vodItemId(r)];
    final progress = await store.progressFor(_connection.id, ids);
    return [for (final r in rows) _vodItem(r, progress[_vodItemId(r)])];
  }

  static String _vodItemId(IptvVodRow r) =>
      r.kind == IptvGroupKind.movie ? IptvMovieId(r.id).toString() : IptvSeriesId(r.id).toString();

  MediaItem _vodItem(IptvVodRow r, IptvProgress? progress) {
    final isMovie = r.kind == IptvGroupKind.movie;
    return MediaItem.iptv(
      id: _vodItemId(r),
      kind: isMovie ? MediaKind.movie : MediaKind.show,
      title: r.name,
      summary: r.plot,
      year: r.year,
      thumbPath: r.poster,
      rating: r.rating,
      genres: r.genre == null ? null : _splitGenres(r.genre!),
      addedAt: r.added,
      viewCount: progress?.watched == true ? 1 : 0,
      viewOffsetMs: progress != null && !progress.watched && progress.positionMs > 0 ? progress.positionMs : null,
      durationMs: progress != null && progress.durationMs > 0 ? progress.durationMs : null,
      lastViewedAt: progress == null ? null : progress.updatedAt ~/ 1000,
      libraryId: isMovie ? IptvLibraryIds.movies : IptvLibraryIds.series,
      libraryTitle: _libraryTitle(r.kind),
      serverId: serverId.value,
      serverName: serverName,
      raw: {'category_id': r.categoryId, 'ext': ?r.extension},
    );
  }

  static List<String> _splitGenres(String raw) => [
    for (final g in raw.split(RegExp(r'[,/|]')))
      if (g.trim().isNotEmpty) g.trim(),
  ];

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async {
    final kind = _libraryKind(libraryId);
    if (kind == null) return LibraryFilterResult.empty;
    final hidden = await _hiddenCategoryIds(kind);
    final groups = (await store.groups(_connection.id, kind)).where((g) => !hidden.contains(g.id) && g.count > 0);
    return LibraryFilterResult(
      filters: [
        MediaFilter(
          filter: MediaFilterField.genre,
          filterType: MediaFilterType.tag,
          key: MediaFilterField.genre,
          title: t.iptv.category,
          type: 'filter',
          operators: const [LibraryFilterOperator.is_],
        ),
        MediaFilter(
          filter: MediaFilterField.unwatched,
          filterType: MediaFilterType.boolean,
          key: '',
          title: t.libraries.filterCategories.unwatched,
          type: 'filter',
          operators: const [LibraryFilterOperator.is_],
        ),
      ],
      cachedValues: {
        MediaFilterField.genre: [for (final g in groups) MediaFilterValue(key: g.id, title: g.name)],
      },
    );
  }

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async {
    if (_libraryKind(libraryId) == null) return const [];
    return [
      MediaSort(key: 'default', title: t.iptv.sortProviderOrder, defaultDirection: 'asc'),
      MediaSort(key: 'title', title: t.libraries.sortLabels.title, defaultDirection: 'asc'),
      MediaSort(key: 'added', title: t.libraries.sortLabels.dateAdded, defaultDirection: 'desc'),
      MediaSort(key: 'year', title: t.libraries.sortLabels.productionYear, defaultDirection: 'desc'),
      MediaSort(key: 'rating', title: t.libraries.sortLabels.rating, defaultDirection: 'desc'),
    ];
  }

  /// A library's categories, as the Genres tab shows them.
  @override
  Future<List<LibraryGenre>> fetchLibraryGenres(String libraryId, {required MediaKind libraryKind}) async {
    final kind = _libraryKind(libraryId);
    if (kind == null) return const [];
    final hidden = await _hiddenCategoryIds(kind);
    return [
      for (final g in await store.groups(_connection.id, kind))
        if (!hidden.contains(g.id) && g.count > 0) LibraryGenre(title: g.name, filterValue: g.id),
    ];
  }

  @override
  Future<void> refreshLibraryMetadata(String libraryId) async =>
      throw UnsupportedError('IPTV libraries refresh with the playlist.');

  @override
  Future<void> scanLibrary(String libraryId) async =>
      throw UnsupportedError('IPTV libraries refresh with the playlist.');

  // ---------------------------------------------------------------------------
  // Items
  // ---------------------------------------------------------------------------

  /// Xtream detail answers read this session.
  final Map<String, ({DateTime at, Map<String, dynamic> data})> _seriesInfo = {};
  final Map<String, ({DateTime at, Map<String, dynamic> data})> _vodInfo = {};
  final Map<String, Future<Map<String, dynamic>?>> _detailInFlight = {};
  static const _detailFreshness = Duration(minutes: 30);

  Future<Map<String, dynamic>?> _cachedDetail(
    Map<String, ({DateTime at, Map<String, dynamic> data})> cache,
    String key,
    Future<Map<String, dynamic>?> Function() fetch,
  ) {
    final hit = cache[key];
    if (hit != null && _now().difference(hit.at) < _detailFreshness) return Future.value(hit.data);
    final flightKey = '${identityHashCode(cache)}:$key';
    return _detailInFlight[flightKey] ??= () async {
      try {
        final data = await fetch();
        if (data != null) {
          cache[key] = (at: _now(), data: data);
          if (cache.length > 40) cache.remove(cache.keys.first);
        }
        return data;
      } finally {
        unawaited(Future<void>(() => _detailInFlight.remove(flightKey)));
      }
    }();
  }

  Future<Map<String, dynamic>?> _seriesData(String seriesId) {
    final api = _xtream;
    if (api == null) return Future.value();
    return _cachedDetail(_seriesInfo, seriesId, () => api.seriesInfo(seriesId));
  }

  Future<Map<String, dynamic>?> _vodData(String streamId) {
    final api = _xtream;
    if (api == null) return Future.value();
    return _cachedDetail(_vodInfo, streamId, () => api.vodInfo(streamId));
  }

  @override
  Future<MediaItem?> fetchItem(String id) async {
    final parsed = IptvItemId.parse(id);
    try {
      final item = switch (parsed) {
        IptvMovieId(:final streamId) => await _movie(streamId),
        IptvSeriesId(:final seriesId) => await _series(seriesId),
        IptvSeasonId(:final seriesId, :final season) => await _season(seriesId, season),
        IptvEpisodeId(:final seriesId, :final episodeId) => await _episode(seriesId, episodeId),
        IptvChannelItemId(:final channelId) => await _channelItem(channelId),
        IptvRecordingId(:final recordingId) => await _recordingItem(recordingId),
        null => null,
      };
      if (item != null && parsed is! IptvChannelItemId && parsed is! IptvRecordingId) {
        unawaited(Future(() => IptvApiCache.instance.putItem(serverId, item)).catchError((_) {}));
      }
      return item;
    } on XtreamAuthException {
      throw MediaServerHttpException(type: MediaServerHttpErrorType.unknown, statusCode: 401, message: 'refused');
    } on XtreamRequestException catch (e) {
      // Offline or a slow provider: what the cache has.
      final cached = await IptvApiCache.instance.getMetadata(serverId, id);
      if (cached != null) return cached;
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.connectionError,
        statusCode: e.statusCode,
        message: e.message,
      );
    }
  }

  Future<MediaItem?> _movie(String streamId) async {
    final row = await store.vodRow(_connection.id, IptvGroupKind.movie, streamId);
    final data = await _vodData(streamId);
    final info = data?['info'] is Map ? (data!['info'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final movieData = data?['movie_data'] is Map
        ? (data!['movie_data'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    if (row == null && data == null) return null;
    final id = IptvMovieId(streamId).toString();
    final progress = await store.progress(_connection.id, id);
    final durationSecs = xtreamInt(info['duration_secs']) ?? _durationText(xtreamString(info['duration']));
    final backdrops = _backdrops(info['backdrop_path']);
    final ext = xtreamString(movieData['container_extension']) ?? row?.extension ?? 'mp4';
    return MediaItem.iptv(
      id: id,
      kind: MediaKind.movie,
      title: xtreamString(info['name']) ?? xtreamString(movieData['name']) ?? row?.name,
      originalTitle: xtreamString(info['o_name']),
      summary: xtreamString(info['plot']) ?? xtreamString(info['description']) ?? row?.plot,
      year: _yearOf(xtreamString(info['releasedate']) ?? xtreamString(info['release_date'])) ?? row?.year,
      originallyAvailableAt: xtreamString(info['releasedate']),
      thumbPath: xtreamString(info['movie_image']) ?? xtreamString(info['cover_big']) ?? row?.poster,
      artPath: backdrops.firstOrNull,
      backdropPaths: backdrops.isEmpty ? null : backdrops,
      durationMs: durationSecs == null ? null : durationSecs * 1000,
      rating: xtreamDouble(info['rating']) ?? row?.rating,
      genres: _splitGenresOrNull(xtreamString(info['genre']) ?? row?.genre),
      directors: _splitNamesOrNull(xtreamString(info['director'])),
      roles: _cast(xtreamString(info['cast']) ?? xtreamString(info['actors'])),
      countries: _splitNamesOrNull(xtreamString(info['country'])),
      contentRating: xtreamString(info['mpaa_rating']) ?? xtreamString(info['age']),
      addedAt: xtreamInt(movieData['added']) ?? row?.added,
      viewCount: progress?.watched == true ? 1 : 0,
      viewOffsetMs: progress != null && !progress.watched && progress.positionMs > 0 ? progress.positionMs : null,
      lastViewedAt: progress == null ? null : progress.updatedAt ~/ 1000,
      libraryId: IptvLibraryIds.movies,
      libraryTitle: t.iptv.moviesLibrary,
      serverId: serverId.value,
      serverName: serverName,
      raw: {
        'ext': ext,
        'trailer': ?xtreamString(info['youtube_trailer']),
        'tmdb': ?xtreamString(info['tmdb_id']),
        'category_id': ?xtreamString(movieData['category_id']) ?? row?.categoryId,
      },
    );
  }

  static int? _yearOf(String? date) => date == null || date.length < 4 ? null : int.tryParse(date.substring(0, 4));

  static int? _durationText(String? text) {
    if (text == null) return null;
    final parts = text.split(':').map(int.tryParse).toList();
    if (parts.any((p) => p == null) || parts.isEmpty) return null;
    var seconds = 0;
    for (final p in parts) {
      seconds = seconds * 60 + p!;
    }
    return parts.length == 1 ? seconds * 60 : seconds;
  }

  static List<String> _backdrops(Object? raw) {
    if (raw is List) {
      return [for (final b in raw) ?xtreamString(b)];
    }
    final single = xtreamString(raw);
    return single == null ? const [] : [single];
  }

  static List<String>? _splitGenresOrNull(String? raw) {
    if (raw == null) return null;
    final list = _splitGenres(raw);
    return list.isEmpty ? null : list;
  }

  static List<String>? _splitNamesOrNull(String? raw) {
    if (raw == null) return null;
    final list = [
      for (final n in raw.split(','))
        if (n.trim().isNotEmpty) n.trim(),
    ];
    return list.isEmpty ? null : list;
  }

  static List<MediaRole>? _cast(String? raw) {
    final names = _splitNamesOrNull(raw);
    if (names == null) return null;
    return [for (final n in names.take(30)) MediaRole(tag: n)];
  }

  Map<String, dynamic> _seriesInfoMap(Map<String, dynamic>? data) =>
      data?['info'] is Map ? (data!['info'] as Map).cast<String, dynamic>() : const <String, dynamic>{};

  /// Episodes by season number. Xtream sends `episodes` as an object keyed by
  /// season, or (some servers) a list of lists.
  static Map<int, List<Map<String, dynamic>>> _episodesBySeason(Map<String, dynamic>? data) {
    final raw = data?['episodes'];
    final out = <int, List<Map<String, dynamic>>>{};
    void addAll(Object? list, int? fallbackSeason) {
      if (list is! List) return;
      for (final e in list.whereType<Map>()) {
        final row = e.cast<String, dynamic>();
        final season = xtreamInt(row['season']) ?? fallbackSeason ?? 1;
        out.putIfAbsent(season, () => []).add(row);
      }
    }

    if (raw is Map) {
      for (final entry in raw.entries) {
        addAll(entry.value, int.tryParse('${entry.key}'));
      }
    } else if (raw is List) {
      for (final list in raw) {
        addAll(list, null);
      }
    }
    for (final list in out.values) {
      list.sort((a, b) => (xtreamInt(a['episode_num']) ?? 0).compareTo(xtreamInt(b['episode_num']) ?? 0));
    }
    return out;
  }

  Future<MediaItem?> _series(String seriesId) async {
    final row = await store.vodRow(_connection.id, IptvGroupKind.series, seriesId);
    final data = await _seriesData(seriesId);
    if (row == null && data == null) return null;
    final info = _seriesInfoMap(data);
    final episodes = _episodesBySeason(data);
    final episodeIds = [
      for (final list in episodes.values)
        for (final e in list)
          if (xtreamString(e['id']) case final id?) IptvEpisodeId(seriesId, id).toString(),
    ];
    final progress = await store.progressFor(_connection.id, episodeIds);
    final watched = progress.values.where((p) => p.watched).length;
    final backdrops = _backdrops(info['backdrop_path']);
    return MediaItem.iptv(
      id: IptvSeriesId(seriesId).toString(),
      kind: MediaKind.show,
      title: xtreamString(info['name']) ?? row?.name,
      summary: xtreamString(info['plot']) ?? row?.plot,
      year: _yearOf(xtreamString(info['releaseDate']) ?? xtreamString(info['release_date'])) ?? row?.year,
      originallyAvailableAt: xtreamString(info['releaseDate']),
      thumbPath: xtreamString(info['cover']) ?? row?.poster,
      artPath: backdrops.firstOrNull,
      backdropPaths: backdrops.isEmpty ? null : backdrops,
      rating: xtreamDouble(info['rating']) ?? row?.rating,
      genres: _splitGenresOrNull(xtreamString(info['genre']) ?? row?.genre),
      directors: _splitNamesOrNull(xtreamString(info['director'])),
      roles: _cast(xtreamString(info['cast'])),
      leafCount: episodeIds.length,
      viewedLeafCount: watched,
      childCount: episodes.length,
      viewCount: episodeIds.isNotEmpty && watched == episodeIds.length ? 1 : 0,
      libraryId: IptvLibraryIds.series,
      libraryTitle: t.iptv.seriesLibrary,
      serverId: serverId.value,
      serverName: serverName,
      raw: {
        'trailer': ?xtreamString(info['youtube_trailer']),
        'tmdb': ?xtreamString(info['tmdb']) ?? xtreamString(info['tmdb_id']),
        'category_id': ?xtreamString(info['category_id']) ?? row?.categoryId,
      },
    );
  }

  List<Map<String, dynamic>> _seasonRows(Map<String, dynamic>? data) => [
    if (data?['seasons'] is List)
      for (final s in (data!['seasons'] as List).whereType<Map>()) s.cast<String, dynamic>(),
  ];

  Future<List<MediaItem>> _seasons(String seriesId) async {
    final data = await _seriesData(seriesId);
    if (data == null) return const [];
    final info = _seriesInfoMap(data);
    final seriesTitle = xtreamString(info['name']);
    final seriesCover = xtreamString(info['cover']);
    final episodes = _episodesBySeason(data);
    final seasonMeta = {for (final s in _seasonRows(data)) xtreamInt(s['season_number']) ?? -1: s};
    final numbers = episodes.keys.toList()..sort();
    final out = <MediaItem>[];
    for (final number in numbers) {
      final list = episodes[number]!;
      final meta = seasonMeta[number] ?? const <String, dynamic>{};
      final ids = [
        for (final e in list)
          if (xtreamString(e['id']) case final id?) IptvEpisodeId(seriesId, id).toString(),
      ];
      final progress = await store.progressFor(_connection.id, ids);
      final watched = progress.values.where((p) => p.watched).length;
      out.add(
        MediaItem.iptv(
          id: IptvSeasonId(seriesId, number).toString(),
          kind: MediaKind.season,
          title: xtreamString(meta['name']) ?? t.iptv.seasonNumber(number: number),
          summary: xtreamString(meta['overview']),
          index: number,
          parentId: IptvSeriesId(seriesId).toString(),
          parentTitle: seriesTitle,
          parentThumbPath: seriesCover,
          thumbPath: xtreamString(meta['cover_big']) ?? xtreamString(meta['cover']) ?? seriesCover,
          leafCount: list.length,
          viewedLeafCount: watched,
          viewCount: list.isNotEmpty && watched == list.length ? 1 : 0,
          libraryId: IptvLibraryIds.series,
          libraryTitle: t.iptv.seriesLibrary,
          serverId: serverId.value,
          serverName: serverName,
        ),
      );
    }
    return out;
  }

  Future<MediaItem?> _season(String seriesId, int season) async {
    for (final s in await _seasons(seriesId)) {
      if (s.index == season) return s;
    }
    return null;
  }

  Future<List<MediaItem>> _episodes(String seriesId, {int? season}) async {
    final data = await _seriesData(seriesId);
    if (data == null) return const [];
    final info = _seriesInfoMap(data);
    final seriesTitle = xtreamString(info['name']);
    final seriesCover = xtreamString(info['cover']);
    final backdrops = _backdrops(info['backdrop_path']);
    final bySeason = _episodesBySeason(data);
    final numbers = (season == null ? bySeason.keys.toList() : [season])..sort();
    final rows = [
      for (final n in numbers)
        for (final e in bySeason[n] ?? const <Map<String, dynamic>>[]) (season: n, row: e),
    ];
    final ids = [
      for (final r in rows)
        if (xtreamString(r.row['id']) case final id?) IptvEpisodeId(seriesId, id).toString(),
    ];
    final progress = await store.progressFor(_connection.id, ids);
    final out = <MediaItem>[];
    for (final r in rows) {
      final episodeId = xtreamString(r.row['id']);
      if (episodeId == null) continue;
      final id = IptvEpisodeId(seriesId, episodeId).toString();
      final info = r.row['info'] is Map ? (r.row['info'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
      final p = progress[id];
      final durationSecs = xtreamInt(info['duration_secs']) ?? _durationText(xtreamString(info['duration']));
      out.add(
        MediaItem.iptv(
          id: id,
          kind: MediaKind.episode,
          title: xtreamString(r.row['title']) ?? t.iptv.episodeNumber(number: xtreamInt(r.row['episode_num']) ?? 0),
          summary: xtreamString(info['plot']),
          index: xtreamInt(r.row['episode_num']),
          parentIndex: r.season,
          parentId: IptvSeasonId(seriesId, r.season).toString(),
          parentTitle: t.iptv.seasonNumber(number: r.season),
          grandparentId: IptvSeriesId(seriesId).toString(),
          grandparentTitle: seriesTitle,
          grandparentThumbPath: seriesCover,
          grandparentArtPath: backdrops.firstOrNull,
          thumbPath: xtreamString(info['movie_image']) ?? seriesCover,
          originallyAvailableAt: xtreamString(info['releasedate']) ?? xtreamString(info['air_date']),
          durationMs: durationSecs == null
              ? (p != null && p.durationMs > 0 ? p.durationMs : null)
              : durationSecs * 1000,
          rating: xtreamDouble(info['rating']),
          viewCount: p?.watched == true ? 1 : 0,
          viewOffsetMs: p != null && !p.watched && p.positionMs > 0 ? p.positionMs : null,
          lastViewedAt: p == null ? null : p.updatedAt ~/ 1000,
          libraryId: IptvLibraryIds.series,
          libraryTitle: t.iptv.seriesLibrary,
          serverId: serverId.value,
          serverName: serverName,
          raw: {'ext': xtreamString(r.row['container_extension']) ?? 'mp4'},
        ),
      );
    }
    return out;
  }

  Future<MediaItem?> _episode(String seriesId, String episodeId) async {
    final target = IptvEpisodeId(seriesId, episodeId).toString();
    for (final e in await _episodes(seriesId)) {
      if (e.id == target) return e;
    }
    return null;
  }

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async {
    final item = await fetchItem(id);
    if (item == null) return (item: null, onDeckEpisode: null);
    onItemReady?.call(item);
    if (item.kind != MediaKind.show) return (item: item, onDeckEpisode: null);
    final parsed = IptvItemId.parse(id);
    if (parsed is! IptvSeriesId) return (item: item, onDeckEpisode: null);
    final episodes = await _episodes(parsed.seriesId);
    MediaItem? next;
    // In progress first, then the first unwatched after the last watched one.
    for (final e in episodes) {
      if ((e.viewOffsetMs ?? 0) > 0 && (e.viewCount ?? 0) == 0) {
        next = e;
        break;
      }
    }
    if (next == null) {
      var lastWatched = -1;
      for (var i = 0; i < episodes.length; i++) {
        if ((episodes[i].viewCount ?? 0) > 0) lastWatched = i;
      }
      if (lastWatched + 1 < episodes.length) next = episodes[lastWatched + 1];
    }
    return (item: item, onDeckEpisode: next);
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    final parsed = IptvItemId.parse(parentId);
    return switch (parsed) {
      IptvSeriesId(:final seriesId) => _seasons(seriesId),
      IptvSeasonId(:final seriesId, :final season) => _episodes(seriesId, season: season),
      _ => const <MediaItem>[],
    };
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
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final all = await fetchChildren(parentId);
    return _slice(all, start, size);
  }

  static LibraryPage<MediaItem> _slice(List<MediaItem> all, int? start, int? size) {
    final from = (start ?? 0).clamp(0, all.length);
    final to = size == null ? all.length : (from + size).clamp(from, all.length);
    return LibraryPage(items: all.sublist(from, to), totalCount: all.length, offset: from);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async => _slice(await fetchPlayableDescendants(parentId), start, size);

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async {
    final parsed = IptvItemId.parse(parentId);
    return switch (parsed) {
      IptvSeriesId(:final seriesId) => _episodes(seriesId),
      IptvSeasonId(:final seriesId, :final season) => _episodes(seriesId, season: season),
      IptvMovieId() || IptvEpisodeId() => [?await fetchItem(parentId)],
      _ => const <MediaItem>[],
    };
  }

  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) async {
    final parsed = IptvItemId.parse(seriesId);
    if (parsed is! IptvSeriesId) return null;
    return _episodes(parsed.seriesId);
  }

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

  /// Movies and series whose title matches, then live channels.
  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final out = <MediaItem>[];
    if (_hasVod) {
      for (final kind in const [IptvGroupKind.movie, IptvGroupKind.series]) {
        final libraryId = kind == IptvGroupKind.movie ? IptvLibraryIds.movies : IptvLibraryIds.series;
        if (excludedLibraryIds.contains(libraryId)) continue;
        final page = await store.vodPage(
          _connection.id,
          kind,
          offset: 0,
          limit: limit ~/ 2,
          search: q,
          sort: 'title',
          hiddenCategoryIds: await _hiddenCategoryIds(kind),
        );
        out.addAll(await _vodItems(page.rows));
      }
    }
    return out;
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async => const [];

  /// Movies and episodes started on this device, most recent first.
  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async {
    if (!_hasVod) return const [];
    final rows = await store.inProgress(_connection.id, limit: count ?? 20);
    final out = <MediaItem>[];
    for (final p in rows) {
      final item = _itemFromProgress(p);
      if (item == null) continue;
      if (item.libraryId != null && excludedLibraryIds.contains(item.libraryId)) continue;
      out.add(item);
    }
    return out;
  }

  /// The item as stored with its progress.
  MediaItem? _itemFromProgress(IptvProgress p) {
    final meta = p.meta;
    final parsed = IptvItemId.parse(p.itemId);
    if (parsed is! IptvMovieId && parsed is! IptvEpisodeId) return null;
    final isEpisode = parsed is IptvEpisodeId;
    String? s(String key) => meta[key] is String ? meta[key] as String : null;
    int? n(String key) => meta[key] is int ? meta[key] as int : null;
    return MediaItem.iptv(
      id: p.itemId,
      kind: isEpisode ? MediaKind.episode : MediaKind.movie,
      title: s('title'),
      thumbPath: s('thumb'),
      artPath: s('art'),
      year: n('year'),
      index: n('index'),
      parentIndex: n('parentIndex'),
      parentId: s('parentId'),
      grandparentId: s('grandparentId'),
      grandparentTitle: s('grandparentTitle'),
      grandparentThumbPath: s('grandparentThumb'),
      grandparentArtPath: s('grandparentArt'),
      durationMs: p.durationMs > 0 ? p.durationMs : null,
      viewOffsetMs: p.positionMs,
      viewCount: 0,
      lastViewedAt: p.updatedAt ~/ 1000,
      libraryId: isEpisode ? IptvLibraryIds.series : IptvLibraryIds.movies,
      libraryTitle: isEpisode ? t.iptv.seriesLibrary : t.iptv.moviesLibrary,
      serverId: serverId.value,
      serverName: serverName,
      raw: {'ext': s('ext') ?? 'mp4'},
    );
  }

  static const _recentMoviesHub = 'iptv:recent-movies';
  static const _recentSeriesHub = 'iptv:recent-series';
  static const _continueHub = 'iptv:continue';

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async {
    if (!_hasVod) return const [];
    final hubs = <MediaHub>[];
    try {
      if (includePlaybackHubs) {
        final continuing = await fetchContinueWatching(count: limit);
        if (continuing.isNotEmpty) hubs.add(_hub(_continueHub, t.iptv.continueWatching, continuing, false));
      }
      for (final kind in const [IptvGroupKind.movie, IptvGroupKind.series]) {
        final page = await store.vodPage(
          _connection.id,
          kind,
          offset: 0,
          limit: limit,
          sort: 'added',
          descending: true,
          hiddenCategoryIds: await _hiddenCategoryIds(kind),
        );
        if (page.rows.isEmpty) continue;
        final items = await _vodItems(page.rows);
        hubs.add(
          _hub(
            kind == IptvGroupKind.movie ? _recentMoviesHub : _recentSeriesHub,
            kind == IptvGroupKind.movie
                ? t.iptv.recentlyAddedMovies(source: _connection.name)
                : t.iptv.recentlyAddedSeries(source: _connection.name),
            items,
            page.total > items.length,
            libraryId: kind == IptvGroupKind.movie ? IptvLibraryIds.movies : IptvLibraryIds.series,
          ),
        );
      }
    } catch (e) {
      diagnostics?.recordFailure(e);
      appLogger.w('[iptv] home rows failed (${e.runtimeType})');
    }
    return hubs;
  }

  MediaHub _hub(String id, String title, List<MediaItem> items, bool more, {String? libraryId}) => MediaHub(
    id: id,
    identifier: id,
    title: title,
    type: 'mixed',
    items: items,
    size: items.length,
    more: more,
    libraryId: libraryId,
    serverId: serverId.value,
    serverName: serverName,
  );

  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) async {
    final kind = _libraryKind(libraryId);
    if (kind == null) return const [];
    final hubs = <MediaHub>[];
    try {
      final hidden = await _hiddenCategoryIds(kind);
      final recent = await store.vodPage(
        _connection.id,
        kind,
        offset: 0,
        limit: limit,
        sort: 'added',
        descending: true,
        hiddenCategoryIds: hidden,
      );
      if (recent.rows.isNotEmpty) {
        hubs.add(
          _hub(
            kind == IptvGroupKind.movie ? _recentMoviesHub : _recentSeriesHub,
            t.iptv.recentlyAdded,
            await _vodItems(recent.rows),
            recent.total > recent.rows.length,
            libraryId: libraryId,
          ),
        );
      }
      // One row for each of the first categories.
      final groups = (await store.groups(_connection.id, kind)).where((g) => !hidden.contains(g.id) && g.count > 0);
      for (final g in groups.take(8)) {
        final page = await store.vodPage(_connection.id, kind, offset: 0, limit: limit, categoryIds: {g.id});
        if (page.rows.isEmpty) continue;
        hubs.add(
          _hub(
            'iptv:cat:${kind.id}:${g.id}',
            g.name,
            await _vodItems(page.rows),
            page.total > page.rows.length,
            libraryId: libraryId,
          ),
        );
      }
    } catch (e) {
      diagnostics?.recordFailure(e);
    }
    return hubs;
  }

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) async {
    // Titles of the same category.
    final parsed = IptvItemId.parse(id);
    final (kind, rawId) = switch (parsed) {
      IptvMovieId(:final streamId) => (IptvGroupKind.movie, streamId),
      IptvSeriesId(:final seriesId) => (IptvGroupKind.series, seriesId),
      _ => (null, null),
    };
    if (kind == null || rawId == null) return const [];
    final row = await store.vodRow(_connection.id, kind, rawId);
    final category = row?.categoryId;
    if (category == null) return const [];
    final page = await store.vodPage(_connection.id, kind, offset: 0, limit: count + 1, categoryIds: {category});
    final items = (await _vodItems(page.rows)).where((i) => i.id != id).take(count).toList();
    if (items.isEmpty) return const [];
    return [_hub('iptv:related:$id', t.iptv.moreInCategory, items, false)];
  }

  @override
  Future<List<MediaItem>> fetchExtras(String id) async => const [];

  /// Xtream gives a YouTube id (`youtube_trailer`) for many titles.
  @override
  Future<List<RemoteTrailer>> fetchRemoteTrailers(String id) async {
    final item = await fetchItem(id);
    final key = item?.raw?['trailer'];
    if (key is! String || key.trim().isEmpty) return const [];
    final videoId = _youtubeId(key.trim());
    if (videoId == null) return const [];
    return [RemoteTrailer(site: 'YouTube', key: videoId, kind: 'trailer', name: t.iptv.trailer)];
  }

  static String? _youtubeId(String raw) {
    if (!raw.contains('/') && !raw.contains('=')) return raw;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.queryParameters['v'] case final v? when v.isNotEmpty) return v;
    final last = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    return last;
  }

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
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async =>
      (await fetchMoreHubItemsPage(hubId, start: 0, size: limit)).items;

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(
    String hubId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final offset = start ?? 0;
    final limit = size ?? 50;
    if (hubId == _continueHub) {
      final all = await fetchContinueWatching(count: 200);
      return _slice(all, offset, limit);
    }
    IptvGroupKind? kind;
    String? category;
    var sort = 'added';
    if (hubId == _recentMoviesHub) kind = IptvGroupKind.movie;
    if (hubId == _recentSeriesHub) kind = IptvGroupKind.series;
    if (hubId.startsWith('iptv:cat:')) {
      final parts = hubId.split(':');
      if (parts.length >= 4) {
        kind = IptvGroupKind.parse(parts[2]);
        category = parts.sublist(3).join(':');
        sort = 'default';
      }
    }
    if (kind == null) return const LibraryPage(items: [], totalCount: 0);
    final page = await store.vodPage(
      _connection.id,
      kind,
      offset: offset,
      limit: limit,
      categoryIds: category == null ? null : {category},
      sort: sort,
      descending: sort == 'added',
      hiddenCategoryIds: await _hiddenCategoryIds(kind),
    );
    return LibraryPage(items: await _vodItems(page.rows), totalCount: page.total, offset: offset);
  }

  // ---------------------------------------------------------------------------
  // Watch state (on the device)
  // ---------------------------------------------------------------------------

  Future<void> _setWatched(MediaItem item, bool watched) async {
    final parsed = IptvItemId.parse(item.id);
    final targets = switch (parsed) {
      IptvMovieId() || IptvEpisodeId() => [item],
      IptvSeriesId(:final seriesId) => await _episodes(seriesId),
      IptvSeasonId(:final seriesId, :final season) => await _episodes(seriesId, season: season),
      _ => const <MediaItem>[],
    };
    for (final target in targets) {
      if (watched) {
        await store.saveProgress(
          _connection.id,
          target.id,
          positionMs: 0,
          durationMs: target.durationMs ?? 0,
          watched: true,
          meta: _progressMeta(target),
        );
      } else {
        await store.deleteProgress(_connection.id, target.id);
      }
    }
  }

  @override
  Future<void> markWatched(MediaItem item) => _setWatched(item, true);

  @override
  Future<void> markUnwatched(MediaItem item) => _setWatched(item, false);

  @override
  Future<void> removeFromContinueWatching(MediaItem item) => store.deleteProgress(_connection.id, item.id);

  @override
  Future<void> rate(MediaItem item, double rating) async => throw UnsupportedError('IPTV has no ratings.');

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) async => throw UnsupportedError('IPTV has no favorites.');

  // ---------------------------------------------------------------------------
  // Playlists and collections: none
  // ---------------------------------------------------------------------------

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
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) async =>
      throw UnsupportedError('IPTV has no playlists.');

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) async =>
      throw UnsupportedError('IPTV has no playlists.');

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) async => throw UnsupportedError('IPTV has no playlists.');

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) async => throw UnsupportedError('IPTV has no playlists.');

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) async =>
      throw UnsupportedError('IPTV has no playlists.');

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
  }) async => throw UnsupportedError('IPTV has no collections.');

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) async =>
      throw UnsupportedError('IPTV has no collections.');

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) async =>
      throw UnsupportedError('IPTV has no collections.');

  @override
  Future<bool> deleteCollection(MediaItem collection) async => throw UnsupportedError('IPTV has no collections.');

  /// Only local recordings can be deleted.
  @override
  Future<bool> deleteMediaItem(MediaItem item) async {
    final parsed = IptvItemId.parse(item.id);
    if (parsed is! IptvRecordingId) return false;
    await IptvRecorder.instance.deleteRecording(parsed.recordingId);
    return true;
  }

  @override
  Future<MediaFileInfo?> getFileInfo(MediaItem item) async => null;

  // ---------------------------------------------------------------------------
  // Images and headers
  // ---------------------------------------------------------------------------

  /// Provider artwork is absolute and needs no headers.
  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    if (path == null || path.isEmpty) return '';
    return path;
  }

  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;

  /// The headers the source's streams need (its user-agent and referrer).
  /// Channels with their own headers send those instead (see the live
  /// session).
  @override
  Map<String, String> get streamHeaders => {
    if (_connection.userAgent != null) 'User-Agent': _connection.userAgent!,
    if (_connection.referrer != null) 'Referer': _connection.referrer!,
  };

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    final item = await fetchItem(itemId);
    final tmdb = int.tryParse('${item?.raw?['tmdb'] ?? ''}');
    return ExternalIds(tmdb: tmdb);
  }

  @override
  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async => null;

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

  // ---------------------------------------------------------------------------
  // Playback
  // ---------------------------------------------------------------------------

  @override
  double get watchedThreshold => 0.9;

  /// Nothing marks watched on its own: the player's explicit mark is the one
  /// that stores it.
  @override
  bool get marksWatchedOnPlaybackStopped => false;

  /// What [item] is kept with in the progress table (Continue Watching rows
  /// are built from it, without the provider).
  static Map<String, Object?> _progressMeta(MediaItem item) => {
    'title': ?item.title,
    'thumb': ?item.thumbPath,
    'art': ?item.artPath,
    'year': ?item.year,
    'index': ?item.index,
    'parentIndex': ?item.parentIndex,
    'parentId': ?item.parentId,
    'grandparentId': ?item.grandparentId,
    'grandparentTitle': ?item.grandparentTitle,
    'grandparentThumb': ?item.grandparentThumbPath,
    'grandparentArt': ?item.grandparentArtPath,
    'ext': ?item.raw?['ext'],
  };

  /// Items being played this session, for progress rows.
  final Map<String, MediaItem> _playing = {};

  Future<void> _saveProgress(String itemId, Duration position, Duration? duration) async {
    final parsed = IptvItemId.parse(itemId);
    if (parsed is! IptvMovieId && parsed is! IptvEpisodeId) return;
    final item = _playing[itemId];
    final durationMs = duration?.inMilliseconds ?? item?.durationMs ?? 0;
    final positionMs = position.inMilliseconds;
    if (positionMs < 10000) return;
    final existing = await store.progress(_connection.id, itemId);
    final finished = durationMs > 0 && positionMs >= durationMs * watchedThreshold;
    await store.saveProgress(
      _connection.id,
      itemId,
      positionMs: finished ? 0 : positionMs,
      durationMs: durationMs,
      watched: finished || (existing?.watched ?? false) && positionMs == 0,
      meta: item == null ? existing?.meta ?? const {} : _progressMeta(item),
    );
  }

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
  }) async {}

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
  }) => _saveProgress(itemId, position, duration);

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
    await _saveProgress(itemId, position, duration);
    _playing.remove(itemId);
  }

  /// The stream address of a movie, episode or recording.
  @visibleForTesting
  Future<String?> streamUrlFor(MediaItem item) async {
    final parsed = IptvItemId.parse(item.id);
    final api = _xtream;
    switch (parsed) {
      case IptvMovieId(:final streamId):
        if (api == null) return null;
        final ext =
            item.raw?['ext'] as String? ??
            (await store.vodRow(_connection.id, IptvGroupKind.movie, streamId))?.extension ??
            'mp4';
        return api.movieUrl(streamId, ext);
      case IptvEpisodeId(:final episodeId):
        if (api == null) return null;
        return api.seriesUrl(episodeId, item.raw?['ext'] as String? ?? 'mp4');
      case IptvRecordingId(:final recordingId):
        final rec = (await store.recordings(sourceId: _connection.id)).where((r) => r.id == recordingId).firstOrNull;
        final path = rec?.path;
        return path == null ? null : Uri.file(path).toString();
      default:
        return null;
    }
  }

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final item = options.metadata;
    final url = await streamUrlFor(item);
    if (url == null) {
      appLogger.w('[iptv] nothing to play for ${item.kind.name}');
      throw PlaybackException(t.messages.playbackFailed, reason: PlaybackFailureReason.noPlayableSource);
    }
    _playing[item.id] = item;
    appLogger.i('[iptv] playing ${item.kind.name} (direct stream)');
    final isRecording = IptvItemId.parse(item.id) is IptvRecordingId;
    return PlaybackInitializationResult(availableVersions: const [], videoUrl: url, isOffline: isRecording);
  }

  @override
  LiveTvSupport get liveTv => _IptvLiveTvSupport(this);

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async =>
      throw UnsupportedError('IPTV titles are not downloaded.');

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async => item;

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) => buildArtworkSpecs(item, thumbnailUrl);

  /// External players get the provider's address as is; it needs no header
  /// unless the source set one, which an external player cannot send.
  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async {
    final url = await streamUrlFor(item);
    return url == null ? null : ExternalPlaybackTarget(url: url);
  }
}
