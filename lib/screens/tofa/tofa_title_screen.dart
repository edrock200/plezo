import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../media/remote_trailer.dart';
import '../../services/tofa/tofa_client.dart';
import '../../services/tofa/tofa_extras.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_navigation_helper.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/youtube_trailer_launcher.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/optimized_media_image.dart';
import '../libraries/state_messages.dart';
import '../silo/silo_request_widgets.dart';
import 'tofa_widgets.dart';

/// A Discover title on a Tofa server (`GET /discovery/detail/{type}/{tmdb}`):
/// what it is, whether it is in the library (Open), its request state and
/// Request (when `requests_available` and the profile's `request_rights`
/// allow it), Seen and Not interested marks, its trailer, and its cast when
/// the answer lists one.
class TofaTitleScreen extends StatefulWidget {
  const TofaTitleScreen({super.key, required this.client, required this.item});

  final TofaClient client;
  final TofaDiscoverItem item;

  @override
  State<TofaTitleScreen> createState() => _TofaTitleScreenState();
}

class _TofaTitleScreenState extends State<TofaTitleScreen> {
  TofaDiscoverDetail? _detail;
  TofaRequestRights? _rights;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  final _actionNodes = <String, FocusNode>{};

  TofaDiscoverItem get _item => _detail?.item ?? widget.item;

  FocusNode _node(String id) => _actionNodes.putIfAbsent(id, () => FocusNode(debugLabel: 'TofaTitle.$id'));

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final node in _actionNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _detail == null;
      _failed = false;
    });
    try {
      final (detail, rights) = await (
        widget.client.discoverDetail(widget.item),
        widget.client.requestRights().then<TofaRequestRights?>((r) => r).catchError((Object _) => null),
      ).wait;
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _rights = rights ?? detail.rights;
        _loading = false;
      });
    } catch (e) {
      appLogger.d('[tofa] discovery detail failed', error: e.runtimeType);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = _detail == null;
      });
    }
  }

  Future<void> _run(Future<void> Function() action, {String? success, String? failure}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && success != null) showSuccessSnackBar(context, success);
    } catch (e) {
      appLogger.d('[tofa] discover action failed', error: e.runtimeType);
      if (mounted) showErrorSnackBar(context, failure ?? t.tofaExtras.actionFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openInLibrary() async {
    final item = await widget.client.discoverLibraryItem(_item);
    if (!mounted) return;
    if (item == null) {
      showErrorSnackBar(context, t.siloRequests.openFailed);
      return;
    }
    await navigateToMediaItemDetails(context, item);
  }

  Future<void> _request({bool is4k = false}) => _run(
    () async {
      final created = await widget.client.createRequest(_item, is4k: is4k);
      if (!mounted) return;
      setState(() => _detail = _withItem(_item.copyWith(requestStatus: created?.status ?? 'pending_approval')));
    },
    success: t.tofaExtras.requested,
    failure: t.tofaExtras.requestFailed,
  );

  Future<void> _toggleSeen() => _run(() async {
    final seen = !_item.seen;
    await widget.client.setSeen(_item, seen);
    if (mounted) setState(() => _detail = _withItem(_item.copyWith(seen: seen)));
  });

  Future<void> _toggleNotInterested() => _run(() async {
    final value = !_item.notInterested;
    await widget.client.setNotInterested(_item, value);
    if (mounted) setState(() => _detail = _withItem(_item.copyWith(notInterested: value)));
  });

  TofaDiscoverDetail _withItem(TofaDiscoverItem item) {
    final d = _detail;
    return TofaDiscoverDetail(
      item: item,
      requestsAvailable: d?.requestsAvailable ?? false,
      requestBlocked: d?.requestBlocked ?? false,
      requestStatus: item.requestStatus,
      is4kCapable: d?.is4kCapable ?? false,
      rights: d?.rights,
      youtubeTrailerId: d?.youtubeTrailerId,
      cast: d?.cast ?? const [],
    );
  }

  /// Whether Request is offered: requests on, not in the library, not yet
  /// requested or blocked, and a right other than `off` for the type.
  bool _canRequest({bool is4k = false}) {
    final d = _detail;
    final rights = _rights;
    if (d == null || rights == null || _item.inLibrary || d.requestBlocked) return false;
    if (!(d.requestsAvailable || rights.requestsAvailable)) return false;
    if (_item.requestStatus != null) return false;
    if (is4k && !d.is4kCapable) return false;
    return rights.accessFor(_item.type, is4k: is4k) != TofaRequestAccess.off;
  }

  List<({String id, IconData icon, String label, VoidCallback? onPressed})> _actions() {
    final trailer = _detail?.youtubeTrailerId;
    return [
      if (_item.inLibrary && _item.localMediaId != null)
        (id: 'open', icon: Symbols.play_arrow_rounded, label: t.tofaExtras.openInLibrary, onPressed: _openInLibrary),
      if (_canRequest())
        (
          id: 'request',
          icon: Symbols.playlist_add_rounded,
          label: _rights?.accessFor(_item.type) == TofaRequestAccess.auto
              ? t.tofaExtras.requestNow
              : t.tofaExtras.request,
          onPressed: _busy ? null : () => unawaited(_request()),
        ),
      if (_canRequest(is4k: true))
        (
          id: 'request4k',
          icon: Symbols.four_k_rounded,
          label: t.tofaExtras.request4k,
          onPressed: _busy ? null : () => unawaited(_request(is4k: true)),
        ),
      if (trailer != null)
        (
          id: 'trailer',
          icon: Symbols.movie_rounded,
          label: t.tofaExtras.trailer,
          onPressed: () =>
              unawaited(openYoutubeTrailer(context, RemoteTrailer(site: 'YouTube', key: trailer, kind: 'trailer'))),
        ),
      (
        id: 'seen',
        icon: _item.seen ? Symbols.visibility_off_rounded : Symbols.visibility_rounded,
        label: _item.seen ? t.tofaExtras.unmarkSeen : t.tofaExtras.markSeen,
        onPressed: _busy ? null : () => unawaited(_toggleSeen()),
      ),
      (
        id: 'notInterested',
        icon: _item.notInterested ? Symbols.thumb_up_rounded : Symbols.thumb_down_rounded,
        label: _item.notInterested ? t.tofaExtras.interestedAgain : t.tofaExtras.notInterested,
        onPressed: _busy ? null : () => unawaited(_toggleNotInterested()),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = _item;
    final poster = widget.client.discoverImageUrl(item);
    final display = item.inLibrary ? null : tofaRequestDisplay(item.requestStatus);
    final actions = _actions();
    return FocusedScrollScaffold(
      title: Text(item.title),
      slivers: [
        if (_loading)
          LoadingIndicatorBox.sliver
        else if (_failed)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ErrorStateWidget(
              message: t.tofaExtras.loadFailed,
              icon: Symbols.error_outline_rounded,
              onRetry: _load,
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                    child: OptimizedMediaImage.poster(
                      imagePath: poster.isEmpty ? null : poster,
                      width: 120,
                      height: 180,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.title, style: theme.textTheme.headlineSmall),
                        const SizedBox(height: 4),
                        Text(
                          [
                            siloRequestMediaTypeLabel(item.isShow ? 'series' : 'movie'),
                            if (item.year != null) '${item.year}',
                          ].join(' · '),
                          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        if (item.inLibrary) ...[
                          const SizedBox(height: 8),
                          Text(t.tofaExtras.inLibrary, style: theme.textTheme.labelLarge),
                        ] else if (display != null) ...[
                          const SizedBox(height: 8),
                          SiloRequestStatusPill(display: display),
                        ],
                        if (item.overview != null) ...[
                          const SizedBox(height: 12),
                          Text(item.overview!, style: theme.textTheme.bodyMedium),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < actions.length; i++)
                    FocusableButton(
                      focusNode: _node(actions[i].id),
                      autofocus: i == 0,
                      useBackgroundFocus: true,
                      onPressed: actions[i].onPressed,
                      onNavigateLeft: i > 0 ? _node(actions[i - 1].id).requestFocus : null,
                      onNavigateRight: i < actions.length - 1 ? _node(actions[i + 1].id).requestFocus : null,
                      child: FilledButton.tonalIcon(
                        onPressed: actions[i].onPressed,
                        icon: AppIcon(actions[i].icon, fill: 1),
                        label: Text(actions[i].label),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_detail?.cast.isNotEmpty ?? false) ...[
            tofaSectionHeader(context, t.tofaExtras.cast),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList.list(
                children: [
                  for (final member in _detail!.cast.take(30))
                    TofaNavRow(
                      title: member.name,
                      subtitle: member.role,
                      icon: Symbols.person_rounded,
                      onSelect: () => unawaited(
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                TofaPersonScreen(client: widget.client, personId: member.personId, name: member.name),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ],
    );
  }
}

/// A person on a Tofa server (`GET /discovery/people/{id}`): biography and
/// credits, each opening its Discover title.
class TofaPersonScreen extends StatefulWidget {
  const TofaPersonScreen({super.key, required this.client, required this.personId, required this.name});

  final TofaClient client;
  final int personId;
  final String name;

  @override
  State<TofaPersonScreen> createState() => _TofaPersonScreenState();
}

class _TofaPersonScreenState extends State<TofaPersonScreen> {
  TofaPersonPage? _page;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final page = await widget.client.discoverPerson(widget.personId, widget.name);
      if (mounted) setState(() => _page = page);
    } catch (e) {
      appLogger.d('[tofa] person page failed', error: e.runtimeType);
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return FocusedScrollScaffold(
      title: Text(page?.name ?? widget.name),
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
        else ...[
          if (page.biography != null)
            SliverToBoxAdapter(
              child: Padding(padding: const EdgeInsets.all(16), child: Text(page.biography!)),
            ),
          tofaSectionHeader(context, t.tofaExtras.credits),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.list(
              children: [
                for (var i = 0; i < page.credits.length; i++)
                  TofaTitleRow(client: widget.client, item: page.credits[i], autofocus: i == 0),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
