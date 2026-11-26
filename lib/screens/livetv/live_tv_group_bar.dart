import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../widgets/focusable_tab_chip.dart';

/// A horizontally scrolling row of group filter chips for the Live TV guide
/// and channel list: All, Recent (when there are recently watched channels),
/// then each group. Left/Right move between chips (the row scrolls to keep
/// the focused one in view), Select picks one, Up and Down leave the row.
class LiveTvGroupBar extends StatefulWidget {
  const LiveTvGroupBar({
    super.key,
    required this.groups,
    required this.selected,
    required this.onSelected,
    this.showRecent = false,
    this.onNavigateUp,
    this.onNavigateDown,
    this.onBack,
  });

  /// The value [selected] holds for the recently watched channels.
  static const recentKey = '\u0000recent';

  final List<String> groups;

  /// Null for all channels.
  final String? selected;
  final ValueChanged<String?> onSelected;
  final bool showRecent;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;
  final VoidCallback? onBack;

  @override
  State<LiveTvGroupBar> createState() => LiveTvGroupBarState();
}

class LiveTvGroupBarState extends State<LiveTvGroupBar> {
  final List<FocusNode> _nodes = [];
  final Map<int, GlobalKey> _keys = {};

  List<String?> get _values => [null, if (widget.showRecent) LiveTvGroupBar.recentKey, ...widget.groups];

  FocusNode _node(int i) {
    while (_nodes.length <= i) {
      _nodes.add(FocusNode(debugLabel: 'live_tv_group_${_nodes.length}'));
    }
    return _nodes[i];
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  /// Focus the selected chip (Up from the guide or channel list).
  void focusSelected() {
    final index = _values.indexOf(widget.selected);
    _focus(index < 0 ? 0 : index);
  }

  void _focus(int i) {
    if (i < 0 || i >= _values.length) return;
    _node(i).requestFocus();
    final context = _keys[i]?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 150));
    }
  }

  String _label(String? value) => switch (value) {
    null => t.liveTv.allGroups,
    LiveTvGroupBar.recentKey => t.liveTv.recentChannels,
    final group => group,
  };

  @override
  Widget build(BuildContext context) {
    final values = _values;
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        itemCount: values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final value = values[i];
          return KeyedSubtree(
            key: _keys.putIfAbsent(i, GlobalKey.new),
            child: FocusableTabChip(
              label: _label(value),
              isSelected: widget.selected == value,
              focusNode: _node(i),
              onSelect: () => widget.onSelected(value),
              onNavigateLeft: i > 0 ? () => _focus(i - 1) : null,
              onNavigateRight: i < values.length - 1 ? () => _focus(i + 1) : null,
              onNavigateUp: widget.onNavigateUp,
              onNavigateDown: widget.onNavigateDown,
              onBack: widget.onBack,
            ),
          );
        },
      ),
    );
  }
}
