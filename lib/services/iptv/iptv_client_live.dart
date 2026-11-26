part of 'iptv_client.dart';

/// One channel as the Live TV screens and the player see it, with the number
/// it shows.
class IptvShownChannel {
  const IptvShownChannel(this.channel, this.number);
  final IptvChannel channel;
  final String number;
}

/// Now and next on a channel.
typedef IptvNowNext = ({IptvProgramme? now, IptvProgramme? next});

extension IptvClientLive on IptvClient {
  /// The channels shown, in order, numbered: hidden channels, hidden groups
  /// and (while locked) the parental filter's groups left out.
  Future<List<IptvShownChannel>> shownChannels() async {
    final revision = IptvParentalGate.revision.value;
    final cached = _channelCache;
    if (cached != null && cached.revision == revision && cached.dataRevision == IptvDataRevision.of(_connection.id)) {
      return cached.channels;
    }
    final channels = await store.channels(_connection.id);
    final groups = await store.groups(_connection.id, IptvGroupKind.live);
    final locked = _lockedNames;
    final hiddenGroups = {
      for (final g in groups)
        if (g.hidden || locked.contains(g.name)) g.name,
    };
    final groupOrder = {for (var i = 0; i < groups.length; i++) groups[i].name: i};
    final visible = [
      for (final ch in channels)
        if (!ch.hidden && !(ch.group != null && hiddenGroups.contains(ch.group))) ch,
    ];
    // Group order (the user's, then the source's), playlist order inside.
    visible.sort((a, b) {
      final ga = a.group == null ? -1 : groupOrder[a.group] ?? 1 << 20;
      final gb = b.group == null ? -1 : groupOrder[b.group] ?? 1 << 20;
      if (ga != gb) return ga.compareTo(gb);
      return a.sortIndex.compareTo(b.sortIndex);
    });
    final shown = numberChannels(visible, _connection.numbering);
    _channelCache = (revision: revision, dataRevision: IptvDataRevision.of(_connection.id), channels: shown);
    return shown;
  }

  /// Number [channels] (already in display order): the user's number first;
  /// then, with [IptvChannelNumbering.playlist], `tvg-chno`; every other
  /// channel takes the next free number after the highest one used.
  static List<IptvShownChannel> numberChannels(List<IptvChannel> channels, IptvChannelNumbering numbering) {
    final used = <String>{};
    var highest = 0;
    final fixed = <int, String>{};
    for (var i = 0; i < channels.length; i++) {
      final ch = channels[i];
      final explicit = ch.number ?? (numbering == IptvChannelNumbering.playlist ? ch.playlistNumber : null);
      if (explicit == null || explicit.trim().isEmpty || used.contains(explicit.trim())) continue;
      final value = explicit.trim();
      fixed[i] = value;
      used.add(value);
      final n = double.tryParse(value)?.floor();
      if (n != null && n > highest) highest = n;
    }
    var next = highest + 1;
    return [
      for (var i = 0; i < channels.length; i++)
        IptvShownChannel(
          channels[i],
          fixed[i] ??
              () {
                while (used.contains('$next')) {
                  next++;
                }
                final value = '$next';
                used.add(value);
                next++;
                return value;
              }(),
        ),
    ];
  }

  LiveTvChannel _liveChannel(IptvShownChannel shown) {
    final ch = shown.channel;
    return LiveTvChannel(
      key: ch.id,
      identifier: ch.id,
      title: ch.name,
      thumb: ch.logo,
      number: shown.number,
      serverId: serverId.value,
      serverName: serverName,
      group: ch.group,
      catchupDays: ch.hasCatchup ? ch.catchupDays ?? 0 : 0,
      radio: ch.radio,
    );
  }

  Future<IptvShownChannel?> _shownChannel(String channelId) async {
    for (final shown in await shownChannels()) {
      if (shown.channel.id == channelId) return shown;
    }
    return null;
  }

  /// Total guide shift of [ch] in seconds.
  int _shiftSeconds(IptvChannel ch) =>
      (_connection.epgShiftMinutes + ch.shiftMinutes) * 60 + ((ch.tvgShiftHours ?? 0) * 3600).round();

  /// Programmes of the shown channels overlapping `[from, to)`, shifted,
  /// one per channel showing them (two channels can share a guide channel).
  Future<List<({IptvShownChannel channel, IptvProgramme programme})>> schedule(DateTime from, DateTime to) async {
    final shown = await shownChannels();
    final byEpg = <String, List<IptvShownChannel>>{};
    var maxShift = 0;
    for (final s in shown) {
      final epg = s.channel.epgChannelId;
      if (epg == null || epg.isEmpty) continue;
      byEpg.putIfAbsent(epg, () => []).add(s);
      final shift = _shiftSeconds(s.channel).abs();
      if (shift > maxShift) maxShift = shift;
    }
    if (byEpg.isEmpty) return const [];
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    final rows = await store.programmes(
      _connection.id,
      from: fromEpoch - maxShift,
      to: toEpoch + maxShift,
      channels: byEpg.length > 2000 ? null : byEpg.keys.toSet(),
    );
    final out = <({IptvShownChannel channel, IptvProgramme programme})>[];
    for (final p in rows) {
      final targets = byEpg[p.epgChannelId];
      if (targets == null) continue;
      for (final target in targets) {
        final shifted = p.shifted(_shiftSeconds(target.channel));
        if (shifted.stop <= fromEpoch || shifted.start >= toEpoch) continue;
        out.add((channel: target, programme: shifted));
      }
    }
    return out;
  }

  LiveTvProgram _liveProgram(IptvShownChannel channel, IptvProgramme p, {IptvRecordingRow? recording}) {
    final isEpisode = p.subTitle != null || p.episode != null;
    return LiveTvProgram(
      key: '${channel.channel.id}@${p.start}',
      ratingKey: '${channel.channel.id}@${p.start}',
      guid: _IptvDvr.airingGuid(channel.channel.id, p.start, p.stop),
      title: isEpisode && p.subTitle != null ? p.subTitle! : p.title,
      grandparentTitle: isEpisode && p.subTitle != null ? p.title : null,
      summary: p.description,
      type: isEpisode ? 'episode' : 'movie',
      year: p.year,
      beginsAt: p.start,
      endsAt: p.stop,
      index: p.episodeNumber,
      parentIndex: p.season,
      thumb: p.icon,
      channelIdentifier: channel.channel.id,
      channelCallSign: channel.channel.name,
      serverId: serverId.value,
      serverName: serverName,
      subscriptionId: recording == null ? null : '${_IptvDvr.recordingPrefix}${recording.id}',
      grandparentSubscriptionId: recording?.ruleId == null ? null : '${_IptvDvr.rulePrefix}${recording!.ruleId}',
    );
  }

  /// Now and next on [channelId]: from the stored guide, else (Xtream) the
  /// provider's short guide.
  Future<IptvNowNext> nowNext(String channelId, {DateTime? at}) async {
    final shown = await _shownChannel(channelId) ?? await _anyChannel(channelId);
    if (shown == null) return (now: null, next: null);
    final ch = shown.channel;
    final now = (at ?? _now()).millisecondsSinceEpoch ~/ 1000;
    final epg = ch.epgChannelId;
    final shift = _shiftSeconds(ch);
    if (epg != null && epg.isNotEmpty) {
      final rows = await store.programmes(
        _connection.id,
        from: now - shift.abs(),
        to: now + 12 * 3600 + shift.abs(),
        channels: {epg},
      );
      final shifted = [for (final p in rows) p.shifted(shift)]..sort((a, b) => a.start.compareTo(b.start));
      IptvProgramme? current;
      IptvProgramme? next;
      for (final p in shifted) {
        if (p.start <= now && p.stop > now) {
          current ??= p;
        } else if (p.start > now) {
          next ??= p;
        }
      }
      if (current != null || next != null) return (now: current, next: next);
    }
    final api = _xtream;
    final xtreamId = ch.xtreamId;
    if (api == null || xtreamId == null) return (now: null, next: null);
    try {
      final entries = await api.shortEpg(xtreamId, limit: 3);
      IptvProgramme? current;
      IptvProgramme? next;
      for (final e in entries) {
        final p = IptvProgramme(
          epgChannelId: e.epgId ?? ch.id,
          start: e.start,
          stop: e.stop,
          title: e.title,
          description: e.description,
        );
        if (p.start <= now && p.stop > now) {
          current ??= p;
        } else if (p.start > now) {
          next ??= p;
        }
      }
      return (now: current, next: next);
    } catch (e) {
      appLogger.d('[iptv] short guide unavailable (${e.runtimeType})');
      return (now: null, next: null);
    }
  }

  /// A channel even when it is not shown (hidden, locked): for the player of
  /// a channel opened before it was hidden.
  Future<IptvShownChannel?> _anyChannel(String channelId) async {
    final ch = await store.channel(_connection.id, channelId);
    return ch == null ? null : IptvShownChannel(ch, ch.number ?? ch.playlistNumber ?? '');
  }

  /// The live address of [ch].
  String? liveUrlOf(IptvChannel ch) {
    final api = _xtream;
    if (ch.xtreamId != null && api != null) {
      return api.liveUrl(ch.xtreamId!, extension: _connection.xtreamOutput == 'm3u8' ? 'm3u8' : 'ts');
    }
    return ch.url.isEmpty ? null : ch.url;
  }

  /// The archive address of [ch] from [start] (up to now), or null.
  String? catchupUrlOf(IptvChannel ch, DateTime start, {Duration? duration}) {
    if (!ch.hasCatchup) return null;
    final now = _now();
    final length = duration ?? now.difference(start);
    if (length.inSeconds <= 0) return null;
    final api = _xtream;
    if (ch.catchupMode == IptvCatchupMode.xtream && api != null && ch.xtreamId != null) {
      return api.timeshiftUrl(
        ch.xtreamId!,
        start: start,
        duration: length,
        serverOffset: _serverOffset ?? Duration.zero,
        phpRoute: _connection.xtreamTimeshiftPhp,
      );
    }
    final live = liveUrlOf(ch);
    if (live == null) return null;
    return IptvCatchup.build(
      mode: ch.catchupMode,
      channelUrl: live,
      source: ch.catchupSource,
      start: start,
      duration: length,
      now: now,
    );
  }

  /// What the recorder fetches for [channelId], or null.
  Future<IptvRecordingTarget?> recordingTarget(String channelId) async {
    final shown = await _shownChannel(channelId) ?? await _anyChannel(channelId);
    if (shown == null) return null;
    final url = liveUrlOf(shown.channel);
    return url == null ? null : (url: url, headers: headersOf(shown.channel));
  }

  /// HTTP headers for [ch]'s streams: the source's, then the channel's own.
  Map<String, String> headersOf(IptvChannel ch) => {...streamHeaders, ...ch.headers};

  Future<LiveTvPlaybackSession?> _startLive(String channelKey) async {
    final shown = await _shownChannel(channelKey) ?? await _anyChannel(channelKey);
    if (shown == null) {
      appLogger.w('[iptv] channel not found');
      return null;
    }
    final url = liveUrlOf(shown.channel);
    if (url == null) {
      appLogger.w('[iptv] channel has no address');
      return null;
    }
    if (_serverOffset == null && _xtream != null) {
      final account = await storedAccount();
      _serverOffset = account?.serverOffset;
    }
    unawaited(store.addRecent(_connection.id, shown.channel.id).catchError((_) {}));
    final current = await nowNext(shown.channel.id);
    final programme = current.now;
    appLogger.i(
      '[iptv] tuning channel catchup=${shown.channel.hasCatchup ? '${shown.channel.catchupDays}d/${shown.channel.catchupMode.id}' : 'none'} '
      'headers=${headersOf(shown.channel).keys.join(',')}',
    );
    return IptvLiveSession._(
      this,
      shown.channel,
      url,
      program: programme == null
          ? LiveProgramInfo.none
          : LiveProgramInfo(
              id: '${shown.channel.id}@${programme.start}',
              durationMs: (programme.stop - programme.start) * 1000,
              beginsAt: programme.start,
            ),
    );
  }

  Future<MediaItem?> _channelItem(String channelId) async {
    final shown = await _shownChannel(channelId) ?? await _anyChannel(channelId);
    if (shown == null) return null;
    return MediaItem.iptv(
      id: IptvChannelItemId(channelId).toString(),
      kind: MediaKind.clip,
      title: shown.channel.name,
      thumbPath: shown.channel.logo,
      serverId: serverId.value,
      serverName: serverName,
      raw: {'key': channelId},
    );
  }

  /// Live TV favourites of this source, as the Home row shows them: the
  /// channel and what is on now.
  Future<List<({LiveTvChannel channel, IptvProgramme? now})>> favoriteChannelsNow({int limit = 30}) async {
    final ids = await store.favoriteChannelIds(_connection.id);
    if (ids.isEmpty) return const [];
    final shown = {for (final s in await shownChannels()) s.channel.id: s};
    final out = <({LiveTvChannel channel, IptvProgramme? now})>[];
    for (final id in ids.take(limit)) {
      final s = shown[id];
      if (s == null) continue;
      final nn = await nowNext(id);
      out.add((channel: _liveChannel(s), now: nn.now));
    }
    return out;
  }

  /// Channels and programmes matching [query], for search.
  Future<({List<LiveTvChannel> channels, List<({LiveTvChannel channel, LiveTvProgram programme})> programmes})>
  searchLive(String query, {int limit = 30}) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return (
        channels: const <LiveTvChannel>[],
        programmes: const <({LiveTvChannel channel, LiveTvProgram programme})>[],
      );
    }
    final shown = await shownChannels();
    final channels = [
      for (final s in shown)
        if (s.channel.name.toLowerCase().contains(q) || s.number == q) _liveChannel(s),
    ].take(limit).toList();
    final byEpg = <String, List<IptvShownChannel>>{};
    for (final s in shown) {
      final epg = s.channel.epgChannelId;
      if (epg != null) byEpg.putIfAbsent(epg, () => []).add(s);
    }
    final now = _now().millisecondsSinceEpoch ~/ 1000;
    final rows = await store.searchProgrammes(_connection.id, q, from: now, limit: limit * 2);
    final programmes = <({LiveTvChannel channel, LiveTvProgram programme})>[];
    for (final p in rows) {
      final target = byEpg[p.epgChannelId]?.firstOrNull;
      if (target == null) continue;
      final shifted = p.shifted(_shiftSeconds(target.channel));
      programmes.add((channel: _liveChannel(target), programme: _liveProgram(target, shifted)));
      if (programmes.length >= limit) break;
    }
    return (channels: channels, programmes: programmes);
  }

  /// The source's live groups, shown ones only, in order.
  Future<List<String>> shownGroups() async {
    final shown = await shownChannels();
    final seen = <String>{};
    return [
      for (final s in shown)
        if (s.channel.group case final g? when seen.add(g)) g,
    ];
  }
}

/// Live TV of an IPTV source.
class _IptvLiveTvSupport implements LiveTvSupport, LiveTvChannelGroups, LiveTvRecordedItems {
  _IptvLiveTvSupport(this._client);
  final IptvClient _client;

  @override
  LiveTvDvrSupport? get dvr => _IptvDvr(_client);

  @override
  Future<bool> isAvailable() async => (await _client.shownChannels()).isNotEmpty;

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) async => [
    for (final s in await _client.shownChannels()) _client._liveChannel(s),
  ];

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async {
    final start = from ?? DateTime.now();
    final end = to ?? start.add(const Duration(hours: 6));
    final rows = await _client.schedule(start, end);
    // Airings set to record carry the recording (and series rule) key, so
    // the guide marks them and the details sheet offers Manage, not Record.
    final booked = <String, IptvRecordingRow>{
      for (final r in await _client.store.recordings(sourceId: _client.connection.id))
        if (r.state == IptvRecordingState.scheduled || r.state == IptvRecordingState.recording)
          '${r.channelId}@${r.start}': r,
    };
    return [
      for (final row in rows)
        _client._liveProgram(
          row.channel,
          row.programme,
          recording: booked['${row.channel.channel.id}@${row.programme.start}'],
        ),
    ];
  }

  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) => _client._startLive(channelKey);

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => 'server://${_client.serverId.value}/iptv';

  @override
  String get favoriteStoreKey => 'iptv:${_client.connection.id}';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) async {
    final source = await buildFavoriteChannelSource();
    final ids = await _client.store.favoriteChannelIds(_client.connection.id);
    final shown = {for (final s in await _client.shownChannels()) s.channel.id: s};
    return [
      for (final id in ids)
        FavoriteChannel(
          source: source,
          id: id,
          title: shown[id]?.channel.name,
          thumb: shown[id]?.channel.logo,
          vcn: shown[id]?.number,
        ),
    ];
  }

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) async {
    final source = await buildFavoriteChannelSource();
    await _client.store.setFavoriteChannelIds(_client.connection.id, [
      for (final f in channels)
        if (f.source == source) f.id,
    ]);
    IptvDataRevision.bumpFavorites();
  }

  @override
  Future<List<String>> fetchGroups() => _client.shownGroups();

  @override
  Future<List<String>> fetchRecentChannelKeys() => _client.store.recentChannelIds(_client.connection.id);

  @override
  Future<void> markChannelWatched(String channelKey) => _client.store.addRecent(_client.connection.id, channelKey);

  @override
  Future<List<LiveTvRecording>> fetchRecordings() async => [
    for (final r in await _client.store.recordings(sourceId: _client.connection.id))
      if (r.state == IptvRecordingState.completed && r.path != null)
        LiveTvRecording(
          id: IptvRecordingId(r.id).toString(),
          title: r.title,
          channelName: r.channelName,
          recordedAt: DateTime.fromMillisecondsSinceEpoch(r.start * 1000),
        ),
  ];

  @override
  Future<MediaItem?> recordingItem(LiveTvRecording recording) => _client.fetchItem(recording.id);
}

/// A tuned IPTV channel. There is no server session: the stream is the
/// provider's address, and "time-shift" is the channel's catch-up archive.
///
/// For a channel with catch-up, [captureBuffer] spans the archive (from
/// `catchup-days` ago to now), so the player's seek bar, skip and "Watch from
/// start" restart at the shifted archive address ([streamUrlAt]); the live
/// edge plays the live address again.
class IptvLiveSession implements LiveTvPlaybackSession, LiveTvStreamHeaders {
  IptvLiveSession._(this._client, this.channel, this._liveUrl, {required this.program})
    : _openedAt = _client._now(),
      _archiveDays = channel.hasCatchup ? (channel.catchupDays ?? 0).clamp(0, 30) : 0;

  final IptvClient _client;
  final IptvChannel channel;
  final String _liveUrl;
  final DateTime _openedAt;
  final int _archiveDays;

  /// Reconnect attempts since the stream last played.
  int _attempts = 0;

  @visibleForTesting
  static List<Duration> reconnectDelays = const [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ];

  @override
  final LiveProgramInfo program;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.stopAndExit;

  @override
  Map<String, String> get streamHeaders => _client.headersOf(channel);

  CaptureBuffer? _window(DateTime now) {
    if (_archiveDays <= 0) return null;
    final origin = _openedAt.millisecondsSinceEpoch / 1000 - _archiveDays * 86400;
    final end = now.millisecondsSinceEpoch / 1000 - origin;
    return CaptureBuffer(startedAt: origin.floorToDouble(), seekStartSeconds: 0, seekEndSeconds: end.floorToDouble());
  }

  @override
  CaptureBuffer? get captureBuffer => _window(_client._now());

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  bool get canTimeShift => _archiveDays > 0;

  /// Seconds behind now that still count as live.
  static const liveEdgeSlackSeconds = 45;

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) async {
    if (offsetSeconds == null) return _liveUrl;
    final window = captureBuffer;
    if (window == null) return null;
    final epoch = (window.startedAt + offsetSeconds).round();
    final now = _client._now().millisecondsSinceEpoch ~/ 1000;
    if (epoch >= now - liveEdgeSlackSeconds) return _liveUrl;
    final start = DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
    final url = _client.catchupUrlOf(channel, start);
    appLogger.i(
      '[iptv] catch-up from ${((now - epoch) / 60).round()} min ago ${url == null ? 'unavailable' : 'opened'}',
    );
    return url;
  }

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) async {
    if (state == 'playing') _attempts = 0;
    final window = captureBuffer;
    return window == null ? null : LiveTimelineUpdate(captureBuffer: window);
  }

  @override
  Future<void> discard() async {}

  /// Reconnect with back-off: wait, check the address answers, and hand the
  /// same session back for the player to reopen.
  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) async {
    for (final delay in reconnectDelays) {
      _attempts++;
      await Future<void>.delayed(delay);
      if (await _answers()) {
        appLogger.i('[iptv] stream answers again after $_attempts attempt(s)');
        return this;
      }
      appLogger.w('[iptv] stream still down (attempt $_attempts)');
    }
    return this;
  }

  Future<bool> _answers() async {
    final uri = Uri.tryParse(_liveUrl);
    if (uri == null || !uri.scheme.startsWith('http')) return true;
    final request = http.Request('GET', uri)..headers.addAll(streamHeaders);
    try {
      final response = await _client._http.send(request).timeout(const Duration(seconds: 8));
      unawaited(response.stream.listen((_) {}).cancel());
      return response.statusCode < 400;
    } catch (_) {
      return false;
    }
  }
}

/// Bumped whenever a source's stored data changes (refresh, the user's
/// channel or group changes), so cached channel lists are rebuilt.
class IptvDataRevision {
  IptvDataRevision._();

  static final Map<String, int> _revisions = {};

  /// Notifies every listener after any source changed.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  /// Notifies after favourites changed (Home's Live TV row).
  static final ValueNotifier<int> favorites = ValueNotifier(0);

  static int of(String sourceId) => _revisions[sourceId] ?? 0;

  static void bump(String sourceId) {
    _revisions[sourceId] = of(sourceId) + 1;
    changes.value++;
  }

  static void bumpFavorites() => favorites.value++;
}
