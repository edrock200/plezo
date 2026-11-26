import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/livetv_channel.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/dialogs.dart';
import '../../utils/live_tv_player_navigation.dart';
import '../../models/livetv_program.dart';
import '../../services/iptv/iptv_client.dart';
import '../../services/iptv/iptv_reminders.dart';
import '../../services/iptv/iptv_store.dart';
import '../../utils/snackbar_helper.dart';
import '../../i18n/strings.g.dart';
import 'program_details_sheet.dart';

/// The reminder action of a programme on an IPTV channel.
ProgramReminderAction iptvReminderFor(IptvClient client, LiveTvChannel channel, LiveTvProgram program) {
  final sourceId = client.connection.id;
  final start = program.beginsAt ?? 0;
  final reminders = IptvReminders.instance;
  final isSet = reminders.has(sourceId, channel.key, start);
  return ProgramReminderAction(
    isSet: isSet,
    toggle: () async {
      if (isSet) {
        await reminders.remove(sourceId, channel.key, start);
        showMainSnackBar(t.liveTv.reminderCancelled);
        return;
      }
      await reminders.add(
        IptvReminder(
          sourceId: sourceId,
          channelId: channel.key,
          start: start,
          stop: program.endsAt ?? start + 3600,
          title: program.displayTitle,
          channelName: channel.displayName,
        ),
      );
      showMainSnackBar(t.liveTv.reminderSet);
    },
  );
}

/// A due reminder: a dialog (reachable with the D-pad) that tunes the
/// channel on Watch.
Future<void> showIptvReminderDialog(BuildContext context, IptvReminder reminder) async {
  final watch = await showConfirmDialog(
    context,
    title: t.liveTv.reminderTitle,
    message: t.liveTv.reminderMessage(title: reminder.title, channel: reminder.channelName ?? ''),
    confirmText: t.liveTv.reminderWatch,
    cancelText: t.liveTv.reminderDismiss,
  );
  if (!watch || !context.mounted) return;
  final multiServer = context.read<MultiServerProvider>();
  final client = multiServer.serverManager.iptvClient(reminder.sourceId);
  if (client == null) {
    showErrorSnackBar(context, t.liveTv.serverNotConnected);
    return;
  }
  await multiServer.checkLiveTvAvailability();
  final channels = await client.liveTv.fetchChannels();
  final channel = channels.where((c) => c.key == reminder.channelId).firstOrNull;
  if (channel == null || !context.mounted) return;
  final dvrKey = multiServer.liveTvServers.where((s) => s.serverId == client.serverId.value).firstOrNull?.dvrKey;
  final scoped = [for (final c in channels) c.copyWith(liveDvrKey: dvrKey)];
  await navigateToLiveTv(
    context,
    multiServer: multiServer,
    channel: channel.copyWith(liveDvrKey: dvrKey),
    channels: scoped,
  );
}
