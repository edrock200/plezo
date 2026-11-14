import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_kind.dart';
import '../providers/multi_server_provider.dart';
import '../services/settings_service.dart';
import '../services/silo/silo_card_overlay_store.dart';
import '../services/silo/silo_card_overlays.dart';
import '../services/silo/silo_client.dart';
import '../utils/json_utils.dart';
import '../utils/media_image_helper.dart';
import 'silo_overlay_icons.dart';
import 'watched_indicator.dart';

/// The artwork's shape for card overlays: a poster scales Silo's lengths by
/// its width over 185 px; a landscape card or episode still draws them at the
/// library density's scale ([SiloOverlayScale.wideScaleForDensity]). Both
/// also follow the system text size, held to 1-1.35x.
enum SiloOverlayCardShape { poster, wide }

/// The system text scale overlays read: how much the default text size has
/// grown ([SiloOverlayScale.textFactor] holds it to 1-1.35).
double siloOverlayTextScaleOf(BuildContext context) {
  final scaler = MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
  return scaler.scale(SiloOverlayScale.referenceFontSize) / SiloOverlayScale.referenceFontSize;
}

/// A wide Silo card's overlay scale: the library density's card scale times
/// the text factor. Plezy's watched check on a wide Silo card (episode
/// thumbnails, landscape cards) is drawn at it, so it matches the badges.
double siloWideOverlayScaleOf(BuildContext context) => SiloOverlayScale.value(
  SiloOverlayScale.wideScaleForDensity(SettingsService.instance.read(SettingsService.libraryDensity)),
  siloOverlayTextScaleOf(context),
);

/// Plezy's watch-state overlay for a card's artwork ([WatchedIndicator]),
/// and on a Silo item Silo's own look, as Silo's apps draw it (Silo Android
/// #882, the web's `CardWatchStatus`): a Silo poster's top-right corner is
/// Silo's watch status (a check, or the episodes a started series or season
/// has left) in place of Plezy's check and unwatched count, whether or not
/// badges are on; while its profile shows card overlays, Silo's badges
/// ([SiloCardOverlayLayer]) are drawn too. Silo draws no watch status on
/// landscape artwork, so a wide Silo card keeps Plezy's check there, the one
/// indicator it has. Progress bars stay Plezy's. Plex, Jellyfin and Emby
/// items get [WatchedIndicator] unchanged.
class CardArtworkOverlays extends StatefulWidget {
  const CardArtworkOverlays({
    super.key,
    required this.item,
    required this.shape,
    this.size = WatchedIndicatorSize.standard,
  });

  final MediaItem item;
  final SiloOverlayCardShape shape;
  final WatchedIndicatorSize size;

  /// Finds the overlay store of a Silo item's client; tests replace it.
  @visibleForTesting
  static SiloCardOverlayStore? Function(BuildContext context, MediaItem item)? debugStoreResolver;

  /// Loads an uploaded overlay image's URL; tests replace it.
  @visibleForTesting
  static String? Function(BuildContext context, MediaItem item, String ref)? debugImageUrlResolver;

  static SiloClient? _clientFor(BuildContext context, MediaItem item) {
    final serverId = item.serverId;
    if (serverId == null) return null;
    final provider = Provider.of<MultiServerProvider?>(context, listen: false);
    final client = provider?.getClientForServer(ServerId(serverId));
    return client is SiloClient ? client : null;
  }

  static SiloCardOverlayStore? storeFor(BuildContext context, MediaItem item) {
    if (item is! SiloMediaItem) return null;
    final resolver = debugStoreResolver;
    if (resolver != null) return resolver(context, item);
    return _clientFor(context, item)?.cardOverlays;
  }

  @override
  State<CardArtworkOverlays> createState() => _CardArtworkOverlaysState();
}

class _CardArtworkOverlaysState extends State<CardArtworkOverlays> {
  SiloCardOverlayStore? _store;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveStore();
  }

  @override
  void didUpdateWidget(CardArtworkOverlays oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.serverId != widget.item.serverId || oldWidget.item.backend != widget.item.backend) {
      _resolveStore();
    }
  }

  void _resolveStore() {
    final store = CardArtworkOverlays.storeFor(context, widget.item);
    if (!identical(store, _store)) {
      _store?.removeListener(_onStoreChanged);
      // A store its client already closed is not listened to.
      if (store != null && !store.isDisposed) store.addListener(_onStoreChanged);
    }
    _store = store;
    // Never notifies synchronously: the read lands in a later frame.
    if (store != null && !store.isDisposed) store.ensureLoaded();
  }

  /// The store changed, or its client closed it (the client was replaced or
  /// removed): rebuild, and in the second case look the client up again.
  void _onStoreChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onStoreChanged());
      return;
    }
    setState(() {
      if (_store?.isDisposed ?? false) _resolveStore();
    });
  }

  @override
  void dispose() {
    _store?.removeListener(_onStoreChanged);
    super.dispose();
  }

  String? _imageUrl(String ref) {
    final resolver = CardArtworkOverlays.debugImageUrlResolver;
    if (resolver != null) return resolver(context, widget.item, ref);
    return CardArtworkOverlays._clientFor(context, widget.item)?.cardOverlayImageUrl(ref);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (item is! SiloMediaItem) return WatchedIndicator(item: item, size: widget.size);
    final store = _store;
    final settings = store?.value;
    final badges = settings != null && settings.enabled;
    final poster = widget.shape == SiloOverlayCardShape.poster;
    final wideScale = SiloOverlayScale.wideScaleForDensity(
      SettingsService.instance.read(SettingsService.libraryDensity),
    );
    // A wide Silo card keeps Plezy's check, at the badges' scale (Silo
    // Android #912 scales episode thumbnails' checks the same way).
    final checkScale = poster ? 1.0 : SiloOverlayScale.value(wideScale, siloOverlayTextScaleOf(context));
    if (!poster && !badges) return WatchedIndicator(item: item, size: widget.size, checkScale: checkScale);
    // Plezy's "watched indicators" and "unwatched count" settings still gate
    // Silo's corner.
    final showWatched = SettingsService.instance.read(SettingsService.showWatchedIndicators);
    final showCount = SettingsService.instance.read(SettingsService.showUnwatchedCount);
    return Stack(
      fit: StackFit.expand,
      children: [
        WatchedIndicator(item: item, size: widget.size, showWatchStatus: !poster, checkScale: checkScale),
        SiloCardOverlayLayer(
          settings: badges ? settings : SiloCardOverlaySettings.off,
          data: SiloOverlayData.ofRaw(item.raw),
          shape: widget.shape,
          wideScale: wideScale,
          progress: siloCardHasProgressBar(item),
          watched: poster && showWatched && item.isWatched,
          episodesLeft: poster && showCount ? siloEpisodesLeftOf(item) : 0,
          imageUrl: _imageUrl,
          onImageFailed: store?.imageFailed,
        ),
      ],
    );
  }
}

/// Whether [WatchedIndicator] draws a progress bar along the artwork's bottom
/// for [item]: the bottom badge row lifts clear of it.
bool siloCardHasProgressBar(MediaItem item) => item.hasActiveProgress || (item.isSeason && item.isPartiallyWatched);

/// The episodes a started, unfinished Silo series or season has left (the
/// watch-status corner's count), from its leaf counts, else the card's
/// `user_state` counts.
int siloEpisodesLeftOf(MediaItem item) {
  if (item.kind != MediaKind.show && item.kind != MediaKind.season) return 0;
  final state = item.raw?['user_state'];
  final stateMap = state is Map ? state : const {};
  final total = item.leafWatchTotal;
  final viewed = item.viewedLeafCount;
  final watched = viewed ?? flexibleInt(stateMap['watched_count']);
  final unplayed = total != null && viewed != null
      ? math.max(0, total - viewed)
      : flexibleInt(stateMap['unplayed_count']);
  return siloEpisodesLeft(played: item.isWatched, watched: watched, unplayed: unplayed);
}

/// Silo's badges for one card, laid out as the web's `CardOverlays` lays
/// them out. Layouts are computed once per (settings, card data, size) and
/// cached, text widths once per (font, size, text); nothing runs per frame.
/// Everything draws at one overlay scale ([SiloOverlayScale]): the card's
/// scale times the system text size held to 1-1.35x. Badge text is sized in
/// exact pixels from it and drawn with [TextScaler.noScaling], so the text
/// size counts once. Paints no focusable and ignores pointers.
class SiloCardOverlayLayer extends StatelessWidget {
  const SiloCardOverlayLayer({
    super.key,
    required this.settings,
    required this.data,
    required this.shape,
    this.wideScale = 1,
    this.progress = false,
    this.watched = false,
    this.episodesLeft = 0,
    required this.imageUrl,
    this.onImageFailed,
  });

  final SiloCardOverlaySettings settings;
  final SiloOverlayData data;
  final SiloOverlayCardShape shape;

  /// A wide card's scale before the text factor (the library density's,
  /// [SiloOverlayScale.wideScaleForDensity]); posters measure their width.
  final double wideScale;

  /// The card shows a progress bar: the bottom row lifts one inset over it.
  final bool progress;

  /// Draw the watched check in the watch-status corner.
  final bool watched;

  /// Draw this many episodes left in the watch-status corner (0 for none).
  final int episodesLeft;
  final String? Function(String ref) imageUrl;
  final void Function(String ref)? onImageFailed;

  @override
  Widget build(BuildContext context) {
    final fontFamily = DefaultTextStyle.of(context).style.fontFamily;
    final copy = _copyFor(LocaleSettings.currentLocale);
    final textScale = SiloOverlayScale.textFactor(siloOverlayTextScaleOf(context));
    // Decorative like the artwork under it: the card announces itself.
    return IgnorePointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) return const SizedBox.shrink();
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            if (width <= 0 || height <= 0) return const SizedBox.shrink();
            final layout = SiloOverlayLayout.cached(
              settings: settings,
              data: data,
              width: width,
              height: height,
              shape: shape,
              textScale: textScale,
              wideScale: wideScale,
              progress: progress,
              watched: watched,
              episodesLeft: episodesLeft,
              fontFamily: fontFamily,
              copy: copy,
            );
            if (layout.parts.isEmpty) return const SizedBox.shrink();
            final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
            return RepaintBoundary(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final part in layout.parts)
                    Positioned(
                      left: part.rect.left,
                      top: part.rect.top,
                      width: part.rect.width,
                      height: part.rect.height,
                      child: _partView(part, layout, fontFamily, dpr),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _partView(SiloOverlayPart part, SiloOverlayLayout layout, String? fontFamily, double dpr) {
    return switch (part) {
      SiloOverlayScrimPart(:final top) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: const [Color(0xD9000000), Color(0x99000000), Color(0x00000000)],
            stops: const [0, 0.55, 1],
          ),
        ),
      ),
      SiloOverlayDividerPart() => const ColoredBox(color: Color(0x66FFFFFF)),
      SiloOverlayCheckPart() => const SiloWatchedCheck(),
      SiloOverlayCountPart(:final label, :final fontSize) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xA6000000),
          borderRadius: BorderRadius.circular(part.rect.height / 2),
          border: Border.all(color: const Color(0x33FFFFFF)),
          boxShadow: siloShadowSm,
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            textScaler: TextScaler.noScaling,
            style: siloWatchCountStyle(fontSize, fontFamily),
          ),
        ),
      ),
      SiloOverlayBadgePart(:final plan) => SiloOverlayBadgeView(
        plan: plan,
        look: layout.look,
        k: layout.k,
        fontFamily: fontFamily,
        dpr: dpr,
        imageUrl: imageUrl,
        onImageFailed: onImageFailed,
      ),
    };
  }

  static AppLocale? _copyLocale;
  static SiloOverlayCopy _copy = SiloOverlayCopy.english;

  static SiloOverlayCopy _copyFor(AppLocale locale) {
    if (_copyLocale == locale) return _copy;
    final words = t.siloCardOverlays;
    _copyLocale = locale;
    return _copy = SiloOverlayCopy(
      multiAudio: words.multiAudio,
      subtitles: words.subtitles,
      runtimeHoursMinutes: (hours, minutes) => words.runtimeHoursMinutes(hours: hours, minutes: minutes),
      runtimeMinutes: (minutes) => words.runtimeMinutes(minutes: minutes),
      returning: words.returning,
      ended: words.ended,
      cancelled: words.cancelled,
      upcoming: words.upcoming,
    );
  }
}

// -----------------------------------------------------------------------------
// Layout (the web's CardOverlays; Silo's Roku app's overlayDraw.bs)
// -----------------------------------------------------------------------------

/// What a badge draws before its text.
enum SiloLeadKind { none, image, chip, mark, glyph }

/// One measured badge: its size and parts.
class SiloBadgePlan {
  SiloBadgePlan({
    required this.badge,
    required this.finished,
    required this.paint,
    required this.rail,
    required this.fontSize,
    required this.w,
    required this.h,
    this.valueImage,
    this.lead = SiloLeadKind.none,
    this.leadImage,
    this.leadW = 0,
    this.leadH = 0,
    this.markFontSize = 0,
    this.gap = 0,
    this.border = 0,
    this.left = 0,
    this.right = 0,
    this.padX = 0,
    this.padY = 0,
    this.contentHeight = 0,
    this.truncated = false,
  });

  /// True when the label was cut to the slot's width and draws an ellipsis.
  final bool truncated;

  final SiloOverlayBadge badge;
  final SiloOverlayFinished finished;
  final SiloOverlayPaint paint;

  /// The rail edge this badge sits flush against, or null.
  final AxisDirection? rail;
  final double fontSize;
  final double w;
  final double h;

  /// A value image that replaces the whole badge, or null.
  final String? valueImage;
  final SiloLeadKind lead;
  final String? leadImage;
  final double leadW;
  final double leadH;
  final double markFontSize;
  final double gap;
  final double border;
  final double left;
  final double right;
  final double padX;
  final double padY;
  final double contentHeight;
}

/// One placed piece of a card's overlays.
sealed class SiloOverlayPart {
  const SiloOverlayPart(this.rect);
  final Rect rect;
}

class SiloOverlayBadgePart extends SiloOverlayPart {
  const SiloOverlayBadgePart(super.rect, this.plan);
  final SiloBadgePlan plan;
}

class SiloOverlayScrimPart extends SiloOverlayPart {
  const SiloOverlayScrimPart(super.rect, {required this.top});
  final bool top;
}

class SiloOverlayDividerPart extends SiloOverlayPart {
  const SiloOverlayDividerPart(super.rect);
}

class SiloOverlayCheckPart extends SiloOverlayPart {
  const SiloOverlayCheckPart(super.rect);
}

class SiloOverlayCountPart extends SiloOverlayPart {
  const SiloOverlayCountPart(super.rect, this.label, this.fontSize);
  final String label;
  final double fontSize;
}

/// The episodes-left count's text: bold, white, tabular figures.
TextStyle siloWatchCountStyle(double fontSize, String? fontFamily) => TextStyle(
  fontFamily: fontFamily,
  color: const Color(0xFFFFFFFF),
  fontSize: fontSize,
  fontWeight: FontWeight.w700,
  letterSpacing: 0,
  wordSpacing: 0,
  height: 1,
  leadingDistribution: TextLeadingDistribution.even,
  fontFeatures: const [FontFeature.tabularFigures()],
);

typedef _LayoutKey = (
  SiloCardOverlaySettings,
  SiloOverlayData,
  double,
  double,
  SiloOverlayCardShape,
  double,
  double,
  bool,
  bool,
  int,
  String?,
  SiloOverlayCopy,
);

/// A card's overlays placed in its box.
class SiloOverlayLayout {
  SiloOverlayLayout._(this.look, this.k);

  final SiloOverlayLook look;

  /// The scale of the web's lengths on this card: its overlay scale, the
  /// card's scale times the text factor ([SiloOverlayScale]).
  final double k;
  final List<SiloOverlayPart> parts = [];

  static final _cache = <_LayoutKey, SiloOverlayLayout>{};
  static const _cacheLimit = 300;

  static final _widths = <String, double>{};
  static const _widthLimit = 800;

  @visibleForTesting
  static void clearCaches() {
    _cache.clear();
    _widths.clear();
  }

  /// [compute], remembered for the last few hundred distinct cards.
  static SiloOverlayLayout cached({
    required SiloCardOverlaySettings settings,
    required SiloOverlayData data,
    required double width,
    required double height,
    required SiloOverlayCardShape shape,
    double textScale = 1,
    double wideScale = 1,
    bool progress = false,
    bool watched = false,
    int episodesLeft = 0,
    String? fontFamily,
    SiloOverlayCopy copy = SiloOverlayCopy.english,
  }) {
    final key = (
      settings,
      data,
      width,
      height,
      shape,
      textScale,
      wideScale,
      progress,
      watched,
      episodesLeft,
      fontFamily,
      copy,
    );
    final hit = _cache.remove(key);
    if (hit != null) return _cache[key] = hit;
    final layout = compute(
      settings: settings,
      data: data,
      width: width,
      height: height,
      shape: shape,
      textScale: textScale,
      wideScale: wideScale,
      progress: progress,
      watched: watched,
      episodesLeft: episodesLeft,
      fontFamily: fontFamily,
      copy: copy,
    );
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    return _cache[key] = layout;
  }

  /// The width of [text] in the overlay font, measured once.
  static double textWidth(String text, double fontSize, int weight, String? fontFamily, {double letterSpacing = 0}) =>
      _measure(text, siloOverlayTextStyle(fontSize, weight, fontFamily, letterSpacing: letterSpacing));

  static double _measure(String text, TextStyle style) {
    if (text.isEmpty) return 0;
    final key =
        '${style.fontFamily}|${style.fontWeight}|${style.fontSize}|${style.letterSpacing}|'
        '${style.fontFeatures?.length ?? 0}|$text';
    final hit = _widths.remove(key);
    if (hit != null) return _widths[key] = hit;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    if (_widths.length >= _widthLimit) _widths.remove(_widths.keys.first);
    return _widths[key] = width;
  }

  static SiloOverlayLayout compute({
    required SiloCardOverlaySettings settings,
    required SiloOverlayData data,
    required double width,
    required double height,
    required SiloOverlayCardShape shape,
    double textScale = 1,
    double wideScale = 1,
    bool progress = false,
    bool watched = false,
    int episodesLeft = 0,
    String? fontFamily,
    SiloOverlayCopy copy = SiloOverlayCopy.english,
  }) {
    final look = settings.look;
    final insets = SiloOverlayLayoutMath.insets(
      width: width,
      wide: shape == SiloOverlayCardShape.wide,
      progress: progress,
      textScale: textScale,
      wideScale: wideScale,
    );
    final k = insets.k;
    final layout = SiloOverlayLayout._(look, k);
    final c = _Canvas(layout, settings, width, height, k, fontFamily);
    if (settings.enabled && !data.isEmpty) {
      final resolved = SiloOverlayBadges.resolve(settings.prefs, data, look, copy);
      final inset = insets.side;
      final topLeft = resolved[SiloOverlayPosition.topLeft]!;
      final bottomLeft = resolved[SiloOverlayPosition.bottomLeft]!;
      final bottomRight = resolved[SiloOverlayPosition.bottomRight]!;
      // The top row stops short of the top-right corner.
      final topWidth = width - inset - insets.topRight;
      if (look.band) {
        c.bandTop(topLeft, topWidth);
        c.bandBottom([...bottomLeft, ...bottomRight], insets.bottom);
      } else {
        c.stackTop(topLeft, topWidth);
        c.bottomRows(bottomLeft, bottomRight, insets.bottom);
      }
      final railInset = look.flushRails ? 0.0 : inset;
      c.rail(resolved[SiloOverlayPosition.leftEdge]!, railInset, left: true);
      c.rail(resolved[SiloOverlayPosition.rightEdge]!, railInset, left: false);
    }
    c.watchStatus(watched: watched, episodesLeft: episodesLeft);
    return layout;
  }
}

/// The text style overlay badges use, at an exact size and line height 1.
TextStyle siloOverlayTextStyle(double fontSize, int weight, String? fontFamily, {double letterSpacing = 0}) =>
    TextStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: _fontWeight(weight),
      // Every spacing field is set, so the drawn text cannot pick up the
      // theme's (Material's body styles carry 0.25 letter spacing) and come
      // out wider than it was measured, which ellipsized "1080p" to "108…".
      letterSpacing: letterSpacing,
      wordSpacing: 0,
      fontFeatures: const [],
      fontVariations: const [],
      decoration: TextDecoration.none,
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
    );

FontWeight _fontWeight(int weight) => switch (weight) {
  <= 400 => FontWeight.w400,
  <= 500 => FontWeight.w500,
  <= 600 => FontWeight.w600,
  <= 700 => FontWeight.w700,
  <= 800 => FontWeight.w800,
  _ => FontWeight.w900,
};

/// A wordmark's font size as a share of the icon size: the web draws them as
/// SVG text on a view box 12 high, at font 10 (ATMOS 9).
double siloWordmarkFontSize(String? icon, double iconSize) => iconSize * (icon == 'atmos' ? 9 : 10) / 12;

/// The ATMOS wordmark's letter spacing: 0.5 view-box units at font 9.
const siloAtmosTrackingEm = 0.5 / 9;

class _Canvas {
  _Canvas(this.layout, this.settings, this.width, this.height, this.k, this.fontFamily);

  final SiloOverlayLayout layout;
  final SiloCardOverlaySettings settings;
  final double width;
  final double height;
  final double k;
  final String? fontFamily;

  SiloOverlayLook get look => layout.look;
  double get inset => SiloCardOverlays.edgeInset * k;
  double get gap => look.stackGap * k;

  void _place(SiloBadgePlan plan, double x, double y) =>
      layout.parts.add(SiloOverlayBadgePart(Rect.fromLTWH(x, y, plan.w, plan.h), plan));

  void stackTop(List<SiloOverlayBadge> list, double maxWidth) {
    var y = inset;
    for (final badge in list) {
      final plan = measure(badge, maxWidth);
      _place(plan, inset, y);
      y += plan.h + gap;
    }
  }

  void rail(List<SiloOverlayBadge> list, double railInset, {required bool left}) {
    if (list.isEmpty) return;
    final flush = railInset == 0 ? (left ? AxisDirection.left : AxisDirection.right) : null;
    final plans = [for (final badge in list) measure(badge, width * 0.6, rail: flush)];
    final total = plans.fold<double>(0, (sum, plan) => sum + plan.h) + gap * (plans.length - 1);
    var y = (height - total) / 2;
    for (final plan in plans) {
      _place(plan, left ? railInset : width - railInset - plan.w, y);
      y += plan.h + gap;
    }
  }

  /// The bottom corners a row per level from the bottom up
  /// ([SiloOverlayLayoutMath.bottomRows]), [bottomInset] above the bottom.
  void bottomRows(List<SiloOverlayBadge> left, List<SiloOverlayBadge> right, double bottomInset) {
    if (left.isEmpty && right.isEmpty) return;
    final available = math.max(0.0, width - 2 * inset);
    final lp = [for (final badge in left) measure(badge, available)];
    final rp = [for (final badge in right) measure(badge, available)];
    final rows = SiloOverlayLayoutMath.bottomRows(
      [for (final p in lp) (w: p.w, h: p.h)],
      [for (final p in rp) (w: p.w, h: p.h)],
      available: available,
      gap: SiloCardOverlays.edgeGap * k,
      stackGap: gap,
    );
    final top = height - bottomInset - rows.height;
    for (var i = 0; i < lp.length; i++) {
      _place(lp[i], inset + rows.left[i].x, top + rows.left[i].y);
    }
    for (var i = 0; i < rp.length; i++) {
      _place(rp[i], inset + rows.right[i].x, top + rows.right[i].y);
    }
  }

  void bandTop(List<SiloOverlayBadge> list, double available) {
    if (list.isEmpty) return;
    final marks = _bandMarks(list, available);
    final scrim = inset * 4 + marks.h;
    layout.parts.insert(0, SiloOverlayScrimPart(Rect.fromLTWH(0, 0, width, scrim), top: true));
    _placeMarks(marks, inset, inset);
  }

  void bandBottom(List<SiloOverlayBadge> list, double below) {
    if (list.isEmpty) return;
    final marks = _bandMarks(list, width - 2 * inset);
    final strip = inset * 3 + marks.h + below;
    layout.parts.insert(0, SiloOverlayScrimPart(Rect.fromLTWH(0, height - strip, width, strip), top: false));
    _placeMarks(marks, (width - marks.w) / 2, height - below - marks.h);
  }

  ({List<SiloBadgePlan> plans, double w, double h}) _bandMarks(List<SiloOverlayBadge> list, double available) {
    final plans = [for (final badge in list) measure(badge, double.infinity)];
    final count = SiloOverlayBadges.bandFit([for (final p in plans) p.w], available, gap, 1);
    if (count == 1 && plans.first.w > available) plans[0] = measure(list.first, available);
    var total = 0.0;
    var tallest = 0.0;
    for (var i = 0; i < count; i++) {
      total += plans[i].w + (i > 0 ? 2 * gap + 1 : 0);
      tallest = math.max(tallest, plans[i].h);
    }
    return (plans: plans.sublist(0, count), w: total, h: tallest);
  }

  void _placeMarks(({List<SiloBadgePlan> plans, double w, double h}) marks, double x, double y) {
    final dividerHeight = look.fontSize * k * 0.9;
    for (var i = 0; i < marks.plans.length; i++) {
      final plan = marks.plans[i];
      if (i > 0) {
        x += gap;
        layout.parts.add(SiloOverlayDividerPart(Rect.fromLTWH(x, y + (marks.h - dividerHeight) / 2, 1, dividerHeight)));
        x += 1 + gap;
      }
      _place(plan, x, y + (marks.h - plan.h) / 2);
      x += plan.w;
    }
  }

  /// The top-right corner (the web's `CardWatchStatus`): the episodes left,
  /// else the watched check, at the badges' overlay scale.
  void watchStatus({required bool watched, required int episodesLeft}) {
    final size = SiloCardOverlays.watchStatusSize * k;
    if (episodesLeft > 0) {
      final label = '$episodesLeft';
      // [k] carries the text factor, so the font size is exact pixels.
      final fontSize = SiloCardOverlays.watchStatusFontSize * k;
      final textW = SiloOverlayLayout._measure(label, siloWatchCountStyle(fontSize, fontFamily));
      final w = SiloOverlayLayoutMath.countWidth(textW, k).ceilToDouble();
      layout.parts.add(SiloOverlayCountPart(Rect.fromLTWH(width - inset - w, inset, w, size), label, fontSize));
    } else if (watched) {
      layout.parts.add(SiloOverlayCheckPart(Rect.fromLTWH(width - inset - size, inset, size, size)));
    }
  }

  SiloOverlayImage? _image(String? ref) => ref == null ? null : settings.images[ref];

  /// What [badge] draws at most [maxWidth] wide.
  SiloBadgePlan measure(SiloOverlayBadge badge, double maxWidth, {AxisDirection? rail}) {
    final paint = SiloOverlayPaint.of(look, badge.accent);
    // An uploaded image for the badge's value replaces the whole badge.
    if (_image(badge.valueImage) case final image?) {
      final h = (look.fontSize + 2 * look.padY) * SiloCardOverlays.valueImageScale * k;
      final w = math.min(maxWidth, h * image.aspectRatio);
      return SiloBadgePlan(
        badge: badge,
        finished: SiloOverlayBadges.finish(badge, look),
        paint: paint,
        rail: rail,
        fontSize: look.fontSize * k,
        w: w,
        h: h,
        valueImage: badge.valueImage,
      );
    }
    final iconImage = _image(badge.image);
    final finished = SiloOverlayBadges.finish(badge, look, withImage: iconImage != null);
    final fontSize = look.fontSize * k;
    final letterSpacing = look.letterSpacingEm * fontSize;
    final border = paint.border != null && (paint.border! >> 24) > 0 ? look.borderWidth * k : 0.0;
    final iconSize = look.iconSize * k;
    var left = border;
    var right = border;
    if (rail == AxisDirection.left) left = 0;
    if (rail == AxisDirection.right) right = 0;
    if (look.accentLeft > 0 && paint.accentLeft != null && rail != AxisDirection.left) left = look.accentLeft * k;
    final padX = look.padX * k;
    final padY = look.padY * k;
    var lead = SiloLeadKind.none;
    var leadW = 0.0;
    var leadH = 0.0;
    var markFontSize = 0.0;
    if (iconImage != null) {
      lead = SiloLeadKind.image;
      leadH = iconSize;
      // At most the badge's content width (the web's `max-w-full`), so a wide
      // logo cannot push the badge past its slot.
      leadW = math.min(math.max(0.0, maxWidth - left - right - 2 * padX), iconSize * iconImage.aspectRatio);
    } else if (finished.chip != null) {
      lead = SiloLeadKind.chip;
      leadW =
          SiloOverlayLayout.textWidth(finished.chip!, fontSize, look.weight, fontFamily, letterSpacing: letterSpacing) +
          0.7 * fontSize;
      leadH = fontSize * 1.3;
    } else if (finished.markText != null) {
      lead = SiloLeadKind.mark;
      markFontSize = siloWordmarkFontSize(badge.icon, iconSize);
      leadW = SiloOverlayLayout.textWidth(
        finished.markText!,
        markFontSize,
        900,
        fontFamily,
        letterSpacing: badge.icon == 'atmos' ? siloAtmosTrackingEm * markFontSize : 0,
      );
      leadH = iconSize;
    } else if (badge.icon != null && SiloOverlayIcons.has(badge.icon!)) {
      lead = SiloLeadKind.glyph;
      leadW = iconSize;
      leadH = iconSize;
    }
    final text = finished.text;
    final textW = SiloOverlayLayout.textWidth(text, fontSize, look.weight, fontFamily, letterSpacing: letterSpacing);
    final contentHeight = math.max(fontSize, leadH);
    final gapW = leadW > 0 && textW > 0 ? look.iconGap * k : 0.0;
    var w = left + padX + leadW + gapW + textW + padX + right;
    // A bare score never truncates; any other label ellipsizes.
    final truncated = w > maxWidth && textW > 0 && !finished.scoreOnly;
    if (truncated) w = maxWidth;
    // Rounded up so the measured text never wraps at the last pixel.
    w = w.ceilToDouble();
    return SiloBadgePlan(
      badge: badge,
      finished: finished,
      paint: paint,
      rail: rail,
      fontSize: fontSize,
      w: w,
      h: border + padY + contentHeight + padY + border,
      lead: lead,
      leadImage: iconImage == null ? null : badge.image,
      leadW: leadW,
      leadH: leadH,
      markFontSize: markFontSize,
      gap: gapW,
      border: border,
      left: left,
      right: right,
      padX: padX,
      padY: padY,
      contentHeight: contentHeight,
      truncated: truncated,
    );
  }
}

/// One badge drawn as its [SiloBadgePlan] measured it.
class SiloOverlayBadgeView extends StatelessWidget {
  const SiloOverlayBadgeView({
    super.key,
    required this.plan,
    required this.look,
    required this.k,
    required this.fontFamily,
    required this.dpr,
    required this.imageUrl,
    required this.onImageFailed,
  });

  final SiloBadgePlan plan;
  final SiloOverlayLook look;
  final double k;
  final String? fontFamily;
  final double dpr;
  final String? Function(String ref) imageUrl;
  final void Function(String ref)? onImageFailed;

  Widget _image(String ref, double w, double h) {
    final url = imageUrl(ref);
    if (url == null || url.isEmpty) return SizedBox(width: w, height: h);
    // Uploaded overlay images are public reads on the server's own origin:
    // the shared artwork pipeline sends no credentials with them.
    final provider = MediaImageHelper.serverArtworkProvider(
      imageUrl: url,
      memWidth: math.max(1, (w * dpr).ceil()),
      memHeight: math.max(1, (h * dpr).ceil()),
    );
    return Image(
      image: provider,
      width: w,
      height: h,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) {
        onImageFailed?.call(ref);
        return SizedBox(width: w, height: h);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (plan.valueImage case final ref?) return _image(ref, plan.w, plan.h);
    final paint = plan.paint;
    final h = plan.h;
    final w = plan.w;
    var radius = look.radius * k;
    if (look.radius < 0 || radius > h / 2) radius = h / 2;
    radius = math.min(radius, w / 2);
    final r = Radius.circular(radius);
    final borderRadius = switch (plan.rail) {
      AxisDirection.left => BorderRadius.horizontal(right: r),
      AxisDirection.right => BorderRadius.horizontal(left: r),
      _ => BorderRadius.all(r),
    };
    final hasFill = paint.fill != null && (paint.fill! >> 24) > 0;
    final shadow = look.boxShadow;
    final textColor = Color(paint.text);
    final textShadow = look.textShadow;
    final textShadowPaint = textShadow == null
        ? null
        : Shadow(
            offset: Offset(textShadow.x * k, textShadow.y * k),
            blurRadius: siloCssBlurRadius(textShadow.blur * k),
            color: Color(textShadow.color),
          );
    final textStyle = siloOverlayTextStyle(
      plan.fontSize,
      look.weight,
      fontFamily,
      letterSpacing: look.letterSpacingEm * plan.fontSize,
    ).copyWith(color: textColor, shadows: textShadowPaint == null ? null : [textShadowPaint]);
    final children = <Widget>[];
    switch (plan.lead) {
      case SiloLeadKind.image:
        children.add(_image(plan.leadImage!, plan.leadW, plan.leadH));
      case SiloLeadKind.chip:
        final accent = plan.badge.accent == null ? 0xFFFFFFFF : siloOverlayColor(plan.badge.accent!) | 0xFF000000;
        children.add(
          Container(
            width: plan.leadW,
            height: plan.leadH,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Color(accent), borderRadius: BorderRadius.circular(plan.fontSize * 0.2)),
            child: Text(
              plan.finished.chip!,
              maxLines: 1,
              softWrap: false,
              textScaler: TextScaler.noScaling,
              style: textStyle.copyWith(color: Color(siloOverlayReadableOn(accent))),
            ),
          ),
        );
      case SiloLeadKind.mark:
        children.add(
          SizedBox(
            width: plan.leadW,
            height: plan.leadH,
            child: Center(
              child: Text(
                plan.finished.markText!,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                textScaler: TextScaler.noScaling,
                style: siloOverlayTextStyle(
                  plan.markFontSize,
                  900,
                  fontFamily,
                  letterSpacing: plan.badge.icon == 'atmos' ? siloAtmosTrackingEm * plan.markFontSize : 0,
                ).copyWith(color: textColor, shadows: textShadowPaint == null ? null : [textShadowPaint]),
              ),
            ),
          ),
        );
      case SiloLeadKind.glyph:
        children.add(
          SiloOverlayGlyph(icon: plan.badge.icon!, size: plan.leadW, color: textColor, shadow: textShadowPaint),
        );
      case SiloLeadKind.none:
        break;
    }
    if (plan.finished.text.isNotEmpty) {
      if (children.isNotEmpty) children.add(SizedBox(width: plan.gap));
      children.add(
        Flexible(
          child: Text(
            plan.finished.text,
            maxLines: 1,
            softWrap: false,
            // Only a label cut to its slot ellipsizes; one measured to fit draws
            // whole even if the device's font lays it out a hair wider.
            overflow: plan.truncated ? TextOverflow.ellipsis : TextOverflow.visible,
            textScaler: TextScaler.noScaling,
            style: textStyle,
          ),
        ),
      );
    }
    Widget content = Padding(
      padding: EdgeInsets.fromLTRB(
        plan.left + plan.padX,
        plan.border + plan.padY,
        plan.padX + plan.right,
        plan.border + plan.padY,
      ),
      child: Row(mainAxisSize: MainAxisSize.max, children: children),
    );
    if (paint.accentLeft != null && look.accentLeft > 0 && plan.rail != AxisDirection.left) {
      final stripeInset = radius * 0.3;
      content = Stack(
        children: [
          Positioned(
            left: 0,
            top: stripeInset,
            bottom: stripeInset,
            width: plan.left,
            child: ColoredBox(color: Color(paint.accentLeft!)),
          ),
          Positioned.fill(child: content),
        ],
      );
    }
    final borderColor = paint.border;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hasFill ? Color(paint.fill!) : null,
        borderRadius: borderRadius,
        border: plan.border > 0 && borderColor != null
            ? Border.all(color: Color(borderColor), width: plan.border)
            : null,
        boxShadow: shadow == null || !hasFill
            ? null
            : [
                BoxShadow(
                  offset: Offset(shadow.x * k, shadow.y * k),
                  blurRadius: siloCssBlurRadius(shadow.blur * k),
                  color: Color(shadow.color),
                ),
              ],
      ),
      child: content,
    );
  }
}
