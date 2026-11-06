import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_wrapper.dart';
import '../../i18n/strings.g.dart';
import '../../services/silo/silo_audiobook_player.dart';
import '../../utils/formatters.dart';
import '../../utils/media_image_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/optimized_media_image.dart';

/// Full-screen audiobook player (Silo's `AudiobookPlayerScreen` /
/// `TvAudiobookPlayerScreen`): cover, title, chapter, whole-book progress,
/// chapter and 30-second skips, speed and the chapter list. Leaving the
/// screen stops playback and saves the position.
class SiloAudiobookPlayerScreen extends StatefulWidget {
  const SiloAudiobookPlayerScreen({super.key, required this.player, this.startAtSeconds, this.autoStart = true});

  /// Owned by this screen: closed and disposed when it goes.
  final SiloAudiobookPlayer player;
  final double? startAtSeconds;
  final bool autoStart;

  static const skipSeconds = 30;

  @override
  State<SiloAudiobookPlayerScreen> createState() => _SiloAudiobookPlayerScreenState();
}

class _SiloAudiobookPlayerScreenState extends State<SiloAudiobookPlayerScreen> {
  SiloAudiobookPlayer get _player => widget.player;

  final _prevChapter = FocusNode(debugLabel: 'ab_prev_chapter');
  final _back = FocusNode(debugLabel: 'ab_back30');
  final _playPause = FocusNode(debugLabel: 'ab_play');
  final _forward = FocusNode(debugLabel: 'ab_fwd30');
  final _nextChapter = FocusNode(debugLabel: 'ab_next_chapter');
  final _speed = FocusNode(debugLabel: 'ab_speed');
  final _chapters = FocusNode(debugLabel: 'ab_chapters');
  final _retry = FocusNode(debugLabel: 'ab_retry');

  /// A drag on the progress bar, in book seconds, until it is released.
  double? _scrub;

  @override
  void initState() {
    super.initState();
    _player.addListener(_onChanged);
    if (widget.autoStart) unawaited(_player.start(atSeconds: widget.startAtSeconds));
  }

  @override
  void dispose() {
    _player.removeListener(_onChanged);
    _player.dispose();
    for (final node in [_prevChapter, _back, _playPause, _forward, _nextChapter, _speed, _chapters, _retry]) {
      node.dispose();
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _cycleSpeed() {
    const speeds = SiloAudiobookPlayer.speeds;
    final index = speeds.indexWhere((s) => (s - _player.speed).abs() < 0.001);
    unawaited(_player.setSpeed(speeds[(index + 1) % speeds.length]));
  }

  Future<void> _showChapters() async {
    final chapters = _player.timeline.chapters;
    if (chapters.isEmpty) return;
    final current = _player.chapterIndex;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: chapters.length,
            itemBuilder: (context, i) {
              final chapter = chapters[i];
              void select() {
                Navigator.of(sheetContext).pop();
                unawaited(_player.jumpToChapter(i));
              }

              return FocusableWrapper(
                autofocus: i == (current < 0 ? 0 : current),
                onSelect: select,
                borderRadius: 8,
                child: ListTile(
                  selected: i == current,
                  onTap: select,
                  leading: Text('${i + 1}'),
                  title: Text(chapter.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Text(formatDurationTimestamp(Duration(seconds: chapter.startSeconds.round()))),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _transportButton({
    required FocusNode node,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    FocusNode? left,
    FocusNode? right,
    bool large = false,
    bool autofocus = false,
  }) {
    return FocusableButton(
      focusNode: node,
      autofocus: autofocus,
      onPressed: onPressed,
      onNavigateLeft: left?.requestFocus,
      onNavigateRight: right?.requestFocus,
      onNavigateDown: _speed.requestFocus,
      onNavigateUp: _player.canRetry ? _retry.requestFocus : null,
      child: IconButton(
        tooltip: label,
        iconSize: large ? 56 : 32,
        onPressed: onPressed,
        icon: AppIcon(icon, fill: 1, semanticLabel: label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _player.detail;
    final timeline = _player.timeline;
    final chapter = _player.currentChapter;
    final hasChapters = timeline.chapters.length > 1;
    final playing = _player.isPlaying;
    final error = _player.error;

    return Scaffold(
      appBar: AppBar(title: Text(detail.title)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: OptimizedMediaImage(
                      client: _player.client,
                      imagePath: _player.mediaItem?.thumbPath ?? detail.coverUrl,
                      imageType: ImageType.square,
                      width: 260,
                      height: 260,
                      fallbackIcon: Symbols.headphones_rounded,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(detail.title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
                  if (detail.authors.isNotEmpty)
                    Text(detail.authors.join(', '), style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
                  if (chapter != null) ...[
                    const SizedBox(height: 8),
                    Text(chapter.title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (hasChapters)
                      Text(
                        t.siloAudio.chapterOf(n: chapter.index + 1, total: timeline.chapters.length),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                  const SizedBox(height: 16),
                  ValueListenableBuilder<double>(
                    valueListenable: _player.position,
                    builder: (context, seconds, _) {
                      final total = timeline.totalSeconds;
                      final shown = _scrub ?? seconds;
                      return Column(
                        children: [
                          Slider(
                            value: total <= 0 ? 0 : shown.clamp(0, total),
                            max: total <= 0 ? 1 : total,
                            onChanged: total <= 0 ? null : (v) => setState(() => _scrub = v),
                            onChangeEnd: total <= 0
                                ? null
                                : (v) {
                                    setState(() => _scrub = null);
                                    unawaited(_player.seekTo(v));
                                  },
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(formatDurationTimestamp(Duration(seconds: shown.round()))),
                              Text(
                                '-${formatDurationTimestamp(Duration(seconds: (total - shown).clamp(0, total).round()))}',
                              ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                  if (error != null || _player.isFinished) ...[
                    const SizedBox(height: 8),
                    Text(
                      error ?? t.siloAudio.finished,
                      textAlign: TextAlign.center,
                      style: error == null ? null : TextStyle(color: theme.colorScheme.error),
                    ),
                    if (_player.canRetry) ...[
                      const SizedBox(height: 8),
                      FocusableButton(
                        focusNode: _retry,
                        onPressed: () => unawaited(_player.play()),
                        onNavigateDown: _playPause.requestFocus,
                        child: OutlinedButton(
                          onPressed: () => unawaited(_player.play()),
                          child: Text(t.siloAudio.retry),
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _transportButton(
                        node: _prevChapter,
                        icon: Symbols.skip_previous_rounded,
                        label: t.siloAudio.previousChapter,
                        onPressed: hasChapters ? () => unawaited(_player.previousChapter()) : null,
                        right: _back,
                      ),
                      _transportButton(
                        node: _back,
                        icon: Symbols.replay_30_rounded,
                        label: t.siloAudio.skipBack(n: SiloAudiobookPlayerScreen.skipSeconds),
                        onPressed: () => unawaited(_player.skip(-SiloAudiobookPlayerScreen.skipSeconds.toDouble())),
                        left: hasChapters ? _prevChapter : null,
                        right: _playPause,
                      ),
                      if (_player.isLoading)
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: SizedBox(width: 48, height: 48, child: CircularProgressIndicator()),
                        )
                      else
                        _transportButton(
                          node: _playPause,
                          autofocus: true,
                          large: true,
                          icon: playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded,
                          label: t.siloAudio.playPause,
                          onPressed: _player.endedByServer ? null : () => unawaited(_player.togglePlay()),
                          left: _back,
                          right: _forward,
                        ),
                      _transportButton(
                        node: _forward,
                        icon: Symbols.forward_30_rounded,
                        label: t.siloAudio.skipForward(n: SiloAudiobookPlayerScreen.skipSeconds),
                        onPressed: () => unawaited(_player.skip(SiloAudiobookPlayerScreen.skipSeconds.toDouble())),
                        left: _playPause,
                        right: hasChapters ? _nextChapter : null,
                      ),
                      _transportButton(
                        node: _nextChapter,
                        icon: Symbols.skip_next_rounded,
                        label: t.siloAudio.nextChapter,
                        onPressed: hasChapters ? () => unawaited(_player.nextChapter()) : null,
                        left: _forward,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FocusableButton(
                        focusNode: _speed,
                        onPressed: _cycleSpeed,
                        onNavigateUp: _playPause.requestFocus,
                        onNavigateRight: timeline.chapters.isNotEmpty ? _chapters.requestFocus : null,
                        child: TextButton.icon(
                          onPressed: _cycleSpeed,
                          icon: const AppIcon(Symbols.speed_rounded, fill: 1),
                          label: Text('${t.siloAudio.speed} ${formatPlaybackRate(_player.speed)}'),
                        ),
                      ),
                      if (timeline.chapters.isNotEmpty)
                        FocusableButton(
                          focusNode: _chapters,
                          onPressed: () => unawaited(_showChapters()),
                          onNavigateUp: _playPause.requestFocus,
                          onNavigateLeft: _speed.requestFocus,
                          child: TextButton.icon(
                            onPressed: () => unawaited(_showChapters()),
                            icon: const AppIcon(Symbols.list_rounded, fill: 1),
                            label: Text(t.siloAudio.chapters),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
