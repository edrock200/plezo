import '../media/media_backend.dart';
import '../media/media_browser_dialect.dart';
import '../models/plex/plex_home_user.dart';
import '../services/plex_auth_service.dart';
import '../utils/json_utils.dart';
import '../utils/url_utils.dart';

/// A media server connection — a unit of authentication the user added.
///
/// A `PlexAccountConnection` carries one Plex account + its discovered servers + an
/// optional active Home profile. A `JellyfinConnection` is a single server +
/// user. Most users only ever add one connection.
sealed class Connection {
  String get id;
  MediaBackend get kind;
  String get displayName;
  DateTime get createdAt;
  DateTime? get lastAuthenticatedAt;

  /// Alias for [kind] kept for UI call sites that read "backend"
  /// (badges, etc.).
  MediaBackend get backend => kind;

  /// Primary label shown in connection-list UIs. Plex shows the active
  /// profile/account name; Jellyfin shows the server name.
  String get displayLabel;

  /// Secondary line shown beneath [displayLabel] in connection-list UIs.
  /// Plex: server count; Jellyfin: `userName · baseUrl`. May be null when
  /// no useful subtitle exists.
  String? get displaySubtitle;

  /// Backend-specific config payload, persisted as JSON. Each subclass
  /// defines the schema.
  Map<String, Object?> toConfigJson();
}

/// A Plex account connection.
///
/// Fields here mirror what [PlexAuthService] gathers during PIN OAuth: an
/// account token (long-lived), the per-device client identifier (so plex.tv
/// doesn't see a "new device" each launch), and the optional Home user the
/// user has switched into.
class PlexAccountConnection extends Connection {
  @override
  final String id;

  @override
  final DateTime createdAt;

  @override
  final DateTime? lastAuthenticatedAt;

  /// plex.tv account access token.
  final String accountToken;

  /// Per-device client identifier. Stable across launches.
  final String clientIdentifier;

  /// Display name shown for this connection (typically the Plex account email
  /// or username, fallback "Plex").
  final String accountLabel;

  /// Active Home user, or `null` for the main account.
  final PlexHomeUser? activeProfile;

  /// Servers discovered for this account (cached). Populated by the auth
  /// flow and refreshed periodically.
  final List<PlexServer> servers;

  PlexAccountConnection({
    required this.id,
    required this.accountToken,
    required this.clientIdentifier,
    required this.accountLabel,
    this.activeProfile,
    this.servers = const [],
    required this.createdAt,
    this.lastAuthenticatedAt,
  });

  @override
  MediaBackend get kind => MediaBackend.plex;

  @override
  String get displayName => activeProfile != null && activeProfile!.title.isNotEmpty
      ? '${activeProfile!.title} · $accountLabel'
      : accountLabel;

  @override
  String get displayLabel => displayName;

  @override
  String? get displaySubtitle => servers.length == 1 ? '1 Plex server' : '${servers.length} Plex servers';

  PlexAccountConnection copyWith({
    String? id,
    String? accountToken,
    String? clientIdentifier,
    String? accountLabel,
    PlexHomeUser? activeProfile,
    bool clearActiveProfile = false,
    List<PlexServer>? servers,
    DateTime? createdAt,
    DateTime? lastAuthenticatedAt,
  }) {
    return PlexAccountConnection(
      id: id ?? this.id,
      accountToken: accountToken ?? this.accountToken,
      clientIdentifier: clientIdentifier ?? this.clientIdentifier,
      accountLabel: accountLabel ?? this.accountLabel,
      activeProfile: clearActiveProfile ? null : (activeProfile ?? this.activeProfile),
      servers: servers ?? this.servers,
      createdAt: createdAt ?? this.createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt ?? this.lastAuthenticatedAt,
    );
  }

  @override
  Map<String, Object?> toConfigJson() {
    return {
      'accountToken': accountToken,
      'clientIdentifier': clientIdentifier,
      'accountLabel': accountLabel,
      'activeProfile': activeProfile?.toJson(),
      'servers': servers.map((s) => s.toJson()).toList(),
    };
  }

  factory PlexAccountConnection.fromConfigJson({
    required String id,
    required Map<String, Object?> json,
    required DateTime createdAt,
    DateTime? lastAuthenticatedAt,
  }) {
    final profileJson = json['activeProfile'];
    final activeProfile = profileJson is Map<String, dynamic> ? PlexHomeUser.fromJson(profileJson) : null;
    final serversJson = json['servers'];
    final servers = serversJson is List
        ? serversJson.whereType<Map<String, dynamic>>().map(PlexServer.fromJson).toList()
        : <PlexServer>[];
    return PlexAccountConnection(
      id: id,
      accountToken: json['accountToken'] as String? ?? '',
      clientIdentifier: json['clientIdentifier'] as String? ?? '',
      accountLabel: json['accountLabel'] as String? ?? 'Plex',
      activeProfile: activeProfile,
      servers: servers,
      createdAt: createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt,
    );
  }
}

/// A single-server connection to a MediaBrowser-family server — Jellyfin or its
/// Emby ancestor. [dialect] selects which of the two wire dialects this
/// connection speaks; every other field has the same meaning on both.
class JellyfinConnection extends Connection {
  @override
  final String id;

  @override
  final DateTime createdAt;

  @override
  final DateTime? lastAuthenticatedAt;

  /// Which MediaBrowser dialect this server speaks. Drives [kind], [backend]
  /// and every route/capability delta in [JellyfinClient].
  final MediaBrowserDialect dialect;

  /// Active server base URL, no trailing slash. e.g. `https://jellyfin.home.lan`.
  final String baseUrl;

  /// Candidate server URLs for this server, with [baseUrl] first.
  /// Existing installs only have [baseUrl]; deserialization backfills this.
  final List<String> baseUrls;

  /// Server's reported name (System/Info).
  final String serverName;

  /// Server's machine identifier (System/Info `Id`).
  final String serverMachineId;

  /// Authenticated user id. A UUID on Jellyfin, an opaque hex string on Emby.
  final String userId;

  final String userName;

  /// Long-lived access token from `/Users/AuthenticateByName`.
  final String accessToken;

  /// Per-device client identifier (same value sent in the
  /// `Authorization: MediaBrowser DeviceId="..."` header).
  final String deviceId;

  /// Whether this user is a server admin (`/Users/{id}.Policy.IsAdministrator`).
  /// Captured at auth time so the UI can gate admin-only entries (delete,
  /// match/unmatch, edit metadata) without an extra round-trip.
  final bool isAdministrator;

  /// The authenticated user's `PrimaryImageTag`, or `null` when they have no
  /// profile picture. The server omits the key entirely in that case, and the
  /// tag is `MD5(imagePath + lastModified)` so it changes on every upload —
  /// which makes the derived avatar URL self-invalidating. Captured at auth
  /// time and refreshed by [JellyfinClient.checkHealth].
  final String? primaryImageTag;

  JellyfinConnection({
    required this.id,
    required String baseUrl,
    List<String>? baseUrls,
    required this.serverName,
    required this.serverMachineId,
    required this.userId,
    required this.userName,
    required this.accessToken,
    required this.deviceId,
    this.dialect = MediaBrowserDialect.jellyfin,
    this.isAdministrator = false,
    this.primaryImageTag,
    required this.createdAt,
    this.lastAuthenticatedAt,
  }) : baseUrl = canonicalizeBaseUrl(baseUrl),
       baseUrls = _normalizeBaseUrls(baseUrl, baseUrls);

  @override
  MediaBackend get kind => dialect.backend;

  @override
  String get displayName => '$userName · $serverName';

  @override
  String get displayLabel => serverName;

  @override
  String? get displaySubtitle {
    final extraCount = baseUrls.length - 1;
    final suffix = extraCount > 0 ? ' +$extraCount' : '';
    return '$userName · ${_truncateUrl(baseUrl)}$suffix';
  }

  static String _truncateUrl(String url) {
    if (url.length <= 40) return url;
    return '${url.substring(0, 37)}…';
  }

  static List<String> _normalizeBaseUrls(String activeBaseUrl, List<String>? urls) {
    final result = <String>[];
    final seen = <String>{};

    void add(String url) {
      final normalized = canonicalizeBaseUrl(url);
      if (normalized.isEmpty || !seen.add(normalized)) return;
      result.add(normalized);
    }

    add(activeBaseUrl);
    for (final url in urls ?? const <String>[]) {
      add(url);
    }
    return List.unmodifiable(result);
  }

  JellyfinConnection copyWith({
    String? id,
    String? baseUrl,
    List<String>? baseUrls,
    String? serverName,
    String? serverMachineId,
    String? userId,
    String? userName,
    String? accessToken,
    String? deviceId,
    MediaBrowserDialect? dialect,
    bool? isAdministrator,
    String? primaryImageTag,

    /// Deleting a profile picture drops `PrimaryImageTag` from the user DTO, so
    /// a refresh must be able to null the cached value — a bare
    /// `primaryImageTag: null` is indistinguishable from "unchanged".
    bool clearPrimaryImageTag = false,
    DateTime? createdAt,
    DateTime? lastAuthenticatedAt,
  }) {
    final nextBaseUrl = baseUrl ?? this.baseUrl;
    return JellyfinConnection(
      id: id ?? this.id,
      baseUrl: nextBaseUrl,
      baseUrls: baseUrls ?? this.baseUrls,
      serverName: serverName ?? this.serverName,
      serverMachineId: serverMachineId ?? this.serverMachineId,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      accessToken: accessToken ?? this.accessToken,
      deviceId: deviceId ?? this.deviceId,
      dialect: dialect ?? this.dialect,
      isAdministrator: isAdministrator ?? this.isAdministrator,
      primaryImageTag: clearPrimaryImageTag ? null : (primaryImageTag ?? this.primaryImageTag),
      createdAt: createdAt ?? this.createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt ?? this.lastAuthenticatedAt,
    );
  }

  /// The persisted payload deliberately omits [dialect]: the `connections.kind`
  /// column is the authoritative, indexed discriminator and
  /// [JellyfinConnection.fromConfigJson] receives it from there.
  @override
  Map<String, Object?> toConfigJson() {
    return {
      'baseUrl': baseUrl,
      'baseUrls': baseUrls,
      'serverName': serverName,
      'serverMachineId': serverMachineId,
      'userId': userId,
      'userName': userName,
      'accessToken': accessToken,
      'deviceId': deviceId,
      'isAdministrator': isAdministrator,
      'primaryImageTag': primaryImageTag,
    };
  }

  factory JellyfinConnection.fromConfigJson({
    required String id,
    required Map<String, Object?> json,
    required DateTime createdAt,
    DateTime? lastAuthenticatedAt,
    MediaBrowserDialect dialect = MediaBrowserDialect.jellyfin,
  }) {
    final rawBaseUrls = json['baseUrls'];
    final baseUrls = rawBaseUrls is List ? rawBaseUrls.whereType<String>().toList(growable: false) : const <String>[];
    final rawBaseUrl = json['baseUrl'] as String?;
    final baseUrl = rawBaseUrl != null && rawBaseUrl.isNotEmpty
        ? rawBaseUrl
        : (baseUrls.isNotEmpty ? baseUrls.first : '');
    return JellyfinConnection(
      id: id,
      baseUrl: baseUrl,
      baseUrls: baseUrls,
      dialect: dialect,
      serverName: json['serverName'] as String? ?? dialect.productName,
      serverMachineId: json['serverMachineId'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      userName: json['userName'] as String? ?? '',
      accessToken: json['accessToken'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
      isAdministrator: json['isAdministrator'] as bool? ?? false,
      primaryImageTag: normalizePrimaryImageTag(json['primaryImageTag']),
      createdAt: createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt,
    );
  }

  /// Tolerant read of a Jellyfin user DTO's `PrimaryImageTag`.
  ///
  /// The tag is decorative — a fork or a drifted scalar type must never brick
  /// sign-in — so this coerces through [readStringField] rather than casting,
  /// and collapses absent/blank to `null` ("no picture").
  static String? readPrimaryImageTag(Map<String, Object?> userDto) =>
      normalizePrimaryImageTag(readStringField(userDto, 'PrimaryImageTag'));

  static String? normalizePrimaryImageTag(Object? raw) {
    final tag = raw?.toString().trim();
    return tag == null || tag.isEmpty ? null : tag;
  }
}

/// A connection to a Silo server (`/api/v2`): one account signed in on one
/// server, bound to one of that account's Silo profiles.
///
/// Silo accounts own several profiles (like Plex Home users), and almost every
/// content route requires the `X-Profile-Id` header, so the chosen profile is
/// part of the connection's identity: two profiles of the same account are two
/// connections, each of which a Plezy profile can bind on its own.
///
/// Access tokens are short-lived and the refresh token rotates on every use,
/// so the client persists each refreshed pair back through the registry.
class SiloConnection extends Connection {
  @override
  final String id;

  @override
  final DateTime createdAt;

  @override
  final DateTime? lastAuthenticatedAt;

  /// Server base URL as the user entered it after normalisation, no trailing
  /// slash. May carry a reverse-proxy path prefix; API paths are appended.
  final String baseUrl;

  /// Friendly server name (`/api/v2/theme/branding`), or the host.
  final String serverName;

  /// Stable deployment id (`/api/v2/system/identity` `server_id`).
  final String serverId;

  final String userId;
  final String userName;

  /// Whether the account's role is `admin`.
  final bool isAdministrator;

  /// Bearer access token. Short-lived (`expires_in`, typically an hour).
  final String accessToken;

  /// Rotating refresh token. Every refresh returns a new one, which replaces
  /// this value; the old one stops working.
  final String refreshToken;

  /// When [accessToken] expires, or `null` when unknown.
  final DateTime? accessTokenExpiresAt;

  /// Seconds [accessToken] was valid for when issued (`expires_in`), or
  /// `null` when unknown. Kept so the "half spent" refresh before playback
  /// still knows the lifetime after a restart.
  final int? accessTokenLifetimeSeconds;

  /// Per-install device id sent as `X-Silo-Device-Id`.
  final String deviceId;

  /// The Silo profile this connection acts as (`X-Profile-Id`).
  final String profileId;
  final String profileName;

  /// Root-relative or absolute avatar URL from `/api/v2/profiles`.
  final String? profileAvatarUrl;

  /// `X-Profile-Token` from `verify-pin`, present only for PIN-locked
  /// profiles. Bound to the login session that minted it.
  final String? profileToken;

  final bool profileHasPin;

  SiloConnection({
    required this.id,
    required String baseUrl,
    required this.serverName,
    required this.serverId,
    required this.userId,
    required this.userName,
    required this.accessToken,
    required this.refreshToken,
    required this.deviceId,
    required this.profileId,
    required this.profileName,
    this.accessTokenExpiresAt,
    this.accessTokenLifetimeSeconds,
    this.isAdministrator = false,
    this.profileAvatarUrl,
    this.profileToken,
    this.profileHasPin = false,
    required this.createdAt,
    this.lastAuthenticatedAt,
  }) : baseUrl = canonicalizeBaseUrl(baseUrl);

  /// Compound connection id: one account's profile on one server.
  static String compoundId({required String serverId, required String userId, required String profileId}) =>
      '$serverId/$userId/$profileId';

  @override
  MediaBackend get kind => MediaBackend.silo;

  @override
  String get displayName => '$profileName · $serverName';

  @override
  String get displayLabel => serverName;

  @override
  String? get displaySubtitle {
    final who = profileName == userName ? userName : '$profileName ($userName)';
    final url = baseUrl.length <= 40 ? baseUrl : '${baseUrl.substring(0, 37)}…';
    return '$who · $url';
  }

  SiloConnection copyWith({
    String? baseUrl,
    String? serverName,
    String? userName,
    bool? isAdministrator,
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
    int? accessTokenLifetimeSeconds,
    String? profileName,
    String? profileAvatarUrl,
    String? profileToken,
    bool clearProfileToken = false,
    bool? profileHasPin,
    DateTime? lastAuthenticatedAt,
  }) {
    return SiloConnection(
      id: id,
      baseUrl: baseUrl ?? this.baseUrl,
      serverName: serverName ?? this.serverName,
      serverId: serverId,
      userId: userId,
      userName: userName ?? this.userName,
      isAdministrator: isAdministrator ?? this.isAdministrator,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
      accessTokenLifetimeSeconds: accessTokenLifetimeSeconds ?? this.accessTokenLifetimeSeconds,
      deviceId: deviceId,
      profileId: profileId,
      profileName: profileName ?? this.profileName,
      profileAvatarUrl: profileAvatarUrl ?? this.profileAvatarUrl,
      profileToken: clearProfileToken ? null : (profileToken ?? this.profileToken),
      profileHasPin: profileHasPin ?? this.profileHasPin,
      createdAt: createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt ?? this.lastAuthenticatedAt,
    );
  }

  @override
  Map<String, Object?> toConfigJson() {
    return {
      'baseUrl': baseUrl,
      'serverName': serverName,
      'serverId': serverId,
      'userId': userId,
      'userName': userName,
      'isAdministrator': isAdministrator,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'accessTokenExpiresAt': accessTokenExpiresAt?.millisecondsSinceEpoch,
      'accessTokenLifetimeSeconds': accessTokenLifetimeSeconds,
      'deviceId': deviceId,
      'profileId': profileId,
      'profileName': profileName,
      'profileAvatarUrl': profileAvatarUrl,
      'profileToken': profileToken,
      'profileHasPin': profileHasPin,
    };
  }

  factory SiloConnection.fromConfigJson({
    required String id,
    required Map<String, Object?> json,
    required DateTime createdAt,
    DateTime? lastAuthenticatedAt,
  }) {
    final expiresAtMs = flexibleInt(json['accessTokenExpiresAt']);
    final profileToken = json['profileToken'] as String?;
    return SiloConnection(
      id: id,
      baseUrl: json['baseUrl'] as String? ?? '',
      serverName: json['serverName'] as String? ?? 'Silo',
      serverId: json['serverId'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      userName: json['userName'] as String? ?? '',
      isAdministrator: json['isAdministrator'] as bool? ?? false,
      accessToken: json['accessToken'] as String? ?? '',
      refreshToken: json['refreshToken'] as String? ?? '',
      accessTokenExpiresAt: expiresAtMs == null ? null : DateTime.fromMillisecondsSinceEpoch(expiresAtMs),
      accessTokenLifetimeSeconds: flexibleInt(json['accessTokenLifetimeSeconds']),
      deviceId: json['deviceId'] as String? ?? '',
      profileId: json['profileId'] as String? ?? '',
      profileName: json['profileName'] as String? ?? '',
      profileAvatarUrl: json['profileAvatarUrl'] as String?,
      profileToken: profileToken == null || profileToken.isEmpty ? null : profileToken,
      profileHasPin: json['profileHasPin'] as bool? ?? false,
      createdAt: createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt,
    );
  }
}

/// One tofa account (or admin API key) on one tofa server, acting as one tofa
/// profile.
///
/// Signed in with tofa's device flow, [accessToken] is the server-scoped token
/// from `POST https://api.tofa.tv/servers/{id}/server-session` (about 30 days)
/// and [refreshToken] renews it through
/// `POST https://api.tofa.tv/servers/{id}/device-token/refresh`. Signed in with
/// an API key, [accessToken] is the `tofa_…` key and [refreshToken] is empty.
class TofaConnection extends Connection {
  @override
  final String id;

  @override
  final DateTime createdAt;

  @override
  final DateTime? lastAuthenticatedAt;

  /// The address Plezilo uses for the server: a LAN or direct URL, or the
  /// cloud relay `https://api.tofa.tv/servers/{id}/relay`. No trailing slash.
  final String baseUrl;

  /// Other addresses for the same server, tried when [baseUrl] stops
  /// answering (best first).
  final List<String> fallbackUrls;

  /// Friendly server name from the tofa account's server list, or the host.
  final String serverName;

  /// tofa server id (`/api/v1/auth/status` `server_id`).
  final String serverId;

  final String userId;
  final String userName;
  final bool isAdministrator;

  /// `Authorization: Bearer` value: the server-scoped token or an API key.
  final String accessToken;

  /// Server-scoped refresh token; empty for API keys. Rotates: always store
  /// the newest one before using it.
  final String refreshToken;

  final DateTime? accessTokenExpiresAt;

  /// True when [accessToken] is an admin API key (`tofa_…`) rather than a
  /// device-flow token. Keys never refresh and never work through the relay.
  final bool isApiKey;

  /// Per-install id sent as `X-Tofa-Device-Id`.
  final String deviceId;

  /// The tofa profile this connection acts as (`X-Profile-Id`); empty for the
  /// account's primary profile.
  final String profileId;
  final String profileName;
  final String? profileAvatarUrl;

  /// `X-Profile-Token` from `verify-pin` for a PIN-locked profile.
  final String? profileToken;
  final bool profileHasPin;

  TofaConnection({
    required this.id,
    required String baseUrl,
    this.fallbackUrls = const [],
    required this.serverName,
    required this.serverId,
    required this.userId,
    required this.userName,
    required this.accessToken,
    this.refreshToken = '',
    this.accessTokenExpiresAt,
    this.isApiKey = false,
    this.isAdministrator = false,
    required this.deviceId,
    this.profileId = '',
    this.profileName = '',
    this.profileAvatarUrl,
    this.profileToken,
    this.profileHasPin = false,
    required this.createdAt,
    this.lastAuthenticatedAt,
  }) : baseUrl = canonicalizeBaseUrl(baseUrl);

  /// Compound connection id: one account's profile on one server.
  static String compoundId({required String serverId, required String userId, required String profileId}) =>
      'tofa:$serverId/$userId/${profileId.isEmpty ? 'primary' : profileId}';

  @override
  MediaBackend get kind => MediaBackend.tofa;

  @override
  String get displayName => profileName.isEmpty ? serverName : '$profileName · $serverName';

  @override
  String get displayLabel => serverName;

  @override
  String? get displaySubtitle {
    final who = profileName.isEmpty || profileName == userName ? userName : '$profileName ($userName)';
    final url = baseUrl.length <= 40 ? baseUrl : '${baseUrl.substring(0, 37)}…';
    return who.isEmpty ? url : '$who · $url';
  }

  TofaConnection copyWith({
    String? baseUrl,
    List<String>? fallbackUrls,
    String? serverName,
    String? userName,
    bool? isAdministrator,
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
    String? profileName,
    String? profileAvatarUrl,
    String? profileToken,
    bool clearProfileToken = false,
    bool? profileHasPin,
    DateTime? lastAuthenticatedAt,
  }) {
    return TofaConnection(
      id: id,
      baseUrl: baseUrl ?? this.baseUrl,
      fallbackUrls: fallbackUrls ?? this.fallbackUrls,
      serverName: serverName ?? this.serverName,
      serverId: serverId,
      userId: userId,
      userName: userName ?? this.userName,
      isAdministrator: isAdministrator ?? this.isAdministrator,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
      isApiKey: isApiKey,
      deviceId: deviceId,
      profileId: profileId,
      profileName: profileName ?? this.profileName,
      profileAvatarUrl: profileAvatarUrl ?? this.profileAvatarUrl,
      profileToken: clearProfileToken ? null : (profileToken ?? this.profileToken),
      profileHasPin: profileHasPin ?? this.profileHasPin,
      createdAt: createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt ?? this.lastAuthenticatedAt,
    );
  }

  @override
  Map<String, Object?> toConfigJson() {
    return {
      'baseUrl': baseUrl,
      'fallbackUrls': fallbackUrls,
      'serverName': serverName,
      'serverId': serverId,
      'userId': userId,
      'userName': userName,
      'isAdministrator': isAdministrator,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'accessTokenExpiresAt': accessTokenExpiresAt?.millisecondsSinceEpoch,
      'isApiKey': isApiKey,
      'deviceId': deviceId,
      'profileId': profileId,
      'profileName': profileName,
      'profileAvatarUrl': profileAvatarUrl,
      'profileToken': profileToken,
      'profileHasPin': profileHasPin,
    };
  }

  factory TofaConnection.fromConfigJson({
    required String id,
    required Map<String, Object?> json,
    required DateTime createdAt,
    DateTime? lastAuthenticatedAt,
  }) {
    final expiresAtMs = flexibleInt(json['accessTokenExpiresAt']);
    final profileToken = json['profileToken'] as String?;
    final fallbacks = json['fallbackUrls'];
    return TofaConnection(
      id: id,
      baseUrl: json['baseUrl'] as String? ?? '',
      fallbackUrls: fallbacks is List ? fallbacks.whereType<String>().toList() : const [],
      serverName: json['serverName'] as String? ?? 'tofa',
      serverId: json['serverId'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      userName: json['userName'] as String? ?? '',
      isAdministrator: json['isAdministrator'] as bool? ?? false,
      accessToken: json['accessToken'] as String? ?? '',
      refreshToken: json['refreshToken'] as String? ?? '',
      accessTokenExpiresAt: expiresAtMs == null ? null : DateTime.fromMillisecondsSinceEpoch(expiresAtMs),
      isApiKey: json['isApiKey'] as bool? ?? false,
      deviceId: json['deviceId'] as String? ?? '',
      profileId: json['profileId'] as String? ?? '',
      profileName: json['profileName'] as String? ?? '',
      profileAvatarUrl: json['profileAvatarUrl'] as String?,
      profileToken: profileToken == null || profileToken.isEmpty ? null : profileToken,
      profileHasPin: json['profileHasPin'] as bool? ?? false,
      createdAt: createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt,
    );
  }
}
