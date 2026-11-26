import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../mixins/debounced_media_search.dart';
import '../../services/tofa/tofa_client.dart';
import '../../services/tofa/tofa_extras.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/search_input_field.dart';
import '../libraries/state_messages.dart';
import '../silo/silo_request_widgets.dart';
import 'tofa_title_screen.dart';
import 'tofa_widgets.dart';

/// Tofa requests for one server: search for a title to request (`GET
/// /search`'s `discover` hits), what the profile may request
/// (`GET /requests/rights`), and the profile's requests (`GET /requests`).
/// Each title opens [TofaTitleScreen], where Request is.
class TofaRequestsScreen extends StatefulWidget {
  const TofaRequestsScreen({super.key, required this.client});

  final TofaClient client;

  @override
  State<TofaRequestsScreen> createState() => _TofaRequestsScreenState();
}

class _TofaRequestsScreenState extends State<TofaRequestsScreen>
    with DebouncedMediaSearch<TofaRequestsScreen, TofaDiscoverItem> {
  List<TofaRequest>? _mine;
  TofaRequestRights? _rights;
  bool _failed = false;
  final _firstRequestFocus = FocusNode(debugLabel: 'TofaRequests.first');

  @override
  String get searchDebugLabel => 'TofaRequestsSearch';

  @override
  Future<List<TofaDiscoverItem>> performSearchQuery(String query) => widget.client.searchDiscover(query);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _firstRequestFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final (mine, rights) = await (widget.client.myRequests(), widget.client.requestRights()).wait;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _rights = rights;
      });
    } catch (e) {
      appLogger.d('[tofa] requests failed', error: e.runtimeType);
      if (mounted) setState(() => _failed = _mine == null);
    }
  }

  String _rightsText(TofaRequestRights r) {
    String access(TofaRequestAccess a) => switch (a) {
      TofaRequestAccess.off => t.tofaExtras.rightsOff,
      TofaRequestAccess.ask => t.tofaExtras.rightsAsk,
      TofaRequestAccess.auto => t.tofaExtras.rightsAuto,
    };
    return [
      '${t.siloRequests.movie}: ${access(r.movie)}${r.movieRemaining == null ? '' : ' (${t.tofaExtras.remaining(n: r.movieRemaining!)})'}',
      '${t.siloRequests.series}: ${access(r.tv)}${r.tvRemaining == null ? '' : ' (${t.tofaExtras.remaining(n: r.tvRemaining!)})'}',
    ].join(' · ');
  }

  String _requestStatusText(TofaRequest r) {
    final progress = r.downloadProgress;
    if (r.status == 'downloading' && progress != null) {
      final percent = progress <= 1 ? progress * 100 : progress;
      return '${percent.round()}%';
    }
    return r.denialReason ?? '';
  }

  bool get _searchActive => searchController.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final rights = _rights;
    return FocusedScrollScaffold(
      title: Text(t.tofaExtras.requests),
      slivers: [
        SliverToBoxAdapter(
          child: SearchInputField(
            controller: searchController,
            focusNode: searchFocusNode,
            debugLabel: searchDebugLabel,
            hintText: t.tofaExtras.searchToRequest,
            onNavigateDown: _searchActive
                ? (searchResults.isNotEmpty ? firstResultFocusNode.requestFocus : null)
                : ((_mine?.isNotEmpty ?? false) ? _firstRequestFocus.requestFocus : null),
            onEditingComplete: PlatformDetector.isTV() ? handleSearchSubmit : null,
          ),
        ),
        if (rights != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                rights.requestsAvailable ? _rightsText(rights) : t.tofaExtras.requestsOff,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        if (_searchActive) ..._buildSearch() else ..._buildMine(context),
      ],
    );
  }

  List<Widget> _buildSearch() {
    if (isSearching || !hasSearched) return [LoadingIndicatorBox.sliver];
    if (lastSearchFailed || searchResults.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StateMessageWidget(
            message: lastSearchFailed ? t.tofaExtras.loadFailed : t.siloRequests.noResults,
            icon: Symbols.search_off_rounded,
          ),
        ),
      ];
    }
    return [
      buildResultsSliver(padding: const EdgeInsets.symmetric(horizontal: 16), (context, index) {
        final item = searchResults[index];
        return TofaTitleRow(
          key: ValueKey('tofa-request-result-${item.type}-${item.tmdbId}'),
          client: widget.client,
          item: item,
          focusNode: index == 0 ? firstResultFocusNode : null,
          onNavigateUp: index == 0 ? searchFocusNode.requestFocus : null,
          onReturn: () => unawaited(_load()),
        );
      }, childCount: searchResults.length),
    ];
  }

  List<Widget> _buildMine(BuildContext context) {
    final mine = _mine;
    if (_failed) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorStateWidget(
            message: t.tofaExtras.loadFailed,
            icon: Symbols.error_outline_rounded,
            onRetry: _load,
          ),
        ),
      ];
    }
    if (mine == null) return [LoadingIndicatorBox.sliver];
    if (mine.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StateMessageWidget(
            message: t.siloRequests.noRequests,
            subtitle: t.tofaExtras.noRequestsSubtitle,
            icon: Symbols.playlist_add_rounded,
          ),
        ),
      ];
    }
    return [
      tofaSectionHeader(context, t.siloRequests.myRequests),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList.list(
          children: [
            for (var i = 0; i < mine.length; i++)
              SiloRequestRow(
                key: ValueKey('tofa-request-${mine[i].id}'),
                title: mine[i].title,
                mediaType: mine[i].type == 'tv' ? 'series' : 'movie',
                display: tofaRequestDisplay(mine[i].status),
                statusText: _requestStatusText(mine[i]).isEmpty ? null : _requestStatusText(mine[i]),
                focusNode: i == 0 ? _firstRequestFocus : null,
                onNavigateUp: i == 0 ? searchFocusNode.requestFocus : null,
                onSelect: () => unawaited(_open(mine[i])),
              ),
          ],
        ),
      ),
    ];
  }

  Future<void> _open(TofaRequest request) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TofaTitleScreen(
          client: widget.client,
          item: TofaDiscoverItem(
            tmdbId: request.tmdbId,
            type: request.type,
            title: request.title,
            requestStatus: request.status,
          ),
        ),
      ),
    );
    if (mounted) unawaited(_load());
  }
}
