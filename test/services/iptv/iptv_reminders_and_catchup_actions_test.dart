import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/screens/livetv/live_tv_actions_mixin.dart';
import 'package:plezy/services/iptv/iptv_os_notifications.dart';
import 'package:plezy/services/iptv/iptv_reminders.dart';
import 'package:plezy/services/iptv/iptv_store.dart';

import 'iptv_test_helpers.dart';

void main() {
  test('catch-up is offered for a programme that started inside the archive window', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final archive = LiveTvChannel(key: 'c', title: 'C', catchupDays: 2);
    final plain = LiveTvChannel(key: 'p', title: 'P');
    LiveTvProgram at(int start) => LiveTvProgram(title: 't', beginsAt: start, endsAt: start + 1800);
    expect(LiveTvActionsMixin.canCatchUp(archive, at(now - 3600)), isTrue, reason: 'ended an hour ago');
    expect(LiveTvActionsMixin.canCatchUp(archive, at(now - 600)), isTrue, reason: 'on now, started 10 min ago');
    expect(LiveTvActionsMixin.canCatchUp(archive, at(now - 3 * 86400)), isFalse, reason: 'older than the archive');
    expect(LiveTvActionsMixin.canCatchUp(archive, at(now + 600)), isFalse, reason: 'has not started');
    expect(LiveTvActionsMixin.canCatchUp(plain, at(now - 3600)), isFalse, reason: 'no archive');
  });

  test('a reminder fires a minute before the start, once, and a missed one is only dropped', () async {
    final store = memoryIptvStore();
    var now = DateTime.utc(2026, 11, 26, 20, 0);
    final reminders = IptvReminders(store: store, now: () => now);
    final fired = <IptvReminder>[];
    reminders.onDue = fired.add;
    final start = DateTime.utc(2026, 11, 26, 20, 30).millisecondsSinceEpoch ~/ 1000;
    await reminders.add(
      IptvReminder(sourceId: 's', channelId: 'c', start: start, stop: start + 3600, title: 'Film', channelName: 'One'),
    );
    expect(reminders.has('s', 'c', start), isTrue);
    expect(await reminders.tick(), isEmpty);
    now = DateTime.utc(2026, 11, 26, 20, 29, 10);
    expect((await reminders.tick()).single.title, 'Film');
    expect(fired.single.channelName, 'One');
    expect(reminders.has('s', 'c', start), isFalse);
    expect(await reminders.tick(), isEmpty, reason: 'fires once');

    // Missed while closed: dropped without firing.
    await reminders.add(
      IptvReminder(sourceId: 's', channelId: 'c', start: start - 7200, stop: start - 3600, title: 'Old'),
    );
    await reminders.tick();
    expect(fired, hasLength(1));
    reminders.stop();
    await store.db.close();
  });

  test('with system notifications: scheduled ahead, no dialog, cancelled on removal; Linux shows them itself', () async {
    final store = memoryIptvStore();
    var now = DateTime.utc(2026, 11, 26, 20, 0);
    final system = _FakeNotifier(schedulesAhead: true);
    final reminders = IptvReminders(store: store, now: () => now, notifier: system);
    final dialogs = <IptvReminder>[];
    reminders.onDue = dialogs.add;
    final start = DateTime.utc(2026, 11, 26, 20, 30).millisecondsSinceEpoch ~/ 1000;
    final r = IptvReminder(sourceId: 's', channelId: 'c', start: start, stop: start + 3600, title: 'Film');
    await reminders.add(r);
    expect(system.scheduled.single.$2, DateTime.fromMillisecondsSinceEpoch((start - 60) * 1000));
    now = DateTime.utc(2026, 11, 26, 20, 29, 30);
    await reminders.tick();
    expect(dialogs, isEmpty, reason: 'the system shows it');

    final second = IptvReminder(sourceId: 's', channelId: 'c', start: start + 7200, stop: start + 9000, title: 'Late');
    await reminders.add(second);
    await reminders.remove('s', 'c', start + 7200);
    expect(system.cancelled.single.title, 'Late');

    // Refused by the system: the in-app dialog.
    system.refuse = true;
    final third = IptvReminder(sourceId: 's', channelId: 'd', start: start + 600, stop: start + 1200, title: 'Third');
    await reminders.add(third);
    now = DateTime.fromMillisecondsSinceEpoch((start + 560) * 1000, isUtc: true);
    await reminders.tick();
    expect(dialogs.single.title, 'Third');

    // Linux: no scheduler, shown when due.
    final linux = _FakeNotifier(schedulesAhead: false);
    reminders.notifier = linux;
    final fourth = IptvReminder(sourceId: 's', channelId: 'e', start: start + 1200, stop: start + 1800, title: 'Fourth');
    await reminders.add(fourth);
    now = DateTime.fromMillisecondsSinceEpoch((start + 1150) * 1000, isUtc: true);
    await reminders.tick();
    expect(linux.shown.single.title, 'Fourth');
    expect(dialogs, hasLength(1));
    reminders.stop();
    await store.db.close();
  });

  test('a notification payload round-trips and ids are stable', () {
    final r = IptvReminder(sourceId: 's1', channelId: 'c1', start: 100, stop: 200, title: 'T', channelName: 'N');
    final back = IptvOsNotifications.payloadToReminder(IptvOsNotifications.reminderPayload(r))!;
    expect((back.sourceId, back.channelId, back.start, back.stop, back.title, back.channelName), ('s1', 'c1', 100, 200, 'T', 'N'));
    expect(IptvOsNotifications.notificationId(r), IptvOsNotifications.notificationId(back));
    expect(IptvOsNotifications.notificationId(r), lessThan(1 << 31));
    expect(IptvOsNotifications.payloadToReminder('garbage'), isNull);
  });
}

class _FakeNotifier implements IptvReminderNotifier {
  _FakeNotifier({required this.schedulesAhead});
  @override
  final bool schedulesAhead;
  bool refuse = false;
  final scheduled = <(IptvReminder, DateTime)>[];
  final cancelled = <IptvReminder>[];
  final shown = <IptvReminder>[];

  @override
  Future<bool> schedule(IptvReminder reminder, DateTime at) async {
    if (refuse) return false;
    scheduled.add((reminder, at));
    return true;
  }

  @override
  Future<void> cancel(IptvReminder reminder) async => cancelled.add(reminder);

  @override
  Future<bool> showNow(IptvReminder reminder) async {
    shown.add(reminder);
    return true;
  }
}
