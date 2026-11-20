import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/silo/silo_subtitles.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import '../models/silo_subtitle_tools.dart';
import 'silo_ai_subtitle_controller.dart';
import 'silo_ai_subtitle_sheet.dart';
import 'silo_subtitle_search_sheet.dart';

/// The subtitle sheet's Silo rows: "Search subtitles" while the server can
/// search a subtitle provider (re-read each time the sheet opens, Silo Android
/// #608), "Translate with AI" when the server has AI subtitles on (read once
/// per client). Built only for online playback, so downloads never probe.
class SiloSubtitleFooterTiles extends StatefulWidget {
  const SiloSubtitleFooterTiles({super.key, required this.tools});

  final SiloSubtitleTools tools;

  @override
  State<SiloSubtitleFooterTiles> createState() => _SiloSubtitleFooterTilesState();
}

class _SiloSubtitleFooterTilesState extends State<SiloSubtitleFooterTiles> {
  SiloAiStatus? _status;
  final _searchFocus = FocusNode(debugLabel: 'SiloSubtitleSearch');
  final _aiFocus = FocusNode(debugLabel: 'SiloSubtitleTranslate');
  late final SiloSubtitleSearchGate _gate = widget.tools.client.subtitleSearchGate;

  @override
  void initState() {
    super.initState();
    _gate.addListener(_onGateChanged);
    unawaited(_gate.refresh());
    _status = widget.tools.client.cachedAiStatus;
    if (_status == null) {
      widget.tools.client.aiStatus().then((status) {
        if (mounted) setState(() => _status = status);
      });
    }
  }

  /// A D-pad user focused on "Search subtitles" when it hides keeps focus in
  /// the sheet: on "Translate with AI", else the row above.
  void _onGateChanged() {
    if (_gate.offered || !_searchFocus.hasFocus) return;
    if (_status?.available ?? false) {
      _aiFocus.requestFocus();
    } else {
      _searchFocus.previousFocus();
    }
  }

  @override
  void dispose() {
    _gate.removeListener(_onGateChanged);
    _searchFocus.dispose();
    _aiFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tools = widget.tools;
    final ai = SiloAiSubtitleController.of(tools);
    return ListenableBuilder(
      listenable: Listenable.merge([ai, _gate]),
      builder: (context, _) {
        final running = ai.phase == SiloAiPhase.running;
        final percent = ((ai.job?.progress ?? 0) * 100).round().clamp(0, 100);
        final showAi = _status?.available ?? false;
        if (!_gate.offered && !showAi) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Divider(height: 1, color: Theme.of(context).dividerColor),
            if (_gate.offered)
              FocusableListTile(
                focusNode: _searchFocus,
                leading: const AppIcon(Symbols.search_rounded),
                title: Text(t.videoControls.searchSubtitles),
                onTap: () =>
                    OverlaySheetController.of(context).push(builder: (_) => SiloSubtitleSearchSheet(tools: tools)),
              ),
            if (showAi)
              FocusableListTile(
                focusNode: _aiFocus,
                leading: const AppIcon(Symbols.translate_rounded),
                title: Text(t.videoControls.siloSubtitles.translateWithAi),
                subtitle: running ? Text(ai.progressLabel(percent)) : null,
                onTap: () => OverlaySheetController.of(context).push(builder: (_) => SiloAiSubtitleSheet(tools: tools)),
              ),
          ],
        );
      },
    );
  }
}
