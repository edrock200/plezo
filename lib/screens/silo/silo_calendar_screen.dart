import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_wrapper.dart';
import '../../i18n/app_locale_utils.dart';
import '../../i18n/strings.g.dart';
import '../../services/settings_service.dart';
import '../../services/silo/silo_calendar.dart';
import '../../services/silo/silo_client.dart';
import '../../utils/app_logger.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_tab_chip.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/optimized_media_image.dart';
import '../libraries/state_messages.dart';
import 'silo_request_widgets.dart';

/// Silo's calendar for one Silo connection: a Monday-first week of episode
/// airings and movie releases, in the Following / Trending / All views of
/// Silo's apps (`TvCalendarScreen.kt`). Each day lists its events with the
/// server's badges (PREMIERE, NEW SEASON, FINALE, DIGITAL, PHYSICAL) and the
/// air time on the device's clock; an event opens its detail page (an
/// episode its series page with the episode selected).
class SiloCalendarScreen extends StatefulWidget {
  const SiloCalendarScreen({super.key, required this.client, this.now});

  final SiloClient client;

  /// Today, for tests.
  final DateTime? now;

  @override
  State<SiloCalendarScreen> createState() => _SiloCalendarScreenState();
}

class _SiloCalendarScreenState extends State<SiloCalendarScreen> {
  late DateTime _today = siloCalendarDay(widget.now ?? DateTime.now());
  late DateTime _weekStart = siloCalendarWeekStart(_today);
  SiloCalendarFilter _filter = SiloCalendarFilter.following;
  SiloCalendarWeek? _week;
  bool _loading = true;
  bool _failed = false;
  int _seq = 0;

  late final Map<SiloCalendarFilter, FocusNode> _filterFocus = {
    for (final f in SiloCalendarFilter.values) f: FocusNode(debugLabel: 'SiloCalendarFilter_${f.wire}'),
  };
  final _prevFocus = FocusNode(debugLabel: 'SiloCalendarPrevWeek');
  final _nextFocus = FocusNode(debugLabel: 'SiloCalendarNextWeek');
  final _todayFocus = FocusNode(debugLabel: 'SiloCalendarToday');
  final _firstEventFocus = FocusNode(debugLabel: 'SiloCalendarFirstEvent');

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final node in _filterFocus.values) {
      node.dispose();
    }
    _prevFocus.dispose();
    _nextFocus.dispose();
    _todayFocus.dispose();
    _firstEventFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final week = await widget.client.calendar.fetchWeek(_weekStart, filter: _filter, now: widget.now);
      if (!mounted || seq != _seq) return;
      setState(() {
        _week = week;
        _loading = false;
      });
    } catch (e) {
      appLogger.d('Silo calendar: load failed', error: e.runtimeType);
      if (!mounted || seq != _seq) return;
      setState(() {
        _week = null;
        _loading = false;
        _failed = true;
      });
    }
  }

  void _setFilter(SiloCalendarFilter filter) {
    if (filter == _filter) return;
    _filter = filter;
    unawaited(_load());
  }

  void _shiftWeek(int weeks) {
    _weekStart = DateTime(_weekStart.year, _weekStart.month, _weekStart.day + 7 * weeks);
    unawaited(_load());
  }

  void _goToToday() {
    _today = siloCalendarDay(widget.now ?? DateTime.now());
    final start = siloCalendarWeekStart(_today);
    if (start == _weekStart) return;
    _weekStart = start;
    unawaited(_load());
  }

  bool get _hasEvents => (_week?.eventCount ?? 0) > 0;

  void _focusEvents() {
    if (_hasEvents && !_loading) _firstEventFocus.requestFocus();
  }

  Future<void> _open(SiloCalendarItem item) => openSiloLibraryItem(
    context,
    widget.client,
    item.contentId,
    fallbackId: item.isEpisode ? item.seriesId : null,
    failureMessage: t.siloCalendar.openFailed,
  );

  String _locale() => LocaleSettings.currentLocale.intlLocaleName;

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.siloCalendar.title),
      slivers: [
        SliverToBoxAdapter(child: _buildControls(context)),
        ..._buildContent(context),
      ],
    );
  }

  Widget _buildControls(BuildContext context) {
    final theme = Theme.of(context);
    final filters = SiloCalendarFilter.values;
    final weekEnd = DateTime(_weekStart.year, _weekStart.month, _weekStart.day + 6);
    final range = '${DateFormat.MMMd(_locale()).format(_weekStart)} – ${DateFormat.yMMMd(_locale()).format(weekEnd)}';
    final isThisWeek = siloCalendarWeekStart(_today) == _weekStart;

    Widget iconButton(FocusNode node, IconData icon, String tooltip, VoidCallback onPressed, {VoidCallback? left}) =>
        FocusableButton(
          focusNode: node,
          useBackgroundFocus: true,
          onPressed: onPressed,
          onNavigateUp: () => _filterFocus[_filter]!.requestFocus(),
          onNavigateDown: _focusEvents,
          onNavigateLeft: left,
          child: IconButton(onPressed: onPressed, tooltip: tooltip, icon: AppIcon(icon)),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TabChipStrip(
            children: [
              for (final (index, filter) in filters.indexed) ...[
                if (index > 0) const SizedBox(width: 8),
                FocusableTabChip(
                  label: _filterLabel(filter),
                  isSelected: _filter == filter,
                  focusNode: _filterFocus[filter],
                  onSelect: () => _setFilter(filter),
                  onNavigateLeft: index > 0 ? () => _filterFocus[filters[index - 1]]!.requestFocus() : null,
                  onNavigateRight: index < filters.length - 1
                      ? () => _filterFocus[filters[index + 1]]!.requestFocus()
                      : null,
                  onNavigateDown: () => _prevFocus.requestFocus(),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              iconButton(_prevFocus, Symbols.chevron_left_rounded, t.siloCalendar.previousWeek, () => _shiftWeek(-1)),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(range, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
              iconButton(
                _nextFocus,
                Symbols.chevron_right_rounded,
                t.siloCalendar.nextWeek,
                () => _shiftWeek(1),
                left: () => _prevFocus.requestFocus(),
              ),
              if (!isThisWeek) ...[
                const SizedBox(width: 8),
                FocusableButton(
                  focusNode: _todayFocus,
                  useBackgroundFocus: true,
                  onPressed: _goToToday,
                  onNavigateUp: () => _filterFocus[_filter]!.requestFocus(),
                  onNavigateDown: _focusEvents,
                  onNavigateLeft: () => _nextFocus.requestFocus(),
                  child: OutlinedButton(onPressed: _goToToday, child: Text(t.siloCalendar.thisWeek)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _filterLabel(SiloCalendarFilter filter) => switch (filter) {
    SiloCalendarFilter.following => t.siloCalendar.following,
    SiloCalendarFilter.trending => t.siloCalendar.trending,
    SiloCalendarFilter.all => t.siloCalendar.all,
  };

  List<Widget> _buildContent(BuildContext context) {
    if (_loading) return [LoadingIndicatorBox.sliver];
    final week = _week;
    if (_failed || week == null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorStateWidget(
            message: '${t.siloCalendar.loadFailed}. ${t.siloCalendar.loadFailedBody}',
            icon: Symbols.error_outline_rounded,
            onRetry: _load,
          ),
        ),
      ];
    }
    if (week.eventCount == 0) {
      final (title, body) = switch (_filter) {
        SiloCalendarFilter.following => (t.siloCalendar.emptyFollowingTitle, t.siloCalendar.emptyFollowingBody),
        SiloCalendarFilter.trending => (t.siloCalendar.emptyTrendingTitle, t.siloCalendar.emptyTrendingBody),
        SiloCalendarFilter.all => (t.siloCalendar.emptyAllTitle, t.siloCalendar.emptyAllBody),
      };
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StateMessageWidget(message: title, subtitle: body, icon: Symbols.calendar_month_rounded, iconSize: 64),
        ),
      ];
    }

    final theme = Theme.of(context);
    final hideSpoilers = SettingsService.instanceOrNull?.read(SettingsService.hideSpoilers) ?? false;
    final use24 = MediaQuery.alwaysUse24HourFormatOf(context);
    var firstAssigned = false;
    final children = <Widget>[];
    for (var i = 0; i < 7; i++) {
      final day = DateTime(week.start.year, week.start.month, week.start.day + i);
      final events = week.days[i];
      final label = day == _today ? t.siloCalendar.today : DateFormat.MMMMEEEEd(_locale()).format(day);
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
          child: Text(label, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
        ),
      );
      if (events.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Text(
              t.siloCalendar.nothingScheduled,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        );
        continue;
      }
      for (final event in events) {
        final first = !firstAssigned;
        firstAssigned = true;
        children.add(
          SiloCalendarRow(
            key: ValueKey('silo-calendar-${event.contentId}'),
            item: event,
            hideSpoilers: hideSpoilers,
            airTime: event.airClock == null ? null : formatClockTime(event.airClock!, is24Hour: use24),
            focusNode: first ? _firstEventFocus : null,
            onNavigateUp: first ? () => _prevFocus.requestFocus() : null,
            onSelect: () => unawaited(_open(event)),
          ),
        );
      }
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
        sliver: SliverList.list(children: children),
      ),
    ];
  }
}

String siloCalendarBadgeLabel(SiloCalendarBadge badge) => switch (badge) {
  SiloCalendarBadge.premiere => t.siloCalendar.badgePremiere,
  SiloCalendarBadge.newSeason => t.siloCalendar.badgeNewSeason,
  SiloCalendarBadge.finale => t.siloCalendar.badgeFinale,
  SiloCalendarBadge.digital => t.siloCalendar.badgeDigital,
  SiloCalendarBadge.physical => t.siloCalendar.badgePhysical,
};

/// "S5 · E14 · Title" for episodes, "Movie" for films (Silo's card caption);
/// the episode title is left out under the spoiler rule.
String siloCalendarSubtitle(SiloCalendarItem item, {required bool hideSpoilers}) {
  final parts = <String>[];
  if (item.isEpisode) {
    if (item.seasonNumber != null && item.episodeNumber != null) {
      parts.add(t.siloCalendar.episodeCode(season: item.seasonNumber!, episode: item.episodeNumber!));
    }
    final title = item.episodeTitleShown(hideSpoilers: hideSpoilers);
    if (title != null) parts.add(title);
  } else if (item.isMovie) {
    parts.add(t.siloCalendar.movie);
  }
  return parts.join(' · ');
}

/// One calendar event: poster (dimmed when watched), title, caption,
/// badge pills and air time.
class SiloCalendarRow extends StatelessWidget {
  const SiloCalendarRow({
    super.key,
    required this.item,
    required this.onSelect,
    this.hideSpoilers = false,
    this.airTime,
    this.focusNode,
    this.onNavigateUp,
  });

  final SiloCalendarItem item;
  final VoidCallback onSelect;
  final bool hideSpoilers;
  final String? airTime;
  final FocusNode? focusNode;
  final VoidCallback? onNavigateUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final subtitle = siloCalendarSubtitle(item, hideSpoilers: hideSpoilers);
    final badges = [for (final badge in item.badges) siloCalendarBadgeLabel(badge)];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: FocusableWrapper(
        focusNode: focusNode,
        onSelect: onSelect,
        onNavigateUp: onNavigateUp,
        disableScale: true,
        borderRadius: 12,
        descendantsAreFocusable: false,
        semanticLabel: [
          item.title,
          if (subtitle.isNotEmpty) subtitle,
          ...badges,
          ?airTime,
          if (item.watched) t.siloCalendar.watched,
        ].join(', '),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Opacity(
                  opacity: item.watched ? 0.65 : 1,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(6)),
                    child: OptimizedMediaImage.poster(imagePath: item.posterUrl, width: 60, height: 90),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                      ],
                      if (badges.isNotEmpty || airTime != null || item.watched) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final label in badges) _Pill(label: label, color: theme.colorScheme.primary),
                            if (airTime != null) Text(airTime!, style: muted),
                            if (item.watched)
                              AppIcon(
                                Symbols.check_circle_rounded,
                                fill: 1,
                                size: 18,
                                color: theme.colorScheme.primary,
                                semanticLabel: t.siloCalendar.watched,
                              ),
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

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: const BorderRadius.all(Radius.circular(8)),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
    ),
  );
}
