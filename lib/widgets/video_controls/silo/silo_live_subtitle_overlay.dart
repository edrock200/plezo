import 'dart:async';

import 'package:flutter/material.dart';

import 'silo_ai_subtitle_controller.dart';

/// Draws the live AI cues of a running "Translate with AI" job over the video,
/// where the player's own subtitles would be, while the server is still
/// translating (the player's subtitle is hidden meanwhile). The stored track
/// replaces it when the job completes.
class SiloLiveSubtitleOverlay extends StatefulWidget {
  const SiloLiveSubtitleOverlay({
    super.key,
    required this.controller,
    required this.positions,
    required this.position,
    required this.visible,
    required this.controlsShown,
  });

  final SiloAiSubtitleController controller;

  /// The player's position stream and its current value.
  final Stream<Duration> positions;
  final Duration Function() position;

  /// The user's subtitle visibility toggle.
  final bool visible;

  /// Lifts the lines above the controls while they are shown.
  final bool controlsShown;

  @override
  State<SiloLiveSubtitleOverlay> createState() => _SiloLiveSubtitleOverlayState();
}

class _SiloLiveSubtitleOverlayState extends State<SiloLiveSubtitleOverlay> {
  StreamSubscription<Duration>? _positionSub;
  String? _text;

  @override
  void initState() {
    super.initState();
    widget.controller.liveRevision.addListener(_refresh);
    _subscribe();
    _refresh();
  }

  @override
  void didUpdateWidget(SiloLiveSubtitleOverlay old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.liveRevision.removeListener(_refresh);
      widget.controller.liveRevision.addListener(_refresh);
    }
    if (old.positions != widget.positions) _subscribe();
    _refresh();
  }

  void _subscribe() {
    unawaited(_positionSub?.cancel());
    _positionSub = widget.positions.listen((_) => _refresh());
  }

  void _refresh() {
    final next = widget.controller.liveTextAt(widget.position());
    if (next != _text && mounted) setState(() => _text = next);
  }

  @override
  void dispose() {
    widget.controller.liveRevision.removeListener(_refresh);
    unawaited(_positionSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (!widget.visible || text == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight.isFinite ? constraints.maxHeight : MediaQuery.sizeOf(context).height;
        final fontSize = (height * 0.045).clamp(16.0, 52.0);
        return AnimatedPadding(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.only(bottom: height * (widget.controlsShown ? 0.2 : 0.07)),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              widthFactor: 0.85,
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                  shadows: const [
                    Shadow(blurRadius: 3, color: Colors.black),
                    Shadow(offset: Offset(1.5, 1.5), blurRadius: 2, color: Colors.black),
                    Shadow(offset: Offset(-1, -1), blurRadius: 2, color: Colors.black87),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
