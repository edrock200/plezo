import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/tofa/tofa_api_cache.dart';
import 'package:plezy/services/tofa/tofa_client.dart';
import 'package:plezy/services/tofa/tofa_mappers.dart';

TofaConnection _connection({String baseUrl = 'https://tofa.example.com/relay', bool apiKey = false}) => TofaConnection(
  id: TofaConnection.compoundId(serverId: 'srv-1', userId: 'u-1', profileId: 'p-1'),
  baseUrl: baseUrl,
  serverName: 'Home tofa',
  serverId: 'srv-1',
  userId: 'u-1',
  userName: 'laura',
  accessToken: apiKey ? 'tofa_key' : 'acc-1',
  refreshToken: apiKey ? '' : 'ref-1',
  isApiKey: apiKey,
  deviceId: 'dev-1',
  profileId: 'p-1',
  profileName: 'Laura',
  createdAt: DateTime(2026),
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _file(String id, {int durationMs = 3600000}) => {
  'id': id,
  'available': true,
  'container': 'mkv',
  'duration_ms': durationMs,
  'video_codec': 'hevc',
  'resolution': '1080p',
};

Map<String, dynamic> _show() => {
  'id': 'show-1',
  'media_type': 'tv',
  'title': 'The Show',
  'library_id': 'lib-tv',
  'poster_path': 'images/posters/show.jpg',
  'files': <Object>[],
  'provider_ids': [
    {'media_id': 'show-1', 'provider': 'tvdb', 'provider_id': '280619'},
    {'media_id': 'show-1', 'provider': 'tmdb', 'provider_id': '63639'},
  ],
  'seasons': [
    {
      'id': 'season-0',
      'media_id': 'show-1',
      'season_number': 0,
      'episodes': [
        {'id': 'ep-0-1', 'season_id': 'season-0', 'episode_number': 1, 'title': 'Special', 'files': [_file('f-01')]},
      ],
    },
    {
      'id': 'season-1',
      'media_id': 'show-1',
      'season_number': 1,
      'episodes': [
        {'id': 'ep-1-2', 'season_id': 'season-1', 'episode_number': 2, 'title': 'Two', 'files': [_file('f-12')]},
        {'id': 'ep-1-1', 'season_id': 'season-1', 'episode_number': 1, 'title': 'One', 'files': [_file('f-11')]},
      ],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;

  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    TofaApiCache.initialize(db);
    requests = [];
  });

  TofaClient client(Future<http.Response> Function(http.Request request) handler, {TofaConnection? connection}) =>
      TofaClient.forTesting(
        connection ?? _connection(),
        httpClient: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
      );

  test('requests keep the relay path and carry bearer, profile and client headers', () async {
    final c = client((_) async => _json(<Object>[]));
    await c.fetchLibraries();
    final request = requests.firstWhere((r) => r.url.path.endsWith('/libraries'));
    expect(request.url.toString(), 'https://tofa.example.com/relay/api/v1/libraries');
    expect(request.headers['Authorization'], 'Bearer acc-1');
    expect(request.headers['X-Profile-Id'], 'p-1');
    expect(request.headers['X-Tofa-Device-Id'], 'dev-1');
    expect(request.headers['X-Tofa-Client'], 'Plezilo');
  });

  test('season and episode ids carry their show so they resolve on their own', () {
    final season = TofaIds.season('show-1', 'season-1');
    final episode = TofaIds.episode('show-1', 'ep-1-1');
    expect(TofaIds.parse(season), (mediaId: 'show-1', seasonId: 'season-1', episodeId: null));
    expect(TofaIds.parse(episode), (mediaId: 'show-1', seasonId: null, episodeId: 'ep-1-1'));
    expect(TofaIds.parse('movie-1'), (mediaId: 'movie-1', seasonId: null, episodeId: null));
  });

  test('a show lists numbered seasons first, episodes in order, with their file and progress', () async {
    final c = client((request) async {
      if (request.url.path.endsWith('/media/show-1')) return _json(_show());
      if (request.url.path.endsWith('/progress/batch')) {
        return _json({
          'items': [
            {'media_file_id': 'f-11', 'position_ms': 0, 'completed': true},
            {'media_file_id': 'f-12', 'position_ms': 120000, 'completed': false},
          ],
        });
      }
      return _json(<String, Object>{});
    });
    final seasons = await c.fetchChildren('show-1');
    expect(seasons.map((s) => s.index), [1, 0]);
    final episodes = await c.fetchChildren(seasons.first.id);
    expect(episodes.map((e) => e.title), ['One', 'Two']);
    expect(episodes.first.raw?[TofaRaw.fileId], 'f-11');
    expect(episodes.first.isWatched, isTrue);
    expect(episodes.last.viewOffsetMs, 120000);
    expect(episodes.first.grandparentId, 'show-1');
    expect(episodes.first.backend, MediaBackend.tofa);

    final queue = await c.fetchClientSideEpisodeQueue('show-1');
    expect(queue!.map((e) => e.title), ['One', 'Two'], reason: 'specials stay out of the play queue');
  });

  test('images go under /cache with the image token; the public CDN gets no token', () async {
    final c = client((request) async {
      if (request.url.path.endsWith('/auth/image-token')) return _json({'token': 'img-1', 'expires_in': 3600});
      return _json(<Object>[]);
    });
    await c.fetchLibraries();
    await Future<void>.delayed(Duration.zero);
    expect(
      c.thumbnailUrl('images/posters/a.jpg', width: 300),
      'https://tofa.example.com/relay/cache/images/posters/a.jpg?st=img-1&w=300',
    );
    expect(c.thumbnailUrl('/cache/x.jpg'), 'https://tofa.example.com/relay/cache/x.jpg?st=img-1');
    expect(c.thumbnailUrl('https://cdn.tofa.tv/p.jpg'), 'https://cdn.tofa.tv/p.jpg');
    expect(c.thumbnailUrl('https://tofa.example.com/art/1.jpg'), 'https://tofa.example.com/art/1.jpg?st=img-1');
    expect(c.thumbnailUrl(null), '');
  });

  test('library pages map offset paging onto tofa pages and sort fields', () async {
    final c = client((request) async {
      if (request.url.path.endsWith('/api/v1/media')) {
        return _json({
          'items': [
            {'id': 'm1', 'media_type': 'movie', 'title': 'A', 'release_date': '1999-03-31', 'runtime_minutes': 136},
          ],
          'page': 3,
          'per_page': 25,
          'total': 51,
          'total_pages': 3,
        });
      }
      return _json(<String, Object>{});
    });
    final page = await c.fetchLibraryPagedContent(
      'lib-1',
      query: const LibraryQuery(
        offset: 50,
        limit: 25,
        sort: LibrarySort(field: 'added_at', direction: LibrarySortDirection.descending),
      ),
    );
    final q = requests.firstWhere((r) => r.url.path.endsWith('/api/v1/media')).url.queryParameters;
    expect(q['page'], '3');
    expect(q['per_page'], '25');
    expect(q['sort'], 'added_at');
    expect(q['order'], 'desc');
    expect(q['library_id'], 'lib-1');
    expect(page.totalCount, 51);
    expect(page.items.single.year, 1999);
    expect(page.items.single.durationMs, 136 * 60000);
  });

  test('playback reports positions in ticks on the session, milliseconds outside one', () async {
    final c = client((request) async {
      if (request.url.path.endsWith('/stream/f-1/info')) {
        return _json({
          'play_method': 'DirectPlay',
          'stream_url': '/api/v1/stream/f-1/direct?st=play',
          'session_id': 's-1',
          'session_token': 'tok-1',
          'start_position_ticks': 0,
          'audio_tracks': [
            {'index': 1, 'codec': 'eac3', 'language': 'eng', 'channels': 6},
          ],
          'subtitle_tracks': <Object>[],
        });
      }
      if (request.url.path.endsWith('/media/m-1')) {
        return _json({'id': 'm-1', 'media_type': 'movie', 'title': 'M', 'files': [_file('f-1')], 'provider_ids': []});
      }
      return _json(<String, Object>{});
    });
    final movie = MediaItem.tofa(id: 'm-1', kind: MediaKind.movie, raw: {TofaRaw.fileId: 'f-1'});
    final init = await c.getPlaybackInitialization(
      PlaybackInitializationOptions(metadata: movie, selectedMediaIndex: 0, startPosition: const Duration(seconds: 90)),
    );
    expect(init.videoUrl, 'https://tofa.example.com/relay/api/v1/stream/f-1/direct?st=play');
    expect(init.playSessionId, 's-1');
    expect(init.isTranscoding, isFalse);
    final info = requests.firstWhere((r) => r.url.path.endsWith('/info')).url.queryParameters;
    expect(info['resume_ticks'], '${90 * 1000 * 10000}');
    expect(info['quality_mode'], 'original');

    await c.reportPlaybackProgress(
      itemId: 'm-1',
      position: const Duration(seconds: 2),
      duration: const Duration(hours: 1),
      playSessionId: 's-1',
    );
    final heartbeat = requests.lastWhere((r) => r.url.path.endsWith('/stream/s/s-1/progress'));
    expect(heartbeat.url.queryParameters['st'], 'tok-1');
    expect(jsonDecode(heartbeat.body)['position_ticks'], 2000 * 10000);

    await c.reportPlaybackStopped(itemId: 'm-1', position: const Duration(seconds: 3), playSessionId: 's-1');
    expect(requests.any((r) => r.url.path.endsWith('/stream/s/s-1/stopped') && r.url.queryParameters['st'] == 'tok-1'), isTrue);

    // Offline replay: no session, so the file's own progress (milliseconds).
    await c.reportPlaybackStopped(itemId: 'm-1', position: const Duration(minutes: 55), duration: const Duration(hours: 1));
    final put = requests.lastWhere((r) => r.method == 'PUT' && r.url.path.endsWith('/media/f-1/progress'));
    expect(jsonDecode(put.body), {'position_ms': 55 * 60000, 'ended': true});
  });

  test('watched marks go to the file, the season or the show', () async {
    final c = client((_) async => _json({'watched': true}));
    await c.markWatched(MediaItem.tofa(id: 'm-1', kind: MediaKind.movie, raw: {TofaRaw.fileId: 'f-1'}));
    await c.markUnwatched(MediaItem.tofa(id: TofaIds.season('show-1', 'season-1'), kind: MediaKind.season));
    await c.markWatched(MediaItem.tofa(id: 'show-1', kind: MediaKind.show));
    expect(requests.map((r) => '${r.method} ${r.url.path}'), [
      'PUT /relay/api/v1/media/f-1/watched',
      'PUT /relay/api/v1/seasons/season-1/watched',
      'PUT /relay/api/v1/shows/show-1/watched',
    ]);
    expect(jsonDecode(requests[1].body), {'watched': false});
  });

  test('a refused refresh after a 401 reports authError; an API key 401 too', () async {
    final device = client((request) async {
      if (request.url.host == 'api.tofa.tv') return _json({'error': 'invalid_refresh_token'}, 401);
      return _json({'error': 'unauthorized'}, 401);
    });
    expect(await device.checkHealth(), HealthStatus.authError);

    final key = client((_) async => _json({'error': 'unauthorized'}, 401), connection: _connection(apiKey: true));
    expect(await key.checkHealth(), HealthStatus.authError);
  });

  test('a 401 refreshes the server token once, persists the new pair and retries', () async {
    TofaConnection? persisted;
    final c = client((request) async {
      if (request.url.host == 'api.tofa.tv') {
        expect(request.url.path, '/servers/srv-1/device-token/refresh');
        expect(jsonDecode(request.body), {'refresh_token': 'ref-1'});
        return _json({'access_token': 'acc-2', 'refresh_token': 'ref-2', 'expires_in': 2592000});
      }
      if (request.headers['Authorization'] == 'Bearer acc-1') return _json({'error': 'expired'}, 401);
      return _json({'id': 'u-1'});
    });
    c.onConnectionUpdated = (updated) async => persisted = updated;
    expect(await c.checkHealth(), HealthStatus.online);
    expect(persisted?.accessToken, 'acc-2');
    expect(persisted?.refreshToken, 'ref-2');
  });

  test('external ids read provider_ids by provider', () async {
    final c = client((request) async => _json(_show()));
    final ids = await c.fetchExternalIds('show-1');
    expect(ids.tvdb, 280619);
    expect(ids.tmdb, 63639);
  });

  test('connections round-trip through their stored config', () {
    final original = _connection().copyWith(fallbackUrls: ['http://192.168.1.50:33333'], profileToken: 'pt');
    final restored = TofaConnection.fromConfigJson(
      id: original.id,
      json: original.toConfigJson(),
      createdAt: original.createdAt,
    );
    expect(restored.toConfigJson(), original.toConfigJson());
    expect(restored.kind, MediaBackend.tofa);
    expect(MediaItem.fromJson(MediaItem.tofa(id: 'x', kind: MediaKind.movie).toJson()).backend, MediaBackend.tofa);
  });
}
