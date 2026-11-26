import 'dart:async';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../focus/card_focus_scope.dart';
import '../media/catalog_item_ref.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_kind.dart';
import '../services/device_performance.dart';
import '../services/settings_service.dart';
import '../utils/media_image_helper.dart';
import '../utils/provider_extensions.dart';
import 'optimized_media_image.dart';

/// The "Expand on focus" appearance setting ([SettingsService.expandOnFocus]):
/// a focused portrait poster in a horizontal row (hub rows, TV browse rails)
/// widens to a 16:9 card of the same height and cross-fades to the item's wide
/// artwork, with its title or clear logo on a scrim. Grids never expand: a
/// resized cell would reflow every row below it.
///
/// Items without wide artwork, already-wide cards (episode thumbnails, clips),
/// square music artwork, playlists and offline downloads stay as they are.
abstract final class ExpandOnFocus {
  /// Width and cross-fade duration: long enough to read as one motion, short
  /// enough that a held D-pad never waits for it (each step retargets the
  /// running animation instead of queueing a new one).
  static const Duration duration = Duration(milliseconds: 220);
  static const Curve curve = Curves.easeInOutCubic;
  static const double wideAspectRatio = 16 / 9;

  /// [duration], or zero (snap) on the reduced effects tier and when the
  /// platform asks for reduced motion.
  static Duration durationOf(BuildContext context) =>
      DevicePerformance.isReduced || MediaQuery.maybeDisableAnimationsOf(context) == true ? Duration.zero : duration;

  /// The server image path of [item]'s wide artwork, or null when it has none.
  ///
  /// Movies, shows and collections use their own backdrop (inherited art only
  /// when they have none); seasons their own backdrop, else the series'; an
  /// episode its own 16:9 still, else the series backdrop. With spoilers
  /// hidden an unwatched episode shows the series backdrop, never its still.
  static String? wideArtPath(MediaItem item, {bool hideSpoilers = false}) {
    String? firstOf(Iterable<String?> paths) {
      for (final path in paths) {
        if (path != null && path.isNotEmpty) return path;
      }
      return null;
    }

    return switch (item.kind) {
      MediaKind.episode =>
        hideSpoilers && item.shouldHideSpoiler
            ? firstOf(item.resolvedGrandparentBackdropPaths)
            : firstOf([item.thumbPath, ...item.resolvedGrandparentBackdropPaths]),
      MediaKind.season => firstOf([...item.resolvedBackdropPaths, ...item.resolvedGrandparentBackdropPaths]),
      MediaKind.movie || MediaKind.show || MediaKind.collection => firstOf(item.heroBackdropPaths),
      _ => null,
    };
  }

  /// Whether [item] renders as a portrait poster that can widen: a poster
  /// silhouette with wide artwork to show. Catalog stand-ins (Explore) widen
  /// to their provider backdrop.
  static bool canExpand(
    Object item, {
    required EpisodePosterMode episodePosterMode,
    bool mixedHubContext = false,
    CardShape? cardShapeOverride,
    bool isOffline = false,
    bool? hideSpoilers,
  }) {
    if (item is! MediaItem || isOffline) return false;
    final shape = cardShapeOverride ?? item.cardShape(episodePosterMode, mixedHubContext: mixedHubContext);
    if (shape != CardShape.poster) return false;
    if (item.catalogItem case final catalog?) {
      final backdrop = catalog.backdropUrl;
      return backdrop != null && backdrop.isNotEmpty;
    }
    return wideArtPath(
          item,
          hideSpoilers: hideSpoilers ?? SettingsService.instanceOrNull?.read(SettingsService.hideSpoilers) ?? false,
        ) !=
        null;
  }

  /// Card width once a card [height] tall shows 16:9 artwork, plus the card's
  /// own [horizontalInset] around the artwork (MediaCard's 3px each side).
  static double expandedCardWidth({required double artworkHeight, double horizontalInset = 0}) =>
      artworkHeight * wideAspectRatio + horizontalInset;

  /// How much wider a [collapsedWidth] card grows when [item] expands, or 0
  /// when it does not. Rows add half of it to the focused card's scroll
  /// target so the expanded card, not the poster, is centred.
  static double extraWidthFor(
    Object item, {
    required double collapsedWidth,
    required double artworkHeight,
    required double horizontalInset,
    required EpisodePosterMode episodePosterMode,
    bool mixedHubContext = false,
  }) {
    if (!canExpand(item, episodePosterMode: episodePosterMode, mixedHubContext: mixedHubContext)) return 0;
    final expanded = expandedCardWidth(artworkHeight: artworkHeight, horizontalInset: horizontalInset);
    return expanded > collapsedWidth ? expanded - collapsedWidth : 0;
  }

  static final _prefetched = <String>{};
  static const _prefetchMemory = 128;

  /// Warms the image cache with [item]'s wide artwork at the size an expanded
  /// card [artworkHeight] tall paints it, so the cross-fade has nothing to
  /// wait for when focus reaches it. Same URL and decode bounds as
  /// [ExpandedArtLayer]'s image; a no-op for items that do not expand and for
  /// URLs already warmed recently.
  static void prefetch(
    BuildContext context,
    Object item, {
    required double artworkHeight,
    required EpisodePosterMode episodePosterMode,
    bool mixedHubContext = false,
  }) {
    if (item is! MediaItem || item.catalogItem != null) return;
    if (!canExpand(item, episodePosterMode: episodePosterMode, mixedHubContext: mixedHubContext)) return;
    final path = wideArtPath(
      item,
      hideSpoilers: SettingsService.instanceOrNull?.read(SettingsService.hideSpoilers) ?? false,
    );
    if (path == null || !artworkHeight.isFinite || artworkHeight <= 0) return;
    final width = artworkHeight * wideAspectRatio;
    const imageType = ImageType.thumb;
    final pixelRatio = MediaImageHelper.artworkPixelRatio(context, imageType: imageType);
    final url = MediaImageHelper.getOptimizedImageUrl(
      client: context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId)),
      thumbPath: path,
      maxWidth: width,
      maxHeight: artworkHeight,
      pixelRatio: pixelRatio,
      imageType: imageType,
    );
    if (url.isEmpty || !_prefetched.add(url)) return;
    if (_prefetched.length > _prefetchMemory) _prefetched.remove(_prefetched.first);
    final (memWidth, memHeight) = MediaImageHelper.getMemCacheDimensions(
      displayWidth: (width * pixelRatio).round(),
      displayHeight: (artworkHeight * pixelRatio).round(),
      imageType: imageType,
    );
    unawaited(
      precacheImage(
        MediaImageHelper.serverArtworkProvider(imageUrl: url, memWidth: memWidth, memHeight: memHeight),
        context,
        onError: (_, _) => _prefetched.remove(url),
      ),
    );
  }
}

/// Drives a card's expansion from the enclosing [CardFocusScope] and animates
/// its width between [collapsedWidth] and [expandedWidth].
///
/// The animation is published through [expansion] (a proxy the card owns), so
/// the card builds its content once per focus change and only this widget's
/// [SizedBox] and the art layer's fade run per frame. No scope (touch mode,
/// where rows draw no focus) means collapsed.
class FocusExpansion extends StatefulWidget {
  const FocusExpansion({
    super.key,
    required this.expansion,
    required this.collapsedWidth,
    required this.expandedWidth,
    required this.child,
  });

  final ProxyAnimation expansion;
  final double collapsedWidth;
  final double expandedWidth;
  final Widget child;

  @override
  State<FocusExpansion> createState() => _FocusExpansionState();
}

class _FocusExpansionState extends State<FocusExpansion> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  late final CurvedAnimation _curved = CurvedAnimation(parent: _controller, curve: ExpandOnFocus.curve);
  bool? _expanded;

  @override
  void initState() {
    super.initState();
    widget.expansion.parent = _curved;
  }

  @override
  void didUpdateWidget(FocusExpansion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.expansion, widget.expansion)) {
      oldWidget.expansion.parent = kAlwaysDismissedAnimation;
      widget.expansion.parent = _curved;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final expanded = CardFocusScope.maybeOf(context) ?? false;
    final previous = _expanded;
    _expanded = expanded;
    if (previous == null) {
      // A card built while already focused (row realised under focus, memo
      // flush) starts in its final state instead of replaying the motion.
      _controller.value = expanded ? 1 : 0;
    } else if (previous != expanded) {
      // Retargets a running animation from where it is: a fast D-pad run
      // never queues expansions behind each other.
      // forward/reverse (not animateTo) so a collapsed card reports
      // dismissed and drops its art layer.
      _controller.duration = ExpandOnFocus.durationOf(context);
      unawaited(expanded ? _controller.forward() : _controller.reverse());
    }
  }

  @override
  void dispose() {
    if (identical(widget.expansion.parent, _curved)) widget.expansion.parent = kAlwaysDismissedAnimation;
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      child: widget.child,
      builder: (context, child) =>
          SizedBox(width: lerpDouble(widget.collapsedWidth, widget.expandedWidth, _curved.value), child: child),
    );
  }
}

/// The wide artwork, scrim and title of an expanding card, laid over its
/// poster. Builds nothing until the card starts to expand (no backdrop fetch
/// for cards that are never focused) and fades with [expansion].
///
/// The layer is laid out at the full expanded size and clipped by the growing
/// card, so neither the image URL nor the title's line breaks change while the
/// width animates.
class ExpandedArtLayer extends StatefulWidget {
  const ExpandedArtLayer({
    super.key,
    required this.expansion,
    required this.width,
    required this.height,
    required this.image,
    required this.title,
    this.logo,
  });

  final Animation<double> expansion;

  /// Expanded artwork size (16:9).
  final double width;
  final double height;

  /// The wide artwork; its placeholder must be transparent so the poster
  /// shows until the image has loaded.
  final Widget image;
  final String title;

  /// Clear logo shown instead of [title], when the item has one.
  final Widget Function(BuildContext context, Widget titleFallback)? logo;

  static const Key layerKey = ValueKey('expanded_art_layer');

  @override
  State<ExpandedArtLayer> createState() => _ExpandedArtLayerState();
}

class _ExpandedArtLayerState extends State<ExpandedArtLayer> {
  late bool _active = widget.expansion.status != AnimationStatus.dismissed;

  @override
  void initState() {
    super.initState();
    widget.expansion.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(ExpandedArtLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.expansion, widget.expansion)) {
      oldWidget.expansion.removeStatusListener(_onStatus);
      widget.expansion.addStatusListener(_onStatus);
      _active = widget.expansion.status != AnimationStatus.dismissed;
    }
  }

  @override
  void dispose() {
    widget.expansion.removeStatusListener(_onStatus);
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    final active = status != AnimationStatus.dismissed;
    if (active != _active && mounted) setState(() => _active = active);
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) return const SizedBox.shrink();
    final height = widget.height;
    final titleStyle = TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.w700,
      fontSize: (height * 0.085).clamp(12.0, 24.0),
      height: 1.15,
      shadows: const [Shadow(color: Color(0x99000000), blurRadius: 6)],
    );
    final title = Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: titleStyle);
    final inset = (height * 0.06).clamp(6.0, 16.0);
    return FadeTransition(
      key: ExpandedArtLayer.layerKey,
      opacity: widget.expansion,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: widget.width,
          maxWidth: widget.width,
          minHeight: height,
          maxHeight: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.image,
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.45, 1.0],
                    colors: [Color(0x00000000), Color(0xCC000000)],
                  ),
                ),
              ),
              Positioned(
                left: inset,
                right: inset,
                bottom: inset,
                child: Align(alignment: Alignment.bottomLeft, child: widget.logo?.call(context, title) ?? title),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A clear logo sized for an expanded card's lower-left corner; [fallback]
/// (the title) shows while it fails to load.
Widget expandedCardLogo(
  BuildContext context, {
  required MediaItem item,
  required double cardWidth,
  required double cardHeight,
  required Widget fallback,
}) {
  final path = item.clearLogoPath;
  if (path == null || path.isEmpty) return fallback;
  final width = cardWidth * 0.5;
  final height = cardHeight * 0.26;
  return SizedBox(
    width: width,
    height: height,
    child: OptimizedMediaImage(
      client: context.tryGetMediaClientWithFallback(serverIdOrNull(item.serverId)),
      imagePath: path,
      width: width,
      height: height,
      fit: BoxFit.contain,
      alignment: Alignment.bottomLeft,
      imageType: ImageType.logo,
      placeholder: (context, _) => const SizedBox.shrink(),
      errorWidget: (context, _, _) => Align(alignment: Alignment.bottomLeft, child: fallback),
    ),
  );
}
