import '../../media/chapter_marker_classifier.dart';
import '../../media/media_source_info.dart';

/// What a registered Tofa download keeps for offline playback and sync: the
/// ids `POST /api/v1/download/register` answered with, and the parts of its
/// `DownloadRegistrationResponse` playback reads without the server (tracks,
/// skip segments, length). Stored pinned in `TofaApiCache` under the item id;
/// never holds a token.
class TofaDownloadRecord {
  const TofaDownloadRecord({
    required this.downloadId,
    required this.fileId,
    required this.mediaId,
    required this.qualityKey,
    required this.clientRequestId,
    this.container,
    this.durationSeconds,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.skipSegments = const [],
    this.seq = 0,
  });

  /// `download_id`, for `DELETE /download/{id}` and offline progress.
  final String downloadId;
  final String fileId;
  final String mediaId;
  final String qualityKey;

  /// The `client_request_id` sent at registration (kept so a retry asks for
  /// the same preparation).
  final String clientRequestId;
  final String? container;
  final double? durationSeconds;

  /// `OfflineAudioTrackSnapshot`s and `OfflineSubtitleSnapshot`s.
  final List<Map<String, dynamic>> audioTracks;
  final List<Map<String, dynamic>> subtitleTracks;

  /// `OfflineSkipSegment`s (`kind`, `start_seconds`, `end_seconds`).
  final List<Map<String, dynamic>> skipSegments;

  /// The last `monotonic_seq` sent with an offline progress event.
  final int seq;

  TofaDownloadRecord copyWith({int? seq}) => TofaDownloadRecord(
    downloadId: downloadId,
    fileId: fileId,
    mediaId: mediaId,
    qualityKey: qualityKey,
    clientRequestId: clientRequestId,
    container: container,
    durationSeconds: durationSeconds,
    audioTracks: audioTracks,
    subtitleTracks: subtitleTracks,
    skipSegments: skipSegments,
    seq: seq ?? this.seq,
  );

  static List<Map<String, dynamic>> _maps(Object? raw) =>
      raw is List ? [for (final m in raw.whereType<Map>()) Map<String, dynamic>.from(m)] : const [];

  /// From a registration answer for [fileId] / [mediaId] at [qualityKey].
  static TofaDownloadRecord? fromRegistration(
    Object? data, {
    required String fileId,
    required String mediaId,
    required String qualityKey,
    required String clientRequestId,
  }) {
    if (data is! Map) return null;
    final id = data['download_id'];
    if (id is! String || id.isEmpty) return null;
    final snapshot = data['metadata_snapshot'];
    return TofaDownloadRecord(
      downloadId: id,
      fileId: fileId,
      mediaId: mediaId,
      qualityKey: qualityKey,
      clientRequestId: clientRequestId,
      container: data['container'] is String ? data['container'] as String : null,
      durationSeconds: (data['duration_seconds'] as num?)?.toDouble(),
      audioTracks: _maps(data['audio_tracks'] ?? (snapshot is Map ? snapshot['audio_tracks'] : null)),
      subtitleTracks: _maps(data['subtitle_tracks'] ?? (snapshot is Map ? snapshot['subtitles'] : null)),
      skipSegments: _maps(data['skip_segments'] ?? (snapshot is Map ? snapshot['skip_segments'] : null)),
    );
  }

  Map<String, dynamic> toJson() => {
    'download_id': downloadId,
    'media_file_id': fileId,
    'media_id': mediaId,
    'quality_key': qualityKey,
    'client_request_id': clientRequestId,
    'container': ?container,
    'duration_seconds': ?durationSeconds,
    'audio_tracks': audioTracks,
    'subtitle_tracks': subtitleTracks,
    'skip_segments': skipSegments,
    'seq': seq,
  };

  static TofaDownloadRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    String? s(String key) => json[key] is String && (json[key] as String).isNotEmpty ? json[key] as String : null;
    final downloadId = s('download_id');
    final fileId = s('media_file_id');
    final mediaId = s('media_id');
    if (downloadId == null || fileId == null || mediaId == null) return null;
    return TofaDownloadRecord(
      downloadId: downloadId,
      fileId: fileId,
      mediaId: mediaId,
      qualityKey: s('quality_key') ?? '',
      clientRequestId: s('client_request_id') ?? '',
      container: s('container'),
      durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
      audioTracks: _maps(json['audio_tracks']),
      subtitleTracks: _maps(json['subtitle_tracks']),
      skipSegments: _maps(json['skip_segments']),
      seq: (json['seq'] as num?)?.toInt() ?? 0,
    );
  }

  /// The downloaded file's tracks, for offline playback. Ids are the track
  /// index + 1, as on a streamed session.
  MediaSourceInfo sourceInfo() => MediaSourceInfo(
    videoUrl: '',
    audioTracks: [
      for (final track in audioTracks)
        if ((track['index'] as num?)?.toInt() case final index?)
          MediaAudioTrack(
            id: index + 1,
            index: index,
            codec: track['codec']?.toString(),
            language: track['language']?.toString(),
            languageCode: track['language']?.toString(),
            title: track['title']?.toString(),
            channels: (track['channels'] as num?)?.toInt(),
            selected: false,
          ),
    ],
    subtitleTracks: [
      for (final track in subtitleTracks)
        if ((track['index'] as num?)?.toInt() case final index?)
          MediaSubtitleTrack(
            id: index + 1,
            index: index,
            language: track['language']?.toString(),
            languageCode: track['language']?.toString(),
            title: track['title']?.toString(),
            selected: false,
            forced: track['is_forced'] == true,
          ),
    ],
    chapters: const [],
    mediaSourceId: fileId,
    mediaIndex: 0,
  );
}

/// A download quality of one file (`MediaFile.download_options[]`,
/// `DownloadQualityOption`), best first.
class TofaDownloadQuality {
  const TofaDownloadQuality({
    required this.tag,
    required this.label,
    required this.isOriginal,
    this.height,
    this.sizeBytes,
    this.sizeIsEstimate = false,
  });

  /// The `quality_key` to register with.
  final String tag;
  final String label;
  final bool isOriginal;
  final int? height;
  final int? sizeBytes;
  final bool sizeIsEstimate;

  /// Stored preference across a season's or show's episodes, whose files
  /// each have their own tags: the original, or a height.
  String get preference => isOriginal ? 'original' : 'height:${height ?? 0}';

  static List<TofaDownloadQuality> listOf(Object? options) => [
    if (options is List)
      for (final o in options.whereType<Map>())
        if (o['tag'] is String && (o['tag'] as String).isNotEmpty && o['label'] is String)
          TofaDownloadQuality(
            tag: o['tag'] as String,
            label: o['label'] as String,
            isOriginal: o['is_original'] == true,
            height: (o['height'] as num?)?.toInt(),
            sizeBytes: (o['size_bytes'] as num?)?.toInt(),
            sizeIsEstimate: o['size_is_estimate'] == true,
          ),
  ];

  /// The option of [options] for a stored [preference]: the original, or the
  /// option of that height; else the original; else null (never the first
  /// by position when none is marked original).
  static TofaDownloadQuality? pick(List<TofaDownloadQuality> options, String? preference) {
    if (preference != null && preference != 'original') {
      final height = int.tryParse(preference.replaceFirst('height:', ''));
      for (final o in options) {
        if (!o.isOriginal && o.height == height) return o;
      }
    }
    for (final o in options) {
      if (o.isOriginal) return o;
    }
    return null;
  }
}

/// Chapters and skip markers from Tofa's QuickView data and download
/// snapshots, shared by streamed playback and offline playback.
abstract final class TofaOfflineExtras {
  static int _ticksToMs(Object? ticks) => ticks is num ? ticks.toInt() ~/ 10000 : 0;

  /// Plezilo's marker type for a QuickView `segment_type` (or a download's
  /// skip segment `kind`). Unverified: the type names; the spec says "such
  /// as intro and outro", Tofa's guide also names recaps and credits.
  static String? markerType(Object? segmentType) {
    final type = segmentType is String ? segmentType.toLowerCase() : '';
    if (type.contains('intro') || type.contains('opening')) return 'intro';
    if (type.contains('recap')) return 'recap';
    if (type.contains('credit') || type.contains('outro') || type.contains('ending')) return 'credits';
    if (type.contains('preview')) return 'preview';
    return null;
  }

  /// Skip markers from QuickView `segments` (ticks) or, with [seconds], a
  /// download's `skip_segments`, sorted by start; unknown kinds left out.
  static List<MediaMarker> markers(Object? segments, {bool seconds = false}) {
    final regions = <({String type, int start, int end})>[];
    if (segments is List) {
      for (final segment in segments.whereType<Map>()) {
        final type = markerType(segment['segment_type'] ?? segment['kind']);
        final start = seconds
            ? (((segment['start_seconds'] as num?)?.toDouble() ?? -1) * 1000).round()
            : (segment['start_ticks'] is num ? _ticksToMs(segment['start_ticks']) : -1);
        final end = seconds
            ? (((segment['end_seconds'] as num?)?.toDouble() ?? -1) * 1000).round()
            : (segment['end_ticks'] is num ? _ticksToMs(segment['end_ticks']) : -1);
        if (type == null || start < 0 || end <= start) continue;
        regions.add((type: type, start: start, end: end));
      }
    }
    regions.sort((a, b) => a.start.compareTo(b.start));
    return [
      for (final (i, r) in regions.indexed)
        MediaMarker(id: i, type: r.type, startTimeOffset: r.start, endTimeOffset: r.end),
    ];
  }

  /// QuickView `chapters`, in start order, with [thumb] naming each one's
  /// image (null: none).
  static List<MediaChapter> chapters(Object? chapters, {String? Function(int index)? thumb}) {
    final out = <MediaChapter>[];
    if (chapters is List) {
      for (final chapter in chapters.whereType<Map>()) {
        final index = (chapter['chapter_index'] as num?)?.toInt();
        if (index == null) continue;
        final hasImage = chapter['image_tag'] != null || chapter['image_rel_path'] != null;
        out.add(
          MediaChapter(
            id: index,
            index: index,
            startTimeOffset: _ticksToMs(chapter['start_ticks']),
            title: chapter['title'] is String ? chapter['title'] as String : null,
            thumb: hasImage ? thumb?.call(index) : null,
          ),
        );
      }
    }
    out.sort((a, b) => (a.startTimeOffset ?? 0).compareTo(b.startTimeOffset ?? 0));
    return MediaChapter.backfillEndOffsets(out);
  }

  /// Extras for a download: the pinned QuickView's chapters and segments,
  /// else the registration's skip segments.
  static PlaybackExtras build({
    required TofaDownloadRecord? record,
    required Map<String, dynamic>? quickView,
    required ChapterMarkerClassifier classifier,
    String? Function(int index)? chapterThumb,
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) {
    var found = markers(quickView?['segments']);
    if (found.isEmpty && record != null) found = markers(record.skipSegments, seconds: true);
    return PlaybackExtras.withChapterFallback(
      chapters: chapters(quickView?['chapters'], thumb: chapterThumb),
      markers: found,
      introPatternStr: introPattern,
      creditsPatternStr: creditsPattern,
      forceChapterFallback: forceChapterFallback,
      classifier: classifier,
    );
  }
}
