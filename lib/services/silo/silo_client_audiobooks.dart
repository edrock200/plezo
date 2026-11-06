part of 'silo_client.dart';

/// Audio formats Plezy's player (mpv) plays, added to what a part's
/// playback start declares so the server serves the original file (Silo's
/// audiobook player asks for the original stream).
const _audiobookContainers = <String>[
  'mp3',
  'm4a',
  'm4b',
  'mp4',
  'aac',
  'adts',
  'flac',
  'ogg',
  'oga',
  'opus',
  'wav',
  'mka',
  'mkv',
  'webm',
  'mov',
];

extension SiloClientAudiobooks on SiloClient {
  /// The audiobook calls of this client, for [SiloAudiobookPlayer].
  SiloAudiobookBackend get audiobooks => SiloClientAudiobookBackend(this);
}

class SiloClientAudiobookBackend implements SiloAudiobookBackend {
  SiloClientAudiobookBackend(this._client);

  final SiloClient _client;

  @override
  Future<SiloAudiobookDetail> fetchAudiobook(String id) async {
    final data = await _client._api.getJson(
      '/api/v2/catalog/items/${Uri.encodeComponent(id)}',
      query: {'image_size': 'large'},
    );
    return SiloAudiobookDetail.parse(data, resolveUrl: _client._ctx.resolveUrl);
  }

  /// The playback start body for one part: client-owned progress (a part's
  /// position must never become the book's), the original stream, and audio
  /// containers on top of the video declaration. `start_position` stays 0:
  /// as for video, Plezy seeks to the part-local start itself.
  @visibleForTesting
  static Map<String, Object?> shapeStart(Map<String, Object?> body) {
    final out = Map<String, Object?>.from(body);
    out['progress_persistence'] = 'client';
    out['quality_preference'] = 'original';
    out.remove('bandwidth_cap_kbps');
    List<String> widen(Object? list) =>
        {...?(list as List?)?.map((e) => e.toString()), ..._audiobookContainers}.toList();
    final caps = Map<String, Object?>.from(out['client_capabilities']! as Map);
    caps['containers'] = widen(caps['containers']);
    out['client_capabilities'] = caps;
    final context = Map<String, Object?>.from(out['client_playback_context']! as Map);
    final deliveries = Map<String, Object?>.from(context['deliveries']! as Map);
    final original = deliveries['original_http'];
    if (original is Map) {
      deliveries['original_http'] = {
        ...Map<String, Object?>.from(original),
        'containers': widen(original['containers']),
      };
    }
    context['deliveries'] = deliveries;
    out['client_playback_context'] = context;
    return out;
  }

  @override
  Future<SiloAudiobookStream> startPart(String fileId, {required double localStartSeconds}) async {
    await _client._api.refreshTokensIfHalfSpent();
    final decision = await _client._startPlayback(
      fileId: fileId,
      preset: TranscodeQualityPreset.original,
      shapeBody: shapeStart,
    );
    if (decision['outcome'] != 'playable') {
      final terminal = decision['terminal'];
      final message = terminal is Map ? terminal['message']?.toString() : null;
      throw PlaybackException(
        message == null || message.isEmpty ? t.messages.playbackFailed : message,
        reason: PlaybackFailureReason.noPlayableSource,
      );
    }
    final plan = decision['playback_plan'];
    final stream = plan is Map ? plan['stream'] : null;
    final rawUrl = stream is Map ? stream['url']?.toString() : null;
    final sessionId = (decision['session_id'] ?? (plan is Map ? plan['session_id'] : null))?.toString();
    if (rawUrl == null || rawUrl.isEmpty || sessionId == null || sessionId.isEmpty) {
      throw PlaybackException(t.messages.playbackDataInvalid, reason: PlaybackFailureReason.invalidPlaybackData);
    }
    appLogger.i('Silo audiobook part started: delivery=${plan is Map ? plan['delivery'] : null}');
    return SiloAudiobookStream(
      sessionId: sessionId,
      installationId: decision['_installation_id'].toString(),
      fileId: fileId,
      url: _client._streamUrl(rawUrl),
      headers: _client.streamHeaders,
    );
  }

  @override
  Future<SiloAudiobookProgressAnswer> sendProgress(
    SiloAudiobookStream stream,
    double localSeconds, {
    required bool paused,
  }) async {
    stream.sequence++;
    try {
      final response = await _client._api.request(
        'POST',
        '/api/v2/playback/${Uri.encodeComponent(stream.sessionId)}/progress',
        body: {
          'installation_id': stream.installationId,
          'sequence': stream.sequence,
          'position': localSeconds < 0 ? 0 : localSeconds,
          'is_paused': paused,
        },
      );
      return SiloAudiobookProgressAnswer(response.statusCode, response.data);
    } catch (error) {
      appLogger.d('Silo audiobook progress failed', error: error.runtimeType);
      return const SiloAudiobookProgressAnswer(0);
    }
  }

  @override
  Future<void> stopPart(SiloAudiobookStream stream, double localSeconds) async {
    final stopId = stream.stopId ??= const Uuid().v4();
    try {
      await _client._api.request(
        'DELETE',
        '/api/v2/playback/${Uri.encodeComponent(stream.sessionId)}',
        body: {
          'installation_id': stream.installationId,
          'stop_id': stopId,
          'sequence': ++stream.sequence,
          'position': localSeconds < 0 ? 0 : localSeconds,
          'is_paused': true,
        },
      );
    } catch (error) {
      appLogger.d('Silo audiobook stop failed', error: error.runtimeType);
    }
  }

  @override
  Future<void> syncBookProgress(String bookId, double bookSeconds, double totalSeconds) async {
    if (bookSeconds <= 0) return;
    try {
      await _client._syncProgress(
        bookId,
        position: Duration(milliseconds: (bookSeconds * 1000).round()),
        duration: Duration(milliseconds: (totalSeconds * 1000).round()),
      );
    } catch (error) {
      appLogger.d('Silo audiobook progress sync failed', error: error.runtimeType);
    }
  }
}
