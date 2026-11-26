import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../media/media_item.dart';
import '../../models/livetv_channel.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/dialogs.dart';
import '../../utils/live_tv_player_navigation.dart';
import '../../models/livetv_program.dart';
import '../../services/iptv/iptv_client.dart';
import '../../services/iptv/iptv_ids.dart';
import 'live_tv_actions_mixin.dart';
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
  await tuneIptvReminder(context, reminder);
}

/// Tune a reminder's channel (Watch in the dialog, or a selected system
/// notification).
Future<void> tuneIptvReminder(BuildContext context, IptvReminder reminder) async {
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

/// Tune the channel of an IPTV channel card (Home's favourites row, a search
/// hit). A guide-programme hit that has ended, on a channel with catch-up,
/// starts at the programme's beginning in the archive.
Future<void> tuneIptvChannelItem(BuildContext context, MediaItem item) async {
  final multiServer = context.read<MultiServerProvider>();
  final serverId = item.serverId;
  final client = serverId == null ? null : multiServer.serverManager.iptvClient(serverId);
  final parsed = IptvItemId.parse(item.id);
  if (client == null || parsed is! IptvChannelItemId) {
    showErrorSnackBar(context, t.liveTv.serverNotConnected);
    return;
  }
  if (!multiServer.liveTvServers.any((s) => s.serverId == client.serverId.value)) {
    await multiServer.checkLiveTvAvailability();
  }
  final dvrKey = multiServer.liveTvServers.where((s) => s.serverId == client.serverId.value).firstOrNull?.dvrKey;
  final channels = [for (final c in await client.liveTv.fetchChannels()) c.copyWith(liveDvrKey: dvrKey)];
  final channel = channels.where((c) => c.key == parsed.channelId).firstOrNull;
  if (channel == null || !context.mounted) return;
  final start = item.raw?['start'];
  final stop = item.raw?['stop'];
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final program = start is int
      ? LiveTvProgram(title: item.title ?? '', beginsAt: start, endsAt: stop is int ? stop : null)
      : null;
  final catchUp = program != null && (program.endsAt ?? now) <= now && LiveTvActionsMixin.canCatchUp(channel, program);
  await navigateToLiveTv(
    context,
    multiServer: multiServer,
    channel: channel,
    channels: channels,
    startAtEpoch: catchUp ? program.beginsAt : null,
  );
}
