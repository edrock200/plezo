import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../media/media_item.dart';
import '../../media/media_server_client.dart';
import '../../services/media_controls_manager.dart';
import '../../services/silo/silo_audiobook.dart';
import '../../services/silo/silo_audiobook_player.dart';
import '../../services/silo/silo_client.dart';
import '../../utils/app_logger.dart';
import '../../utils/formatters.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/provider_extensions.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/optimized_media_image.dart';
import 'silo_audiobook_player_screen.dart';

/// A Silo audiobook's page (Silo Android `AudiobookDetailContent`, Siku
/// `AudioDetailScreen`): cover, authors and narrators, Play / Resume and
/// Start over, the chapters (each starts the book there) and the parts.
class SiloAudiobookScreen extends StatefulWidget {
  const SiloAudiobookScreen({super.key, required this.item, this.backendOverride, this.client});

  /// The book's card (a [MediaItem] of kind album, `raw['type'] == 'audiobook'`).
  final MediaItem item;

  /// Tests inject the server calls; the app uses the item's [SiloClient].
  final SiloAudiobookBackend? backendOverride;
  final MediaServerClient? client;

  @override
  State<SiloAudiobookScreen> createState() => _SiloAudiobookScreenState();
}

class _SiloAudiobookScreenState extends State<SiloAudiobookScreen> {
  SiloAudiobookBackend? _backend;
  MediaServerClient? _client;
  SiloAudiobookDetail? _detail;
  bool _loading = true;

  final _playFocus = FocusNode(debugLabel: 'audiobook_play');
  final _startOverFocus = FocusNode(debugLabel: 'audiobook_start_over');
  final _retryFocus = FocusNode(debugLabel: 'audiobook_retry');
  final List<FocusNode> _chapterFocus = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _playFocus.dispose();
    _startOverFocus.dispose();
    _retryFocus.dispose();
    for (final node in _chapterFocus) {
      node.dispose();
    }
    super.dispose();
  }

  SiloAudiobookBackend? _resolveBackend() {
    if (widget.backendOverride != null) return widget.backendOverride;
    final client = widget.client ?? context.getMediaClientForItemOrNull(widget.item);
    _client = client;
    return client is SiloClient ? client.audiobooks : null;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
    });
    final backend = _backend ??= _resolveBackend();
    try {
      if (backend == null) throw StateError('No Silo client for ${widget.item.serverId}');
      final detail = await backend.fetchAudiobook(widget.item.id);
      if (!mounted) return;
      _syncChapterNodes(detail.timeline?.chapters.length ?? 0);
      setState(() {
        _detail = detail;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && detail.timeline != null) _playFocus.requestFocus();
      });
    } catch (error, stackTrace) {
      appLogger.w('Failed to load Silo audiobook', error: error, stackTrace: stackTrace);
      if (!mounted) return;
      setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _retryFocus.requestFocus();
      });
    }
  }

  void _syncChapterNodes(int count) {
    while (_chapterFocus.length > count) {
      _chapterFocus.removeLast().dispose();
    }
    while (_chapterFocus.length < count) {
      _chapterFocus.add(FocusNode(debugLabel: 'audiobook_chapter_${_chapterFocus.length}'));
    }
  }

  Future<void> _open({double? atSeconds}) async {
    final detail = _detail;
    final backend = _backend;
    if (detail == null || backend == null || detail.timeline == null) return;
    final player = SiloAudiobookPlayer(
      backend: backend,
      detail: detail,
      mediaItem: widget.item,
      client: _client,
      engineFactory: MpvSiloAudiobookEngine.new,
      mediaControlsFactory: MediaControlsManager.new,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SiloAudiobookPlayerScreen(player: player, startAtSeconds: atSeconds),
      ),
    );
    // The player wrote the position: read the book again for Resume.
    if (mounted) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(widget.item.displayTitle)),
      body: _loading && detail == null
          ? const Center(child: CircularProgressIndicator())
          : detail == null
          ? _buildError(context)
          : _buildBody(context, detail),
    );
  }

  Widget _buildError(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t.siloAudio.loadFailed, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FocusableButton(
            focusNode: _retryFocus,
            autofocus: true,
            onPressed: () => unawaited(_load()),
            child: FilledButton(onPressed: () => unawaited(_load()), child: Text(t.siloAudio.retry)),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, SiloAudiobookDetail detail) {
    final theme = Theme.of(context);
    final timeline = detail.timeline;
    final resume = detail.resumeSeconds;
    final chapters = timeline?.chapters ?? const <SiloAudiobookChapter>[];
    final meta = <String>[
      if (detail.year != null) '${detail.year}',
      if (detail.totalSeconds > 0) formatDurationTextual((detail.totalSeconds * 1000).round()),
    ];
    final hasStartOver = resume > 0;

    void focusFirstChapter() {
      if (_chapterFocus.isNotEmpty) _chapterFocus.first.requestFocus();
    }

    final playLabel = resume > 0
        ? t.siloAudio.resumeAt(time: formatDurationTimestamp(Duration(seconds: resume.round())))
        : (detail.played ? t.siloAudio.listenAgain : t.siloAudio.play);

    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: OptimizedMediaImage(
        client: _client,
        imagePath: widget.item.thumbPath,
        imageType: ImageType.square,
        width: 200,
        height: 200,
        fallbackIcon: Symbols.headphones_rounded,
      ),
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(detail.title, style: theme.textTheme.headlineSmall),
        if (detail.authors.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(t.siloAudio.byAuthors(names: detail.authors.join(', ')), style: theme.textTheme.titleMedium),
        ],
        if (detail.narrators.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(t.siloAudio.narratedBy(names: detail.narrators.join(', '))),
        ],
        if (detail.seriesName != null) ...[
          const SizedBox(height: 2),
          Text(t.siloAudio.series(name: detail.seriesName!)),
        ],
        if (meta.isNotEmpty) ...[const SizedBox(height: 4), Text(toBulletedString(meta))],
        if (resume > 0 && detail.totalSeconds > 0) ...[
          const SizedBox(height: 8),
          SizedBox(width: 240, child: LinearProgressIndicator(value: (resume / detail.totalSeconds).clamp(0.0, 1.0))),
          const SizedBox(height: 4),
          Text(t.siloAudio.timeLeft(time: formatDurationTextual(((detail.totalSeconds - resume) * 1000).round()))),
        ],
        const SizedBox(height: 16),
        if (timeline == null)
          Text(t.siloAudio.noAudio)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FocusableButton(
                focusNode: _playFocus,
                autofocus: true,
                onPressed: () => unawaited(_open(atSeconds: resume)),
                onNavigateRight: hasStartOver ? _startOverFocus.requestFocus : null,
                onNavigateDown: focusFirstChapter,
                child: FilledButton.icon(
                  onPressed: () => unawaited(_open(atSeconds: resume)),
                  icon: const AppIcon(Symbols.play_arrow_rounded, fill: 1),
                  label: Text(playLabel),
                ),
              ),
              if (hasStartOver)
                FocusableButton(
                  focusNode: _startOverFocus,
                  onPressed: () => unawaited(_open(atSeconds: 0)),
                  onNavigateLeft: _playFocus.requestFocus,
                  onNavigateDown: focusFirstChapter,
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(_open(atSeconds: 0)),
                    icon: const AppIcon(Symbols.replay_rounded, fill: 1),
                    label: Text(t.siloAudio.startOver),
                  ),
                ),
            ],
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 600;
        final current = timeline?.chapterIndexAt(resume) ?? -1;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  cover,
                  const SizedBox(width: 24),
                  Expanded(child: info),
                ],
              )
            else ...[
              Center(child: cover),
              const SizedBox(height: 16),
              info,
            ],
            if (detail.overview != null && detail.overview!.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(detail.overview!, style: theme.textTheme.bodyMedium),
            ],
            if (timeline != null && !timeline.isSinglePart) ...[
              const SizedBox(height: 24),
              Text(t.siloAudio.parts, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                toBulletedString([
                  for (final part in timeline.parts)
                    '${t.siloAudio.partNumber(n: part.index + 1)} '
                        '(${formatDurationTimestamp(Duration(seconds: part.durationSeconds.round()))})',
                ]),
              ),
            ],
            if (chapters.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(t.siloAudio.chapters, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              for (var i = 0; i < chapters.length; i++)
                _ChapterRow(
                  chapter: chapters[i],
                  focusNode: _chapterFocus[i],
                  current: i == current && resume > 0,
                  onSelect: () => unawaited(_open(atSeconds: chapters[i].startSeconds)),
                  onNavigateUp: i == 0 ? _playFocus.requestFocus : _chapterFocus[i - 1].requestFocus,
                  onNavigateDown: i + 1 < chapters.length ? _chapterFocus[i + 1].requestFocus : null,
                ),
            ],
          ],
        );
      },
    );
  }
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.chapter,
    required this.focusNode,
    required this.current,
    required this.onSelect,
    required this.onNavigateUp,
    this.onNavigateDown,
  });

  final SiloAudiobookChapter chapter;
  final FocusNode focusNode;
  final bool current;
  final VoidCallback onSelect;
  final VoidCallback onNavigateUp;
  final VoidCallback? onNavigateDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final length = Duration(seconds: (chapter.endSeconds - chapter.startSeconds).round());
    return FocusableWrapper(
      focusNode: focusNode,
      onSelect: onSelect,
      onNavigateUp: onNavigateUp,
      onNavigateDown: onNavigateDown,
      borderRadius: 8,
      child: ListTile(
        onTap: onSelect,
        leading: current
            ? AppIcon(Symbols.graphic_eq_rounded, fill: 1, color: theme.colorScheme.primary)
            : Text('${chapter.index + 1}', style: theme.textTheme.bodyMedium),
        title: Text(chapter.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Text(formatDurationTimestamp(length)),
      ),
    );
  }
}
