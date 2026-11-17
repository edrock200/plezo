import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../focus/hub_vertical_navigation.dart';
import '../../focus/locked_hub_controller.dart';
import '../../i18n/strings.g.dart';
import '../../media/library_query.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_sort.dart';
import '../../navigation/profile_navigation_scope.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/settings_service.dart';
import '../../services/silo/silo_client.dart';
import '../../services/silo/silo_mappers.dart';
import '../../services/silo/silo_memberships.dart';
import '../../services/silo/silo_personal_lists.dart';
import '../../utils/app_logger.dart';
import '../../utils/hub_icons.dart';
import '../../utils/layout_constants.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_media_card.dart';
import '../../widgets/focusable_tab_chip.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/hub_section.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/media_card_sliver_layout.dart';
import '../../widgets/overlay_sheet.dart';
import '../libraries/sort_bottom_sheet.dart';
import '../libraries/state_messages.dart';
import 'silo_feature_entries.dart';

/// The three parts of Silo's For You page (Android TV's `TvForYouSelector`).
enum SiloForYouTab { recommendations, favorites, watchlist }

/// The media filter of a saved list.
enum _KindFilter {
  all(null),
  movies(MediaKind.movie),
  shows(MediaKind.show);

  const _KindFilter(this.kind);

  final MediaKind? kind;
}

/// Route name of the For You page, so a second open does not stack it.
const siloForYouRouteName = 'silo_for_you';

/// Opens [SiloForYouScreen] on the profile navigator; no-op when it is
/// already on top.
Future<void> openSiloForYou(BuildContext context) async {
  final navigator = ProfileNavigationScope.maybeOf(context)?.navigatorKey.currentState ?? Navigator.of(context);
  var onTop = false;
  navigator.popUntil((route) {
    onTop = route.settings.name == siloForYouRouteName;
    return true;
  });
  if (onTop) return;
  await navigator.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: siloForYouRouteName),
      builder: (_) => const SiloForYouScreen(),
    ),
  );
}

/// Silo's For You page for one Silo connection (= one Silo profile):
/// Recommendations (`GET /recommendations/discover`, the rows Home can also
/// show), Favorites and Watchlist (`GET /catalog?source=favorites|watchlist`).
///
/// Follows Silo's apps: Recommendations opens first; an empty feed switches
/// to the Watchlist (or Favorites) with "No recommendations yet — showing
/// your saved titles."; with nothing saved either, "Not enough data yet"
/// and Check again. The shown part is read again whenever the page comes
/// back into view; a failed re-read keeps what is drawn. With several Silo
/// servers online, chips at the top pick whose For You is shown (the last
/// pick is remembered).
class SiloForYouScreen extends StatefulWidget {
  const SiloForYouScreen({super.key, this.clients});

  /// The Silo clients to offer, for tests; null reads the online ones from
  /// [MultiServerProvider].
  final List<SiloClient>? clients;

  @override
  State<SiloForYouScreen> createState() => SiloForYouScreenState();
}

/// One saved list's pages.
class _ListState {
  final items = <MediaItem>[];
  int total = 0;
  bool hasMore = false;
  bool loading = false;
  bool loadingMore = false;
  bool failed = false;
  bool loaded = false;
  int seq = 0;
  _KindFilter filter = _KindFilter.all;

  /// Null: the list's own order (most recently saved first).
  MediaSort? sort;
  bool descending = false;
}

@visibleForTesting
class SiloForYouScreenState extends State<SiloForYouScreen> with RouteAware {
  static const _pageSize = 40;

  SiloClient? _client;
  SiloForYouTab _tab = SiloForYouTab.recommendations;

  List<MediaHub>? _hubs;
  bool _recsLoading = false;
  bool _recsFailed = false;
  bool _notEnoughData = false;
  int _recsSeq = 0;

  /// The saved list is shown because the feed was empty (the caption).
  bool _savedFallback = false;

  final Map<SiloPersonalList, _ListState> _lists = {for (final list in SiloPersonalList.values) list: _ListState()};
  List<MediaSort>? _sortOptions;

  final Map<SiloForYouTab, FocusNode> _tabFocus = {
    for (final tab in SiloForYouTab.values) tab: FocusNode(debugLabel: 'SiloForYouTab_${tab.name}'),
  };
  final Map<_KindFilter, FocusNode> _kindFocus = {
    for (final f in _KindFilter.values) f: FocusNode(debugLabel: 'SiloForYouKind_${f.name}'),
  };
  final Map<String, FocusNode> _serverFocus = {};
  final _sortFocus = FocusNode(debugLabel: 'SiloForYouSort');
  final _actionFocus = FocusNode(debugLabel: 'SiloForYouAction');
  final Map<int, FocusNode> _cardFocus = {};
  final Map<String, GlobalKey<HubSectionState>> _hubKeys = {};
  HubFocusMemory _hubFocusMemory = HubFocusMemory();
  final _sheetContextKey = GlobalKey();

  RouteObserver<PageRoute<dynamic>>? _routeObserver;
  StreamSubscription<SiloMembershipChange>? _membershipChanges;

  @override
  void initState() {
    super.initState();
    _membershipChanges = SiloMembershipStore.changes.listen(_onMembershipChanged);
  }

  /// A title went on or off a Watchlist or Favorites list (a card menu here,
  /// or a page above): read the shown part again so it appears or goes. A
  /// page above refreshes this one when it closes ([didPopNext]).
  void _onMembershipChanged(SiloMembershipChange change) {
    if (!mounted || _client?.serverId.value != change.serverId) return;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    refreshShown();
  }

  /// The tab shown, for tests.
  @visibleForTesting
  SiloForYouTab get tab => _tab;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ProfileNavigationScope.maybeOf(context)?.routeObserver;
    if (observer != _routeObserver) {
      _routeObserver?.unsubscribe(this);
      _routeObserver = observer;
      final route = ModalRoute.of(context);
      if (observer != null && route is PageRoute<dynamic>) observer.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    unawaited(_membershipChanges?.cancel());
    _routeObserver?.unsubscribe(this);
    for (final node in [
      ..._tabFocus.values,
      ..._kindFocus.values,
      ..._serverFocus.values,
      ..._cardFocus.values,
      _sortFocus,
      _actionFocus,
    ]) {
      node.dispose();
    }
    super.dispose();
  }

  /// Back from a detail page or the player: read the shown part again.
  @override
  void didPopNext() => refreshShown();

  /// Reads the shown part again, keeping what is drawn if it fails.
  @visibleForTesting
  void refreshShown() {
    if (_client == null) return;
    switch (_tab) {
      case SiloForYouTab.recommendations:
        unawaited(_loadRecommendations(quiet: true));
      case SiloForYouTab.favorites || SiloForYouTab.watchlist:
        unawaited(_loadList(_listOf(_tab)!, quiet: true));
    }
  }

  static SiloPersonalList? _listOf(SiloForYouTab tab) => switch (tab) {
    SiloForYouTab.recommendations => null,
    SiloForYouTab.favorites => SiloPersonalList.favorites,
    SiloForYouTab.watchlist => SiloPersonalList.watchlist,
  };

  static SiloForYouTab _tabOf(SiloPersonalList list) => switch (list) {
    SiloPersonalList.favorites => SiloForYouTab.favorites,
    SiloPersonalList.watchlist => SiloForYouTab.watchlist,
  };

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  List<SiloClient> _clients(BuildContext context) =>
      widget.clients ?? onlineSiloClients(context.watch<MultiServerProvider?>());

  /// Keeps [_client] one of [clients]: the remembered server, else the first.
  void _resolveClient(List<SiloClient> clients) {
    final current = _client;
    if (current != null && clients.any((c) => identical(c, current))) return;
    if (clients.isEmpty) {
      _client = null;
      return;
    }
    final remembered = SettingsService.instanceOrNull?.read(SettingsService.siloForYouServerId);
    final next = clients.where((c) => c.serverId.value == remembered).firstOrNull ?? clients.first;
    _switchTo(next);
  }

  void _switchTo(SiloClient client) {
    _client = client;
    _tab = SiloForYouTab.recommendations;
    _hubs = null;
    _recsFailed = false;
    _notEnoughData = false;
    _savedFallback = false;
    _recsSeq++;
    for (final entry in _lists.entries) {
      _lists[entry.key] = _ListState();
    }
    _sortOptions = null;
    _hubKeys.clear();
    _hubFocusMemory = HubFocusMemory();
    _clearCardFocus();
    _recsLoading = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_client, client)) unawaited(_loadRecommendations());
    });
  }

  void _pickClient(SiloClient client) {
    if (identical(client, _client)) return;
    unawaited(SettingsService.instanceOrNull?.write(SettingsService.siloForYouServerId, client.serverId.value));
    setState(() => _switchTo(client));
  }

  // ---------------------------------------------------------------------------
  // Recommendations
  // ---------------------------------------------------------------------------

  Future<void> _loadRecommendations({bool quiet = false}) async {
    final client = _client;
    if (client == null) return;
    final seq = ++_recsSeq;
    if (!quiet) {
      setState(() {
        _recsLoading = true;
        _recsFailed = false;
        _notEnoughData = false;
      });
    }
    final hubs = await client.fetchPersonalRecommendationHubs();
    if (!mounted || seq != _recsSeq || !identical(client, _client)) return;
    if (hubs == null) {
      // Failed or timed out: keep drawn rows, otherwise show the error.
      setState(() {
        _recsLoading = false;
        final drawn = _hubs?.isNotEmpty == true || (quiet && _notEnoughData);
        if (!drawn) {
          _hubs = null;
          _recsFailed = true;
        }
      });
      return;
    }
    if (hubs.isNotEmpty) {
      setState(() {
        _hubs = hubs;
        _recsLoading = false;
        _recsFailed = false;
        _notEnoughData = false;
      });
      return;
    }
    // An empty feed: Silo's apps show the saved lists instead.
    await _showSavedFallback(client, seq);
  }

  /// Watchlist first, then Favorites; with nothing saved either, "Not
  /// enough data yet" stays on Recommendations.
  Future<void> _showSavedFallback(SiloClient client, int seq) async {
    for (final list in [SiloPersonalList.watchlist, SiloPersonalList.favorites]) {
      await _loadList(list);
      if (!mounted || seq != _recsSeq || !identical(client, _client)) return;
      if (_lists[list]!.items.isNotEmpty) {
        setState(() {
          _hubs = const [];
          _recsLoading = false;
          _recsFailed = false;
          _notEnoughData = false;
          if (_tab == SiloForYouTab.recommendations) {
            _tab = _tabOf(list);
            _savedFallback = true;
          }
        });
        return;
      }
    }
    setState(() {
      _hubs = const [];
      _recsLoading = false;
      _recsFailed = false;
      _notEnoughData = true;
    });
  }

  // ---------------------------------------------------------------------------
  // Saved lists
  // ---------------------------------------------------------------------------

  LibrarySort? _sortOf(_ListState state) {
    final sort = state.sort;
    if (sort == null) return null;
    return LibrarySort(
      field: sort.key,
      direction: state.descending ? LibrarySortDirection.descending : LibrarySortDirection.ascending,
    );
  }

  /// Loads [list] from its start. [quiet] keeps the drawn cards until the
  /// answer lands and keeps them when it fails.
  Future<void> _loadList(SiloPersonalList list, {bool quiet = false}) async {
    final client = _client;
    if (client == null) return;
    final state = _lists[list]!;
    final seq = ++state.seq;
    final keep = quiet && state.loaded && !state.failed;
    if (!keep) {
      setState(() {
        state.loading = true;
        state.failed = false;
        state.items.clear();
        state.total = 0;
        state.hasMore = false;
        if (_listOf(_tab) == list) _clearCardFocus();
      });
    }
    try {
      final limit = keep ? state.items.length.clamp(_pageSize, 200) : _pageSize;
      final page = await client.fetchPersonalListPage(
        list,
        offset: 0,
        limit: limit,
        sort: _sortOf(state),
        kind: state.filter.kind,
      );
      if (!mounted || seq != state.seq || !identical(client, _client)) return;
      setState(() {
        state.items
          ..clear()
          ..addAll(page.items);
        state.total = page.totalCount;
        state.hasMore = page.items.isNotEmpty && page.totalCount > page.items.length;
        state.loading = false;
        state.failed = false;
        state.loaded = true;
      });
    } catch (e) {
      appLogger.d('Silo For You: ${list.source} load failed', error: e.runtimeType);
      if (!mounted || seq != state.seq || !identical(client, _client)) return;
      setState(() {
        state.loading = false;
        if (!keep) state.failed = true;
      });
    }
  }

  Future<void> _loadMore(SiloPersonalList list) async {
    final client = _client;
    final state = _lists[list]!;
    if (client == null || !state.hasMore || state.loading || state.loadingMore || state.failed) return;
    final seq = state.seq;
    state.loadingMore = true;
    try {
      final page = await client.fetchPersonalListPage(
        list,
        offset: state.items.length,
        limit: _pageSize,
        sort: _sortOf(state),
        kind: state.filter.kind,
      );
      if (!mounted || seq != state.seq || !identical(client, _client)) return;
      setState(() {
        state.items.addAll(page.items);
        state.total = page.totalCount;
        state.hasMore = page.items.isNotEmpty && page.totalCount > state.items.length;
      });
    } catch (e) {
      appLogger.d('Silo For You: ${list.source} next page failed', error: e.runtimeType);
      if (mounted && seq == state.seq) setState(() => state.hasMore = false);
    } finally {
      if (seq == state.seq) state.loadingMore = false;
    }
  }

  void _setFilter(SiloPersonalList list, _KindFilter filter) {
    final state = _lists[list]!;
    if (state.filter == filter) return;
    state.filter = filter;
    unawaited(_loadList(list));
  }

  Future<void> _showSort(SiloPersonalList list) async {
    final client = _client;
    if (client == null) return;
    final options = _sortOptions ??= await client.fetchPersonalListSortOptions();
    if (!mounted || !identical(client, _client)) return;
    final state = _lists[list]!;
    MediaSort? pendingSort = state.sort;
    var pendingDescending = state.descending;
    var cleared = false;
    final sheetContext = _sheetContextKey.currentContext ?? context;
    if (!sheetContext.mounted) return;
    await OverlaySheetController.showAdaptive<void>(
      sheetContext,
      builder: (_) => SortBottomSheet(
        sortOptions: options,
        selectedSort: state.sort,
        isSortDescending: state.descending,
        onSortChanged: (sort, descending) {
          pendingSort = sort;
          pendingDescending = descending;
          cleared = false;
        },
        onClear: () {
          pendingSort = null;
          pendingDescending = false;
          cleared = true;
        },
      ),
    );
    if (!mounted || !identical(client, _client)) return;
    final changed = cleared
        ? state.sort != null
        : pendingSort != null && (pendingSort!.key != state.sort?.key || pendingDescending != state.descending);
    if (!changed) return;
    state.sort = cleared ? null : pendingSort;
    state.descending = cleared ? false : pendingDescending;
    unawaited(_loadList(list));
  }

  // ---------------------------------------------------------------------------
  // Tabs and focus
  // ---------------------------------------------------------------------------

  void _selectTab(SiloForYouTab tab, {bool focus = false}) {
    if (focus) _tabFocus[tab]!.requestFocus();
    if (tab == _tab) return;
    setState(() {
      _tab = tab;
      _savedFallback = false;
      _clearCardFocus();
    });
    final list = _listOf(tab);
    if (list == null) {
      if (_hubs == null && !_recsLoading) {
        unawaited(_loadRecommendations());
      } else {
        unawaited(_loadRecommendations(quiet: true));
      }
    } else {
      unawaited(_loadList(list, quiet: _lists[list]!.loaded));
    }
  }

  /// Drops the card focus nodes; disposed after the frame, once the cards
  /// that still hold them have unmounted.
  void _clearCardFocus() {
    if (_cardFocus.isEmpty) return;
    final stale = _cardFocus.values.toList();
    _cardFocus.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in stale) {
        node.dispose();
      }
    });
  }

  FocusNode _cardNode(int index) => _cardFocus.putIfAbsent(index, () => FocusNode(debugLabel: 'SiloForYouCard_$index'));

  void _focusLater(FocusNode node) {
    if (node.context != null) {
      node.requestFocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.context != null) node.requestFocus();
    });
  }

  void _focusTabs() => _tabFocus[_tab]!.requestFocus();

  /// Down from the tabs: the first row, the list controls or the state's button.
  void _focusContent() {
    final list = _listOf(_tab);
    if (list != null) {
      final state = _lists[list]!;
      if (state.failed) {
        _focusLater(_actionFocus);
      } else {
        _kindFocus[state.filter]!.requestFocus();
      }
      return;
    }
    final hubs = _hubs;
    if (hubs != null && hubs.isNotEmpty) {
      _hubKeys[hubs.first.id]?.currentState?.requestFocusFromMemory();
    } else if (_actionFocus.context != null) {
      _actionFocus.requestFocus();
    }
  }

  void _back() => unawaited(Navigator.of(context).maybePop());

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final clients = _clients(context);
    _resolveClient(clients);
    return OverlaySheetHost(
      child: KeyedSubtree(
        key: _sheetContextKey,
        child: FocusedScrollScaffold(
          title: Text(t.siloForYou.title),
          slivers: [
            if (_client == null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: StateMessageWidget(
                  message: t.siloForYou.loadFailed,
                  subtitle: t.siloForYou.loadFailedBody,
                  icon: Symbols.cloud_off_rounded,
                ),
              )
            else ...[
              SliverToBoxAdapter(child: _buildHeader(context, clients)),
              ..._buildBody(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, List<SiloClient> clients) {
    final theme = Theme.of(context);
    final tabs = SiloForYouTab.values;
    final showServers = clients.length > 1;
    _serverFocus.removeWhere((id, node) {
      final gone = !clients.any((c) => c.serverId.value == id);
      if (gone) WidgetsBinding.instance.addPostFrameCallback((_) => node.dispose());
      return gone;
    });
    String tabLabel(SiloForYouTab tab) => switch (tab) {
      SiloForYouTab.recommendations => t.siloForYou.recommendations,
      SiloForYouTab.favorites => t.siloForYou.favorites,
      SiloForYouTab.watchlist => t.siloForYou.watchlist,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showServers) ...[
            TabChipStrip(
              children: [
                for (final (index, client) in clients.indexed) ...[
                  if (index > 0) const SizedBox(width: 8),
                  FocusableTabChip(
                    key: ValueKey('silo-for-you-server-${client.serverId.value}'),
                    label: t.siloForYou.serverProfile(
                      server: client.serverName ?? client.serverId.value,
                      profile: client.connection.profileName,
                    ),
                    isSelected: identical(client, _client),
                    focusNode: _serverFocus.putIfAbsent(
                      client.serverId.value,
                      () => FocusNode(debugLabel: 'SiloForYouServer_${client.serverId.value}'),
                    ),
                    onSelect: () => _pickClient(client),
                    onNavigateLeft: index > 0
                        ? () => _serverFocus[clients[index - 1].serverId.value]?.requestFocus()
                        : null,
                    onNavigateRight: index < clients.length - 1
                        ? () => _serverFocus[clients[index + 1].serverId.value]?.requestFocus()
                        : null,
                    onNavigateDown: _focusTabs,
                    onBack: _back,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
          ],
          TabChipStrip(
            children: [
              for (final (index, tab) in tabs.indexed) ...[
                if (index > 0) const SizedBox(width: 8),
                FocusableTabChip(
                  key: ValueKey('silo-for-you-tab-${tab.name}'),
                  label: tabLabel(tab),
                  isSelected: _tab == tab,
                  focusNode: _tabFocus[tab],
                  onSelect: () => _selectTab(tab),
                  // Left/Right switch tabs, as on Silo's TV For You selector.
                  onNavigateLeft: index > 0 ? () => _selectTab(tabs[index - 1], focus: true) : null,
                  onNavigateRight: index < tabs.length - 1 ? () => _selectTab(tabs[index + 1], focus: true) : null,
                  onNavigateUp: showServers ? () => _serverFocus[_client!.serverId.value]?.requestFocus() : null,
                  onNavigateDown: _focusContent,
                  onBack: _back,
                ),
              ],
            ],
          ),
          if (_savedFallback && _tab != SiloForYouTab.recommendations) ...[
            const SizedBox(height: 8),
            Text(
              t.siloForYou.savedFallback,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildBody(BuildContext context) {
    final list = _listOf(_tab);
    return list == null ? _buildRecommendations(context) : _buildList(context, list);
  }

  List<Widget> _buildRecommendations(BuildContext context) {
    final hubs = _hubs;
    if (_recsLoading && (hubs == null || hubs.isEmpty)) return [LoadingIndicatorBox.sliver];
    if (_recsFailed || hubs == null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorStateWidget(
            message: '${t.siloForYou.loadFailed}. ${t.siloForYou.loadFailedBody}',
            icon: Symbols.error_outline_rounded,
            onRetry: _loadRecommendations,
            actionFocusNode: _actionFocus,
            onActionNavigateUp: _focusTabs,
            onActionBack: _back,
          ),
        ),
      ];
    }
    if (hubs.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StateMessageWidget(
            message: t.siloForYou.notEnoughData,
            subtitle: t.siloForYou.notEnoughDataBody,
            icon: personalRecommendationsIcon,
            actionLabel: t.siloForYou.checkAgain,
            actionIcon: Symbols.refresh_rounded,
            onAction: _loadRecommendations,
            actionFocusNode: _actionFocus,
            onActionNavigateUp: _focusTabs,
            onActionBack: _back,
          ),
        ),
      ];
    }
    final live = {for (final hub in hubs) hub.id};
    _hubKeys.removeWhere((id, _) => !live.contains(id));
    final keys = [for (final hub in hubs) _hubKeys.putIfAbsent(hub.id, GlobalKey<HubSectionState>.new)];
    return [
      SliverPadding(
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        sliver: SliverList.builder(
          itemCount: hubs.length,
          findChildIndexCallback: (key) {
            final index = keys.indexOf(key as GlobalKey<HubSectionState>);
            return index < 0 ? null : index;
          },
          itemBuilder: (context, index) => HubSection(
            key: keys[index],
            hub: hubs[index],
            focusMemory: _hubFocusMemory,
            icon: hubIconFor(hubs[index]),
            onVerticalNavigation: (isUp) => navigateVerticalHubRows(
              hubCount: keys.length,
              hubIndex: index,
              isUp: isUp,
              onTopBoundary: _focusTabs,
              requestFocus: (target) => keys[target].currentState?.requestFocusFromMemory(),
            ),
            onNavigateUp: index == 0 ? _focusTabs : null,
            onBack: _back,
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildList(BuildContext context, SiloPersonalList list) {
    final state = _lists[list]!;
    final controls = SliverToBoxAdapter(child: _buildListControls(context, list, state));
    if (state.loading && state.items.isEmpty) return [controls, LoadingIndicatorBox.sliver];
    if (state.failed) {
      return [
        controls,
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorStateWidget(
            message: t.siloForYou.listLoadFailed,
            icon: Symbols.error_outline_rounded,
            onRetry: () => _loadList(list),
            actionFocusNode: _actionFocus,
            onActionNavigateUp: () => _kindFocus[state.filter]!.requestFocus(),
            onActionBack: _back,
          ),
        ),
      ];
    }
    if (state.items.isEmpty) {
      final message = switch ((list, state.filter)) {
        (SiloPersonalList.favorites, _KindFilter.all) => t.siloForYou.favoritesEmpty,
        (SiloPersonalList.favorites, _KindFilter.movies) => t.siloForYou.favoritesEmptyMovies,
        (SiloPersonalList.favorites, _KindFilter.shows) => t.siloForYou.favoritesEmptyShows,
        (SiloPersonalList.watchlist, _KindFilter.all) => t.siloForYou.watchlistEmpty,
        (SiloPersonalList.watchlist, _KindFilter.movies) => t.siloForYou.watchlistEmptyMovies,
        (SiloPersonalList.watchlist, _KindFilter.shows) => t.siloForYou.watchlistEmptyShows,
      };
      return [
        controls,
        SliverFillRemaining(
          hasScrollBody: false,
          child: StateMessageWidget(
            message: message,
            subtitle: t.siloForYou.emptyHint,
            icon: list == SiloPersonalList.favorites ? Symbols.favorite_rounded : Symbols.bookmark_rounded,
          ),
        ),
      ];
    }
    return [controls, _buildGrid(context, list, state)];
  }

  Widget _buildListControls(BuildContext context, SiloPersonalList list, _ListState state) {
    final theme = Theme.of(context);
    final filters = _KindFilter.values;
    String filterLabel(_KindFilter f) => switch (f) {
      _KindFilter.all => t.siloForYou.all,
      _KindFilter.movies => t.siloForYou.movies,
      _KindFilter.shows => t.siloForYou.shows,
    };
    void focusFirstCard() {
      if (state.items.isNotEmpty) {
        _focusLater(_cardNode(0));
      } else if (state.failed) {
        _focusLater(_actionFocus);
      }
    }

    final sortLabel = state.sort?.title ?? t.siloForYou.recentlySaved;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (index, filter) in filters.indexed)
            FocusableTabChip(
              key: ValueKey('silo-for-you-kind-${filter.name}'),
              label: filterLabel(filter),
              isSelected: state.filter == filter,
              focusNode: _kindFocus[filter],
              onSelect: () => _setFilter(list, filter),
              onNavigateLeft: index > 0 ? () => _kindFocus[filters[index - 1]]!.requestFocus() : null,
              onNavigateRight: index < filters.length - 1
                  ? () => _kindFocus[filters[index + 1]]!.requestFocus()
                  : () => _sortFocus.requestFocus(),
              onNavigateUp: _focusTabs,
              onNavigateDown: focusFirstCard,
              onBack: _back,
            ),
          FocusableButton(
            key: const ValueKey('silo-for-you-sort'),
            focusNode: _sortFocus,
            useBackgroundFocus: true,
            onPressed: () => unawaited(_showSort(list)),
            onNavigateLeft: () => _kindFocus[filters.last]!.requestFocus(),
            onNavigateUp: _focusTabs,
            onNavigateDown: focusFirstCard,
            onBack: _back,
            child: TextButton.icon(
              onPressed: () => unawaited(_showSort(list)),
              icon: const AppIcon(Symbols.swap_vert_rounded, fill: 1),
              label: Text('${t.siloForYou.sort}: $sortLabel'),
            ),
          ),
          if (state.loaded && state.total > 0)
            Text(
              t.siloForYou.titleCount(n: state.total, count: state.total),
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _buildGrid(BuildContext context, SiloPersonalList list, _ListState state) {
    final settings = SettingsService.instanceOrNull;
    final density = settings?.read(SettingsService.libraryDensity) ?? LibraryDensity.defaultValue;
    final items = state.items;
    return MediaCardSliverLayout(
      // Posters, whatever the library view mode: Silo shows these lists as grids.
      viewMode: ViewMode.grid,
      // A list of only audiobooks shows square covers (Silo Android #974).
      shape: SiloMappers.areAllAudiobooks(items) ? CardShape.square : null,
      itemCount: items.length,
      density: density,
      padding: GridLayoutConstants.gridPadding.copyWith(top: GridLayoutConstants.gridPadding.top + 3),
      findChildIndexCallback: (key) {
        final value = (key as ValueKey<String>).value;
        final index = items.indexWhere((item) => item.globalKey == value);
        return index < 0 ? null : index;
      },
      itemBuilder: (context, position) {
        final index = position.index;
        if (state.hasMore && index >= items.length - 8) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_loadMore(list));
          });
        }
        final item = items[index];
        final columns = position.columnCount;
        return FocusableMediaCard(
          key: ValueKey(item.globalKey),
          item: item,
          focusNode: _cardNode(index),
          disableScale: position.disableScale,
          onListRefresh: () => unawaited(_loadList(list, quiet: true)),
          onNavigateUp: position.isFirstRow
              ? () => _kindFocus[state.filter]!.requestFocus()
              : () => _focusLater(_cardNode(index - columns)),
          onNavigateDown: index + columns < items.length ? () => _focusLater(_cardNode(index + columns)) : null,
          onNavigateLeft: position.isFirstColumn ? null : () => _focusLater(_cardNode(index - 1)),
          onNavigateRight: !position.isLastColumn && index + 1 < items.length
              ? () => _focusLater(_cardNode(index + 1))
              : null,
          onBack: _back,
        );
      },
    );
  }
}
