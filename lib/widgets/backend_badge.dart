import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../media/media_backend.dart';

/// Tiny badge for a [MediaBackend] (Plex chevron / Jellyfin or Emby mark /
/// Silo project icon).
/// The SVG marks render in `currentColor` so they pick up whatever foreground
/// the parent provides — pass [color] to override, otherwise inherits from
/// [DefaultTextStyle] / `IconTheme`.
///
/// Silo is shown with Silo's official project icon, which Silo's trademark
/// policy lets a project that works with Silo use, unmodified, to name Silo as
/// a server type. It is drawn as supplied: never tinted, recoloured or used as
/// Plezy's own icon (`assets/brand/silo/NOTICE.txt`).
///
/// Tofa's logo is not licensed to Plezilo, so Tofa gets a neutral badge of
/// Plezilo's own: a rounded outline holding the letter "T" (spoken "Tofa"),
/// in the inherited foreground colour like the SVG marks.
class BackendBadge extends StatelessWidget {
  final MediaBackend backend;
  final double size;
  final Color? color;

  const BackendBadge({super.key, required this.backend, this.size = 16, this.color});

  /// Silo's official project icon, unmodified (see the class doc).
  static const siloIconAsset = 'assets/brand/silo/silo-project-icon.png';

  /// Tofa's name, not localized (a product name).
  static const tofaLabel = 'Tofa';

  @override
  Widget build(BuildContext context) {
    final asset = switch (backend) {
      MediaBackend.plex => 'assets/plex_chevron.svg',
      MediaBackend.jellyfin => 'assets/jellyfin_icon.svg',
      MediaBackend.emby => 'assets/emby_icon.svg',
      MediaBackend.silo || MediaBackend.tofa => null,
    };
    if (backend == MediaBackend.tofa) return _tofaBadge(context);
    if (asset == null) {
      return Image.asset(
        siloIconAsset,
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
      );
    }
    final tint =
        color ??
        DefaultTextStyle.of(context).style.color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      theme: SvgTheme(currentColor: tint),
    );
  }

  Widget _tofaBadge(BuildContext context) {
    final tint =
        color ??
        DefaultTextStyle.of(context).style.color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return Semantics(
      label: tofaLabel,
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.25),
          border: Border.all(color: tint, width: (size / 12).clamp(1.0, 3.0)),
        ),
        child: Text(
          'T',
          textScaler: TextScaler.noScaling,
          style: TextStyle(color: tint, fontSize: size * 0.62, fontWeight: FontWeight.w700, height: 1),
        ),
      ),
    );
  }
}
