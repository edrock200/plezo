import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../connection/connection.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../services/iptv/iptv_store.dart';
import '../../services/iptv/iptv_sync_worker.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import 'iptv_source_settings_screen.dart' show formatShiftMinutes;

enum _ChannelAction { toggleHidden, rename, renumber, mapGuide, shift, reset }

/// Every channel of a source, hidden ones included, with a search box. A row
/// opens its actions: show or hide, rename, change the number, pick the
/// guide channel it reads (searchable), shift its guide, or undo every change.
///
/// The list is built lazily, so a source of thousands of channels scrolls
/// without building them all.
class IptvChannelEditorScreen extends StatefulWidget {
  const IptvChannelEditorScreen({super.key, required this.connection, this.store});

  final IptvConnection connection;
  final IptvStore? store;

  @override
  State<IptvChannelEditorScreen> createState() => _IptvChannelEditorScreenState();
}

class _IptvChannelEditorScreenState extends State<IptvChannelEditorScreen> {
  IptvStore get _store => widget.store ?? IptvStore.instance;
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'IptvChannels:Search');
  final _listFocus = FocusNode(debugLabel: 'IptvChannels:FirstRow');
  List<IptvChannel> _all = const [];
  List<IptvChannel> _shown = const [];
  Map<String, String> _guideNames = const {};
  bool _loading = true;

  String get _sourceId => widget.connection.id;

  @override
  void initState() {
    super.initState();
    _search.addListener(_filter);
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final channels = await _store.channels(_sourceId);
    final guide = await _store.epgChannels(_sourceId);
    if (!mounted) return;
    setState(() {
      _all = channels;
      _guideNames = guide.names;
      _loading = false;
    });
    _filter();
  }

  void _filter() {
    final q = _search.text.trim().toLowerCase();
    setState(() {
      _shown = q.isEmpty
          ? _all
          : _all
                .where((c) => c.name.toLowerCase().contains(q) || (c.originalName ?? '').toLowerCase().contains(q))
                .toList();
    });
  }

  Future<void> _save(
    IptvChannel c, {
    bool? hidden,
    String? name,
    String? number,
    String? epgId,
    int? shift,
    bool clearName = false,
    bool clearNumber = false,
    bool clearEpg = false,
  }) async {
    final keepName = c.name != c.originalName ? c.name : null;
    await _store.setChannelOverride(
      _sourceId,
      c.id,
      hidden: hidden ?? c.hidden,
      name: clearName ? null : name ?? keepName,
      number: clearNumber ? null : number ?? c.number,
      epgId: clearEpg ? null : epgId ?? c.manualEpgId,
      shiftMinutes: shift ?? c.shiftMinutes,
    );
    if (epgId != null || clearEpg) {
      await IptvSyncWorker(store: _store).rematch(widget.connection);
    }
    await _load();
  }

  Future<void> _act(IptvChannel c) async {
    final action = await showOptionPickerDialog<_ChannelAction>(
      context,
      title: c.name,
      options: [
        (
          icon: c.hidden ? Symbols.visibility_rounded : Symbols.visibility_off_rounded,
          label: c.hidden ? t.iptv.showChannel : t.iptv.hideChannel,
          value: _ChannelAction.toggleHidden,
        ),
        (icon: Symbols.edit_rounded, label: t.iptv.renameChannel, value: _ChannelAction.rename),
        (icon: Symbols.pin_rounded, label: t.iptv.renumberChannel, value: _ChannelAction.renumber),
        (icon: Symbols.calendar_view_day_rounded, label: t.iptv.mapGuide, value: _ChannelAction.mapGuide),
        (icon: Symbols.more_time_rounded, label: t.iptv.channelShift, value: _ChannelAction.shift),
        (icon: Symbols.restart_alt_rounded, label: t.iptv.resetChannel, value: _ChannelAction.reset),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _ChannelAction.toggleHidden:
        await _save(c, hidden: !c.hidden);
      case _ChannelAction.rename:
        final name = await showTextInputDialog(
          context,
          title: t.iptv.renameChannel,
          labelText: t.iptv.channelName,
          initialValue: c.name,
          allowEmpty: true,
        );
        if (name == null) return;
        await _save(c, name: name.trim(), clearName: name.trim().isEmpty || name.trim() == c.originalName);
      case _ChannelAction.renumber:
        final number = await showTextInputDialog(
          context,
          title: t.iptv.renumberChannel,
          labelText: t.iptv.channelNumber,
          initialValue: c.number ?? c.playlistNumber,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          allowEmpty: true,
        );
        if (number == null) return;
        await _save(c, number: number.trim(), clearNumber: number.trim().isEmpty);
      case _ChannelAction.mapGuide:
        final picked = await Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => IptvGuidePickerScreen(channel: c, guideNames: _guideNames),
          ),
        );
        if (picked == null) return;
        await _save(c, epgId: picked.isEmpty ? null : picked, clearEpg: picked.isEmpty);
      case _ChannelAction.shift:
        final options = [for (var m = -6 * 60; m <= 6 * 60; m += 15) m];
        final shift = await showOptionPickerDialog<int>(
          context,
          title: t.iptv.channelShift,
          options: [
            for (final m in options)
              (icon: m == c.shiftMinutes ? Symbols.check_rounded : null, label: formatShiftMinutes(m), value: m),
          ],
        );
        if (shift == null) return;
        await _save(c, shift: shift);
      case _ChannelAction.reset:
        await _store.setChannelOverride(_sourceId, c.id, hidden: false);
        await IptvSyncWorker(store: _store).rematch(widget.connection);
        await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.iptv.channels)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: FocusableTextFormField(
              controller: _search,
              focusNode: _searchFocus,
              autofocus: true,
              tvTextInputPresentation: TvTextInputPresentation.platform,
              tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
              onNavigateDown: () => _listFocus.requestFocus(),
              decoration: InputDecoration(
                prefixIcon: const AppIcon(Symbols.search_rounded),
                labelText: t.iptv.searchChannels,
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _shown.isEmpty
                ? Center(child: Text(t.iptv.noChannelsFound))
                : ListView.builder(
                    itemCount: _shown.length,
                    itemExtent: 72,
                    itemBuilder: (context, i) {
                      final c = _shown[i];
                      final guide = c.epgChannelId == null
                          ? t.iptv.noGuide
                          : _guideNames[c.epgChannelId] ?? c.epgChannelId!;
                      final parts = [
                        if (c.group != null) c.group!,
                        guide,
                        if (c.hidden) t.iptv.hidden,
                        if (c.manualEpgId != null) t.iptv.mappedByHand,
                        if (c.shiftMinutes != 0) formatShiftMinutes(c.shiftMinutes),
                      ];
                      return FocusableListTile(
                        key: ValueKey('iptv-channel:${c.id}'),
                        focusNode: i == 0 ? _listFocus : null,
                        leading: SizedBox(
                          width: 44,
                          child: Text(
                            c.number ?? c.playlistNumber ?? '',
                            style: theme.textTheme.titleSmall,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        title: Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: c.hidden ? TextStyle(color: theme.disabledColor) : null,
                        ),
                        subtitle: Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const AppIcon(Symbols.more_vert_rounded, fill: 1),
                        onTap: () => unawaited(_act(c)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Pick the guide channel a channel reads. Pops with its id, or `''` to go
/// back to automatic matching.
class IptvGuidePickerScreen extends StatefulWidget {
  const IptvGuidePickerScreen({super.key, required this.channel, required this.guideNames});

  final IptvChannel channel;

  /// Guide channel id → display name.
  final Map<String, String> guideNames;

  @override
  State<IptvGuidePickerScreen> createState() => _IptvGuidePickerScreenState();
}

class _IptvGuidePickerScreenState extends State<IptvGuidePickerScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'IptvGuidePicker:Search');
  final _firstFocus = FocusNode(debugLabel: 'IptvGuidePicker:First');
  late List<MapEntry<String, String>> _entries = _filtered();

  @override
  void initState() {
    super.initState();
    _search.text = widget.channel.originalName ?? widget.channel.name;
    _entries = _filtered();
    _search.addListener(() => setState(() => _entries = _filtered()));
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _firstFocus.dispose();
    super.dispose();
  }

  List<MapEntry<String, String>> _filtered() {
    final q = _search.text.trim().toLowerCase();
    final all = widget.guideNames.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    if (q.isEmpty) return all;
    final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    return all
        .where((e) => words.every((w) => e.value.toLowerCase().contains(w) || e.key.toLowerCase().contains(w)))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.channel.epgChannelId;
    return Scaffold(
      appBar: AppBar(title: Text(t.iptv.mapGuideFor(name: widget.channel.name))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: FocusableTextFormField(
              controller: _search,
              focusNode: _searchFocus,
              tvTextInputPresentation: TvTextInputPresentation.platform,
              tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.never,
              onNavigateDown: () => _firstFocus.requestFocus(),
              decoration: InputDecoration(
                prefixIcon: const AppIcon(Symbols.search_rounded),
                labelText: t.iptv.searchGuideChannels,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _entries.length + 1,
              itemExtent: 64,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return FocusableListTile(
                    focusNode: _firstFocus,
                    autofocus: true,
                    leading: const AppIcon(Symbols.auto_awesome_rounded, fill: 1),
                    title: Text(t.iptv.automaticMatch),
                    subtitle: Text(t.iptv.automaticMatchHint),
                    onTap: () => Navigator.of(context).pop(''),
                  );
                }
                final e = _entries[i - 1];
                return FocusableListTile(
                  leading: AppIcon(e.key == current ? Symbols.check_rounded : Symbols.tv_rounded, fill: 1),
                  title: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.of(context).pop(e.key),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
