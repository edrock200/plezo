import 'dart:io' show Platform;

import '../../models/transcode_quality_preset.dart';
import '../video_decode_capabilities.dart';

/// What Plezy's player (libmpv, or ExoPlayer on Android with an mpv
/// fallback) can play, expressed as Silo's playback protocol v3
/// `client_capabilities` / `client_playback_context`.
///
/// The tier is `declared`: the server then matches only against the flat
/// codec/container lists and never requires per-decoder `video_decode[]`
/// evidence. mpv decodes nearly everything in software, so the lists are
/// broad and the server direct-plays whenever the file allows; transcoding is
/// left to a capped quality preset.
abstract final class SiloPlaybackCaps {
  static const protocolVersion = 3;

  static const clientFeatures = <String>['playback_plan_v3', 'direct_stream_resume_v1'];

  static const _containers = <String>[
    'mkv',
    'matroska',
    'webm',
    'mp4',
    'm4v',
    'mov',
    'avi',
    'ts',
    'mpegts',
    'm2ts',
    'wmv',
    'asf',
    'flv',
    'ogg',
    '3gp',
  ];

  static const _audioCodecs = <String>[
    'aac',
    'ac3',
    'eac3',
    'truehd',
    'dts',
    'dca',
    'flac',
    'opus',
    'vorbis',
    'mp3',
    'mp2',
    'alac',
    'pcm',
    'pcm_s16le',
    'pcm_s24le',
    'wmav2',
    'wmapro',
  ];

  static List<String> videoCodecs() {
    final hevc = VideoDecodeCapabilities.accepts(RankedVideoCodec.hevc);
    final av1 = VideoDecodeCapabilities.accepts(RankedVideoCodec.av1);
    return ['h264', if (hevc) 'hevc', if (av1) 'av1', 'vp9', 'vp8', 'mpeg4', 'mpeg2video', 'vc1'];
  }

  /// Silo `quality_preference` for a Plezy preset.
  static String qualityPreference(TranscodeQualityPreset preset) {
    if (preset.isOriginal) return 'original';
    return switch (preset.resolutionHeight) {
      1080 => '1080p',
      720 => '720p',
      _ => 'auto',
    };
  }

  static String _platform() {
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
    } catch (_) {
      // Web/tests.
    }
    return 'unknown';
  }

  static Map<String, Object?> _delivery({required List<String> containers, required List<String> video}) => {
    'enabled': true,
    'supported_on_device': true,
    'containers': containers,
    'video_codecs': video,
    'audio_decode_codecs': _audioCodecs,
    'audio_passthrough_codecs': const <String>[],
    'subtitles': {
      'sidecar_text': true,
      'embedded_text': true,
      'ass_styling': true,
      'embedded_bitmap': true,
      'sidecar_bitmap': true,
      'font_attachments': true,
    },
    'features': const <String>[],
    'transformations': const <String>[],
    'validated_claims': const <String>[],
    'auth_header_refresh': false,
  };

  static Map<String, Object?> clientCapabilities() {
    final video = videoCodecs();
    return {
      'video_evidence': 'declared',
      'audio_evidence': 'declared',
      'codecs_video': video,
      'codecs_video_hardware': const <String>['h264'],
      'codecs_audio': _audioCodecs,
      'containers': _containers,
      'max_resolution': '2160p',
      // mpv tone-maps HDR to the display itself; declaring HDR keeps the
      // original stream instead of a server-side tone-mapped transcode.
      'hdr': true,
      'hdr_details': {'hdr10': true, 'hdr10_plus': true, 'hlg': true, 'dolby_vision_profiles': const <int>[]},
    };
  }

  static Map<String, Object?> playbackContext({required String appVersion, required String formFactor}) {
    final video = videoCodecs();
    return {
      'protocol_version': protocolVersion,
      'form_factor': formFactor,
      'app_version': appVersion,
      'device': {'platform': _platform()},
      'output': {
        'output_context_id': '1',
        'display': {'hdr_evidence': 'unknown'},
      },
      'deliveries': {
        'original_http': _delivery(containers: _containers, video: video),
        'hls': {
          ..._delivery(containers: const ['m3u8', 'hls', 'ts', 'mp4', 'fmp4'], video: video),
          'features': const ['hls'],
        },
        'progressive': _delivery(containers: const ['mp4', 'mkv', 'webm'], video: video),
      },
    };
  }
}
