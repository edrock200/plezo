import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/services/silo/silo_playback_caps.dart';

void main() {
  test('HDR originals can direct-play without a display probe', () {
    final context = SiloPlaybackCaps.playbackContext(appVersion: '1.0', formFactor: 'tv');
    final output = context['output']! as Map<String, Object?>;
    final display = output['display']! as Map<String, Object?>;
    final deliveries = context['deliveries']! as Map<String, Object?>;
    final original = deliveries['original_http']! as Map<String, Object?>;
    final hls = deliveries['hls']! as Map<String, Object?>;

    // `display` is unknown, so `hdr_details` must travel with it and the
    // original route carries the client-managed dynamic-range claim.
    expect(display['hdr_evidence'], 'unknown');
    expect(output['hdr_details'], containsPair('hdr10', true));
    expect(original['validated_claims'], [SiloPlaybackCaps.clientManagedDynamicRangeClaim]);
    // The claim is valid only on original_http.
    expect(hls['validated_claims'], isEmpty);
  });

  test('HEVC is declared for decode and hardware when the device accepts it', () {
    final caps = SiloPlaybackCaps.clientCapabilities();
    expect(caps['video_evidence'], 'declared');
    expect(caps['codecs_video'], containsAll(['h264', 'hevc']));
    expect(caps['codecs_video_hardware'], containsAll(['h264', 'hevc']));
    expect(caps['max_resolution'], '2160p');
  });

  test('quality preference never asks for the original, as Silo\'s apps', () {
    expect(SiloPlaybackCaps.qualityPreference(TranscodeQualityPreset.original), 'auto');
    expect(SiloPlaybackCaps.qualityPreference(TranscodeQualityPreset.p1080_8mbps), '1080p');
    expect(SiloPlaybackCaps.qualityPreference(TranscodeQualityPreset.p720_4mbps), '720p');
    expect(SiloPlaybackCaps.qualityPreference(TranscodeQualityPreset.p480_1_5mbps), 'auto');
  });

  test('an original answer to a capped preset is a refusal only when the source exceeds it', () {
    const preset = TranscodeQualityPreset.p720_4mbps;
    // Fits the preset: the original is the right answer.
    expect(SiloPlaybackCaps.refusedCappedPreset(preset, {'height': 720, 'bitrate_kbps': 3000}), isFalse);
    // Unknown size: nothing to tell the user.
    expect(SiloPlaybackCaps.refusedCappedPreset(preset, {'media_file_id': '1'}), isFalse);
    expect(SiloPlaybackCaps.refusedCappedPreset(preset, null), isFalse);
    // Larger than the preset, yet played unchanged.
    expect(SiloPlaybackCaps.refusedCappedPreset(preset, {'height': 2160, 'bitrate_kbps': 3000}), isTrue);
    expect(SiloPlaybackCaps.refusedCappedPreset(preset, {'height': 720, 'bitrate_kbps': 9000}), isTrue);
    expect(
      SiloPlaybackCaps.refusedCappedPreset(TranscodeQualityPreset.original, {'height': 2160, 'bitrate_kbps': 90000}),
      isFalse,
    );
  });
}
