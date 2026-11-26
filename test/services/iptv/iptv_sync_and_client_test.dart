import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_filter.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/iptv/iptv_catchup.dart';
import 'package:plezy/services/iptv/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_parental.dart';
import 'package:plezy/services/iptv/iptv_store.dart';
import 'package:plezy/services/iptv/iptv_sync_worker.dart';
import 'package:plezy/services/iptv/m3u_parser.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/playback_initialization_types.dart';

import 'fake_iptv_server.dart';
import 'iptv_test_helpers.dart';

void main() {
  late FakeIptvServer server;
  late IptvStore store;
  late AppDatabase appDb;

  setUp(() async {
    server = await FakeIptvServer().start();
    store = memoryIptvStore();
    appDb = memoryAppDatabaseWithIptvCache();
  });

  tearDown(() async {
    await server.close();
    await store.db.close();
    await appDb.close();
    IptvParentalGate.lockAll();
  });

  group('M3U source', () {
    test('imports channels, groups, headers and the header guide, then matches by tvg-id', () async {
      final source = m3uSource(server.base);
      final worker = IptvSyncWorker(store: store, now: () => server.now);
      expect(await worker.importPlaylist(source), 6);
      final channels = await store.channels(source.id);
      expect(channels.map((c) => c.name).first, 'Channel 1 HD');
      expect(channels.first.group, 'News');
      expect(channels.first.headers['User-Agent'], 'FakePlayer/1.0');
      expect(channels.first.catchupMode, IptvCatchupMode.shift, reason: 'the header catch-up applies to every entry');
      expect(channels.first.catchupDays, 3);
      expect(await worker.guideUrls(source), ['${server.base}/epg.xml.gz']);

      final stored = await worker.importEpg(source);
      expect(stored, 6 * 24);
      final matched = await store.channels(source.id);
      expect(matched.every((c) => c.epgChannelId == c.tvgId), isTrue);
      final record = await store.syncRecord(source.id, IptvSyncWorker.epgKind);
      expect(record.lastSuccess, isNotNull);
      expect(record.count, 144);
      worker.close();
    });

    test('keeps only the configured guide window', () async {
      final source = m3uSource(server.base).copyWith(epgPastDays: 0, epgFutureDays: 1);
      final worker = IptvSyncWorker(store: store, now: () => server.now.add(const Duration(days: 1, hours: 10)));
      await worker.importPlaylist(source);
      final stored = await worker.importEpg(source);
      expect(stored, 0, reason: 'every programme ended before the window');
      worker.close();
    });

    test('a refresh keeps favourites and the user changes (stable channel ids)', () async {
      final source = m3uSource(server.base);
      final worker = IptvSyncWorker(store: store);
      await worker.importPlaylist(source);
      final first = (await store.channels(source.id)).first;
      await store.setFavoriteChannelIds(source.id, [first.id]);
      await store.setChannelOverride(source.id, first.id, hidden: false, name: 'Renamed', number: '7');
      await worker.importPlaylist(source);
      final again = (await store.channels(source.id)).first;
      expect(again.id, first.id);
      expect(again.name, 'Renamed');
      expect(again.number, '7');
      expect(await store.favoriteChannelIds(source.id), [first.id]);
      worker.close();
    });

    test('a failing guide is reported and keeps the previous guide', () async {
      final source = m3uSource(server.base);
      final worker = IptvSyncWorker(store: store, now: () => server.now);
      await worker.importPlaylist(source);
      await worker.importEpg(source);
      server.failEverything = true;
      await expectLater(worker.importEpg(source), throwsA(isA<IptvSyncException>()));
      expect(await store.programmeCount(source.id), 144);
      expect((await store.syncRecord(source.id, IptvSyncWorker.epgKind)).error, 'HTTP 500');
      worker.close();
    });

    test('matches by normalised name when tvg-id is missing, and honours a manual mapping', () async {
      final source = m3uSource(server.base);
      final worker = IptvSyncWorker(store: store, now: () => server.now);
      await worker.importPlaylist(source);
      await worker.importEpg(source);
      // A channel without tvg-id named like the guide's "Channel 2".
      final ch = (await store.channels(source.id))[1];
      await store.replaceChannels(source.id, [
        IptvChannel(sourceId: source.id, id: 'lone', name: 'UK: CHANNEL 2 (1080p)', sortIndex: 0, url: 'http://x/1'),
        IptvChannel(sourceId: source.id, id: 'manual', name: 'Something', sortIndex: 1, url: 'http://x/2'),
      ], const []);
      await store.setChannelOverride(source.id, 'manual', hidden: false, epgId: 'ch5.fake');
      await worker.rematch(source);
      final lone = await store.channel(source.id, 'lone');
      expect(lone!.epgChannelId, ch.tvgId);
      expect((await store.channel(source.id, 'manual'))!.epgChannelId, 'ch5.fake');
      worker.close();
    });
  });

  group('M3U movie files', () {
    void addMovies() => server.extraM3u =
        '#EXTINF:-1 tvg-logo="${server.base}/p/a.jpg" group-title="Films",Arrival Day (2016)\n'
        '#EXTVLCOPT:http-referrer=https://ref.example/\n'
        '${server.base}/files/arrival.mkv\n'
        '#EXTINF:-1 group-title="VOD",Night Train\n'
        '${server.base}/files/night\n'
        '#EXTINF:-1 group-title="VOD",Live in VOD group\n'
        '${server.base}/live/x/y/9.ts\n';

    test('off by default: movie files stay channels', () async {
      addMovies();
      final source = m3uSource(server.base);
      final worker = IptvSyncWorker(store: store, now: () => server.now);
      expect(await worker.importPlaylist(source), 9);
      final client = IptvClient(source, store: store, now: () => server.now);
      expect(await client.fetchLibraries(), isEmpty);
    });

    test('opt-in: a Movies library that plays the entry with its headers', () async {
      addMovies();
      final source = IptvConnection.fromConfigJson(
        id: 'iptv-m3u-movies',
        json: {...m3uSource(server.base).toConfigJson(), 'm3uMoviesAsVod': true},
        createdAt: DateTime(2026),
      );
      expect(source.m3uMoviesAsVod, isTrue);
      expect(m3uSource(server.base).toConfigJson().containsKey('m3uMoviesAsVod'), isFalse);
      final worker = IptvSyncWorker(store: store, now: () => server.now);
      expect(await worker.importPlaylist(source), 7, reason: 'the .ts entry in a VOD group stays a channel');
      final client = IptvClient(source, store: store, now: () => server.now);
      final libraries = await client.fetchLibraries();
      expect(libraries.map((l) => l.kind), [MediaKind.movie]);
      final page = await client.fetchLibraryPagedContent(libraries.single.id, query: const LibraryQuery());
      expect(page.items.map((i) => i.title).toSet(), {'Arrival Day (2016)', 'Night Train'});
      final arrival = page.items.firstWhere((i) => i.title!.startsWith('Arrival'));
      expect(arrival.year, 2016);
      final movie = (await client.fetchItem(arrival.id))!;
      final init = await client.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: movie, selectedMediaIndex: 0),
      );
      expect(init.videoUrl, '${server.base}/files/arrival.mkv');
      expect(client.streamHeaders['Referer'], 'https://ref.example/');

      // Turning it off again clears the library on the next refresh.
      final off = source.copyWith(m3uMoviesAsVod: false);
      expect(await worker.importPlaylist(off), 9);
      expect(await store.vodCount(off.id, IptvGroupKind.movie), 0);
    });

    test('what counts as a movie file', () {
      M3uEntry entry(String url, {String? group}) =>
          M3uEntry(url: url, title: 'x', attributes: {'group-title': ?group});
      expect(IptvSyncWorker.looksLikeMovie(entry('http://h.example/a/b.MP4?token=1')), isTrue);
      expect(IptvSyncWorker.looksLikeMovie(entry('http://h.example/a/b.ts', group: 'Movies')), isFalse);
      expect(IptvSyncWorker.looksLikeMovie(entry('http://h.example/a/b', group: 'Series EN')), isTrue);
      expect(IptvSyncWorker.looksLikeMovie(entry('http://h.example/a/b', group: 'Moviestar TV')), isFalse);
      expect(IptvSyncWorker.looksLikeMovie(entry('http://h.example/a/b', group: 'News')), isFalse);
    });
  });

  group('IPTV client: live', () {
    Future<IptvClient> m3uClient({int shift = 0}) async {
      final source = m3uSource(server.base, shift: shift);
      final worker = IptvSyncWorker(store: store, now: () => server.now);
      await worker.importPlaylist(source);
      await worker.importEpg(source);
      worker.close();
      return IptvClient(source, store: store, now: () => server.now);
    }

    test('numbers channels by tvg-chno, groups them, hides hidden channels and groups', () async {
      final client = await m3uClient();
      expect(client.capabilities, ServerCapabilities.iptv);
      var channels = await client.liveTv.fetchChannels();
      expect(channels.map((c) => c.number), [
        '101',
        '103',
        '105',
        '102',
        '104',
        '106',
      ], reason: 'News first, then Sport');
      expect(channels.first.group, 'News');
      await store.setGroupHidden(client.connection.id, IptvGroupKind.live, 'Sport', true);
      await store.setChannelOverride(client.connection.id, channels.first.key, hidden: true);
      IptvDataRevision.bump(client.connection.id);
      channels = await client.liveTv.fetchChannels();
      expect(channels.map((c) => c.number), ['103', '105']);
      expect(await (client.liveTv as LiveTvChannelGroups).fetchGroups(), ['News']);
    });

    test('automatic numbering and the parental lock', () async {
      final base = await m3uClient();
      final source = base.connection.copyWith(numbering: IptvChannelNumbering.automatic, lockedGroups: ['Sport']);
      final client = IptvClient(source, store: store, now: () => server.now);
      var channels = await client.liveTv.fetchChannels();
      expect(channels.map((c) => c.number), ['1', '2', '3']);
      IptvParentalGate.unlock(source.id);
      channels = await client.liveTv.fetchChannels();
      expect(channels, hasLength(6));
    });

    test('numberChannels keeps explicit numbers and fills the rest after the highest', () {
      IptvChannel ch(String id, {String? number, String? playlist}) =>
          IptvChannel(sourceId: 's', id: id, name: id, sortIndex: 0, number: number, playlistNumber: playlist);
      final numbered = IptvClientLive.numberChannels([
        ch('a', playlist: '5'),
        ch('b'),
        ch('c', number: '2'),
        ch('d', playlist: '5'),
      ], IptvChannelNumbering.playlist);
      expect(numbered.map((s) => s.number), ['5', '6', '2', '7'], reason: 'a duplicate number is renumbered');
    });

    test('the guide is shifted by the source and channel shifts', () async {
      final client = await m3uClient(shift: 60);
      final from = server.now.subtract(const Duration(hours: 1));
      final programmes = await client.liveTv.fetchSchedule(from: from, to: server.now.add(const Duration(hours: 2)));
      expect(programmes, isNotEmpty);
      final channelOne = programmes.where((p) => p.channelIdentifier != null).first;
      final hourStart = DateTime.utc(server.now.year, server.now.month, server.now.day, server.now.hour);
      // Raw programmes start on the hour; a 60-minute shift keeps them on the hour, one later.
      expect((channelOne.beginsAt! - hourStart.millisecondsSinceEpoch ~/ 1000) % 3600, 0);
      final raw = await m3uClient();
      final rawProgrammes = await raw.liveTv.fetchSchedule(from: from, to: server.now.add(const Duration(hours: 2)));
      final rawTitle = rawProgrammes.firstWhere((p) => p.beginsAt == channelOne.beginsAt).title;
      expect(rawTitle, isNot(channelOne.title), reason: 'the same slot shows the previous hour\'s programme');
    });

    test('now and next come from the stored guide', () async {
      final client = await m3uClient();
      final channels = await client.liveTv.fetchChannels();
      final nn = await client.nowNext(channels.first.key);
      expect(nn.now?.title, startsWith('Show 6 on'));
      expect(nn.next?.title, startsWith('Show 7 on'));
    });

    test('a tuned channel plays its address with its headers and offers its catch-up window', () async {
      final client = await m3uClient();
      final channel = (await client.liveTv.fetchChannels()).first;
      expect(channel.catchupDays, 3);
      final session = (await client.liveTv.startPlayback(channel.key))!;
      expect(await session.streamUrlAt(), '${server.base}/stream/1.ts');
      expect((session as LiveTvStreamHeaders).streamHeaders['User-Agent'], 'FakePlayer/1.0');
      expect(session.canTimeShift, isTrue);
      final window = session.captureBuffer!;
      expect(window.seekableDurationSeconds, closeTo(3 * 86400, 2));
      expect(session.program.beginsAt, isNotNull);
      // An hour back: the shift archive address.
      final offset = window.seekEndSeconds.round() - 3600;
      final url = await session.streamUrlAt(offsetSeconds: offset);
      expect(url, startsWith('${server.base}/stream/1.ts?utc='));
      // The live edge plays live again.
      expect(await session.streamUrlAt(offsetSeconds: window.seekEndSeconds.round()), '${server.base}/stream/1.ts');
      expect(await store.recentChannelIds(client.connection.id), [channel.key]);
    });

    test('Home gets a favourite-channels row with what is on, and search finds channels and programmes', () async {
      final client = await m3uClient();
      final live = client.liveTv;
      final channels = await live.fetchChannels();
      final source = await live.buildFavoriteChannelSource();
      expect(await client.fetchGlobalHubs(), isEmpty, reason: 'no favourites, no VOD: no row');
      await live.setFavoriteChannels([FavoriteChannel.fromLiveTvChannel(channels.first, source)]);
      final hubs = await client.fetchGlobalHubs();
      expect(hubs.single.title, 'Favourite Channels on Test playlist');
      final card = hubs.single.items.single;
      expect(card.kind, MediaKind.clip);
      expect(card.title, 'Channel 1 HD');
      expect(card.parentTitle, startsWith('Now: Show 6 on'));
      expect((await client.fetchMoreHubItemsPage(hubs.single.id)).items, hasLength(1));

      final byName = await client.searchItems('Channel 3');
      expect(byName.first.title, 'Channel 3 HD');
      final byProgramme = await client.searchItems('Show 9 on 2');
      expect(byProgramme.where((i) => i.title == 'Show 9 on 2'), isNotEmpty);
      expect(byProgramme.first.raw?['start'], isA<int>());
    });

    test('favourites are kept per source', () async {
      final client = await m3uClient();
      final live = client.liveTv;
      final channels = await live.fetchChannels();
      final source = await live.buildFavoriteChannelSource();
      await live.setFavoriteChannels([
        FavoriteChannel.fromLiveTvChannel(channels[2], source),
        FavoriteChannel.fromLiveTvChannel(channels[0], source),
        FavoriteChannel(source: 'server://other/plex', id: 'x'),
      ]);
      final favourites = await live.fetchFavoriteChannels();
      expect(favourites.map((f) => f.id), [channels[2].key, channels[0].key]);
      expect(live.favoritePersistenceMode, FavoriteChannelPersistenceMode.serverSlice);
    });
  });

  group('Xtream source', () {
    test('a refused login fails the refresh as an auth failure', () async {
      server.refuseLogin = true;
      final worker = IptvSyncWorker(store: store);
      await expectLater(
        worker.importPlaylist(xtreamSource(server.base)),
        throwsA(isA<IptvSyncException>().having((e) => e.authFailed, 'authFailed', isTrue)),
      );
      worker.close();
    });

    test('imports the account, live channels with archive, movies and series', () async {
      final source = xtreamSource(server.base);
      final worker = IptvSyncWorker(store: store, now: () => server.now);
      expect(await worker.importPlaylist(source), 6);
      expect(await store.vodCount(source.id, IptvGroupKind.movie), 4);
      expect(await store.vodCount(source.id, IptvGroupKind.series), 1);
      final ch1 = await store.channel(source.id, 'x1001');
      expect(ch1!.catchupMode, IptvCatchupMode.xtream);
      expect(ch1.catchupDays, 5);
      expect(ch1.url, isEmpty, reason: 'the login-bearing address is never stored');
      expect(await worker.guideUrls(source), [startsWith('${server.base}/xmltv.php?username=demo')]);
      expect(await worker.importEpg(source), 144);
      worker.close();

      final client = IptvClient(source, store: store, now: () => server.now);
      final account = await client.storedAccount();
      expect(account!.status, 'Active');
      expect(account.maxConnections, 2);
      expect(account.serverOffset, Duration.zero);
      expect(await client.checkHealth(), HealthStatus.online);
    });

    Future<IptvClient> xtreamClient() async {
      final source = xtreamSource(server.base);
      final worker = IptvSyncWorker(store: store, now: () => server.now);
      await worker.importPlaylist(source);
      worker.close();
      return IptvClient(source, store: store, now: () => server.now);
    }

    test('live addresses, timeshift catch-up and the short guide fallback', () async {
      final client = await xtreamClient();
      final session = (await client.liveTv.startPlayback('x1001'))!;
      expect(await session.streamUrlAt(), '${server.base}/live/demo/secret/1001.ts');
      final window = session.captureBuffer!;
      final url = await session.streamUrlAt(offsetSeconds: window.seekEndSeconds.round() - 1800);
      expect(url, matches(RegExp(r'/timeshift/demo/secret/30/\d{4}-\d{2}-\d{2}:\d{2}-\d{2}/1001\.ts$')));
      // No guide imported: now/next from get_short_epg.
      final nn = await client.nowNext('x1001');
      expect(nn.now?.title, 'Short Now');
      expect(nn.next?.title, 'Short Next');
      final noArchive = (await client.liveTv.startPlayback('x1002'))!;
      expect(noArchive.captureBuffer, isNull);
      expect(await noArchive.streamUrlAt(offsetSeconds: 10), isNull);
    });

    test('the timeshift.php catch-up route', () async {
      final base = await xtreamClient();
      final client = IptvClient(
        base.connection.copyWith(xtreamTimeshiftPhp: true),
        store: store,
        now: () => server.now,
      );
      final session = (await client.liveTv.startPlayback('x1001'))!;
      final url = await session.streamUrlAt(offsetSeconds: session.captureBuffer!.seekEndSeconds.round() - 900);
      expect(url, contains('/streaming/timeshift.php?username=demo&password=secret&stream=1001&start='));
      expect(url, endsWith('&duration=15'));
    });

    test('the HLS output format', () async {
      final base = await xtreamClient();
      final client = IptvClient(base.connection.copyWith(xtreamOutput: 'm3u8'), store: store);
      final session = (await client.liveTv.startPlayback('x1003'))!;
      expect(await session.streamUrlAt(), '${server.base}/live/demo/secret/1003.m3u8');
    });

    test('a refused login reads as an auth error', () async {
      final client = await xtreamClient();
      server.refuseLogin = true;
      expect(await client.checkHealth(), HealthStatus.authError);
    });

    test('movie and series libraries, categories as genres, sorting and search', () async {
      final client = await xtreamClient();
      final libraries = await client.fetchLibraries();
      expect(libraries.map((l) => l.kind), [MediaKind.movie, MediaKind.show]);
      final all = await client.fetchLibraryPagedContent('movies', query: const LibraryQuery());
      expect(all.totalCount, 4);
      final genres = await client.fetchLibraryGenres('movies', libraryKind: MediaKind.movie);
      expect(genres.map((g) => g.title), ['Action', 'Drama']);
      final drama = await client.fetchLibraryPagedContent(
        'movies',
        query: const LibraryQuery(
          filters: [
            LibraryFilter(field: MediaFilterField.genre, values: ['11']),
          ],
          sort: LibrarySort(field: 'added', direction: LibrarySortDirection.descending),
        ),
      );
      expect(drama.items.map((i) => i.title), ['Movie 4 (2014)', 'Movie 3 (2013)']);
      expect(drama.items.first.year, 2014);
      final found = await client.searchItems('series');
      expect(found.single.kind, MediaKind.show);
    });

    test('movie details, trailer and playback address', () async {
      final client = await xtreamClient();
      final movie = (await client.fetchItem('m2001'))!;
      expect(movie, isA<IptvMediaItem>());
      expect(movie.summary, 'A made-up plot.');
      expect(movie.durationMs, 5400 * 1000);
      expect(movie.roles!.map((r) => r.tag), ['Actor One', 'Actor Two']);
      expect(movie.genres, ['Action', 'Drama']);
      expect(movie.artPath, '${server.base}/backdrop/m.jpg');
      final trailers = await client.fetchRemoteTrailers('m2001');
      expect(trailers.single.key, 'dQw4w9WgXcQ');
      final init = await client.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: movie, selectedMediaIndex: 0),
      );
      expect(init.videoUrl, '${server.base}/movie/demo/secret/2001.mkv');
    });

    test('series, seasons and episodes; local progress, Continue Watching and watched state', () async {
      final client = await xtreamClient();
      final series = (await client.fetchItem('s3001'))!;
      expect(series.kind, MediaKind.show);
      expect(series.leafCount, 3);
      final seasons = await client.fetchChildren('s3001');
      expect(seasons.map((s) => s.index), [1, 2]);
      final episodes = await client.fetchChildren(seasons.first.id);
      expect(episodes.map((e) => e.title), ['Pilot', 'Second']);
      final pilot = episodes.first;
      final init = await client.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: pilot, selectedMediaIndex: 0),
      );
      expect(init.videoUrl, '${server.base}/series/demo/secret/4001.mp4');

      await client.reportPlaybackProgress(
        itemId: pilot.id,
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 25),
      );
      final continuing = await client.fetchContinueWatching();
      expect(continuing.single.id, pilot.id);
      expect(continuing.single.viewOffsetMs, 5 * 60 * 1000);
      expect(continuing.single.grandparentTitle, 'Series One');
      final onDeck = await client.fetchItemWithOnDeck('s3001');
      expect(onDeck.onDeckEpisode?.id, pilot.id);

      // Past 90%: watched, out of Continue Watching, next episode on deck.
      await client.reportPlaybackStopped(
        itemId: pilot.id,
        position: const Duration(minutes: 24),
        duration: const Duration(minutes: 25),
      );
      expect(await client.fetchContinueWatching(), isEmpty);
      expect((await client.fetchItemWithOnDeck('s3001')).onDeckEpisode?.title, 'Second');

      await client.markWatched(seasons.first);
      final seasonsAfter = await client.fetchChildren('s3001');
      expect(seasonsAfter.first.viewCount, 1);
      await client.markUnwatched(series);
      expect((await client.fetchItem('s3001'))!.viewedLeafCount, 0);
    });

    test('large lists are decoded while they download, up to a cap', () async {
      XtreamApi api({int? cap}) => XtreamApi(
        XtreamCredentials(baseUrl: server.base, username: 'demo', password: 'secret'),
        maxListBytes: cap ?? XtreamApi.defaultMaxListBytes,
      );
      final normal = api();
      expect(await normal.vodStreams(), hasLength(4));
      normal.close();
      final capped = api(cap: 64);
      await expectLater(
        capped.vodStreams(),
        throwsA(isA<XtreamRequestException>().having((e) => e.message, 'message', 'too large')),
      );
      capped.close();
    });

    test('live only leaves the libraries out', () async {
      final source = xtreamSource(server.base, includeVod: false);
      final worker = IptvSyncWorker(store: store);
      await worker.importPlaylist(source);
      worker.close();
      expect(await store.vodCount(source.id, IptvGroupKind.movie), 0);
      final client = IptvClient(source, store: store);
      expect(await client.fetchLibraries(), isEmpty);
      expect(await client.fetchGlobalHubs(), isEmpty);
    });

    test('credentials from an M3U get.php address', () {
      final creds = XtreamCredentials.fromM3uUrl('http://x.example:8080/get.php?username=u&password=p&type=m3u_plus');
      expect(creds!.baseUrl, 'http://x.example:8080');
      expect(creds.username, 'u');
      expect(XtreamCredentials.normaliseBaseUrl('x.example:25461/player_api.php'), 'http://x.example:25461');
      expect(XtreamCredentials.fromM3uUrl('http://x.example/list.m3u'), isNull);
    });
  });
}
