part of 'iptv_client.dart';

/// Recording on the device ([IptvRecorder]), offered through the shared DVR
/// screens: "Record" on a guide programme schedules that airing; the
/// Recordings tab lists scheduled and running recordings (cancel) and the
/// finished ones ([LiveTvRecordedItems]), which play from their file.
///
/// Only single airings are recorded: a series rule would need a guide match
/// by title on every refresh, which this first version leaves out.
class _IptvDvr implements LiveTvDvrSupport {
  _IptvDvr(this._client);
  final IptvClient _client;

  static const _airingPrefix = 'iptv-airing:';
  static const recordingPrefix = 'iptvrec:';

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

  @override
  Future<List<LiveTvDvr>> fetchDvrs() async => const [];

  @override
  Future<void> reloadGuide(String dvrId) async {}

  @override
  bool get supportsRuleProcessing => false;

  @override
  Future<void> processRecordingRules() async => throw UnsupportedError('IPTV has no recording rules.');

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
        ],
      ),
    ];
  }

  @override
  Future<MediaSubscription?> createRecordingRule(MediaSubscriptionCreateRequest request) async {
    final airing = request.parameters == null ? null : parseAiring(request.parameters!);
    if (airing == null) throw ArgumentError.value(request.parameters, 'request.parameters', 'missing the airing');
    final shown = await _client._shownChannel(airing.channelId) ?? await _client._anyChannel(airing.channelId);
    final programme = (await _client.schedule(
      DateTime.fromMillisecondsSinceEpoch(airing.start * 1000),
      DateTime.fromMillisecondsSinceEpoch(airing.stop * 1000),
    )).where((r) => r.channel.channel.id == airing.channelId && r.programme.start == airing.start).firstOrNull;
    try {
      await IptvRecorder.instance.schedule(
        sourceId: _client.connection.id,
        channelId: airing.channelId,
        channelName: shown?.channel.name,
        title: programme?.programme.title ?? shown?.channel.name ?? t.liveTv.title,
        start: airing.start,
        stop: airing.stop,
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
  }) async => throw UnsupportedError('IPTV has no recording rules.');

  @override
  Future<void> deleteRecordingRule(String subscriptionId) => cancelGrab(subscriptionId);

  @override
  Future<void> cancelGrab(String operationId) async {
    final id = operationId.startsWith(recordingPrefix) ? operationId.substring(recordingPrefix.length) : operationId;
    await IptvRecorder.instance.cancel(id);
  }

  @override
  Future<List<MediaSubscription>> fetchSubscriptionMapping({
    required String providerId,
    required List<String> ratingKeys,
    bool includeStorage = true,
  }) async => const [];

  @override
  Future<List<MediaGrabOperation>> fetchScheduledRecordings() async => [
    for (final r in await _client.store.recordings(sourceId: _client.connection.id))
      if (r.state == IptvRecordingState.scheduled || r.state == IptvRecordingState.recording)
        MediaGrabOperation(
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
          },
        ),
  ];

  @override
  Future<List<MediaSubscription>> fetchRecordingRules({bool includeGrabs = true, bool includeStorage = true}) async =>
      const [];
}

extension _IptvRecordings on IptvClient {
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
