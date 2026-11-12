part of 'silo_client.dart';

/// Series-wide audio and subtitle memory (Silo Android #680): a Silo episode
/// starts with the server's effective choice for its series, and a viewer's
/// own pick in the player is written back to the series' preferences.
/// Movies start with the profile's effective tracks too (no series pick to
/// lay over them); extras and other backends are untouched. See [SiloTrackPrefs].
mixin _SiloTrackPrefsMethods on MediaServerCacheMixin, _SiloPlaybackMethods {
  @override
  late final SiloSeriesTrackChoices _trackChoices = SiloSeriesTrackChoices(
    send: (path, body) async {
      final response = await _api.request('PUT', path, body: body, timeout: const Duration(seconds: 10));
      throwIfHttpError(response);
    },
  );

  /// The sink the player hands explicit picks for [itemId] to. A pick made
  /// while no session of that item is known, or on an item that is not an
  /// episode, is ignored.
  SourceTrackPickSink seriesTrackPickSink(String itemId) => _SiloSeriesTrackPickSink(this, itemId);

  _SiloPlaybackSession? _latestSession(String itemId) {
    _SiloPlaybackSession? latest;
    for (final session in _sessions.values) {
      if (session.itemId == itemId) latest = session;
    }
    return latest;
  }

  void _recordAudioPick(String itemId, int sourceAudioId) {
    final session = _latestSession(itemId);
    final seriesKey = session?.seriesKey;
    if (session == null || seriesKey == null) return;
    final ordinal = sourceAudioId - 1;
    if (ordinal < 0 || ordinal >= session.audioTracks.length) return;
    _trackChoices.saveAudio(seriesKey, SiloTrackPrefs.audioBody(session.audioTracks[ordinal], ordinal));
  }

  void _recordSubtitlePick(String itemId, int? sourceSubtitleId) {
    final session = _latestSession(itemId);
    final seriesKey = session?.seriesKey;
    if (session == null || seriesKey == null) return;
    if (sourceSubtitleId == null) {
      _trackChoices.saveSubtitle(seriesKey, SiloTrackPrefs.subtitleOffBody());
      return;
    }
    final row = session.subtitleInventory.where((r) => _inventoryTrackId(r) == sourceSubtitleId).firstOrNull;
    // A track this session does not list (a stored subtitle the next reload
    // adds) cannot be described yet.
    if (row == null || SiloSubtitleRules.isUnplayable(row)) return;
    _trackChoices.saveSubtitle(seriesKey, SiloTrackPrefs.subtitleBody(row));
  }

  /// The player's `MediaSubtitleTrack.id` for an inventory row (see
  /// `getPlaybackInitialization`): a stored subtitle's stable id, else its
  /// `combined_index` + 1.
  static int? _inventoryTrackId(Map<dynamic, dynamic> row) {
    if (row['source']?.toString() == 'downloaded') {
      final storedId = SiloSubtitleRules.storedId(row);
      final id = storedId == null ? null : SiloSubtitleRules.storedTrackId(storedId);
      if (id != null) return id;
    }
    final index = (row['combined_index'] as num?)?.toInt();
    return index == null ? null : SiloMappers.trackId(index);
  }

  /// The audio ordinal an episode's original-file playback should mark as
  /// selected when the viewer asked for none: an unsent pick for the series
  /// resolved on this version, else the plan's own choice, else the version's
  /// `effective_audio_track_index`. Other deliveries keep the server's
  /// choice (the server already applies the series preference when it
  /// builds the stream, and asking for a non-default track there could only
  /// change the delivery).
  @override
  int? _seriesStartAudio({
    required String? seriesKey,
    required bool applies,
    required Map<String, dynamic> version,
    required bool isOriginal,
    required int? planSelected,
  }) {
    if (!applies || !isOriginal) return planSelected;
    final pending = seriesKey == null ? null : _trackChoices.pendingAudio(seriesKey);
    final tracks = version['audio_tracks'];
    if (pending != null && tracks is List) {
      final resolved = SiloTrackPrefs.resolveAudioBody(pending, tracks);
      if (resolved != null) return resolved;
    }
    return planSelected ?? SiloTrackPrefs.effectiveAudioOrdinal(version);
  }

  /// The subtitle an episode starts with. [candidates] are the inventory
  /// rows this playback can show, each with the id its picker row has.
  @override
  SiloSubtitleStart _seriesStartSubtitle({
    required String? seriesKey,
    required Map<String, dynamic>? watch,
    required List<SiloSubtitleCandidate> candidates,
    required Object? audioLanguage,
  }) {
    final prefs = SiloTrackPrefs.subtitlePrefs(
      watch,
      pending: seriesKey == null ? null : _trackChoices.pendingSubtitle(seriesKey),
    );
    final start = SiloTrackPrefs.resolveSubtitle(candidates, prefs, audioLanguage: audioLanguage);
    appLogger.d('Silo profile subtitle start: $start (mode=${prefs.mode ?? '-'})');
    return start;
  }

  /// [info] with [start] applied: the chosen row marked as the server's
  /// selection, or `defaultSubtitleStreamIndex: -1` for "start off".
  @override
  MediaSourceInfo _applySubtitleStart(MediaSourceInfo info, SiloSubtitleStart start) {
    if (start.isNoChange) return info;
    final trackId = start.trackId;
    if (trackId != null) {
      if (!info.subtitleTracks.any((t) => t.id == trackId)) return info;
      return info.copyWith(subtitleTracks: [for (final t in info.subtitleTracks) t.withSelected(t.id == trackId)]);
    }
    return MediaSourceInfo(
      videoUrl: info.videoUrl,
      audioTracks: info.audioTracks,
      subtitleTracks: [for (final t in info.subtitleTracks) t.selected ? t.withSelected(false) : t],
      chapters: info.chapters,
      partId: info.partId,
      displayCriteria: info.displayCriteria,
      mediaSourceId: info.mediaSourceId,
      mediaIndex: info.mediaIndex,
      partIndex: info.partIndex,
      partTimeline: info.partTimeline,
      defaultAudioStreamIndex: info.defaultAudioStreamIndex,
      defaultSubtitleStreamIndex: -1,
      trickplayByWidth: info.trickplayByWidth,
      videoAspectRatio: info.videoAspectRatio,
    );
  }
}

class _SiloSeriesTrackPickSink implements SourceTrackPickSink {
  _SiloSeriesTrackPickSink(this._client, this._itemId);

  final _SiloTrackPrefsMethods _client;
  final String _itemId;

  @override
  void audioPicked(int sourceAudioId) {
    try {
      _client._recordAudioPick(_itemId, sourceAudioId);
    } catch (e) {
      appLogger.d('Silo series audio pick not recorded', error: e.runtimeType);
    }
  }

  @override
  void subtitlePicked(int? sourceSubtitleId) {
    try {
      _client._recordSubtitlePick(_itemId, sourceSubtitleId);
    } catch (e) {
      appLogger.d('Silo series subtitle pick not recorded', error: e.runtimeType);
    }
  }
}
