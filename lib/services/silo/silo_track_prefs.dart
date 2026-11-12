import '../../utils/language_codes.dart';
import 'silo_subtitles.dart';

/// Audio and subtitle choices Silo remembers for a whole series (Silo Android
/// #680: `SeriesAudioChoice.kt`, `SeriesSubtitleChoice.kt`,
/// `AutoSubtitleResolver.kt`; Siku's `SeriesChoice.brs`):
///
/// * `PUT /api/v2/audio-prefs/{series_id}`
///   `{audio_track_index, audio_language?, track_signature?}`
/// * `PUT /api/v2/subtitle-prefs/{series_id}`
///   `{subtitle_language, subtitle_track_index, subtitle_mode, track_signature?}`
///
/// The server folds the choice into every later watch detail: the version's
/// `effective_audio_track_index` and the detail's `effective_subtitle_language`
/// / `_mode` / `_track_signature` / `effective_show_forced_subtitles` (which
/// also carry the profile's defaults when the series has no choice).
///
/// Plezilo applies them to Silo **movies and episodes** (not extras), as Silo's
/// apps do: a movie's watch detail carries the profile's defaults too. Only an
/// episode has a series to remember; Plezilo writes only a viewer's own pick
/// in the player.
class SiloTrackPrefs {
  const SiloTrackPrefs._();

  /// The series a watch detail's choices are remembered under, or null for
  /// anything that is not an episode of a series (movies, extras).
  static String? seriesKey(Map<String, dynamic>? watch) {
    if (watch == null) return null;
    final type = watch['type']?.toString().toLowerCase();
    if (type != null && type != 'episode') return null;
    final series = watch['series_id']?.toString().trim() ?? '';
    return series.isEmpty ? null : series;
  }

  static String audioPath(String seriesKey) => '/api/v2/audio-prefs/${Uri.encodeComponent(seriesKey)}';
  static String subtitlePath(String seriesKey) => '/api/v2/subtitle-prefs/${Uri.encodeComponent(seriesKey)}';

  // ---------------------------------------------------------------------------
  // Bodies
  // ---------------------------------------------------------------------------

  static final _serverLanguage = RegExp(r'^[A-Za-z]{2,3}(?:[-_][0-9A-Za-z]{1,8})*$');

  /// A track language as `audio_language` / `subtitle_language` accept it: a
  /// BCP 47 tag or ISO 639 code as recorded, an English language name older
  /// files carry ("English") as its code, and null for unknown (`und`) or
  /// anything else, which the server would refuse with a 422.
  static String? serverLanguageTag(Object? language) {
    final value = language?.toString().trim() ?? '';
    if (value.isEmpty || value.toLowerCase() == 'und') return null;
    if (_serverLanguage.hasMatch(value)) return value;
    final lower = value.toLowerCase();
    for (final entry in LanguageCodes.getAllLanguages()) {
      if (entry.name.toLowerCase() == lower) return entry.code;
    }
    return null;
  }

  static String? _clean(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// The body for the audio track at [ordinal] of a version's
  /// `audio_tracks` ([track] is that raw row). The signature is built from
  /// the catalog row because the server matches title, embedded title, codec
  /// and layout exactly; `default` is not part of the match and not sent.
  static Map<String, Object?> audioBody(Map<dynamic, dynamic> track, int ordinal) {
    final signature = <String, Object?>{
      'language': ?_clean(track['language']),
      'title': ?_clean(track['title']),
      'embedded_title': ?_clean(track['embedded_title']),
      'codec': ?_clean(track['codec']),
      'layout': ?_clean(track['layout'] ?? track['channel_layout']),
      if ((track['channels'] as num?)?.toInt() case final channels? when channels > 0) 'channels': channels,
    };
    return {
      'audio_track_index': ordinal < -1 ? -1 : ordinal,
      'audio_language': ?serverLanguageTag(track['language']),
      if (signature.isNotEmpty) 'track_signature': signature,
    };
  }

  /// Subtitles off for the series (the web and Apple spelling).
  /// `show_forced_subtitles` is never sent: it would pin the profile's forced
  /// toggle on this series.
  static Map<String, Object?> subtitleOffBody() => {
    'subtitle_language': '',
    'subtitle_track_index': -1,
    'subtitle_mode': 'off',
  };

  /// The body for one row of the session's subtitle inventory (the player's
  /// view of the track: its `combined_index`, `source`, `label`, flags).
  static Map<String, Object?> subtitleBody(Map<dynamic, dynamic> row) {
    final candidate = SiloSubtitleCandidate.fromInventory(row, id: 0);
    final index = (row['combined_index'] as num?)?.toInt() ?? -1;
    return {
      'subtitle_language': serverLanguageTag(row['language']) ?? '',
      'subtitle_track_index': index < -1 ? -1 : index,
      'subtitle_mode': 'always',
      'track_signature': {
        'source': ?candidate.source,
        'language': ?_clean(row['language']),
        'codec': ?_clean(row['codec']),
        'label': ?_clean(row['label']),
        'forced': candidate.forced,
        'hearing_impaired': candidate.hearingImpaired,
      },
    };
  }

  // ---------------------------------------------------------------------------
  // Languages
  // ---------------------------------------------------------------------------

  /// The key two languages compare by: the primary subtag folded to ISO
  /// 639-1 (`eng` = `en`), null for none or `und`.
  static String? languageKey(Object? code) {
    final value = code?.toString().trim().toLowerCase().replaceAll('_', '-') ?? '';
    if (value.isEmpty) return null;
    final primary = value.split('-').first;
    if (primary.isEmpty || primary == 'und') return null;
    return LanguageCodes.getIso6391Code(primary) ?? primary;
  }

  /// The server's `langMatchRank`: 0 the same tag, 1 a bare tag of the same
  /// language, 2 another regional variant, -1 another (or unknown) language.
  static int _audioLanguageRank(Object? candidate, Object? preferred) {
    final a = _comparableTag(candidate);
    final b = _comparableTag(preferred);
    if (a == null || b == null) return -1;
    if (a == b) return 0;
    if (a.split('-').first != b.split('-').first) return -1;
    return a.contains('-') ? 2 : 1;
  }

  static String? _comparableTag(Object? value) {
    final tag = value?.toString().trim().toLowerCase().replaceAll('_', '-') ?? '';
    if (tag.isEmpty) return null;
    final dash = tag.indexOf('-');
    final primary = languageKey(dash < 0 ? tag : tag.substring(0, dash));
    if (primary == null) return null;
    return dash < 0 ? primary : '$primary${tag.substring(dash)}';
  }

  static bool _sameText(Object? a, Object? b) =>
      (a?.toString().trim().toLowerCase() ?? '') == (b?.toString().trim().toLowerCase() ?? '');

  // ---------------------------------------------------------------------------
  // Audio at start
  // ---------------------------------------------------------------------------

  /// The version's `effective_audio_track_index` when it names one of its
  /// tracks, else null.
  static int? effectiveAudioOrdinal(Map<String, dynamic> version) {
    final tracks = version['audio_tracks'];
    final index = (version['effective_audio_track_index'] as num?)?.toInt();
    if (tracks is! List || index == null || index < 0 || index >= tracks.length) return null;
    return index;
  }

  /// Whether [track] is the very track [signature] describes, by the server's
  /// rule: a compatible language, the same title, embedded title, codec and
  /// layout ignoring case, and the same channel count. An untagged track is
  /// recognised only by an untagged signature whose other fields carry
  /// something.
  static bool audioMatchesSignature(Map<dynamic, dynamic> track, Map<dynamic, dynamic> signature) {
    final meaningful = signature.entries.where((e) => e.key != 'default' && _clean(e.value) != null).toList();
    if (meaningful.isEmpty) return false;
    final trackLanguage = languageKey(track['language']);
    if (trackLanguage != languageKey(signature['language'])) return false;
    if (trackLanguage == null && !meaningful.any((e) => e.key != 'language')) return false;
    return _sameText(track['title'], signature['title']) &&
        _sameText(track['embedded_title'], signature['embedded_title']) &&
        _sameText(track['codec'], signature['codec']) &&
        _sameText(track['layout'] ?? track['channel_layout'], signature['layout']) &&
        ((track['channels'] as num?)?.toInt() ?? 0) == ((signature['channels'] as num?)?.toInt() ?? 0);
  }

  /// The position in [tracks] an audio [body] (not yet on the server) plays:
  /// the track its signature describes, else the remembered position while
  /// it still holds the language, else the closest track in that language.
  /// Null when none applies (`SeriesAudioChoice.resolveOn`, simplified: every
  /// track counts as decodable).
  static int? resolveAudioBody(Map<String, Object?> body, List<dynamic> tracks) {
    final rows = tracks.map((t) => t is Map ? t : const {}).toList();
    if (rows.isEmpty) return null;
    final signature = body['track_signature'];
    if (signature is Map) {
      int? best;
      var bestRank = 1 << 30;
      for (var i = 0; i < rows.length; i++) {
        if (!audioMatchesSignature(rows[i], signature)) continue;
        var rank = _audioLanguageRank(rows[i]['language'], signature['language']);
        if (rank < 0) rank = 99;
        if (rank < bestRank) {
          best = i;
          bestRank = rank;
        }
      }
      if (best != null) return best;
    }
    final language = body['audio_language'];
    if (language == null) return null;
    final index = (body['audio_track_index'] as num?)?.toInt() ?? -1;
    if (index >= 0 && index < rows.length && _audioLanguageRank(rows[index]['language'], language) >= 0) {
      return index;
    }
    int? best;
    var bestRank = 1 << 30;
    for (var i = 0; i < rows.length; i++) {
      final rank = _audioLanguageRank(rows[i]['language'], language);
      if (rank >= 0 && rank < bestRank) {
        best = i;
        bestRank = rank;
      }
    }
    return best;
  }

  // ---------------------------------------------------------------------------
  // Subtitles at start
  // ---------------------------------------------------------------------------

  /// The effective subtitle fields of [watch] with a not-yet-landed [pending]
  /// body laid over them (`EffectiveSubtitleFields.withPending`): a track
  /// becomes its language, mode `always` and signature; Off becomes mode
  /// `off` with no signature.
  static SiloSubtitleStartPrefs subtitlePrefs(Map<String, dynamic>? watch, {Map<String, Object?>? pending}) {
    final forced = watch?['effective_show_forced_subtitles'];
    var language = watch?['effective_subtitle_language']?.toString();
    var mode = watch?['effective_subtitle_mode']?.toString();
    final rawSignature = watch?['effective_subtitle_track_signature'];
    Map<dynamic, dynamic>? signature = rawSignature is Map ? rawSignature : null;
    if (pending != null) {
      if (pending['subtitle_mode'] == 'off') {
        mode = 'off';
        signature = null;
      } else {
        final pendingLanguage = pending['subtitle_language']?.toString() ?? '';
        if (pendingLanguage.isNotEmpty) language = pendingLanguage;
        mode = pending['subtitle_mode']?.toString();
        final pendingSignature = pending['track_signature'];
        signature = pendingSignature is Map ? pendingSignature : null;
      }
    }
    return SiloSubtitleStartPrefs(language: language, mode: mode, showForced: forced == true, signature: signature);
  }

  /// The subtitle a Silo episode starts with: a port of Silo's
  /// `resolveAutoSubtitle` over the tracks this playback can show
  /// ([candidates]; unplayable rows already left out). [audioLanguage] is the
  /// language of the audio that plays.
  static SiloSubtitleStart resolveSubtitle(
    List<SiloSubtitleCandidate> candidates,
    SiloSubtitleStartPrefs prefs, {
    Object? audioLanguage,
  }) {
    if (candidates.isEmpty) return const SiloSubtitleStart.noChange();
    final mode = (prefs.mode?.trim().toLowerCase() ?? '').isEmpty ? 'auto' : prefs.mode!.trim().toLowerCase();
    final audioKey = languageKey(audioLanguage);
    if (mode == 'off') {
      // Off still shows foreign dialogue when forced subtitles are on: the
      // forced track in the language of the audio, else nothing.
      if (!prefs.showForced || audioKey == null) return const SiloSubtitleStart.off();
      final forced = _best(candidates.where((c) => c.forced && languageKey(c.language) == audioKey));
      return forced == null ? const SiloSubtitleStart.off() : SiloSubtitleStart.select(forced.id);
    }

    final signature = prefs.signature;
    if (signature != null) {
      for (final candidate in candidates) {
        if (candidate.matchesSignature(signature)) return SiloSubtitleStart.select(candidate.id);
      }
    }

    final preferred = prefs.language;
    if (preferred != null && preferred.trim().isEmpty) return const SiloSubtitleStart.off();
    final target = languageKey(preferred);
    if (target == null) {
      if (mode != 'always') return const SiloSubtitleStart.noChange();
      final best = _best(candidates, signature: signature);
      return best == null ? const SiloSubtitleStart.noChange() : SiloSubtitleStart.select(best.id);
    }
    if (mode == 'auto' && audioKey != null && audioKey == target) {
      if (prefs.showForced) {
        final forced = _best(candidates.where((c) => c.forced && languageKey(c.language) == target));
        if (forced != null) return SiloSubtitleStart.select(forced.id);
      }
      return const SiloSubtitleStart.off();
    }
    final best =
        _best(candidates.where((c) => languageKey(c.language) == target), signature: signature) ??
        (prefs.showForced ? _best(candidates.where((c) => c.forced)) : null);
    return best == null ? const SiloSubtitleStart.noChange() : SiloSubtitleStart.select(best.id);
  }

  /// `autoSubtitlePreferenceOrder`: a track the player renders itself, full
  /// dialogue before forced, plain before SDH, embedded before external
  /// before downloaded; with a signature, the closest to it first. The
  /// first of equals wins.
  static SiloSubtitleCandidate? _best(Iterable<SiloSubtitleCandidate> pool, {Map<dynamic, dynamic>? signature}) {
    SiloSubtitleCandidate? best;
    List<int>? bestKey;
    for (final candidate in pool) {
      final key = [
        if (signature != null) -candidate.signatureScore(signature),
        candidate.bitmap ? 1 : 0,
        candidate.forced ? 1 : 0,
        candidate.hearingImpaired ? 1 : 0,
        candidate.sourceRank,
      ];
      if (bestKey == null || _compare(key, bestKey) < 0) {
        best = candidate;
        bestKey = key;
      }
    }
    return best;
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return 0;
  }
}

/// The cascaded subtitle preferences a start resolves against.
class SiloSubtitleStartPrefs {
  const SiloSubtitleStartPrefs({this.language, this.mode, this.showForced = false, this.signature});

  /// Null = no preference; empty = no subtitles.
  final String? language;
  final String? mode;
  final bool showForced;
  final Map<dynamic, dynamic>? signature;
}

/// What a Silo episode's subtitles start as.
class SiloSubtitleStart {
  const SiloSubtitleStart.noChange() : trackId = null, off = false;
  const SiloSubtitleStart.off() : trackId = null, off = true;
  const SiloSubtitleStart.select(int this.trackId) : off = false;

  /// The `MediaSubtitleTrack.id` to start with.
  final int? trackId;

  /// Subtitles start off.
  final bool off;

  bool get isNoChange => trackId == null && !off;

  @override
  String toString() => off ? 'off' : (trackId == null ? 'unchanged' : 'track $trackId');
}

/// One subtitle the player can show, as Silo's resolver sees it.
class SiloSubtitleCandidate {
  const SiloSubtitleCandidate({
    required this.id,
    this.source,
    this.language,
    this.codec,
    this.label,
    this.forced = false,
    this.hearingImpaired = false,
  });

  /// A row of the playback session's subtitle inventory; [id] is the
  /// player's `MediaSubtitleTrack.id` for it.
  factory SiloSubtitleCandidate.fromInventory(Map<dynamic, dynamic> row, {required int id}) {
    final label = row['label']?.toString();
    final raw = row['source']?.toString().trim().toLowerCase();
    final stored = raw == 'downloaded' || (raw == null && SiloSubtitleRules.storedId(row) != null);
    final source = stored ? 'downloaded' : (raw == 'embedded' || raw == 'external' ? raw : null);
    return SiloSubtitleCandidate(
      id: id,
      source: source,
      language: row['language']?.toString(),
      codec: row['codec']?.toString(),
      label: label,
      forced: row['forced'] == true,
      hearingImpaired: row['hearing_impaired'] == true || labelIndicatesHearingImpaired(label),
    );
  }

  final int id;

  /// `embedded`, `external` or `downloaded` (stored on the server); null when
  /// unknown, which ranks with embedded.
  final String? source;
  final String? language;
  final String? codec;
  final String? label;
  final bool forced;
  final bool hearingImpaired;

  bool get bitmap => SiloSubtitleRules.isBitmap(codec);

  int get sourceRank => switch (source) {
    'downloaded' => 2,
    'external' => 1,
    _ => 0,
  };

  static final _sdhToken = RegExp(r'(^|[^a-z0-9])(cc|sdh)([^a-z0-9]|$)');

  /// Silo's `subtitleLabelIndicatesHearingImpaired`.
  static bool labelIndicatesHearingImpaired(String? label) {
    final value = label?.toLowerCase();
    if (value == null) return false;
    if (value.contains('closed caption') || value.contains('hearing impaired') || value.contains('hearing-impaired')) {
      return true;
    }
    return _sdhToken.hasMatch(value);
  }

  static String _norm(Object? value) => value?.toString().trim().toLowerCase() ?? '';

  bool _sameLanguage(Object? other) {
    if (_norm(other) == _norm(language)) return true;
    final key = SiloTrackPrefs.languageKey(other);
    return key != null && key == SiloTrackPrefs.languageKey(language);
  }

  /// `subtitleTrackMatchesSignature`: the same source, language and codec,
  /// the same label when the signature carries one, the same forced and SDH
  /// flags.
  bool matchesSignature(Map<dynamic, dynamic> signature) =>
      _norm(signature['source']) == _norm(source) &&
      _sameLanguage(signature['language']) &&
      _norm(signature['codec']) == _norm(codec) &&
      (_norm(signature['label']).isEmpty || _norm(signature['label']) == _norm(label)) &&
      (signature['forced'] == true) == forced &&
      (signature['hearing_impaired'] == true) == hearingImpaired;

  /// `scoreSignatureFallback`: higher is closer to the remembered track.
  int signatureScore(Map<dynamic, dynamic> signature) {
    var score = 0;
    if (_norm(signature['source']) == _norm(source)) score += 4;
    if ((signature['forced'] == true) == forced) score += 2;
    if ((signature['hearing_impaired'] == true) == hearingImpaired) score += 2;
    if (_norm(signature['codec']) == _norm(codec)) score += 1;
    if (_norm(signature['label']) == _norm(label)) score += 1;
    return score;
  }
}
