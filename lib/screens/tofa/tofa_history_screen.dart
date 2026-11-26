import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../services/tofa/tofa_client.dart';
import '../../services/tofa/tofa_extras.dart';
import '../../utils/app_logger.dart';
import '../../utils/dialogs.dart';
import '../../utils/formatters.dart';
import '../../utils/media_navigation_helper.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../libraries/state_messages.dart';

/// The Tofa profile's watch history (`GET /watch/history`, newest first,
/// paged by `before`/`before_id`): each play opens its title; Remove deletes
/// one entry (`DELETE /watch/history/{id}`), Clear history all of them
/// (`DELETE /watch/history`) after a confirmation.
class TofaHistoryScreen extends StatefulWidget {
  const TofaHistoryScreen({super.key, required this.client});

  final TofaClient client;

  @override
  State<TofaHistoryScreen> createState() => _TofaHistoryScreenState();
}

class _TofaHistoryScreenState extends State<TofaHistoryScreen> {
  final List<TofaHistoryEntry> _entries = [];
  bool _hasMore = false;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  final _clearFocus = FocusNode(debugLabel: 'TofaHistory.clear');
  final _moreFocus = FocusNode(debugLabel: 'TofaHistory.more');
  final _rowFocus = <String, FocusNode>{};
  final _removeFocus = <String, FocusNode>{};

  FocusNode _row(String id) => _rowFocus.putIfAbsent(id, () => FocusNode(debugLabel: 'TofaHistory.$id'));
  FocusNode _remove(String id) => _removeFocus.putIfAbsent(id, () => FocusNode(debugLabel: 'TofaHistory.$id.remove'));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final n in [_clearFocus, _moreFocus, ..._rowFocus.values, ..._removeFocus.values]) {
      n.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await widget.client.watchHistory(after: more && _entries.isNotEmpty ? _entries.last : null);
      if (!mounted) return;
      setState(() {
        if (!more) _entries.clear();
        final known = {for (final e in _entries) e.id};
        _entries.addAll(page.items.where((e) => !known.contains(e.id)));
        _hasMore = page.hasMore && page.items.isNotEmpty;
        _loading = false;
      });
    } catch (e) {
      appLogger.d('[tofa] history failed', error: e.runtimeType);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = _entries.isEmpty;
      });
      if (_entries.isNotEmpty) showErrorSnackBar(context, t.tofaExtras.loadFailed);
    }
  }

  Future<void> _delete(TofaHistoryEntry entry) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.client.deleteHistoryEntry(entry.id);
      if (!mounted) return;
      final index = _entries.indexWhere((e) => e.id == entry.id);
      setState(() => _entries.removeWhere((e) => e.id == entry.id));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_entries.isEmpty) {
          _clearFocus.requestFocus();
        } else {
          _row(_entries[index.clamp(0, _entries.length - 1)].id).requestFocus();
        }
      });
    } catch (e) {
      if (mounted) showErrorSnackBar(context, t.tofaExtras.actionFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAll() async {
    if (_busy) return;
    final confirmed = await showConfirmDialog(
      context,
      title: t.tofaExtras.clearHistoryTitle,
      message: t.tofaExtras.clearHistoryMessage,
      confirmText: t.tofaExtras.clearHistory,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.client.clearWatchHistory();
      if (!mounted) return;
      setState(() {
        _entries.clear();
        _hasMore = false;
      });
      showSuccessSnackBar(context, t.tofaExtras.historyCleared);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, t.tofaExtras.actionFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(TofaHistoryEntry entry) async {
    final item = await widget.client.historyItem(entry).catchError((Object _) => null);
    if (!mounted) return;
    if (item == null) {
      showErrorSnackBar(context, t.tofaExtras.titleGone);
      return;
    }
    await navigateToMediaItemDetails(context, item);
  }

  String _subtitle(TofaHistoryEntry e) => [
    if (e.seasonNumber != null && e.episodeNumber != null) 'S${e.seasonNumber}E${e.episodeNumber}',
    ?e.episodeTitle,
    if (e.startedAt != null) formatRelativeDayLabel(e.startedAt!.toLocal()),
    if (e.progressPercent != null && e.progressPercent! > 0) '${e.progressPercent}%',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.tofaExtras.history),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FocusableButton(
                focusNode: _clearFocus,
                useBackgroundFocus: true,
                onPressed: _entries.isEmpty || _busy ? null : () => unawaited(_clearAll()),
                onNavigateDown: _entries.isEmpty ? null : _row(_entries.first.id).requestFocus,
                child: OutlinedButton.icon(
                  onPressed: _entries.isEmpty || _busy ? null : () => unawaited(_clearAll()),
                  icon: const AppIcon(Symbols.delete_sweep_rounded),
                  label: Text(t.tofaExtras.clearHistory),
                ),
              ),
            ),
          ),
        ),
        if (_failed)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorStateWidget(
              message: t.tofaExtras.loadFailed,
              icon: Symbols.error_outline_rounded,
              onRetry: _load,
            ),
          )
        else if (_entries.isEmpty && _loading)
          LoadingIndicatorBox.sliver
        else if (_entries.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: StateMessageWidget(message: t.tofaExtras.historyEmpty, icon: Symbols.history_rounded),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.list(
              children: [
                for (var i = 0; i < _entries.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: FocusableWrapper(
                            focusNode: _row(_entries[i].id),
                            autofocus: i == 0,
                            disableScale: true,
                            useBackgroundFocus: true,
                            autoScroll: true,
                            borderRadius: 12,
                            onSelect: () => unawaited(_open(_entries[i])),
                            onNavigateRight: _remove(_entries[i].id).requestFocus,
                            onNavigateUp: i == 0 ? _clearFocus.requestFocus : null,
                            child: InkWell(
                              canRequestFocus: false,
                              onTap: () => unawaited(_open(_entries[i])),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_entries[i].title, style: theme.textTheme.titleMedium),
                                    Text(
                                      _subtitle(_entries[i]),
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        FocusableButton(
                          focusNode: _remove(_entries[i].id),
                          useBackgroundFocus: true,
                          onPressed: _busy ? null : () => unawaited(_delete(_entries[i])),
                          onNavigateLeft: _row(_entries[i].id).requestFocus,
                          child: IconButton(
                            tooltip: t.tofaExtras.removeFromHistory,
                            onPressed: _busy ? null : () => unawaited(_delete(_entries[i])),
                            icon: const AppIcon(Symbols.delete_rounded),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_hasMore)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: FocusableButton(
                        focusNode: _moreFocus,
                        useBackgroundFocus: true,
                        onPressed: _loading ? null : () => unawaited(_load(more: true)),
                        child: FilledButton.tonal(
                          onPressed: _loading ? null : () => unawaited(_load(more: true)),
                          child: Text(t.tofaExtras.loadMore),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
