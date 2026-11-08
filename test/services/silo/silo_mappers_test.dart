import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_item_types.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/silo/silo_mappers.dart';

final _ctx = SiloMappingContext(
  serverId: 'srv-1',
  serverName: 'Home Silo',
  resolveUrl: (url) => url.startsWith('/') ? 'https://silo.example.com$url' : url,
);

void main() {
  test('maps a continue-watching movie card', () {
    final item = SiloMappers.item({
      'content_id': 'movie:heat-1995',
      'type': 'movie',
      'title': 'Heat',
      'year': 1995,
      'runtime': 170,
      'genres': ['Crime'],
      'content_rating': 'R',
      'rating_imdb': 8.3,
      'rating_rt_critic': 88,
      'position_seconds': 1200.5,
      'duration_seconds': 10200,
      'progress_updated_at': '2026-01-02T03:04:05.000Z',
      'poster_url': '/api/v2/artwork/p1?exp=1&sig=a',
      'backdrop_url': 'https://cdn.example.com/b.jpg',
      'item_source': 'in_progress',
      'user_state': {'played': false, 'is_favorite': true, 'in_watchlist': true},
    }, _ctx)!;

    expect(item, isA<SiloMediaItem>());
    expect(item.kind, MediaKind.movie);
    expect(item.id, 'movie:heat-1995');
    expect(item.serverId, 'srv-1');
    expect(item.thumbPath, 'https://silo.example.com/api/v2/artwork/p1?exp=1&sig=a');
    expect(item.artPath, 'https://cdn.example.com/b.jpg');
    expect(item.durationMs, 10200000);
    expect(item.viewOffsetMs, 1200500);
    expect(item.viewCount, 0);
    expect(item.isFavorite, isTrue);
    expect(item.ratings!.map((r) => r.source), ['imdb', 'rottenTomatoesCritic']);
    expect(item.ratings!.last.value, closeTo(8.8, 0.001));
    expect(item.lastViewedAt, DateTime.parse('2026-01-02T03:04:05.000Z').millisecondsSinceEpoch ~/ 1000);
  });

  test('an episode card links to its series and a synthetic season', () {
    final item = SiloMappers.item({
      'content_id': 'episode:orbital-s01e03',
      'type': 'episode',
      'title': 'Chapter 3',
      'series_id': 'series:orbital',
      'series_title': 'Orbital',
      'season_number': 1,
      'episode_number': 3,
      'still_url': 'https://cdn/still.jpg',
      'poster_url': 'https://cdn/poster.jpg',
      'user_state': {'played': true},
    }, _ctx)!;

    expect(item.kind, MediaKind.episode);
    expect(item.title, 'Chapter 3');
    expect(item.grandparentId, 'series:orbital');
    expect(item.grandparentTitle, 'Orbital');
    expect(item.parentIndex, 1);
    expect(item.index, 3);
    expect(item.thumbPath, 'https://cdn/still.jpg');
    expect(item.viewCount, 1);
    expect(SiloMappers.parseSyntheticSeasonId(item.parentId!), (seriesId: 'series:orbital', seasonNumber: 1));
  });

  group('episode parent artwork (series_*/season_poster_url)', () {
    Map<String, dynamic> episode(Map<String, dynamic> extra) => {
      'content_id': 'episode:orbital-s01e03',
      'type': 'episode',
      'series_id': 'series:orbital',
      'season_number': 1,
      'episode_number': 3,
      'still_url': 'https://cdn/still.jpg',
      'poster_url': 'https://cdn/poster.jpg',
      'backdrop_url': 'https://cdn/episode-backdrop.jpg',
      'user_state': {'played': false},
      ...extra,
    };

    test('series and season art feed the parent fields and the episode hero', () {
      final item = SiloMappers.item(
        episode({
          'series_poster_url': '/api/v2/artwork/series-poster?exp=1&sig=a',
          'series_poster_thumbhash': 'SP',
          'series_backdrop_url': 'https://cdn/series-backdrop.jpg',
          'series_backdrop_thumbhash': 'SB',
          'season_poster_url': 'https://cdn/season-poster.jpg',
          'season_poster_thumbhash': 'SN',
        }),
        _ctx,
      )!;

      expect(item.thumbPath, 'https://cdn/still.jpg');
      expect(item.grandparentThumbPath, 'https://silo.example.com/api/v2/artwork/series-poster?exp=1&sig=a');
      expect(item.parentThumbPath, 'https://cdn/season-poster.jpg');
      expect(item.grandparentArtPath, 'https://cdn/series-backdrop.jpg');
      expect(item.heroBackdropPaths, ['https://cdn/series-backdrop.jpg']);
      expect(item.heroArtCandidates(containerAspectRatio: 16 / 9).first, 'https://cdn/series-backdrop.jpg');
      // The own backdrop stays the episode's; the series art is never a still,
      // so the spoiler-safe art is the series backdrop.
      expect(item.artPath, 'https://cdn/episode-backdrop.jpg');
      expect(item.spoilerSafeArt, 'https://cdn/series-backdrop.jpg');
      expect(item.shouldHideSpoiler, isTrue);
    });

    test('the season poster falls back to the series poster', () {
      final item = SiloMappers.item(episode({'series_poster_url': 'https://cdn/series-poster.jpg'}), _ctx)!;
      expect(item.parentThumbPath, 'https://cdn/series-poster.jpg');
      expect(item.grandparentThumbPath, 'https://cdn/series-poster.jpg');
      expect(item.grandparentArtPath, 'https://cdn/episode-backdrop.jpg');
    });

    test('older servers without the fields keep poster_url and backdrop_url', () {
      final item = SiloMappers.item(episode({'series_backdrop_url': '  '}), _ctx)!;
      expect(item.grandparentThumbPath, 'https://cdn/poster.jpg');
      expect(item.parentThumbPath, 'https://cdn/poster.jpg');
      expect(item.grandparentArtPath, 'https://cdn/episode-backdrop.jpg');
      expect(item.grandparentBackdropPaths, isNull);
    });

    test('movies ignore stray series artwork', () {
      final item = SiloMappers.item({
        'content_id': 'movie:heat-1995',
        'type': 'movie',
        'poster_url': 'https://cdn/poster.jpg',
        'series_backdrop_url': 'https://cdn/series-backdrop.jpg',
      }, _ctx)!;
      expect(item.grandparentArtPath, isNull);
      expect(item.grandparentThumbPath, isNull);
    });
  });

  test('synthetic season ids survive colons in the series id', () {
    final id = SiloMappers.syntheticSeasonId('series:a:b', 0);
    expect(SiloMappers.parseSyntheticSeasonId(id), (seriesId: 'series:a:b', seasonNumber: 0));
    expect(SiloMappers.parseSyntheticSeasonId('season:series:a-1'), isNull);
  });

  test('a series reports watched episodes from unplayed_count', () {
    final item = SiloMappers.item({
      'content_id': 'series:orbital',
      'type': 'series',
      'title': 'Orbital',
      'season_count': 3,
      'episode_count': 24,
      'user_data': {'unplayed_count': 20},
    }, _ctx)!;
    expect(item.kind, MediaKind.show);
    expect(item.leafCount, 24);
    expect(item.viewedLeafCount, 4);
    expect(item.childCount, 3);
  });

  group('watch state as Silo sends it', () {
    // Leaf `user_data` comes from a progress row: `watched_count` and
    // `unplayed_count` are always present and always 0 on a movie or episode.
    Map<String, dynamic> leafUserData({required bool played, double position = 0}) => {
      'played': played,
      'is_in_progress': position > 0,
      'position_seconds': position,
      'duration_seconds': 3000,
      'watched_count': 0,
      'unplayed_count': 0,
      'in_progress_count': 0,
    };

    test('a played movie detail is watched; an unplayed one is not', () {
      final watched = SiloMappers.item({
        'content_id': 'movie:heat-1995',
        'type': 'movie',
        'title': 'Heat',
        'runtime': 170,
        'user_state': {'played': false, 'is_favorite': false, 'in_watchlist': false, 'not_interested': false},
        'user_data': leafUserData(played: true),
      }, _ctx)!;
      expect(watched.viewCount, 1);
      expect(watched.isWatched, isTrue);

      final unwatched = SiloMappers.item({
        'content_id': 'movie:ronin-1998',
        'type': 'movie',
        'title': 'Ronin',
        'user_data': leafUserData(played: false, position: 900),
      }, _ctx)!;
      expect(unwatched.viewCount, 0);
      expect(unwatched.isWatched, isFalse);
      expect(unwatched.hasActiveProgress, isTrue);
    });

    test('a movie card is watched from user_state.played', () {
      Map<String, dynamic> card(bool played) => {
        'content_id': 'movie:heat-1995',
        'type': 'movie',
        'title': 'Heat',
        'user_state': {'played': played, 'is_favorite': false, 'in_watchlist': false, 'not_interested': false},
      };
      expect(SiloMappers.item(card(true), _ctx)!.isWatched, isTrue);
      expect(SiloMappers.item(card(false), _ctx)!.isWatched, isFalse);
    });

    test('episode rows of a season list carry their own played flag', () {
      final rows = SiloMappers.items([
        {
          'content_id': 'episode:orbital-s01e01',
          'type': 'episode',
          'season_number': 1,
          'episode_number': 1,
          'title': 'Pilot',
          'runtime': 50,
          'user_data': leafUserData(played: true),
        },
        {
          'content_id': 'episode:orbital-s01e02',
          'type': 'episode',
          'season_number': 1,
          'episode_number': 2,
          'title': 'Second',
          'runtime': 50,
        },
      ], _ctx);
      expect(rows.map((e) => e.isWatched), [true, false]);
      expect(rows.first.unwatchedCount, isNull, reason: 'episodes have no unwatched badge');
    });

    test('a season counts its unwatched episodes from the rollup', () {
      final season = SiloMappers.item({
        'content_id': 'season:orbital-s01',
        'type': 'season',
        'series_id': 'series:orbital',
        'season_number': 1,
        'title': 'Season 1',
        'episode_count': 10,
        'user_data': {'played': false, 'watched_count': 3, 'unplayed_count': 7, 'in_progress_count': 1},
      }, _ctx)!;
      expect(season.leafCount, 10);
      expect(season.viewedLeafCount, 3);
      expect(season.unwatchedCount, 7);
      expect(season.isWatched, isFalse);
      expect(season.isPartiallyWatched, isTrue);

      final done = SiloMappers.item({
        'content_id': 'season:orbital-s02',
        'type': 'season',
        'series_id': 'series:orbital',
        'season_number': 2,
        'episode_count': 8,
        'user_data': {'played': true, 'watched_count': 8, 'unplayed_count': 0, 'in_progress_count': 0},
      }, _ctx)!;
      expect(done.isWatched, isTrue);
      expect(done.unwatchedCount, 0);
    });

    test('a series detail without episode_count counts episodes from the rollup', () {
      final series = SiloMappers.item({
        'content_id': 'series:orbital',
        'type': 'series',
        'title': 'Orbital',
        'season_count': 2,
        'user_data': {'played': false, 'watched_count': 11, 'unplayed_count': 7, 'in_progress_count': 0},
      }, _ctx)!;
      expect(series.leafCount, 18);
      expect(series.viewedLeafCount, 11);
      expect(series.unwatchedCount, 7);
      expect(series.isWatched, isFalse);

      final finished = SiloMappers.item({
        'content_id': 'series:orbital',
        'type': 'series',
        'title': 'Orbital',
        'user_data': {'played': true, 'watched_count': 18, 'unplayed_count': 0, 'in_progress_count': 0},
      }, _ctx)!;
      expect(finished.isWatched, isTrue);
      expect(finished.unwatchedCount, 0);
    });

    test('a series card has only user_state: watched mark, no count', () {
      Map<String, dynamic> card(bool played) => {
        'content_id': 'series:orbital',
        'type': 'series',
        'title': 'Orbital',
        'user_state': {'played': played, 'is_favorite': false, 'in_watchlist': false, 'not_interested': false},
      };
      final watched = SiloMappers.item(card(true), _ctx)!;
      expect(watched.isWatched, isTrue);
      final unwatched = SiloMappers.item(card(false), _ctx)!;
      expect(unwatched.isWatched, isFalse);
      expect(unwatched.unwatchedCount, isNull);
      expect(unwatched.withWatchedFlag(true).isWatched, isTrue);
    });
  });

  test('music and reading items are not mapped', () {
    expect(SiloMappers.item({'content_id': 'ebook:x', 'type': 'ebook'}, _ctx), isNull);
    expect(SiloMappers.item({'content_id': 'track:x', 'type': 'track'}, _ctx), isNull);
    expect(SiloMappers.item({'type': 'movie'}, _ctx), isNull);
  });

  test('versions carry tracks with Silo track ids', () {
    final version = SiloMappers.version({
      'file_id': '43',
      'resolution': '2160p',
      'codec_video': 'hevc',
      'container': 'mkv',
      'bitrate': 24000,
      'duration': 7200,
      'audio_tracks': [
        {'index': 0, 'language': 'eng', 'codec': 'eac3', 'channels': 6, 'default': true},
        {'index': 1, 'language': 'spa', 'codec': 'aac', 'channels': 2},
      ],
      'subtitle_tracks': [
        {'index': 0, 'language': 'eng', 'codec': 'srt', 'forced': true},
      ],
    })!;
    expect(version.id, '43');
    expect(version.height, 2160);
    expect(version.videoResolution, '4k');
    expect(version.parts.single.durationMs, 7200000);
    expect(version.parts.single.streams.map((s) => s.id), ['file:43:audio:0', 'file:43:audio:1', 'file:43:subtitle:0']);
  });

  test('library family follows the free-text type', () {
    expect(SiloMappers.libraryFamily('Movies'), SiloLibraryFamily.video);
    expect(SiloMappers.libraryFamily('mixed'), SiloLibraryFamily.video);
    expect(SiloMappers.libraryFamily('audiobooks'), SiloLibraryFamily.audio);
    expect(SiloMappers.libraryFamily('manga'), SiloLibraryFamily.reading);
    expect(SiloMappers.libraryKind('tv'), MediaKind.show);
  });

  test('markers prefer marker_segments, then item-level objects', () {
    final fromSegments = SiloMappers.markers(
      {
        'intro': {'start_seconds': 1, 'end_seconds': 2},
      },
      {
        'marker_segments': [
          {'kind': 'intro', 'start_seconds': 30, 'end_seconds': 90},
          {'kind': 'credits', 'start_seconds': 3000, 'end_seconds': 3100},
        ],
      },
    );
    expect(fromSegments.map((m) => (m.type, m.startTimeOffset, m.endTimeOffset)), [
      ('intro', 30000, 90000),
      ('credits', 3000000, 3100000),
    ]);
    final fromDetail = SiloMappers.markers({
      'intro': {'start': 5, 'end': 65},
    }, null);
    expect(fromDetail.single.startTimeOffset, 5000);
  });

  test('every marker occurrence is its own marker, in source-time order (Silo Android #694)', () {
    final markers = SiloMappers.markers(
      {
        'credits': {'start_seconds': 2975.5, 'end_seconds': 3167.4},
      },
      {
        'credits': {'start_seconds': 2975.5, 'end_seconds': 3167.4},
        'marker_segments': [
          {'kind': 'credits', 'start_seconds': 3189, 'end_seconds': 3300},
          {'kind': 'intro', 'start_seconds': 30, 'end_seconds': 90},
          {'kind': 'credits', 'start_seconds': 2975.5, 'end_seconds': 3167.4},
          {'kind': 'commercial', 'start_seconds': 100, 'end_seconds': 120},
          {'kind': 'recap', 'start_seconds': 50, 'end_seconds': 40},
        ],
      },
    );
    expect(markers.map((m) => (m.id, m.type, m.startTimeOffset, m.endTimeOffset)), [
      (0, 'intro', 30000, 90000),
      (1, 'credits', 2975500, 3167400),
      (2, 'credits', 3189000, 3300000),
    ]);
    // Each skip ends at its own range: the scene between the two credits
    // ranges is not inside either marker.
    expect(markers.any((m) => m.containsPosition(const Duration(seconds: 3175))), isFalse);
  });

  group('box sets (Silo Android #646)', () {
    final card = {
      'content_id': 'box_set:1:1241',
      'type': 'box_set',
      'title': 'The Paper Collection',
      'box_set': {
        'id': '1241',
        'library_id': '1',
        'title': 'The Paper Collection',
        'overview': 'Two films.',
        'poster_url': '/img/p.jpg',
        'backdrop_url': '/img/b.jpg',
        'movie_count': 3,
        'played_count': 1,
        'first_year': 2001,
        'last_year': 2011,
      },
    };

    test('a box set card of a grouped browse is a collection named by library and box set', () {
      final item = SiloMappers.item(card, _ctx, libraryTitle: 'Movies')!;
      expect(item.kind, MediaKind.collection);
      expect(item.id, 'silo-boxset:1:1241');
      expect(SiloMappers.parseBoxSetId(item.id), (libraryId: '1', boxSetId: '1241'));
      expect(SiloMappers.isBoxSet(item), isTrue);
      expect(item.title, 'The Paper Collection');
      expect(item.summary, 'Two films.');
      expect(item.thumbPath, 'https://silo.example.com/img/p.jpg');
      expect(item.artPath, 'https://silo.example.com/img/b.jpg');
      expect(item.libraryId, '1');
      expect(item.libraryTitle, 'Movies');
      expect(item.leafCount, 3);
      expect(item.viewedLeafCount, 1);
      expect(item.isPartiallyWatched, isTrue);
    });

    test('a box set card without its box set is dropped', () {
      expect(SiloMappers.item({'content_id': 'x', 'type': 'box_set'}, _ctx), isNull);
      expect(SiloMappers.parseBoxSetId('silo-collection:1:2'), isNull);
      expect(SiloMappers.parseBoxSetId('silo-boxset:1:'), isNull);
    });

    test('Play starts the first movie not watched, else the first', () {
      MediaItem movie(String id, {bool watched = false, int? offset}) => MediaItem.silo(
        id: id,
        kind: MediaKind.movie,
        viewCount: watched ? 1 : 0,
        viewOffsetMs: offset,
        durationMs: 6000000,
      );
      expect(SiloMappers.boxSetStartIndex([movie('a', watched: true), movie('b', offset: 60000), movie('c')]), 1);
      expect(SiloMappers.boxSetStartIndex([movie('a', watched: true), movie('b', watched: true)]), 0);
      expect(SiloMappers.boxSetStartIndex(const []), 0);
    });
  });

  test('resume points follow Silo\'s TV app thresholds and survive a re-watch', () {
    expect(SiloMappers.resumeOffsetMs(null, 600000), isNull);
    expect(SiloMappers.resumeOffsetMs(30, 600000), isNull);
    expect(SiloMappers.resumeOffsetMs(31, 600000), 31000);
    expect(SiloMappers.resumeOffsetMs(596, 600000), isNull);
    expect(SiloMappers.resumeOffsetMs(594, 600000), 594000);
    expect(SiloMappers.resumeOffsetMs(120, null), 120000);

    final item = SiloMappers.item({
      'content_id': 'movie:m1',
      'type': 'movie',
      'title': 'Seen before',
      'duration_seconds': 6000,
      'user_data': {'played': true, 'position_seconds': 1500, 'watched_count': 0, 'unplayed_count': 0},
    }, _ctx)!;
    expect(item.viewCount, 1);
    expect(item.isWatched, isTrue);
    expect(item.viewOffsetMs, 1500000);
  });

  group('length (0 means unknown)', () {
    test('a detail with runtime 0 and an unmeasured file has no length', () {
      final item = SiloMappers.item({
        'content_id': 'movie:heat-1995',
        'type': 'movie',
        'title': 'Heat',
        'runtime': 0,
        'versions': [
          {'file_id': '120', 'duration': 0},
        ],
      }, _ctx)!;
      expect(item.durationMs, isNull);
      expect(item.mediaVersions!.single.parts.single.durationMs, isNull);
    });

    test("the file's measured length comes before the catalog runtime", () {
      final item = SiloMappers.item({
        'content_id': 'movie:heat-1995',
        'type': 'movie',
        'title': 'Heat',
        'runtime': 170,
        'versions': [
          {'file_id': '120', 'duration': 10237},
        ],
      }, _ctx)!;
      expect(item.durationMs, 10237000);
    });

    test('runtime minutes when nothing was measured; zero progress lengths are skipped', () {
      final item = SiloMappers.item({
        'content_id': 'episode:x-s01e01',
        'type': 'episode',
        'title': 'Pilot',
        'air_date': '2022-02-18',
        'runtime': 57,
        'duration_seconds': 0,
        'user_data': {'duration_seconds': 0, 'played': false},
      }, _ctx)!;
      expect(item.durationMs, 57 * 60000);
      expect(item.originallyAvailableAt, '2022-02-18');
    });
  });

  test("an episode is dated by its air date, not a release date it inherits", () {
    final item = SiloMappers.item({
      'content_id': 'episode:x-s01e02',
      'type': 'episode',
      'title': 'Second',
      'air_date': '2022-02-25',
      'release_date': '2022-02-18',
    }, _ctx)!;
    expect(item.originallyAvailableAt, '2022-02-25');
  });
}
