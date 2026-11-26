import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/tofa/tofa_mappers.dart';

import 'tofa_fixtures.dart';

const _ctx = TofaMappingContext(serverId: 'srv-1', serverName: 'Tofa');

void main() {
  group('ticks', () {
    test('are 100 ns: 10,000 per millisecond, 10,000,000 per second', () {
      expect(tofaTicksPerMillisecond, 10000);
      expect(tofaTicksFromDuration(const Duration(seconds: 1)), 10000000);
      expect(tofaTicksFromDuration(const Duration(milliseconds: 1500)), 15000000);
      expect(tofaTicksFromDuration(Duration.zero), 0);
      expect(tofaDurationFromTicks(36000000000), const Duration(hours: 1));
      expect(tofaDurationFromTicks(15), const Duration(microseconds: 1));
    });

    test('round-trip at millisecond precision', () {
      for (final ms in [0, 1, 999, 123456789]) {
        expect(tofaDurationFromTicks(tofaTicksFromDuration(Duration(milliseconds: ms))).inMilliseconds, ms);
      }
    });
  });

  group('ids', () {
    test('season and episode ids name their title and round-trip', () {
      final season = TofaMappers.seasonItemId('show-1', 'sea-1');
      final episode = TofaMappers.episodeItemId('show-1', 'e-1');
      expect(TofaMappers.parseSeasonId(season), (mediaId: 'show-1', childId: 'sea-1'));
      expect(TofaMappers.parseEpisodeId(episode), (mediaId: 'show-1', childId: 'e-1'));
      expect(TofaMappers.mediaIdOf(season), 'show-1');
      expect(TofaMappers.mediaIdOf(episode), 'show-1');
      expect(TofaMappers.mediaIdOf('m-1'), 'm-1');
      expect(TofaMappers.parseSeasonId(episode), isNull);
      expect(TofaMappers.parseEpisodeId('tofa-episode:broken'), isNull);
    });

    test('paths saved by earlier versions are still recognised', () {
      expect(TofaMappers.parseArtworkPath('tofa-artwork:m-1/backdrop_thumb'), (mediaId: 'm-1', kind: 'backdrop_thumb'));
      expect(TofaMappers.parseArtworkPath('/posters/m-1.jpg'), isNull);
    });
  });

  group('list rows', () {
    test('a movie row', () {
      final item = TofaMappers.summary(mediaSummary('m-1', watched: true), _ctx)!;
      expect(item.backend, MediaBackend.tofa);
      expect(item.kind, MediaKind.movie);
      expect(item.year, 2021);
      expect(item.durationMs, 100 * 60000);
      expect(item.isWatched, isTrue);
      expect(item.thumbPath, '/posters/m-1.jpg', reason: 'the raw path, drawn through /cache/');
      expect(item.artPath, '/backdrops/m-1.jpg');
      expect(item.clearLogoPath, isNull);
      expect(item.libraryId, 'lib-1');
      expect(item.raw?[TofaRaw.tmdbId], 42);
      expect(item.ratings!.single.source, 'imdb');
    });

    test('a series row shows the episodes left as its unwatched count', () {
      final json = mediaSummary('show-1', type: 'tv')..['unwatched_episode_count'] = 3;
      final item = TofaMappers.summary(json, _ctx)!;
      expect(item.kind, MediaKind.show);
      expect(item.unwatchedCount, 3);
      expect(item.isWatched, isFalse);
    });

    test('a movie part-way through gets an approximate resume point from the percentage', () {
      final json = mediaSummary('m-1')
        ..['watch_mark'] = {'state': 'none', 'progress_percent': 50, 'episodes_left': null};
      expect(TofaMappers.summary(json, _ctx)!.viewOffsetMs, 50 * 60000);
    });

    test('an unknown media type is left out', () {
      expect(TofaMappers.summary(mediaSummary('x', type: 'podcast'), _ctx), isNull);
    });
  });

  group('details', () {
    test('watch state comes from the files: completed wins, else the newest position', () {
      final state = TofaMappers.fileWatchState(
        ['a', 'b'],
        {
          'a': progressRow('a', positionMs: 1000, at: '2026-11-01T00:00:00Z'),
          'b': progressRow('b', positionMs: 2000, at: '2026-11-02T00:00:00Z'),
        },
      );
      expect(state.watched, isFalse);
      expect(state.offsetMs, 2000);
      final watched = TofaMappers.fileWatchState(
        ['a', 'b'],
        {'a': progressRow('a', completed: true), 'b': progressRow('b', positionMs: 2000)},
      );
      expect(watched.watched, isTrue);
      expect(watched.offsetMs, isNull);
    });

    test('later parts of a multi-part set and unavailable files are not playable versions', () {
      final files = TofaMappers.playableFiles([
        mediaFile('f-1')..['part_number'] = 1,
        mediaFile('f-2')..['part_number'] = 2,
        mediaFile('f-3')..['available'] = false,
        mediaFile('f-4'),
      ]);
      expect(files.map((f) => f['id']), ['f-1', 'f-4']);
    });

    test('a file version carries its streams and bitrate in kbps', () {
      final version = TofaMappers.version(mediaFile('f-1'))!;
      expect(version.id, 'f-1');
      expect(version.bitrate, 25000);
      expect(version.videoCodec, 'hevc');
      expect(version.parts.single.durationMs, 6000000);
      expect(version.parts.single.streams.map((s) => s.kind.name), ['video', 'audio', 'subtitle']);
    });

    test('a series counts episodes of numbered seasons only', () {
      final show = TofaMappers.detail(
        showDetail(),
        _ctx,
        progress: {'f-e2': progressRow('f-e2', completed: true), 'f-sp': progressRow('f-sp', completed: true)},
      )!;
      expect(show.kind, MediaKind.show);
      expect(show.leafCount, 2);
      expect(show.viewedLeafCount, 1);
      expect(show.childCount, 2);
      expect(show.isPartiallyWatched, isTrue);
    });

    test('an episode without a still URL falls back to the series artwork', () {
      final show = TofaMappers.detail(showDetail(), _ctx)!;
      final season = (showDetail()['seasons'] as List)[1] as Map<String, dynamic>;
      final episodes = TofaMappers.episodes(season, show, _ctx);
      expect(episodes.first.thumbPath, '/sb.jpg', reason: 'no still, no backdrop_thumb: the series backdrop');
      expect(episodes.first.grandparentThumbPath, '/sp.jpg');
    });

    test('mapped items survive a JSON round trip as Tofa items', () {
      final item = TofaMappers.detail(movieDetail(), _ctx)!;
      final restored = MediaItem.fromJson(item.toJson());
      expect(restored, isA<TofaMediaItem>());
      expect(restored.backend, MediaBackend.tofa);
      expect(TofaMappers.fileIdsOf(restored), ['f-1']);
    });
  });

  test("ratings keep IMDb, Rotten Tomatoes, Metacritic and Tofa's own scores", () {
    final item = TofaMappers.summary({
      ...mediaSummary('m-1'),
      'rotten_tomatoes_score': 91,
      'metacritic_score': 77,
      'tofa_critics_rating': 85,
      'tofa_audience_rating': 300,
    }, _ctx)!;
    expect(item.ratings!.map((r) => r.source), ['imdb', 'rottenTomatoesCritic', 'metacritic', 'tofaCritics']);
  });
}
