import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';
import 'iptv_os_notifications.dart';
import 'iptv_store.dart';

/// Reminders for guide programmes that have not started.
///
/// A reminder fires a minute before the programme starts:
/// - as a system notification ([notifier], flutter_local_notifications) on
///   Android phones and tablets, iOS, macOS and Windows, scheduled with the
///   system so it shows even while Plezilo is closed; on Linux, which has no
///   scheduler, Plezilo shows it while it runs. Selecting it opens the channel.
/// - inside Plezilo (a dialog with Watch) on TV, where there is no
///   notification shade, and wherever the system refused (no permission).
///   That one fires only while Plezilo is open.
class IptvReminders {
  IptvReminders({IptvStore? store, DateTime Function()? now, this.notifier})
    : _storeOverride = store,
      _now = now ?? DateTime.now;

  /// System notifications, or null (TV, tests, unsupported).
  IptvReminderNotifier? notifier;

  /// Reminders the system holds (shown by it, not by the dialog).
  final Set<String> _withSystem = {};

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
    // Scheduling again is harmless (same id) and covers a reinstall or a
    // system that dropped its alarms.
    for (final r in await _store.reminders()) {
      await _scheduleWithSystem(r);
    }
    _timer ??= Timer.periodic(const Duration(seconds: 20), (_) => unawaited(tick()));
    changes.value++;
  }

  Future<void> _scheduleWithSystem(IptvReminder r) async {
    final n = notifier;
    if (n == null || !n.schedulesAhead) return;
    final at = DateTime.fromMillisecondsSinceEpoch((r.start - lead.inSeconds) * 1000);
    if (!at.isAfter(_now())) return;
    if (await n.schedule(r, at)) _withSystem.add(keyOf(r.sourceId, r.channelId, r.start));
  }

  Future<void> add(IptvReminder reminder) async {
    await _store.addReminder(reminder);
    _keys.add(keyOf(reminder.sourceId, reminder.channelId, reminder.start));
    await _scheduleWithSystem(reminder);
    changes.value++;
    appLogger.i(
      '[iptv] reminder set ${((reminder.start - _now().millisecondsSinceEpoch ~/ 1000) / 60).round()} min ahead',
    );
  }

  Future<void> remove(String sourceId, String channelId, int start) async {
    final stored = (await _store.reminders(
      sourceId: sourceId,
    )).where((r) => r.channelId == channelId && r.start == start);
    for (final r in stored) {
      await notifier?.cancel(r);
    }
    _withSystem.remove(keyOf(sourceId, channelId, start));
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
      final key = keyOf(r.sourceId, r.channelId, r.start);
      // A reminder for a programme that already ended is only cleaned up.
      if (r.stop <= now) {
        _withSystem.remove(key);
        continue;
      }
      // The system shows the ones it holds; Linux shows ours now; the rest
      // (TV, refused) get the in-app dialog.
      if (_withSystem.remove(key)) continue;
      final n = notifier;
      if (n != null && !n.schedulesAhead && await n.showNow(r)) continue;
      onDue?.call(r);
    }
    if (due.isNotEmpty) changes.value++;
    return due;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
