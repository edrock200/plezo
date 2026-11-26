// A local fake IPTV provider for tests and manual checks: an Xtream Codes
// `player_api.php`, `xmltv.php`, an M3U playlist, a gzip guide and playable
// dummy streams. It uses dart: libraries only, so it also runs on its own:
//
//   dart run scripts/iptv_fake_server.dart --port 8899
//
// Every name and address in it is made up.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class FakeIptvServer {
  FakeIptvServer({this.username = 'demo', this.password = 'secret', this.channelCount = 6});

  final String username;
  final String password;
  final int channelCount;

  HttpServer? _server;
  final List<Uri> requests = [];

  /// Answer `user_info.auth: 0` to every login.
  bool refuseLogin = false;

  /// Answer every request with HTTP 500.
  bool failEverything = false;

  /// The address it answers at: the socket once [start]ed, else a made-up
  /// host for [respond] (an in-process `MockClient`).
  String get base => _server == null ? 'http://iptv.test' : 'http://${_server!.address.host}:${_server!.port}';

  Future<FakeIptvServer> start({int port = 0}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen(_handle);
    return this;
  }

  Future<void> close() async => _server?.close(force: true);

  /// The guide's day: programmes run on the hour from 6 hours before [now].
  DateTime now = DateTime.now().toUtc();

  static String xmltvTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final u = t.toUtc();
    return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
  }

  String m3u() {
    final b = StringBuffer('#EXTM3U url-tvg="$base/epg.xml.gz" catchup="shift" catchup-days="3"\n');
    for (var i = 1; i <= channelCount; i++) {
      b
        ..writeln(
          '#EXTINF:-1 tvg-id="ch$i.fake" tvg-name="Channel $i" tvg-logo="$base/logo/$i.png" '
          'tvg-chno="${100 + i}" group-title="${i.isOdd ? 'News' : 'Sport'}",Channel $i HD',
        )
        ..writeln('#EXTVLCOPT:http-user-agent=FakePlayer/1.0')
        ..writeln('$base/stream/$i.ts');
    }
    return b.toString();
  }

  String xmltv() {
    final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<tv generator-info-name="fake">\n');
    for (var i = 1; i <= channelCount; i++) {
      b.writeln(
        '<channel id="ch$i.fake"><display-name>Channel $i</display-name><icon src="$base/logo/$i.png"/></channel>',
      );
    }
    final start = DateTime.utc(now.year, now.month, now.day, now.hour).subtract(const Duration(hours: 6));
    for (var i = 1; i <= channelCount; i++) {
      for (var h = 0; h < 24; h++) {
        final s = start.add(Duration(hours: h));
        final e = s.add(const Duration(hours: 1));
        b.writeln(
          '<programme start="${xmltvTime(s)}" stop="${xmltvTime(e)}" channel="ch$i.fake">'
          '<title lang="en">Show $h on $i</title><desc>About show $h &amp; more.</desc>'
          '<category>Talk</category><episode-num system="xmltv_ns">0.$h.</episode-num></programme>',
        );
      }
    }
    b.writeln('</tv>');
    return b.toString();
  }

  bool _authorised(Map<String, String> q) => q['username'] == username && q['password'] == password;

  Object _account() => {
    'user_info': {
      'username': username,
      'auth': refuseLogin ? 0 : 1,
      'status': refuseLogin ? 'Disabled' : 'Active',
      'exp_date': '${now.add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000}',
      'is_trial': '0',
      'active_cons': '0',
      'created_at': '1700000000',
      'max_connections': '2',
      'allowed_output_formats': ['m3u8', 'ts'],
    },
    'server_info': {
      'url': Uri.parse(base).host,
      'port': '${Uri.parse(base).port}',
      'https_port': '443',
      'server_protocol': 'http',
      'timezone': 'Europe/London',
      'timestamp_now': now.millisecondsSinceEpoch ~/ 1000,
      'time_now': now.toIso8601String().substring(0, 19).replaceFirst('T', ' '),
    },
  };

  Object? _api(Map<String, String> q) {
    switch (q['action']) {
      case null:
        return _account();
      case 'get_live_categories':
        return [
          {'category_id': '1', 'category_name': 'News', 'parent_id': 0},
          {'category_id': '2', 'category_name': 'Sport', 'parent_id': 0},
        ];
      case 'get_live_streams':
        return [
          for (var i = 1; i <= channelCount; i++)
            {
              'num': i,
              'name': 'Channel $i',
              'stream_type': 'live',
              'stream_id': 1000 + i,
              'stream_icon': '$base/logo/$i.png',
              'epg_channel_id': 'ch$i.fake',
              'added': '1700000000',
              'category_id': i.isOdd ? '1' : '2',
              'tv_archive': i == 1 ? 1 : 0,
              'tv_archive_duration': i == 1 ? '5' : 0,
            },
        ];
      case 'get_vod_categories':
        return [
          {'category_id': '10', 'category_name': 'Action'},
          {'category_id': '11', 'category_name': 'Drama'},
        ];
      case 'get_vod_streams':
        return [
          for (var i = 1; i <= 4; i++)
            {
              'num': i,
              'name': 'Movie $i (20${10 + i})',
              'stream_type': 'movie',
              'stream_id': 2000 + i,
              'stream_icon': '$base/poster/m$i.jpg',
              'rating': '${5 + i}.5',
              'added': '${1700000000 + i * 1000}',
              'category_id': i <= 2 ? '10' : '11',
              'container_extension': 'mkv',
            },
        ];
      case 'get_vod_info':
        final id = q['vod_id'];
        return {
          'info': {
            'name': 'Movie ${int.parse(id!) - 2000}',
            'movie_image': '$base/poster/m.jpg',
            'backdrop_path': ['$base/backdrop/m.jpg'],
            'plot': 'A made-up plot.',
            'cast': 'Actor One, Actor Two',
            'director': 'Director One',
            'genre': 'Action / Drama',
            'releasedate': '2012-05-01',
            'duration_secs': 5400,
            'rating': '7.1',
            'youtube_trailer': 'dQw4w9WgXcQ',
            'tmdb_id': '1234',
          },
          'movie_data': {
            'stream_id': int.parse(id),
            'name': 'Movie',
            'container_extension': 'mkv',
            'category_id': '10',
          },
        };
      case 'get_series_categories':
        return [
          {'category_id': '20', 'category_name': 'Comedy'},
        ];
      case 'get_series':
        return [
          {
            'num': 1,
            'name': 'Series One',
            'series_id': 3001,
            'cover': '$base/poster/s1.jpg',
            'plot': 'Made up.',
            'genre': 'Comedy',
            'releaseDate': '2020-01-01',
            'rating': '8',
            'last_modified': '1700000500',
            'category_id': '20',
          },
        ];
      case 'get_series_info':
        return {
          'info': {
            'name': 'Series One',
            'cover': '$base/poster/s1.jpg',
            'plot': 'Made up.',
            'cast': 'Someone',
            'genre': 'Comedy',
            'releaseDate': '2020-01-01',
            'backdrop_path': ['$base/backdrop/s1.jpg'],
            'youtube_trailer': '',
            'category_id': '20',
          },
          'seasons': [
            {'season_number': 1, 'name': 'Season 1', 'episode_count': 2},
            {'season_number': 2, 'name': 'Season 2', 'episode_count': 1},
          ],
          'episodes': {
            '1': [
              {
                'id': '4001',
                'episode_num': 1,
                'title': 'Pilot',
                'container_extension': 'mp4',
                'season': 1,
                'info': {'duration_secs': 1500, 'plot': 'First.'},
              },
              {
                'id': '4002',
                'episode_num': 2,
                'title': 'Second',
                'container_extension': 'mp4',
                'season': 1,
                'info': {'duration_secs': 1500},
              },
            ],
            '2': [
              {
                'id': '4003',
                'episode_num': 1,
                'title': 'Return',
                'container_extension': 'mkv',
                'season': 2,
                'info': {},
              },
            ],
          },
        };
      case 'get_short_epg':
        final start = now.millisecondsSinceEpoch ~/ 1000 - 600;
        return {
          'epg_listings': [
            {
              'id': '1',
              'epg_id': 'ch1.fake',
              'title': base64.encode(utf8.encode('Short Now')),
              'description': base64.encode(utf8.encode('Now desc')),
              'start_timestamp': '$start',
              'stop_timestamp': '${start + 1800}',
            },
            {
              'id': '2',
              'epg_id': 'ch1.fake',
              'title': base64.encode(utf8.encode('Short Next')),
              'description': '',
              'start_timestamp': '${start + 1800}',
              'stop_timestamp': '${start + 3600}',
            },
          ],
        };
      case 'get_simple_data_table':
        return {'epg_listings': <Object>[]};
    }
    return <Object>[];
  }

  /// The answer to [uri]: status, body and content type. Shared by the
  /// socket server and in-process clients.
  ({int status, List<int> body, String type}) respond(Uri uri) {
    requests.add(uri);
    if (failEverything) return (status: 500, body: const [], type: 'text/plain');
    final path = uri.path;
    final q = uri.queryParameters;
    List<int> text(String s) => utf8.encode(s);
    if (path == '/player_api.php') {
      return (
        status: 200,
        body: text(
          jsonEncode(
            _authorised(q)
                ? _api(q)
                : {
                    'user_info': {'auth': 0},
                  },
          ),
        ),
        type: 'application/json',
      );
    }
    if (path == '/xmltv.php') {
      if (!_authorised(q)) return (status: 401, body: const [], type: 'text/plain');
      return (status: 200, body: text(xmltv()), type: 'application/xml');
    }
    if (path == '/playlist.m3u') return (status: 200, body: text(m3u()), type: 'audio/x-mpegurl');
    if (path == '/epg.xml') return (status: 200, body: text(xmltv()), type: 'application/xml');
    if (path == '/epg.xml.gz') return (status: 200, body: gzip.encode(text(xmltv())), type: 'application/gzip');
    if (path.startsWith('/stream/') || path.startsWith('/live/') || path.startsWith('/timeshift/')) {
      // A few hundred bytes of MPEG-TS-shaped filler (sync bytes every 188).
      return (status: 200, body: List.generate(188 * 4, (i) => i % 188 == 0 ? 0x47 : 0), type: 'video/mp2t');
    }
    return (status: 404, body: const [], type: 'text/plain');
  }

  Future<void> _handle(HttpRequest request) async {
    final answer = respond(request.uri);
    final res = request.response
      ..statusCode = answer.status
      ..headers.contentType = ContentType.parse(answer.type)
      ..add(answer.body);
    await res.close();
  }
}
