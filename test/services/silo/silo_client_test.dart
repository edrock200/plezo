import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/services/cached_playback_metadata_service.dart';
import 'package:plezy/services/download_manager_service.dart' show downloadExtensionFromUrl;
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_mappers.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection({String accessToken = 'acc-1', String refreshToken = 'ref-1'}) => SiloConnection(
  id: 'srv-1/1/p-owner',
  baseUrl: 'https://silo.example.com/base',
  serverName: 'Home Silo',
  serverId: 'srv-1',
  userId: '1',
  userName: 'laura',
  accessToken: accessToken,
  refreshToken: refreshToken,
  deviceId: 'dev-1',
  profileId: 'p-owner',
  profileName: 'Laura',
  createdAt: DateTime(2026),
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

http.Response _problem(int status, String code) => http.Response(
  jsonEncode({'type': 'https://siloserver.org/docs/api/v2/problems/$code', 'title': code, 'status': status}),
  status,
  headers: {'content-type': 'application/problem+json'},
);

Map<String, dynamic> _movie(int i) => {'content_id': 'movie:m$i', 'type': 'movie', 'title': 'Movie $i'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;

  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
    requests = [];
  });

  SiloClient client(Future<http.Response> Function(http.Request request) handler, {SiloConnection? connection}) =>
      SiloClient.forTesting(
        connection ?? _connection(),
        headers: _headers,
        httpClient: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
      );

  test('every request carries bearer, profile and device headers under the base path', () async {
    final c = client((_) async => _json({'items': []}));
    await c.fetchLibraries();
    final request = requests.single;
    expect(request.url.toString(), 'https://silo.example.com/base/api/v2/user/libraries');
    expect(request.headers['Authorization'], 'Bearer acc-1');
    expect(request.headers['X-Profile-Id'], 'p-owner');
    expect(request.headers['X-Silo-Device-Id'], 'dev-1');
    expect(request.headers['Accept'], 'application/json');
  });

  test('distant pages seek with the window cursor; adjacent pages reuse next_cursor', () async {
    final c = client((request) async {
      final q = request.url.queryParameters;
      final limit = int.parse(q['limit']!);
      final cursor = q['cursor'];
      final start = q['seek'] != null
          ? (cursor == 'win-$limit' ? int.parse(q['seek']!) : throw StateError('seek without window'))
          : cursor == null
          ? 0
          : int.parse(cursor.split(':').last);
      final end = (start + limit).clamp(0, 10);
      return _json({
        'items': [for (var i = start; i < end; i++) _movie(i)],
        'page': {'has_more': end < 10, 'next_cursor': 'n$limit:$end'},
        'total': 10,
        'window_cursor': 'win-$limit',
      });
    });

    final page = await c.fetchLibraryPagedContent('3', query: const LibraryQuery(offset: 4, limit: 2));
    expect(page.items.map((i) => i.id), ['movie:m4', 'movie:m5']);
    expect(page.totalCount, 10);
    expect(page.offset, 4);
    // The first page (same page size) yields the window cursor, then one seek.
    expect(requests.map((r) => r.url.queryParameters['cursor']), [null, 'win-2']);
    expect(requests.map((r) => r.url.queryParameters['seek']), [null, '4']);
    expect(requests.map((r) => r.url.queryParameters['limit']), ['2', '2']);
    expect(requests.first.url.queryParameters['library_id'], '3');

    requests.clear();
    await c.fetchLibraryPagedContent('3', query: const LibraryQuery(offset: 6, limit: 2));
    expect(requests.map((r) => r.url.queryParameters['cursor']), ['n2:6']);
    expect(requests.single.url.queryParameters.containsKey('seek'), isFalse);

    requests.clear();
    await c.fetchLibraryPagedContent('3', query: const LibraryQuery(offset: 2, limit: 2));
    expect(requests.map((r) => r.url.queryParameters['cursor']), ['n2:2']);

    // Another page size never reuses the first size's cursors.
    requests.clear();
    await c.fetchLibraryPagedContent('3', query: const LibraryQuery(offset: 6, limit: 3));
    expect(requests.map((r) => r.url.queryParameters['cursor']), [null, 'win-3']);
    expect(requests.map((r) => r.url.queryParameters['limit']), ['3', '3']);
  });

  test('an invalid_cursor restarts the listing once', () async {
    var stale = true;
    final c = client((request) async {
      final q = request.url.queryParameters;
      if (q['cursor'] == 'old' && stale) {
        stale = false;
        return _problem(400, 'invalid_cursor');
      }
      final start = int.tryParse(q['seek'] ?? '') ?? 0;
      return _json({
        'items': [_movie(start)],
        'page': {'has_more': true, 'next_cursor': 'n'},
        'window_cursor': requests.length < 2 ? 'old' : 'new',
      });
    });
    await c.fetchLibraryPagedContent('3', query: const LibraryQuery(offset: 0, limit: 1));
    requests.clear();
    final page = await c.fetchLibraryPagedContent('3', query: const LibraryQuery(offset: 5, limit: 1));
    expect(page.items.map((i) => i.id), ['movie:m5']);
    expect(requests.map((r) => r.url.queryParameters['cursor']), ['old', null, 'new']);
  });

  test('sort, type and prefix map onto catalog parameters', () async {
    final c = client(
      (_) async => _json({
        'items': [],
        'page': {'has_more': false},
      }),
    );
    await c.fetchLibraryPagedContent(
      '3',
      query: const LibraryQuery(
        sort: LibrarySort(field: 'addedAt', direction: LibrarySortDirection.descending),
        nameStartsWith: 'B',
        kind: MediaKind.show,
      ),
    );
    final query = requests.single.url.queryParameters;
    expect(query['sort'], '-added_at');
    expect(query['type'], 'series');
    expect(query['name_prefix'], 'B');
    expect(query['source'], 'query');
  });

  test('a 401 refreshes once, retries, and reports the rotated tokens', () async {
    var refreshed = false;
    final c = client((request) async {
      if (request.url.path.endsWith('/auth/refresh')) {
        expect(jsonDecode(request.body), {'refresh_token': 'ref-1'});
        expect(request.headers.containsKey('Authorization'), isFalse);
        refreshed = true;
        return _json({'access_token': 'acc-2', 'refresh_token': 'ref-2', 'expires_in': 3600});
      }
      if (request.headers['Authorization'] == 'Bearer acc-1') return _problem(401, 'invalid_token');
      return _json({'items': []});
    });
    SiloConnection? persisted;
    c.onConnectionUpdated = (connection) => persisted = connection;

    await c.fetchLibraries();
    expect(refreshed, isTrue);
    expect(requests.last.headers['Authorization'], 'Bearer acc-2');
    expect(persisted?.refreshToken, 'ref-2');
    expect(c.connection.accessToken, 'acc-2');
    expect(c.ownsRefreshToken('ref-1'), isTrue);
    expect(c.ownsRefreshToken('ref-2'), isTrue);
  });

  test('a refused refresh reports an auth error from the health probe', () async {
    final c = client((request) async {
      if (request.url.path.endsWith('/auth/refresh')) return _problem(401, 'session_expired');
      return _problem(401, 'invalid_token');
    });
    expect(await c.checkHealth(), HealthStatus.authError);
  });

  test('a refresh failing without Silo\'s refusal keeps the session', () async {
    for (final failure in [
      _problem(403, 'forbidden'),
      http.Response('<html>Sign in to the proxy</html>', 401, headers: {'content-type': 'text/html'}),
      http.Response('bad gateway', 502),
    ]) {
      requests.clear();
      var expired = false;
      final c = client((request) async {
        if (request.url.path.endsWith('/auth/refresh')) return failure;
        return _problem(401, 'invalid_token');
      });
      c.onConnectionUpdated = (_) => expired = true;
      expect(await c.checkHealth(), HealthStatus.offline);
      // Tried again next time: the refresh token was not written off.
      expect(await c.checkHealth(), HealthStatus.offline);
      expect(requests.where((r) => r.url.path.endsWith('/auth/refresh')), hasLength(2));
      expect(expired, isFalse);
    }
  });

  test('a 401 for a token another request already replaced retries without refreshing again', () async {
    final gate = Completer<void>();
    var refreshes = 0;
    final c = client((request) async {
      final path = request.url.path;
      if (path.endsWith('/auth/refresh')) {
        refreshes++;
        return _json({'access_token': 'acc-2', 'refresh_token': 'ref-$refreshes', 'expires_in': 3600});
      }
      if (request.headers['Authorization'] == 'Bearer acc-1') {
        if (path.endsWith('/user/libraries')) await gate.future;
        return _problem(401, 'invalid_token');
      }
      if (path.endsWith('/account/me')) return _json({'role': 'user'});
      return _json({'items': []});
    });
    final libraries = c.fetchLibraries();
    await Future<void>.delayed(Duration.zero);
    expect(await c.checkHealth(), HealthStatus.online);
    gate.complete();
    await libraries;
    expect(refreshes, 1);
    expect(requests.last.headers['Authorization'], 'Bearer acc-2');
  });

  test('a refused refresh token is not sent again', () async {
    final c = client((request) async {
      if (request.url.path.endsWith('/auth/refresh')) return _problem(401, 'session_expired');
      return _problem(401, 'invalid_token');
    });
    expect(await c.checkHealth(), HealthStatus.authError);
    expect(await c.checkHealth(), HealthStatus.authError);
    expect(requests.where((r) => r.url.path.endsWith('/auth/refresh')), hasLength(1));
  });

  test('watch-state writes on a synthetic season go to the real season, never the series', () async {
    final c = client((request) async {
      final path = Uri.decodeComponent(request.url.path);
      if (path.endsWith('/catalog/series/series:s1/seasons')) {
        return _json({
          'items': [
            {'content_id': 'season:s1-2', 'season_number': 2, 'title': 'Season 2'},
          ],
        });
      }
      return http.Response('', 204);
    });
    final season = (await c.fetchItem(SiloMappers.syntheticSeasonId('series:s1', 2)))!;
    await c.markWatched(season);
    expect(Uri.decodeComponent(requests.last.url.path), endsWith('/api/v2/watched/season:s1-2'));
  });

  test('home sections become hubs; playback rows can be left out', () async {
    final c = client((request) async {
      if (request.url.path.endsWith('/home/sections')) {
        return _json({
          'sections': [
            {
              'id': 'continue_watching',
              'section_type': 'continue_watching',
              'title': 'Continue Watching',
              'total_count': 1,
              'items': [_movie(1)],
            },
            {
              'id': 'ra-3',
              'section_type': 'recently_added',
              'title': 'Recently Added',
              'total_count': 40,
              'items': [_movie(2)],
            },
            {'id': 'empty', 'section_type': 'random', 'title': 'Empty', 'total_count': 0, 'items': []},
          ],
        });
      }
      return _json({
        'items': [],
        'page': {'has_more': false},
      });
    });

    final all = await c.fetchGlobalHubs();
    expect(all.map((h) => h.id), ['home:continue_watching', 'home:ra-3']);
    expect(all.first.isContinueWatchingHub, isTrue);
    expect(all.last.more, isTrue);

    final withoutPlayback = await c.fetchGlobalHubs(includePlaybackHubs: false);
    expect(withoutPlayback.map((h) => h.id), ['home:ra-3']);

    requests.clear();
    await c.fetchMoreHubItemsPage('home:ra-3', start: 0, size: 20);
    final query = requests.single.url.queryParameters;
    expect(query['source'], 'section');
    expect(query['section_id'], 'ra-3');
    expect(query['scope'], 'home');
  });

  group('section rows item_limit', () {
    final sections = {
      'sections': [
        {
          'id': 'ra-3',
          'section_type': 'recently_added',
          'title': 'Recently Added',
          'total_count': 1,
          'items': [_movie(1)],
        },
      ],
    };

    test('item_limit is min(20, section_item_limit_max), or nothing', () {
      expect(SiloClient.sectionItemLimitParam(null), isNull);
      expect(SiloClient.sectionItemLimitParam(0), isNull);
      expect(SiloClient.sectionItemLimitParam('100'), isNull);
      expect(SiloClient.sectionItemLimitParam(5), 5);
      expect(SiloClient.sectionItemLimitParam(100), 20);
    });

    /// Loads Home twice and one library's rows; returns the capability
    /// reads and the `item_limit` each section list carried.
    Future<(int, List<String?>)> sentLimits(http.Response Function() capability) async {
      var capabilityReads = 0;
      final limits = <String?>[];
      final c = client((request) async {
        final path = request.url.path;
        if (path.endsWith('/home/capabilities')) {
          capabilityReads++;
          return capability();
        }
        if (path.endsWith('/home/sections') || path.endsWith('/library/7/sections')) {
          limits.add(request.url.queryParameters['item_limit']);
          return _json(sections);
        }
        throw StateError('unexpected $path');
      });
      await Future.wait([c.fetchGlobalHubs(), c.fetchContinueWatching()]);
      await c.fetchGlobalHubs();
      await c.fetchLibraryHubs('7', libraryName: 'Movies');
      return (capabilityReads, limits);
    }

    test('an advertising server is asked once and gets the capped limit', () async {
      final (reads, limits) = await sentLimits(
        () => _json({'revision': 'r', 'state': 'available', 'section_item_limit_max': 100}),
      );
      expect(reads, 1);
      expect(limits, ['20', '20', '20']);
    });

    test('an older server without the field gets no item_limit', () async {
      final (reads, limits) = await sentLimits(() => _json({'revision': 'r', 'state': 'available'}));
      expect(reads, 1);
      expect(limits, [null, null, null]);
    });

    test('a failed capability read counts as unsupported for the session', () async {
      final (reads, limits) = await sentLimits(() => _problem(404, 'not_found'));
      expect(reads, 1);
      expect(limits, [null, null, null]);
    });

    test('a 422 unknown_parameter for item_limit is read again without it, once', () async {
      var capabilityReads = 0;
      final limits = <String?>[];
      final c = client((request) async {
        if (request.url.path.endsWith('/home/capabilities')) {
          capabilityReads++;
          return _json({'section_item_limit_max': 50});
        }
        final limit = request.url.queryParameters['item_limit'];
        limits.add(limit);
        if (limit != null) {
          return http.Response(
            jsonEncode({
              'type': 'https://siloserver.org/problems/validation_failed',
              'title': 'Validation failed',
              'status': 422,
              'errors': [
                {'location': 'query.item_limit', 'code': 'unknown_parameter'},
              ],
            }),
            422,
            headers: {'content-type': 'application/problem+json'},
          );
        }
        return _json(sections);
      });
      final hubs = await c.fetchGlobalHubs();
      expect(hubs.single.id, 'home:ra-3');
      await c.fetchLibraryHubs('7', libraryName: 'Movies');
      expect(capabilityReads, 1);
      expect(limits, ['20', null, null]);
    });

    test('other validation failures are not retried', () async {
      var listReads = 0;
      final c = client((request) async {
        if (request.url.path.endsWith('/home/capabilities')) return _json({'section_item_limit_max': 50});
        listReads++;
        return http.Response(
          jsonEncode({
            'type': 'https://siloserver.org/problems/validation_failed',
            'status': 422,
            'errors': [
              {'location': 'query.image_size', 'code': 'invalid_value'},
            ],
          }),
          422,
          headers: {'content-type': 'application/problem+json'},
        );
      });
      final hubs = await c.fetchLibraryHubs('7', libraryName: 'Movies');
      expect(hubs, isEmpty);
      expect(listReads, 1);
    });

    test('every row with cards opens its full page, even when it looks complete', () async {
      final c = client((request) async {
        if (request.url.path.endsWith('/home/sections')) return _json(sections);
        return _json({});
      });
      final hub = (await c.fetchGlobalHubs()).single;
      expect(hub.items, hasLength(1));
      expect(hub.more, isTrue);
    });
  });

  group('playback', () {
    late Map<String, dynamic> startBody;
    final progressBodies = <Map<String, dynamic>>[];
    Map<String, dynamic>? stopBody;

    SiloClient playbackClient() => client((request) async {
      final path = Uri.decodeComponent(request.url.path);
      if (path.endsWith('/watch/movie:m1')) {
        return _json({
          'content_id': 'movie:m1',
          'type': 'movie',
          'user_data': {'last_file_id': '43'},
          'versions': [
            {'file_id': '42', 'resolution': '1080p', 'audio_tracks': []},
            {
              'file_id': '43',
              'resolution': '2160p',
              'audio_tracks': [
                {'index': 0, 'language': 'eng', 'codec': 'eac3', 'default': true},
                {'index': 1, 'language': 'spa', 'codec': 'aac'},
              ],
              'subtitle_tracks': [
                {'index': 0, 'language': 'eng', 'codec': 'srt', 'external': true},
                {'index': 1, 'language': 'eng', 'codec': 'subrip'},
              ],
              'marker_segments': [
                {'kind': 'intro', 'start_seconds': 10, 'end_seconds': 70},
              ],
            },
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
        startBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({
          'protocol_version': 3,
          'outcome': 'playable',
          'session_id': 'sess-1',
          'playback_plan': {
            'delivery': 'original_http',
            'stream': {'url': '/api/v2/stream/sess-1?st=sig', 'protocol': 'http_progressive'},
            'selected_tracks': {
              'audio': {'id': 'file:43:audio:1', 'index': 1},
            },
            'subtitle': {
              'inventory': [
                {
                  'combined_index': 0,
                  'source': 'external',
                  'codec': 'srt',
                  'delivery': 'sidecar',
                  'url': '/api/v2/stream/sess-1/subtitles/0.vtt?file_id=43',
                },
                {
                  'combined_index': 1,
                  'source': 'embedded',
                  'codec': 'subrip',
                  'delivery': 'sidecar',
                  'url': '/api/v2/stream/sess-1/subtitles/1.vtt?file_id=43',
                },
              ],
            },
          },
        }, 201);
      }
      if (path.endsWith('/playback/sess-1/progress')) {
        progressBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return _json({'outcome': 'applied'});
      }
      if (path.endsWith('/playback/sess-1') && request.method == 'DELETE') {
        stopBody = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({'outcome': 'stopped'});
      }
      return _json({}, 404);
    });

    test('starts the chosen file and reports sequenced progress', () async {
      progressBodies.clear();
      final c = playbackClient();
      final metadata = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie, serverId: 'srv-1');
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: metadata, selectedMediaIndex: 1),
      );

      expect(startBody['file_id'], '43');
      expect(startBody['installation_id'], 'inst-1');
      expect(startBody['profile_id'], 'p-owner');
      expect(startBody['protocol_version'], 3);
      expect(startBody['quality_preference'], 'auto');
      expect((startBody['client_capabilities'] as Map)['video_evidence'], 'declared');
      final context = startBody['client_playback_context'] as Map;
      expect(context['form_factor'], 'desktop');
      expect(startBody['metered'], isFalse);
      final progressive = (context['deliveries'] as Map)['progressive'] as Map;
      expect(progressive['enabled'], isFalse);

      expect(result.videoUrl, 'https://silo.example.com/api/v2/stream/sess-1?st=sig');
      expect(result.isTranscoding, isFalse);
      expect(result.selectedMediaIndex, 1);
      expect(result.playSessionId, 'sess-1');
      // Server-selected audio index 1 → track id 2.
      expect(result.activeAudioStreamId, 2);
      expect(result.mediaInfo!.audioTracks.where((t) => t.selected).single.languageCode, 'spa');
      // Direct play: only the external file is a sidecar; embedded ones are in the file.
      expect(result.subtitleSidecars, hasLength(1));
      expect(result.subtitleSidecars.single.track.uri, contains('/subtitles/0.vtt?file_id=43&token=acc-1'));
      expect(c.streamHeaders['Authorization'], 'Bearer acc-1');

      await c.reportPlaybackStarted(itemId: 'movie:m1', position: Duration.zero, playSessionId: 'sess-1');
      await c.reportPlaybackProgress(
        itemId: 'movie:m1',
        position: const Duration(seconds: 30),
        duration: const Duration(hours: 2),
        isPaused: true,
        playSessionId: 'sess-1',
      );
      await c.reportPlaybackStopped(itemId: 'movie:m1', position: const Duration(seconds: 31), playSessionId: 'sess-1');

      expect(progressBodies.map((b) => b['sequence']), [1, 2]);
      expect(progressBodies.last, {'installation_id': 'inst-1', 'sequence': 2, 'position': 30.0, 'is_paused': true});
      expect(stopBody!['sequence'], 3);
      expect(stopBody!['position'], 31.0);
      expect(stopBody!['stop_id'], isNotEmpty);

      requests.clear();
      final extras = await c.fetchPlaybackExtras('movie:m1');
      expect(extras.markers.single.type, 'intro');
      expect(extras.markers.single.startTimeOffset, 10000);
      // Markers are read for the file being played.
      expect(requests.single.url.queryParameters['file_id'], '43');
    });

    test('a session the server ended stops taking session progress', () async {
      final c = client((request) async {
        final path = Uri.decodeComponent(request.url.path);
        if (path.endsWith('/watch/movie:m1')) {
          return _json({
            'content_id': 'movie:m1',
            'versions': [
              {'file_id': '42'},
            ],
          });
        }
        if (path.endsWith('/playback/capabilities')) {
          return _json({
            'state': 'available',
            'installation_id': 'inst-1',
            'protocol_versions': [3],
            'features': ['sequenced_progress_v1'],
          });
        }
        if (path.endsWith('/playback/start')) {
          return _json({
            'outcome': 'playable',
            'session_id': 'sess-9',
            'playback_plan': {
              'delivery': 'original_http',
              'stream': {'url': '/api/v2/stream/sess-9?st=sig'},
            },
          }, 201);
        }
        if (path.endsWith('/playback/sess-9/progress')) return _problem(410, 'playback_session_ended');
        if (path.endsWith('/sync/progress')) return _json({'items': []});
        return _json({}, 404);
      });
      final metadata = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie, serverId: 'srv-1');
      await c.getPlaybackInitialization(PlaybackInitializationOptions(metadata: metadata, selectedMediaIndex: 0));
      await c.reportPlaybackStarted(itemId: 'movie:m1', position: Duration.zero, playSessionId: 'sess-9');
      requests.clear();
      await c.reportPlaybackProgress(
        itemId: 'movie:m1',
        position: const Duration(minutes: 5),
        duration: const Duration(hours: 1),
        playSessionId: 'sess-9',
      );
      // The session row is gone: the resume point is written without it.
      expect(requests.single.url.path, endsWith('/sync/progress'));
    });

    test('a capped preset reports a fallback only when the server left a larger source unchanged', () async {
      Map<String, dynamic>? source;
      final c = client((request) async {
        final path = Uri.decodeComponent(request.url.path);
        if (path.endsWith('/watch/movie:m1')) {
          return _json({
            'content_id': 'movie:m1',
            'versions': [
              {'file_id': '42'},
            ],
          });
        }
        if (path.endsWith('/playback/capabilities')) {
          return _json({
            'state': 'available',
            'installation_id': 'inst-1',
            'protocol_versions': [3],
            'features': ['sequenced_progress_v1'],
          });
        }
        if (path.endsWith('/playback/start')) {
          return _json({
            'outcome': 'playable',
            'session_id': 'sess-${requests.length}',
            'playback_plan': {
              'delivery': 'original_http',
              'stream': {'url': '/api/v2/stream/s?st=sig'},
              'source': ?source,
            },
          }, 201);
        }
        return _json({}, 404);
      });
      final metadata = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie, serverId: 'srv-1');
      Future<TranscodeFallbackReason?> play() async => (await c.getPlaybackInitialization(
        PlaybackInitializationOptions(
          metadata: metadata,
          selectedMediaIndex: 0,
          qualityPreset: TranscodeQualityPreset.p720_4mbps,
        ),
      )).fallbackReason;

      source = {'media_file_id': '42', 'height': 720, 'bitrate_kbps': 2500};
      expect(await play(), isNull);
      source = {'media_file_id': '42', 'height': 2160, 'bitrate_kbps': 40000};
      expect(await play(), TranscodeFallbackReason.directPlayOnly);
    });

    test('an external player gets a direct link and no playback session', () async {
      final c = client((request) async {
        final path = Uri.decodeComponent(request.url.path);
        if (path.endsWith('/watch/movie:m1')) {
          return _json({
            'content_id': 'movie:m1',
            'versions': [
              {'file_id': '42'},
            ],
          });
        }
        if (path.endsWith('/direct-download/links')) {
          return _json({'url': '/api/v2/direct-download?file_id=42&dl=tok'});
        }
        return _json({}, 404);
      });
      final metadata = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie, serverId: 'srv-1');
      final target = await c.resolveExternalPlayback(metadata);
      expect(target!.url, 'https://silo.example.com/api/v2/direct-download?file_id=42&dl=tok');
      expect(requests.where((r) => r.url.path.contains('/playback/')), isEmpty);
    });
  });

  group('downloads', () {
    Map<String, dynamic> watchDetail({bool externalSubs = true}) => {
      'content_id': 'movie:m1',
      'type': 'movie',
      'versions': [
        {
          'file_id': '42',
          'container': 'mkv',
          'resolution': '1080p',
          'audio_tracks': [
            {'index': 0, 'language': 'eng', 'codec': 'aac', 'default': true},
          ],
          'subtitle_tracks': [
            {'index': 0, 'language': 'eng', 'codec': 'srt', 'external': externalSubs},
          ],
          'marker_segments': [
            {'kind': 'credits', 'start_seconds': 100, 'end_seconds': 120},
          ],
        },
      ],
    };

    SiloClient downloadClient({bool linksSupported = true, bool externalSubs = true}) => client((request) async {
      final path = Uri.decodeComponent(request.url.path);
      if (path.endsWith('/watch/movie:m1')) return _json(watchDetail(externalSubs: externalSubs));
      if (path.endsWith('/direct-download/links')) {
        if (!linksSupported) return _problem(404, 'not_found');
        expect(jsonDecode(request.body), {'file_id': '42'});
        return _json({
          'url': '/api/v2/direct-download?file_id=42&token=dl-signed',
          'proxy_url': '/api/v2/direct-download-proxy?file_id=42&token=dl-signed',
          'expires_at': '2030-01-01T00:00:00Z',
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
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final deliveries = (body['client_playback_context'] as Map)['deliveries'] as Map;
        expect(deliveries.keys, ['original_http']);
        return _json({
          'outcome': 'playable',
          'session_id': 'sess-dl',
          'playback_plan': {
            'delivery': 'original_http',
            'stream': {'url': '/api/v2/stream/sess-dl?st=x'},
            'subtitle': {
              'inventory': [
                {
                  'combined_index': 0,
                  'source': 'external',
                  'codec': 'srt',
                  'language': 'eng',
                  'label': 'English',
                  'delivery': 'sidecar',
                  'url': '/api/v2/stream/sess-dl/subtitles/0.vtt?file_id=42&external_subtitle_key=k',
                },
                {'combined_index': 1, 'source': 'embedded', 'codec': 'ass', 'delivery': 'sidecar', 'url': '/x/1.ass'},
              ],
            },
          },
        }, 201);
      }
      return _json({}, 404);
    });

    test('downloads the original file through a header-free direct link', () async {
      final c = downloadClient();
      final item = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie, serverId: 'srv-1');
      final resolution = await c.resolveDownload(item);

      expect(
        resolution.videoUrl,
        'https://silo.example.com/api/v2/direct-download?file_id=42&token=dl-signed#container=mkv',
      );
      expect(downloadExtensionFromUrl(resolution.videoUrl!), 'mkv');
      expect(resolution.mediaSourceId, '42');
      expect(resolution.externalSubtitlesResolved, isTrue);
      final subtitle = resolution.externalSubtitles.single;
      expect(
        subtitle.url,
        contains('/api/v2/stream/sess-dl/subtitles/0.vtt?file_id=42&external_subtitle_key=k&token=acc-1'),
      );
      expect(subtitle.codec, 'webvtt');
      expect(subtitle.language, 'eng');
      // The session only lists external subtitles; it is left to expire.
      expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    });

    test('no playback session is opened when the file has no external subtitles', () async {
      final c = downloadClient(externalSubs: false);
      final resolution = await c.resolveDownload(MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie));
      expect(resolution.externalSubtitles, isEmpty);
      expect(requests.where((r) => r.url.path.endsWith('/playback/start')), isEmpty);
    });

    test('a server without direct links fails the download instead of putting the account token in a URL', () async {
      final c = downloadClient(linksSupported: false, externalSubs: false);
      await expectLater(
        c.resolveDownload(MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie)),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('a pinned download plays offline with its markers and tracks', () async {
      final c = downloadClient(externalSubs: false);
      final item = MediaItem.silo(id: 'movie:m1', kind: MediaKind.movie);
      await c.resolveDownload(item);
      await SiloApiCache.instance.pinForOffline(ServerId(c.cacheServerId), item.id);
      await SiloApiCache.instance.clearVolatile();

      final extras = await CachedPlaybackMetadataService.fetchPlaybackExtras(
        backend: MediaBackend.silo,
        cacheServerId: c.cacheServerId,
        itemId: item.id,
      );
      expect(extras!.markers.single.type, 'credits');
      final info = await CachedPlaybackMetadataService.fetchMediaSourceInfo(
        backend: MediaBackend.silo,
        cacheServerId: c.cacheServerId,
        itemId: item.id,
      );
      expect(info!.mediaSourceId, '42');
      expect(info.audioTracks.single.languageCode, 'eng');
    });
  });

  group('progress without a playback session', () {
    late List<Map<String, dynamic>> syncBodies;

    SiloClient progressClient() {
      syncBodies = [];
      return client((request) async {
        if (request.url.path.endsWith('/sync/progress')) {
          syncBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _json({
            'items': [
              {'index': 0, 'media_item_id': 'movie:m1', 'status': 'success'},
            ],
            'summary': {'total': 1, 'succeeded': 1, 'failed': 0},
          });
        }
        return http.Response('', 204);
      });
    }

    test('a downloaded file writes its resume point', () async {
      final c = progressClient();
      await c.reportPlaybackStopped(
        itemId: 'movie:m1',
        position: const Duration(minutes: 10),
        duration: const Duration(hours: 2),
      );
      final item = (syncBodies.single['items'] as List).single as Map;
      expect(item['media_item_id'], 'movie:m1');
      expect(item['position_ms'], 600000);
      expect(item['duration_ms'], 7200000);
      expect(item['updated_at'], isNotNull);
    });

    test('stopping past the watched threshold marks the item played', () async {
      final c = progressClient();
      await c.reportPlaybackStopped(
        itemId: 'movie:m1',
        position: const Duration(minutes: 115),
        duration: const Duration(hours: 2),
      );
      expect(syncBodies, isEmpty);
      expect(Uri.decodeComponent(requests.single.url.path), endsWith('/api/v2/watched/movie:m1'));
      expect(requests.single.method, 'POST');
    });
  });

  group('extras and remote trailers', () {
    final detail = {
      'content_id': 'movie:m1',
      'type': 'movie',
      'title': 'Heat',
      'extras': [
        {
          'content_id': 'extra:1',
          'kind': 'trailer',
          'title': 'Official Trailer',
          'duration_seconds': 150,
          'file_id': 501,
          'still_url': '/api/v2/images/extra-1.jpg?exp=1&sig=a',
        },
        {'content_id': 'extra:2', 'kind': 'behind_the_scenes', 'file_id': 502},
        {'content_id': 'extra:1', 'kind': 'trailer', 'file_id': 501},
        {'kind': 'featurette'},
      ],
      'videos': [
        {'kind': 'trailer', 'site': 'YouTube', 'site_key': 'yt-1', 'name': 'Trailer 1', 'is_official': true},
        {'kind': 'teaser', 'site': 'Vimeo', 'site_key': 'vm-1'},
        {'kind': 'teaser', 'site': 'youtube', 'site_key': ' '},
        {'kind': 'clip', 'site': 'youtube', 'site_key': 'yt-2', 'language': 'en'},
        {'kind': 'trailer', 'site': 'YouTube', 'site_key': 'yt-1'},
      ],
    };

    test('extras and YouTube videos come from the detail document fetchItem read', () async {
      final c = client((request) async {
        final path = Uri.decodeComponent(request.url.path);
        if (path.endsWith('/catalog/items/movie:m1')) return _json(detail);
        return _json({}, 404);
      });

      await c.fetchItem('movie:m1');
      final extras = await c.fetchExtras('movie:m1');
      final remote = await c.fetchRemoteTrailers('movie:m1');
      expect(requests, hasLength(1), reason: 'extras reuse the detail row instead of fetching it again');

      expect(extras.map((e) => e.id), ['extra:1', 'extra:2']);
      final trailer = extras.first;
      expect(trailer.backend, MediaBackend.silo);
      expect(trailer.kind, MediaKind.clip);
      expect(trailer.title, 'Official Trailer');
      expect(trailer.durationMs, 150000);
      expect(trailer.thumbPath, 'https://silo.example.com/api/v2/images/extra-1.jpg?exp=1&sig=a');
      expect(trailer.serverId, 'srv-1');
      expect(SiloMappers.isExtra(trailer), isTrue);
      expect(SiloMappers.extraFileId(trailer), '501');
      expect(SiloMappers.extraKind(trailer), 'trailer');
      // No title: the kind's label.
      expect(extras[1].title, 'Behind the Scenes');
      expect(extras[1].thumbPath, isNull);

      expect(remote.map((v) => v.key), ['yt-1', 'yt-2']);
      expect(remote.first.isOfficial, isTrue);
      expect(remote.first.name, 'Trailer 1');
      expect(remote.last.kind, 'clip');
      expect(remote.last.language, 'en');
    });

    test('a cold call fetches the detail once for both lists', () async {
      final c = client((request) async => _json(detail));
      final (extras, remote) = await (c.fetchExtras('movie:m1'), c.fetchRemoteTrailers('movie:m1')).wait;
      expect(extras, hasLength(2));
      expect(remote, hasLength(2));
      expect(requests, hasLength(1));
    });

    test('items without a detail document or extras have none', () async {
      final c = client((request) async {
        final path = Uri.decodeComponent(request.url.path);
        if (path.endsWith('/catalog/items/movie:none')) return _json({'content_id': 'movie:none', 'type': 'movie'});
        return _problem(404, 'not_found');
      });
      expect(await c.fetchExtras('silo-season:1:series:s1'), isEmpty);
      expect(await c.fetchRemoteTrailers('silo-collection:3'), isEmpty);
      expect(requests, isEmpty);
      expect(await c.fetchExtras('movie:gone'), isEmpty);
      expect(await c.fetchExtras('movie:none'), isEmpty);
      expect(await c.fetchRemoteTrailers('movie:none'), isEmpty);
    });

    Future<http.Response> extraPlayback(
      http.Request request, {
      required Map<String, dynamic> Function(Map<String, dynamic> body) onStart,
      http.Response? watch,
    }) async {
      final path = Uri.decodeComponent(request.url.path);
      if (path.endsWith('/watch/extra:1')) return watch ?? _problem(404, 'not_found');
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
        return _json(onStart(jsonDecode(request.body) as Map<String, dynamic>), 201);
      }
      return _json({}, 404);
    }

    Map<String, dynamic> playable(Map<String, dynamic> _) => {
      'outcome': 'playable',
      'session_id': 'sess-x',
      'playback_plan': {
        'delivery': 'original_http',
        'stream': {'url': '/api/v2/stream/sess-x?st=sig'},
      },
    };

    MediaItem extraItem() => SiloMappers.extras(
      detail,
      const SiloMappingContext(serverId: 'srv-1', serverName: null, resolveUrl: _same),
    ).first;

    test('an extra without watch detail plays its own file', () async {
      Map<String, dynamic>? startBody;
      final c = client(
        (request) => extraPlayback(
          request,
          onStart: (body) {
            startBody = body;
            return playable(body);
          },
        ),
      );
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: extraItem(), selectedMediaIndex: 0),
      );
      expect(startBody!['file_id'], '501');
      expect(result.playSessionId, 'sess-x');
      expect(result.selectedMediaSourceId, '501');
    });

    test('an extra with watch detail picks its file among the versions', () async {
      Map<String, dynamic>? startBody;
      final c = client(
        (request) => extraPlayback(
          request,
          watch: _json({
            'content_id': 'extra:1',
            'user_data': {'last_file_id': '777'},
            'versions': [
              {'file_id': '777'},
              {'file_id': '501'},
            ],
          }),
          onStart: (body) {
            startBody = body;
            return playable(body);
          },
        ),
      );
      final result = await c.getPlaybackInitialization(
        PlaybackInitializationOptions(metadata: extraItem(), selectedMediaIndex: 0),
      );
      expect(startBody!['file_id'], '501');
      expect(result.selectedMediaIndex, 1);
    });

    test('a missing watch detail still fails playback for ordinary items', () async {
      final c = client((request) => extraPlayback(request, onStart: playable));
      final movie = MediaItem.silo(id: 'extra:1', kind: MediaKind.movie, serverId: 'srv-1');
      await expectLater(
        c.getPlaybackInitialization(PlaybackInitializationOptions(metadata: movie, selectedMediaIndex: 0)),
        throwsA(isA<PlaybackException>()),
      );
    });
  });
}

String _same(String url) => url;
