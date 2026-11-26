import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../focus/focusable_text_field.dart';
import '../../../focus/focusable_wrapper.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/ids.dart';
import '../../../mixins/mounted_set_state_mixin.dart';
import '../../../models/livetv_channel.dart';
import '../../../models/livetv_program.dart';
import '../../../providers/multi_server_provider.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/formatters.dart';
import '../../../widgets/app_icon.dart';
import '../live_tv_actions_mixin.dart';
import '../live_tv_refresh_mixin.dart';
import '../live_tv_server_iteration.dart';

/// A channel list: number, logo (initials when there is none), name, what is
/// on now with its progress and what is next, a favourite star and a
/// catch-up mark. Select tunes; long press (or the menu key) toggles the
/// favourite. A search field filters by name or number.
///
/// The list is built lazily with a fixed row height, so thousands of channels
/// scroll smoothly on a TV box; now/next is read once for the shown window
/// and refreshed every minute.
class ChannelsTab extends StatefulWidget {
  const ChannelsTab({
    super.key,
    required this.channels,
    this.isFavoriteChannel,
    this.onToggleFavorite,
    this.onNavigateUp,
    this.onBack,
  });

  final List<LiveTvChannel> channels;
  final bool Function(LiveTvChannel channel)? isFavoriteChannel;
  final void Function(LiveTvChannel channel)? onToggleFavorite;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onBack;

  @override
  State<ChannelsTab> createState() => ChannelsTabState();
}

class ChannelsTabState extends State<ChannelsTab>
    with
        LiveTvActionsMixin<ChannelsTab>,
        MountedSetStateMixin,
        WidgetsBindingObserver,
        LiveTvRefreshMixin<ChannelsTab> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'ChannelsTab:Search');
  final _scrollController = ScrollController();
  final List<FocusNode> _rowNodes = [];
  Map<String, List<LiveTvProgram>> _programsByChannel = const {};
  int _loadGeneration = 0;

  static const rowHeight = 76.0;

  @override
  List<LiveTvChannel> get liveTvChannels => widget.channels;

  @override
  Duration get refreshInterval => const Duration(minutes: 1);

  @override
  void onRefreshTick() => unawaited(_loadPrograms());

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    unawaited(_loadPrograms());
  }

  @override
  void didUpdateWidget(covariant ChannelsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.channels, widget.channels)) unawaited(_loadPrograms());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    for (final n in _rowNodes) {
      n.dispose();
    }
    super.dispose();
  }

  /// Focus the first row (the screen's Down from the tab bar).
  void focusContent() {
    if (_shown.isEmpty) {
      _searchFocus.requestFocus();
      return;
    }
    _nodeFor(0).requestFocus();
  }

  Future<void> _loadPrograms() async {
    final generation = ++_loadGeneration;
    final now = DateTime.now();
    final multiServer = context.read<MultiServerProvider>();
    final programs = <LiveTvProgram>[];
    await forEachLiveTvServer(
      multiServer,
      resolveClient: multiServer.getClientForServer,
      isCurrent: () => mounted && generation == _loadGeneration,
      body: (client, _) async {
        programs.addAll(await client.liveTv.fetchSchedule(from: now, to: now.add(const Duration(hours: 4))));
      },
      onError: (client, serverInfo, error, stackTrace) =>
          appLogger.d('Channels tab: guide unavailable for ${serverInfo.serverId}', error: error),
    );
    if (!mounted || generation != _loadGeneration) return;
    final byChannel = <String, List<LiveTvProgram>>{};
    for (final channel in widget.channels) {
      byChannel[liveTvChannelScopeKey(channel)] = [];
    }
    final index = {for (final c in widget.channels) '${c.serverId}\u0000${c.key}': liveTvChannelScopeKey(c)};
    for (final p in programs) {
      final scope = index['${p.serverId}\u0000${p.channelIdentifier}'];
      if (scope != null) byChannel[scope]?.add(p);
    }
    for (final list in byChannel.values) {
      list.sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
    }
    setStateIfMounted(() => _programsByChannel = byChannel);
  }

  List<LiveTvChannel> get _shown {
    final q = _searchController.text.trim().toLowerCase();
    if (q.isEmpty) return widget.channels;
    return widget.channels
        .where(
          (c) => c.displayName.toLowerCase().contains(q) || (c.number ?? '') == q || (c.number ?? '').startsWith(q),
        )
        .toList();
  }

  FocusNode _nodeFor(int index) {
    while (_rowNodes.length <= index) {
      _rowNodes.add(FocusNode(debugLabel: 'ChannelsTab:Row${_rowNodes.length}'));
    }
    return _rowNodes[index];
  }

  ({LiveTvProgram? now, LiveTvProgram? next}) _nowNext(LiveTvChannel channel) {
    final list = _programsByChannel[liveTvChannelScopeKey(channel)] ?? const [];
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    LiveTvProgram? current;
    LiveTvProgram? next;
    for (final p in list) {
      final begins = p.beginsAt ?? 0;
      final ends = p.endsAt ?? begins;
      if (begins <= now && ends > now) {
        current ??= p;
      } else if (begins > now) {
        next ??= p;
        break;
      }
    }
    return (now: current, next: next);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: FocusableTextFormField(
            controller: _searchController,
            focusNode: _searchFocus,
            tvTextInputPresentation: TvTextInputPresentation.platform,
            tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
            onNavigateUp: widget.onNavigateUp,
            onNavigateDown: () => shown.isEmpty ? null : _nodeFor(0).requestFocus(),
            onBack: widget.onBack,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const AppIcon(Symbols.search_rounded),
              labelText: t.liveTv.searchChannels,
            ),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(child: Text(t.liveTv.noChannelsInGroup))
              : ListView.builder(
                  controller: _scrollController,
                  itemCount: shown.length,
                  itemExtent: rowHeight,
                  padding: const EdgeInsets.only(bottom: 24),
                  itemBuilder: (context, i) => _row(context, shown, i),
                ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, List<LiveTvChannel> shown, int i) {
    final theme = Theme.of(context);
    final channel = shown[i];
    final nn = _nowNext(channel);
    final favourite = widget.isFavoriteChannel?.call(channel) ?? false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final current = nn.now;
    double? progress;
    if (current?.beginsAt != null && current?.endsAt != null && current!.endsAt! > current.beginsAt!) {
      progress = ((now - current.beginsAt!) / (current.endsAt! - current.beginsAt!)).clamp(0.0, 1.0);
    }
    final is24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String? nextLine;
    if (nn.next case final next?) {
      final at = next.startTime == null ? '' : '${formatClockTime(next.startTime!, is24Hour: is24h)} ';
      nextLine = t.liveTv.nextOn(title: '$at${next.displayTitle}');
    }
    return FocusableWrapper(
      key: ValueKey('channel-row:${liveTvChannelScopeKey(channel)}'),
      focusNode: _nodeFor(i),
      useBackgroundFocus: true,
      disableScale: true,
      autoScroll: true,
      onSelect: () => unawaited(tuneChannel(channel)),
      onLongPress: widget.onToggleFavorite == null ? null : () => widget.onToggleFavorite!(channel),
      onNavigateUp: i == 0 ? () => _searchFocus.requestFocus() : () => _nodeFor(i - 1).requestFocus(),
      onNavigateDown: i < shown.length - 1 ? () => _nodeFor(i + 1).requestFocus() : null,
      onBack: widget.onBack,
      child: InkWell(
        onTap: () => unawaited(tuneChannel(channel)),
        onLongPress: widget.onToggleFavorite == null ? null : () => widget.onToggleFavorite!(channel),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  channel.number ?? '',
                  style: theme.textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 8),
              ChannelLogo(channel: channel, size: 52),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: .start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            channel.displayName,
                            style: theme.textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (channel.catchupDays > 0) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: t.liveTv.catchUpBadge,
                            child: AppIcon(Symbols.history_rounded, size: 16, color: theme.colorScheme.primary),
                          ),
                        ],
                      ],
                    ),
                    if (current != null)
                      Text(
                        t.liveTv.nowOn(title: current.displayTitle),
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (progress != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3, bottom: 2),
                        child: LinearProgressIndicator(value: progress, minHeight: 2),
                      ),
                    if (nextLine != null)
                      Text(
                        nextLine,
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (widget.onToggleFavorite != null)
                // The row itself is the D-pad target (long press toggles);
                // the star is for touch and the mouse.
                ExcludeFocus(
                  child: IconButton(
                    tooltip: favourite ? t.liveTv.removeFavorite : t.liveTv.addFavorite,
                    onPressed: () => widget.onToggleFavorite!(channel),
                    icon: AppIcon(
                      favourite ? Symbols.star_rounded : Symbols.star_outline_rounded,
                      fill: favourite ? 1 : 0,
                      color: favourite ? Colors.amber : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A channel's logo, or its initials on a tinted tile when it has none or
/// the image fails.
class ChannelLogo extends StatelessWidget {
  const ChannelLogo({super.key, required this.channel, this.size = 48});

  final LiveTvChannel channel;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Text(
        _initials(channel.displayName),
        style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
      ),
    );
    final url = _logoUrl(context);
    if (url == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.contain,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }

  String? _logoUrl(BuildContext context) {
    final thumb = channel.thumb;
    if (thumb == null || thumb.isEmpty) return null;
    if (thumb.startsWith('http://') || thumb.startsWith('https://')) return thumb;
    final serverId = channel.serverId;
    if (serverId == null) return null;
    final client = context.read<MultiServerProvider>().getClientForServer(ServerId(serverId));
    final url = client?.thumbnailUrl(thumb, width: 96, height: 96);
    return url == null || url.isEmpty ? null : url;
  }

  static String _initials(String name) {
    final words = name.split(RegExp(r'[\s\-_.]+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) return words.first.substring(0, words.first.length.clamp(1, 3)).toUpperCase();
    return (words[0][0] + words[1][0]).toUpperCase();
  }
}
