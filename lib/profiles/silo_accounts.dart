import '../connection/connection.dart';
import 'profile_connection.dart';

/// Several Silo accounts (or several Silo profiles of one account) on the same
/// server are separate [SiloConnection]s, each with its own id
/// (`server/user/profile`), tokens, client and cache scope. The server manager
/// keeps one active client per server id, so one Plezilo profile can use only
/// one of them at a time; the helpers below keep that choice explicit.

/// A Silo connection other than [incoming] that [joinRows] (one Plezilo
/// profile's rows) already bind to [incoming]'s server, or null.
SiloConnection? otherSiloConnectionOnServer({
  required SiloConnection incoming,
  required Iterable<ProfileConnection> joinRows,
  required Map<String, Connection> connectionsById,
}) {
  for (final row in joinRows) {
    if (row.connectionId == incoming.id) continue;
    if (connectionsById[row.connectionId] case final SiloConnection other when other.serverId == incoming.serverId) {
      return other;
    }
  }
  return null;
}

/// Who a Silo connection signs in as: the Silo profile, with the account's
/// username when the two differ.
String siloAccountLabel(SiloConnection connection) {
  final user = connection.userName;
  final profile = connection.profileName;
  if (profile.isEmpty) return user;
  if (user.isEmpty || profile == user) return profile;
  return '$profile ($user)';
}

/// Name for a new Plezilo profile holding [connection], unlike every name in
/// [takenNames]: the Silo profile name, then with the username, then with the
/// server name.
String newProfileNameForSiloConnection(SiloConnection connection, Iterable<String> takenNames) {
  final taken = {for (final name in takenNames) name.trim().toLowerCase()};
  bool free(String name) => name.isNotEmpty && !taken.contains(name.trim().toLowerCase());
  final base = connection.profileName.isNotEmpty
      ? connection.profileName
      : (connection.userName.isNotEmpty ? connection.userName : connection.serverName);
  final candidates = [
    base,
    siloAccountLabel(connection),
    '$base · ${connection.serverName}',
    '${siloAccountLabel(connection)} · ${connection.serverName}',
  ];
  for (final candidate in candidates) {
    if (free(candidate)) return candidate;
  }
  for (var n = 2; ; n++) {
    final candidate = '$base $n';
    if (free(candidate)) return candidate;
  }
}

/// Connection ids among one Plezilo profile's [joinRows] that are *not* bound
/// because another Silo connection to the same server wins: the default
/// binding first, then the most recently used, then the lowest id (the order
/// `DownloadManagerService._siloProfileScopeId` uses for the cache scope, so
/// browsing and offline data agree on the account).
Set<String> shadowedSiloConnectionIds(Iterable<ProfileConnection> joinRows, Map<String, Connection> connectionsById) {
  final byServer = <String, List<ProfileConnection>>{};
  for (final row in joinRows) {
    if (connectionsById[row.connectionId] case final SiloConnection silo) {
      byServer.putIfAbsent(silo.serverId, () => []).add(row);
    }
  }
  final shadowed = <String>{};
  for (final rows in byServer.values) {
    if (rows.length < 2) continue;
    rows.sort((a, b) {
      if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
      final used = (b.lastUsedAt?.millisecondsSinceEpoch ?? 0).compareTo(a.lastUsedAt?.millisecondsSinceEpoch ?? 0);
      return used != 0 ? used : a.connectionId.compareTo(b.connectionId);
    });
    shadowed.addAll(rows.skip(1).map((row) => row.connectionId));
  }
  return shadowed;
}
