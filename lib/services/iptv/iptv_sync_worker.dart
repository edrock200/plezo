import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../connection/connection.dart';
import '../../utils/app_logger.dart';
import 'iptv_catchup.dart';
import 'iptv_epg_matching.dart';
import 'iptv_store.dart';
import 'm3u_parser.dart';
import 'xmltv_parser.dart';
import 'xtream_api.dart';

/// What a refresh is doing, for the source's settings page.
enum IptvSyncPhase { idle, playlist, movies, series, guide, matching, done, failed }

class IptvSyncProgress {
  const IptvSyncProgress(this.phase, {this.count = 0, this.message});
  final IptvSyncPhase phase;
  final int count;
  final String? message;
}

/// The playlist or guide could not be read. [message] is safe to show (no
/// address, no login).
class IptvSyncException implements Exception {
  const IptvSyncException(this.message, {this.authFailed = false});
  final String message;
  final bool authFailed;
  @override
  String toString() => 'IptvSyncException($message)';
}

/// Store meta keys.
abstract final class IptvMetaKeys {
  /// The playlist header's guide addresses (newline separated).
  static const headerEpg = 'header_epg';

  /// The last Xtream account answer ([XtreamAccount.toJson]).
  static const account = 'xtream_account';

  /// How the last guide refresh went for the source's own guide (Xtream
  /// `xmltv.php`, or the playlist header's): JSON `{own, error, programmes}`,
  /// `own` one of `ok`, `empty`, `failed`, `none`.
  static const guideState = 'guide_state';
}

/// Imports a source's playlist and guide into the [IptvStore].
///
/// Everything streams: a playlist is parsed line by line and a guide as XML
/// events, written in batches. Run it in a background isolate (see
/// `IptvSyncService`) or, in tests, directly.
class IptvSyncWorker {
  IptvSyncWorker({required this.store, http.Client? client, this.onProgress, DateTime Function()? now})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _now = now ?? DateTime.now;

  final IptvStore store;
  final http.Client _client;
  final bool _ownsClient;
  final void Function(IptvSyncProgress progress)? onProgress;
  final DateTime Function() _now;

  static const playlistKind = 'playlist';
  static const epgKind = 'epg';
  static const vodKind = 'vod';

  void _progress(IptvSyncPhase phase, {int count = 0, String? message}) =>
      onProgress?.call(IptvSyncProgress(phase, count: count, message: message));

  void close() {
    if (_ownsClient) _client.close();
  }

  Map<String, String> _requestHeaders(IptvConnection c) => {
    'User-Agent': c.userAgent ?? 'Plezilo',
    if (c.referrer != null) 'Referer': c.referrer!,
  };

  /// Bytes of [url]: http(s), `file://` or a plain path.
  Future<Stream<List<int>>> _open(String url, IptvConnection c) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme.isEmpty || uri.scheme == 'file') {
      final path = uri != null && uri.scheme == 'file' ? uri.toFilePath() : url;
      final file = File(path);
      if (!await file.exists()) throw const IptvSyncException('file not found');
      return file.openRead();
    }
    final request = http.Request('GET', uri)..headers.addAll(_requestHeaders(c));
    final http.StreamedResponse response;
    try {
      // Big panels take a while to start a guide of hundreds of MB.
      response = await _client.send(request).timeout(const Duration(seconds: 120));
    } on TimeoutException {
      throw const IptvSyncException('timeout');
    } catch (e) {
      throw IptvSyncException('connection failed (${e.runtimeType})');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      await response.stream.drain<void>();
      throw IptvSyncException('HTTP ${response.statusCode}', authFailed: true);
    }
    if (response.statusCode >= 400) {
      await response.stream.drain<void>();
      throw IptvSyncException('HTTP ${response.statusCode}');
    }
    // No total cap: a slow download may take long, a stalled one fails.
    return response.stream.timeout(
      const Duration(seconds: 60),
      onTimeout: (sink) {
        sink.addError(const IptvSyncException('stalled'));
        sink.close();
      },
    );
  }

  // ---- playlist -------------------------------------------------------------

  /// Import the channel list (and, for Xtream with [withVod], movies and
  /// series; the refresh imports those last, after the guide: [importVod]).
  /// Returns the number of channels.
  Future<int> importPlaylist(IptvConnection c, {bool withVod = true}) async {
    try {
      final count = c.isXtream ? await _importXtream(c, withVod: withVod) : await _importM3u(c);
      await store.recordSync(c.id, playlistKind, ok: true, count: count);
      await rematch(c);
      _progress(IptvSyncPhase.done, count: count);
      return count;
    } on XtreamAuthException catch (e) {
      appLogger.w('[iptv] playlist refresh refused: ${e.status ?? 'login refused'}');
      await store.recordSync(c.id, playlistKind, ok: false, error: 'login refused');
      _progress(IptvSyncPhase.failed, message: 'login refused');
      throw const IptvSyncException('login refused', authFailed: true);
    } on XtreamRequestException catch (e) {
      final message = e.statusCode == null ? e.message : 'HTTP ${e.statusCode}';
      appLogger.w('[iptv] playlist refresh failed: $message');
      await store.recordSync(c.id, playlistKind, ok: false, error: message);
      _progress(IptvSyncPhase.failed, message: message);
      throw IptvSyncException(message);
    } on IptvSyncException catch (e) {
      appLogger.w('[iptv] playlist refresh failed: ${e.message}');
      await store.recordSync(c.id, playlistKind, ok: false, error: e.message);
      _progress(IptvSyncPhase.failed, message: e.message);
      rethrow;
    }
  }

  /// A stable id for a playlist entry: favourites and the user's changes are
  /// keyed by it, so it survives a refresh as long as the entry keeps its
  /// name, guide id and group (stream addresses often carry rotating tokens).
  static String m3uChannelId(M3uEntry entry) {
    final basis = '${entry.group ?? ''}\n${entry.displayName}\n${entry.tvgId ?? ''}';
    return sha1.convert(utf8.encode(basis)).toString().substring(0, 16);
  }

  static const _movieExtensions = {
    'mp4', 'mkv', 'avi', 'mov', 'm4v', 'wmv', 'flv', 'webm', 'mpg', 'mpeg', 'divx', 'ogv', '3gp', //
  };
  static final _movieGroup = RegExp(r'\b(movies?|vod|films?|series|cinema)\b', caseSensitive: false);

  /// Whether a playlist entry looks like a movie file rather than a channel
  /// (for "Treat movie files as movies"): a video-file address, or a
  /// Movies/VOD/Series group whose address is not a live stream (`.ts`,
  /// `.m3u8`, `/live/`). Entries with catch-up are always channels.
  static bool looksLikeMovie(M3uEntry entry) {
    if (entry.catchup != null || entry.catchupSource != null) return false;
    final path = (Uri.tryParse(entry.url)?.path ?? entry.url).toLowerCase();
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 || dot < path.lastIndexOf('/') ? '' : path.substring(dot + 1);
    if (_movieExtensions.contains(ext)) return true;
    if (ext == 'ts' || ext == 'm3u8' || path.contains('/live/')) return false;
    final group = entry.group;
    return group != null && _movieGroup.hasMatch(group);
  }

  static final _yearInName = RegExp(r'[\(\[]((?:19|20)\d{2})[\)\]]\s*$');

  /// Rows written per batch while a list imports (never the whole list).
  static const importBatch = 2000;

  Future<int> _importM3u(IptvConnection c) async {
    _progress(IptvSyncPhase.playlist);
    final address = c.m3uFilePath ?? c.m3uUrl;
    if (address.trim().isEmpty) throw const IptvSyncException('no playlist address');
    final bytes = await _open(address, c);
    var channels = <IptvChannel>[];
    var movies = <IptvVodRow>[];
    final groups = <String, int>{};
    final movieGroups = <String, int>{};
    final seenIds = <String, int>{};
    var channelCount = 0;
    var movieCount = 0;
    await store.beginChannelImport(c.id);
    await store.beginVodImport(c.id, IptvGroupKind.movie);
    late final M3uStreamParser parser;
    parser = M3uStreamParser((entry) {
      if (entry.url.isEmpty) return;
      if (c.m3uMoviesAsVod && looksLikeMovie(entry)) {
        var id = 'm${m3uChannelId(entry)}';
        final dup = seenIds[id] = (seenIds[id] ?? 0) + 1;
        if (dup > 1) id = '$id~$dup';
        final group = entry.group;
        if (group != null) movieGroups.putIfAbsent(group, () => movieGroups.length);
        final name = entry.displayName;
        final year = _yearInName.firstMatch(name);
        final path = (Uri.tryParse(entry.url)?.path ?? '').toLowerCase();
        final dot = path.lastIndexOf('.');
        movies.add(
          IptvVodRow(
            sourceId: c.id,
            kind: IptvGroupKind.movie,
            id: id,
            name: name,
            sortIndex: movieCount++,
            categoryId: group,
            poster: entry.tvgLogo,
            year: year == null ? null : int.tryParse(year.group(1)!),
            extension: dot < 0 ? null : path.substring(dot + 1),
            url: entry.url,
            headers: entry.headers,
          ),
        );
        return;
      }
      var id = m3uChannelId(entry);
      final dup = seenIds[id] = (seenIds[id] ?? 0) + 1;
      if (dup > 1) id = '$id~$dup';
      final group = entry.group;
      if (group != null) groups.putIfAbsent(group, () => groups.length);
      // The header comes first, so its playlist-wide defaults are known here.
      final header = parser.header;
      final own = IptvCatchupMode.parse(entry.catchup);
      final useHeader = own == IptvCatchupMode.none && header.catchup != null;
      channels.add(
        IptvChannel(
          sourceId: c.id,
          id: id,
          name: entry.displayName,
          originalName: entry.displayName,
          playlistNumber: entry.tvgChno,
          sortIndex: channelCount++,
          group: group,
          logo: entry.tvgLogo,
          url: entry.url,
          tvgId: entry.tvgId,
          tvgName: entry.tvgName,
          tvgShiftHours: useHeader ? entry.tvgShift ?? header.tvgShift : entry.tvgShift,
          catchupMode: useHeader ? IptvCatchupMode.parse(header.catchup) : own,
          catchupDays: useHeader ? entry.catchupDays ?? header.catchupDays : entry.catchupDays,
          catchupSource: useHeader ? entry.catchupSource ?? header.catchupSource : entry.catchupSource,
          radio: entry.isRadio,
          headers: entry.headers,
        ),
      );
    });
    await for (final line in M3uStreamParser.linesOf(bytes)) {
      parser.addLine(line);
      if (channels.length >= importBatch) {
        final batch = channels;
        channels = [];
        await store.stageChannels(c.id, batch);
        _progress(IptvSyncPhase.playlist, count: channelCount);
      }
      if (movies.length >= importBatch) {
        final batch = movies;
        movies = [];
        await store.stageVod(c.id, IptvGroupKind.movie, batch);
      }
    }
    await store.stageChannels(c.id, channels);
    await store.stageVod(c.id, IptvGroupKind.movie, movies);
    final header = parser.header;
    if (channelCount == 0 && movieCount == 0) {
      await store.beginChannelImport(c.id);
      await store.beginVodImport(c.id, IptvGroupKind.movie);
      throw const IptvSyncException('the playlist has no channels');
    }
    await store.commitChannelImport(c.id, [
      for (final e in groups.entries) IptvGroup(kind: IptvGroupKind.live, id: e.key, name: e.key, sortIndex: e.value),
    ]);
    // Movie files (when asked for) become the Movies library; turning the
    // setting off clears it.
    await store.commitVodImport(c.id, IptvGroupKind.movie, [
      for (final e in movieGroups.entries)
        IptvGroup(kind: IptvGroupKind.movie, id: e.key, name: e.key, sortIndex: e.value),
    ]);
    if (c.m3uMoviesAsVod) appLogger.i('[iptv] playlist movies=$movieCount categories=${movieGroups.length}');
    await store.putMeta(c.id, IptvMetaKeys.headerEpg, header.epgUrls.isEmpty ? null : header.epgUrls.join('\n'));
    appLogger.i(
      '[iptv] playlist imported channels=$channelCount groups=${groups.length} guides=${header.epgUrls.length}',
    );
    return channelCount;
  }

  XtreamApi _xtream(IptvConnection c) => XtreamApi(
    XtreamCredentials(baseUrl: c.xtreamServer, username: c.xtreamUsername, password: c.xtreamPassword),
    client: _client,
    userAgent: c.userAgent,
  );

  /// Xtream movies and series on their own (recorded as [vodKind]), so a
  /// big catalogue never holds up the channels or the guide.
  Future<void> importVod(IptvConnection c) async {
    if (!c.isXtream) return;
    if (!c.includeVod) {
      await store.replaceVod(c.id, IptvGroupKind.movie, const [], const []);
      await store.replaceVod(c.id, IptvGroupKind.series, const [], const []);
      await store.recordSync(c.id, vodKind, ok: true);
      return;
    }
    try {
      final total = await _importXtreamVod(c, _xtream(c));
      await store.recordSync(c.id, vodKind, ok: true, count: total);
    } on XtreamAuthException {
      await store.recordSync(c.id, vodKind, ok: false, error: 'login refused');
      throw const IptvSyncException('login refused', authFailed: true);
    }
  }

  Future<int> _importXtream(IptvConnection c, {bool withVod = true}) async {
    _progress(IptvSyncPhase.playlist);
    final api = _xtream(c);
    final account = await api.account();
    await store.putMeta(c.id, IptvMetaKeys.account, jsonEncode(account.toJson()));
    final categories = await api.liveCategories();
    final categoryName = {for (final cat in categories) cat.id: cat.name};
    // Groups by name (the channel's `grp`), in the provider's order; only the
    // names are kept while the rows stream past.
    final groupOrder = <String, int>{};
    for (final cat in categories) {
      groupOrder.putIfAbsent(cat.name, () => groupOrder.length);
    }
    var index = 0;
    await store.beginChannelImport(c.id);
    try {
      await api.forEachRow('get_live_streams', batchSize: importBatch, (rows) async {
        final channels = <IptvChannel>[];
        for (final row in rows) {
          final streamId = xtreamString(row['stream_id']);
          if (streamId == null) continue;
          final type = xtreamString(row['stream_type']);
          final archive = xtreamBool(row['tv_archive']);
          final categoryId = xtreamString(row['category_id']);
          final name = xtreamString(row['name']) ?? streamId;
          final group = categoryId == null ? null : categoryName[categoryId] ?? categoryId;
          if (group != null) groupOrder.putIfAbsent(group, () => groupOrder.length);
          channels.add(
            IptvChannel(
              sourceId: c.id,
              id: 'x$streamId',
              name: name,
              originalName: name,
              playlistNumber: xtreamString(row['num']),
              sortIndex: index++,
              group: group,
              logo: xtreamString(row['stream_icon']),
              tvgId: xtreamString(row['epg_channel_id']),
              tvgName: name,
              catchupMode: archive ? IptvCatchupMode.xtream : IptvCatchupMode.none,
              catchupDays: archive ? xtreamInt(row['tv_archive_duration']) : null,
              radio: type == 'radio_streams',
              xtreamId: streamId,
            ),
          );
        }
        await store.stageChannels(c.id, channels);
        _progress(IptvSyncPhase.playlist, count: index);
      });
    } catch (_) {
      await store.beginChannelImport(c.id);
      rethrow;
    }
    await store.commitChannelImport(c.id, [
      for (final e in groupOrder.entries)
        IptvGroup(kind: IptvGroupKind.live, id: e.key, name: e.key, sortIndex: e.value),
    ]);
    appLogger.i('[iptv] xtream live imported channels=$index categories=${categories.length}');
    if (!withVod) return index;
    if (c.includeVod) {
      await _importXtreamVod(c, api);
    } else {
      await store.replaceVod(c.id, IptvGroupKind.movie, const [], const []);
      await store.replaceVod(c.id, IptvGroupKind.series, const [], const []);
    }
    return index;
  }

  /// Stream one Xtream VOD list into the staging table, then swap it in.
  /// Optional: a provider without it (or a failure) keeps the stored rows.
  Future<int?> _importVodList(
    IptvConnection c,
    XtreamApi api,
    IptvGroupKind kind, {
    required Future<List<XtreamCategory>> Function() categories,
    required String action,
    required IptvVodRow? Function(Map<String, dynamic> row, int sortIndex) map,
  }) async {
    await store.beginVodImport(c.id, kind);
    try {
      final cats = await categories();
      var count = 0;
      await api.forEachRow(action, batchSize: importBatch, (rows) async {
        final mapped = <IptvVodRow>[];
        for (final row in rows) {
          final r = map(row, count);
          if (r == null) continue;
          mapped.add(r);
          count++;
        }
        await store.stageVod(c.id, kind, mapped);
        _progress(kind == IptvGroupKind.movie ? IptvSyncPhase.movies : IptvSyncPhase.series, count: count);
      });
      await store.commitVodImport(c.id, kind, [
        for (var i = 0; i < cats.length; i++) IptvGroup(kind: kind, id: cats[i].id, name: cats[i].name, sortIndex: i),
      ]);
      return count;
    } on XtreamAuthException {
      await store.beginVodImport(c.id, kind);
      rethrow;
    } catch (e) {
      // Movies and series are optional: a provider without them must not
      // fail the refresh; the stored ones stay.
      await store.beginVodImport(c.id, kind);
      appLogger.w('[iptv] xtream ${kind.id} not imported (${e is XtreamRequestException ? e.message : e.runtimeType})');
      return null;
    }
  }

  Future<int> _importXtreamVod(IptvConnection c, XtreamApi api) async {
    _progress(IptvSyncPhase.movies);
    final movies = await _importVodList(
      c,
      api,
      IptvGroupKind.movie,
      categories: api.vodCategories,
      action: 'get_vod_streams',
      map: (row, i) {
        final id = xtreamString(row['stream_id']);
        if (id == null) return null;
        return IptvVodRow(
          sourceId: c.id,
          kind: IptvGroupKind.movie,
          id: id,
          name: xtreamString(row['name']) ?? id,
          sortIndex: i,
          categoryId: xtreamString(row['category_id']),
          poster: xtreamString(row['stream_icon']),
          rating: xtreamDouble(row['rating']),
          year: _year(row),
          added: xtreamInt(row['added']),
          extension: xtreamString(row['container_extension']),
          plot: xtreamString(row['plot']),
          genre: xtreamString(row['genre']),
        );
      },
    );
    if (movies != null) appLogger.i('[iptv] xtream movies imported=$movies');
    _progress(IptvSyncPhase.series);
    final series = await _importVodList(
      c,
      api,
      IptvGroupKind.series,
      categories: api.seriesCategories,
      action: 'get_series',
      map: (row, i) {
        final id = xtreamString(row['series_id']);
        if (id == null) return null;
        return IptvVodRow(
          sourceId: c.id,
          kind: IptvGroupKind.series,
          id: id,
          name: xtreamString(row['name']) ?? id,
          sortIndex: i,
          categoryId: xtreamString(row['category_id']),
          poster: xtreamString(row['cover']),
          rating: xtreamDouble(row['rating']),
          year: _year(row),
          added: xtreamInt(row['last_modified']),
          plot: xtreamString(row['plot']),
          genre: xtreamString(row['genre']),
        );
      },
    );
    if (series != null) appLogger.i('[iptv] xtream series imported=$series');
    return (movies ?? 0) + (series ?? 0);
  }

  static int? _year(Map<String, dynamic> row) {
    final direct = xtreamInt(row['year']);
    if (direct != null && direct > 1800) return direct;
    final release = xtreamString(row['releaseDate']) ?? xtreamString(row['release_date']);
    if (release != null && release.length >= 4) return int.tryParse(release.substring(0, 4));
    final name = xtreamString(row['name']);
    final match = name == null ? null : RegExp(r'\((\d{4})\)').firstMatch(name);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  // ---- guide ----------------------------------------------------------------

  /// Every guide address of [c]: the user's, then the source's own.
  Future<List<String>> guideUrls(IptvConnection c) async {
    final urls = <String>[...c.epgUrls];
    if (c.useSourceEpg) {
      if (c.isXtream) {
        urls.add(_xtream(c).xmltvUri().toString());
      } else {
        final header = await store.meta(c.id, IptvMetaKeys.headerEpg);
        if (header != null) urls.addAll(header.split('\n').where((u) => u.trim().isNotEmpty));
      }
    }
    final seen = <String>{};
    return [
      for (final u in urls)
        if (seen.add(u.trim())) u.trim(),
    ];
  }

  /// The source's own guide addresses (Xtream `xmltv.php`, the playlist
  /// header's), when the source's guide is used.
  Future<Set<String>> _ownGuideUrls(IptvConnection c) async {
    if (!c.useSourceEpg) return const {};
    if (c.isXtream) return {_xtream(c).xmltvUri().toString()};
    final header = await store.meta(c.id, IptvMetaKeys.headerEpg);
    return {
      if (header != null)
        for (final u in header.split('\n'))
          if (u.trim().isNotEmpty) u.trim(),
    };
  }

  Future<void> _putGuideState(IptvConnection c, {required String own, String? error, int programmes = 0}) =>
      store.putMeta(c.id, IptvMetaKeys.guideState, jsonEncode({'own': own, 'error': ?error, 'programmes': programmes}));

  /// Import every guide of [c] into the store, keeping the configured window
  /// and only the guide channels some playlist channel can use. Returns the
  /// programmes stored.
  Future<int> importEpg(IptvConnection c) async {
    final urls = await guideUrls(c);
    final ownUrls = await _ownGuideUrls(c);
    if (urls.isEmpty) {
      await store.recordSync(c.id, epgKind, ok: true, count: 0);
      await _putGuideState(c, own: 'none');
      appLogger.i('[iptv] guide: no guide address');
      return 0;
    }
    String? ownOutcome;
    String? ownError;
    var ownProgrammes = 0;
    _progress(IptvSyncPhase.guide);
    final wantedIds = <String>{};
    final wantedNames = <String>{};
    await store.forEachChannelGuideKey(c.id, (ch) {
      for (final id in [ch.tvgId, ch.manualEpgId]) {
        if (id != null && id.isNotEmpty) wantedIds.add(id.toLowerCase());
      }
      for (final name in [ch.tvgName, ch.originalName, ch.name]) {
        if (name == null) continue;
        final norm = normaliseChannelName(name);
        if (norm.isNotEmpty) wantedNames.add(norm);
      }
    });
    final now = _now().millisecondsSinceEpoch ~/ 1000;
    final from = now - c.epgPastDays.clamp(0, 14) * 86400;
    final to = now + c.epgFutureDays.clamp(1, 14) * 86400;

    // Guide channels are staged in batches as they are read (a guide can list
    // tens of thousands, each under several names).
    var guideChannelRows = <({String id, String displayName, String norm, String? icon})>[];
    await store.beginEpgChannelImport(c.id);
    final coveredByEarlier = <String>{};
    var stored = 0;
    var failures = 0;
    String? lastError;
    await store.beginProgrammeImport(c.id);
    for (var u = 0; u < urls.length; u++) {
      final kept = <String>{};
      final coveredHere = <String>{};
      var channelsSeen = 0;
      var programmesSeen = 0;
      final buffer = <IptvProgramme>[];
      var pending = Future<void>.value();
      void flush() {
        if (buffer.isNotEmpty) {
          final batch = List<IptvProgramme>.of(buffer);
          buffer.clear();
          pending = pending.then((_) => store.stageProgrammes(c.id, batch));
        }
        if (guideChannelRows.isNotEmpty) {
          final rows = guideChannelRows;
          guideChannelRows = [];
          pending = pending.then((_) => store.stageEpgChannels(c.id, rows));
        }
      }

      final parser = XmltvStreamParser(
        onChannel: (channel) {
          channelsSeen++;
          final norms = [for (final n in channel.displayNames) normaliseChannelName(n)];
          final wanted = wantedIds.contains(channel.id.toLowerCase()) || norms.any(wantedNames.contains);
          for (var i = 0; i < channel.displayNames.length; i++) {
            guideChannelRows.add((
              id: channel.id,
              displayName: channel.displayNames[i],
              norm: norms[i],
              icon: channel.icon,
            ));
          }
          if (channel.displayNames.isEmpty) {
            guideChannelRows.add((id: channel.id, displayName: channel.id, norm: '', icon: channel.icon));
          }
          if (wanted && !coveredByEarlier.contains(channel.id)) kept.add(channel.id);
          if (guideChannelRows.length >= importBatch) flush();
        },
        keepProgramme: (channel, start, stop) {
          if (stop < from || start > to) return false;
          if (kept.contains(channel)) return true;
          // A guide that lists programmes before its channels: by id only.
          return channelsSeen == 0 && wantedIds.contains(channel.toLowerCase()) && !coveredByEarlier.contains(channel);
        },
        onProgramme: (programme) {
          coveredHere.add(programme.channel);
          programmesSeen++;
          buffer.add(
            IptvProgramme(
              epgChannelId: programme.channel,
              start: programme.start,
              stop: programme.stop,
              title: programme.title,
              subTitle: programme.subTitle,
              description: programme.description,
              category: programme.category,
              icon: programme.icon,
              episode: programme.episode,
              season: programme.season,
              episodeNumber: programme.episodeNumber,
              rating: programme.rating,
              year: programme.year,
              isNew: programme.isNew,
            ),
          );
          if (buffer.length >= 5000) {
            flush();
            _progress(IptvSyncPhase.guide, count: stored + programmesSeen);
          }
        },
      );
      try {
        final bytes = await _open(urls[u], c);
        await parser.parseBytes(bytes);
        flush();
        await pending;
        stored += parser.programmes;
        coveredByEarlier.addAll(coveredHere);
        if (ownUrls.contains(urls[u])) {
          ownProgrammes += parser.programmes;
          ownOutcome = ownProgrammes > 0 ? 'ok' : (ownOutcome == 'ok' ? 'ok' : 'empty');
        }
        appLogger.i(
          '[iptv] guide ${u + 1}/${urls.length} read channels=${parser.channels} programmes=${parser.programmes} '
          'skipped=${parser.skipped}',
        );
      } catch (e) {
        await pending.catchError((_) {});
        failures++;
        lastError = e is IptvSyncException ? e.message : 'unreadable guide (${e.runtimeType})';
        appLogger.w('[iptv] guide ${u + 1}/${urls.length} failed: $lastError');
        if (ownUrls.contains(urls[u]) && ownOutcome != 'ok') {
          ownOutcome = 'failed';
          ownError = lastError;
        }
      }
    }
    final own = ownUrls.isEmpty ? 'none' : ownOutcome ?? 'failed';
    await _putGuideState(c, own: own, error: ownError, programmes: ownProgrammes);
    if (c.isXtream && own != 'ok') {
      appLogger.i('[iptv] xtream guide $own; channels read their guide from the provider when shown');
    }
    if (failures == urls.length) {
      await store.beginProgrammeImport(c.id);
      await store.beginEpgChannelImport(c.id);
      await store.recordSync(c.id, epgKind, ok: false, error: lastError);
      _progress(IptvSyncPhase.failed, message: lastError);
      throw IptvSyncException(lastError ?? 'guide failed');
    }
    final total = await store.commitProgrammeImport(c.id);
    await store.commitEpgChannelImport(c.id);
    await rematch(c);
    await store.recordSync(c.id, epgKind, ok: true, count: total, error: failures == 0 ? null : lastError);
    appLogger.i('[iptv] guide imported programmes=$total from ${urls.length - failures}/${urls.length} guides');
    _progress(IptvSyncPhase.done, count: total);
    return total;
  }

  /// Match every channel to a guide channel and store the result.
  Future<void> rematch(IptvConnection c) async {
    _progress(IptvSyncPhase.matching);
    final guide = await store.epgChannels(c.id);
    final matcher = IptvEpgMatcher(guideIds: guide.names.keys, guideNames: guide.byNorm);
    final updates = <String, String?>{};
    var byId = 0;
    var byName = 0;
    await store.forEachChannelGuideKey(c.id, (ch) {
      final result = matcher.match(tvgId: ch.tvgId, tvgName: ch.tvgName, title: ch.originalName ?? ch.name);
      // Xtream's own guide id stays when the guide has not been read yet.
      final id = result.id ?? (guide.names.isEmpty ? ch.tvgId : null);
      if (result.how == IptvEpgMatch.tvgId) byId++;
      if (result.how == IptvEpgMatch.name) byName++;
      updates[ch.id] = id;
    });
    if (updates.isEmpty) return;
    await store.setChannelEpgIds(c.id, updates);
    appLogger.i('[iptv] guide matching channels=${updates.length} by_id=$byId by_name=$byName');
  }
}
