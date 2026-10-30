/// Silo's subtitle tools as Plezy uses them in the player: provider search and
/// download (`POST /api/v2/subtitles/search|download`) and "Translate with AI"
/// (`/api/v2/subtitles/ai/*`). Pure models; the calls live in `SiloClient`.
library;

/// `GET /api/v2/subtitles/ai/status`.
class SiloAiStatus {
  const SiloAiStatus({required this.translate, required this.transcribe});

  static const off = SiloAiStatus(translate: false, transcribe: false);

  /// Translating an existing subtitle track (and a transcript) is on.
  final bool translate;

  /// Transcribing an audio track is on. A server can offer it without
  /// translation (Silo Android #547): the subtitles then stay in the spoken
  /// language.
  final bool transcribe;

  bool get available => translate || transcribe;

  static SiloAiStatus fromJson(Map<String, dynamic> json) {
    if (json['state'] != 'available' || json['allowed'] == false) return off;
    return SiloAiStatus(translate: json['enabled'] == true, transcribe: json['transcribe_enabled'] == true);
  }
}

/// `GET /api/v2/subtitles/ai/quota`: the transcription budget. Translation is
/// not counted, and exempt callers (administrators) get `limited: false`.
class SiloAiQuota {
  const SiloAiQuota({required this.limited, this.limit, this.used, this.remaining, this.period});

  final bool limited;
  final int? limit;
  final int? used;
  final int? remaining;

  /// `day`, `week` or `month`.
  final String? period;

  bool get exhausted => limited && (remaining ?? 0) <= 0;

  static SiloAiQuota fromJson(Map<String, dynamic> json) => SiloAiQuota(
    limited: json['limited'] == true,
    limit: (json['limit'] as num?)?.toInt(),
    used: (json['used'] as num?)?.toInt(),
    remaining: (json['remaining'] as num?)?.toInt(),
    period: json['period']?.toString(),
  );
}

/// What an AI job makes: `translate` reads a subtitle track, the transcribe
/// kinds read an audio track.
enum SiloAiJobKind {
  translate('translate'),
  transcribe('transcribe'),
  transcribeTranslate('transcribe_translate');

  const SiloAiJobKind(this.wire);
  final String wire;
}

/// One AI subtitle job (`SubtitleAIJob`).
class SiloAiJob {
  const SiloAiJob({
    required this.id,
    required this.status,
    this.progress = 0,
    this.progressMessage,
    this.errorMessage,
    this.resultSubtitleId,
  });

  final String id;

  /// `pending`, `running`, `completed`, `failed` or `cancelled`.
  final String status;

  /// 0..1.
  final double progress;
  final String? progressMessage;
  final String? errorMessage;

  /// The stored subtitle a completed job made.
  final String? resultSubtitleId;

  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed';
  bool get isCancelled => status == 'cancelled' || status == 'canceled';
  bool get isTerminal => isCompleted || isFailed || isCancelled;

  static SiloAiJob? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    String? text(String key) {
      final value = json[key]?.toString().trim();
      return value == null || value.isEmpty ? null : value;
    }

    return SiloAiJob(
      id: id,
      status: json['status']?.toString() ?? 'pending',
      progress: ((json['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1).toDouble(),
      progressMessage: text('progress_message'),
      errorMessage: text('error_message'),
      resultSubtitleId: text('result_subtitle_id'),
    );
  }
}

/// A subtitle track of the playing file the server can translate.
class SiloAiSubtitleSource {
  const SiloAiSubtitleSource({
    required this.combinedIndex,
    required this.source,
    this.language,
    this.label,
    this.codec,
  });

  /// `source_index` of a `translate` job.
  final int combinedIndex;

  /// `embedded`, `external` or `downloaded`.
  final String source;
  final String? language;
  final String? label;
  final String? codec;
}

/// An audio track of the playing file the server can transcribe.
class SiloAiAudioSource {
  const SiloAiAudioSource({required this.index, this.language, this.title, this.codec, this.channels});

  /// `source_index` of a transcribe job.
  final int index;
  final String? language;
  final String? title;
  final String? codec;
  final int? channels;
}

/// What the AI sheet needs about the playing file: its session (for #726),
/// the file, and the tracks it can work from.
class SiloAiPlaybackContext {
  const SiloAiPlaybackContext({
    required this.itemId,
    required this.fileId,
    required this.sessionId,
    required this.subtitleSources,
    required this.audioSources,
    this.selectedAudioIndex,
  });

  final String itemId;
  final String fileId;
  final String sessionId;
  final List<SiloAiSubtitleSource> subtitleSources;
  final List<SiloAiAudioSource> audioSources;
  final int? selectedAudioIndex;
}

/// One provider hit of `POST /api/v2/subtitles/search`.
class SiloSubtitleSearchHit {
  const SiloSubtitleSearchHit({
    required this.id,
    required this.provider,
    required this.language,
    required this.releaseName,
    this.score,
    this.hearingImpaired = false,
    this.format,
    this.downloads,
  });

  final String id;
  final String provider;
  final String language;
  final String releaseName;
  final double? score;
  final bool hearingImpaired;
  final String? format;
  final int? downloads;

  /// Results are listed and downloaded by (provider, id).
  String get key => '$provider:$id';

  static SiloSubtitleSearchHit? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString() ?? '';
    final provider = json['provider']?.toString() ?? '';
    if (id.isEmpty || provider.isEmpty) return null;
    return SiloSubtitleSearchHit(
      id: id,
      provider: provider,
      language: json['language']?.toString() ?? '',
      releaseName: json['release_name']?.toString() ?? '',
      score: (json['score'] as num?)?.toDouble(),
      hearingImpaired: json['hearing_impaired'] == true,
      format: json['format']?.toString(),
      downloads: (json['downloads'] as num?)?.toInt(),
    );
  }
}

/// `POST /api/v2/subtitles/search` answer: hits plus provider warnings (a
/// provider that failed or is not configured).
class SiloSubtitleSearchResults {
  const SiloSubtitleSearchResults({required this.hits, this.warnings = const []});

  final List<SiloSubtitleSearchHit> hits;
  final List<String> warnings;
}

abstract final class SiloSubtitleRules {
  static const _bitmapCodecs = {
    'pgs',
    'hdmv_pgs_subtitle',
    'dvd_subtitle',
    'dvdsub',
    'dvb_subtitle',
    'dvbsub',
    'vobsub',
  };
  static const _textCodecs = {'srt', 'subrip', 'vtt', 'webvtt'};

  /// Base of the track ids Plezy gives subtitles stored on the server (provider
  /// downloads and AI results). A file's own tracks are its index + 1, far
  /// below; a stored subtitle keeps its id when a reload renumbers the
  /// session's inventory, so a choice made before the reload still finds it.
  static const storedTrackIdBase = 1 << 24;

  static bool isBitmap(String? codec) => _bitmapCodecs.contains(codec?.toLowerCase());

  /// Tracks the server can translate (Silo's TV app): embedded tracks it can
  /// extract to text, and external or stored files in a text format it parses.
  static bool isTranslatable(Map<dynamic, dynamic> entry) {
    final codec = entry['codec']?.toString().toLowerCase();
    if (entry['source'] == 'embedded') return !isBitmap(codec);
    return _textCodecs.contains(codec);
  }

  /// The stored subtitle id of an inventory row: its `stored-<id>` sync key,
  /// else the `downloaded_subtitle_id` the server pins on its sidecar URL.
  static String? storedId(Map<dynamic, dynamic> entry) {
    final key = entry['sync_key']?.toString() ?? '';
    if (key.startsWith('stored-') && key.length > 7) return key.substring(7);
    final url = entry['url']?.toString() ?? '';
    final match = RegExp(r'[?&]downloaded_subtitle_id=([^&#]+)').firstMatch(url);
    return match?.group(1);
  }

  /// Plezy's track id for a stored subtitle, or null for an id that is not a
  /// positive integer (Silo's are).
  static int? storedTrackId(String storedId) {
    final n = int.tryParse(storedId);
    if (n == null || n <= 0 || n >= storedTrackIdBase) return null;
    return storedTrackIdBase + n;
  }

  /// The target languages offered for AI subtitles, as Silo's TV app lists
  /// them (two-letter codes).
  static const aiLanguageCodes = [
    'en', 'es', 'fr', 'de', 'it', 'pt', 'nl', 'pl', 'ru', 'zh', 'ja', 'ko', 'ar', 'tr', 'sv', 'da', 'no', 'fi', //
    'hu', 'cs', 'ro', 'he', 'th', 'vi', 'el', 'bg', 'hr', 'sk', 'sl', 'uk', 'id', 'ms', 'hi', 'ta', 'te', 'bn', 'fa',
  ];

  /// A transcribe job whose audio is already in [target] needs no translation;
  /// one without AI translation can only stay in the spoken language.
  static SiloAiJobKind transcribeKind({
    required String? audioLanguage,
    required String target,
    required bool canTranslate,
  }) {
    if (!canTranslate) return SiloAiJobKind.transcribe;
    return sameLanguage(audioLanguage, target) ? SiloAiJobKind.transcribe : SiloAiJobKind.transcribeTranslate;
  }

  static const _threeToTwo = {
    'eng': 'en', 'spa': 'es', 'fre': 'fr', 'fra': 'fr', 'ger': 'de', 'deu': 'de', 'ita': 'it', 'por': 'pt', //
    'dut': 'nl', 'nld': 'nl', 'pol': 'pl', 'rus': 'ru', 'chi': 'zh', 'zho': 'zh', 'jpn': 'ja', 'kor': 'ko',
    'ara': 'ar', 'tur': 'tr', 'swe': 'sv', 'dan': 'da', 'nor': 'no', 'nob': 'no', 'fin': 'fi', 'hun': 'hu',
    'cze': 'cs', 'ces': 'cs', 'rum': 'ro', 'ron': 'ro', 'heb': 'he', 'tha': 'th', 'vie': 'vi', 'gre': 'el',
    'ell': 'el', 'bul': 'bg', 'hrv': 'hr', 'slo': 'sk', 'slk': 'sk', 'slv': 'sl', 'ukr': 'uk', 'ind': 'id',
    'may': 'ms', 'msa': 'ms', 'hin': 'hi', 'tam': 'ta', 'tel': 'te', 'ben': 'bn', 'per': 'fa', 'fas': 'fa',
  };

  /// A track or profile language as a two-letter code (`eng`, `en-US` → `en`).
  static String? twoLetter(String? code) {
    var c = code?.trim().toLowerCase() ?? '';
    final dash = c.indexOf(RegExp('[-_]'));
    if (dash > 0) c = c.substring(0, dash);
    if (c.length == 2) return c;
    return _threeToTwo[c];
  }

  static bool sameLanguage(String? a, String? b) {
    final x = twoLetter(a);
    return x != null && x == twoLetter(b);
  }
}
