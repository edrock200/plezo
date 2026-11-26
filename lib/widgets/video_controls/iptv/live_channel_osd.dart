import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_wrapper.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/livetv_channel.dart';
import '../../../screens/livetv/tabs/channels_tab.dart' show ChannelLogo;
import '../../../screens/video_player/live_channel_zapper.dart';
import '../../../utils/formatters.dart';
import '../../app_icon.dart';

/// What is on a channel now and next, for the banner and the mini guide.
class LiveChannelNowNext {
  const LiveChannelNowNext({this.nowTitle, this.nowStart, this.nowEnd, this.nextTitle, this.nextStart});
  final String? nowTitle;

  /// Epoch seconds.
  final int? nowStart;
  final int? nowEnd;
  final String? nextTitle;
  final int? nextStart;

  static const empty = LiveChannelNowNext();
}

/// The live player's own on-screen display for channel sources (IPTV): the
/// info banner, the number-entry overlay and the mini guide.
///
/// The player routes keys here first ([handleKey]) while its controls are
/// down: Up/Down and Channel±/Page Up/Down zap, digits enter a number, OK
/// opens the mini guide, Info shows the banner, Last (or a lone 0) recalls the
/// previous channel. Everything else (seeking, the controls) stays with the
/// player.
class LiveChannelOsdController extends ChangeNotifier {
  LiveChannelOsdController({
    required this.zapper,
    required this.nowNext,
    this.onShowControls,
    this.onWatchFromStart,
    this.onRecord,
    this.bannerDuration = const Duration(seconds: 5),
  }) {
    zapper.addListener(_onZapperChanged);
  }

  final LiveChannelZapper zapper;
  final Future<LiveChannelNowNext> Function(LiveTvChannel channel) nowNext;

  /// Raise the player's full controls.
  final VoidCallback? onShowControls;

  /// Restart the current programme from its start (catch-up); the getter
  /// answers null when the channel cannot.
  final Future<void> Function()? Function()? onWatchFromStart;

  /// Record the current programme on this device, or null.
  final Future<void> Function()? Function()? onRecord;
  final Duration bannerDuration;

  bool _bannerVisible = false;
  bool get bannerVisible => _bannerVisible;
  bool _miniGuideOpen = false;
  bool get miniGuideOpen => _miniGuideOpen;
  Timer? _bannerTimer;
  int _lastIndex = -1;

  final Map<String, Future<LiveChannelNowNext>> _nowNextCache = {};
  final Map<String, DateTime> _nowNextAt = {};

  Future<LiveChannelNowNext> nowNextOf(LiveTvChannel channel) {
    final key = '${channel.serverId}\u0000${channel.key}';
    final at = _nowNextAt[key];
    if (at == null || DateTime.now().difference(at) > const Duration(minutes: 1)) {
      _nowNextAt[key] = DateTime.now();
      _nowNextCache[key] = nowNext(channel).catchError((_) => LiveChannelNowNext.empty);
    }
    return _nowNextCache[key]!;
  }

  void _onZapperChanged() {
    if (zapper.currentIndex != _lastIndex) {
      _lastIndex = zapper.currentIndex;
      showBanner();
    }
    notifyListeners();
  }

  void showBanner() {
    _bannerVisible = true;
    _bannerTimer?.cancel();
    _bannerTimer = Timer(bannerDuration, hideBanner);
    notifyListeners();
  }

  void hideBanner() {
    _bannerTimer?.cancel();
    if (!_bannerVisible) return;
    _bannerVisible = false;
    notifyListeners();
  }

  void openMiniGuide() {
    if (_miniGuideOpen) return;
    zapper.cancelEntry();
    _miniGuideOpen = true;
    hideBanner();
    notifyListeners();
  }

  void closeMiniGuide() {
    if (!_miniGuideOpen) return;
    _miniGuideOpen = false;
    notifyListeners();
  }

  static int? digitOf(LogicalKeyboardKey key) {
    const digits = [
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    const numpad = [
      LogicalKeyboardKey.numpad0,
      LogicalKeyboardKey.numpad1,
      LogicalKeyboardKey.numpad2,
      LogicalKeyboardKey.numpad3,
      LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpad5,
      LogicalKeyboardKey.numpad6,
      LogicalKeyboardKey.numpad7,
      LogicalKeyboardKey.numpad8,
      LogicalKeyboardKey.numpad9,
    ];
    final d = digits.indexOf(key);
    if (d >= 0) return d;
    final n = numpad.indexOf(key);
    return n >= 0 ? n : null;
  }

  static bool _isChannelUp(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.channelUp || key == LogicalKeyboardKey.pageUp;
  static bool _isChannelDown(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.channelDown || key == LogicalKeyboardKey.pageDown;
  static bool _isSelect(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;
  static bool _isInfo(LogicalKeyboardKey key) => key == LogicalKeyboardKey.info || key == LogicalKeyboardKey.keyI;
  static bool _isMenu(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.contextMenu || key == LogicalKeyboardKey.keyM;
  static bool _isLast(LogicalKeyboardKey key) => key == LogicalKeyboardKey.mediaLast || key == LogicalKeyboardKey.keyL;

  /// The live player's first look at a key. [controlsVisible]: the player's
  /// own controls are up (they keep the arrows and Select then).
  KeyEventResult handleKey(KeyEvent event, {required bool controlsVisible, required bool canSeek}) {
    if (_miniGuideOpen) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    final actionable = event is KeyDownEvent || event is KeyRepeatEvent;

    final digit = digitOf(key);
    if (digit != null) {
      if (down) unawaited(zapper.digit(digit));
      return KeyEventResult.handled;
    }
    if (_isChannelUp(key) || _isChannelDown(key)) {
      if (actionable) unawaited(zapper.step(_isChannelUp(key) ? 1 : -1));
      return KeyEventResult.handled;
    }
    if (_isLast(key)) {
      if (down) unawaited(zapper.recall());
      return KeyEventResult.handled;
    }
    if (_isInfo(key)) {
      if (down) _bannerVisible ? hideBanner() : showBanner();
      return KeyEventResult.handled;
    }
    if (_isMenu(key)) {
      if (down) onShowControls?.call();
      return KeyEventResult.handled;
    }
    if (controlsVisible) return KeyEventResult.ignored;

    if (_isSelect(key)) {
      if (zapper.pendingDigits.isNotEmpty) {
        if (down) unawaited(zapper.commit());
        return KeyEventResult.handled;
      }
      if (down) openMiniGuide();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
      if (actionable) unawaited(zapper.step(key == LogicalKeyboardKey.arrowUp ? 1 : -1));
      return KeyEventResult.handled;
    }
    // Left opens the mini guide on a channel without an archive to seek.
    if (key == LogicalKeyboardKey.arrowLeft && !canSeek) {
      if (down) openMiniGuide();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    zapper.removeListener(_onZapperChanged);
    _bannerTimer?.cancel();
    super.dispose();
  }
}

/// The overlays of [LiveChannelOsdController], laid over the video.
class LiveChannelOsd extends StatefulWidget {
  const LiveChannelOsd({super.key, required this.controller, required this.controlsVisible});

  final LiveChannelOsdController controller;

  /// Whether the player's controls are up (shows the touch button).
  final ValueListenable<bool> controlsVisible;

  @override
  State<LiveChannelOsd> createState() => _LiveChannelOsdState();
}

class _LiveChannelOsdState extends State<LiveChannelOsd> {
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.controller, widget.controller.zapper, widget.controlsVisible]),
      builder: (context, _) {
        final c = widget.controller;
        return Stack(
          children: [
            if (c.bannerVisible && !c.miniGuideOpen)
              Positioned(left: 24, right: 24, bottom: 32, child: _InfoBanner(controller: c)),
            if (c.zapper.pendingDigits.isNotEmpty)
              Positioned(top: 32, right: 32, child: _NumberEntry(zapper: c.zapper)),
            if (widget.controlsVisible.value && !c.miniGuideOpen)
              Positioned(
                top: 72,
                right: 16,
                child: ExcludeFocus(
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: IconButton(
                      tooltip: t.liveTv.channels,
                      color: Colors.white,
                      icon: const AppIcon(Symbols.list_rounded),
                      onPressed: c.openMiniGuide,
                    ),
                  ),
                ),
              ),
            if (c.miniGuideOpen) Positioned.fill(child: LiveMiniGuide(controller: c)),
          ],
        );
      },
    );
  }
}

class _NumberEntry extends StatelessWidget {
  const _NumberEntry({required this.zapper});
  final LiveChannelZapper zapper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final match = zapper.pendingMatch;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: .end,
        mainAxisSize: .min,
        children: [
          Text(
            zapper.pendingDigits,
            style: theme.textTheme.displaySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (match != null)
            Text(match.displayName, style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70)),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.controller});
  final LiveChannelOsdController controller;

  @override
  Widget build(BuildContext context) {
    final channel = controller.zapper.current;
    if (channel == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final is24h = MediaQuery.alwaysUse24HourFormatOf(context);
    String clock(int epoch) => formatClockTime(DateTime.fromMillisecondsSinceEpoch(epoch * 1000), is24Hour: is24h);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(14),
          ),
          child: FutureBuilder<LiveChannelNowNext>(
            future: controller.nowNextOf(channel),
            builder: (context, snap) {
              final nn = snap.data ?? LiveChannelNowNext.empty;
              final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
              double? progress;
              if (nn.nowStart != null && nn.nowEnd != null && nn.nowEnd! > nn.nowStart!) {
                progress = ((now - nn.nowStart!) / (nn.nowEnd! - nn.nowStart!)).clamp(0.0, 1.0);
              }
              final white = theme.textTheme.titleMedium?.copyWith(color: Colors.white);
              final dim = theme.textTheme.bodyMedium?.copyWith(color: Colors.white70);
              return Row(
                children: [
                  ChannelLogo(channel: channel, size: 64),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: .start,
                      mainAxisSize: .min,
                      children: [
                        Text(
                          [if (channel.number != null) channel.number!, channel.displayName].join('  '),
                          style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        if (nn.nowTitle != null)
                          Text(
                            [
                              if (nn.nowStart != null && nn.nowEnd != null)
                                '${clock(nn.nowStart!)}–${clock(nn.nowEnd!)}',
                              nn.nowTitle!,
                            ].join('  '),
                            style: white,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        else
                          Text(t.liveTv.noProgramInfo, style: dim),
                        if (progress != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 3,
                              backgroundColor: Colors.white24,
                            ),
                          ),
                        if (nn.nextTitle != null)
                          Text(
                            t.liveTv.nextOn(
                              title: [if (nn.nextStart != null) clock(nn.nextStart!), nn.nextTitle!].join('  '),
                            ),
                            style: dim,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (channel.catchupDays > 0) ...[
                    const SizedBox(width: 12),
                    AppIcon(Symbols.history_rounded, color: theme.colorScheme.primary),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The channel list inside the player: Up/Down move, OK tunes, Back or Left
/// closes. The current channel is focused when it opens; above the list sit
/// Watch from start, Record and the player's controls when they apply.
class LiveMiniGuide extends StatefulWidget {
  const LiveMiniGuide({super.key, required this.controller});
  final LiveChannelOsdController controller;

  @override
  State<LiveMiniGuide> createState() => _LiveMiniGuideState();
}

class _LiveMiniGuideState extends State<LiveMiniGuide> {
  static const rowHeight = 64.0;
  late final ScrollController _scroll;
  final List<FocusNode> _rows = [];
  final _fromStartFocus = FocusNode(debugLabel: 'MiniGuide:FromStart');
  final _recordFocus = FocusNode(debugLabel: 'MiniGuide:Record');
  final _controlsFocus = FocusNode(debugLabel: 'MiniGuide:Controls');
  FocusNode? _restoreFocus;

  LiveChannelZapper get _zapper => widget.controller.zapper;

  @override
  void initState() {
    super.initState();
    _restoreFocus = FocusManager.instance.primaryFocus;
    final current = _zapper.currentIndex.clamp(0, (_zapper.channels.length - 1).clamp(0, 1 << 30));
    _scroll = ScrollController(initialScrollOffset: (current - 3).clamp(0, 1 << 30) * rowHeight);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _zapper.channels.isNotEmpty) _node(current).requestFocus();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final n in _rows) {
      n.dispose();
    }
    _fromStartFocus.dispose();
    _recordFocus.dispose();
    _controlsFocus.dispose();
    final restore = _restoreFocus;
    if (restore != null && restore.context != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (restore.context != null) restore.requestFocus();
      });
    }
    super.dispose();
  }

  FocusNode _node(int i) {
    while (_rows.length <= i) {
      _rows.add(FocusNode(debugLabel: 'MiniGuide:Row${_rows.length}'));
    }
    return _rows[i];
  }

  void _close() => widget.controller.closeMiniGuide();

  Future<void> _tune(int index) async {
    _close();
    await _zapper.tuneIndex(index);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack ||
        key == LogicalKeyboardKey.arrowLeft) {
      if (event is KeyUpEvent) _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channels = _zapper.channels;
    final fromStart = widget.controller.onWatchFromStart?.call();
    final record = widget.controller.onRecord?.call();
    final headerNodes = [
      if (fromStart != null) _fromStartFocus,
      if (record != null) _recordFocus,
      if (widget.controller.onShowControls != null) _controlsFocus,
    ];
    Widget headerButton(FocusNode node, IconData icon, String label, VoidCallback onPressed, int index) =>
        FocusableWrapper(
          focusNode: node,
          useBackgroundFocus: true,
          disableScale: true,
          onSelect: onPressed,
          onNavigateLeft: index > 0 ? () => headerNodes[index - 1].requestFocus() : null,
          onNavigateRight: index < headerNodes.length - 1 ? () => headerNodes[index + 1].requestFocus() : null,
          onNavigateDown: channels.isEmpty
              ? null
              : () => _node(_zapper.currentIndex.clamp(0, channels.length - 1)).requestFocus(),
          onBack: _close,
          child: TextButton.icon(
            onPressed: onPressed,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: AppIcon(icon, size: 18),
            label: Text(label),
          ),
        );
    return Focus(
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 420,
              height: double.infinity,
              color: Colors.black.withValues(alpha: 0.86),
              child: SafeArea(
                right: false,
                child: Column(
                  crossAxisAlignment: .stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                      child: Text(t.liveTv.channels, style: theme.textTheme.titleMedium?.copyWith(color: Colors.white)),
                    ),
                    if (headerNodes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Wrap(
                          spacing: 4,
                          children: [
                            if (fromStart != null)
                              headerButton(_fromStartFocus, Symbols.replay_rounded, t.liveTv.watchFromBeginning, () {
                                _close();
                                unawaited(fromStart());
                              }, headerNodes.indexOf(_fromStartFocus)),
                            if (record != null)
                              headerButton(_recordFocus, Symbols.fiber_manual_record_rounded, t.liveTv.record, () {
                                _close();
                                unawaited(record());
                              }, headerNodes.indexOf(_recordFocus)),
                            if (widget.controller.onShowControls != null)
                              headerButton(_controlsFocus, Symbols.tune_rounded, t.liveTv.playerControls, () {
                                _close();
                                widget.controller.onShowControls!();
                              }, headerNodes.indexOf(_controlsFocus)),
                          ],
                        ),
                      ),
                    Expanded(
                      child: ListView.builder(
                        controller: _scroll,
                        itemCount: channels.length,
                        itemExtent: rowHeight,
                        itemBuilder: (context, i) => _row(context, i, headerNodes),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int i, List<FocusNode> headerNodes) {
    final theme = Theme.of(context);
    final channel = _zapper.channels[i];
    final current = i == _zapper.currentIndex;
    return FocusableWrapper(
      focusNode: _node(i),
      useBackgroundFocus: true,
      disableScale: true,
      autoScroll: true,
      onSelect: () => unawaited(_tune(i)),
      onNavigateUp: i > 0
          ? () => _node(i - 1).requestFocus()
          : (headerNodes.isEmpty ? null : () => headerNodes.first.requestFocus()),
      onNavigateDown: i < _zapper.channels.length - 1 ? () => _node(i + 1).requestFocus() : null,
      onBack: _close,
      child: InkWell(
        onTap: () => unawaited(_tune(i)),
        child: Container(
          color: current ? Colors.white.withValues(alpha: 0.08) : null,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                child: Text(
                  channel.number ?? '',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(color: Colors.white),
                ),
              ),
              const SizedBox(width: 8),
              ChannelLogo(channel: channel, size: 44),
              const SizedBox(width: 10),
              Expanded(
                child: FutureBuilder<LiveChannelNowNext>(
                  future: widget.controller.nowNextOf(channel),
                  builder: (context, snap) => Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: .start,
                    children: [
                      Text(
                        channel.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(color: Colors.white),
                      ),
                      if (snap.data?.nowTitle case final title?)
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
                        ),
                    ],
                  ),
                ),
              ),
              if (current) const AppIcon(Symbols.play_arrow_rounded, color: Colors.white, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
