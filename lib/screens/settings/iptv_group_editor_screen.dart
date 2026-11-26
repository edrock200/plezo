import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/iptv/iptv_store.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/settings_section.dart';

enum _GroupAction { toggleHidden, toggleLocked, moveUp, moveDown, moveTop }

/// A source's groups (Live TV groups, and the movie and series categories of
/// an Xtream source): show or hide each, lock it behind the parental filter,
/// and set their order. A row opens its actions, so every change is one
/// Select away on a TV remote as on a touch screen.
///
/// Pops with the new list of locked group names (live group names and
/// category names share the list).
class IptvGroupEditorScreen extends StatefulWidget {
  const IptvGroupEditorScreen({
    super.key,
    required this.sourceId,
    required this.lockedGroups,
    this.includeVod = false,
    this.store,
  });

  final String sourceId;
  final List<String> lockedGroups;
  final bool includeVod;
  final IptvStore? store;

  @override
  State<IptvGroupEditorScreen> createState() => _IptvGroupEditorScreenState();
}

class _IptvGroupEditorScreenState extends State<IptvGroupEditorScreen> {
  IptvStore get _store => widget.store ?? IptvStore.instance;
  late final Set<String> _locked = {...widget.lockedGroups};
  final Map<IptvGroupKind, List<IptvGroup>> _groups = {};
  bool _loading = true;

  List<IptvGroupKind> get _kinds => [
    IptvGroupKind.live,
    if (widget.includeVod) ...[IptvGroupKind.movie, IptvGroupKind.series],
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    for (final kind in _kinds) {
      _groups[kind] = await _store.groups(widget.sourceId, kind);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _act(IptvGroupKind kind, int index) async {
    final groups = _groups[kind]!;
    final group = groups[index];
    final locked = _locked.contains(group.name);
    final action = await showOptionPickerDialog<_GroupAction>(
      context,
      title: group.name,
      options: [
        (
          icon: group.hidden ? Symbols.visibility_rounded : Symbols.visibility_off_rounded,
          label: group.hidden ? t.iptv.showGroup : t.iptv.hideGroup,
          value: _GroupAction.toggleHidden,
        ),
        (
          icon: locked ? Symbols.lock_open_rounded : Symbols.lock_rounded,
          label: locked ? t.iptv.unlockGroup : t.iptv.lockGroup,
          value: _GroupAction.toggleLocked,
        ),
        if (index > 0) (icon: Symbols.arrow_upward_rounded, label: t.iptv.moveUp, value: _GroupAction.moveUp),
        if (index < groups.length - 1)
          (icon: Symbols.arrow_downward_rounded, label: t.iptv.moveDown, value: _GroupAction.moveDown),
        if (index > 0) (icon: Symbols.vertical_align_top_rounded, label: t.iptv.moveTop, value: _GroupAction.moveTop),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _GroupAction.toggleHidden:
        await _store.setGroupHidden(widget.sourceId, kind, group.id, !group.hidden);
        await _load();
      case _GroupAction.toggleLocked:
        setState(() => locked ? _locked.remove(group.name) : _locked.add(group.name));
      case _GroupAction.moveUp || _GroupAction.moveDown || _GroupAction.moveTop:
        final order = [for (final g in groups) g.id];
        final id = order.removeAt(index);
        final target = switch (action) {
          _GroupAction.moveUp => index - 1,
          _GroupAction.moveDown => index + 1,
          _ => 0,
        };
        order.insert(target, id);
        await _store.setGroupOrder(widget.sourceId, kind, order);
        await _load();
    }
  }

  String _kindTitle(IptvGroupKind kind) => switch (kind) {
    IptvGroupKind.live => t.iptv.liveGroups,
    IptvGroupKind.movie => t.iptv.movieCategories,
    IptvGroupKind.series => t.iptv.seriesCategories,
  };

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_locked.toList());
      },
      child: FocusedScrollScaffold(
        title: Text(t.iptv.groups),
        slivers: [
          if (_loading)
            const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
          else
            SliverList(
              delegate: SliverChildListDelegate([
                for (final kind in _kinds)
                  if ((_groups[kind] ?? const []).isNotEmpty)
                    SettingsGroup(
                      title: _kindTitle(kind),
                      children: [for (var i = 0; i < _groups[kind]!.length; i++) _groupRow(kind, i)],
                    ),
                if (_kinds.every((k) => (_groups[k] ?? const []).isEmpty))
                  Padding(padding: const EdgeInsets.all(24), child: Text(t.iptv.noGroups)),
                const SizedBox(height: 24),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _groupRow(IptvGroupKind kind, int index) {
    final group = _groups[kind]![index];
    final locked = _locked.contains(group.name);
    final state = [
      t.iptv.itemsCount(count: group.count),
      if (group.hidden) t.iptv.hidden,
      if (locked) t.iptv.locked,
    ].join(' · ');
    return FocusableListTile(
      key: ValueKey('iptv-group:${kind.id}:${group.id}'),
      leading: AppIcon(
        locked
            ? Symbols.lock_rounded
            : group.hidden
            ? Symbols.visibility_off_rounded
            : Symbols.folder_rounded,
        fill: 1,
      ),
      title: Text(group.name, style: group.hidden ? TextStyle(color: Theme.of(context).disabledColor) : null),
      subtitle: Text(state),
      trailing: const AppIcon(Symbols.more_vert_rounded, fill: 1),
      onTap: () => unawaited(_act(kind, index)),
    );
  }
}
