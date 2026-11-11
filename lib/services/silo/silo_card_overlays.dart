import 'dart:convert';
import 'dart:math' as math;

import '../../utils/language_codes.dart';

/// Silo's card overlays: the badges a Silo profile chooses for posters,
/// landscape cards and episode stills (4K, Dolby Vision, a rating), as
/// silo-server's `docs/architecture/card-overlays.md` specifies them and the
/// web client draws them; ported from Silo's Roku app (`overlays.bs` at
/// silo-roku e8244ee) and Silo Android's `OverlayRegistry`/`OverlaySchema`.
///
/// The profile's `ui.card_overlays` document, else the server default from
/// `GET /api/v2/settings/overlay-config`, picks the badges, where they sit and
/// a look; `ui.card_overlays_enabled` (else the config's `enabled`) turns them
/// on. Plezilo only reads the document (Silo's web client edits it).
///
/// Everything here is pure: lengths are the web's, in logical px at the
/// 185 px reference poster width. A poster scales them by its width over
/// [SiloCardOverlays.referenceWidth]; a landscape card or episode still draws
/// them at 1. Colours are `0xAARRGGBB` ints.
abstract final class SiloCardOverlays {
  static const referenceWidth = 185.0;
  static const edgeInset = 8.0;
  static const edgeGap = 8.0;

  /// A corner draws at most this many badges and a rail one more; the rest
  /// are dropped rather than overlapping.
  static const maxCorner = 3;
  static const maxRail = 4;

  /// An uploaded image that replaces a whole badge is this many times the
  /// height of the text badge it stands for.
  static const valueImageScale = 1.6;

  /// The watch-status corner (the web's `CardWatchStatus`): a 22 px disc.
  static const watchStatusSize = 22.0;

  /// The episodes-left count's font size in the watch-status corner.
  static const watchStatusFontSize = 11.0;

  /// How far a poster's top row stops short of the right edge (after the
  /// edge inset), so a badge never runs under the watch-status corner.
  static const watchStatusReserve = watchStatusSize + edgeGap;

  /// Tailwind's `tracking-wide` and `tracking-widest`, in em.
  static const trackingWide = 0.025;
  static const trackingWidest = 0.1;

  static const documentKey = 'ui.card_overlays';
  static const enabledKey = 'ui.card_overlays_enabled';
  static const imagePath = '/api/v2/overlay-images/';

  static const sizeMin = 0.75;
  static const sizeMax = 2.0;

  static const presetIds = ['minimal', 'classic', 'vibrant', 'pill', 'square', 'plate', 'band'];
}

/// Where a badge sits: three corners and the two edge rails. The top-right
/// corner belongs to the watch status; a stored `top-right` moves to the
/// right-edge rail, as the web reads it.
enum SiloOverlayPosition {
  topLeft('top-left'),
  bottomLeft('bottom-left'),
  bottomRight('bottom-right'),
  leftEdge('left-edge'),
  rightEdge('right-edge');

  const SiloOverlayPosition(this.wire);
  final String wire;

  static SiloOverlayPosition? fromWire(Object? value) {
    if (value == 'top-right') return SiloOverlayPosition.rightEdge;
    for (final position in values) {
      if (position.wire == value) return position;
    }
    return null;
  }

  bool get isRail => this == leftEdge || this == rightEdge;
}

/// One badge type in the registry, in the web registry's order (the default
/// render order within a position).
class SiloOverlayEntry {
  final String id;
  final SiloOverlayPosition position;
  final bool enabled;

  /// Static icon, or null for none or a value's own ([SiloOverlayBadges.iconFor]).
  final String? icon;
  final bool iconCapable;

  /// Default accent (`#rrggbb`), or null.
  final String? accent;

  /// A rating's source mark ("IMDb"), or null.
  final String? sourceMark;

  const SiloOverlayEntry(
    this.id,
    this.position,
    this.enabled, {
    this.icon,
    this.iconCapable = false,
    this.accent,
    this.sourceMark,
  });

  const SiloOverlayEntry.rating(this.id, String this.accent, String this.sourceMark)
    : position = SiloOverlayPosition.leftEdge,
      enabled = false,
      icon = null,
      iconCapable = false;
}

abstract final class SiloOverlayRegistry {
  static const List<SiloOverlayEntry> all = [
    // tech
    SiloOverlayEntry('resolution', SiloOverlayPosition.topLeft, true, icon: 'monitor', iconCapable: true),
    SiloOverlayEntry('hdr', SiloOverlayPosition.topLeft, true, iconCapable: true),
    SiloOverlayEntry('resolution_hdr', SiloOverlayPosition.topLeft, false, iconCapable: true),
    SiloOverlayEntry('resolution_hdr_audio', SiloOverlayPosition.topLeft, false, iconCapable: true),
    SiloOverlayEntry('audio', SiloOverlayPosition.topLeft, true, iconCapable: true),
    SiloOverlayEntry('audio_channels', SiloOverlayPosition.topLeft, false, icon: 'volume', iconCapable: true),
    SiloOverlayEntry('video_codec', SiloOverlayPosition.topLeft, false, icon: 'film', iconCapable: true),
    SiloOverlayEntry('container', SiloOverlayPosition.bottomLeft, false),
    SiloOverlayEntry('aspect_ratio', SiloOverlayPosition.bottomRight, false, icon: 'layout', iconCapable: true),
    SiloOverlayEntry('release_type', SiloOverlayPosition.bottomLeft, true),
    SiloOverlayEntry('edition', SiloOverlayPosition.bottomLeft, false),
    SiloOverlayEntry('multi_audio', SiloOverlayPosition.bottomRight, false, icon: 'languages', iconCapable: true),
    SiloOverlayEntry('multi_sub', SiloOverlayPosition.bottomRight, false, icon: 'subtitles', iconCapable: true),
    // ratings
    SiloOverlayEntry.rating('rating_imdb', '#f5c518', 'IMDb'),
    SiloOverlayEntry.rating('rating_tmdb', '#01b4e4', 'TMDB'),
    SiloOverlayEntry.rating('rating_rt', '#fa320a', 'RT'),
    SiloOverlayEntry.rating('rating_rt_audience', '#fa6400', 'RT Audience'),
    SiloOverlayEntry('content_rating', SiloOverlayPosition.bottomRight, false, icon: 'shield', iconCapable: true),
    SiloOverlayEntry('advisory_age', SiloOverlayPosition.bottomRight, false, icon: 'users', iconCapable: true),
    // metadata
    SiloOverlayEntry('year', SiloOverlayPosition.bottomLeft, false),
    SiloOverlayEntry('runtime', SiloOverlayPosition.bottomLeft, false, icon: 'clock', iconCapable: true),
    SiloOverlayEntry('original_language', SiloOverlayPosition.bottomLeft, false, icon: 'globe', iconCapable: true),
    SiloOverlayEntry('studio', SiloOverlayPosition.bottomRight, false, icon: 'building', iconCapable: true),
    SiloOverlayEntry('network', SiloOverlayPosition.bottomRight, false, icon: 'tv', iconCapable: true),
    // ribbons
    SiloOverlayEntry('show_status', SiloOverlayPosition.rightEdge, false, icon: 'tv', iconCapable: true),
    // Watchlist titles outside the library carry it; Plezilo lists none, so
    // no card has its data. Kept so stored order and positions survive.
    SiloOverlayEntry('request_status', SiloOverlayPosition.topLeft, true, iconCapable: true),
  ];

  static final Map<String, SiloOverlayEntry> _byId = {for (final entry in all) entry.id: entry};

  static SiloOverlayEntry? byId(String id) => _byId[id];

  static bool isKnown(Object? id) => id is String && _byId.containsKey(id);

  /// Combined badges and the badges whose information each already shows
  /// (web's `COMBINED_BADGES`, Silo Android #816).
  static const combinedBadges = <String, Set<String>>{
    'resolution_hdr_audio': {'resolution', 'hdr', 'audio', 'resolution_hdr'},
    'resolution_hdr': {'resolution', 'hdr'},
  };

  /// Whether [id] is hidden because an enabled combined badge already shows
  /// it. The stored document is untouched, so turning the combined badge off
  /// brings them back.
  static bool isSuppressed(String id, SiloOverlayPrefs prefs) => combinedBadges.entries.any(
    (combined) => combined.value.contains(id) && (prefs.items[combined.key]?.enabled ?? false),
  );

  /// The enabled badges at [position], combined badges hiding the ones they
  /// cover, in the document's order and then the registry's.
  static List<SiloOverlayEntry> placed(SiloOverlayPrefs prefs, SiloOverlayPosition position) {
    final out = <SiloOverlayEntry>[
      for (final entry in all)
        if (prefs.items[entry.id] case final item?
            when item.enabled && item.position == position && !isSuppressed(entry.id, prefs))
          entry,
    ];
    if (prefs.order.isEmpty) return out;
    final rank = <String, int>{};
    for (var i = 0; i < prefs.order.length; i++) {
      rank.putIfAbsent(prefs.order[i], () => i);
    }
    final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])];
    indexed.sort((a, b) {
      final ra = rank[a.$2.id] ?? 1 << 30;
      final rb = rank[b.$2.id] ?? 1 << 30;
      return ra != rb ? ra.compareTo(rb) : a.$1.compareTo(b.$1);
    });
    return [for (final pair in indexed) pair.$2];
  }
}

/// One badge's stored configuration.
class SiloOverlayItemConfig {
  final bool enabled;
  final SiloOverlayPosition position;

  /// `#rrggbb`, or null for the badge's own accent.
  final String? accent;

  /// Overrides the look's icon preference; null follows it.
  final bool? showIcon;

  /// An uploaded icon image's ref (64 hex digits + `.webp`), or null.
  final String? image;

  /// Uploaded images that replace the whole badge for a value, by value key.
  final Map<String, String>? valueImages;

  const SiloOverlayItemConfig({
    required this.enabled,
    required this.position,
    this.accent,
    this.showIcon,
    this.image,
    this.valueImages,
  });

  SiloOverlayItemConfig withImages(String? image, Map<String, String>? valueImages) => SiloOverlayItemConfig(
    enabled: enabled,
    position: position,
    accent: accent,
    showIcon: showIcon,
    image: image,
    valueImages: valueImages,
  );
}

/// The document's `style` overrides; each invalid field is dropped.
class SiloOverlayStyle {
  final double? size;
  final String? shape;
  final String? background;
  final String? textColor;
  final String? borderColor;
  final int? borderWidth;
  final String? fontWeight;
  final bool? uppercase;
  final bool? shadow;

  const SiloOverlayStyle({
    this.size,
    this.shape,
    this.background,
    this.textColor,
    this.borderColor,
    this.borderWidth,
    this.fontWeight,
    this.uppercase,
    this.shadow,
  });

  static SiloOverlayStyle? parse(Object? value) {
    if (value is! Map) return null;
    final size = value['size'];
    final borderWidth = value['borderWidth'];
    final style = SiloOverlayStyle(
      size: size is num && size >= SiloCardOverlays.sizeMin && size <= SiloCardOverlays.sizeMax
          ? size.toDouble()
          : null,
      shape: const ['pill', 'rounded', 'square'].contains(value['shape']) ? value['shape'] as String : null,
      background: _isHex(value['background'], 8) ? value['background'] as String : null,
      textColor: _isHex(value['textColor'], 6) ? value['textColor'] as String : null,
      borderColor: _isHex(value['borderColor'], 8) ? value['borderColor'] as String : null,
      borderWidth:
          borderWidth is num && borderWidth == borderWidth.roundToDouble() && borderWidth >= 0 && borderWidth <= 3
          ? borderWidth.toInt()
          : null,
      fontWeight: const ['regular', 'semibold', 'extrabold'].contains(value['fontWeight'])
          ? value['fontWeight'] as String
          : null,
      uppercase: value['uppercase'] is bool ? value['uppercase'] as bool : null,
      shadow: value['shadow'] is bool ? value['shadow'] as bool : null,
    );
    return style._isEmpty ? null : style;
  }

  bool get _isEmpty =>
      size == null &&
      shape == null &&
      background == null &&
      textColor == null &&
      borderColor == null &&
      borderWidth == null &&
      fontWeight == null &&
      uppercase == null &&
      shadow == null;
}

bool _isHex(Object? value, int digits) => value is String && RegExp('^#[0-9a-fA-F]{$digits}\$').hasMatch(value);

/// An uploaded image's reference: 64 lowercase hex digits and `.webp`.
bool isSiloOverlayImageRef(Object? value) => value is String && RegExp(r'^[0-9a-f]{64}\.webp$').hasMatch(value);

/// A complete `ui.card_overlays` document.
class SiloOverlayPrefs {
  final String preset;
  final SiloOverlayStyle? style;
  final List<String> order;
  final Map<String, SiloOverlayItemConfig> items;

  const SiloOverlayPrefs({required this.preset, this.style, required this.order, required this.items});

  /// The built-in document: the classic look and each badge's defaults.
  factory SiloOverlayPrefs.defaults() => SiloOverlayPrefs(preset: 'classic', order: const [], items: _items(null));

  /// Reads a stored value (an object, the JSON text the server's default
  /// comes as, or null) as the web's `parseOverlayPrefs` does: a v1 document
  /// (badges by id) migrates, an unknown preset is classic, and an invalid
  /// field is dropped rather than failing the document.
  factory SiloOverlayPrefs.parse(Object? raw) {
    Object? parsed = raw;
    if (raw is String) {
      if (raw.trim().isEmpty) return SiloOverlayPrefs.defaults();
      try {
        parsed = jsonDecode(raw);
      } catch (_) {
        return SiloOverlayPrefs.defaults();
      }
    }
    if (parsed is! Map) return SiloOverlayPrefs.defaults();
    final version = parsed['version'];
    final v2 =
        (version is num && version == 2) ||
        (parsed['preset'] is String && (parsed['items'] is Map || parsed['items'] is List));
    if (!v2) return SiloOverlayPrefs(preset: 'classic', order: const [], items: _items(parsed));
    final preset = parsed['preset'];
    final order = <String>[];
    final rawOrder = parsed['order'];
    if (rawOrder is List) {
      for (final id in rawOrder) {
        if (SiloOverlayRegistry.isKnown(id) && !order.contains(id)) order.add(id as String);
      }
    }
    return SiloOverlayPrefs(
      preset: SiloCardOverlays.presetIds.contains(preset) ? preset as String : 'classic',
      style: SiloOverlayStyle.parse(parsed['style']),
      order: order,
      items: _items(parsed['items'] is Map ? parsed['items'] as Map : null),
    );
  }

  static Map<String, SiloOverlayItemConfig> _items(Map? source) {
    final out = <String, SiloOverlayItemConfig>{};
    for (final entry in SiloOverlayRegistry.all) {
      var enabled = entry.enabled;
      var position = entry.position;
      String? accent;
      bool? showIcon;
      String? image;
      Map<String, String>? valueImages;
      final patch = source?[entry.id];
      if (patch is Map) {
        if (patch['enabled'] is bool) enabled = patch['enabled'] as bool;
        position = SiloOverlayPosition.fromWire(patch['position']) ?? position;
        if (_isHex(patch['accentColor'], 6)) accent = patch['accentColor'] as String;
        if (patch['showIcon'] is bool) showIcon = patch['showIcon'] as bool;
        if (isSiloOverlayImageRef(patch['image'])) image = patch['image'] as String;
        valueImages = _valueImages(patch['valueImages']);
      }
      out[entry.id] = SiloOverlayItemConfig(
        enabled: enabled,
        position: position,
        accent: accent,
        showIcon: showIcon,
        image: image,
        valueImages: valueImages,
      );
    }
    return out;
  }

  static Map<String, String>? _valueImages(Object? value) {
    if (value is! Map) return null;
    final out = <String, String>{};
    for (final entry in value.entries) {
      if (out.length >= 32) break;
      final key = entry.key;
      if (key is String && key.isNotEmpty && key.length <= 64 && isSiloOverlayImageRef(entry.value)) {
        out[key] = entry.value as String;
      }
    }
    return out.isEmpty ? null : out;
  }

  /// This document without image refs outside [listed] (the overlay
  /// config's `images`), so a deleted image costs no request per card.
  SiloOverlayPrefs withoutUnlisted(Set<String> listed) {
    var changed = false;
    final items = <String, SiloOverlayItemConfig>{};
    for (final MapEntry(:key, :value) in this.items.entries) {
      final image = value.image != null && listed.contains(value.image) ? value.image : null;
      Map<String, String>? kept;
      if (value.valueImages case final images?) {
        kept = {
          for (final e in images.entries)
            if (listed.contains(e.value)) e.key: e.value,
        };
        if (kept.isEmpty) kept = null;
      }
      final itemChanged = image != value.image || (kept?.length ?? 0) != (value.valueImages?.length ?? 0);
      if (itemChanged) changed = true;
      items[key] = itemChanged ? value.withImages(image, kept) : value;
    }
    return changed ? SiloOverlayPrefs(preset: preset, style: style, order: order, items: items) : this;
  }

  /// Every uploaded image ref this document draws, each once.
  Set<String> get usedImages => {
    for (final item in items.values) ...[?item.image, ...?item.valueImages?.values],
  };
}

/// An uploaded image the overlay config lists, with its stored size.
class SiloOverlayImage {
  final int width;
  final int height;

  const SiloOverlayImage({required this.width, required this.height});

  double get aspectRatio => width > 0 && height > 0 ? width / height : 1;
}

/// What a Silo profile's cards draw: whether badges are on, the document,
/// and the uploaded images it may use.
class SiloCardOverlaySettings {
  final bool enabled;
  final SiloOverlayPrefs prefs;
  final Map<String, SiloOverlayImage> images;

  /// The look [prefs] asks for, resolved once.
  late final SiloOverlayLook look = SiloOverlayLook.of(prefs.preset, prefs.style);

  SiloCardOverlaySettings({required this.enabled, required this.prefs, this.images = const {}});

  /// Badges off: a Silo poster still draws its watch-status corner.
  static final off = SiloCardOverlaySettings(enabled: false, prefs: SiloOverlayPrefs.defaults());

  /// The profile's values ([SiloOverlayProfileValues], or null before or
  /// without them) over the overlay config (null for a server without it):
  /// the profile's choice wins, then the server's default; without either,
  /// badges are on in the classic look.
  factory SiloCardOverlaySettings.settle(SiloOverlayProfileValues? values, Map<String, dynamic>? config) {
    var enabled = true;
    Object? document;
    final images = <String, SiloOverlayImage>{};
    if (config != null) {
      if (config['enabled'] is bool) enabled = config['enabled'] as bool;
      document = config['defaults'];
      final list = config['images'];
      if (list is List) {
        for (final image in list.whereType<Map>()) {
          final ref = image['ref'];
          if (!isSiloOverlayImageRef(ref)) continue;
          final width = image['width'];
          final height = image['height'];
          images[ref as String] = SiloOverlayImage(
            width: width is num ? width.toInt() : 0,
            height: height is num ? height.toInt() : 0,
          );
        }
      }
    }
    if (values != null) {
      if (values.enabled != null) enabled = values.enabled!;
      if (values.document != null) document = values.document;
    }
    return SiloCardOverlaySettings(
      enabled: enabled,
      prefs: SiloOverlayPrefs.parse(document).withoutUnlisted(images.keys.toSet()),
      images: images,
    );
  }

  /// These settings without [ref] (an uploaded image that did not load):
  /// its badges draw as they would without it.
  SiloCardOverlaySettings withoutImage(String ref) {
    if (!images.containsKey(ref)) return this;
    final kept = Map.of(images)..remove(ref);
    return SiloCardOverlaySettings(enabled: enabled, prefs: prefs.withoutUnlisted(kept.keys.toSet()), images: kept);
  }
}

/// The profile's own `ui.card_overlays` and `ui.card_overlays_enabled` from
/// `GET /settings/values/effective`; a value counts only when its `source`
/// is the profile (the server's default comes from the overlay config).
class SiloOverlayProfileValues {
  final Object? document;
  final bool? enabled;

  const SiloOverlayProfileValues({this.document, this.enabled});

  factory SiloOverlayProfileValues.fromEffective(Map<String, dynamic>? body) {
    Object? document;
    bool? enabled;
    final list = body?['items'];
    if (list is List) {
      for (final item in list.whereType<Map>()) {
        final key = item['key'];
        final source = item['source'];
        final own = source is! String || source == 'profile';
        if (!own) continue;
        final value = item['value'];
        if (key == SiloCardOverlays.documentKey && value != null) document = value;
        if (key == SiloCardOverlays.enabledKey && value is bool) enabled = value;
      }
    }
    return SiloOverlayProfileValues(document: document, enabled: enabled);
  }
}

// -----------------------------------------------------------------------------
// Card data
// -----------------------------------------------------------------------------

/// The fields of a Silo card the badges read (the web's `extractors.ts`):
/// `overlay_summary`'s, the ratings, the content and advisory ratings, year,
/// runtime, original language, the first studio and network, and the show
/// status. Only present values are kept.
class SiloOverlayData {
  final Map<String, Object> values;

  const SiloOverlayData(this.values);

  static const empty = SiloOverlayData({});

  static final Expando<SiloOverlayData> _byRaw = Expando('siloOverlayData');

  /// The data of a card's raw JSON, read once per JSON object.
  static SiloOverlayData ofRaw(Map<String, Object?>? raw) {
    if (raw == null) return empty;
    return _byRaw[raw] ??= fromJson(raw);
  }

  static SiloOverlayData fromJson(Map<String, Object?> item) {
    final out = <String, Object>{};
    // As the API sent it (the web's `x || undefined`): value images match the
    // exact value, so nothing is trimmed; a blank one is no value.
    void keep(String key, Object? value) {
      if (value is String && value.trim().isNotEmpty) out[key] = value;
    }

    final summary = item['overlay_summary'];
    if (summary is Map) {
      for (final key in const [
        'resolution',
        'hdr',
        'audio',
        'audio_channels',
        'video_codec',
        'container',
        'aspect_ratio',
        'release_type',
        'edition',
      ]) {
        keep(key, summary[key]);
      }
      if (summary['multi_audio'] == true) out['multi_audio'] = true;
      if (summary['multi_sub'] == true) out['multi_sub'] = true;
    }
    for (final key in const [
      'rating_imdb',
      'rating_tmdb',
      'rating_rt_critic',
      'rating_rt_audience',
      'advisory_age',
      'year',
      'runtime',
    ]) {
      final value = item[key];
      if (value is num && value.isFinite) out[key] = value;
    }
    for (final key in const ['content_rating', 'original_language', 'show_status']) {
      keep(key, item[key]);
    }
    keep('studio', _firstNonEmpty(item['studios']));
    keep('network', _firstNonEmpty(item['networks']));
    return SiloOverlayData(out);
  }

  static String? _firstNonEmpty(Object? values) {
    if (values is! List) return null;
    for (final value in values) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  bool get isEmpty => values.isEmpty;

  String text(String key) {
    final value = values[key];
    return value is String ? value : '';
  }

  num? number(String key) {
    final value = values[key];
    return value is num ? value : null;
  }

  bool flag(String key) => values[key] == true;
}

/// The episodes a started, unfinished series or season has left, else 0: an
/// untouched one shows nothing, or every new show would carry a count.
int siloEpisodesLeft({required bool played, required int? watched, required int? unplayed}) {
  if (played) return 0;
  final w = watched ?? 0;
  final left = unplayed ?? 0;
  return w > 0 && left > 0 ? left : 0;
}

// -----------------------------------------------------------------------------
// Labels
// -----------------------------------------------------------------------------

/// The words badges show, translated by the caller.
class SiloOverlayCopy {
  final String multiAudio;
  final String subtitles;
  final String Function(int hours, int minutes) runtimeHoursMinutes;
  final String Function(int minutes) runtimeMinutes;
  final String returning;
  final String ended;
  final String cancelled;
  final String upcoming;

  const SiloOverlayCopy({
    required this.multiAudio,
    required this.subtitles,
    required this.runtimeHoursMinutes,
    required this.runtimeMinutes,
    required this.returning,
    required this.ended,
    required this.cancelled,
    required this.upcoming,
  });

  static String _hm(int hours, int minutes) => '${hours}h ${minutes}m';
  static String _m(int minutes) => '${minutes}m';

  static const english = SiloOverlayCopy(
    multiAudio: 'Multi-Audio',
    subtitles: 'CC',
    runtimeHoursMinutes: _hm,
    runtimeMinutes: _m,
    returning: 'Returning',
    ended: 'Ended',
    cancelled: 'Cancelled',
    upcoming: 'Upcoming',
  );
}

/// A badge resolved for one card: what it says and draws.
class SiloOverlayBadge {
  final String id;

  /// The full label ("4K DV Atmos", "IMDb 7.8").
  final String label;

  /// The accent (`#rrggbb`), or null.
  final String? accent;

  /// The icon drawn before the text, or null.
  final String? icon;

  /// A rating's source mark, or null.
  final String? sourceMark;

  /// A rating's score without its mark, or null.
  final String? score;

  /// Uploaded icon image and whole-badge value image refs, or null.
  final String? image;
  final String? valueImage;

  const SiloOverlayBadge({
    required this.id,
    required this.label,
    this.accent,
    this.icon,
    this.sourceMark,
    this.score,
    this.image,
    this.valueImage,
  });
}

/// What a badge draws under a look ([SiloOverlayBadges.finish]).
class SiloOverlayFinished {
  /// The source mark drawn on an accent chip (the plate look), or null.
  final String? chip;

  /// The text after the lead: the label, only the score beside a chip or an
  /// image, or empty when a wordmark says it.
  final String text;

  /// A bare score never truncates.
  final bool scoreOnly;

  /// A wordmark drawn in the icon's place, or null.
  final String? markText;

  const SiloOverlayFinished({this.chip, required this.text, required this.scoreOnly, this.markText});
}

abstract final class SiloOverlayBadges {
  /// The badge's label for [data], or empty when the card has no value.
  static String label(String id, SiloOverlayData data, [SiloOverlayCopy copy = SiloOverlayCopy.english]) {
    switch (id) {
      case 'resolution':
        return prettyResolution(data.text('resolution'));
      case 'resolution_hdr':
        final resolution = prettyResolution(data.text('resolution'));
        if (resolution.isEmpty) return '';
        return _joined([resolution, compactHdr(data.text('hdr'))]);
      case 'resolution_hdr_audio':
        return _joined([prettyResolution(data.text('resolution')), compactHdr(data.text('hdr')), data.text('audio')]);
      case 'multi_audio':
        return data.flag('multi_audio') ? copy.multiAudio : '';
      case 'multi_sub':
        return data.flag('multi_sub') ? copy.subtitles : '';
      case 'rating_imdb':
        return _ratingLabel('IMDb', outOfTen(data.number('rating_imdb')));
      case 'rating_tmdb':
        return _ratingLabel('TMDB', outOfTen(data.number('rating_tmdb')));
      case 'rating_rt':
        return _ratingLabel('RT', percent(data.number('rating_rt_critic')));
      case 'rating_rt_audience':
        return _ratingLabel('RT Audience', percent(data.number('rating_rt_audience')));
      case 'advisory_age':
        final age = data.number('advisory_age');
        return age != null && age > 0 ? '${age.toInt()}+' : '';
      case 'year':
        final year = data.number('year');
        return year != null && year > 0 ? '${year.toInt()}' : '';
      case 'runtime':
        return runtimeText(data.number('runtime'), copy);
      case 'original_language':
        return languageText(data.text('original_language'));
      case 'show_status':
        return showStatusText(data.text('show_status'), copy);
      default:
        return data.text(id);
    }
  }

  /// A rating's score without its mark ("7.8", "93%"), else empty.
  static String score(String id, SiloOverlayData data) => switch (id) {
    'rating_imdb' => outOfTen(data.number('rating_imdb')),
    'rating_tmdb' => outOfTen(data.number('rating_tmdb')),
    'rating_rt' => percent(data.number('rating_rt_critic')),
    'rating_rt_audience' => percent(data.number('rating_rt_audience')),
    _ => '',
  };

  static const _valueKeyed = {
    'resolution',
    'hdr',
    'audio',
    'audio_channels',
    'video_codec',
    'container',
    'aspect_ratio',
    'release_type',
    'edition',
    'content_rating',
    'original_language',
    'studio',
    'network',
  };

  /// The key a `valueImages` entry matches: the value as the API sends it,
  /// or empty for a badge that takes none.
  static String valueKey(String id, SiloOverlayData data) {
    if (id == 'resolution_hdr') {
      if (data.text('resolution').isEmpty) return '';
      return _joined([data.text('resolution'), data.text('hdr')]);
    }
    if (id == 'resolution_hdr_audio') {
      return _joined([data.text('resolution'), data.text('hdr'), data.text('audio')]);
    }
    if (id == 'show_status') return showStatusKey(data.text('show_status'));
    return _valueKeyed.contains(id) ? data.text(id) : '';
  }

  /// The icon a badge draws for [data] (its value's own, else its static
  /// one), or null. `hdr10`, `hdr`, `atmos` and `av1` are wordmarks.
  static String? iconFor(SiloOverlayEntry entry, SiloOverlayData data) {
    switch (entry.id) {
      case 'hdr':
        final hdr = data.text('hdr');
        if (hdr.contains('DV')) return 'dolby-vision';
        if (hdr == 'HDR10') return 'hdr10';
        if (hdr == 'HDR') return 'hdr';
        return null;
      case 'resolution_hdr' || 'resolution_hdr_audio':
        return data.text('hdr').contains('DV') ? 'dolby-vision' : null;
      case 'audio':
        final audio = data.text('audio');
        if (audio.isEmpty) return null;
        return audio.toLowerCase() == 'atmos' ? 'atmos' : 'volume';
      case 'video_codec':
        final codec = data.text('video_codec');
        if (codec.isEmpty) return null;
        return codec == 'AV1' ? 'av1' : 'film';
      case 'request_status':
        return null;
      default:
        return entry.icon;
    }
  }

  /// A wordmark icon's text, drawn bold in the icon's place; null for a
  /// glyph icon.
  static String? wordmark(String? icon) => switch (icon) {
    'hdr' => 'HDR',
    'hdr10' => 'HDR10',
    'atmos' => 'ATMOS',
    'av1' => 'AV1',
    _ => null,
  };

  /// "4K"/"8K" for UHD, "1080p" for a line count, else the value in capitals.
  static String prettyResolution(String value) {
    final text = value.trim();
    final lowered = text.toLowerCase();
    if (lowered.isEmpty) return '';
    if (lowered == '2160p' || lowered == '4k' || lowered == 'uhd') return '4K';
    if (lowered == '4320p' || lowered == '8k') return '8K';
    if (RegExp(r'^\d+p$').hasMatch(lowered)) return lowered;
    return value.toUpperCase();
  }

  /// The dynamic range in a combined badge: any Dolby Vision is "DV",
  /// HDR10+ keeps its name, and anything else is "HDR".
  static String compactHdr(String hdr) {
    if (hdr.isEmpty) return '';
    if (hdr.contains('DV')) return 'DV';
    if (hdr.contains('HDR10+')) return 'HDR10+';
    return 'HDR';
  }

  static String _ratingLabel(String mark, String value) => value.isEmpty ? '' : '$mark $value';

  /// A score out of 10 to one decimal ("7.8"), else empty.
  static String outOfTen(num? value) {
    if (value == null) return '';
    var tenths = (value * 10 + 0.5).floor();
    var sign = '';
    if (tenths < 0) {
      sign = '-';
      tenths = -tenths;
    }
    return '$sign${tenths ~/ 10}.${tenths % 10}';
  }

  /// A score out of 100 as a percentage ("93%"), else empty.
  static String percent(num? value) => value == null ? '' : '${(value + 0.5).floor()}%';

  /// "2h 43m", "43m", or empty.
  static String runtimeText(num? minutes, SiloOverlayCopy copy) {
    if (minutes == null || minutes <= 0) return '';
    final whole = minutes.toInt();
    final hours = whole ~/ 60;
    final rest = whole % 60;
    return hours > 0 ? copy.runtimeHoursMinutes(hours, rest) : copy.runtimeMinutes(rest);
  }

  /// The language's English name ("English"), the code in capitals when it
  /// has none, or empty.
  static String languageText(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return '';
    final base = trimmed.split(RegExp('[-_]')).first;
    return LanguageCodes.getLanguageName(base) ?? trimmed.toUpperCase();
  }

  /// The normalized status the value keys use: Returning, Ended, Cancelled
  /// or Upcoming, else the value as sent.
  static String showStatusKey(String status) {
    final lowered = status.toLowerCase();
    if (lowered.isEmpty) return '';
    if (const ['returning', 'returning series', 'continuing', 'in_production', 'in production'].contains(lowered)) {
      return 'Returning';
    }
    if (lowered == 'ended') return 'Ended';
    if (lowered == 'cancelled' || lowered == 'canceled') return 'Cancelled';
    if (lowered == 'upcoming' || lowered == 'planned') return 'Upcoming';
    return status;
  }

  static String showStatusText(String status, SiloOverlayCopy copy) => switch (showStatusKey(status)) {
    'Returning' => copy.returning,
    'Ended' => copy.ended,
    'Cancelled' => copy.cancelled,
    'Upcoming' => copy.upcoming,
    final other => other,
  };

  static String _joined(List<String> parts) => parts.where((p) => p.isNotEmpty).join(' ');

  /// The badge for [data] under [look] and its stored [config], or null when
  /// the card has no value for it.
  static SiloOverlayBadge? badge(
    SiloOverlayEntry entry,
    SiloOverlayData data,
    SiloOverlayLook look,
    SiloOverlayItemConfig? config, [
    SiloOverlayCopy copy = SiloOverlayCopy.english,
  ]) {
    final text = label(entry.id, data, copy);
    if (text.isEmpty) return null;
    var icon = iconFor(entry, data);
    final showIcon = config?.showIcon ?? look.preferIcon;
    if (!(entry.iconCapable && icon != null && showIcon)) icon = null;
    final key = valueKey(entry.id, data);
    final points = score(entry.id, data);
    return SiloOverlayBadge(
      id: entry.id,
      label: text,
      accent: config?.accent ?? entry.accent,
      icon: icon,
      sourceMark: entry.sourceMark != null && points.isNotEmpty ? entry.sourceMark : null,
      score: points.isEmpty ? null : points,
      image: config?.image,
      valueImage: key.isEmpty ? null : config?.valueImages?[key],
    );
  }

  /// What [badge] draws without (or, [withImage], with) its uploaded icon.
  static SiloOverlayFinished finish(SiloOverlayBadge badge, SiloOverlayLook look, {bool withImage = false}) {
    String? chip = !withImage && look.sourceChips ? badge.sourceMark : null;
    final scoreOnly = (withImage || chip != null) && badge.score != null;
    final markText = withImage ? null : wordmark(badge.icon);
    // A label the badge's wordmark spells is dropped, as on the web, even
    // when an uploaded image stands in for the mark.
    final badgeMark = wordmark(badge.icon);
    String text;
    if (scoreOnly) {
      text = badge.score!;
    } else if (badgeMark != null && badgeMark.toLowerCase() == badge.label.trim().toLowerCase()) {
      text = '';
    } else {
      text = badge.label;
    }
    if (look.uppercase) {
      text = text.toUpperCase();
      chip = chip?.toUpperCase();
    }
    return SiloOverlayFinished(chip: chip, text: text, scoreOnly: scoreOnly, markText: markText);
  }

  /// The card's badges at each position, capped (three a corner, four a rail).
  static Map<SiloOverlayPosition, List<SiloOverlayBadge>> resolve(
    SiloOverlayPrefs prefs,
    SiloOverlayData data,
    SiloOverlayLook look, [
    SiloOverlayCopy copy = SiloOverlayCopy.english,
  ]) {
    return {
      for (final position in SiloOverlayPosition.values)
        position: () {
          final cap = position.isRail ? SiloCardOverlays.maxRail : SiloCardOverlays.maxCorner;
          final list = <SiloOverlayBadge>[];
          for (final entry in SiloOverlayRegistry.placed(prefs, position)) {
            if (list.length >= cap) break;
            final resolved = badge(entry, data, look, prefs.items[entry.id], copy);
            if (resolved != null) list.add(resolved);
          }
          return list;
        }(),
    };
  }

  /// The two bottom corners as rows from the top, each `(left, right)` (null
  /// where a corner has fewer badges), so the shorter corner lines up with
  /// the bottom.
  static List<(T?, T?)> bottomRows<T>(List<T> left, List<T> right) {
    final levels = math.max(left.length, right.length);
    T? at(List<T> list, int index) => index < 0 || index >= list.length ? null : list[index];
    return [
      for (var level = 0; level < levels; level++)
        (at(left, level - levels + left.length), at(right, level - levels + right.length)),
    ];
  }

  /// How many of a band's marks ([widths], in order) fit whole in [width]
  /// with [gap] around a [dividerWidth] divider before each after the first:
  /// at least one, which may then truncate.
  static int bandFit(List<double> widths, double width, double gap, double dividerWidth) {
    if (widths.isEmpty) return 0;
    var used = widths.first;
    var count = 1;
    for (var i = 1; i < widths.length; i++) {
      used += 2 * gap + dividerWidth + widths[i];
      if (used > width + 0.5) break;
      count++;
    }
    return count;
  }
}

// -----------------------------------------------------------------------------
// Layout maths
// -----------------------------------------------------------------------------

/// A badge's measured size, in logical px.
typedef SiloBadgeSize = ({double w, double h});

/// A badge's top-left offset inside its block, in logical px.
typedef SiloBadgeOffset = ({double x, double y});

/// Where a card's badge layer starts and stops, in logical px.
class SiloOverlayInsets {
  /// The scale of the web's lengths on this card.
  final double k;

  /// From the left, right and top edges to a corner stack or rail.
  final double side;

  /// From the bottom edge to the bottom row, including the progress lift.
  final double bottom;

  /// From the right edge to the end of the top row: it stops short of the
  /// watch-status corner.
  final double topRight;

  const SiloOverlayInsets({required this.k, required this.side, required this.bottom, required this.topRight});
}

/// The card-overlay rules that decide placement from measured sizes (the
/// web's `CardOverlays.tsx`, Silo Android's `OverlayLayoutMath`), free of
/// widgets so they can be checked on their own.
abstract final class SiloOverlayLayoutMath {
  /// A card's insets. A poster scales the web's lengths by its width over
  /// 185 px, a wide card draws them at 1. A card that draws a progress bar
  /// along its artwork's bottom lifts the bottom row one inset clear of it.
  /// The top row always keeps the top-right corner clear: on a poster it is
  /// Silo's watch status, on a wide card Plezilo's own watched check.
  static SiloOverlayInsets insets({required double width, required bool wide, required bool progress}) {
    final k = wide ? 1.0 : width / SiloCardOverlays.referenceWidth;
    final edge = SiloCardOverlays.edgeInset * k;
    return SiloOverlayInsets(
      k: k,
      side: edge,
      bottom: edge + (progress ? edge : 0),
      topRight: (SiloCardOverlays.edgeInset + SiloCardOverlays.watchStatusReserve) * k,
    );
  }

  /// Whether a left and a right badge share one bottom row.
  static bool fitsOnOneLine(double leftWidth, double rightWidth, double available, double gap) =>
      leftWidth + gap + rightWidth <= available + 0.01;

  /// Where the badges of the two bottom corners go (the web's `BottomRows`).
  /// One row per level, counted from the bottom, so the shorter corner lines
  /// up with the bottom and a badge shares its width only with the badge at
  /// the same height in the other corner. A row is a CSS `flex-wrap` line:
  /// the left badge at the start, the right at the end, [gap] apart, bottom
  /// aligned; a pair too wide for [available] puts the right badge on a line
  /// of its own under the left one, [stackGap] below. Rows are [stackGap]
  /// apart. Widths are as measured against [available].
  ///
  /// [left] and [right] list each corner's badges top to bottom; the result
  /// holds each badge's offset from the block's top-left, in the same order,
  /// and the block's height.
  static ({List<SiloBadgeOffset> left, List<SiloBadgeOffset> right, double height}) bottomRows(
    List<SiloBadgeSize> left,
    List<SiloBadgeSize> right, {
    required double available,
    required double gap,
    required double stackGap,
  }) {
    final leftOut = List<SiloBadgeOffset>.filled(left.length, (x: 0, y: 0));
    final rightOut = List<SiloBadgeOffset>.filled(right.length, (x: 0, y: 0));
    final levels = math.max(left.length, right.length);
    var y = 0.0;
    for (var level = 0; level < levels; level++) {
      if (level > 0) y += stackGap;
      final l = left.length - levels + level;
      final r = right.length - levels + level;
      final hasLeft = l >= 0;
      final hasRight = r >= 0;
      if (hasLeft && hasRight && !fitsOnOneLine(left[l].w, right[r].w, available, gap)) {
        leftOut[l] = (x: 0, y: y);
        y += left[l].h + stackGap;
        rightOut[r] = (x: available - right[r].w, y: y);
        y += right[r].h;
        continue;
      }
      final line = math.max(hasLeft ? left[l].h : 0.0, hasRight ? right[r].h : 0.0);
      if (hasLeft) leftOut[l] = (x: 0, y: y + line - left[l].h);
      if (hasRight) rightOut[r] = (x: available - right[r].w, y: y + line - right[r].h);
      y += line;
    }
    return (left: leftOut, right: rightOut, height: y);
  }

  /// The watch-status count's capsule width for a label [textWidth] wide at
  /// [k]: the label with 0.4 em either side and a 1 px border, at least as
  /// wide as it is tall.
  static double countWidth(double textWidth, double k) {
    final size = SiloCardOverlays.watchStatusSize * k;
    final font = SiloCardOverlays.watchStatusFontSize * k;
    return math.max(size, textWidth + font * 0.4 * 2 + 2);
  }
}

// -----------------------------------------------------------------------------
// Looks
// -----------------------------------------------------------------------------

class SiloOverlayShadow {
  final double x;
  final double y;
  final double blur;
  final int color;

  const SiloOverlayShadow(this.x, this.y, this.blur, this.color);
}

/// How a badge's accent paints.
enum SiloAccentStrategy { background, border, text }

/// A preset's look (web `presets.ts`) with the style's overrides (`style.ts`),
/// at the reference width.
class SiloOverlayLook {
  final String id;
  final bool band;
  final bool sourceChips;
  final int weight;
  final bool uppercase;

  /// Letter spacing as a share of the font size (the web's `tracking-*`).
  final double letterSpacingEm;
  final double fontSize;
  final double padX;
  final double padY;

  /// Corner radius in px, or -1 for a capsule.
  final double radius;
  final double borderWidth;

  /// The square look's accent stripe width.
  final double accentLeft;
  final SiloOverlayShadow? textShadow;
  final SiloOverlayShadow? boxShadow;
  final double iconSize;
  final double iconGap;
  final bool preferIcon;
  final double stackGap;
  final SiloAccentStrategy strategy;

  /// The style's colours (null for the preset's own) and the fill behind
  /// the text from half opacity.
  final int? fill;
  final int? textColor;
  final int? borderColor;
  final int? solid;
  final bool styled;

  const SiloOverlayLook({
    required this.id,
    this.band = false,
    this.sourceChips = false,
    required this.weight,
    this.uppercase = true,
    this.letterSpacingEm = SiloCardOverlays.trackingWide,
    required this.fontSize,
    required this.padX,
    required this.padY,
    required this.radius,
    required this.borderWidth,
    this.accentLeft = 0,
    this.textShadow,
    this.boxShadow,
    required this.iconSize,
    required this.iconGap,
    required this.preferIcon,
    required this.stackGap,
    required this.strategy,
    this.fill,
    this.textColor,
    this.borderColor,
    this.solid,
    this.styled = false,
  });

  static SiloOverlayLook preset(String preset) {
    const textShadow = SiloOverlayShadow(0, 1, 2, 0xD9000000);
    return switch (preset) {
      'minimal' => const SiloOverlayLook(
        id: 'minimal',
        weight: 600,
        letterSpacingEm: SiloCardOverlays.trackingWidest,
        fontSize: 9,
        padX: 4,
        padY: 0,
        radius: 8,
        borderWidth: 0,
        iconSize: 10,
        iconGap: 4,
        preferIcon: false,
        stackGap: 2,
        strategy: SiloAccentStrategy.text,
        textShadow: textShadow,
      ),
      'vibrant' => const SiloOverlayLook(
        id: 'vibrant',
        weight: 700,
        fontSize: 10,
        padX: 8,
        padY: 2,
        radius: 10,
        borderWidth: 0,
        iconSize: 12,
        iconGap: 4,
        preferIcon: true,
        stackGap: 4,
        strategy: SiloAccentStrategy.background,
        boxShadow: SiloOverlayShadow(0, 1, 2, 0x40000000),
      ),
      'pill' => const SiloOverlayLook(
        id: 'pill',
        weight: 600,
        fontSize: 10,
        padX: 10,
        padY: 4,
        radius: -1,
        borderWidth: 1,
        iconSize: 12,
        iconGap: 4,
        preferIcon: true,
        stackGap: 4,
        strategy: SiloAccentStrategy.background,
      ),
      'square' => const SiloOverlayLook(
        id: 'square',
        weight: 700,
        letterSpacingEm: SiloCardOverlays.trackingWidest,
        fontSize: 9,
        padX: 6,
        padY: 2,
        radius: 8,
        borderWidth: 0,
        accentLeft: 2,
        iconSize: 10,
        iconGap: 4,
        preferIcon: false,
        stackGap: 2,
        strategy: SiloAccentStrategy.border,
      ),
      'plate' => const SiloOverlayLook(
        id: 'plate',
        sourceChips: true,
        weight: 800,
        fontSize: 12,
        padX: 7,
        padY: 4,
        radius: 6,
        borderWidth: 1,
        iconSize: 13,
        iconGap: 5,
        preferIcon: true,
        stackGap: 4,
        strategy: SiloAccentStrategy.border,
        boxShadow: SiloOverlayShadow(0, 2, 6, 0x59000000),
      ),
      'band' => const SiloOverlayLook(
        id: 'band',
        band: true,
        weight: 800,
        fontSize: 12.5,
        padX: 0,
        padY: 1,
        radius: 0,
        borderWidth: 0,
        iconSize: 13,
        iconGap: 3,
        preferIcon: false,
        stackGap: 7,
        strategy: SiloAccentStrategy.text,
        textShadow: SiloOverlayShadow(0, 1, 3, 0xBF000000),
      ),
      _ => const SiloOverlayLook(
        id: 'classic',
        weight: 600,
        fontSize: 10,
        padX: 8,
        padY: 2,
        radius: -1,
        borderWidth: 1,
        iconSize: 11,
        iconGap: 4,
        preferIcon: false,
        stackGap: 4,
        strategy: SiloAccentStrategy.background,
      ),
    };
  }

  /// [preset]'s look with [style]'s overrides.
  static SiloOverlayLook of(String preset, SiloOverlayStyle? style) {
    final base = SiloOverlayLook.preset(preset);
    if (style == null) return base;
    final scale = style.size ?? 1.0;
    final weight = switch (style.fontWeight) {
      'regular' => 400,
      'semibold' => 600,
      'extrabold' => 800,
      _ => base.weight,
    };
    final radius = switch (style.shape) {
      'pill' => -1.0,
      'rounded' => 6.0,
      'square' => 2.0,
      _ => base.radius,
    };
    var boxShadow = base.boxShadow;
    if (style.shadow == false) boxShadow = null;
    if (style.shadow == true) boxShadow ??= const SiloOverlayShadow(0, 2, 6, 0x59000000);
    final fontSize = base.fontSize * scale;
    var padX = base.padX * scale;
    var padY = base.padY * scale;
    final background = style.background == null ? null : siloOverlayColor(style.background!);
    final alpha = background == null ? 0.0 : ((background >> 24) & 0xFF) / 255;
    final borderWidth = style.borderWidth ?? 0;
    // A framed badge gets padding; bare text would run to the frame.
    if (alpha > 0 || borderWidth > 0) {
      padX = math.max(padX, fontSize * 0.6);
      padY = math.max(padY, fontSize * 0.2);
    }
    // From half opacity the fill, not the artwork, is behind the text.
    final solid = alpha >= 0.5 ? background : null;
    final textColor = style.textColor == null ? null : siloOverlayColor(style.textColor!);
    final borderColor = style.borderColor == null ? null : siloOverlayColor(style.borderColor!);
    return SiloOverlayLook(
      id: base.id,
      band: base.band,
      sourceChips: base.sourceChips,
      weight: weight,
      uppercase: style.uppercase ?? base.uppercase,
      letterSpacingEm: base.letterSpacingEm,
      fontSize: fontSize,
      padX: padX,
      padY: padY,
      radius: radius,
      borderWidth: style.borderWidth?.toDouble() ?? base.borderWidth,
      accentLeft: base.accentLeft,
      textShadow: solid != null ? null : base.textShadow,
      boxShadow: boxShadow,
      iconSize: base.iconSize * scale,
      iconGap: base.iconGap * scale,
      preferIcon: base.preferIcon,
      stackGap: base.stackGap * scale,
      strategy: base.strategy,
      fill: background,
      textColor: textColor,
      borderColor: borderColor,
      solid: solid,
      styled: background != null || textColor != null || borderColor != null || style.borderWidth != null,
    );
  }

  /// Whether rail badges sit flush against the card's edge as tabs: a filled
  /// look's do; bare text (minimal, band) keeps the corner inset.
  bool get flushRails => !band && id != 'minimal';
}

/// A badge's colours under a look: fill, text, border and the square look's
/// accent stripe (null for none).
class SiloOverlayPaint {
  final int? fill;
  final int text;
  final int? border;
  final int? accentLeft;

  const SiloOverlayPaint({this.fill, required this.text, this.border, this.accentLeft});

  /// The preset's badge style for [accent] (`#rrggbb` or null), then the
  /// style's colours over it.
  factory SiloOverlayPaint.of(SiloOverlayLook look, String? accent) {
    final accentColor = accent == null ? null : siloOverlayColor(accent);
    final hasAccent = accentColor != null;
    int? fill;
    var text = 0xFFFFFFFF;
    int? border;
    int? accentLeft;
    switch (look.id) {
      case 'minimal' || 'band':
        text = look.id == 'band' ? 0xFFFFFFFF : 0xD9FFFFFF;
        if (hasAccent) text = _opaque(accentColor);
      case 'classic':
        fill = hasAccent ? siloOverlayMix(accentColor, 0.28, 0x99000000) : 0x99000000;
        border = 0x26FFFFFF;
      case 'vibrant':
        fill = hasAccent ? _opaque(accentColor) : 0xF2DCDCDC;
        text = hasAccent ? 0xFFFFFFFF : 0xFF000000;
      case 'pill':
        fill = hasAccent ? siloOverlayMix(accentColor, 0.20, 0xB314141E) : 0xB314141E;
        border = 0x26FFFFFF;
      case 'square':
        fill = 0xCC000000;
        if (hasAccent) {
          text = _opaque(accentColor);
          accentLeft = _opaque(accentColor);
        }
      case 'plate':
        fill = 0xB8000000;
        border = hasAccent ? siloOverlayMix(accentColor, 0.45, 0x00000000) : 0x1AFFFFFF;
    }
    if (!look.styled) return SiloOverlayPaint(fill: fill, text: text, border: border, accentLeft: accentLeft);
    final strategy = look.strategy;
    final solid = look.solid;
    final accentText =
        hasAccent &&
        strategy == SiloAccentStrategy.text &&
        (solid == null || siloOverlayContrast(accentColor, solid) >= 3);
    final accentFill =
        hasAccent &&
        (strategy == SiloAccentStrategy.background || (strategy == SiloAccentStrategy.text && !accentText));
    if (look.fill != null) fill = accentFill ? siloOverlayMix(accentColor, 0.30, look.fill!) : look.fill;
    var textOverride = look.textColor;
    if (textOverride == null && solid != null) textOverride = siloOverlayReadableOn(solid);
    if (textOverride != null && !accentText) text = _opaque(textOverride);
    if (look.borderColor != null && !(hasAccent && strategy == SiloAccentStrategy.border)) border = look.borderColor;
    // A border the preset does not colour takes the text's colour, as CSS's
    // currentColor does.
    if (look.borderWidth > 0 && border == null) border = text;
    return SiloOverlayPaint(fill: fill, text: text, border: border, accentLeft: accentLeft);
  }
}

// -----------------------------------------------------------------------------
// Colours
// -----------------------------------------------------------------------------

/// `#rrggbb` or `#rrggbbaa` as `0xAARRGGBB`.
int siloOverlayColor(String hex) {
  if (hex.length < 7) return 0xFF000000;
  final rgb = int.tryParse(hex.substring(1, 7), radix: 16) ?? 0;
  final alpha = hex.length >= 9 ? int.tryParse(hex.substring(7, 9), radix: 16) ?? 0xFF : 0xFF;
  return (alpha << 24) | rgb;
}

int _opaque(int color) => 0xFF000000 | (color & 0x00FFFFFF);

double _channel(int color, int shift) => ((color >> shift) & 0xFF) / 255;

int _pack(double a, double r, double g, double b) {
  int c(double v) => (v * 255).round().clamp(0, 255);
  return (c(a) << 24) | (c(r) << 16) | (c(g) << 8) | c(b);
}

/// CSS's `color-mix(in srgb, a share, b)`: premultiplied interpolation.
int siloOverlayMix(int a, double share, int b) {
  final aa = _channel(a, 24);
  final ba = _channel(b, 24);
  final alpha = aa * share + ba * (1 - share);
  if (alpha <= 0) return 0;
  double mixed(int shift) => (_channel(a, shift) * aa * share + _channel(b, shift) * ba * (1 - share)) / alpha;
  return _pack(alpha, mixed(16), mixed(8), mixed(0));
}

double _luminance(int color) {
  double linear(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * linear(_channel(color, 16)) +
      0.7152 * linear(_channel(color, 8)) +
      0.0722 * linear(_channel(color, 0));
}

/// The WCAG contrast ratio of two colours, ignoring alpha.
double siloOverlayContrast(int a, int b) {
  final x = _luminance(a);
  final y = _luminance(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// A CSS shadow blur length as a Flutter blur radius: CSS blurs with a
/// sigma of half the length, Flutter with 0.57735 × radius + 0.5.
double siloCssBlurRadius(double blur) => math.max((blur / 2 - 0.5) / 0.57735, 0);

/// Black or white, whichever reads better on [color].
int siloOverlayReadableOn(int color) => _luminance(color) > 0.4 ? 0xFF000000 : 0xFFFFFFFF;
