import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/livetv_channel.dart';

/// What a channel-number entry or recall resolved to.
sealed class ZapTarget {
  const ZapTarget();
}

/// Tune the channel at [index] of the list.
final class ZapToIndex extends ZapTarget {
  const ZapToIndex(this.index);
  final int index;
}

/// The digits matched no channel.
final class ZapNoMatch extends ZapTarget {
  const ZapNoMatch(this.digits);
  final String digits;
}

/// Channel zapping for the live player, independent of the player: channel
/// up/down, number entry and last-channel recall over the player's channel
/// list.
///
/// Number entry collects digits for [entryTimeout] after the last one (or up
/// to [maxDigits]), then resolves: the channel whose number is exactly the
/// digits, else the first whose number starts with them. A lone `0` that no
/// channel answers recalls the previous channel, like a remote's "last"
/// button.
class LiveChannelZapper extends ChangeNotifier {
  LiveChannelZapper({
    required this.channels,
    required int currentIndex,
    required this.onZap,
    this.entryTimeout = const Duration(milliseconds: 1800),
    this.maxDigits = 5,
  }) : _current = currentIndex;

  /// The player's channel list, in its zapping order.
  final List<LiveTvChannel> channels;
  List<LiveTvChannel> get _channels => channels;
  int _current;
  int? _previous;
  final Duration entryTimeout;
  final int maxDigits;

  /// Asked to tune a channel (the player's zap). Returns whether it did.
  final Future<bool> Function(int index) onZap;

  String _digits = '';
  Timer? _entryTimer;

  int get currentIndex => _current;
  int? get previousIndex => _previous;
  LiveTvChannel? get current => _current >= 0 && _current < _channels.length ? _channels[_current] : null;

  /// The digits typed so far ('' when no entry is under way).
  String get pendingDigits => _digits;

  /// The channel the pending digits would tune now, for the overlay.
  LiveTvChannel? get pendingMatch {
    final index = indexForNumber(_channels, _digits);
    return index == null ? null : _channels[index];
  }

  /// The player tuned [index] by itself (a zap from its own controls).
  void syncCurrent(int index) {
    if (index == _current) return;
    _previous = _current;
    _current = index;
    notifyListeners();
  }

  /// Zaps run one after another, so quick presses each start from the
  /// channel the one before tuned.
  Future<void>? _queue;

  /// Channel up (+1) or down (-1), wrapping around the list.
  Future<bool> step(int delta) {
    if (_channels.isEmpty) return Future.value(false);
    final result = (_queue ?? Future<void>.value()).then((_) {
      final next = (_current + delta) % _channels.length;
      return _tuneNow(next < 0 ? next + _channels.length : next);
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// The previous channel, if any.
  Future<bool> recall() {
    final previous = _previous;
    if (previous == null || previous < 0 || previous >= _channels.length) return Future.value(false);
    return _tune(previous);
  }

  Future<bool> tuneIndex(int index) => _tune(index);

  Future<bool> _tune(int index) {
    final result = (_queue ?? Future<void>.value()).then((_) => _tuneNow(index));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _tuneNow(int index) async {
    if (index == _current || index < 0 || index >= _channels.length) return false;
    final from = _current;
    final ok = await onZap(index);
    if (ok) {
      _previous = from;
      _current = index;
      notifyListeners();
    }
    return ok;
  }

  /// A digit key. Returns the resolution when the entry completed at once
  /// ([maxDigits] reached), else null while waiting for more.
  Future<ZapTarget?> digit(int digit) async {
    if (digit < 0 || digit > 9) return null;
    _digits += '$digit';
    _entryTimer?.cancel();
    notifyListeners();
    if (_digits.length >= maxDigits) return commit();
    _entryTimer = Timer(entryTimeout, () => unawaited(commit()));
    return null;
  }

  /// End the entry now (timeout, OK). Tunes the match, or recalls on a lone 0.
  Future<ZapTarget?> commit() async {
    _entryTimer?.cancel();
    _entryTimer = null;
    final digits = _digits;
    if (digits.isEmpty) return null;
    _digits = '';
    notifyListeners();
    final index = indexForNumber(_channels, digits);
    if (index != null) {
      await _tune(index);
      return ZapToIndex(index);
    }
    if (digits == '0' && _previous != null) {
      final previous = _previous!;
      await recall();
      return ZapToIndex(previous);
    }
    return ZapNoMatch(digits);
  }

  /// Drop a pending entry.
  void cancelEntry() {
    _entryTimer?.cancel();
    _entryTimer = null;
    if (_digits.isEmpty) return;
    _digits = '';
    notifyListeners();
  }

  /// The index of the channel numbered [digits]: an exact number (leading
  /// zeros ignored), else the first number that starts with them.
  @visibleForTesting
  static int? indexForNumber(List<LiveTvChannel> channels, String digits) {
    if (digits.isEmpty) return null;
    final wanted = _trimZeros(digits);
    for (var i = 0; i < channels.length; i++) {
      final number = channels[i].number;
      if (number != null && _trimZeros(number) == wanted) return i;
    }
    for (var i = 0; i < channels.length; i++) {
      final number = channels[i].number;
      if (number != null && number.startsWith(digits)) return i;
    }
    return null;
  }

  static String _trimZeros(String s) {
    final trimmed = s.trim().replaceFirst(RegExp(r'^0+(?=\d)'), '');
    return trimmed;
  }

  @override
  void dispose() {
    _entryTimer?.cancel();
    super.dispose();
  }
}
