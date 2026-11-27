part of 'iptv_client.dart';

/// The Xtream provider's own per-channel guide, read on demand.
///
/// `xmltv.php` is the guide of an Xtream login, but some panels fail it
/// (an error, a timeout, an HTML page, an empty guide) or leave channels out.
/// A channel the guide shows (grid rows on screen, the channel list, the mini
/// guide, the info banner) that has nothing stored around now has its listing
/// read from `player_api.php` (`get_simple_data_table`, else `get_short_epg`)
/// and stored under its [IptvChannel.guideKey], at most [maxConcurrent] at a
/// time and once per [freshFor]. Nothing waits for it: listeners of
/// [IptvDataRevision.guide] read again when rows arrive.
class _IptvGuideFallback {
  _IptvGuideFallback(this._client);
  final IptvClient _client;

  static const maxConcurrent = 4;
  static const freshFor = Duration(hours: 2);

  final Map<String, Future<bool>> _inFlight = {};
  final List<Completer<void>> _waiting = [];
  int _active = 0;
  int _filled = 0;
  Timer? _notify;

  Future<void> _slot() async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future;
    _active++;
  }

  void _release() {
    _active--;
    if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
  }

  /// Read [ch]'s guide from the provider when it is needed and not fresh.
  /// True when rows were stored.
  Future<bool> ensure(IptvChannel ch) {
    final api = _client._xtream;
    final streamId = ch.xtreamId;
    final key = ch.guideKey;
    if (api == null || streamId == null || key == null || _client._closed) return Future.value(false);
    return _inFlight[ch.id] ??= _ensure(api, ch, streamId, key).whenComplete(() {
      // (A block: returning the removed future would make it wait on itself.)
      _inFlight.remove(ch.id);
    });
  }

  Future<bool> _ensure(XtreamApi api, IptvChannel ch, String streamId, String key) async {
    final store = _client.store;
    final sourceId = _client._connection.id;
    final now = _client._now().millisecondsSinceEpoch ~/ 1000;
    final fetched = await store.guideFetchedAt(sourceId, ch.id);
    if (fetched != null && now - fetched < freshFor.inSeconds) return false;
    if (await store.hasProgrammes(sourceId, key, from: now, to: now + 3600)) return false;
    await _slot();
    try {
      if (_client._closed) return false;
      _client._serverOffset ??= (await _client.storedAccount())?.serverOffset;
      final offset = _client._serverOffset ?? Duration.zero;
      var entries = const <XtreamEpgEntry>[];
      try {
        entries = await api.simpleDataTable(streamId, serverOffset: offset);
      } on XtreamAuthException {
        rethrow;
      } catch (e) {
        appLogger.d('[iptv] channel guide table unavailable (${e.runtimeType}); trying the short guide');
      }
      if (entries.isEmpty) entries = await api.shortEpg(streamId, limit: 12, serverOffset: offset);
      final rows = [
        for (final e in entries)
          if (e.stop > e.start && e.title.isNotEmpty)
            IptvProgramme(epgChannelId: key, start: e.start, stop: e.stop, title: e.title, description: e.description),
      ];
      await store.putChannelProgrammes(sourceId, ch.id, key, rows, fetchedAt: now);
      if (rows.isEmpty) return false;
      _filled++;
      _notify ??= Timer(const Duration(milliseconds: 400), () {
        _notify = null;
        appLogger.i('[iptv] provider guide filled $_filled channel(s)');
        _filled = 0;
        IptvDataRevision.bumpGuide();
      });
      return true;
    } catch (e) {
      // Mark it read anyway: a failing provider is not asked again for 2 h.
      appLogger.d('[iptv] channel guide unavailable (${e.runtimeType})');
      await store.putChannelProgrammes(sourceId, ch.id, key, const [], fetchedAt: now).catchError((_) {});
      return false;
    } finally {
      _release();
    }
  }

  void close() {
    _notify?.cancel();
    for (final w in _waiting) {
      if (!w.isCompleted) w.complete();
    }
    _waiting.clear();
  }
}
