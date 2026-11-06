import 'silo_api.dart' show siloProblemCode;

/// Silo audiobooks: the whole-book timeline, chapter math, resume and the
/// session rules of Silo's audiobook player (Silo Android
/// `AudiobookTimeline.kt`, `AudiobookChapters.kt`, `AudiobookPlayerViewModel`;
/// Siku `AudioTimeline.brs`, `AudioSessionRecovery.brs`). Pure: no I/O.
///
/// The server has no whole-book concept. Each file of a book is a
/// `FileVersion` tagged `presentation_kind: "audiobook_part"` with a
/// `presentation_part_index`; the client stitches the parts into one timeline,
/// plays one part per playback session (`progress_persistence: "client"`,
/// part-local positions) and writes the whole-book position itself with
/// `POST /api/v2/sync/progress`.

/// One playable part (file) of a book, placed on the whole-book timeline.
class SiloAudiobookPart {
  const SiloAudiobookPart({
    required this.index,
    required this.fileId,
    required this.durationSeconds,
    required this.offsetSeconds,
  });

  final int index;
  final String fileId;
  final double durationSeconds;

  /// Where this part starts on the whole-book timeline.
  final double offsetSeconds;

  double get endSeconds => offsetSeconds + durationSeconds;
}

/// A chapter on the whole-book timeline (`start`/`end` are book seconds).
class SiloAudiobookChapter {
  const SiloAudiobookChapter({
    required this.index,
    required this.title,
    required this.startSeconds,
    required this.endSeconds,
    required this.partIndex,
  });

  final int index;

  /// The display label (`audiobookChapterLabel`): blank or digit-only titles
  /// read "Chapter N".
  final String title;
  final double startSeconds;
  final double endSeconds;
  final int partIndex;
}

class SiloAudiobookTimeline {
  const SiloAudiobookTimeline({required this.parts, required this.chapters, required this.totalSeconds});

  final List<SiloAudiobookPart> parts;
  final List<SiloAudiobookChapter> chapters;
  final double totalSeconds;

  bool get isSinglePart => parts.length <= 1;

  /// Silo's previous-chapter rule: more than this far into a chapter,
  /// "previous" restarts it.
  static const previousRestartThresholdSeconds = 3.0;

  /// Builds the timeline from a detail's `versions`, or `null` when no
  /// version is a playable audio part. [serverTotalSeconds]
  /// (`audiobook.total_duration_seconds`) only ever lengthens it.
  static SiloAudiobookTimeline? build(
    List<Map<String, dynamic>> versions, {
    double? serverTotalSeconds,
    String? preferredFileId,
  }) {
    final picked = audioParts(versions, preferredFileId: preferredFileId);
    final parts = <SiloAudiobookPart>[];
    final chapters = <({String title, double start, double end, int part})>[];
    var offset = 0.0;
    for (final version in picked) {
      final duration = partDurationSeconds(version);
      final fileId = version['file_id']?.toString();
      // Zero-length parts would trip end-of-part detection and add nothing.
      if (duration <= 0 || fileId == null || fileId.isEmpty) continue;
      final index = parts.length;
      parts.add(SiloAudiobookPart(index: index, fileId: fileId, durationSeconds: duration, offsetSeconds: offset));
      final raw = version['chapters'];
      if (raw is List) {
        for (final chapter in raw.whereType<Map>()) {
          final start = _num(chapter['start_seconds']);
          var end = _num(chapter['end_seconds']);
          if (end < start) end = start;
          chapters.add((
            title: chapter['title']?.toString() ?? '',
            start: offset + start,
            end: offset + (end > duration ? duration : end),
            part: index,
          ));
        }
      }
      offset += duration;
    }
    if (parts.isEmpty) return null;
    final total = (serverTotalSeconds ?? 0) > offset ? serverTotalSeconds! : offset;
    final sorted = [...chapters]..sort((a, b) => a.start.compareTo(b.start));
    return SiloAudiobookTimeline(
      parts: parts,
      chapters: [
        for (var i = 0; i < sorted.length; i++)
          SiloAudiobookChapter(
            index: i,
            title: chapterLabel(i, sorted[i].title),
            startSeconds: sorted[i].start,
            endSeconds: sorted[i].end,
            partIndex: sorted[i].part,
          ),
      ],
      totalSeconds: total,
    );
  }

  /// One playable file per ordered part (Silo's `audioParts()`): versions
  /// tagged `audiobook_part`, or any version with an audio codec or a
  /// duration. Parts are grouped by `presentation_part_index`, and one
  /// variant (`presentation_kind|presentation_group_key`) present in every
  /// part is chosen, the preferred file's first. Without part indexes the book
  /// is one file: the preferred one, else the first.
  static List<Map<String, dynamic>> audioParts(List<Map<String, dynamic>> versions, {String? preferredFileId}) {
    final candidates = versions.where((v) {
      if (v['presentation_kind'] == 'audiobook_part') return true;
      final codec = v['codec_audio']?.toString() ?? '';
      return codec.isNotEmpty || _num(v['duration']) > 0;
    }).toList();
    if (candidates.isEmpty) return const [];
    final preferred = preferredFileId == null
        ? null
        : candidates.where((c) => c['file_id']?.toString() == preferredFileId).firstOrNull;
    final indexed = candidates.where((c) => c['presentation_part_index'] is num).toList();
    if (indexed.isEmpty) return [preferred ?? candidates.first];

    final byPart = <int, List<Map<String, dynamic>>>{};
    for (final c in indexed) {
      byPart.putIfAbsent((c['presentation_part_index'] as num).toInt(), () => []).add(c);
    }
    final partKeys = byPart.keys.toList()..sort();
    String variantKey(Map<String, dynamic> v) => '${v['presentation_kind'] ?? ''}|${v['presentation_group_key'] ?? ''}';
    final keys = [if (preferred != null) variantKey(preferred), ...candidates.map(variantKey)];
    final selected = keys
        .where((key) => partKeys.every((part) => byPart[part]!.any((v) => variantKey(v) == key)))
        .firstOrNull;
    return [
      for (final part in partKeys)
        byPart[part]!.where((v) => selected != null && variantKey(v) == selected).firstOrNull ??
            byPart[part]!.where((v) => v['file_id']?.toString() == preferredFileId).firstOrNull ??
            byPart[part]!.first,
    ];
  }

  /// A part's probed duration, or its furthest chapter edge when the
  /// container has none.
  static double partDurationSeconds(Map<String, dynamic> version) {
    final duration = _num(version['duration']);
    if (duration > 0) return duration;
    var edge = 0.0;
    final chapters = version['chapters'];
    if (chapters is List) {
      for (final chapter in chapters.whereType<Map>()) {
        final start = _num(chapter['start_seconds']);
        final end = _num(chapter['end_seconds']);
        final furthest = end > start ? end : start;
        if (furthest > edge) edge = furthest;
      }
    }
    return edge;
  }

  /// Silo's `audiobookChapterLabel`.
  static String chapterLabel(int index, String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty || RegExp(r'^\d+$').hasMatch(trimmed)) return 'Chapter ${index + 1}';
    return trimmed;
  }

  /// Clamp a book time onto the timeline.
  double clamp(double seconds) {
    if (seconds.isNaN || seconds < 0) return 0;
    return seconds > totalSeconds ? totalSeconds : seconds;
  }

  /// The part playing at a book time (past the end: the last part).
  SiloAudiobookPart partAt(double seconds) {
    final t = seconds < 0 ? 0.0 : seconds;
    for (final part in parts) {
      if (t >= part.offsetSeconds && t < part.endSeconds) return part;
    }
    return parts.last;
  }

  /// A book time as a position inside [part].
  static double localTime(SiloAudiobookPart part, double seconds) {
    final local = seconds - part.offsetSeconds;
    if (local < 0) return 0;
    return local > part.durationSeconds ? part.durationSeconds : local;
  }

  /// Index of the chapter at a book time (start-inclusive; before the first
  /// chapter counts as the first); -1 without chapters.
  int chapterIndexAt(double seconds) {
    if (chapters.isEmpty) return -1;
    var index = 0;
    for (var i = 0; i < chapters.length; i++) {
      if (seconds >= chapters[i].startSeconds) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  /// "Next chapter": the next chapter's start; on the last chapter its own.
  double nextChapterTarget(double seconds) {
    if (chapters.isEmpty) return clamp(seconds);
    final current = chapterIndexAt(seconds);
    return chapters[current + 1 < chapters.length ? current + 1 : current].startSeconds;
  }

  /// "Previous chapter": restart the current chapter when more than
  /// [previousRestartThresholdSeconds] into it (or on the first), else the
  /// previous chapter's start.
  double previousChapterTarget(double seconds) {
    if (chapters.isEmpty) return 0;
    final current = chapterIndexAt(seconds);
    final start = chapters[current].startSeconds;
    if (seconds - start > previousRestartThresholdSeconds || current == 0) return start;
    return chapters[current - 1].startSeconds;
  }

  /// Progress inside the current chapter, 0..1.
  double chapterProgress(double seconds) {
    final index = chapterIndexAt(seconds);
    if (index < 0) return 0;
    final chapter = chapters[index];
    final span = chapter.endSeconds - chapter.startSeconds;
    if (span <= 0) return 0;
    return ((seconds - chapter.startSeconds) / span).clamp(0.0, 1.0);
  }
}

/// A book's detail (`GET /api/v2/catalog/items/{id}` of `type: audiobook`).
class SiloAudiobookDetail {
  const SiloAudiobookDetail({
    required this.id,
    required this.title,
    required this.authors,
    required this.narrators,
    this.seriesName,
    this.overview,
    this.year,
    this.publisher,
    this.coverUrl,
    this.backdropUrl,
    this.timeline,
    this.positionSeconds = 0,
    this.played = false,
    this.lastFileId,
  });

  final String id;
  final String title;
  final List<String> authors;
  final List<String> narrators;
  final String? seriesName;
  final String? overview;
  final int? year;
  final String? publisher;
  final String? coverUrl;
  final String? backdropUrl;

  /// `null` when the book has no playable audio part.
  final SiloAudiobookTimeline? timeline;

  /// The whole-book position the server recorded (`user_data`).
  final double positionSeconds;
  final bool played;
  final String? lastFileId;

  double get totalSeconds => timeline?.totalSeconds ?? 0;

  /// Where Play starts: the recorded position, unless the book is finished
  /// (within the last 5 s, Silo's resume tail) — then from the start.
  double get resumeSeconds => resumeFrom(positionSeconds, totalSeconds);

  static double resumeFrom(double positionSeconds, double totalSeconds) {
    if (positionSeconds.isNaN || positionSeconds <= 0) return 0;
    if (totalSeconds > 0 && positionSeconds >= totalSeconds - 5) return 0;
    return positionSeconds;
  }

  static SiloAudiobookDetail parse(Map<String, dynamic> json, {required String Function(String url) resolveUrl}) {
    final book = json['audiobook'] is Map<String, dynamic> ? json['audiobook'] as Map<String, dynamic> : null;
    final userData = json['user_data'] is Map ? json['user_data'] as Map : null;
    final userState = json['user_state'] is Map ? json['user_state'] as Map : null;
    final versions = (json['versions'] is List ? json['versions'] as List : const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final lastFileId = userData?['last_file_id']?.toString();
    final serverTotal = _num(book?['total_duration_seconds']);
    String? url(Object? value) {
      final s = value?.toString().trim();
      return s == null || s.isEmpty ? null : resolveUrl(s);
    }

    final series = book?['series'];
    return SiloAudiobookDetail(
      id: (json['content_id'] ?? json['id']).toString(),
      title: json['title']?.toString() ?? '',
      authors: SiloAudiobookPeople.names(book?['authors'] ?? json['authors']),
      narrators: SiloAudiobookPeople.names(book?['narrators'] ?? json['narrators']),
      seriesName: series is Map ? series['name']?.toString() : json['series_name']?.toString(),
      overview: json['overview']?.toString(),
      year: (json['year'] as num?)?.toInt(),
      publisher: book?['publisher']?.toString(),
      coverUrl: url(json['poster_url']),
      backdropUrl: url(json['backdrop_url']),
      timeline: SiloAudiobookTimeline.build(
        versions,
        serverTotalSeconds: serverTotal > 0 ? serverTotal : null,
        preferredFileId: lastFileId,
      ),
      positionSeconds: _num(userData?['position_seconds'] ?? json['position_seconds']),
      played: userData?['played'] == true || userState?['played'] == true,
      lastFileId: lastFileId,
    );
  }
}

/// Author/narrator lists arrive as `AudiobookPerson` objects on details and,
/// on some servers' cards, as plain names.
abstract final class SiloAudiobookPeople {
  static List<String> names(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map && entry['name'] is String && (entry['name'] as String).trim().isNotEmpty)
          (entry['name'] as String).trim()
        else if (entry is String && entry.trim().isNotEmpty)
          entry.trim(),
    ];
  }
}

/// What the player does about a progress answer for the session playing now
/// (Silo Android #708; Siku `AudioSession_progressAction`).
enum SiloAudiobookSessionAction {
  /// Keep reporting.
  none,

  /// `410 playback_session_ended`: an administrator stopped it. Stop, say
  /// so, and start no other session (not even from Retry).
  ended,

  /// The server forgot the session while playing: a fresh one now, at the
  /// position.
  renew,

  /// It forgot it while paused: the fresh one starts when Play is pressed.
  renewOnPlay,

  /// Another 404/410, or the renewal limit was reached: stop reporting.
  stopReporting,
}

abstract final class SiloAudiobookSessionRules {
  /// Fresh sessions in a row without a good progress answer before the
  /// player gives up renewing.
  static const maxRenewals = 3;

  /// The server forgot the session (reaped after the player was cut off past
  /// its grace, or a restart): a 404 with `playback_session_not_found`, or
  /// v2's generic not-found whose detail names the session. Other 404s
  /// ("Source media file is missing") say nothing about the session.
  static bool isSessionMissing(int status, Object? problem) {
    if (status != 404) return false;
    if (_code(problem) == 'playback_session_not_found') return true;
    if (problem is! Map) return false;
    return problem['detail'] == 'Playback session not found' || problem['title'] == 'Playback session not found';
  }

  /// `410 playback_session_ended`: an administrator stopped the session.
  static bool isSessionEnded(int status, Object? problem) =>
      status == 410 && _code(problem) == 'playback_session_ended';

  static SiloAudiobookSessionAction progressAction({
    required int status,
    required Object? problem,
    required bool paused,
    required int renewals,
  }) {
    if (status >= 200 && status < 300) return SiloAudiobookSessionAction.none;
    if (isSessionEnded(status, problem)) return SiloAudiobookSessionAction.ended;
    if (isSessionMissing(status, problem)) {
      if (renewals >= maxRenewals) return SiloAudiobookSessionAction.stopReporting;
      return paused ? SiloAudiobookSessionAction.renewOnPlay : SiloAudiobookSessionAction.renew;
    }
    if (status == 404 || status == 410) return SiloAudiobookSessionAction.stopReporting;
    return SiloAudiobookSessionAction.none;
  }

  /// Playback stopped on an error: Play (and Try again) start it again at
  /// the position the player last held, unless the server ended the session
  /// or the player is closing (Android's `canRetryPlayback`).
  static bool canRetry({required bool hasError, required bool endedByServer, required bool closing}) =>
      hasError && !endedByServer && !closing;

  static String? _code(Object? problem) {
    if (problem is Map && problem['code'] is String) return problem['code'] as String;
    return siloProblemCode(problem);
  }
}

/// Whether a catalog `type` is an audiobook (`isAudiobookItemType`).
bool isSiloAudiobookType(Object? type) => type is String && type.trim().toLowerCase() == 'audiobook';

double _num(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

/// One part's playback session: `POST /api/v2/playback/start` with
/// `progress_persistence: "client"`.
class SiloAudiobookStream {
  SiloAudiobookStream({
    required this.sessionId,
    required this.installationId,
    required this.fileId,
    required this.url,
    this.headers = const {},
  });

  final String sessionId;
  final String installationId;
  final String fileId;
  final String url;
  final Map<String, String> headers;

  /// Strictly increasing per session; the server rejects lower values.
  int sequence = 0;

  /// Minted once so a repeated stop is idempotent.
  String? stopId;
}

/// The answer to a part's progress post: the HTTP status (0 when it never
/// arrived) and the problem body.
class SiloAudiobookProgressAnswer {
  const SiloAudiobookProgressAnswer(this.status, [this.problem]);

  final int status;
  final Object? problem;

  bool get ok => status >= 200 && status < 300;
}

/// What the audiobook player needs from a Silo server. `SiloClient.audiobooks`
/// implements it; tests fake it.
abstract interface class SiloAudiobookBackend {
  Future<SiloAudiobookDetail> fetchAudiobook(String id);

  /// A fresh session for [fileId] starting at the part-local position.
  Future<SiloAudiobookStream> startPart(String fileId, {required double localStartSeconds});

  /// `POST /playback/{id}/progress` with a part-local position. Never throws:
  /// a transport failure answers status 0.
  Future<SiloAudiobookProgressAnswer> sendProgress(
    SiloAudiobookStream stream,
    double localSeconds, {
    required bool paused,
  });

  /// `DELETE /playback/{id}` with a final part-local sample. Best effort.
  Future<void> stopPart(SiloAudiobookStream stream, double localSeconds);

  /// The whole-book position (`POST /api/v2/sync/progress`). Best effort.
  Future<void> syncBookProgress(String bookId, double bookSeconds, double totalSeconds);
}
