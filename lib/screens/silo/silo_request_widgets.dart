import 'package:flutter/material.dart';

import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../services/silo/silo_client.dart';
import '../../services/silo/silo_requests.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_navigation_helper.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/optimized_media_image.dart';
import 'silo_request_detail_screen.dart';

/// Status colours of Silo's request surfaces (`RequestColors`): amber,
/// sky, emerald, rose; neutral for "Unavailable".
Color siloRequestTint(SiloRequestDisplay? display, ColorScheme scheme) => switch (display?.kind) {
  SiloRequestDisplayKind.pending => const Color(0xFFF59E0B),
  SiloRequestDisplayKind.onTheWay => const Color(0xFF38BDF8),
  SiloRequestDisplayKind.inLibrary => const Color(0xFF34D399),
  SiloRequestDisplayKind.attention => const Color(0xFFFB7185),
  SiloRequestDisplayKind.unavailable || null => scheme.onSurfaceVariant,
};

/// The short status a card shows.
String siloRequestLabel(SiloRequestDisplay display) => switch (display.kind) {
  SiloRequestDisplayKind.pending => t.siloRequests.pending,
  SiloRequestDisplayKind.onTheWay => t.siloRequests.onTheWay,
  SiloRequestDisplayKind.inLibrary => t.siloRequests.inLibrary,
  SiloRequestDisplayKind.attention =>
    display.attention == SiloRequestAttention.declined ? t.siloRequests.declined : t.siloRequests.failed,
  SiloRequestDisplayKind.unavailable => siloRequestReasonText(display.reason) ?? t.siloRequests.unavailable,
};

/// Copy for a reason code (`RequestReason`, Silo's `requestReasonCopy`). An
/// unknown code shows nothing; a server sentence shows as written.
String? siloRequestReasonText(String? reason) {
  final value = reason?.trim() ?? '';
  if (value.isEmpty) return null;
  switch (value) {
    case 'already_requested':
      return t.siloRequests.reasonAlreadyRequested;
    case 'already_available':
      return t.siloRequests.reasonAlreadyAvailable;
    case 'quota_exceeded' || 'limit_reached':
      return t.siloRequests.reasonQuotaExceeded;
    case 'requests_disabled':
      return t.siloRequests.reasonRequestsDisabled;
    case 'blocked' || 'requesting_blocked':
      return t.siloRequests.reasonBlocked;
    case 'validation_failed':
      return t.siloRequests.reasonInvalid;
    case 'not_found':
      return t.siloRequests.reasonNotFound;
  }
  if (RegExp(r'^[a-z0-9_]+$').hasMatch(value)) return null;
  return value[0].toUpperCase() + value.substring(1);
}

/// The detail page's status line (Silo's `RequestDisplayState.detailTitle`).
String siloRequestDetailTitle(SiloRequestDisplay display) {
  final reason = siloRequestReasonText(display.reason);
  return switch (display.kind) {
    SiloRequestDisplayKind.pending => t.siloRequests.detailPending,
    SiloRequestDisplayKind.onTheWay => t.siloRequests.onTheWay,
    SiloRequestDisplayKind.inLibrary => t.siloRequests.detailInLibrary,
    SiloRequestDisplayKind.attention => [siloRequestLabel(display), ?reason].join(' · '),
    SiloRequestDisplayKind.unavailable => reason ?? t.siloRequests.unavailable,
  };
}

/// The longer status of the viewer's own request (Silo's `RequestProgress`).
String siloRequestRecordStatus(SiloMediaRequest record) {
  final display = record.display;
  if (display.kind == SiloRequestDisplayKind.onTheWay) {
    if (record.state == 'partially_available') return t.siloRequests.partlyInLibrary;
    return switch (record.status) {
      'downloading' => t.siloRequests.downloading,
      'completed' => t.siloRequests.addingToLibrary,
      'approved' || 'queued' => t.siloRequests.queued,
      _ => t.siloRequests.onTheWay,
    };
  }
  if (display.kind == SiloRequestDisplayKind.pending) return t.siloRequests.waitingForApproval;
  if (display.kind == SiloRequestDisplayKind.attention) return siloRequestDetailTitle(display);
  return siloRequestLabel(display);
}

String siloRequestMediaTypeLabel(String mediaType) =>
    mediaType == 'series' ? t.siloRequests.series : t.siloRequests.movie;

/// A small coloured status pill.
class SiloRequestStatusPill extends StatelessWidget {
  const SiloRequestStatusPill({super.key, required this.display});

  final SiloRequestDisplay display;

  @override
  Widget build(BuildContext context) {
    final tint = siloRequestTint(display, Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.18),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Text(
        siloRequestLabel(display),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tint, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// One request title as a list row: poster, title, type and year, status.
/// Works with touch (tap) and D-pad (select); the caller wires the focus
/// graph through [focusNode] and the `onNavigate*` callbacks.
class SiloRequestRow extends StatelessWidget {
  const SiloRequestRow({
    super.key,
    required this.title,
    required this.mediaType,
    required this.onSelect,
    this.year,
    this.posterPath,
    this.display,
    this.statusText,
    this.focusNode,
    this.autofocus = false,
    this.onNavigateUp,
    this.onNavigateDown,
    this.onNavigateLeft,
  });

  final String title;
  final String mediaType;
  final int? year;
  final String? posterPath;
  final SiloRequestDisplay? display;
  final String? statusText;
  final VoidCallback onSelect;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;
  final VoidCallback? onNavigateLeft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final display = this.display;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: FocusableWrapper(
        focusNode: focusNode,
        autofocus: autofocus,
        onSelect: onSelect,
        onNavigateUp: onNavigateUp,
        onNavigateDown: onNavigateDown,
        onNavigateLeft: onNavigateLeft,
        disableScale: true,
        borderRadius: 12,
        descendantsAreFocusable: false,
        semanticLabel: [title, if (display != null) siloRequestLabel(display)].join(', '),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(6)),
                  child: OptimizedMediaImage.poster(imagePath: siloRequestImageUrl(posterPath), width: 60, height: 90),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        [siloRequestMediaTypeLabel(mediaType), if (year != null && year! > 0) '$year'].join(' · '),
                        style: muted,
                      ),
                      if (display != null || statusText != null) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (display != null) SiloRequestStatusPill(display: display),
                            if (statusText != null) Text(statusText!, style: muted),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a catalog item of [client] by its content id on its detail page
/// (an episode lands on its series page with the episode selected).
/// [fallbackId] is tried when the first id cannot be read (e.g. a calendar
/// episode the library has not scanned yet: its series).
Future<void> openSiloLibraryItem(
  BuildContext context,
  SiloClient client,
  String contentId, {
  String? fallbackId,
  String? failureMessage,
}) async {
  MediaItem? item;
  for (final id in [contentId, ?fallbackId]) {
    try {
      item = await client.fetchItem(id);
    } catch (e) {
      appLogger.d('Silo: could not open $id', error: e.runtimeType);
    }
    if (item != null) break;
  }
  if (!context.mounted) return;
  if (item == null) {
    showErrorSnackBar(context, failureMessage ?? t.siloRequests.openFailed);
    return;
  }
  await navigateToMediaItemDetails(context, item);
}

/// Silo's one routing rule for request cards: "In library" opens the real
/// item, everything else the request detail (`libraryItemToOpen`).
Future<void> openSiloRequestTitle(
  BuildContext context,
  SiloClient client, {
  required String mediaType,
  required int tmdbId,
  required String title,
  SiloRequestDisplay? display,
  String? libraryContentId,
  String? posterPath,
}) async {
  final libraryId = display?.libraryItemToOpen(libraryContentId);
  if (libraryId != null) {
    await openSiloLibraryItem(context, client, libraryId);
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SiloRequestDetailScreen(
        client: client,
        mediaType: mediaType,
        tmdbId: tmdbId,
        initialTitle: title,
        initialPosterPath: posterPath,
      ),
    ),
  );
}
