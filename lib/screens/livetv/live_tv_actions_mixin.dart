import 'package:flutter/material.dart';
import '../../media/ids.dart';
import 'package:provider/provider.dart';

import '../../models/livetv_channel.dart';
import '../../models/livetv_program.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/live_tv_matching.dart';
import '../../utils/live_tv_player_navigation.dart';
import '../../utils/media_image_helper.dart';
import '../../services/iptv/iptv_client.dart';
import 'iptv_live_actions.dart';
import 'program_details_sheet.dart';

/// Shared live-TV actions: channel lookup, tuning, and program-details sheet.
///
/// Implementers expose their channel list via [liveTvChannels] and invoke
/// [findChannelForProgram], [tuneChannel], and [showProgramDetails] as needed.
mixin LiveTvActionsMixin<T extends StatefulWidget> on State<T> {
  /// Channel list used for lookups and passed into the playback navigator.
  List<LiveTvChannel> get liveTvChannels;

  LiveTvChannel? findChannelForProgram(LiveTvProgram program) {
    return liveTvChannels.where((channel) => liveTvProgramMatchesChannel(program, channel)).firstOrNull;
  }

  /// Start live playback for [channel] on its owning server.
  ///
  /// Both backends route through the live-TV navigator so the player
  /// inherits the live-only branches (no Trakt scrobble, no progress
  /// scrobble, channel up/down nav, no resume bookmark). The player starts
  /// the backend-neutral session itself (Plex tune / Jellyfin stream
  /// negotiation under its loading spinner).
  Future<void> tuneChannel(LiveTvChannel channel, {int? startAtEpoch}) async {
    final multiServer = context.read<MultiServerProvider>();
    await navigateToLiveTv(
      context,
      multiServer: multiServer,
      channel: channel,
      channels: liveTvChannels,
      startAtEpoch: startAtEpoch,
    );
  }

  /// Whether [program] on [channel] can be played from its start out of the
  /// channel's catch-up archive: it started within the archive window.
  static bool canCatchUp(LiveTvChannel? channel, LiveTvProgram program) {
    final begins = program.beginsAt;
    if (channel == null || channel.catchupDays <= 0 || begins == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return begins < now - 60 && begins > now - channel.catchupDays * 86400;
  }

  /// Open the program-details bottom sheet. The poster is resolved from
  /// [posterThumb] on the server identified by [posterServerId].
  void showProgramDetails({
    BuildContext? sheetContext,
    required LiveTvProgram program,
    required LiveTvChannel? channel,
    required String? posterThumb,
    required String? posterServerId,
    ValueChanged<bool>? onRecordingStateChanged,
  }) {
    final effectiveContext = sheetContext ?? context;
    final multiServer = effectiveContext.read<MultiServerProvider>();
    final serverId = serverIdOrNull(posterServerId);
    final client = serverId == null ? null : multiServer.getClientForServer(serverId);
    String? posterUrl;
    if (posterThumb != null && client != null) {
      posterUrl = MediaImageHelper.getOptimizedImageUrl(
        client: client,
        thumbPath: posterThumb,
        maxWidth: 80,
        maxHeight: 120,
        pixelRatio: MediaImageHelper.artworkPixelRatio(effectiveContext),
        imageType: ImageType.poster,
      );
    }

    showProgramDetailsSheet(
      effectiveContext,
      program: program,
      channel: channel,
      posterUrl: posterUrl,
      onTuneChannel: channel != null ? () => tuneChannel(channel) : null,
      onPlayFromStart: canCatchUp(channel, program)
          ? () => tuneChannel(channel!, startAtEpoch: program.beginsAt)
          : null,
      reminder: client is IptvClient && channel != null ? iptvReminderFor(client, channel, program) : null,
      client: client,
      onRecordingStateChanged: onRecordingStateChanged,
    );
  }
}
