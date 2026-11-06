import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/debounced_media_search.dart';
import '../../services/silo/silo_client.dart';
import '../../services/silo/silo_requests.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/search_input_field.dart';
import '../libraries/state_messages.dart';
import 'silo_request_widgets.dart';

/// Silo's Requests page for one Silo connection: search the request
/// provider for a movie or series, and the account's own requests ("My
/// requests", in motion first). Reached from the profile menu while the
/// server's `GET /requests/status` enables requests for the profile (Silo
/// Android #782 puts Requests in the profile menu on TV). A failed request
/// that delivered nothing offers Remove where the server takes it (#792).
class SiloRequestsScreen extends StatefulWidget {
  const SiloRequestsScreen({super.key, required this.client});

  final SiloClient client;

  @override
  State<SiloRequestsScreen> createState() => _SiloRequestsScreenState();
}

class _SiloRequestsScreenState extends State<SiloRequestsScreen>
    with DebouncedMediaSearch<SiloRequestsScreen, SiloRequestMediaResult> {
  List<SiloMediaRequest>? _mine;
  bool _mineLoading = true;
  bool _mineFailed = false;

  /// The request whose removal is in flight; Remove waits for it.
  String? _removingId;
  StreamSubscription<SiloMediaRequest>? _removals;

  /// Each listed request's row and Remove button, by request id.
  final _rowFocus = <String, FocusNode>{};
  final _removeFocus = <String, FocusNode>{};

  @override
  String get searchDebugLabel => 'SiloRequestsSearch';

  SiloRequestsApi get _requests => widget.client.requests;

  @override
  Future<List<SiloRequestMediaResult>> performSearchQuery(String query) => _requests.search(query);

  @override
  void initState() {
    super.initState();
    _requests.removeFailedSupported.addListener(_onCapabilityChanged);
    _removals = _requests.removals.listen(_onRemoved);
    // Remove is offered only where the server takes it.
    unawaited(_requests.refreshStatus());
    unawaited(_loadMine());
  }

  @override
  void dispose() {
    _requests.removeFailedSupported.removeListener(_onCapabilityChanged);
    unawaited(_removals?.cancel());
    for (final node in [..._rowFocus.values, ..._removeFocus.values]) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _rowNode(String id) => _rowFocus.putIfAbsent(id, () => FocusNode(debugLabel: 'SiloMyRequest.$id'));
  FocusNode _removeNode(String id) =>
      _removeFocus.putIfAbsent(id, () => FocusNode(debugLabel: 'SiloMyRequest.$id.remove'));

  /// Disposes the focus nodes of requests no longer listed, once the frame
  /// that dropped their rows has detached them.
  void _pruneFocusNodes() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final listed = {for (final record in _mine ?? const <SiloMediaRequest>[]) record.id};
      for (final nodes in [_rowFocus, _removeFocus]) {
        for (final id in [...nodes.keys]) {
          if (!listed.contains(id)) nodes.remove(id)!.dispose();
        }
      }
    });
  }

  void _onCapabilityChanged() {
    if (mounted) setState(() {});
  }

  /// Whether the last read of My requests answered.
  Future<bool> _loadMine() async {
    setState(() {
      _mineLoading = _mine == null;
      _mineFailed = false;
    });
    try {
      final records = await _requests.mine();
      if (!mounted) return false;
      setState(() {
        _mine = siloBucketMyRequests(records);
        _mineLoading = false;
      });
      _pruneFocusNodes();
      return true;
    } catch (e) {
      appLogger.d('Silo requests: My requests failed', error: e.runtimeType);
      if (!mounted) return false;
      setState(() {
        _mineLoading = false;
        _mineFailed = _mine == null;
      });
      return false;
    }
  }

  /// A removal here or on a detail page: the row leaves the list, and a
  /// focused row hands focus to the one that takes its place (else the one
  /// above, else the search field).
  void _onRemoved(SiloMediaRequest record) {
    final mine = _mine;
    if (!mounted || mine == null) return;
    final index = mine.indexWhere((r) => r.id == record.id);
    if (index < 0) return;
    final hadFocus = (_rowFocus[record.id]?.hasFocus ?? false) || (_removeFocus[record.id]?.hasFocus ?? false);
    final remaining = [...mine]..removeAt(index);
    setState(() => _mine = remaining);
    _pruneFocusNodes();
    if (!hadFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (remaining.isEmpty) {
        searchFocusNode.requestFocus();
      } else {
        _rowNode(remaining[index < remaining.length ? index : remaining.length - 1].id).requestFocus();
      }
    });
  }

  /// Remove on a failed request that delivered nothing (Silo Android #792):
  /// after a confirmation naming the title, one `DELETE`, never resent.
  Future<void> _remove(SiloMediaRequest record) async {
    if (_removingId != null || !_requests.canRemove(record)) return;
    final confirmed = await confirmSiloRequestRemoval(context, record.title);
    if (!confirmed || !mounted || _removingId != null) return;
    setState(() => _removingId = record.id);
    try {
      // The removals listener drops the row.
      await _requests.removeFailed(record);
      if (!mounted) return;
      showSuccessSnackBar(context, t.siloRequests.requestRemoved);
      unawaited(_loadMine());
    } on SiloRequestFailure catch (failure) {
      if (!mounted) return;
      if (failure.kind == SiloRequestFailureKind.uncertain) {
        // A fresh read shows whether it landed; nothing is held either way.
        final read = await _loadMine();
        if (!mounted) return;
        final gone = read && !(_mine ?? const []).any((r) => r.id == record.id);
        if (gone) {
          showSuccessSnackBar(context, t.siloRequests.requestRemoved);
        } else {
          showErrorSnackBar(context, t.siloRequests.unconfirmedRemove);
        }
      } else if (siloRemovalConflict(failure)) {
        // Retried or completed since the list loaded: show what it is now.
        showErrorSnackBar(context, t.siloRequests.removeConflict);
        unawaited(_loadMine());
      } else {
        showErrorSnackBar(
          context,
          siloRequestFailureText(
            failure,
            unconfirmed: t.siloRequests.unconfirmedRemove,
            fallback: t.siloRequests.removeFailed,
          ),
        );
        if (failure.kind == SiloRequestFailureKind.disabled) unawaited(_requests.refreshStatus(force: true));
      }
    } finally {
      if (mounted) setState(() => _removingId = null);
    }
  }

  /// Returning from a detail page re-reads what it may have changed.
  Future<void> _afterOpen() async {
    if (!mounted) return;
    unawaited(_loadMine());
    final query = searchController.text.trim();
    if (query.isNotEmpty) unawaited(runSearch(query));
  }

  Future<void> _openResult(SiloRequestMediaResult result) async {
    await openSiloRequestTitle(
      context,
      widget.client,
      mediaType: result.mediaType,
      tmdbId: result.tmdbId,
      title: result.title,
      display: result.display,
      libraryContentId: result.libraryContentId,
      posterPath: result.posterPath,
    );
    await _afterOpen();
  }

  Future<void> _openRecord(SiloMediaRequest record) async {
    await openSiloRequestTitle(
      context,
      widget.client,
      mediaType: record.mediaType,
      tmdbId: record.tmdbId,
      title: record.title,
      display: record.display,
      libraryContentId: record.libraryContentId,
      posterPath: record.posterPath,
    );
    await _afterOpen();
  }

  bool get _searchActive => searchController.text.trim().isNotEmpty;

  VoidCallback? get _downFromSearch {
    if (_searchActive) return searchResults.isNotEmpty && !isSearching ? firstResultFocusNode.requestFocus : null;
    final mine = _mine;
    return (mine != null && mine.isNotEmpty) ? _rowNode(mine.first.id).requestFocus : null;
  }

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.siloRequests.title),
      slivers: [
        SliverToBoxAdapter(
          child: SearchInputField(
            controller: searchController,
            focusNode: searchFocusNode,
            debugLabel: searchDebugLabel,
            hintText: t.siloRequests.searchHint,
            onNavigateDown: _downFromSearch,
            onEditingComplete: PlatformDetector.isTV() ? handleSearchSubmit : null,
          ),
        ),
        if (_searchActive) ..._buildSearch(context) else ..._buildMine(context),
      ],
    );
  }

  List<Widget> _buildSearch(BuildContext context) {
    if (isSearching || !hasSearched) return [LoadingIndicatorBox.sliver];
    if (lastSearchFailed) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StateMessageWidget(message: t.siloRequests.searchFailed, icon: Symbols.error_rounded, iconSize: 64),
        ),
      ];
    }
    if (searchResults.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StateMessageWidget(message: t.siloRequests.noResults, icon: Symbols.search_off_rounded, iconSize: 64),
        ),
      ];
    }
    return [
      _header(context, t.siloRequests.searchResults),
      buildResultsSliver(padding: const EdgeInsets.symmetric(horizontal: 16), (context, index) {
        final result = searchResults[index];
        return SiloRequestRow(
          key: ValueKey('silo-request-result-${result.key}'),
          title: result.title,
          mediaType: result.mediaType,
          year: result.year,
          posterPath: result.posterPath,
          display: result.display,
          focusNode: index == 0 ? firstResultFocusNode : null,
          onNavigateUp: index == 0 ? searchFocusNode.requestFocus : null,
          onSelect: () => unawaited(_openResult(result)),
        );
      }),
    ];
  }

  List<Widget> _buildMine(BuildContext context) {
    if (_mineLoading) return [LoadingIndicatorBox.sliver];
    if (_mineFailed) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorStateWidget(
            message: t.siloRequests.loadFailed,
            icon: Symbols.error_outline_rounded,
            onRetry: _loadMine,
          ),
        ),
      ];
    }
    final mine = _mine ?? const [];
    if (mine.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StateMessageWidget(
            message: t.siloRequests.noRequests,
            subtitle: t.siloRequests.noRequestsSubtitle,
            icon: Symbols.playlist_add_rounded,
            iconSize: 64,
          ),
        ),
      ];
    }
    return [
      _header(context, t.siloRequests.myRequests),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: SliverList.builder(
          itemCount: mine.length,
          itemBuilder: (context, index) {
            final record = mine[index];
            final removable = _requests.canRemove(record);
            final rowNode = _rowNode(record.id);
            final up = index == 0 ? searchFocusNode.requestFocus : _rowNode(mine[index - 1].id).requestFocus;
            final down = index < mine.length - 1 ? _rowNode(mine[index + 1].id).requestFocus : null;
            return SiloRequestRow(
              key: ValueKey('silo-request-record-${record.id}'),
              title: record.title,
              mediaType: record.mediaType,
              year: record.year,
              posterPath: record.posterPath,
              display: record.display,
              statusText: siloRequestRecordStatus(record),
              focusNode: rowNode,
              onNavigateUp: up,
              onNavigateDown: down,
              onNavigateRight: removable ? _removeNode(record.id).requestFocus : null,
              onSelect: () => unawaited(_openRecord(record)),
              trailing: removable ? _removeButton(record, rowNode, up: up, down: down) : null,
            );
          },
        ),
      ),
    ];
  }

  /// Remove beside a removable row: LEFT goes back to the row; UP and DOWN
  /// move between rows like the row itself.
  Widget _removeButton(SiloMediaRequest record, FocusNode rowNode, {VoidCallback? up, VoidCallback? down}) {
    final busy = _removingId == record.id;
    void onPressed() => unawaited(_remove(record));
    return FocusableButton(
      key: ValueKey('silo-request-remove-${record.id}'),
      focusNode: _removeNode(record.id),
      useBackgroundFocus: true,
      onPressed: onPressed,
      onNavigateLeft: rowNode.requestFocus,
      onNavigateUp: up,
      onNavigateDown: down,
      child: FilledButton.tonalIcon(
        onPressed: busy ? null : onPressed,
        icon: busy
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const AppIcon(Symbols.delete_rounded, fill: 1),
        label: Text(t.siloRequests.removeRequest),
      ),
    );
  }

  Widget _header(BuildContext context, String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
    ),
  );
}
