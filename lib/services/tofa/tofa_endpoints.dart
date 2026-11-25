import 'dart:async';

/// Tofa's cloud service.
const tofaCloudUrl = 'https://api.tofa.tv';

/// How a device reaches a Tofa server (Tofa's guide "Local, direct, or
/// relay"): the server's own network, a port-forwarded or tunnelled path, or
/// Tofa's relay. [typed] is the address the person entered.
enum TofaEndpointKind {
  typed,
  lanDirect,
  wanDirect,
  relay;

  static TofaEndpointKind? fromWire(Object? type) => switch (type) {
    'lan-direct' => lanDirect,
    'wan-direct' => wanDirect,
    'relay' => relay,
    _ => null,
  };
}

/// One address to try, after [stagger].
class TofaEndpointCandidate {
  const TofaEndpointCandidate({required this.url, required this.kind, this.stagger = Duration.zero});

  final String url;
  final TofaEndpointKind kind;
  final Duration stagger;

  @override
  String toString() => 'TofaEndpointCandidate(${kind.name}, +${stagger.inMilliseconds} ms)';
}

/// `GET {cloud}/servers/{id}/connection-info` (documented in Tofa's API
/// guide, "Reach the server from anywhere"; not in the cloud OpenAPI
/// document, whose `HouseholdConnectionInfo` has the same shape): the
/// server's candidates, tried in order with their `stagger_ms`.
class TofaConnectionInfo {
  const TofaConnectionInfo({required this.candidates, required this.online, this.bandwidthLimit});

  final List<TofaEndpointCandidate> candidates;
  final bool online;

  /// `bandwidth_limit` (`HouseholdConnectionInfo`). Unverified: its unit is
  /// not documented, so Plezilo shows the relay notice and does not turn it
  /// into a bitrate cap.
  final int? bandwidthLimit;

  /// Candidates of known types, in the server's order, without the ones
  /// marked unavailable (unknown types are skipped, as the guide asks).
  static TofaConnectionInfo? fromJson(Object? data) {
    if (data is! Map) return null;
    final raw = data['candidates'];
    final candidates = <TofaEndpointCandidate>[];
    if (raw is List) {
      for (final c in raw.whereType<Map>()) {
        final kind = TofaEndpointKind.fromWire(c['type']);
        final url = c['url'];
        if (kind == null || url is! String || !url.startsWith('https://') && !url.startsWith('http://')) continue;
        if (c['available'] == false) continue;
        final stagger = c['stagger_ms'];
        candidates.add(
          TofaEndpointCandidate(
            url: url.endsWith('/') ? url.substring(0, url.length - 1) : url,
            kind: kind,
            stagger: Duration(milliseconds: stagger is int && stagger > 0 ? stagger : 0),
          ),
        );
      }
    }
    return TofaConnectionInfo(
      candidates: candidates,
      online: data['online'] != false,
      bandwidthLimit: data['bandwidth_limit'] is int ? data['bandwidth_limit'] as int : null,
    );
  }
}

/// The relay base of a server: `{cloud}/servers/{id}/relay`, to which the
/// normal API path is appended.
String tofaRelayUrl(String cloudUrl, String serverId) => '$cloudUrl/servers/${Uri.encodeComponent(serverId)}/relay';

/// Race [candidates]: each starts after its stagger, the first whose [probe]
/// answers true wins (a later answer is ignored). Null when every probe
/// failed. Duplicated addresses are tried once.
Future<TofaEndpointCandidate?> raceTofaEndpoints(
  List<TofaEndpointCandidate> candidates,
  Future<bool> Function(TofaEndpointCandidate candidate) probe, {
  Future<void> Function(Duration delay)? wait,
}) {
  final unique = <String>{};
  final list = [
    for (final c in candidates)
      if (unique.add(c.url)) c,
  ];
  if (list.isEmpty) return Future.value();
  final waitFor = wait ?? (d) => d == Duration.zero ? Future<void>.value() : Future<void>.delayed(d);
  final done = Completer<TofaEndpointCandidate?>();
  var pending = list.length;
  for (final candidate in list) {
    () async {
      try {
        await waitFor(candidate.stagger);
        if (done.isCompleted) return;
        final ok = await probe(candidate);
        if (ok && !done.isCompleted) done.complete(candidate);
      } catch (_) {
        // A failed probe is a lost race, nothing more.
      } finally {
        pending--;
        if (pending == 0 && !done.isCompleted) done.complete(null);
      }
    }();
  }
  return done.future;
}
