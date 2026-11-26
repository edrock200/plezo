import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_wrapper.dart';
import '../../services/silo/silo_requests.dart';
import '../../services/tofa/tofa_client.dart';
import '../../services/tofa/tofa_extras.dart';
import '../../widgets/app_icon.dart';
import '../silo/silo_request_widgets.dart';
import 'tofa_title_screen.dart';

/// A Tofa request status (`RequestStatus`) on the shared request pill.
SiloRequestDisplay? tofaRequestDisplay(String? status) => switch (status) {
  null || '' => null,
  'pending_approval' => const SiloRequestDisplay(SiloRequestDisplayKind.pending),
  'requested' || 'downloading' || 'retrying' => const SiloRequestDisplay(SiloRequestDisplayKind.onTheWay),
  'available' => const SiloRequestDisplay(SiloRequestDisplayKind.inLibrary),
  'denied' => const SiloRequestDisplay(SiloRequestDisplayKind.attention, attention: SiloRequestAttention.declined),
  'failed' => const SiloRequestDisplay(SiloRequestDisplayKind.attention, attention: SiloRequestAttention.failed),
  _ => const SiloRequestDisplay(SiloRequestDisplayKind.pending),
};

/// One Discover title as a list row (the request screens' row): poster,
/// title, type and year, its request or library state. Opens
/// [TofaTitleScreen].
class TofaTitleRow extends StatelessWidget {
  const TofaTitleRow({
    super.key,
    required this.client,
    required this.item,
    this.focusNode,
    this.autofocus = false,
    this.onNavigateUp,
    this.onReturn,
    this.statusText,
  });

  final TofaClient client;
  final TofaDiscoverItem item;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onReturn;
  final String? statusText;

  @override
  Widget build(BuildContext context) {
    final poster = client.discoverImageUrl(item);
    return SiloRequestRow(
      title: item.title,
      mediaType: item.isShow ? 'series' : 'movie',
      year: item.year,
      posterPath: poster.isEmpty ? null : poster,
      display: item.inLibrary
          ? const SiloRequestDisplay(SiloRequestDisplayKind.inLibrary)
          : tofaRequestDisplay(item.requestStatus),
      statusText: statusText ?? (item.roles.isEmpty ? null : item.roles.join(', ')),
      focusNode: focusNode,
      autofocus: autofocus,
      onNavigateUp: onNavigateUp,
      onSelect: () => unawaited(_open(context)),
    );
  }

  Future<void> _open(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TofaTitleScreen(client: client, item: item),
      ),
    );
    onReturn?.call();
  }
}

/// A row that opens another page: icon, title, optional subtitle, chevron.
/// Touch and D-pad.
class TofaNavRow extends StatelessWidget {
  const TofaNavRow({
    super.key,
    required this.title,
    required this.onSelect,
    this.subtitle,
    this.icon,
    this.focusNode,
    this.autofocus = false,
    this.onNavigateUp,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback onSelect;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onNavigateUp;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: FocusableWrapper(
        focusNode: focusNode,
        autofocus: autofocus,
        onSelect: onSelect,
        onNavigateUp: onNavigateUp,
        disableScale: true,
        borderRadius: 12,
        useBackgroundFocus: true,
        autoScroll: true,
        semanticLabel: [title, ?subtitle].join(', '),
        child: InkWell(
          canRequestFocus: false,
          onTap: onSelect,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                if (icon != null) ...[AppIcon(icon!, fill: 1), const SizedBox(width: 16)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                      if (subtitle != null && subtitle!.isNotEmpty)
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                ?trailing,
                const AppIcon(Symbols.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A section title in a sliver list.
Widget tofaSectionHeader(BuildContext context, String title) => SliverToBoxAdapter(
  child: Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleLarge),
  ),
);
