import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../mixins/debounced_media_search.dart';
import '../../services/silo/silo_client.dart';
import '../../services/silo/silo_requests.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/search_input_field.dart';
import '../libraries/state_messages.dart';
import 'silo_request_widgets.dart';

/// Silo's Requests page for one Silo connection: search the request
/// provider for a movie or series, and the account's own requests ("My
/// requests", in motion first). Reached from the profile menu while the
/// server's `GET /requests/status` enables requests for the profile (Silo
/// Android #782 puts Requests in the profile menu on TV).
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
  final _firstRecordFocus = FocusNode(debugLabel: 'SiloMyRequestsFirst');

  @override
  String get searchDebugLabel => 'SiloRequestsSearch';

  SiloRequestsApi get _requests => widget.client.requests;

  @override
  Future<List<SiloRequestMediaResult>> performSearchQuery(String query) => _requests.search(query);

  @override
  void initState() {
    super.initState();
    unawaited(_loadMine());
  }

  @override
  void dispose() {
    _firstRecordFocus.dispose();
    super.dispose();
  }

  Future<void> _loadMine() async {
    setState(() {
      _mineLoading = _mine == null;
      _mineFailed = false;
    });
    try {
      final records = await _requests.mine();
      if (!mounted) return;
      setState(() {
        _mine = siloBucketMyRequests(records);
        _mineLoading = false;
      });
    } catch (e) {
      appLogger.d('Silo requests: My requests failed', error: e.runtimeType);
      if (!mounted) return;
      setState(() {
        _mineLoading = false;
        _mineFailed = _mine == null;
      });
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
    return (_mine?.isNotEmpty ?? false) ? _firstRecordFocus.requestFocus : null;
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
            return SiloRequestRow(
              key: ValueKey('silo-request-record-${record.id}'),
              title: record.title,
              mediaType: record.mediaType,
              year: record.year,
              posterPath: record.posterPath,
              display: record.display,
              statusText: siloRequestRecordStatus(record),
              focusNode: index == 0 ? _firstRecordFocus : null,
              onNavigateUp: index == 0 ? searchFocusNode.requestFocus : null,
              onSelect: () => unawaited(_openRecord(record)),
            );
          },
        ),
      ),
    ];
  }

  Widget _header(BuildContext context, String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
    ),
  );
}
