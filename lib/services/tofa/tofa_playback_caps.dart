import '../../models/transcode_quality_preset.dart';
import '../video_decode_capabilities.dart';

/// What Plezilo's player (libmpv, or ExoPlayer with an mpv fallback) can
/// play, as the query of Tofa's `GET /api/v1/stream/{id}/info` and
/// `GET /api/v1/media/{id}/versions`.
///
/// Unverified: the spec types the codec and container lists as plain
/// strings. They are sent comma-separated with ffprobe's codec names (the
/// names `MediaFile.video_codec` / `audio_codec` carry), which is how the
/// spec's own descriptions read; check against a server.
abstract final class TofaPlaybackCaps {
  static const _containers = <String>['mkv', 'matroska', 'webm', 'mp4', 'm4v', 'mov', 'avi', 'ts', 'mpegts', 'm2ts'];

  static const _audioCodecs = <String>[
    'aac',
    'ac3',
    'eac3',
    'truehd',
    'dts',
    'flac',
    'opus',
    'vorbis',
    'mp3',
    'mp2',
    'alac',
    'pcm_s16le',
    'pcm_s24le',
  ];

  /// HLS output audio: what any HLS segment the player opens can carry.
  static const _hlsAudioCodecs = <String>['aac', 'ac3', 'eac3', 'mp3', 'opus', 'flac'];

  /// Codecs decoded in hardware (or unprobed and so assumed), as Plezilo's
  /// other backends decide them, then the ones mpv decodes in software.
  static List<String> directPlayVideoCodecs() => [
    'h264',
    if (VideoDecodeCapabilities.accepts(RankedVideoCodec.hevc)) 'hevc',
    if (VideoDecodeCapabilities.accepts(RankedVideoCodec.av1)) 'av1',
    'vp9',
    'vp8',
    'mpeg4',
    'mpeg2video',
    'vc1',
  ];

  static List<String> hlsVideoCodecs() => ['h264', if (VideoDecodeCapabilities.accepts(RankedVideoCodec.hevc)) 'hevc'];

  static List<String> transcodeVideoCodecs() => [
    for (final codec in VideoDecodeCapabilities.transcodeVideoCodecs)
      if (codec != RankedVideoCodec.av1) codec.id,
  ];

  /// The capability query for one negotiation. A capped [preset] sends its
  /// bitrate as `max_bitrate` (bits per second; unverified unit, the spec
  /// does not say) and withholds nothing else: the server decides whether a
  /// file over the cap is transcoded.
  static Map<String, String> query({TranscodeQualityPreset preset = TranscodeQualityPreset.original}) {
    final hevc = VideoDecodeCapabilities.accepts(RankedVideoCodec.hevc);
    final kbps = preset.isOriginal ? null : preset.videoBitrateKbps;
    return {
      'direct_play_video_codecs': directPlayVideoCodecs().join(','),
      'direct_play_audio_codecs': _audioCodecs.join(','),
      'direct_play_containers': _containers.join(','),
      'hls_video_codecs': hlsVideoCodecs().join(','),
      'hls_audio_codecs': _hlsAudioCodecs.join(','),
      // mpv tone-maps HDR to the display itself, as on Plezilo's other
      // backends: declaring HDR keeps the original stream.
      'hdr_supported': 'true',
      'hevc_10bit_supported': hevc.toString(),
      'h264_10bit_supported': 'false',
      // Plezilo does not probe the panel for Dolby Vision; the base layer of
      // a profile 8 file still plays as HDR10.
      'dolby_vision_supported': 'false',
      if (kbps != null) 'max_bitrate': '${kbps * 1000}',
    };
  }

  /// The extra `/stream/{id}/info` parameters a player session adds.
  static Map<String, String> streamQuery({
    TranscodeQualityPreset preset = TranscodeQualityPreset.original,
    required int resumeTicks,
    int? audioStreamIndex,
    bool forceTranscode = false,
  }) => {
    ...query(preset: preset),
    'transcode_video_codecs': transcodeVideoCodecs().join(','),
    // Text tracks come as session sidecars (`…/subtitles/{index}/full.vtt`);
    // bitmap tracks of an original file are drawn by the player.
    'include_text_subtitles': 'true',
    'client_render_bitmap_subtitles': 'true',
    'resume_ticks': '$resumeTicks',
    'audio_stream_index': ?audioStreamIndex?.toString(),
    // Unverified value: the spec does not list `force_method`'s values; the
    // play method names are the only ones it uses.
    if (forceTranscode) 'force_method': 'Transcode',
  };
}
