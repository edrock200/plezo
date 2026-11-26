import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/screens/livetv/live_tv_actions_mixin.dart';
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
}
