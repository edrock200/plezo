part of 'iptv_client.dart';

/// Recording on the device ([IptvRecorder]), offered through the shared DVR
/// screens:
/// - "Record episode" on a guide programme schedules that airing.
/// - "Record series" makes a rule ([IptvRecordingRule]): every airing with the
///   same title on that channel (or any channel), new episodes only if the
///   guide marks them, keeping the latest N. Rules are expanded into scheduled
///   recordings when made or edited, after every guide refresh and at
///   start-up ([IptvClientRules.expandRecordingRules]).
/// - The Recordings tab lists scheduled and running recordings (cancel), the
///   rules (edit, delete) and the finished recordings
///   ([LiveTvRecordedItems]), which play from their file.
class _IptvDvr implements LiveTvDvrSupport {
  _IptvDvr(this._client);
  final IptvClient _client;

  static const _airingPrefix = 'iptv-airing:';
  static const recordingPrefix = 'iptvrec:';
  static const rulePrefix = 'iptvrule:';

  static const _newOnly = 'new_only';
  static const _anyChannel = 'any_channel';
  static const _keepLast = 'keep_last';

  static String airingGuid(String channelId, int start, int stop) => '$_airingPrefix$start/$stop/$channelId';

  static ({String channelId, int start, int stop})? parseAiring(String guid) {
    if (!guid.startsWith(_airingPrefix)) return null;
    final parts = guid.substring(_airingPrefix.length).split('/');
    if (parts.length < 3) return null;
    final start = int.tryParse(parts[0]);
    final stop = int.tryParse(parts[1]);
    final channel = parts.sublist(2).join('/');
    if (start == null || stop == null || channel.isEmpty) return null;
    return (channelId: channel, start: start, stop: stop);
  }

  static String? _strip(String key, String prefix) =>
      key.startsWith(prefix) && key.length > prefix.length ? key.substring(prefix.length) : null;

  @override
  Future<List<LiveTvDvr>> fetchDvrs() async => const [];

  @override
  Future<void> reloadGuide(String dvrId) async {}

  @override
  bool get supportsRuleProcessing => false;

  @override
  Future<void> processRecordingRules() async => throw UnsupportedError('IPTV rules expand on every guide refresh.');

  List<SubscriptionSetting> _ruleSettings({bool newOnly = false, bool anyChannel = false, int keepLast = 0}) => [
    SubscriptionSetting(id: _newOnly, label: t.liveTv.recordSettings.newOnly, type: 'bool', value: newOnly),
    SubscriptionSetting(id: _anyChannel, label: t.liveTv.recordSettings.anyChannel, type: 'bool', value: anyChannel),
    SubscriptionSetting(
      id: _keepLast,
      label: t.liveTv.recordSettings.keepUpTo,
      summary: t.liveTv.recordSettings.keepUpToHint,
      type: 'int',
      value: keepLast,
      minimum: 0,
    ),
  ];

  @override
  Future<List<SubscriptionTemplate>> getSubscriptionTemplate(String guid) async {
    final airing = parseAiring(guid);
    if (airing == null) return const [];
    // Only programmes that have not ended can be recorded.
    if (airing.stop <= _client._now().millisecondsSinceEpoch ~/ 1000) return const [];
    return [
      SubscriptionTemplate(
        subscriptions: [
          MediaSubscription(
            key: '',
            type: MediaSubscription.typeEpisode,
            title: t.liveTv.recordEpisode,
            selected: true,
            parameters: guid,
          ),
          MediaSubscription(
            key: '',
            type: MediaSubscription.typeSeries,
            title: t.liveTv.recordSeries,
            parameters: guid,
            settings: _ruleSettings(),
          ),
        ],
      ),
    ];
  }

  Future<({IptvShownChannel? channel, IptvProgramme? programme})> _airingDetails(
    ({String channelId, int start, int stop}) airing,
  ) async {
    final shown = await _client._shownChannel(airing.channelId) ?? await _client._anyChannel(airing.channelId);
    final programme = (await _client.schedule(
      DateTime.fromMillisecondsSinceEpoch(airing.start * 1000),
      DateTime.fromMillisecondsSinceEpoch(airing.stop * 1000),
    )).where((r) => r.channel.channel.id == airing.channelId && r.programme.start == airing.start).firstOrNull;
    return (channel: shown, programme: programme?.programme);
  }

  @override
  Future<MediaSubscription?> createRecordingRule(MediaSubscriptionCreateRequest request) async {
    final airing = request.parameters == null ? null : parseAiring(request.parameters!);
    if (airing == null) throw ArgumentError.value(request.parameters, 'request.parameters', 'missing the airing');
    final details = await _airingDetails(airing);
    if (request.type == MediaSubscription.typeSeries) {
      final title = details.programme?.title;
      if (title == null || title.trim().isEmpty) {
        throw const RecordingConflictException('This programme has no title to record as a series');
      }
      final keep = flexibleInt(request.prefs[_keepLast]) ?? 0;
      final rule = IptvRecordingRule(
        id: IptvRecorder.newId(),
        sourceId: _client.connection.id,
        title: title,
        channelId: airing.channelId,
        channelName: details.channel?.channel.name,
        anyChannel: request.prefs[_anyChannel] == true,
        newOnly: request.prefs[_newOnly] == true,
        keepLast: keep < 0 ? 0 : keep,
        createdAt: _client._now().millisecondsSinceEpoch ~/ 1000,
      );
      await _client.store.putRule(rule);
      final scheduled = await _client.expandRecordingRules();
      appLogger.i('[iptv] series rule made; $scheduled airing(s) scheduled');
      return null;
    }
    try {
      await IptvRecorder.instance.schedule(
        sourceId: _client.connection.id,
        channelId: airing.channelId,
        channelName: details.channel?.channel.name,
        title: details.programme?.title ?? details.channel?.channel.name ?? t.liveTv.title,
        start: airing.start,
        stop: airing.stop,
        episode: details.programme == null ? null : IptvClientRules.episodeKey(details.programme!),
      );
    } on IptvRecordingExistsException {
      throw const RecordingConflictException('This programme is already set to record');
    }
    return null;
  }

  @override
  Future<MediaSubscription?> updateRecordingRule(
    String subscriptionId,
    Map<String, Object?> prefs, {
    void Function()? checkCurrent,
  }) async {
    final id = _strip(subscriptionId, rulePrefix);
    if (id == null) throw ArgumentError.value(subscriptionId, 'subscriptionId', 'expected an IPTV rule key');
    final rule = (await _client.store.rules(sourceId: _client.connection.id)).where((r) => r.id == id).firstOrNull;
    if (rule == null) return null;
    checkCurrent?.call();
    final keep = prefs.containsKey(_keepLast) ? flexibleInt(prefs[_keepLast]) : null;
    final updated = rule.copyWith(
      newOnly: prefs[_newOnly] is bool ? prefs[_newOnly] as bool : null,
      anyChannel: prefs[_anyChannel] is bool ? prefs[_anyChannel] as bool : null,
      keepLast: keep == null ? null : (keep < 0 ? 0 : keep),
    );
    await _client.store.putRule(updated);
    // What the rule scheduled before may no longer match: schedule afresh.
    await _cancelScheduled(id);
    await _client.expandRecordingRules();
    await IptvRecorder.instance.enforceKeepLast(updated);
    return _subscription(updated, await _grabsByRule());
  }

  Future<void> _cancelScheduled(String ruleId) async {
    for (final r in await _client.store.recordings(sourceId: _client.connection.id)) {
      if (r.ruleId == ruleId && r.state == IptvRecordingState.scheduled) {
        await IptvRecorder.instance.deleteRecording(r.id);
      }
    }
  }

  @override
  Future<void> deleteRecordingRule(String subscriptionId) async {
    final id = _strip(subscriptionId, rulePrefix);
    if (id == null) return cancelGrab(subscriptionId);
    await _cancelScheduled(id);
    await _client.store.deleteRule(id);
    appLogger.i('[iptv] series rule deleted');
  }

  @override
  Future<void> cancelGrab(String operationId) async {
    final id = _strip(operationId, recordingPrefix) ?? operationId;
    await IptvRecorder.instance.cancel(id);
  }

  @override
  Future<List<MediaSubscription>> fetchSubscriptionMapping({
    required String providerId,
    required List<String> ratingKeys,
    bool includeStorage = true,
  }) async => const [];

  MediaGrabOperation _grab(IptvRecordingRow r) => MediaGrabOperation(
    id: '$recordingPrefix${r.id}',
    status: r.state == IptvRecordingState.recording ? 'grabbing' : 'scheduled',
    currentSize: r.bytes,
    metadata: {
      'title': r.title,
      'beginsAt': r.start,
      'endsAt': r.stop,
      'channelIdentifier': r.channelId,
      'channelCallSign': r.channelName,
      'subscriptionID': '$recordingPrefix${r.id}',
      if (r.ruleId != null) 'grandparentSubscriptionID': '$rulePrefix${r.ruleId}',
    },
  );

  Future<List<IptvRecordingRow>> _pending() async => [
    for (final r in await _client.store.recordings(sourceId: _client.connection.id))
      if (r.state == IptvRecordingState.scheduled || r.state == IptvRecordingState.recording) r,
  ];

  Future<Map<String, List<MediaGrabOperation>>> _grabsByRule() async {
    final out = <String, List<MediaGrabOperation>>{};
    for (final r in await _pending()) {
      final rule = r.ruleId;
      if (rule != null) out.putIfAbsent(rule, () => []).add(_grab(r));
    }
    return out;
  }

  MediaSubscription _subscription(IptvRecordingRule rule, Map<String, List<MediaGrabOperation>> grabs) =>
      MediaSubscription(
        key: '$rulePrefix${rule.id}',
        type: MediaSubscription.typeSeries,
        title: rule.anyChannel || rule.channelName == null ? rule.title : '${rule.title} · ${rule.channelName}',
        settings: _ruleSettings(newOnly: rule.newOnly, anyChannel: rule.anyChannel, keepLast: rule.keepLast),
        grabOperations: grabs[rule.id] ?? const [],
      );

  @override
  Future<List<MediaGrabOperation>> fetchScheduledRecordings() async => [for (final r in await _pending()) _grab(r)];

  @override
  Future<List<MediaSubscription>> fetchRecordingRules({bool includeGrabs = true, bool includeStorage = true}) async {
    final rules = await _client.store.rules(sourceId: _client.connection.id);
    if (rules.isEmpty) return const [];
    final grabs = includeGrabs ? await _grabsByRule() : const <String, List<MediaGrabOperation>>{};
    return [for (final rule in rules) _subscription(rule, grabs)];
  }
}

/// Series rules: turning each rule into scheduled recordings.
extension IptvClientRules on IptvClient {
  /// What makes two airings the same episode: the guide's episode number,
  /// else the sub-title, else (no way to tell) the start time.
  static String episodeKey(IptvProgramme p) {
    final episode = p.episode?.trim();
    if (episode != null && episode.isNotEmpty) return 'ep:${episode.toLowerCase()}';
    final sub = p.subTitle?.trim();
    if (sub != null && sub.isNotEmpty) return 'sub:${sub.toLowerCase()}';
    return 'at:${p.start}';
  }

  /// Schedule every airing the rules of this source match in the stored
  /// guide that is not scheduled or recorded yet. Returns how many.
  Future<int> expandRecordingRules() async {
    final rules = await store.rules(sourceId: _connection.id);
    if (rules.isEmpty) return 0;
    final now = _now().millisecondsSinceEpoch ~/ 1000;
    final shown = await shownChannels();
    final byEpg = <String, List<IptvShownChannel>>{};
    for (final s in shown) {
      final epg = s.channel.epgChannelId;
      if (epg != null && epg.isNotEmpty) byEpg.putIfAbsent(epg, () => []).add(s);
    }
    final existing = await store.recordings(sourceId: _connection.id);
    var scheduled = 0;
    for (final rule in rules) {
      // Episodes this rule already has (a failed one may be tried again).
      final have = <String>{
        for (final r in existing)
          if (r.ruleId == rule.id && r.state != IptvRecordingState.failed && r.episode != null) r.episode!,
      };
      final booked = <String>{for (final r in existing) '${r.channelId}@${r.start}'};
      final candidates = <({IptvShownChannel channel, IptvProgramme programme})>[];
      for (final p in await store.programmesTitled(_connection.id, rule.title.toLowerCase(), from: now - 86400)) {
        for (final target in byEpg[p.epgChannelId] ?? const <IptvShownChannel>[]) {
          if (!rule.anyChannel && target.channel.id != rule.channelId) continue;
          final shifted = p.shifted(_shiftSeconds(target.channel));
          if (shifted.stop <= now) continue;
          if (rule.newOnly && !p.isNew) continue;
          candidates.add((channel: target, programme: shifted));
        }
      }
      candidates.sort((a, b) => a.programme.start.compareTo(b.programme.start));
      for (final c in candidates) {
        final key = episodeKey(c.programme);
        final slot = '${c.channel.channel.id}@${c.programme.start}';
        // Any channel: the first airing of an episode wins.
        if (have.contains(key) || booked.contains(slot)) continue;
        try {
          await IptvRecorder.instance.schedule(
            sourceId: _connection.id,
            channelId: c.channel.channel.id,
            channelName: c.channel.channel.name,
            title: c.programme.subTitle == null ? c.programme.title : '${c.programme.title}: ${c.programme.subTitle}',
            start: c.programme.start,
            stop: c.programme.stop,
            ruleId: rule.id,
            episode: key,
          );
          have.add(key);
          booked.add(slot);
          scheduled++;
        } on IptvRecordingExistsException {
          booked.add(slot);
        }
      }
    }
    if (scheduled > 0) appLogger.i('[iptv] series rules scheduled $scheduled airing(s)');
    return scheduled;
  }

  Future<MediaItem?> _recordingItem(String recordingId) async {
    final row = (await store.recordings(sourceId: _connection.id)).where((r) => r.id == recordingId).firstOrNull;
    if (row == null || row.path == null) return null;
    return MediaItem.iptv(
      id: IptvRecordingId(recordingId).toString(),
      kind: MediaKind.movie,
      title: row.title,
      summary: row.channelName,
      durationMs: (row.stop - row.start) * 1000,
      addedAt: row.start,
      serverId: serverId.value,
      serverName: serverName,
      raw: {'recording': recordingId},
    );
  }
}
