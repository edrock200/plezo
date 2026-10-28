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

  static List<String> videoCodecs() => [..._hardwareVideoCodecs(), 'vp9', 'vp8', 'mpeg4', 'mpeg2video', 'vc1'];

  /// Codecs the device decodes in hardware (or that are unprobed and so
  /// assumed), as Plezy's other backends decide them.
  static List<String> _hardwareVideoCodecs() => [
    'h264',
    if (VideoDecodeCapabilities.accepts(RankedVideoCodec.hevc)) 'hevc',
    if (VideoDecodeCapabilities.accepts(RankedVideoCodec.av1)) 'av1',
  ];

  /// HDR ranges the player decodes. mpv and ExoPlayer tone-map to the
  /// attached display themselves.
  static const _hdrDetails = <String, Object?>{
    'hdr10': true,
    'hdr10_plus': true,
    'hlg': true,
    'dolby_vision_profiles': <int>[],
  };

  /// The original-file player resolves HDR and Dolby Vision against the live
  /// display after it receives the bytes, as it does when it direct-plays
  /// from Plex or Jellyfin. Without this claim, an `unknown` display probe
  /// makes the server refuse every HDR original (typically 4K HEVC) and
  /// transcode it to SDR H.264 instead.
  static const clientManagedDynamicRangeClaim = 'client_managed_dynamic_range_v1';

  /// Silo `quality_preference` for a Plezy preset.
  ///
  /// Never `original` for video: Silo's apps no longer send it (Silo
  /// Android #613) and older servers read it as "never convert", which
  /// refuses a file the device cannot play instead of transcoding it. Auto
  /// plays the source whenever the device and connection can, so Plezy's
  /// Original preset is `auto`. A preset's bitrate goes in
  /// `bandwidth_cap_kbps`; heights Silo has no label for are `auto`.
  static String qualityPreference(TranscodeQualityPreset preset) {
    if (preset.isOriginal) return 'auto';
    return switch (preset.resolutionHeight) {
      2160 => '2160p',
      1080 => '1080p',
      720 => '720p',
      _ => 'auto',
    };
  }

  /// Whether an `original_http` answer to [preset] means the server did not
  /// adapt a file that exceeds it (transcoding off or unavailable), which is
  /// worth telling the user. A source that already fits the preset, or whose
  /// size the plan does not report, plays as the original legitimately.
  static bool refusedCappedPreset(TranscodeQualityPreset preset, Object? source) {
    if (preset.isOriginal || source is! Map) return false;
    final bitrate = (source['bitrate_kbps'] as num?)?.toInt();
    final height = (source['height'] as num?)?.toInt();
    final capKbps = preset.videoBitrateKbps;
    final capHeight = preset.resolutionHeight;
    final overBitrate = bitrate != null && bitrate > 0 && capKbps != null && bitrate > capKbps;
    final overHeight = height != null && height > 0 && capHeight != null && height > capHeight;
    return overBitrate || overHeight;
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

  static Map<String, Object?> _delivery({
    required List<String> containers,
    required List<String> video,
    List<String> validatedClaims = const [],
  }) => {
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
    'validated_claims': validatedClaims,
    'auth_header_refresh': false,
  };

  static Map<String, Object?> clientCapabilities() {
    final video = videoCodecs();
    return {
      'video_evidence': 'declared',
      'audio_evidence': 'declared',
      'codecs_video': video,
      'codecs_video_hardware': _hardwareVideoCodecs(),
      'codecs_audio': _audioCodecs,
      'containers': _containers,
      'max_resolution': '2160p',
      // mpv tone-maps HDR to the display itself; declaring HDR keeps the
      // original stream instead of a server-side tone-mapped transcode.
      'hdr': true,
      'hdr_details': _hdrDetails,
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
        // A client sending `display` must send `hdr_details` too, or an older
        // server falls back to the device-level value. Plezy does not probe
        // the panel, so the evidence is `unknown`: native HDR output is never
        // promised, and HDR originals ride the client-managed claim below.
        'hdr_details': _hdrDetails,
        'display': {'hdr_evidence': 'unknown'},
      },
      'deliveries': {
        'original_http': _delivery(
          containers: _containers,
          video: video,
          validatedClaims: const [clientManagedDynamicRangeClaim],
        ),
        'hls': {
          ..._delivery(containers: const ['m3u8', 'hls', 'ts', 'mp4', 'fmp4'], video: video),
          'features': const ['hls'],
        },
        // Declared but off, as Silo's own apps do: a progressive remux is not
        // seekable on the wire yet.
        'progressive': {
          ..._delivery(containers: const ['mp4', 'mkv', 'webm'], video: video),
          'enabled': false,
          'supported_on_device': false,
          'failure_reason': 'disabled_pending_seekable_transport',
        },
      },
    };
  }
}
