import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_item_labels.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_mappers.dart';

/// Silo Android #1035: a series the server marks `episode_labels: air_date`
/// (Sportarr's `S<year>E<n>` leagues) labels its episodes by air date wherever
/// the season and episode code would go.
final _ctx = SiloMappingContext(serverId: 'srv-1', serverName: 'Home Silo', resolveUrl: (url) => url);

Map<String, dynamic> _game({String? labels = 'air_date', Object? airDate = '2026-11-20', String type = 'episode'}) => {
  'content_id': 'episode:nba-2026-296',
  'type': type,
  'title': 'Lakers at Celtics',
  'series_id': 'series:nba',
  'series_title': 'NBA',
  'season_number': 2026,
  'episode_number': 296,
  'episode_labels': ?labels,
  'air_date': ?airDate,
};

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
  });

  group('mapping', () {
    test('a dated episode of a date-labeled series is labeled by its air date', () {
      final item = SiloMappers.item(_game(), _ctx)!;
      expect(item.episodeAirDateLabel, '2026-11-20');
      expect(episodeAirDateText(item), 'Nov 20, 2026');
      expect(formatEpisodeLabel(item), 'Nov 20, 2026');
      expect(formatQueueItemSubtitle(item), 'NBA · Nov 20, 2026');
      // The numbers stay for sorting and next-up.
      expect(item.parentIndex, 2026);
      expect(item.index, 296);
    });

    test('a numbered series keeps its code', () {
      final item = SiloMappers.item(_game(labels: null), _ctx)!;
      expect(item.episodeAirDateLabel, isNull);
      expect(formatEpisodeLabel(item), 'S2026 E296');
      expect(formatQueueItemSubtitle(item), 'NBA · S2026E296');
    });

    test('an undated or impossible date keeps the code', () {
      expect(SiloMappers.item(_game(airDate: null), _ctx)!.episodeAirDateLabel, isNull);
      expect(SiloMappers.item(_game(airDate: '2026-02-30'), _ctx)!.episodeAirDateLabel, isNull);
      expect(SiloMappers.item(_game(airDate: 'soon'), _ctx)!.episodeAirDateLabel, isNull);
      // A timestamp's date part is the calendar date.
      expect(SiloMappers.item(_game(airDate: '2026-11-20T01:00:00Z'), _ctx)!.episodeAirDateLabel, '2026-11-20');
    });

    test('only episodes are labeled; a series card keeps its own fields', () {
      final series = SiloMappers.item({..._game(type: 'series'), 'content_id': 'series:nba'}, _ctx)!;
      expect(series.kind, MediaKind.show);
      expect(series.episodeAirDateLabel, isNull);
    });

    test('the label survives the offline item cache round trip', () {
      final item = SiloMappers.item(_game(), _ctx)!;
      final restored = MediaItem.fromJson(jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>);
      expect(restored.episodeAirDateLabel, '2026-11-20');
    });

    test('Plex and Jellyfin episodes always show numbers', () {
      final plex = MediaItem.plex(
        id: '1',
        kind: MediaKind.episode,
        parentIndex: 1,
        index: 2,
        originallyAvailableAt: '2026-11-20',
      );
      final jellyfin = MediaItem.jellyfin(
        id: '2',
        kind: MediaKind.episode,
        parentIndex: 1,
        index: 2,
        originallyAvailableAt: '2026-11-20',
      );
      for (final item in [plex, jellyfin]) {
        expect(item.episodeAirDateLabel, isNull);
        expect(identical(item.withEpisodeAirDateLabel('2026-11-20'), item), isTrue);
        expect(formatEpisodeLabel(item), 'S1 E2');
      }
    });

    test('withEpisodeAirDateLabel sets and clears a Silo episode label', () {
      final numbered = SiloMappers.item(_game(labels: null), _ctx)!;
      final dated = numbered.withEpisodeAirDateLabel('2026-11-20');
      expect(dated.episodeAirDateLabel, '2026-11-20');
      expect(dated.withEpisodeAirDateLabel(null).episodeAirDateLabel, isNull);
      expect(identical(dated.withEpisodeAirDateLabel('2026-11-20'), dated), isTrue);
    });
  });

  group('client', () {
    late List<http.Request> requests;

    setUp(() {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      SiloApiCache.initialize(db);
      requests = [];
    });

    SiloClient client(Future<http.Response> Function(http.Request request) handler) => SiloClient.forTesting(
      SiloConnection(
        id: 'srv-1/1/p-owner',
        baseUrl: 'https://silo.example.com',
        serverName: 'Home Silo',
        serverId: 'srv-1',
        userId: '1',
        userName: 'laura',
        accessToken: 'acc-1',
        refreshToken: 'ref-1',
        deviceId: 'dev-1',
        profileId: 'p-owner',
        profileName: 'Laura',
        createdAt: DateTime(2026),
      ),
      headers: _headers,
      httpClient: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
    );

    Map<String, dynamic> episodeRow(int number, String? airDate) => {
      'content_id': 'episode:nba-2026-$number',
      'title': 'Game $number',
      'episode_number': number,
      'air_date': ?airDate,
    };

    Future<http.Response> Function(http.Request) seriesServer({Object? labels = 'air_date', int detailStatus = 200}) =>
        (request) async {
          final path = Uri.decodeComponent(request.url.path);
          if (path.endsWith('/catalog/series/series:nba/seasons/2026/episodes')) {
            return _json({
              'items': [episodeRow(296, '2026-11-20'), episodeRow(297, null)],
            });
          }
          if (path.endsWith('/catalog/items/series:nba')) {
            if (detailStatus != 200) return _json({}, detailStatus);
            return _json({'content_id': 'series:nba', 'type': 'series', 'title': 'NBA', 'episode_labels': ?labels});
          }
          return _json({}, 404);
        };

    test("a season's episodes take the series' labels from its detail", () async {
      final c = client(seriesServer());
      final episodes = await c.fetchChildren(SiloMappers.syntheticSeasonId('series:nba', 2026));
      expect(episodes.map((e) => e.episodeAirDateLabel), ['2026-11-20', null]);
      // The undated game keeps its numbers.
      expect(formatEpisodeLabel(episodes.last), 'S2026 E297');
    });

    test('a numbered series and an unreadable detail both keep numbers', () async {
      for (final server in [seriesServer(labels: null), seriesServer(detailStatus: 500)]) {
        final c = client(server);
        final episodes = await c.fetchChildren(SiloMappers.syntheticSeasonId('series:nba', 2026));
        expect(episodes, hasLength(2));
        expect(episodes.map((e) => e.episodeAirDateLabel), [null, null]);
      }
    });

    test('the series detail the page just read is reused, not fetched again', () async {
      final c = client(seriesServer());
      await c.fetchItem('series:nba');
      requests.clear();
      await c.fetchChildren(SiloMappers.syntheticSeasonId('series:nba', 2026));
      expect(requests.map((r) => Uri.decodeComponent(r.url.path)), [endsWith('/seasons/2026/episodes')]);
    });

    group('playback', () {
      Future<PlaybackInitializationResult> start(MediaItem metadata, Map<String, dynamic> watch) {
        final c = client((request) async {
          final path = Uri.decodeComponent(request.url.path);
          if (path.contains('/watch/')) {
            return _json({
              ...watch,
              'versions': [
                {'file_id': '42', 'resolution': '1080p', 'audio_tracks': []},
              ],
            });
          }
          if (path.endsWith('/playback/capabilities')) {
            return _json({
              'state': 'available',
              'allowed': true,
              'installation_id': 'inst-1',
              'protocol_versions': [3],
              'features': ['sequenced_progress_v1'],
            });
          }
          if (path.endsWith('/playback/start')) {
            return _json({
              'protocol_version': 3,
              'outcome': 'playable',
              'session_id': 'sess-1',
              'playback_plan': {
                'delivery': 'original_http',
                'stream': {'url': '/api/v2/stream/sess-1?st=sig', 'protocol': 'http_progressive'},
              },
            }, 201);
          }
          return _json({}, 404);
        });
        return c.getPlaybackInitialization(PlaybackInitializationOptions(metadata: metadata, selectedMediaIndex: 0));
      }

      test('/watch decides the playing episode label', () async {
        // A card that still said numbers is labeled by date once /watch says so.
        final numberedCard = SiloMappers.item(_game(labels: null), _ctx)!;
        final dated = await start(numberedCard, {
          'type': 'episode',
          'episode_labels': 'air_date',
          'air_date': '2026-11-20',
        });
        expect(dated.episodeLabel, isNotNull);
        expect(dated.episodeLabel!.airDate, '2026-11-20');

        // And a /watch that sends numbers overrides a dated card.
        final datedCard = SiloMappers.item(_game(), _ctx)!;
        final numbered = await start(datedCard, {'type': 'episode'});
        expect(numbered.episodeLabel, isNotNull);
        expect(numbered.episodeLabel!.airDate, isNull);
        expect(datedCard.withEpisodeAirDateLabel(numbered.episodeLabel!.airDate).episodeAirDateLabel, isNull);
      });

      test('a movie has no episode label to give', () async {
        final movie = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie, serverId: 'srv-1');
        final result = await start(movie, {'type': 'movie'});
        expect(result.episodeLabel, isNull);
      });
    });
  });
}
