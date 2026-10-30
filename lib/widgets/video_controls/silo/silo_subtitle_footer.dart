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

/// The subtitle sheet's Silo rows: "Search subtitles" always, "Translate with
/// AI" when the server has AI subtitles on (read once per client).
class SiloSubtitleFooterTiles extends StatefulWidget {
  const SiloSubtitleFooterTiles({super.key, required this.tools});

  final SiloSubtitleTools tools;

  @override
  State<SiloSubtitleFooterTiles> createState() => _SiloSubtitleFooterTilesState();
}

class _SiloSubtitleFooterTilesState extends State<SiloSubtitleFooterTiles> {
  SiloAiStatus? _status;

  @override
  void initState() {
    super.initState();
    _status = widget.tools.client.cachedAiStatus;
    if (_status == null) {
      widget.tools.client.aiStatus().then((status) {
        if (mounted) setState(() => _status = status);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tools = widget.tools;
    final ai = SiloAiSubtitleController.of(tools);
    return ListenableBuilder(
      listenable: ai,
      builder: (context, _) {
        final running = ai.phase == SiloAiPhase.running;
        final percent = ((ai.job?.progress ?? 0) * 100).round().clamp(0, 100);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FocusableListTile(
              leading: const AppIcon(Symbols.search_rounded),
              title: Text(t.videoControls.searchSubtitles),
              onTap: () =>
                  OverlaySheetController.of(context).push(builder: (_) => SiloSubtitleSearchSheet(tools: tools)),
            ),
            if (_status?.available ?? false)
              FocusableListTile(
                leading: const AppIcon(Symbols.translate_rounded),
                title: Text(t.videoControls.siloSubtitles.translateWithAi),
                subtitle: running ? Text(t.videoControls.siloSubtitles.progress(percent: percent)) : null,
                onTap: () => OverlaySheetController.of(context).push(builder: (_) => SiloAiSubtitleSheet(tools: tools)),
              ),
          ],
        );
      },
    );
  }
}
