import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../i18n/strings.g.dart';
import '../../../services/settings_service.dart';
import '../../../services/silo/silo_subtitles.dart';
import '../../../utils/language_codes.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import '../models/silo_subtitle_tools.dart';
import '../sheets/base_video_control_sheet.dart';
import '../sheets/subtitle_search_sheet.dart';
import 'silo_ai_subtitle_controller.dart';

enum _AiView { form, source, target }

/// "Translate with AI" for a Silo item (Silo's TvAiTranslateDialog): translate
/// a subtitle track, or transcribe an audio track, into a language. The job
/// runs on the server; [SiloAiSubtitleController] follows it, also after this
/// sheet closes, and loads the result into the player.
class SiloAiSubtitleSheet extends StatefulWidget {
  const SiloAiSubtitleSheet({super.key, required this.tools});

  final SiloSubtitleTools tools;

  @override
  State<SiloAiSubtitleSheet> createState() => _SiloAiSubtitleSheetState();
}

class _SiloAiSubtitleSheetState extends State<SiloAiSubtitleSheet> {
  late final SiloAiSubtitleController _controller = SiloAiSubtitleController.of(widget.tools);
  bool _loading = true;
  _AiView _view = _AiView.form;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    final preferred = SettingsService.instanceOrNull?.read(SettingsService.subtitleSearchLanguage);
    unawaited(
      _controller
          .open(preferredTarget: preferred ?? WidgetsBinding.instance.platformDispatcher.locale.languageCode)
          .whenComplete(() {
            if (mounted) setState(() => _loading = false);
          }),
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _show(_AiView view) {
    setState(() => _view = view);
    OverlaySheetController.of(context).refocus();
  }

  @override
  Widget build(BuildContext context) {
    return switch (_view) {
      _AiView.source => _buildSourcePicker(),
      _AiView.target => SubtitleLanguagePickerView(
        title: t.videoControls.siloSubtitles.targetLanguage,
        currentCode: _controller.targetCode ?? 'en',
        languages: _aiLanguages(),
        onSelected: (code, _) {
          _controller.setTarget(code);
          _show(_AiView.form);
        },
        onBack: () => _show(_AiView.form),
      ),
      _AiView.form => BaseVideoControlSheet(
        title: t.videoControls.siloSubtitles.translateWithAi,
        icon: Symbols.translate_rounded,
        onBack: () => OverlaySheetController.of(context).pop(),
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : ListView(shrinkWrap: true, children: _formRows()),
      ),
    };
  }

  static List<({String code, String name})> _aiLanguages() {
    final list = [
      for (final code in SiloSubtitleRules.aiLanguageCodes)
        (code: code, name: LanguageCodes.getLanguageName(code) ?? code),
    ];
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  List<Widget> _formRows() {
    final s = t.videoControls.siloSubtitles;
    final c = _controller;
    final theme = Theme.of(context);
    Widget note(String text, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(text, style: TextStyle(color: color ?? theme.colorScheme.onSurfaceVariant)),
    );

    switch (c.phase) {
      case SiloAiPhase.running:
        final job = c.job;
        final percent = ((job?.progress ?? 0) * 100).round().clamp(0, 100);
        return [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.progress(percent: percent)),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: percent / 100),
                if (job?.progressMessage != null) ...[
                  const SizedBox(height: 6),
                  Text(job!.progressMessage!, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
          FocusableListTile(
            autofocus: true,
            leading: const AppIcon(Symbols.close_rounded),
            title: Text(t.common.cancel),
            onTap: c.cancel,
          ),
        ];
      case SiloAiPhase.submitting:
        return [note(s.submitting)];
      case SiloAiPhase.applying:
        return [note(s.applying)];
      case SiloAiPhase.idle:
      case SiloAiPhase.failed:
        break;
    }

    if (!c.canUseSubtitles && !c.canUseAudio) {
      return [
        note(s.unavailable),
        FocusableListTile(
          autofocus: true,
          title: Text(t.common.close),
          onTap: () => OverlaySheetController.of(context).pop(),
        ),
      ];
    }

    final rows = <Widget>[];
    var first = true;
    bool takeFirst() {
      final value = first;
      first = false;
      return value;
    }

    if (c.canUseSubtitles && c.canUseAudio) {
      rows.add(
        FocusableListTile(
          autofocus: takeFirst(),
          leading: const AppIcon(Symbols.swap_horiz_rounded),
          title: Text(s.mode),
          subtitle: Text(c.fromSubtitles ? s.fromSubtitles : s.fromAudio),
          onTap: () => c.setFromSubtitles(!c.fromSubtitles),
        ),
      );
    }
    rows.add(
      FocusableListTile(
        autofocus: takeFirst(),
        leading: AppIcon(c.fromSubtitles ? Symbols.subtitles_rounded : Symbols.audiotrack_rounded),
        title: Text(c.fromSubtitles ? s.sourceSubtitle : s.sourceAudio),
        subtitle: Text(_sourceLabel(c.fromSubtitles ? c.subtitlePos : c.audioPos)),
        trailing: const AppIcon(Symbols.chevron_right_rounded),
        onTap: () => _show(_AiView.source),
      ),
    );
    if (c.showsTarget) {
      final code = c.targetCode ?? 'en';
      rows.add(
        FocusableListTile(
          leading: const AppIcon(Symbols.language_rounded),
          title: Text(s.targetLanguage),
          subtitle: Text(LanguageCodes.getLanguageName(code) ?? code),
          trailing: const AppIcon(Symbols.chevron_right_rounded),
          onTap: () => _show(_AiView.target),
        ),
      );
    } else {
      rows.add(note(s.spokenLanguageOnly));
    }
    final quota = c.quota;
    if (!c.fromSubtitles && quota != null && quota.limited) {
      final period = _period(quota.period);
      rows.add(
        c.quotaExhausted
            ? note(
                s.quotaExhausted(used: quota.used ?? 0, limit: quota.limit ?? 0, period: period),
                color: Colors.amber,
              )
            : note(s.quotaLeft(remaining: quota.remaining ?? 0, limit: quota.limit ?? 0, period: period)),
      );
    }
    if (c.phase == SiloAiPhase.failed && c.error != null) {
      rows.add(note(c.error!, color: theme.colorScheme.error));
    }
    rows.add(
      FocusableListTile(
        enabled: !c.quotaExhausted,
        leading: const AppIcon(Symbols.auto_awesome_rounded),
        title: Text(c.fromSubtitles ? s.translate : s.transcribe),
        onTap: c.quotaExhausted ? null : () => unawaited(c.submit()),
      ),
    );
    return rows;
  }

  String _period(String? period) {
    final s = t.videoControls.siloSubtitles;
    return switch (period?.toLowerCase()) {
      'day' => s.periodDay,
      'week' => s.periodWeek,
      'month' => s.periodMonth,
      final p? when p.isNotEmpty => s.periodOther(period: p),
      _ => '',
    };
  }

  String _sourceLabel(int pos) {
    final c = _controller;
    if (c.fromSubtitles) {
      if (c.subtitleSources.isEmpty) return '';
      return subtitleSourceLabel(c.subtitleSources[pos.clamp(0, c.subtitleSources.length - 1)], pos);
    }
    if (c.audioSources.isEmpty) return '';
    return audioSourceLabel(c.audioSources[pos.clamp(0, c.audioSources.length - 1)], pos);
  }

  Widget _buildSourcePicker() {
    final c = _controller;
    final s = t.videoControls.siloSubtitles;
    final count = c.fromSubtitles ? c.subtitleSources.length : c.audioSources.length;
    final selected = c.fromSubtitles ? c.subtitlePos : c.audioPos;
    final primary = Theme.of(context).colorScheme.primary;
    return BaseVideoControlSheet(
      title: c.fromSubtitles ? s.sourceSubtitle : s.sourceAudio,
      icon: c.fromSubtitles ? Symbols.subtitles_rounded : Symbols.audiotrack_rounded,
      onBack: () => _show(_AiView.form),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: count,
        itemBuilder: (context, i) {
          final isSelected = i == selected;
          return FocusableListTile(
            autofocus: isSelected,
            title: Text(_sourceLabel(i), style: TextStyle(color: isSelected ? primary : null)),
            trailing: isSelected ? AppIcon(Symbols.check_rounded, fill: 1, color: primary) : null,
            onTap: () {
              if (c.fromSubtitles) {
                c.setSubtitlePos(i);
              } else {
                c.setAudioPos(i);
              }
              _show(_AiView.form);
            },
          );
        },
      ),
    );
  }
}

/// "English SRT (External)", like Silo's TV app labels a subtitle source.
String subtitleSourceLabel(SiloAiSubtitleSource source, int position) {
  final s = t.videoControls.siloSubtitles;
  final code = SiloSubtitleRules.twoLetter(source.language);
  var name = (code == null ? null : LanguageCodes.getLanguageName(code)) ?? '';
  if (name.isEmpty) name = source.label?.trim() ?? '';
  if (name.isEmpty) name = s.track(number: position + 1);
  final codec = switch (source.codec?.toLowerCase()) {
    'subrip' || 'srt' => 'SRT',
    'webvtt' || 'vtt' => 'VTT',
    'ass' || 'ssa' => 'ASS',
    'mov_text' => 'TX3G',
    final other? when other.isNotEmpty => other.toUpperCase(),
    _ => '',
  };
  if (codec.isNotEmpty) name = '$name $codec';
  return switch (source.source) {
    'external' => '$name (${s.external})',
    'downloaded' => '$name (${s.downloaded})',
    _ => name,
  };
}

/// "English · AC3 · 5.1", with the track's title or "Track 2" when it has no
/// language.
String audioSourceLabel(SiloAiAudioSource source, int position) {
  final code = SiloSubtitleRules.twoLetter(source.language);
  var name = (code == null ? null : LanguageCodes.getLanguageName(code)) ?? source.title?.trim() ?? '';
  if (name.isEmpty) name = t.videoControls.siloSubtitles.track(number: position + 1);
  final channels = switch (source.channels) {
    null => null,
    1 => 'Mono',
    2 => 'Stereo',
    6 => '5.1',
    8 => '7.1',
    final n => '${n}ch',
  };
  return [
    name,
    if (source.codec != null && source.codec!.isNotEmpty) source.codec!.toUpperCase(),
    ?channels,
  ].join(' · ');
}
