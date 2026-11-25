import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';

/// Answers shaped like Tofa's OpenAPI schemas (`MediaSummary`, `MediaDetail`,
/// `MediaFile`, `PlaybackInfoResponse`, …), with made-up ids and no real
/// tokens. Only the fields the client reads are filled in, plus the
/// required ones a real server always sends.

const tofaBase = 'http://tofa.example.com:8096';
const tofaCloud = 'https://cloud.example.com';

TofaConnection tofaConnection({
  String accessToken = 'acc-1',
  String refreshToken = 'ref-1',
  DateTime? accessTokenExpiresAt,
  String? profileToken,
}) => TofaConnection(
  id: TofaConnection.compoundId(serverId: 'srv-1', userId: 'u-1', profileId: 'p-1'),
  baseUrl: tofaBase,
  serverName: 'tofa.example.com',
  serverId: 'srv-1',
  connectUrl: tofaCloud,
  userId: 'u-1',
  userName: 'laura',
  accessToken: accessToken,
  refreshToken: refreshToken,
  accessTokenExpiresAt: accessTokenExpiresAt,
  profileId: 'p-1',
  profileName: 'Laura',
  profileToken: profileToken,
  profileIsLocked: profileToken != null,
  createdAt: DateTime(2026),
);

http.Response jsonResponse(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

http.Response tofaError(int status, String error, [String message = 'Refused']) =>
    jsonResponse({'error': error, 'message': message}, status);

Map<String, dynamic> mediaFile(String id, {String mediaId = 'm-1', String? episodeId, int durationMs = 6000000}) => {
  'id': id,
  'media_id': mediaId,
  'episode_id': episodeId,
  'available': true,
  'container': 'mkv',
  'video_codec': 'hevc',
  'audio_codec': 'eac3',
  'height': 2160,
  'hdr': true,
  'bitrate': 25000000,
  'duration_ms': durationMs,
  'part_number': null,
  'part_count': null,
  'file_path': '/media/$id.mkv',
  'probe_version': 3,
  'audio_tracks': [
    {'index': 0, 'codec': 'eac3', 'language': 'eng', 'title': 'English', 'channels': 6},
  ],
  'subtitle_tracks': [
    {'index': 0, 'codec': 'subrip', 'language': 'eng', 'title': null, 'forced': false, 'external': false},
  ],
};

Map<String, dynamic> mediaSummary(String id, {String type = 'movie', bool watched = false, String library = 'lib-1'}) =>
    {
      'id': id,
      'media_type': type,
      'title': 'Title $id',
      'overview': 'Overview',
      'release_date': '2021-05-04',
      'runtime_minutes': 100,
      'genres': ['Drama'],
      'rating': 7.5,
      'imdb_rating': 7.1,
      'library_id': library,
      'poster_path': '/posters/$id.jpg',
      'backdrop_path': '/backdrops/$id.jpg',
      'backdrop_thumb': null,
      'logo_path': null,
      'tmdb_id': 42,
      'available': true,
      'watched': watched,
      'watch_mark': {'state': watched ? 'watched' : 'none', 'progress_percent': null, 'episodes_left': null},
    };

Map<String, dynamic> movieDetail({List<Map<String, dynamic>>? files}) => {
  'id': 'm-1',
  'media_type': 'movie',
  'title': 'A Movie',
  'sort_title': 'Movie, A',
  'overview': 'Plot',
  'release_date': '2020-01-02',
  'runtime_minutes': 100,
  'library_id': 'lib-1',
  'poster_path': '/p.jpg',
  'backdrop_path': '/b.jpg',
  'genres': ['Drama'],
  'studios': ['Studio'],
  'cast': [
    {'name': 'Actor One', 'role': 'Hero', 'profile_url': 'https://images.example.com/a.jpg'},
  ],
  'crew': [
    {'name': 'Dir One', 'job': 'Director'},
  ],
  'locked_fields': <String>[],
  'match_ignored': false,
  'metadata_retry_count': 0,
  'settings': <String, dynamic>{},
  'files': files ?? [mediaFile('f-1')],
  'provider_ids': [
    {'media_id': 'm-1', 'provider': 'imdb', 'provider_id': 'tt0000001'},
  ],
  'tmdb_id': 42,
};

Map<String, dynamic> episodeJson(String id, int number, {List<String> files = const []}) => {
  'id': id,
  'season_id': 's-$id',
  'episode_number': number,
  'title': 'Episode $number',
  'overview': 'Ep',
  'air_date': '2022-01-0$number',
  'still_path': null,
  'runtime_minutes': 45,
  'metadata_unmatched': false,
  'metadata_verified': false,
  'quickview_ready': false,
  'files': [for (final f in files) mediaFile(f, mediaId: 'show-1', episodeId: id, durationMs: 2700000)],
};

Map<String, dynamic> showDetail({Map<String, dynamic>? nextUp}) => {
  'id': 'show-1',
  'media_type': 'tv',
  'title': 'A Show',
  'sort_title': 'Show, A',
  'overview': 'Series',
  'release_date': '2022-01-01',
  'library_id': 'lib-2',
  'poster_path': '/sp.jpg',
  'backdrop_path': '/sb.jpg',
  'genres': <String>[],
  'studios': <String>[],
  'cast': <Object>[],
  'crew': <Object>[],
  'locked_fields': <String>[],
  'match_ignored': false,
  'metadata_retry_count': 0,
  'settings': <String, dynamic>{},
  'files': <Object>[],
  'provider_ids': <Object>[],
  'next_up': nextUp,
  'seasons': [
    {
      'id': 'sea-0',
      'media_id': 'show-1',
      'season_number': 0,
      'title': 'Specials',
      'episodes': [
        episodeJson('e-sp', 1, files: ['f-sp']),
      ],
    },
    {
      'id': 'sea-1',
      'media_id': 'show-1',
      'season_number': 1,
      'title': 'Season 1',
      'episodes': [
        episodeJson('e-2', 2, files: ['f-e2']),
        episodeJson('e-1', 1, files: ['f-e1a', 'f-e1b']),
      ],
    },
  ],
};

Map<String, dynamic> progressRow(String fileId, {int positionMs = 0, bool completed = false, String? at}) => {
  'media_file_id': fileId,
  'position_ms': positionMs,
  'completed': completed,
  'last_watched_at': at ?? '2026-11-20T10:00:00Z',
  'profile_id': 'p-1',
  'user_id': 'u-1',
};

Map<String, dynamic> playbackInfo({
  String playMethod = 'DirectPlay',
  String streamUrl = '/api/v1/stream/f-1/file.mkv?st=stream-token',
  int startTicks = 0,
}) => {
  'play_method': playMethod,
  'decision_mode': playMethod == 'DirectPlay' ? 'DirectFile' : 'HlsFullTranscode',
  'decision_trace_id': 'trace-1',
  'media_file_id': 'f-1',
  'stream_url': streamUrl,
  'session_id': 'sid-1',
  'session_token': 'sess-tok',
  'start_position_ticks': startTicks,
  'duration_ms': 6000000,
  'audio_tracks': [
    {'index': 0, 'codec': 'eac3', 'language': 'eng', 'title': 'English', 'channels': 6},
    {'index': 1, 'codec': 'aac', 'language': 'fra', 'title': 'French', 'channels': 2},
  ],
  'selected_audio_stream_index': 1,
  'subtitle_tracks': [
    {
      'index': 0,
      'codec': 'subrip',
      'language': 'eng',
      'title': 'English',
      'forced': false,
      'external': false,
      'render': 'text',
    },
    {
      'index': 1,
      'codec': 'webvtt',
      'language': 'deu',
      'title': 'German',
      'forced': false,
      'external': true,
      'render': 'text',
    },
    {
      'index': 2,
      'codec': 'hdmv_pgs_subtitle',
      'language': 'eng',
      'title': 'PGS',
      'forced': false,
      'external': false,
      'render': 'bitmap',
    },
  ],
  'burn_in_subtitle_tracks': <Object>[],
  'font_attachments': <Object>[],
  'quality_tiers': <Object>[],
  'transcode_reasons': <String>[],
  'transcode_reason_codes': <String>[],
};

/// A fake Tofa server and cloud: routes by `METHOD path`, records every
/// request.
class FakeTofa {
  FakeTofa();

  final List<http.Request> requests = [];
  final Map<String, http.Response Function(http.Request request)> routes = {};

  void on(String method, String path, http.Response Function(http.Request request) answer) =>
      routes['$method $path'] = answer;

  /// A route on one host only (several addresses of one server).
  void onHost(String host, String method, String path, http.Response Function(http.Request request) answer) =>
      routes['$method //$host$path'] = answer;

  /// Routes for every path under a prefix (ids made up at run time).
  final Map<String, http.Response Function(http.Request request)> prefixRoutes = {};

  void onPrefix(String method, String prefix, http.Response Function(http.Request request) answer) =>
      prefixRoutes['$method $prefix'] = answer;

  /// Hosts that refuse connections.
  final Set<String> downHosts = {};

  MockClient get client => MockClient((request) async {
    requests.add(request);
    if (downHosts.contains(request.url.host)) throw http.ClientException('connection refused', request.url);
    final route =
        routes['${request.method} //${request.url.host}${request.url.path}'] ??
        routes['${request.method} ${request.url.path}'] ??
        [
          for (final e in prefixRoutes.entries)
            if ('${request.method} ${request.url.path}'.startsWith(e.key)) e.value,
        ].firstOrNull;
    if (route == null) return tofaError(404, 'not_found', 'No route ${request.method} ${request.url.path}');
    return route(request);
  });

  List<http.Request> to(String method, String path) => [
    for (final r in requests)
      if (r.method == method && r.url.path == path) r,
  ];
}
