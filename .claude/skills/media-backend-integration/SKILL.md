---
name: media-backend-integration
description: Checklist for adding a new media-server backend to Plezy or changing how an existing one plugs into the app (MediaBackend enum, MediaItem union, Connection subclasses, credential storage, MultiServerManager, ActiveProfileBinder, API caches, add-server UI, downloads, tests). Use before editing lib/media/media_backend.dart, lib/media/media_item.dart, lib/connection/connection.dart or lib/services/multi_server_manager.dart, and when a backend works in tests but is missing from part of the app.
---

# Adding or changing a Plezy server backend

Plezy's UI and providers only see `MediaServerClient`, `MediaItem` and `Connection`. A backend is
"in the app" only when every layer below knows it. Silo was added this way; grep for
`MediaBackend.silo` / `SiloConnection` to see a complete example.

## 1. Identity and models
- `lib/media/media_backend.dart`: add the enum value, its `id`, `fromId`, `fromString` (otherwise
  cached rows silently become Plex), and `dialect` (non-null only for MediaBrowser servers).
  `usesMediaBrowserApi` means Jellyfin/Emby — do not use it as "not Plex".
- `lib/media/media_item.dart`: add a freezed variant carrying the same neutral field set as
  `MediaItem.jellyfin` (fields common to all variants become the union's getters), plus arms in the
  synthetic `MediaItem(...)` factory, `backend`, `fromJson`, `toJson`. Then
  `dart run build_runner build --delete-conflicting-outputs` and commit only the regenerated files
  for that source.
- `lib/media/server_capabilities.dart`: a `static const` describing what the backend supports; UI
  hides features from it.

## 2. Connections and credentials
- `lib/connection/connection.dart`: a `Connection` subclass with `toConfigJson`/`fromConfigJson`,
  `displayLabel`, `displaySubtitle`, `copyWith`. Make the id stable and compound if one server can
  hold several accounts/profiles (`server/user[/profile]`).
- `lib/connection/connection_registry.dart` `_rowToConnection`: decode the new kind.
- `lib/services/credential_vault.dart` `_tokenKeysForKind`: list **every** credential key
  (access, refresh, PIN/profile tokens). Unlisted keys are persisted in plaintext.

## 3. Client lifecycle
- Implement `MediaServerClient` (+ `ScopedMediaServerClient` when the cache scope differs from the
  public server id, and `GracefullyCloseable`). Unsupported reads return empty; unsupported
  mutations throw `UnsupportedError`. `checkHealth` must map 401 → `authError`, 403 → `accessDenied`.
- `lib/services/multi_server_manager.dart`: an `add<Backend>Connection`/`remove…` pair. Per-account
  clients share `_jellyfinByCompoundId`/`_activeJellyfinMachine`/`_jellyfinHealthByCompoundId`;
  extend `_boundConnectionId` so health, reconnect, scope lookup and `isRegisteredForOtherProfile`
  cover it. Wire an `on<Backend>ConnectionUpdated` persistence callback in `main.dart` if the client
  can change its own credentials.
- `lib/profiles/active_profile_binder.dart`: expected server ids, the bind dispatch, the
  connection-id set passed to `isRegisteredForOtherProfile`.
- `lib/profiles/profile_connection_cleanup.dart`: server ids per connection and removal.
- Register an `ApiCache` subclass (`ApiCacheSingleton`) and call its `initialize` in `main.dart`
  next to `PlexApiCache`/`JellyfinApiCache`; `ApiCache.forBackend` falls back to Plex otherwise.

## 4. Everything else that switches on backend or connection
Run `flutter analyze lib test` after adding the enum value and the `Connection` subclass; every
non-exhaustive switch is an error. Expect, at least: account preferences (controller, accounts,
repository), companion remote, profile avatar source, profile detail and borrow screens, sync rules
screen, download provider (synthesized show raw), cached playback metadata service, library A–Z
strategy, backend badge, media context menu (delete permission), and in tests
`test/test_helpers/media_items.dart` and `test/services/catalog/mal_catalog_source_test.dart`.
Then review the non-exhaustive ones by hand:
- `media_list_playback_launcher.dart` — only Plex has server-side play queues; others must use the
  local-queue launcher.
- `playback_progress_tracker.dart`, `track_selection_service.dart`, `offline_watch_sync_service.dart`,
  `download_manager_service.dart` — branches on `usesMediaBrowserApi` or `== MediaBackend.plex`;
  decide which behaviour the new backend needs.
- `playback_source_resolver.dart` — `client.streamHeaders` are given to the player; return the auth
  headers media requests need. `discord_rpc_service.dart` also sends them when fetching artwork:
  skip them there if the backend's image URLs are self-authorising or can be on another host.
- `hub_detail_screen.dart` (`_replaceContinuationItems`) and other Plex-only continuation logic —
  check `== MediaBackend.plex` guards still hold for the new backend.
- Offline progress sync calls `reportPlaybackStarted/Stopped` **without a session id**; the client
  must persist progress in that case.

## 5. UI and strings
- Add-server screen (copy the structure of `add_jellyfin_screen.dart`/`add_silo_screen.dart`): use
  `FocusableTextFormField`/`FocusableButton`/`FocusableWrapper` with explicit D-pad neighbours; end
  with `persistAndBindConnection` and the same first-run profile rules.
- Picker entries in `add_connection_screen.dart` and the first-run buttons in `auth_screen.dart`.
- Badge asset in `assets/` (listed in `pubspec.yaml`) and `widgets/backend_badge.dart`.
- Strings in `lib/i18n/en.i18n.json`, then `dart run slang`. Update user-facing lists of backends.
- `test/screens/settings/add_connection_screen_test.dart` pins the number of backend cards and
  D-pad reachability; update it.

## 6. Downloads
- `resolveDownload` must return a URL the downloader can fetch **without headers** (the native
  downloader sends none) and must not embed long-lived account tokens. If the path has no file
  extension, add `#container=<ext>` (read by `downloadExtensionFromUrl`).
- `resolveDownloadArtwork` → `buildArtworkSpecs`; make sure `artworkStorageKey` yields a stable key
  if the backend's image URLs carry rotating signatures.
- `ApiCache.pinForOffline` must pin everything offline playback reads; add the backend's arm to
  `CachedPlaybackMetadataService`.

## 7. Paging and concurrency
- If the server pages with opaque cursors, map Plezy's offset paging onto them in one place and
  respect the contract's binding rules (page size, query, sort); prefer a server-side jump (`seek`)
  over walking pages, and restart on an invalid-cursor error.
- Serialize "add connection" per account, share in-flight futures for reads several screens make at
  once, and `Future.wait` independent requests.

## 8. Verify
`flutter analyze lib test`, `dart format` on changed files only, `scripts/run_tests.sh` (whole
suite: shared switches break unrelated tests), plus backend unit tests with a `MockClient`.
