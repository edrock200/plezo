import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
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

  test('audio and reading items are not mapped', () {
    expect(SiloMappers.item({'content_id': 'audiobook:x', 'type': 'audiobook'}, _ctx), isNull);
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
}
