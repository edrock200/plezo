import 'dart:async';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../utils/app_logger.dart';
import '../../utils/url_utils.dart';
import '../multi_server_manager.dart';
import 'silo_api.dart';
import 'silo_auth_service.dart';

/// "Edit" / "Sign in again" on a saved [SiloConnection]: a new address for the
/// same server, a new session for the same account and Silo profile, or a
/// sign-in that turned out to be another account or Silo profile.
///
/// A connection's id is `server/user/profile`, and the bindings (Plezilo
/// profiles), the cache scope and the download owner scope all hang off that
/// id. So a new session for the same user and Silo profile replaces the row in
/// place and keeps all of them; anything else is another connection and follows
/// the multi-account rules of `lib/profiles/silo_accounts.dart`.
enum SiloEditKind {
  /// Same server, user and Silo profile: the row is updated in place.
  sameConnection,

  /// The same account, another of its Silo profiles.
  otherProfile,

  /// Another account on the same server.
  otherAccount,
}

/// What saving [incoming] does to [edited].
SiloEditKind siloEditKind(SiloConnection edited, SiloConnection incoming) {
  if (incoming.id == edited.id) return SiloEditKind.sameConnection;
  if (incoming.userId == edited.userId) return SiloEditKind.otherProfile;
  return SiloEditKind.otherAccount;
}

/// Whether [server], probed at the address typed on the edit screen, is
/// [edited]'s server (`GET /api/v2/system/identity` `server_id`). Another
/// deployment at that address is refused: its accounts, ids and tokens have
/// nothing to do with the saved connection.
bool siloIsSameServer(SiloConnection edited, SiloServerInfo server) =>
    server.serverId.isNotEmpty && server.serverId == edited.serverId;

/// Whether [baseUrl] differs from where [edited] is saved.
bool siloAddressChanged(SiloConnection edited, String baseUrl) => edited.baseUrl != canonicalizeBaseUrl(baseUrl);

/// The tokens [connection] holds, for a best-effort logout.
SiloTokens siloTokensOf(SiloConnection connection) => SiloTokens(
  accessToken: connection.accessToken,
  refreshToken: connection.refreshToken,
  expiresAt: connection.accessTokenExpiresAt,
  lifetimeSeconds: connection.accessTokenLifetimeSeconds,
);

/// Saves the edits. Tokens go through [ConnectionRegistry.upsert], which
/// encrypts them with `CredentialVault`.
class SiloConnectionEditor {
  SiloConnectionEditor({required this.registry, required this.auth, this.serverManager});

  final ConnectionRegistry registry;
  final SiloAuthService auth;

  /// The live clients, when the app has them (not in widget tests).
  final MultiServerManager? serverManager;

  /// Save [baseUrl] as the address of connection [connectionId], keeping its
  /// session. Re-reads the stored row (the live client may have rotated the
  /// tokens since the screen opened) and writes it only if it did not change
  /// meanwhile, so a rotation landing at the same moment is never undone.
  Future<SiloConnection> changeAddress(String connectionId, String baseUrl) async {
    for (var attempt = 0; ; attempt++) {
      final current = await registry.get(connectionId);
      if (current is! SiloConnection) throw StateError('The Silo connection is gone');
      final next = current.copyWith(baseUrl: baseUrl);
      try {
        await registry.upsert(next, expected: current);
        appLogger.i('[silo-edit] address changed for ${current.serverName}');
        return next;
      } on StateError {
        if (attempt >= 2) rethrow;
      }
    }
  }

  /// Save [updated], a new session for an existing connection id (the same
  /// server, user and Silo profile), in place of the stored row: the id, the
  /// creation time, every binding and the download scope stay as they are.
  ///
  /// The replaced session is revoked on the server, best effort, with its own
  /// (old) tokens only: through the live client when there is one (it holds
  /// the newest of that session's rotated pairs, and leaving the manager first
  /// means it can no longer persist that session over the new row), else with
  /// the stored pair. The caller rebinds afterwards.
  Future<void> replaceSession(SiloConnection updated) async {
    final prior = await registry.get(updated.id);
    final replaced = prior is SiloConnection && prior.refreshToken != updated.refreshToken ? prior : null;
    if (replaced != null) {
      final manager = serverManager;
      if (manager != null) {
        manager.removeSiloConnection(replaced);
      } else {
        unawaited(auth.logout(_serverOf(replaced), siloTokensOf(replaced)));
      }
    }
    await registry.upsert(updated);
    appLogger.i(
      '[silo-edit] signed in again on ${updated.serverName}; ${replaced != null ? 'old session revoked' : 'no old session'}',
    );
  }

  static SiloServerInfo _serverOf(SiloConnection connection) =>
      SiloServerInfo(baseUrl: connection.baseUrl, serverId: connection.serverId, serverName: connection.serverName);
}
