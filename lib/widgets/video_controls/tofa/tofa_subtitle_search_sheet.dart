import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_button.dart';
import '../../../i18n/strings.g.dart';
import '../../../services/settings_service.dart';
import '../../../services/tofa/tofa_client.dart';
import '../../../services/tofa/tofa_extras.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/language_codes.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import '../../../widgets/pill_input_decoration.dart';
import '../../loading_indicator_box.dart';
import '../models/tofa_subtitle_tools.dart';
import '../models/track_controls_state.dart';
import '../sheets/base_video_control_sheet.dart';
import '../sheets/subtitle_search_sheet.dart';

/// "Search subtitles" for a Tofa item: the server's subtitle providers'
/// candidates for the playing file (`/subtitles/fetch/files/{file}/candidates`),
/// a pick is fetched by the server (`POST …/candidate`, 202), and once the
/// file lists the new track the player reloads with it selected. "Remove
/// downloaded subtitle" deletes the one fetched for the language.
class TofaSubtitleSearchSheet extends StatefulWidget {
  const TofaSubtitleSearchSheet({super.key, required this.tools});

  final TofaSubtitleTools tools;

  @override
  State<TofaSubtitleSearchSheet> createState() => _TofaSubtitleSearchSheetState();
}

class _TofaSubtitleSearchSheetState extends State<TofaSubtitleSearchSheet> {
  final _languageFocusNode = FocusNode(debugLabel: 'TofaSubtitleSearch_language');
  final _firstResultFocusNode = FocusNode(debugLabel: 'TofaSubtitleSearch_firstResult');

  String _languageCode = 'en';
  String _languageName = 'English';
  TofaSubtitleCandidates? _results;
  bool _searching = false;
  String? _error;
  String? _pickingId;
  int _generation = 0;
  bool _showLanguagePicker = false;

  TofaClient get _client => widget.tools.client;
  String? get _fileId => _client.playingFileId(widget.tools.itemId);

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
      final results = await _client.subtitleCandidates(fileId, _languageCode);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      appLogger.d('[tofa] subtitle search failed', error: e.runtimeType);
      setState(() {
        _error = t.videoControls.siloSubtitles.searchFailed;
        _searching = false;
      });
    }
  }

  Future<void> _pick(TofaSubtitleCandidate candidate) async {
    final fileId = _fileId;
    if (_pickingId != null || fileId == null) return;
    setState(() => _pickingId = candidate.id);
    try {
      final before = {for (final track in await _client.fileSubtitleTracks(fileId)) track.index};
      await _client.selectSubtitleCandidate(fileId, candidate.id, _languageCode);
      final index = await _client.waitForNewSubtitle(fileId, before);
      if (!mounted) return;
      if (index == null) {
        showErrorSnackBar(context, t.videoControls.tofaSubtitleStillFetching);
        setState(() => _pickingId = null);
        return;
      }
      final outcome = await widget.tools.applyTrack(index);
      if (!mounted) return;
      if (outcome == SubtitleDownloadApplyOutcome.applied) {
        showSuccessSnackBar(context, t.videoControls.subtitleDownloaded);
        OverlaySheetController.of(context).close();
      } else {
        showErrorSnackBar(context, t.videoControls.subtitleDownloadedNotApplied);
        setState(() => _pickingId = null);
      }
    } catch (e) {
      appLogger.d('[tofa] subtitle pick failed', error: e.runtimeType);
      if (!mounted) return;
      showErrorSnackBar(context, t.videoControls.subtitleDownloadFailed);
      setState(() => _pickingId = null);
    }
  }

  Future<void> _removeFetched() async {
    final fileId = _fileId;
    if (fileId == null || _pickingId != null) return;
    try {
      await _client.removeFetchedSubtitle(fileId, _languageCode);
      if (!mounted) return;
      showSuccessSnackBar(context, t.videoControls.tofaSubtitleRemoved);
      unawaited(_search());
    } catch (e) {
      if (mounted) showErrorSnackBar(context, t.videoControls.subtitleDownloadFailed);
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

  List<TofaSubtitleCandidate> get _visible => [
    for (final c in _results?.candidates ?? const <TofaSubtitleCandidate>[])
      if (!c.rejected) c,
  ];

  bool get _hasResults => _visible.isNotEmpty && !_searching && _error == null;

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
    final visible = _visible;
    final selected = results.selectedCandidate;
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            results.canFetch ? t.videoControls.noSubtitlesFound : t.videoControls.tofaSubtitleCannotFetch,
            textAlign: TextAlign.center,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: visible.length + (selected == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == visible.length) {
          return FocusableListTile(
            leading: const AppIcon(Symbols.delete_rounded),
            title: Text(t.videoControls.tofaRemoveFetchedSubtitle),
            onTap: _pickingId != null ? null : () => unawaited(_removeFetched()),
          );
        }
        final candidate = visible[index];
        final picking = _pickingId == candidate.id;
        final details = [
          candidate.provider,
          LanguageCodes.getLanguageName(candidate.language) ?? candidate.language,
          if (candidate.hearingImpaired) t.videoControls.siloSubtitles.hearingImpaired,
          if (candidate.hashMatch) t.videoControls.tofaSubtitleExactMatch,
          if (candidate.id == selected) t.videoControls.tofaSubtitleInUse,
        ].where((part) => part.isNotEmpty).join(' · ');
        return FocusableListTile(
          focusNode: index == 0 ? _firstResultFocusNode : null,
          title: Text(
            candidate.release.isEmpty ? t.common.unknown : candidate.release,
            maxLines: 2,
            overflow: .ellipsis,
          ),
          subtitle: Text(
            details,
            maxLines: 1,
            overflow: .ellipsis,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          trailing: picking
              ? const LoadingIndicatorBox(size: 20)
              : candidate.score == null
              ? null
              : Text('${candidate.score}', style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
          onTap: _pickingId != null ? null : () => unawaited(_pick(candidate)),
        );
      },
    );
  }
}
