import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/silo/silo_mappers.dart';

void main() {
  group('a server stream started part-way into the source', () {
    test('opens at the resume point on the item clock, laid at the stream origin', () {
      final timing = playbackOpenTiming(
        isTranscoding: true,
        resumePosition: const Duration(seconds: 1500),
        durationMs: 2700 * 1000,
        streamOffset: const Duration(milliseconds: 1496250),
      );
      expect(timing.timelineOffset, const Duration(milliseconds: 1496250));
      // The player converts to stream time at its boundary: 1500 - 1496.25
      // = the plan's player_start_seconds.
      expect(timing.mediaStart, const Duration(seconds: 1500));
      expect(timing.mediaStart! - timing.timelineOffset, const Duration(milliseconds: 3750));
      // The seek bar spans the whole item, not the stream's remainder.
      expect(timing.timelineDuration, const Duration(seconds: 2700));
    });

    test('never opens before the origin', () {
      final timing = playbackOpenTiming(
        isTranscoding: true,
        resumePosition: const Duration(seconds: 10),
        durationMs: 2700 * 1000,
        streamOffset: const Duration(seconds: 1496),
      );
      expect(timing.mediaStart, const Duration(seconds: 1496));
    });

    test('a stream on the source clock keeps the old timing', () {
      final timing = playbackOpenTiming(
        isTranscoding: false,
        resumePosition: const Duration(seconds: 1500),
        durationMs: 2700 * 1000,
      );
      expect(timing.timelineOffset, Duration.zero);
      expect(timing.mediaStart, const Duration(seconds: 1500));
      expect(timing.timelineDuration, isNull);
    });

    test('a seek before the origin needs a new stream; one at it does not', () {
      const origin = Duration(seconds: 1496);
      expect(streamStartsAfter(origin, const Duration(seconds: 1400)), isTrue);
      expect(streamStartsAfter(origin, const Duration(milliseconds: 1495500)), isFalse);
      expect(streamStartsAfter(origin, const Duration(seconds: 1600)), isFalse);
      expect(streamStartsAfter(Duration.zero, Duration.zero), isFalse);
    });
  });

  group('SiloMappers timeline helpers', () {
    test('planTimelineOffset reads timeline_offset_seconds and ignores junk', () {
      expect(
        SiloMappers.planTimelineOffset({
          'timeline': {'timeline_offset_seconds': 1496.25},
        }),
        const Duration(milliseconds: 1496250),
      );
      expect(
        SiloMappers.planTimelineOffset({
          'timeline': {'timeline_offset_seconds': 0},
        }),
        Duration.zero,
      );
      expect(
        SiloMappers.planTimelineOffset({
          'timeline': {'timeline_offset_seconds': -3},
        }),
        Duration.zero,
      );
      expect(
        SiloMappers.planTimelineOffset({
          'timeline': {'timeline_offset_seconds': '12'},
        }),
        Duration.zero,
      );
      expect(SiloMappers.planTimelineOffset({}), Duration.zero);
      expect(SiloMappers.planTimelineOffset(null), Duration.zero);
    });

    test('sidecarForTimeline asks for shifted WebVTT only when there is an offset', () {
      const url = '/stream/s/subtitles/1.ass?file_id=42&timestamp_offset=5';
      expect(SiloMappers.sidecarForTimeline(url, Duration.zero), (url: url, codec: null));
      final shifted = SiloMappers.sidecarForTimeline(url, const Duration(seconds: 90));
      final uri = Uri.parse(shifted.url);
      expect(uri.path, '/stream/s/subtitles/1.vtt');
      expect(uri.queryParametersAll['timestamp_offset'], ['-90.0']);
      expect(uri.queryParameters['file_id'], '42');
      expect(shifted.codec, 'webvtt');
    });
  });
}
