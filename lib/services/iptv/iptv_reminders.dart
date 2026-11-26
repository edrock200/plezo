import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import 'iptv_store.dart';

/// Reminders for guide programmes that have not started.
///
/// A reminder fires inside Plezilo (the main screen shows "starting now" with
/// a Watch button that tunes the channel) a minute before the programme
/// starts. It does not reach the system notification area: that needs a
/// notification plugin with its own setup on each of Android, iOS, macOS,
/// Windows and Linux (permissions, receivers, a scheduler that survives the app
/// being closed), which Plezilo does not ship. A reminder whose time passes
/// while Plezilo is closed is dropped when it next opens.
class IptvReminders {
  IptvReminders({IptvStore? store, DateTime Function()? now}) : _storeOverride = store, _now = now ?? DateTime.now;

  static IptvReminders? _instance;
  static IptvReminders get instance => _instance ??= IptvReminders();
  static set testInstance(IptvReminders? reminders) => _instance = reminders;

  final IptvStore? _storeOverride;
  IptvStore get _store => _storeOverride ?? IptvStore.instance;
  final DateTime Function() _now;

  /// How long before the start a reminder fires.
  static const lead = Duration(minutes: 1);

  /// Called for a due reminder (set by the main screen).
  void Function(IptvReminder reminder)? onDue;

  /// Bumped when reminders change (guide cells show a bell).
  final ValueNotifier<int> changes = ValueNotifier(0);

  Timer? _timer;
  final Set<String> _keys = {};

  static String keyOf(String sourceId, String channelId, int start) => '$sourceId\u0000$channelId\u0000$start';

  bool has(String sourceId, String channelId, int start) => _keys.contains(keyOf(sourceId, channelId, start));

  Future<void> start() async {
    final now = _now().millisecondsSinceEpoch ~/ 1000;
    await _store.pruneReminders(now);
    _keys
      ..clear()
      ..addAll([for (final r in await _store.reminders()) keyOf(r.sourceId, r.channelId, r.start)]);
    _timer ??= Timer.periodic(const Duration(seconds: 20), (_) => unawaited(tick()));
    changes.value++;
  }

  Future<void> add(IptvReminder reminder) async {
    await _store.addReminder(reminder);
    _keys.add(keyOf(reminder.sourceId, reminder.channelId, reminder.start));
    changes.value++;
    appLogger.i(
      '[iptv] reminder set ${((reminder.start - _now().millisecondsSinceEpoch ~/ 1000) / 60).round()} min ahead',
    );
  }

  Future<void> remove(String sourceId, String channelId, int start) async {
    await _store.removeReminder(sourceId, channelId, start);
    _keys.remove(keyOf(sourceId, channelId, start));
    changes.value++;
  }

  /// Fire every reminder within [lead] of its start.
  @visibleForTesting
  Future<List<IptvReminder>> tick() async {
    final now = _now().millisecondsSinceEpoch ~/ 1000;
    final due = <IptvReminder>[];
    for (final r in await _store.reminders()) {
      if (r.start - lead.inSeconds <= now) {
        due.add(r);
        await _store.removeReminder(r.sourceId, r.channelId, r.start);
        _keys.remove(keyOf(r.sourceId, r.channelId, r.start));
      }
    }
    for (final r in due) {
      // A reminder for a programme that already ended is only cleaned up.
      if (r.stop > now) onDue?.call(r);
    }
    if (due.isNotEmpty) changes.value++;
    return due;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
