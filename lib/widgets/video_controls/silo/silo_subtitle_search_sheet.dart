import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_button.dart';
import '../../../i18n/strings.g.dart';
import '../../../services/settings_service.dart';
import '../../../services/silo/silo_client.dart';
import '../../../services/silo/silo_subtitles.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/language_codes.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import '../../../widgets/pill_input_decoration.dart';
import '../../loading_indicator_box.dart';
import '../models/silo_subtitle_tools.dart';
import '../models/track_controls_state.dart';
import '../sheets/base_video_control_sheet.dart';
import '../sheets/subtitle_search_sheet.dart';

/// "Search subtitles" for a Silo item (Silo's TvSubtitleSearchDialog): the
/// server asks its subtitle providers for the playing file, stores the chosen
/// hit, and the player reloads to show it.
class SiloSubtitleSearchSheet extends StatefulWidget {
  const SiloSubtitleSearchSheet({super.key, required this.tools});

  final SiloSubtitleTools tools;

  @override
  State<SiloSubtitleSearchSheet> createState() => _SiloSubtitleSearchSheetState();
}

class _SiloSubtitleSearchSheetState extends State<SiloSubtitleSearchSheet> {
  final _languageFocusNode = FocusNode(debugLabel: 'SiloSubtitleSearch_language');
  final _firstResultFocusNode = FocusNode(debugLabel: 'SiloSubtitleSearch_firstResult');

  String _languageCode = 'en';
  String _languageName = 'English';
  SiloSubtitleSearchResults? _results;
  bool _searching = false;
  String? _error;
  String? _downloadingKey;
  int _generation = 0;
  bool _showLanguagePicker = false;

  String? get _fileId => widget.tools.client.aiPlaybackContext(widget.tools.itemId)?.fileId;

  @override
  void initState() {
    super.initState();
    final code = resolveSubtitleSearchLanguageCode(
      savedLanguageCode: SettingsService.instanceOrNull?.read(SettingsService.subtitleSearchLanguage),
      systemLocale: WidgetsBinding.instance.platformDispatcher.locale,
    );
    final name = LanguageCodes.getLanguageName(code);
    if (name != null) {
      _languageCode = code;
      _languageName = name;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    ++_generation;
    _languageFocusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final fileId = _fileId;
    if (!mounted || fileId == null) return;
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await widget.tools.client.searchServerSubtitles(fileId: fileId, languages: [_languageCode]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      appLogger.d('Silo subtitle search failed', error: e.runtimeType);
      setState(() {
        _error = (e is SiloSubtitleException ? e.message : null) ?? t.videoControls.siloSubtitles.searchFailed;
        _searching = false;
      });
    }
  }

  Future<void> _download(SiloSubtitleSearchHit hit) async {
    final fileId = _fileId;
    if (_downloadingKey != null || fileId == null) return;
    setState(() => _downloadingKey = hit.key);
    try {
      final storedId = await widget.tools.client.downloadServerSubtitle(fileId: fileId, hit: hit);
      final outcome = await widget.tools.applyStored(storedId);
      if (!mounted) return;
      if (outcome == SubtitleDownloadApplyOutcome.applied) {
        showSuccessSnackBar(context, t.videoControls.subtitleDownloaded);
        OverlaySheetController.of(context).close();
      } else {
        showErrorSnackBar(context, t.videoControls.subtitleDownloadedNotApplied);
        setState(() => _downloadingKey = null);
      }
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(
        context,
        (e is SiloSubtitleException ? e.message : null) ?? t.videoControls.subtitleDownloadFailed,
      );
      setState(() => _downloadingKey = null);
    }
  }

  void _openLanguagePicker() {
    setState(() => _showLanguagePicker = true);
    OverlaySheetController.of(context).refocus();
  }

  void _closeLanguagePicker() {
    setState(() => _showLanguagePicker = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _languageFocusNode.requestFocus();
    });
  }

  void _onLanguageSelected(String code, String name) {
    setState(() {
      _languageCode = code;
      _languageName = name;
      _showLanguagePicker = false;
    });
    final settings = SettingsService.instanceOrNull;
    if (settings != null) unawaited(settings.write(SettingsService.subtitleSearchLanguage, code));
    OverlaySheetController.of(context).refocus();
    _search();
  }

  bool get _hasResults => (_results?.hits.isNotEmpty ?? false) && !_searching && _error == null;

  @override
  Widget build(BuildContext context) {
    if (_showLanguagePicker) {
      return SubtitleLanguagePickerView(
        currentCode: _languageCode,
        onSelected: _onLanguageSelected,
        onBack: _closeLanguagePicker,
      );
    }
    final fillColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    return BaseVideoControlSheet(
      title: t.videoControls.searchSubtitles,
      icon: Symbols.search_rounded,
      onBack: () => OverlaySheetController.of(context).pop(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FocusableButton(
                focusNode: _languageFocusNode,
                autofocus: true,
                onPressed: _openLanguagePicker,
                onNavigateDown: _hasResults ? _firstResultFocusNode.requestFocus : null,
                autoScroll: false,
                child: Material(
                  color: fillColor,
                  borderRadius: pillInputRadius,
                  child: InkWell(
                    borderRadius: pillInputRadius,
                    canRequestFocus: false,
                    onTap: _openLanguagePicker,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        mainAxisSize: .min,
                        children: [
                          Text(_languageName),
                          const SizedBox(width: 2),
                          const AppIcon(Symbols.arrow_drop_down_rounded, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    final colorScheme = Theme.of(context).colorScheme;
    if (_searching) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: TextStyle(color: colorScheme.error)),
        ),
      );
    }
    final results = _results;
    if (results == null) return const SizedBox.shrink();
    final warnings = results.warnings;
    if (results.hits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            [t.videoControls.noSubtitlesFound, ...warnings].join('\n'),
            textAlign: TextAlign.center,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: results.hits.length + (warnings.isEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == results.hits.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(warnings.join('\n'), style: TextStyle(color: colorScheme.onSurfaceVariant)),
          );
        }
        final hit = results.hits[index];
        final downloading = _downloadingKey == hit.key;
        final details = [
          hit.provider,
          LanguageCodes.getLanguageName(hit.language) ?? hit.language,
          if (hit.format != null && hit.format!.isNotEmpty) hit.format!.toUpperCase(),
          if (hit.hearingImpaired) t.videoControls.siloSubtitles.hearingImpaired,
        ].where((part) => part.isNotEmpty).join(' · ');
        return FocusableListTile(
          focusNode: index == 0 ? _firstResultFocusNode : null,
          title: Text(hit.releaseName.isEmpty ? t.common.unknown : hit.releaseName, maxLines: 2, overflow: .ellipsis),
          subtitle: Text(
            details,
            maxLines: 1,
            overflow: .ellipsis,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          trailing: downloading
              ? const LoadingIndicatorBox(size: 20)
              : hit.score == null
              ? null
              : Text(
                  hit.score!.round().toString(),
                  style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                ),
          onTap: downloading || _downloadingKey != null ? null : () => _download(hit),
        );
      },
    );
  }
}
