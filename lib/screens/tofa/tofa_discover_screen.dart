import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../services/tofa/tofa_client.dart';
import '../../services/tofa/tofa_extras.dart';
import '../../utils/app_logger.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../libraries/state_messages.dart';
import 'tofa_requests_screen.dart';
import 'tofa_widgets.dart';

/// Tofa's Discover for one server (`GET /discovery/page`): the featured
/// titles, then a row per shelf and lane (each opens its own page), the radar
/// (titles arriving soon) and, when the profile may request, Requests.
class TofaDiscoverScreen extends StatefulWidget {
  const TofaDiscoverScreen({super.key, required this.client});

  final TofaClient client;

  @override
  State<TofaDiscoverScreen> createState() => _TofaDiscoverScreenState();
}

class _TofaDiscoverScreenState extends State<TofaDiscoverScreen> {
  TofaDiscoverPage? _page;
  TofaRequestRights? _rights;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final (page, rights) = await (
        widget.client.discoverPage(),
        widget.client.requestRights().then<TofaRequestRights?>((r) => r).catchError((Object _) => null),
      ).wait;
      if (!mounted) return;
      setState(() {
        _page = page;
        _rights = rights;
      });
    } catch (e) {
      appLogger.d('[tofa] discover page failed', error: e.runtimeType);
      if (mounted) setState(() => _failed = true);
    }
  }

  void _push(Widget screen) => unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen)));

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final client = widget.client;
    var first = true;
    bool takeFirst() {
      final was = first;
      first = false;
      return was;
    }

    return FocusedScrollScaffold(
      title: Text(t.tofaExtras.discover),
      slivers: [
        if (_failed)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorStateWidget(
              message: t.tofaExtras.loadFailed,
              icon: Symbols.error_outline_rounded,
              onRetry: _load,
            ),
          )
        else if (page == null)
          LoadingIndicatorBox.sliver
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.list(
              children: [
                if (_rights?.canRequestAnything ?? false)
                  TofaNavRow(
                    title: t.tofaExtras.requests,
                    subtitle: t.tofaExtras.requestsSubtitle,
                    icon: Symbols.playlist_add_rounded,
                    autofocus: takeFirst(),
                    onSelect: () => _push(TofaRequestsScreen(client: client)),
                  ),
                TofaNavRow(
                  title: t.tofaExtras.radar,
                  subtitle: t.tofaExtras.radarSubtitle,
                  icon: Symbols.radar_rounded,
                  autofocus: takeFirst(),
                  onSelect: () => _push(TofaRadarScreen(client: client)),
                ),
                if (page.heroes.isNotEmpty) ...[
                  _header(context, t.tofaExtras.featured),
                  for (final item in page.heroes) TofaTitleRow(client: client, item: item),
                ],
                if (page.shelves.isNotEmpty) _header(context, t.tofaExtras.shelves),
                for (final shelf in page.shelves)
                  TofaNavRow(
                    title: shelf.title,
                    subtitle: shelf.subtitle,
                    icon: Symbols.view_list_rounded,
                    onSelect: () => _push(TofaShelfScreen(client: client, shelf: shelf)),
                  ),
                if (page.lanes.isNotEmpty) _header(context, t.tofaExtras.lanes),
                for (final lane in page.lanes)
                  TofaNavRow(
                    title: lane.title,
                    subtitle: lane.description,
                    icon: lane.followed ? Symbols.bookmark_rounded : Symbols.explore_rounded,
                    onSelect: () => _push(TofaLaneScreen(client: client, lane: lane)),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
      ],
    );
  }

  Widget _header(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleLarge),
  );
}

/// One shelf's titles, paged by its cursor (`GET /discovery/shelf/{key}`).
class TofaShelfScreen extends StatefulWidget {
  const TofaShelfScreen({super.key, required this.client, required this.shelf});

  final TofaClient client;
  final TofaDiscoverShelf shelf;

  @override
  State<TofaShelfScreen> createState() => _TofaShelfScreenState();
}

class _TofaShelfScreenState extends State<TofaShelfScreen> {
  late final List<TofaDiscoverItem> _items = [...widget.shelf.items];
  late String? _cursor = widget.shelf.nextCursor;
  bool _loadingMore = false;
  final _moreFocus = FocusNode(debugLabel: 'TofaShelf.more');

  @override
  void initState() {
    super.initState();
    // A shelf from the page may be a preview: read its first page in full.
    if (_items.isEmpty || widget.shelf.hasMore) unawaited(_more(reset: true));
  }

  @override
  void dispose() {
    _moreFocus.dispose();
    super.dispose();
  }

  Future<void> _more({bool reset = false}) async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.client.discoverShelf(widget.shelf.key, cursor: reset ? null : _cursor);
      if (!mounted) return;
      setState(() {
        if (page != null) {
          final known = {for (final i in _items) '${i.type}:${i.tmdbId}'};
          if (reset) {
            _items
              ..clear()
              ..addAll(page.items);
          } else {
            _items.addAll(page.items.where((i) => !known.contains('${i.type}:${i.tmdbId}')));
          }
          _cursor = page.nextCursor;
        }
      });
    } catch (e) {
      appLogger.d('[tofa] shelf page failed', error: e.runtimeType);
      if (mounted) showErrorSnackBar(context, t.tofaExtras.loadFailed);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(widget.shelf.title),
      slivers: [
        if (_items.isEmpty && _loadingMore)
          LoadingIndicatorBox.sliver
        else if (_items.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: StateMessageWidget(message: t.tofaExtras.empty, icon: Symbols.search_off_rounded),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.list(
              children: [
                for (var i = 0; i < _items.length; i++)
                  TofaTitleRow(client: widget.client, item: _items[i], autofocus: i == 0),
                if (_cursor != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: FocusableButton(
                        focusNode: _moreFocus,
                        useBackgroundFocus: true,
                        onPressed: _loadingMore ? null : () => unawaited(_more()),
                        child: FilledButton.tonal(
                          onPressed: _loadingMore ? null : () => unawaited(_more()),
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

/// A lane's shelves (`GET /discovery/lanes/{slug}`), with Follow.
class TofaLaneScreen extends StatefulWidget {
  const TofaLaneScreen({super.key, required this.client, required this.lane});

  final TofaClient client;
  final TofaDiscoverLane lane;

  @override
  State<TofaLaneScreen> createState() => _TofaLaneScreenState();
}

class _TofaLaneScreenState extends State<TofaLaneScreen> {
  List<TofaDiscoverShelf>? _shelves;
  late bool _followed = widget.lane.followed;
  bool _failed = false;
  bool _busy = false;
  final _followFocus = FocusNode(debugLabel: 'TofaLane.follow');

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _followFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final lane = await widget.client.discoverLane(widget.lane.slug);
      if (!mounted) return;
      setState(() {
        _shelves = lane.shelves;
        _followed = lane.lane?.followed ?? _followed;
      });
    } catch (e) {
      appLogger.d('[tofa] lane failed', error: e.runtimeType);
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _toggleFollow() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.client.followLane(widget.lane.slug, !_followed);
      if (mounted) setState(() => _followed = !_followed);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, t.tofaExtras.actionFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shelves = _shelves;
    return FocusedScrollScaffold(
      title: Text(widget.lane.title),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FocusableButton(
                focusNode: _followFocus,
                autofocus: true,
                useBackgroundFocus: true,
                onPressed: _busy ? null : () => unawaited(_toggleFollow()),
                child: FilledButton.tonal(
                  onPressed: _busy ? null : () => unawaited(_toggleFollow()),
                  child: Text(_followed ? t.tofaExtras.unfollow : t.tofaExtras.follow),
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
        else if (shelves == null)
          LoadingIndicatorBox.sliver
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.list(
              children: [
                if (widget.lane.description != null)
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(widget.lane.description!)),
                for (final shelf in shelves)
                  TofaNavRow(
                    title: shelf.title,
                    subtitle: shelf.subtitle,
                    icon: Symbols.view_list_rounded,
                    onSelect: () => unawaited(
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => TofaShelfScreen(client: widget.client, shelf: shelf),
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

/// The radar (`GET /discovery/radar`): titles arriving soon, by bucket.
class TofaRadarScreen extends StatefulWidget {
  const TofaRadarScreen({super.key, required this.client});

  final TofaClient client;

  @override
  State<TofaRadarScreen> createState() => _TofaRadarScreenState();
}

class _TofaRadarScreenState extends State<TofaRadarScreen> {
  List<TofaRadarBucket>? _buckets;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final buckets = await widget.client.discoverRadar();
      if (mounted) setState(() => _buckets = buckets);
    } catch (e) {
      appLogger.d('[tofa] radar failed', error: e.runtimeType);
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final buckets = _buckets;
    var first = true;
    return FocusedScrollScaffold(
      title: Text(t.tofaExtras.radar),
      slivers: [
        if (_failed)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorStateWidget(
              message: t.tofaExtras.loadFailed,
              icon: Symbols.error_outline_rounded,
              onRetry: _load,
            ),
          )
        else if (buckets == null)
          LoadingIndicatorBox.sliver
        else if (buckets.every((b) => b.items.isEmpty))
          SliverFillRemaining(
            hasScrollBody: false,
            child: StateMessageWidget(message: t.tofaExtras.empty, icon: Symbols.radar_rounded),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.list(
              children: [
                for (final bucket in buckets)
                  if (bucket.items.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
                      child: Text(bucket.title, style: Theme.of(context).textTheme.titleLarge),
                    ),
                    for (final item in bucket.items)
                      TofaTitleRow(
                        client: widget.client,
                        item: item,
                        statusText: item.availableOn,
                        autofocus: () {
                          final was = first;
                          first = false;
                          return was;
                        }(),
                      ),
                  ],
              ],
            ),
          ),
      ],
    );
  }
}
