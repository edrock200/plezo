import 'dart:math';

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

  /// Whether the user has this connection switched on. A disabled
  /// connection stays saved (credentials and profile links included) but is
  /// never connected: no client, no network calls, nothing shown from it.
  bool get enabled;

  /// Backend-specific config payload, persisted as JSON. Each subclass
  /// defines the schema; [enabledKey] is written only while disabled, so a
  /// row saved before the switch existed (or an enabled one) reads as on.
  Map<String, Object?> toConfigJson();

  /// Config key holding the enable switch (absent = enabled).
  static const String enabledKey = 'enabled';

  /// Reads [enabledKey] from a stored config: anything but `false` is on.
  static bool enabledFromConfig(Map<String, Object?> json) => json[enabledKey] != false;

  /// This connection with its switch set to [enabled].
  Connection withEnabled(bool enabled) => switch (this) {
    final PlexAccountConnection c => c.copyWith(enabled: enabled),
    final JellyfinConnection c => c.copyWith(enabled: enabled),
    final SiloConnection c => c.copyWith(enabled: enabled),
    final TofaConnection c => c.copyWith(enabled: enabled),
    final IptvConnection c => c.copyWith(enabled: enabled),
  };
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

  @override
  final bool enabled;

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
    this.enabled = true,
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
    bool? enabled,
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
      enabled: enabled ?? this.enabled,
    );
  }

  @override
  Map<String, Object?> toConfigJson() {
    return {
      if (!enabled) Connection.enabledKey: false,
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
      enabled: Connection.enabledFromConfig(json),
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

  @override
  final bool enabled;

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
    this.enabled = true,
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
    bool? enabled,
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
      enabled: enabled ?? this.enabled,
    );
  }

  /// The persisted payload deliberately omits [dialect]: the `connections.kind`
  /// column is the authoritative, indexed discriminator and
  /// [JellyfinConnection.fromConfigJson] receives it from there.
  @override
  Map<String, Object?> toConfigJson() {
    return {
      if (!enabled) Connection.enabledKey: false,
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
      enabled: Connection.enabledFromConfig(json),
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

  @override
  final bool enabled;

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
    this.enabled = true,
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
    bool? enabled,
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
      enabled: enabled ?? this.enabled,
    );
  }

  @override
  Map<String, Object?> toConfigJson() {
    return {
      if (!enabled) Connection.enabledKey: false,
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
      enabled: Connection.enabledFromConfig(json),
    );
  }
}

/// A Tofa (tofa.tv) account signed in on one Tofa media server, acting as one
/// of that account's Tofa profiles.
///
/// Like [SiloConnection], the chosen profile is part of the identity: every
/// watch-state call acts on the `X-Profile-Id` profile, so two profiles of one
/// account are two connections.
///
/// Sign-in runs the device flow at Tofa's cloud service ([connectUrl]), which
/// grants a 30-day access token scoped to this server and a rotating 90-day
/// refresh token. The client persists each refreshed pair back through the
/// registry before it uses it: replaying a retired refresh token revokes the
/// whole session.
class TofaConnection extends Connection {
  @override
  final String id;

  @override
  final DateTime createdAt;

  @override
  final DateTime? lastAuthenticatedAt;

  @override
  final bool enabled;

  /// Server base URL as the user entered it after normalisation, no trailing
  /// slash. API paths (`/api/v1/...`) are appended.
  final String baseUrl;

  /// Shown name of the server. Tofa's own API has no server name for a
  /// device-flow client (only the cloud's account-first server list does), so
  /// this is the host unless the user's address said otherwise.
  final String serverName;

  /// Tofa's server id (`/api/v1/auth/status` `server_id`); the token is
  /// scoped to it.
  final String serverId;

  /// The cloud service that signs this server's devices in and refreshes
  /// their tokens (`auth/status` `connect_url`, e.g. `https://api.tofa.tv`).
  final String connectUrl;

  final String userId;
  final String userName;
  final bool isAdministrator;

  /// Bearer access token (30 days).
  final String accessToken;

  /// Rotating refresh token (90 days).
  final String refreshToken;

  /// When [accessToken] expires, or `null` when unknown.
  final DateTime? accessTokenExpiresAt;

  /// The Tofa profile this connection acts as (`X-Profile-Id`).
  final String profileId;
  final String profileName;

  /// `avatar_image_url` from `/api/v1/profiles` (root-relative or absolute).
  final String? profileAvatarUrl;

  /// `X-Profile-Token` from `verify-pin`, present only for a locked profile.
  final String? profileToken;

  /// When [profileToken] expires (`verify-pin` `expires_at`), or `null`.
  final DateTime? profileTokenExpiresAt;

  final bool profileIsLocked;

  TofaConnection({
    required this.id,
    required String baseUrl,
    required this.serverName,
    required this.serverId,
    required String connectUrl,
    required this.userId,
    required this.userName,
    required this.accessToken,
    required this.refreshToken,
    required this.profileId,
    required this.profileName,
    this.accessTokenExpiresAt,
    this.isAdministrator = false,
    this.profileAvatarUrl,
    this.profileToken,
    this.profileTokenExpiresAt,
    this.profileIsLocked = false,
    required this.createdAt,
    this.lastAuthenticatedAt,
    this.enabled = true,
  }) : baseUrl = canonicalizeBaseUrl(baseUrl),
       connectUrl = canonicalizeBaseUrl(connectUrl);

  /// Compound connection id: one account's profile on one server.
  static String compoundId({required String serverId, required String userId, required String profileId}) =>
      '$serverId/$userId/$profileId';

  @override
  MediaBackend get kind => MediaBackend.tofa;

  @override
  String get displayName => '$profileName · $serverName';

  @override
  String get displayLabel => serverName;

  @override
  String? get displaySubtitle {
    final who = profileName == userName || userName.isEmpty ? profileName : '$profileName ($userName)';
    final url = baseUrl.length <= 40 ? baseUrl : '${baseUrl.substring(0, 37)}…';
    return '$who · $url';
  }

  TofaConnection copyWith({
    String? baseUrl,
    String? serverName,
    String? connectUrl,
    String? userName,
    bool? isAdministrator,
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
    String? profileName,
    String? profileAvatarUrl,
    String? profileToken,
    DateTime? profileTokenExpiresAt,
    bool clearProfileToken = false,
    bool? profileIsLocked,
    DateTime? lastAuthenticatedAt,
    bool? enabled,
  }) {
    return TofaConnection(
      id: id,
      baseUrl: baseUrl ?? this.baseUrl,
      serverName: serverName ?? this.serverName,
      serverId: serverId,
      connectUrl: connectUrl ?? this.connectUrl,
      userId: userId,
      userName: userName ?? this.userName,
      isAdministrator: isAdministrator ?? this.isAdministrator,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
      profileId: profileId,
      profileName: profileName ?? this.profileName,
      profileAvatarUrl: profileAvatarUrl ?? this.profileAvatarUrl,
      profileToken: clearProfileToken ? null : (profileToken ?? this.profileToken),
      profileTokenExpiresAt: clearProfileToken ? null : (profileTokenExpiresAt ?? this.profileTokenExpiresAt),
      profileIsLocked: profileIsLocked ?? this.profileIsLocked,
      createdAt: createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt ?? this.lastAuthenticatedAt,
      enabled: enabled ?? this.enabled,
    );
  }

  @override
  Map<String, Object?> toConfigJson() {
    return {
      if (!enabled) Connection.enabledKey: false,
      'baseUrl': baseUrl,
      'serverName': serverName,
      'serverId': serverId,
      'connectUrl': connectUrl,
      'userId': userId,
      'userName': userName,
      'isAdministrator': isAdministrator,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'accessTokenExpiresAt': accessTokenExpiresAt?.millisecondsSinceEpoch,
      'profileId': profileId,
      'profileName': profileName,
      'profileAvatarUrl': profileAvatarUrl,
      'profileToken': profileToken,
      'profileTokenExpiresAt': profileTokenExpiresAt?.millisecondsSinceEpoch,
      'profileIsLocked': profileIsLocked,
    };
  }

  factory TofaConnection.fromConfigJson({
    required String id,
    required Map<String, Object?> json,
    required DateTime createdAt,
    DateTime? lastAuthenticatedAt,
  }) {
    DateTime? millis(Object? raw) {
      final ms = flexibleInt(raw);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    }

    final profileToken = json['profileToken'] as String?;
    return TofaConnection(
      id: id,
      baseUrl: json['baseUrl'] as String? ?? '',
      serverName: json['serverName'] as String? ?? 'Tofa',
      serverId: json['serverId'] as String? ?? '',
      connectUrl: json['connectUrl'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      userName: json['userName'] as String? ?? '',
      isAdministrator: json['isAdministrator'] as bool? ?? false,
      accessToken: json['accessToken'] as String? ?? '',
      refreshToken: json['refreshToken'] as String? ?? '',
      accessTokenExpiresAt: millis(json['accessTokenExpiresAt']),
      profileId: json['profileId'] as String? ?? '',
      profileName: json['profileName'] as String? ?? '',
      profileAvatarUrl: json['profileAvatarUrl'] as String?,
      profileToken: profileToken == null || profileToken.isEmpty ? null : profileToken,
      profileTokenExpiresAt: millis(json['profileTokenExpiresAt']),
      profileIsLocked: json['profileIsLocked'] as bool? ?? false,
      createdAt: createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt,
      enabled: Connection.enabledFromConfig(json),
    );
  }
}

/// Where an IPTV source's channels come from.
enum IptvSourceType {
  /// An M3U / M3U8 playlist, by address or from a file.
  m3u,

  /// An Xtream Codes compatible login (server, username, password).
  xtream;

  static IptvSourceType parse(Object? raw) => raw == 'xtream' ? xtream : m3u;
}

/// How an IPTV source numbers its channels.
enum IptvChannelNumbering {
  /// `tvg-chno` (Xtream `num`) where the playlist has one, else the position.
  playlist,

  /// Always 1, 2, 3… in the shown order.
  automatic;

  static IptvChannelNumbering parse(Object? raw) => raw == 'automatic' ? automatic : playlist;
}

/// An IPTV source the user added: an M3U playlist or an Xtream login, with
/// its guide addresses and settings.
///
/// One source is one "server" to the rest of the app: [id] is also its server
/// id. Several sources can be bound to one Plezilo profile. The playlist
/// address, the Xtream login and the guide addresses can all carry
/// credentials, so they are encrypted at rest (`CredentialVault`).
class IptvConnection extends Connection {
  @override
  final String id;

  @override
  final DateTime createdAt;

  @override
  final DateTime? lastAuthenticatedAt;

  @override
  final bool enabled;

  final IptvSourceType sourceType;

  /// The name shown for this source.
  final String name;

  /// M3U address (http, https or file).
  final String m3uUrl;

  /// A copy of a picked playlist file, read on every refresh.
  final String? m3uFilePath;

  final String xtreamServer;
  final String xtreamUsername;
  final String xtreamPassword;

  /// `ts` or `m3u8` for Xtream live streams.
  final String xtreamOutput;

  /// Guide addresses the user added (XMLTV, `.gz` allowed).
  final List<String> epgUrls;

  /// Also read the guide the source names itself (the playlist's `url-tvg`,
  /// Xtream's `xmltv.php`).
  final bool useSourceEpg;

  final String? userAgent;
  final String? referrer;

  final int playlistRefreshHours;
  final int epgRefreshHours;

  /// Minutes added to every guide time of this source.
  final int epgShiftMinutes;

  /// Guide days kept before now (for catch-up) and after.
  final int epgPastDays;
  final int epgFutureDays;

  final IptvChannelNumbering numbering;

  /// Xtream: also show the movie and series libraries.
  final bool includeVod;

  /// Groups shown only after the profile PIN (or always hidden for a profile
  /// without one) — the parental filter.
  final List<String> lockedGroups;

  IptvConnection({
    required this.id,
    required this.sourceType,
    required this.name,
    this.m3uUrl = '',
    this.m3uFilePath,
    this.xtreamServer = '',
    this.xtreamUsername = '',
    this.xtreamPassword = '',
    this.xtreamOutput = 'ts',
    this.epgUrls = const [],
    this.useSourceEpg = true,
    this.userAgent,
    this.referrer,
    this.playlistRefreshHours = 24,
    this.epgRefreshHours = 12,
    this.epgShiftMinutes = 0,
    this.epgPastDays = 2,
    this.epgFutureDays = 3,
    this.numbering = IptvChannelNumbering.playlist,
    this.includeVod = true,
    this.lockedGroups = const [],
    required this.createdAt,
    this.lastAuthenticatedAt,
    this.enabled = true,
  });

  /// A fresh source id. No `:` (server ids are the left half of global keys).
  static String newId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final random = Random.secure();
    final salt = List.generate(6, (_) => random.nextInt(36).toRadixString(36)).join();
    return 'iptv-$now$salt';
  }

  /// The server id this source registers under.
  String get serverId => id;

  bool get isXtream => sourceType == IptvSourceType.xtream;

  @override
  MediaBackend get kind => MediaBackend.iptv;

  @override
  String get displayName => name;

  @override
  String get displayLabel => name;

  @override
  String? get displaySubtitle {
    if (isXtream) {
      final host = Uri.tryParse(xtreamServer)?.host ?? '';
      return host.isEmpty ? 'Xtream' : 'Xtream · $host';
    }
    if (m3uFilePath != null) return 'M3U · ${m3uFilePath!.split(RegExp(r'[/\\]')).last}';
    final host = Uri.tryParse(m3uUrl)?.host ?? '';
    return host.isEmpty ? 'M3U' : 'M3U · $host';
  }

  IptvConnection copyWith({
    String? name,
    String? m3uUrl,
    String? m3uFilePath,
    String? xtreamServer,
    String? xtreamUsername,
    String? xtreamPassword,
    String? xtreamOutput,
    List<String>? epgUrls,
    bool? useSourceEpg,
    String? userAgent,
    bool clearUserAgent = false,
    String? referrer,
    bool clearReferrer = false,
    int? playlistRefreshHours,
    int? epgRefreshHours,
    int? epgShiftMinutes,
    int? epgPastDays,
    int? epgFutureDays,
    IptvChannelNumbering? numbering,
    bool? includeVod,
    List<String>? lockedGroups,
    DateTime? lastAuthenticatedAt,
    bool? enabled,
  }) {
    return IptvConnection(
      id: id,
      sourceType: sourceType,
      name: name ?? this.name,
      m3uUrl: m3uUrl ?? this.m3uUrl,
      m3uFilePath: m3uFilePath ?? this.m3uFilePath,
      xtreamServer: xtreamServer ?? this.xtreamServer,
      xtreamUsername: xtreamUsername ?? this.xtreamUsername,
      xtreamPassword: xtreamPassword ?? this.xtreamPassword,
      xtreamOutput: xtreamOutput ?? this.xtreamOutput,
      epgUrls: epgUrls ?? this.epgUrls,
      useSourceEpg: useSourceEpg ?? this.useSourceEpg,
      userAgent: clearUserAgent ? null : (userAgent ?? this.userAgent),
      referrer: clearReferrer ? null : (referrer ?? this.referrer),
      playlistRefreshHours: playlistRefreshHours ?? this.playlistRefreshHours,
      epgRefreshHours: epgRefreshHours ?? this.epgRefreshHours,
      epgShiftMinutes: epgShiftMinutes ?? this.epgShiftMinutes,
      epgPastDays: epgPastDays ?? this.epgPastDays,
      epgFutureDays: epgFutureDays ?? this.epgFutureDays,
      numbering: numbering ?? this.numbering,
      includeVod: includeVod ?? this.includeVod,
      lockedGroups: lockedGroups ?? this.lockedGroups,
      createdAt: createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt ?? this.lastAuthenticatedAt,
      enabled: enabled ?? this.enabled,
    );
  }

  /// Guide addresses are stored as one newline-separated string so the
  /// credential vault can encrypt them like any other secret.
  @override
  Map<String, Object?> toConfigJson() => {
    if (!enabled) Connection.enabledKey: false,
    'sourceType': sourceType.name,
    'name': name,
    'm3uUrl': m3uUrl,
    'm3uFilePath': m3uFilePath,
    'xtreamServer': xtreamServer,
    'xtreamUsername': xtreamUsername,
    'xtreamPassword': xtreamPassword,
    'xtreamOutput': xtreamOutput,
    'epgUrls': epgUrls.join('\n'),
    'useSourceEpg': useSourceEpg,
    'userAgent': userAgent,
    'referrer': referrer,
    'playlistRefreshHours': playlistRefreshHours,
    'epgRefreshHours': epgRefreshHours,
    'epgShiftMinutes': epgShiftMinutes,
    'epgPastDays': epgPastDays,
    'epgFutureDays': epgFutureDays,
    'numbering': numbering.name,
    'includeVod': includeVod,
    'lockedGroups': lockedGroups,
  };

  factory IptvConnection.fromConfigJson({
    required String id,
    required Map<String, Object?> json,
    required DateTime createdAt,
    DateTime? lastAuthenticatedAt,
  }) {
    String? optional(Object? raw) => raw is String && raw.trim().isNotEmpty ? raw : null;
    int number(Object? raw, int fallback) => flexibleInt(raw) ?? fallback;
    final epg = json['epgUrls'];
    final epgUrls = epg is String
        ? epg.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
        : epg is List
        ? epg.whereType<String>().toList()
        : const <String>[];
    final locked = json['lockedGroups'];
    return IptvConnection(
      id: id,
      sourceType: IptvSourceType.parse(json['sourceType']),
      name: json['name'] as String? ?? 'IPTV',
      m3uUrl: json['m3uUrl'] as String? ?? '',
      m3uFilePath: optional(json['m3uFilePath']),
      xtreamServer: json['xtreamServer'] as String? ?? '',
      xtreamUsername: json['xtreamUsername'] as String? ?? '',
      xtreamPassword: json['xtreamPassword'] as String? ?? '',
      xtreamOutput: json['xtreamOutput'] == 'm3u8' ? 'm3u8' : 'ts',
      epgUrls: epgUrls,
      useSourceEpg: json['useSourceEpg'] as bool? ?? true,
      userAgent: optional(json['userAgent']),
      referrer: optional(json['referrer']),
      playlistRefreshHours: number(json['playlistRefreshHours'], 24),
      epgRefreshHours: number(json['epgRefreshHours'], 12),
      epgShiftMinutes: number(json['epgShiftMinutes'], 0),
      epgPastDays: number(json['epgPastDays'], 2),
      epgFutureDays: number(json['epgFutureDays'], 3),
      numbering: IptvChannelNumbering.parse(json['numbering']),
      includeVod: json['includeVod'] as bool? ?? true,
      lockedGroups: locked is List ? locked.whereType<String>().toList() : const [],
      createdAt: createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt,
      enabled: Connection.enabledFromConfig(json),
    );
  }
}
