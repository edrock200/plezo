part of 'tofa_client.dart';

/// Which address this client talks to: the one the person entered, or one
/// of the candidates Tofa's cloud lists for the server (`connection-info`),
/// raced as Tofa's own apps do: local first, then direct, then the relay,
/// each after its `stagger_ms`, the first that answers winning. When the
/// current address stops answering the race runs again.
///
/// Probe: `GET /api/v1/auth/status` (no credentials), which must name this
/// server's id when it names one. Through the relay the same API answers at
/// `{cloud}/servers/{id}/relay/api/v1/...`; the bearer goes as usual, and
/// stream URLs carry their `st`.
extension _TofaConnect on TofaClient {
  static const _infoFreshness = Duration(minutes: 5);
  static const _probeTimeout = Duration(seconds: 6);

  /// `GET {cloud}/servers/{id}/connection-info` with the server token ("any
  /// account token works", Tofa's guide), cached a few minutes. Null when
  /// the cloud cannot be read.
  Future<TofaConnectionInfo?> _connectionInfo() async {
    final known = _connectionInfoCache;
    if (known != null && DateTime.now().difference(known.at) < _infoFreshness) return known.info;
    if (connection.connectUrl.isEmpty || connection.serverId.isEmpty) return null;
    try {
      final response = await _api.getAbsolute(
        '${connection.connectUrl}/servers/${TofaClient._seg(connection.serverId)}/connection-info',
        timeout: const Duration(seconds: 8),
      );
      if (response.statusCode != 200) {
        appLogger.d('[tofa] connection-info answered ${response.statusCode}');
        return known?.info;
      }
      final info = TofaConnectionInfo.fromJson(response.data);
      if (info != null) _connectionInfoCache = (at: DateTime.now(), info: info);
      appLogger.d('[tofa] connection-info candidates=${info?.candidates.map((c) => c.kind.name).join(',')}');
      return info;
    } catch (e) {
      appLogger.d('[tofa] connection-info unavailable', error: e.runtimeType);
      return known?.info;
    }
  }

  /// The candidates in race order: the entered address first, then the
  /// cloud's list as given (lan-direct, wan-direct, relay); when the cloud
  /// lists no relay, the documented relay base is added last.
  List<TofaEndpointCandidate> _candidates(TofaConnectionInfo? info) {
    final cloud = info?.candidates ?? const <TofaEndpointCandidate>[];
    final typed = connection.baseUrl;
    final hasRelay = cloud.any((c) => c.kind == TofaEndpointKind.relay);
    final lastStagger = cloud.isEmpty ? Duration.zero : cloud.last.stagger;
    return [
      if (typed.isNotEmpty) TofaEndpointCandidate(url: typed, kind: TofaEndpointKind.typed),
      ...cloud,
      if (!hasRelay && connection.connectUrl.isNotEmpty && connection.serverId.isNotEmpty)
        TofaEndpointCandidate(
          url: tofaRelayUrl(connection.connectUrl, connection.serverId),
          kind: TofaEndpointKind.relay,
          stagger: lastStagger + const Duration(milliseconds: 300),
        ),
    ];
  }

  Future<bool> _probe(TofaEndpointCandidate candidate) async {
    try {
      final response = await _api.getAbsolute(
        '${candidate.url}/api/v1/auth/status',
        bearer: false,
        timeout: _probeTimeout,
      );
      if (response.statusCode != 200 || response.data is! Map) return false;
      final id = (response.data as Map)['server_id'];
      return id == null || id == connection.serverId;
    } catch (_) {
      return false;
    }
  }

  /// Run the race once (one race in flight); keeps the current address when
  /// nothing answers.
  Future<void> _selectEndpoint({required String reason}) {
    return _endpointRace ??= () async {
      try {
        final info = await _connectionInfo();
        final winner = await raceTofaEndpoints(_candidates(info), _probe, wait: _raceWait);
        if (winner == null) {
          appLogger.i('[tofa] no address answered ($reason); keeping the current one');
          return;
        }
        final changed = winner.url != _api.baseUrl;
        _api.baseUrl = winner.url;
        _endpointKind = winner.kind;
        appLogger.i('[tofa] connected via ${winner.kind.name}${changed ? ' (switched)' : ''} ($reason)');
      } finally {
        _endpointRace = null;
      }
    }();
  }

  /// The current address stopped answering: look again, at most every
  /// [TofaClient.failoverInterval].
  void _onUnreachable() {
    final last = _lastFailover;
    if (_closed || (last != null && DateTime.now().difference(last) < TofaClient.failoverInterval)) return;
    _lastFailover = DateTime.now();
    unawaited(_selectEndpoint(reason: 'failover'));
  }
}
