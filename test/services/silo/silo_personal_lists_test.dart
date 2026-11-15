import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/silo/silo_api.dart';
import 'package:plezy/services/silo/silo_api_cache.dart';
import 'package:plezy/services/silo/silo_client.dart';
import 'package:plezy/services/silo/silo_personal_lists.dart';
import 'package:plezy/services/silo/silo_sort_options.dart';

const _headers = SiloDeviceHeaders(
  deviceId: 'dev-1',
  deviceName: 'Test',
  platform: 'linux',
  clientFamily: 'desktop',
  clientVersion: '1.0',
);

SiloConnection _connection() => SiloConnection(
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
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// A card as silo-server's catalog renders it.
Map<String, dynamic> _card(int i, {String type = 'movie'}) => {
  'content_id': '$type:t$i',
  'type': type,
  'title': 'Title $i',
  'poster_url': '/api/v2/images/p/$i?sig=abc',
  'is_favorite': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocaleSync(AppLocale.en);

  late List<http.Request> requests;

  setUp(() {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    SiloApiCache.initialize(db);
    requests = [];
  });

  SiloClient client(http.Response Function(http.Request request) handler) => SiloClient.forTesting(
    _connection(),
    headers: _headers,
    httpClient: MockClient((request) async {
      requests.add(request);
      return handler(request);
    }),
  );

  /// `GET /catalog?source=favorites|watchlist` over [count] saved titles,
  /// cursor-paged as the server pages (`page.next_cursor`, `total`).
  http.Response catalog(http.Request request, {int count = 5}) {
    final q = request.url.queryParameters;
    if (request.url.path != '/api/v2/catalog') return _json({'type': 'not_found'}, 404);
    final limit = int.parse(q['limit']!);
    final start = q['cursor'] == null ? 0 : int.parse(q['cursor']!.substring(1));
    final end = (start + limit).clamp(0, count);
    return _json({
      'items': [for (var i = start; i < end; i++) _card(i, type: q['type'] ?? 'movie')],
      'page': {'has_more': end < count, if (end < count) 'next_cursor': 'c$end'},
      'total': count,
      'total_exact': true,
    });
  }

  test('a personal list pages GET /catalog?source=… in its saved order (no sort sent)', () async {
    final c = client(catalog);
    final first = await c.fetchPersonalListPage(SiloPersonalList.favorites, offset: 0, limit: 2);
    expect(first.items.map((i) => i.id), ['movie:t0', 'movie:t1']);
    expect(first.totalCount, 5);
    final q = requests.single.url.queryParameters;
    expect(q['source'], 'favorites');
    expect(q['limit'], '2');
    expect(q.containsKey('sort'), isFalse, reason: 'no sort = the list order, most recently saved first');
    expect(q.containsKey('type'), isFalse);
    expect(q.containsKey('library_id'), isFalse);
    expect(requests.single.headers['X-Profile-Id'], 'p-owner');

    requests.clear();
    final next = await c.fetchPersonalListPage(SiloPersonalList.favorites, offset: 2, limit: 2);
    expect(next.items.map((i) => i.id), ['movie:t2', 'movie:t3']);
    expect(requests.single.url.queryParameters['cursor'], 'c2', reason: 'the next page reuses next_cursor');
  });

  test('the watchlist sends its source, the media filter and the chosen sort', () async {
    final c = client(catalog);
    final page = await c.fetchPersonalListPage(
      SiloPersonalList.watchlist,
      offset: 0,
      limit: 40,
      kind: MediaKind.show,
      sort: const LibrarySort(field: 'title', direction: LibrarySortDirection.ascending),
    );
    expect(page.items.map((i) => i.id).first, 'series:t0');
    final q = requests.single.url.queryParameters;
    expect(q['source'], 'watchlist');
    expect(q['type'], 'series');
    expect(q['sort'], 'title');

    requests.clear();
    await c.fetchPersonalListPage(
      SiloPersonalList.watchlist,
      offset: 0,
      limit: 40,
      kind: MediaKind.movie,
      sort: const LibrarySort(field: 'addedAt'),
    );
    expect(requests.single.url.queryParameters['type'], 'movie');
    expect(requests.single.url.queryParameters['sort'], '-added_at');
  });

  test('a list failure reaches the caller', () async {
    final c = client((_) => _json({'type': 'server_error', 'status': 500}, 500));
    expect(() => c.fetchPersonalListPage(SiloPersonalList.favorites, offset: 0, limit: 40), throwsA(anything));
  });

  group('personal list sorts', () {
    test('leave out Progress, Date Viewed and Plays (the server refuses personalized sorts there)', () {
      final keys = [for (final f in SiloSortOptions.forPersonalList(shownRatingSources: const {})) f.key];
      expect(keys, containsAll(['title', 'addedAt', 'releaseDate', 'year', 'rating', 'runtime']));
      expect(keys, isNot(contains('progress')));
      expect(keys, isNot(contains('dateViewed')));
      expect(keys, isNot(contains('plays')));
      // Fields only one media type has are not offered for a list of both.
      expect(keys, isNot(contains('latestEpisodeAdded')));
      expect(keys, isNot(contains('author')));
    });

    test('Rotten Tomatoes only while the server shows it', () async {
      final c = client((request) {
        if (request.url.path == '/api/v2/capabilities/ratings') {
          return _json({
            'state': 'available',
            'sources': [
              {'source': 'rt_critic'},
            ],
          });
        }
        return _json({'type': 'not_found'}, 404);
      });
      final sorts = await c.fetchPersonalListSortOptions();
      final keys = sorts.map((s) => s.key).toList();
      expect(keys, contains('ratingRtCritic'));
      expect(keys, isNot(contains('ratingRtAudience')));
      expect(keys, isNot(contains('plays')));
    });
  });
}
