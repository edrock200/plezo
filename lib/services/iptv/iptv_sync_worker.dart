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
      response = await _client.send(request).timeout(const Duration(seconds: 60));
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
    return response.stream;
  }

  // ---- playlist -------------------------------------------------------------

  /// Import the channel list (and, for Xtream, movies and series). Returns
  /// the number of channels.
  Future<int> importPlaylist(IptvConnection c) async {
    try {
      final count = c.isXtream ? await _importXtream(c) : await _importM3u(c);
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

  Future<int> _importM3u(IptvConnection c) async {
    _progress(IptvSyncPhase.playlist);
    final address = c.m3uFilePath ?? c.m3uUrl;
    if (address.trim().isEmpty) throw const IptvSyncException('no playlist address');
    final bytes = await _open(address, c);
    final channels = <IptvChannel>[];
    final groups = <String, int>{};
    final seenIds = <String, int>{};
    var index = 0;
    final header = await M3uStreamParser.parse(M3uStreamParser.linesOf(bytes), (entry) {
      if (entry.url.isEmpty) return;
      var id = m3uChannelId(entry);
      final dup = seenIds[id] = (seenIds[id] ?? 0) + 1;
      if (dup > 1) id = '$id~$dup';
      final group = entry.group;
      if (group != null) groups.putIfAbsent(group, () => groups.length);
      channels.add(
        IptvChannel(
          sourceId: c.id,
          id: id,
          name: entry.displayName,
          originalName: entry.displayName,
          playlistNumber: entry.tvgChno,
          sortIndex: index++,
          group: group,
          logo: entry.tvgLogo,
          url: entry.url,
          tvgId: entry.tvgId,
          tvgName: entry.tvgName,
          tvgShiftHours: entry.tvgShift,
          catchupMode: IptvCatchupMode.parse(entry.catchup),
          catchupDays: entry.catchupDays,
          catchupSource: entry.catchupSource,
          radio: entry.isRadio,
          headers: entry.headers,
        ),
      );
      if (index % 5000 == 0) _progress(IptvSyncPhase.playlist, count: index);
    });
    // Playlist-wide catch-up defaults for entries that named none.
    final withDefaults = header.catchup == null
        ? channels
        : [
            for (final ch in channels)
              ch.catchupMode != IptvCatchupMode.none
                  ? ch
                  : IptvChannel(
                      sourceId: ch.sourceId,
                      id: ch.id,
                      name: ch.name,
                      originalName: ch.originalName,
                      playlistNumber: ch.playlistNumber,
                      sortIndex: ch.sortIndex,
                      group: ch.group,
                      logo: ch.logo,
                      url: ch.url,
                      tvgId: ch.tvgId,
                      tvgName: ch.tvgName,
                      tvgShiftHours: ch.tvgShiftHours ?? header.tvgShift,
                      catchupMode: IptvCatchupMode.parse(header.catchup),
                      catchupDays: ch.catchupDays ?? header.catchupDays,
                      catchupSource: ch.catchupSource ?? header.catchupSource,
                      radio: ch.radio,
                      headers: ch.headers,
                    ),
          ];
    if (withDefaults.isEmpty) throw const IptvSyncException('the playlist has no channels');
    await store.replaceChannels(c.id, withDefaults, [
      for (final e in groups.entries) IptvGroup(kind: IptvGroupKind.live, id: e.key, name: e.key, sortIndex: e.value),
    ]);
    await store.putMeta(c.id, IptvMetaKeys.headerEpg, header.epgUrls.isEmpty ? null : header.epgUrls.join('\n'));
    appLogger.i(
      '[iptv] playlist imported channels=${withDefaults.length} groups=${groups.length} guides=${header.epgUrls.length}',
    );
    return withDefaults.length;
  }

  XtreamApi _xtream(IptvConnection c) => XtreamApi(
    XtreamCredentials(baseUrl: c.xtreamServer, username: c.xtreamUsername, password: c.xtreamPassword),
    client: _client,
    userAgent: c.userAgent,
  );

  Future<int> _importXtream(IptvConnection c) async {
    _progress(IptvSyncPhase.playlist);
    final api = _xtream(c);
    final account = await api.account();
    await store.putMeta(c.id, IptvMetaKeys.account, jsonEncode(account.toJson()));
    final results = await Future.wait([api.liveCategories(), api.liveStreams()]);
    final categories = results[0] as List<XtreamCategory>;
    final streams = results[1] as List<Map<String, dynamic>>;
    final categoryName = {for (final cat in categories) cat.id: cat.name};
    final channels = <IptvChannel>[];
    var index = 0;
    for (final row in streams) {
      final streamId = xtreamString(row['stream_id']);
      if (streamId == null) continue;
      final type = xtreamString(row['stream_type']);
      final archive = xtreamBool(row['tv_archive']);
      final categoryId = xtreamString(row['category_id']);
      final name = xtreamString(row['name']) ?? streamId;
      channels.add(
        IptvChannel(
          sourceId: c.id,
          id: 'x$streamId',
          name: name,
          originalName: name,
          playlistNumber: xtreamString(row['num']),
          sortIndex: index++,
          group: categoryId == null ? null : categoryName[categoryId] ?? categoryId,
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
    // Groups by name (the channel's `grp`), in the provider's order.
    final groupOrder = <String, int>{};
    for (final cat in categories) {
      groupOrder.putIfAbsent(cat.name, () => groupOrder.length);
    }
    for (final ch in channels) {
      final g = ch.group;
      if (g != null) groupOrder.putIfAbsent(g, () => groupOrder.length);
    }
    await store.replaceChannels(c.id, channels, [
      for (final e in groupOrder.entries)
        IptvGroup(kind: IptvGroupKind.live, id: e.key, name: e.key, sortIndex: e.value),
    ]);
    appLogger.i('[iptv] xtream live imported channels=${channels.length} categories=${categories.length}');
    if (c.includeVod) {
      await _importXtreamVod(c, api);
    } else {
      await store.replaceVod(c.id, IptvGroupKind.movie, const [], const []);
      await store.replaceVod(c.id, IptvGroupKind.series, const [], const []);
    }
    return channels.length;
  }

  Future<void> _importXtreamVod(IptvConnection c, XtreamApi api) async {
    _progress(IptvSyncPhase.movies);
    try {
      final results = await Future.wait([api.vodCategories(), api.vodStreams()]);
      final cats = results[0] as List<XtreamCategory>;
      final rows = results[1] as List<Map<String, dynamic>>;
      final movies = <IptvVodRow>[];
      for (final row in rows) {
        final id = xtreamString(row['stream_id']);
        if (id == null) continue;
        movies.add(
          IptvVodRow(
            sourceId: c.id,
            kind: IptvGroupKind.movie,
            id: id,
            name: xtreamString(row['name']) ?? id,
            sortIndex: movies.length,
            categoryId: xtreamString(row['category_id']),
            poster: xtreamString(row['stream_icon']),
            rating: xtreamDouble(row['rating']),
            year: _year(row),
            added: xtreamInt(row['added']),
            extension: xtreamString(row['container_extension']),
            plot: xtreamString(row['plot']),
            genre: xtreamString(row['genre']),
          ),
        );
      }
      await store.replaceVod(c.id, IptvGroupKind.movie, movies, [
        for (var i = 0; i < cats.length; i++)
          IptvGroup(kind: IptvGroupKind.movie, id: cats[i].id, name: cats[i].name, sortIndex: i),
      ]);
      appLogger.i('[iptv] xtream movies imported=${movies.length}');
    } on XtreamAuthException {
      rethrow;
    } catch (e) {
      // Movies are optional: a provider without them must not fail the refresh.
      appLogger.w('[iptv] xtream movies not imported (${e.runtimeType})');
    }
    _progress(IptvSyncPhase.series);
    try {
      final results = await Future.wait([api.seriesCategories(), api.series()]);
      final cats = results[0] as List<XtreamCategory>;
      final rows = results[1] as List<Map<String, dynamic>>;
      final series = <IptvVodRow>[];
      for (final row in rows) {
        final id = xtreamString(row['series_id']);
        if (id == null) continue;
        series.add(
          IptvVodRow(
            sourceId: c.id,
            kind: IptvGroupKind.series,
            id: id,
            name: xtreamString(row['name']) ?? id,
            sortIndex: series.length,
            categoryId: xtreamString(row['category_id']),
            poster: xtreamString(row['cover']),
            rating: xtreamDouble(row['rating']),
            year: _year(row),
            added: xtreamInt(row['last_modified']),
            plot: xtreamString(row['plot']),
            genre: xtreamString(row['genre']),
          ),
        );
      }
      await store.replaceVod(c.id, IptvGroupKind.series, series, [
        for (var i = 0; i < cats.length; i++)
          IptvGroup(kind: IptvGroupKind.series, id: cats[i].id, name: cats[i].name, sortIndex: i),
      ]);
      appLogger.i('[iptv] xtream series imported=${series.length}');
    } on XtreamAuthException {
      rethrow;
    } catch (e) {
      appLogger.w('[iptv] xtream series not imported (${e.runtimeType})');
    }
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

  /// Import every guide of [c] into the store, keeping the configured window
  /// and only the guide channels some playlist channel can use. Returns the
  /// programmes stored.
  Future<int> importEpg(IptvConnection c) async {
    final urls = await guideUrls(c);
    if (urls.isEmpty) {
      await store.recordSync(c.id, epgKind, ok: true, count: 0);
      appLogger.i('[iptv] guide: no guide address');
      return 0;
    }
    _progress(IptvSyncPhase.guide);
    final channels = await store.channels(c.id);
    final wantedIds = <String>{};
    final wantedNames = <String>{};
    for (final ch in channels) {
      for (final id in [ch.tvgId, ch.manualEpgId]) {
        if (id != null && id.isNotEmpty) wantedIds.add(id.toLowerCase());
      }
      for (final name in [ch.tvgName, ch.originalName, ch.name]) {
        if (name == null) continue;
        final norm = normaliseChannelName(name);
        if (norm.isNotEmpty) wantedNames.add(norm);
      }
    }
    final now = _now().millisecondsSinceEpoch ~/ 1000;
    final from = now - c.epgPastDays.clamp(0, 14) * 86400;
    final to = now + c.epgFutureDays.clamp(1, 14) * 86400;

    final guideChannelRows = <({String id, String displayName, String norm, String? icon})>[];
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
        if (buffer.isEmpty) return;
        final batch = List<IptvProgramme>.of(buffer);
        buffer.clear();
        pending = pending.then((_) => store.stageProgrammes(c.id, batch));
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
        appLogger.i(
          '[iptv] guide ${u + 1}/${urls.length} read channels=${parser.channels} programmes=${parser.programmes} '
          'skipped=${parser.skipped}',
        );
      } catch (e) {
        await pending.catchError((_) {});
        failures++;
        lastError = e is IptvSyncException ? e.message : 'unreadable guide (${e.runtimeType})';
        appLogger.w('[iptv] guide ${u + 1}/${urls.length} failed: $lastError');
      }
    }
    if (failures == urls.length) {
      await store.beginProgrammeImport(c.id);
      await store.recordSync(c.id, epgKind, ok: false, error: lastError);
      _progress(IptvSyncPhase.failed, message: lastError);
      throw IptvSyncException(lastError ?? 'guide failed');
    }
    final total = await store.commitProgrammeImport(c.id);
    await store.replaceEpgChannels(c.id, guideChannelRows);
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
    final channels = await store.channels(c.id);
    if (channels.isEmpty) return;
    final matcher = IptvEpgMatcher(guideIds: guide.names.keys, guideNames: guide.byNorm);
    final updates = <String, String?>{};
    var byId = 0;
    var byName = 0;
    for (final ch in channels) {
      final result = matcher.match(tvgId: ch.tvgId, tvgName: ch.tvgName, title: ch.originalName ?? ch.name);
      // Xtream's own guide id stays when the guide has not been read yet.
      final id = result.id ?? (guide.names.isEmpty ? ch.tvgId : null);
      if (result.how == IptvEpgMatch.tvgId) byId++;
      if (result.how == IptvEpgMatch.name) byName++;
      updates[ch.id] = id;
    }
    await store.setChannelEpgIds(c.id, updates);
    appLogger.i('[iptv] guide matching channels=${channels.length} by_id=$byId by_name=$byName');
  }
}
