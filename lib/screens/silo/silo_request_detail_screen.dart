import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../services/silo/silo_client.dart';
import '../../services/silo/silo_requests.dart';
import '../../utils/app_logger.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/optimized_media_image.dart';
import '../libraries/state_messages.dart';
import 'silo_request_widgets.dart';

/// A title from Silo's request provider: what it is, whether it is in the
/// library or requested, and the actions the viewer has (Request, Cancel
/// request, Remove request on a failed one, Open in library). Port of Silo's `TvRequestDetailScreen` /
/// `RequestDetailViewModel` without the season picker and following: a series
/// request names no seasons, so the server requests every aired season the
/// library does not have complete.
class SiloRequestDetailScreen extends StatefulWidget {
  const SiloRequestDetailScreen({
    super.key,
    required this.client,
    required this.mediaType,
    required this.tmdbId,
    this.initialTitle,
    this.initialPosterPath,
  });

  final SiloClient client;
  final String mediaType;
  final int tmdbId;
  final String? initialTitle;
  final String? initialPosterPath;

  @override
  State<SiloRequestDetailScreen> createState() => _SiloRequestDetailScreenState();
}

class _SiloRequestDetailScreenState extends State<SiloRequestDetailScreen> {
  SiloRequestMediaDetail? _detail;
  SiloMediaRequest? _ownRecord;
  bool _loading = true;
  bool _loadFailed = false;
  bool _busy = false;

  /// A create or cancel went out without a usable answer: its button stays
  /// hidden until a fresh read shows what happened (never resent).
  bool _held = false;
  String? _message;

  final _primaryFocus = FocusNode(debugLabel: 'SiloRequestPrimary');
  final _secondaryFocus = FocusNode(debugLabel: 'SiloRequestSecondary');

  SiloRequestsApi get _requests => widget.client.requests;

  StreamSubscription<SiloMediaRequest>? _removals;

  @override
  void initState() {
    super.initState();
    _requests.removeFailedSupported.addListener(_onCapabilityChanged);
    _removals = _requests.removals.listen(_onRemoved);
    unawaited(_load());
  }

  @override
  void dispose() {
    _requests.removeFailedSupported.removeListener(_onCapabilityChanged);
    unawaited(_removals?.cancel());
    _primaryFocus.dispose();
    _secondaryFocus.dispose();
    super.dispose();
  }

  void _onCapabilityChanged() {
    if (mounted) setState(() {});
  }

  /// A removal of this title's request, here or on another page: requestable again.
  void _onRemoved(SiloMediaRequest record) {
    final detail = _detail;
    if (!mounted || detail == null || record.mediaType != widget.mediaType || record.tmdbId != widget.tmdbId) return;
    setState(() {
      _detail = detail.withoutRecord(record);
      if (_ownRecord?.id == record.id) _ownRecord = null;
    });
  }

  Future<void> _load() async {
    // Remove is offered only where the server takes it.
    unawaited(_requests.refreshStatus());
    setState(() {
      _loading = _detail == null;
      _loadFailed = false;
    });
    try {
      final results = await Future.wait([
        _requests.detail(widget.mediaType, widget.tmdbId),
        _requests.mine().then<List<SiloMediaRequest>?>((r) => r).catchError((Object e) {
          appLogger.d('Silo requests: own requests unavailable', error: e.runtimeType);
          return null;
        }),
      ]);
      if (!mounted) return;
      final mine = results[1] as List<SiloMediaRequest>?;
      setState(() {
        _detail = results[0] as SiloRequestMediaDetail;
        if (mine != null) _ownRecord = siloCurrentRequestFor(mine, widget.mediaType, widget.tmdbId);
        _held = false;
        _loading = false;
      });
    } catch (e) {
      appLogger.d('Silo requests: detail failed', error: e.runtimeType);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = _detail == null;
      });
    }
  }

  Future<void> _submit() async {
    final detail = _detail;
    if (detail == null || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final record = await _requests.create(detail);
      if (!mounted) return;
      setState(() {
        _detail = detail.withRecord(record);
        _ownRecord = record;
      });
      showSuccessSnackBar(context, t.siloRequests.requested);
    } on SiloRequestFailure catch (failure) {
      if (!mounted) return;
      _onFailure(failure, unconfirmed: t.siloRequests.unconfirmedSubmit, fallback: t.siloRequests.submitFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final record = _ownRecord;
    final detail = _detail;
    if (record == null || detail == null || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final updated = await _requests.cancel(record.id);
      if (!mounted) return;
      setState(() {
        _detail = detail.withRecord(updated);
        _ownRecord = updated;
      });
      showAppSnackBar(context, t.siloRequests.requestCancelled);
    } on SiloRequestFailure catch (failure) {
      if (!mounted) return;
      _onFailure(failure, unconfirmed: t.siloRequests.unconfirmedCancel, fallback: t.siloRequests.cancelFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Removes the viewer's failed request after a confirmation naming the
  /// title (Silo Android #792). Sent once; an uncertain answer re-reads the
  /// title and holds nothing (a resend of a removal that landed answers 404).
  Future<void> _remove() async {
    final record = _ownRecord;
    if (record == null || _busy || !_requests.canRemove(record)) return;
    final hadFocus = _primaryFocus.hasFocus || _secondaryFocus.hasFocus;
    final confirmed = await confirmSiloRequestRemoval(context, _detail?.title ?? record.title);
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // The removals listener makes the title requestable again.
      await _requests.removeFailed(record);
      if (!mounted) return;
      showSuccessSnackBar(context, t.siloRequests.requestRemoved);
    } on SiloRequestFailure catch (failure) {
      if (!mounted) return;
      if (failure.kind == SiloRequestFailureKind.uncertain) {
        await _load();
        if (!mounted) return;
        if (_ownRecord?.id != record.id) {
          showSuccessSnackBar(context, t.siloRequests.requestRemoved);
        } else {
          setState(() => _message = t.siloRequests.unconfirmedRemove);
        }
      } else if (siloRemovalConflict(failure)) {
        setState(() => _message = t.siloRequests.removeConflict);
        unawaited(_load());
      } else {
        _onFailure(failure, unconfirmed: t.siloRequests.unconfirmedRemove, fallback: t.siloRequests.removeFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // The button that had focus may be gone: the first action takes it.
    if (hadFocus && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _primaryFocus.hasFocus || _secondaryFocus.hasFocus) return;
        if (_primaryFocus.context != null) _primaryFocus.requestFocus();
      });
    }
  }

  void _onFailure(SiloRequestFailure failure, {required String unconfirmed, required String fallback}) {
    setState(() {
      _message = siloRequestFailureText(failure, unconfirmed: unconfirmed, fallback: fallback);
      if (failure.kind == SiloRequestFailureKind.uncertain) _held = true;
    });
    if (failure.kind == SiloRequestFailureKind.disabled) {
      unawaited(_requests.refreshStatus(force: true));
    } else if (failure.kind == SiloRequestFailureKind.refused && failure.statusCode == 409) {
      // A conflict: the title was requested or arrived meanwhile.
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return FocusedScrollScaffold(
      title: Text(detail?.title ?? widget.initialTitle ?? t.siloRequests.title),
      slivers: [
        if (_loading)
          LoadingIndicatorBox.sliver
        else if (_loadFailed || detail == null)
          SliverFillRemaining(
            child: ErrorStateWidget(
              message: t.siloRequests.detailLoadFailed,
              icon: Symbols.error_outline_rounded,
              onRetry: _load,
              actionAutofocus: true,
            ),
          )
        else
          SliverToBoxAdapter(child: _buildBody(context, detail)),
      ],
    );
  }

  Widget _buildBody(BuildContext context, SiloRequestMediaDetail detail) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final display = detail.display;
    final meta = [
      siloRequestMediaTypeLabel(detail.mediaType),
      if (detail.year != null && detail.year! > 0) '${detail.year}',
      if (detail.runtime != null && detail.runtime! > 0) t.siloCardOverlays.runtimeMinutes(minutes: detail.runtime!),
      if (detail.numberOfSeasons != null && detail.numberOfSeasons! > 0)
        t.siloRequests.seasonCount(count: detail.numberOfSeasons!),
      if (detail.contentRating.isNotEmpty) detail.contentRating,
      if (detail.voteAverage != null && detail.voteAverage! > 0)
        t.siloRequests.tmdbRating(rating: detail.voteAverage!.toStringAsFixed(1)),
    ].join(' · ');

    final poster = ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: OptimizedMediaImage.poster(
        imagePath: siloRequestImageUrl(detail.posterPath ?? widget.initialPosterPath),
        width: 140,
        height: 210,
      ),
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(detail.title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
        if (detail.tagline.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(detail.tagline, style: theme.textTheme.bodyLarge?.copyWith(fontStyle: FontStyle.italic)),
        ],
        const SizedBox(height: 8),
        Text(meta, style: muted),
        if (detail.genres.isNotEmpty) ...[const SizedBox(height: 4), Text(detail.genres.join(', '), style: muted)],
        if (display != null) ...[
          const SizedBox(height: 12),
          Text(
            siloRequestDetailTitle(display),
            style: theme.textTheme.titleMedium?.copyWith(color: siloRequestTint(display, theme.colorScheme)),
          ),
        ],
        if (_ownRecord != null && _ownRecord!.display.kind == SiloRequestDisplayKind.onTheWay) ...[
          const SizedBox(height: 4),
          Text(siloRequestRecordStatus(_ownRecord!), style: muted),
        ],
        const SizedBox(height: 16),
        _buildActions(detail),
        if (_message != null) ...[
          const SizedBox(height: 12),
          Text(_message!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 520
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      poster,
                      const SizedBox(width: 24),
                      Expanded(child: info),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [poster, const SizedBox(height: 16), info],
                  ),
          ),
          if (detail.overview.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(detail.overview, style: theme.textTheme.bodyLarge),
          ],
          if (detail.director.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(t.siloRequests.directedBy(name: detail.director), style: muted),
          ],
          if (detail.cast.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(t.siloRequests.starring(names: detail.cast.take(6).join(', ')), style: muted),
          ],
        ],
      ),
    );
  }

  Widget _buildActions(SiloRequestMediaDetail detail) {
    final libraryId = detail.libraryContentId != null && detail.availability == 'available'
        ? detail.libraryContentId
        : detail.display?.libraryItemToOpen(detail.libraryContentId);
    final canRequest = detail.request.requestable && !_held;
    final record = _ownRecord;
    final canCancel = record != null && record.canCancel && !_held;
    final canRemove = record != null && _requests.canRemove(record);

    final buttons = <Widget>[];
    void add({required String label, required IconData icon, required VoidCallback? onPressed, bool tonal = false}) {
      final focus = buttons.isEmpty ? _primaryFocus : _secondaryFocus;
      final first = buttons.isEmpty;
      buttons.add(
        FocusableButton(
          focusNode: focus,
          autofocus: first,
          useBackgroundFocus: true,
          onPressed: onPressed,
          onNavigateRight: first ? () => _secondaryFocus.requestFocus() : null,
          onNavigateLeft: first ? null : () => _primaryFocus.requestFocus(),
          child: tonal
              ? FilledButton.tonalIcon(onPressed: onPressed, icon: AppIcon(icon, fill: 1), label: Text(label))
              : FilledButton.icon(onPressed: onPressed, icon: AppIcon(icon, fill: 1), label: Text(label)),
        ),
      );
    }

    if (libraryId != null) {
      add(
        label: t.siloRequests.openInLibrary,
        icon: Symbols.play_arrow_rounded,
        onPressed: () => unawaited(openSiloLibraryItem(context, widget.client, libraryId)),
      );
    }
    if (canRequest && buttons.length < 2) {
      add(label: t.siloRequests.request, icon: Symbols.add_rounded, onPressed: _submit);
    }
    if (canCancel && buttons.length < 2) {
      add(label: t.siloRequests.cancelRequest, icon: Symbols.close_rounded, onPressed: _cancel, tonal: true);
    }
    if (canRemove && buttons.length < 2) {
      add(label: t.siloRequests.removeRequest, icon: Symbols.delete_rounded, onPressed: _remove, tonal: true);
    }
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 12, runSpacing: 12, children: buttons);
  }
}
