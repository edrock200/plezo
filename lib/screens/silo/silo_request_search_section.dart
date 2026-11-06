import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/silo/silo_client.dart';
import '../../services/silo/silo_requests.dart';
import '../../utils/app_logger.dart';
import '../../widgets/optimized_media_image.dart';
import 'silo_feature_entries.dart';
import 'silo_request_widgets.dart';

/// Search's "Available to request" row for each online Silo server that
/// enables requests: the request provider's titles for [query], without the
/// ones the server marks `availability: "available"` (the library results
/// above already show them; Silo Android #773). Renders nothing for servers
/// without requests, short queries, failed searches or when every match is
/// in the library. A sliver.
class SiloRequestSearchSection extends StatefulWidget {
  const SiloRequestSearchSection({super.key, required this.query, this.onNavigateLeft});

  final String query;

  /// Left from the first card (the main screen's sidebar).
  final VoidCallback? onNavigateLeft;

  /// Queries shorter than this are not sent (Silo's apps wait for two characters).
  static const minQueryLength = 2;

  @override
  State<SiloRequestSearchSection> createState() => _SiloRequestSearchSectionState();
}

class _SiloRequestSearchSectionState extends State<SiloRequestSearchSection> {
  /// Results per Silo client, for the query in [_answeredQuery].
  Map<SiloClient, List<SiloRequestMediaResult>> _results = const {};
  String? _answeredQuery;
  Set<SiloClient> _searchedClients = const {};
  int _seq = 0;
  List<SiloClient> _clients = const [];
  Listenable? _gates;
  List<StreamSubscription<SiloMediaRequest>> _removals = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final servers = context.watch<MultiServerProvider?>();
    final clients = onlineSiloClients(servers);
    if (!_sameClients(clients)) {
      _gates?.removeListener(_onGateChanged);
      _clients = clients;
      _gates = Listenable.merge([for (final c in clients) c.requests.enabled])..addListener(_onGateChanged);
      for (final sub in _removals) {
        unawaited(sub.cancel());
      }
      _removals = [for (final c in clients) c.requests.removals.listen((record) => _onRemoved(c, record))];
      for (final c in clients) {
        unawaited(c.requests.refreshStatus());
      }
      _search();
    }
  }

  bool _sameClients(List<SiloClient> clients) =>
      clients.length == _clients.length && clients.indexed.every((e) => identical(e.$2, _clients[e.$1]));

  @override
  void didUpdateWidget(SiloRequestSearchSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query.trim() != widget.query.trim()) _search();
  }

  @override
  void dispose() {
    _gates?.removeListener(_onGateChanged);
    for (final sub in _removals) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  /// The viewer removed a failed request on [client] (Silo Android #792): its
  /// card here is requestable again.
  void _onRemoved(SiloClient client, SiloMediaRequest record) {
    final results = _results[client];
    if (!mounted || results == null) return;
    final patched = siloResultsApplyingRemoval(results, record);
    if (identical(patched, results)) return;
    setState(() => _results = {..._results, client: patched});
  }

  void _onGateChanged() {
    if (mounted) setState(_search);
  }

  List<SiloClient> get _enabledClients => [
    for (final c in _clients)
      if (c.requests.enabled.value) c,
  ];

  /// Starts the search for the current query; the synchronous part only
  /// sets fields (callers outside a build wrap it in setState).
  void _search() {
    final query = widget.query.trim();
    final clients = _enabledClients;
    if (query.length < SiloRequestSearchSection.minQueryLength || clients.isEmpty) {
      _seq++;
      _results = const {};
      _answeredQuery = null;
      _searchedClients = const {};
      return;
    }
    if (query == _answeredQuery &&
        clients.toSet().containsAll(_searchedClients) &&
        clients.length == _searchedClients.length) {
      return;
    }
    final seq = ++_seq;
    unawaited(() async {
      final answers = await Future.wait([
        for (final client in clients)
          client.requests.search(query).then<List<SiloRequestMediaResult>>(siloRequestsWithoutLibraryTitles).catchError(
            (Object e) {
              appLogger.d('Silo requests: search failed', error: e.runtimeType);
              return const <SiloRequestMediaResult>[];
            },
          ),
      ]);
      if (!mounted || seq != _seq) return;
      setState(() {
        _answeredQuery = query;
        _searchedClients = clients.toSet();
        _results = {
          for (final (i, client) in clients.indexed)
            if (answers[i].isNotEmpty) client: answers[i],
        };
      });
    }());
  }

  Future<void> _open(SiloClient client, SiloRequestMediaResult result) async {
    await openSiloRequestTitle(
      context,
      client,
      mediaType: result.mediaType,
      tmdbId: result.tmdbId,
      title: result.title,
      display: result.display,
      libraryContentId: result.libraryContentId,
      posterPath: result.posterPath,
    );
    // A request made on the detail page changes the cards' status.
    _answeredQuery = null;
    if (mounted) setState(_search);
  }

  @override
  Widget build(BuildContext context) {
    if (_results.isEmpty || _answeredQuery != widget.query.trim()) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final named = _clients.length > 1;
    final theme = Theme.of(context);
    return SliverList.list(
      children: [
        for (final MapEntry(key: client, value: results) in _results.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Text(
              named
                  ? t.siloRequests.availableToRequestOnServer(server: client.serverName ?? client.serverId.value)
                  : t.siloRequests.availableToRequest,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(
            // Poster, title and a status pill (a pill overflowed 250 by 12 px).
            height: 264,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: results.length,
              itemBuilder: (context, index) => SiloRequestPosterCard(
                key: ValueKey('silo-request-search-${client.serverId.value}-${results[index].key}'),
                result: results[index],
                onNavigateLeft: index == 0 ? widget.onNavigateLeft : null,
                onSelect: () => unawaited(_open(client, results[index])),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A request title as a poster card with its status.
class SiloRequestPosterCard extends StatelessWidget {
  const SiloRequestPosterCard({super.key, required this.result, required this.onSelect, this.onNavigateLeft});

  final SiloRequestMediaResult result;
  final VoidCallback onSelect;
  final VoidCallback? onNavigateLeft;

  static const width = 120.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = result.display;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: FocusableWrapper(
        onSelect: onSelect,
        onNavigateLeft: onNavigateLeft,
        borderRadius: 8,
        descendantsAreFocusable: false,
        semanticLabel: [result.title, if (display != null) siloRequestLabel(display)].join(', '),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onSelect,
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  child: OptimizedMediaImage.poster(
                    imagePath: siloRequestImageUrl(result.posterPath),
                    width: width,
                    height: 180,
                  ),
                ),
                const SizedBox(height: 6),
                Text(result.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                if (display != null) ...[
                  const SizedBox(height: 4),
                  SiloRequestStatusPill(display: display),
                ] else if (result.year != null)
                  Text(
                    '${result.year}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
