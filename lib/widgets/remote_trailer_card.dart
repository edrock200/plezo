import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/card_focus_scope.dart';
import '../i18n/strings.g.dart';
import '../media/remote_trailer.dart';
import '../theme/mono_tokens.dart';
import 'app_icon.dart';
import 'optimized_media_image.dart';

/// A YouTube video card for the detail page's "Trailers & Extras" row,
/// sized like the [MediaCard] grid cards beside it (16:9 still, title and
/// kind captions) with a "YouTube" badge so it is clear the video opens in
/// YouTube rather than Plezy's player.
///
/// Focus and activation belong to the enclosing row (see
/// `FocusBuilders.buildLockedFocusWrapper` with `delegateFocusBorder`); the
/// border is drawn around the still by [CardFocusBorder].
class RemoteTrailerCard extends StatelessWidget {
  final RemoteTrailer trailer;
  final double width;
  final double posterHeight;

  const RemoteTrailerCard({super.key, required this.trailer, required this.width, required this.posterHeight});

  @override
  Widget build(BuildContext context) {
    final radius = tokens(context).radiusSm;
    final title = trailer.name ?? extraKindLabel(trailer.kind);
    final caption = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: tokens(context).textMuted, fontSize: 11, height: 1.1);

    return Semantics(
      button: true,
      label: '$title, ${t.discover.youtube}',
      excludeSemantics: true,
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(3, 3, 3, 1),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                height: posterHeight,
                child: CardFocusBorder(
                  borderRadius: radius,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        OptimizedMediaImage.thumb(
                          imagePath: trailer.thumbnailUrl,
                          width: width - 6,
                          height: posterHeight,
                        ),
                        Positioned(left: 6, bottom: 6, child: _YoutubeBadge(label: t.discover.youtube)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, height: 1.1),
              ),
              Text(extraKindLabel(trailer.kind), maxLines: 1, overflow: TextOverflow.ellipsis, style: caption),
            ],
          ),
        ),
      ),
    );
  }
}

class _YoutubeBadge extends StatelessWidget {
  final String label;
  const _YoutubeBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(4)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppIcon(Symbols.open_in_new_rounded, size: 11, color: Colors.white, fill: 1),
            const SizedBox(width: 3),
            Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600, height: 1.1),
            ),
          ],
        ),
      ),
    );
  }
}
