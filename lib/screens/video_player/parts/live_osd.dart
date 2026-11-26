part of '../../video_player_screen.dart';

/// The IPTV live OSD: zapping (Up/Down, Channel±, Page Up/Down), number
/// entry, last-channel recall, the info banner and the mini guide, plus
/// "Watch from start" and "Record" for the programme on now. Only IPTV
/// sessions get it; Plex, Jellyfin and Tofa live playback is unchanged.
extension _VideoPlayerLiveOsdMethods on VideoPlayerScreenState {
  void _initLiveOsd() {
    final live = widget.live;
    final channels = live?.channels;
    if (live == null || channels == null || channels.isEmpty || widget.metadata.backend != MediaBackend.iptv) return;
    final zapper = LiveChannelZapper(
      channels: channels,
      currentIndex: live.currentChannelIndex ?? 0,
      onZap: (index) async {
        final delta = index - _live.channelIndex;
        if (delta == 0) return false;
        await _switchLiveChannel(delta);
        return _live.channelIndex == index;
      },
    );
    _liveZapper = zapper;
    _liveOsd = LiveChannelOsdController(
      zapper: zapper,
      nowNext: _iptvNowNext,
      onShowControls: () => _chromeController.show(focusPlayPause: true),
      onWatchFromStart: _watchCurrentProgrammeFromStart,
      onRecord: _recordCurrentProgramme,
    )..showBanner();
  }

  void _disposeLiveOsd() {
    _liveOsd?.dispose();
    _liveOsd = null;
    _liveZapper?.dispose();
    _liveZapper = null;
  }

  KeyEventResult _handleLiveOsdKey(KeyEvent event, {required bool controlsVisible}) {
    final osd = _liveOsd;
    if (osd == null) return KeyEventResult.ignored;
    return osd.handleKey(event, controlsVisible: controlsVisible, canSeek: _live.captureBuffer != null);
  }

  IptvClient? _iptvClientFor(LiveTvChannel channel) {
    final serverId = channel.serverId;
    if (serverId == null) return null;
    final client = context.read<MultiServerProvider>().getClientForServer(ServerId(serverId));
    return client is IptvClient ? client : null;
  }

  Future<LiveChannelNowNext> _iptvNowNext(LiveTvChannel channel) async {
    final client = _iptvClientFor(channel);
    if (client == null) return LiveChannelNowNext.empty;
    final nn = await client.nowNext(channel.key);
    String? title(IptvProgramme? p) => p == null ? null : (p.subTitle == null ? p.title : '${p.title}: ${p.subTitle}');
    return LiveChannelNowNext(
      nowTitle: title(nn.now),
      nowStart: nn.now?.start,
      nowEnd: nn.now?.stop,
      nextTitle: title(nn.next),
      nextStart: nn.next?.start,
    );
  }

  void _markIptvChannelWatched(LiveTvChannel channel) {
    final client = _iptvClientFor(channel);
    if (client != null) unawaited(client.store.addRecent(client.connection.id, channel.key).catchError((_) {}));
  }

  /// "Watch from start" for the programme on now, when the channel's archive
  /// holds its start.
  Future<void> Function()? _watchCurrentProgrammeFromStart() {
    final buffer = _live.captureBuffer;
    final channel = _liveZapper?.current;
    if (buffer == null || channel == null) return null;
    return () async {
      final nn = await _iptvNowNext(channel);
      final start = nn.nowStart;
      if (start == null || start < buffer.seekableStartEpoch) return;
      await _seekLiveToEpoch(start);
    };
  }

  /// Record the programme on now until it ends (or the next hour without a
  /// guide), on this device.
  Future<void> Function()? _recordCurrentProgramme() {
    final channel = _liveZapper?.current;
    if (channel == null) return null;
    final client = _iptvClientFor(channel);
    if (client == null) return null;
    return () async {
      final nn = await _iptvNowNext(channel);
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      try {
        await IptvRecorder.instance.schedule(
          sourceId: client.connection.id,
          channelId: channel.key,
          channelName: channel.displayName,
          title: nn.nowTitle ?? channel.displayName,
          start: now,
          stop: nn.nowEnd != null && nn.nowEnd! > now ? nn.nowEnd! : now + 3600,
        );
        showMainSnackBar(t.liveTv.recordingStarted);
      } catch (e) {
        appLogger.w('[iptv] recording from the player not started (${e.runtimeType})');
        showGlobalErrorSnackBar(t.liveTv.recordingFailedToStart);
      }
    };
  }
}
