---
name: silo-backend
description: How Plezilo's (this Plezy fork's) Silo media-server backend works and how to change, test and debug it. Use whenever you touch lib/services/silo/, the Silo sign-in screen (lib/screens/settings/add_silo_screen.dart), SiloConnection, SiloMediaItem, SiloApiCache or Silo's card overlays (badges on Silo posters); when a Silo user reports sign-in, browsing, playback, subtitle, download or progress problems; when checking Plezy against Silo's API contract or its Android/Android TV apps; or when running the Silo mock server.
---

# Silo backend for Plezilo

Plezilo is the user-facing name of this Plezy fork; "Plezy" below means the shared codebase.

Silo (https://github.com/Silo-Server/silo-server) is a self-hosted media server. Plezy speaks its
**`/api/v2` REST contract only** — never `/api/v1`, never the root `/health`, never the
Jellyfin-compatible API the server also hosts. `SiloApi.request` throws on any path outside
`/api/v2/`.

## Sources of truth (clone them, read as data)
- Server contract: `Silo-Server/silo-server` → `contracts/api/v2/openapi.json` (6 MB OpenAPI) and
  `contracts/api/v2/fixtures/*.json`; prose in `docs/playback-api.md`. A sparse clone is enough:
  `git clone --depth 1 --filter=blob:none --sparse https://github.com/Silo-Server/silo-server && git sparse-checkout set contracts/api/v2 docs`.
  Query it with a small Python script that resolves `$ref`s (paths → requestBody/responses).
- Reference clients: `Silo-Server/silo-android` (`shared/` = common code, `androidApp/` = phone and
  tablet, `androidTvApp/` = TV) and `edrock200/Siku` (Roku port; `docs/api-spec.md` is the best
  single summary of the contract, `tools/mock_server.py` is a mock server).
- When Plezy and Silo's apps disagree, prefer matching the Android app unless Plezy's player or
  downloader cannot do what it does (documented under "Deliberate differences").

## Files
| File | Role |
|---|---|
| `lib/services/silo/silo_api.dart` | HTTP layer: device headers (`SiloDeviceHeaders`), `SiloFormFactor`, bearer + `X-Profile-Id`/`X-Profile-Token`, single-flight token refresh, problem+json helpers, URL resolution |
| `lib/services/silo/silo_auth_service.dart` | Pre-connection calls: address probing, password login, device-code calls, logout, profiles, PIN, `buildConnection`; typed `SiloSignInException` |
| `lib/services/silo/silo_device_sign_in.dart` | `SiloDeviceSignIn`: the device-code state machine (port of Silo's `DeviceSignInMachine`), a `ValueNotifier` the sign-in screen renders |
| `lib/services/silo/silo_client.dart` | `SiloClient` (`MediaServerClient`): libraries, cursor paging, items/seasons/episodes, hubs, search, watch state, collections, images |
| `lib/services/silo/silo_client_playback.dart` | `part`: playback v3 start, sidecars, progress/stop, sessionless progress, downloads, markers |
| `lib/services/silo/silo_playback_caps.dart` | What the player declares (`client_capabilities`, `client_playback_context`) |
| `lib/services/silo/silo_mappers.dart` | Pure JSON → `MediaItem`/`MediaVersion`/chapters/markers; watch-detail helpers shared with offline playback |
| `lib/services/silo/silo_trickplay.dart` | Seek-bar previews: `SiloTrickplayManifest` (validation, time → sheet/tile), `SiloTrickplayService` (`ScrubPreviewSource`: bounded sheet cache, renewal), `load`/`fetchManifest`/`fetchSheet` |
| `lib/services/silo/silo_subtitles.dart`, `silo_client_subtitles.dart` | Subtitle search/download and AI subtitles: models, `SiloSubtitleRules` (stored-track ids, translatable tracks, transcribe kind), the client calls (`part`) |
| `lib/widgets/video_controls/silo/` | The player's Silo subtitle rows and sheets (`SiloSubtitleFooterTiles`, `SiloSubtitleSearchSheet`, `SiloAiSubtitleSheet`) and `SiloAiSubtitleController` (one per client + item: form, job, polling) |
| `lib/services/silo/silo_api_cache.dart` | `SiloApiCache`: serialized items (`silo:item/<id>`) and pinned watch detail for downloads |
| `lib/screens/settings/add_silo_screen.dart` | Add-server UI: address → code or password → (temporary password) → Silo profile (+PIN) → persist and bind |
| `lib/services/silo/silo_password_change.dart`, `lib/screens/settings/silo_password_change_panel.dart` | Temporary passwords (Silo Android #790): capability/limits, change result mapping, `SiloTemporaryPasswordSession`, `SiloPasswordChangeController` (port of `PasswordChangeViewModel`) and the "Choose a new password" form |
| `lib/media/remote_trailer.dart` | `RemoteTrailer` (YouTube video, never a `MediaItem`), `RemoteTrailerClient`, `buildExtrasRail` (port of Silo's `trailerRailEntries`) |
| `lib/utils/youtube_trailer_launcher.dart`, `lib/screens/youtube_trailer_screen.dart` | Opening a YouTube trailer per platform; the in-app IFrame player route |
| `lib/services/silo/pairing/` | Sign in from a phone (Silo companion pairing): `silo_pairing_protocol.dart` (frames, messages, codes), `silo_pairing_receiver.dart` (the TV state machine, port of Silo's `PairingReceiver`), `silo_pairing_host.dart` (loopback bridge + advertiser channel), `silo_pairing_flow.dart` (device-code flow → pairing code/outcome) |
| `android/app/src/main/kotlin/com/edde746/plezy/silopairing/` | `SiloPairingChannel.kt` (`com.plezy/silo_pairing`: NsdManager registration, LAN listener, one phone at a time, relay to Dart) and `SiloPairingTls.kt` (BouncyCastle TLS-PSK server) |
| `lib/connection/connection.dart` | `SiloConnection` (id `serverId/userId/profileId`) |
| `lib/services/cached_playback_metadata_service.dart` | Offline markers/tracks for downloaded Silo items |
| `lib/services/silo/silo_card_overlays.dart` | Card overlays, pure: registry, `ui.card_overlays` parsing (v1/v2, style), settle with the overlay config, labels, placement/caps/suppression, looks and colours, `SiloOverlayData` (from a card's raw JSON) |
| `lib/services/silo/silo_card_overlay_store.dart` | `SiloCardOverlayStore` (`SiloClient.cardOverlays`): the two settings reads under one in-flight future, known value per connection |
| `lib/widgets/silo_card_overlays.dart` | `CardArtworkOverlays` (Plezy's `WatchedIndicator`, or Silo's layer on Silo items), `SiloCardOverlayLayer` and the cached `SiloOverlayLayout` |
| `lib/widgets/silo_overlay_icons.dart` | Overlay glyphs from Lucide path data and the web's Dolby Vision mark (`parseSvgPath`), `SiloWatchedCheck` |

## Contract rules the code depends on
- **Headers:** every request sends `Accept: application/json` and `X-Silo-Device-Id/-Name/-Platform`,
  `X-Silo-Client` (`Plezilo`), `-Client-Version`, `-Client-Family`. Family is a closed set
  (`tv|mobile|tablet|desktop|web`) and selects `profile_client` settings rows, so tablets must say
  `tablet` (600 dp shortest side, decided once per process; a read before the view has a size is
  used but not cached). Platform is `android-tv` on Android TV.
- **Profiles:** almost every content route needs `X-Profile-Id`; PIN-locked profiles also need
  `X-Profile-Token` from `POST /profiles/{id}/verify-pin`. A Plezy connection is one Silo profile.
  Auto-select a single profile only when it has no PIN (as Silo's apps do).
- **Device-code sign-in** (`SiloDeviceSignIn`, Silo's TV states table): poll at once, then every
  `poll_after`/`interval`; a pending reply's `expires_at` extends the local deadline (applied as the
  offset from the start reply's `expires_at`, never compared across clocks). Past the deadline the code
  is withdrawn (`/auth/device/cancel`, 5 s bound) and **renewed in place** (status "New code"); renewals
  pause after 1 h ("Show a new code"). `status: denied` stops with "declined" + "Show a new code"
  (never re-mint silently); `expired|consumed|canceled`/404 replace the code (3 codes lost at their
  first poll in a row → failed). Network/5xx back off to 30 s and show "Can't reach <host>" after 30 s
  (10 s while starting); 429 for 60 s shows "Too many sign-in attempts" — both **keep polling** and
  keep the live code on screen. Start 404/501 → password only; 410/426 → update required. An approved
  code is spent: never cancel it (no Cancel button after approval). Use `package:clock` (`clock.now()`)
  so `fake_async` tests can drive it.
- **Sign in from a phone** (Silo companion pairing; Android only, `SiloPairingHost.supported`): while
  the add-server screen shows the address step (`st=setup`) or a code (`st=login`, `srv=<server_id>`),
  the device advertises **`_silopair._tcp`** like Silo's Android TV app (`TvPairingAdvertiser.kt`;
  never `_silopair-roku._tcp`, which makes the phone treat it as a Roku). TXT: `v=1`, `name` (device
  name cut to 63 UTF-8 bytes, else "Plezilo"), `id` (the `X-Silo-Device-Id`), `sid` (fresh UUID per
  advertisement), `st`, `srv`, and on `setup` only `acct=1` (several accounts per session, below). No
  `lim`: only Silo's Roku sends one (storage), Android TV does not. Transport: **TLS-PSK**, key `silo-companion-pairing-v1`, identity
  `silo-pairing`, TLS 1.3 `TLS_AES_128_GCM_SHA256` / TLS 1.2 `TLS_PSK_WITH_AES_128_GCM_SHA256`,
  BouncyCastle 1.84 in non-blocking server mode (`SiloPairingTls.kt`, copied from
  `TlsPskPairingTransport.kt`; the TV writes first). Dart has no PSK, so Kotlin terminates TLS and
  relays plaintext to a `127.0.0.1` socket that must open with a 32-byte one-time secret. Frames: 4-byte
  big-endian length + UTF-8 JSON (max 1 MiB). Messages (`type` + `v:1`): TV `hello {tvName,
  tvDeviceId, state, supportedVersions:[1]}`; phone `pushServer {serverURL, serverName?,
  serverIdentity?, endpoints?[{url, kind, provider?, displayName?}]}`; TV `deviceStarted {serverURL,
  userCode, matchCode}` (the start reply's `match_code`: the phone refuses a mismatch with its own
  lookup); TV `serverResult {serverURL (always the pushed one), status signedIn|failed, error?
  auth_failed|denied|expired|unreachable|identity_mismatch|update_required}`; phone `done`; either
  `cancel {reason}` (`consent_denied` from the TV). The first push asks "Allow this setup?" (again for
  a plain-HTTP origin); setup checks `GET /api/v2/system/identity` at the pushed address (another id or
  a v1 server = `identity_mismatch`; unreachable offers a verified alternate endpoint, never takes it),
  then runs the screen's own probe + device-code flow; login only accepts `serverIdentity == srv` and
  lends the code on screen. `serverResult signedIn` goes out once the approval became a session
  (`completeDeviceLogin`), before the profile is picked. 180 s of silence (nothing in flight) drops the
  phone. Tokens never cross the LAN. `pushServer.accountName` (optional, display only, ≤64 chars) titles
  the working panel ("Signing in sam on Home"); it is never matched.
- **Several accounts in one phone session** (Silo Android #810, `PairingReceiver.kt`,
  `PairingSessionBinding.kt`, `TvPairedSession.kt`; Siku's `PairSession.brs`): on `setup` the phone may
  push again after each `serverResult`, any server, the same one included; consent is asked once per
  session (again per plain-HTTP origin). A failed account (`denied`, `identity_mismatch`, …) does not end
  the session. `login` keeps its one account: a later push answers `failed limit_reached` (Siku does the
  same; older phones read unknown codes as `auth_failed`). The screen (`add_silo_screen.dart`) holds each
  approved setup sign-in in `_pairedSignIns` instead of opening its profiles, returns to the address step
  and shows "Signed in [N accounts]" with **Continue** (`receiver.finishSession()`, the same end as
  `done`). When the session is over (`receiver.onSessionEnd`, after `_transport` is cleared) `_PairedRun`
  takes the accounts first to last: each goes through `_onSignedIn` (auto-pick of a bound or lone
  unlocked Silo profile, else the picker, whose "Change server" becomes "Skip this account") and
  `_persistAndExit` with the usual rules (`otherSiloConnectionOnServer` → a new, non-activated Plezilo
  profile; other servers join the chosen profile). The next account starts with `Timer.run` so two
  `runAsync`s never overlap. One account ends like any sign-in (snackbar, pop); several (or a failure)
  end on `_Step.pairedSummary` ("2 accounts added", "<account> on <server>, in the profile <P>" / "in a
  new profile" / "was not added", Done → pop(true), or back to the address step when none saved).
  Plezilo has no Change Account screen; the first account is processed first, like Silo's TV opening
  the first. No advertising while a run is saved (`_wantedAdvertisement` null; `_pairingStartSetup`
  refuses). Leaving the screen logs out held, unsaved sign-ins (`_discardPairedSignIns`).
- **Session binding** (Silo Android #810, contract §B.1/§B.2): `SiloDeviceLoginBinding`
  (`silo_auth_service.dart`): 32 secure-random bytes per phone session (`receiver.run`), `binding` =
  base64url(SHA-256(secret)), `secret` = base64url(secret), no padding (vector: bytes 0..31 →
  `Yw3NKWbEM2aRElRIu7JbT_QSpJxzLbLIq8G4WBvXEN0`). The receiver hands it to `port.startSetup(target,
  binding:)`; `siloSessionBindingFor(server, binding)` sends it only when the probed address is **https**
  and `GET /auth/device/capability` says `session_binding: true` (`SiloServerInfo.deviceSessionBinding`).
  `SiloDeviceSignIn(binding:)` puts `binding` on every `device/start` (renewed codes too) and
  `binding_secret` on every poll. A poll answering 403 problem `device_binding_mismatch` is
  `SiloDevicePollStatus.bindingRefused`: the code is withdrawn (`/device/cancel`) and the flow fails, so the
  phone gets `auth_failed`. The sign-in screen's own code (`login`) carries no binding. Log:
  `[silo-pair] binding sent=yes|no reason=no_session_binding|http`, `the server refused the session
  binding`; the binding itself is never logged (`toString` redacted). Plezilo does not show Silo's
  "automatic" (no-compare) state for later bound codes. Golden frames are those of
  silo-android `PairingProtocolGoldenFramesTest`.
- **Abandoned sessions:** a sign-in that is not saved (screen left, Change server, no profiles,
  completion failed, approval arriving after the flow was abandoned) is revoked with
  `POST /api/v2/auth/logout` (bearer, best effort, 5 s). The screen marks the session handed off just
  before `persistAndBindConnection`.
- **Temporary passwords** (Silo Android #790, silo-apple #874): an admin can make an account's
  password temporary. Until it changes, everything except `GET /account/me`,
  `GET /account/password/capability`, `POST /account/password` and sign-out answers `403` problem
  `password_change_required`; `account/me` carries `password_change_required: true` (absent on older
  servers = unknown, counted as still temporary after a failed change). `SiloApi.request` turns that
  refusal into `SiloPasswordChangeRequiredException` (a `MediaServerHttpException` whose `display` is
  plain copy; `localizedLoadErrorText`/`localizedErrorReason`/`classifyPlaybackFailure` use it), so no
  screen shows the server's protocol detail. The sign-in screen catches it from `fetchProfiles`:
  phones/tablets/desktops get "Choose a new password" (temporary, new, confirm); the limits come from the
  capability (`minimum_password_length` in code points, `maximum_password_bytes` in UTF-8; defaults 8/72)
  and are checked locally. `POST /account/password {current_password, new_password}` goes out **once**
  with no profile headers (`resendAfterRefresh: false`: a 401 refreshes for the next try, never resends);
  204 = changed, 422 naming `body.current_password` = wrong temporary password, other 422 = the first
  `errors[].detail`, 429/409/403 have their own copy. A 4xx keeps the form without reading the account;
  a lost answer or 5xx re-reads `account/me` to tell a saved change from none, and when that read fails
  the form stays closed and Try again only re-reads. After the change the session is refreshed through
  `SiloApi.refreshTokens` (the shared single-flight refresh; the restriction lives in the access token),
  the rotated pair replaces the sign-in's tokens, and profiles load again; a failed refresh retries only
  the refresh; an account already changed skips to the refresh. A second refusal after a finished change
  is not handed off again (no loop). TVs (`PlatformDetector.isTV()`) get no form: a message to use Silo's
  phone app or website, with Sign out focused (logs the unsaved session out). A saved connection whose
  password becomes temporary later still binds (`account/me` answers); its screens show the plain
  message telling the user to remove and re-add the server.
- **PIN:** `verify-pin` 200 without `valid:true` = wrong PIN ("Wrong PIN. Try again."); 429 →
  `SiloSignInFailure.pinRateLimited`; another 4xx → `pinRefused` with the problem `detail` (shown in
  the PIN dialog, which stays open); 5xx/transport throw `MediaServerHttpException`.
  `siloPinErrorMessage` maps them. A device approval bound to a PIN profile without `profile_token`
  opens that profile's PIN dialog; without a PIN it is used directly.
- **Tokens:** access tokens are short-lived; refresh proactively (≤ min(60 s, lifetime/2) left) and
  on 401 under one in-flight refresh. A 401 for an access token another request already replaced
  is retried without refreshing again (rotating twice wastes a pair). Only a 400/401 **carrying
  Silo's problem body** refuses a refresh (`SiloApi.isRefreshRefusal`) and signs out; a 403, a
  proxy's HTML 401, a 5xx or a timeout keeps the session and the next 401 tries again.
  `checkHealth` reports `authError` only after such a refusal, otherwise `offline`. The token
  lifetime (`expires_in`) is persisted as `SiloConnection.accessTokenLifetimeSeconds`, so
  `refreshTokensIfHalfSpent` (run before each play) does not rotate on every play after a restart
  (unknown lifetime counts as an hour). A refused refresh token is remembered and not sent again. **Refresh tokens rotate**: persist every new pair
  (`SiloClient.onConnectionUpdated` → `ConnectionRegistry.upsert`). `MultiServerManager` keeps the
  live client when a re-bind arrives with an older, already-rotated refresh token
  (`SiloClient.ownsRefreshToken`) — replacing it would revive a dead token. When such a re-bind
  must rebuild the client (new address or PIN token), the replacement takes the live client's
  current pair and known tokens (`inheritSession`), and a refresh the replaced client still had
  in flight is handed to the replacement (`adoptTokens`) and persisted as the replacement's row.
  A closing client rejects new requests, so only an already-sent refresh can land after a swap.
- **Server status:** Silo has one address, so `SiloApi.onServerUnreachable` (2 consecutive
  connection failures, or a 401 still there after a refresh attempt) and an `offline`
  `checkHealth` go through `MultiServerManager._onJellyfinEndpointsExhausted` → the shared
  debounce + health probe, which flips the server offline / auth error. A failed probe re-arms
  the check, which is how the server is seen coming back (same loop as a MediaBrowser server).
- **Removal:** `removeSiloConnection` revokes the session in the background
  (`POST /api/v2/auth/logout`, bearer only, 5 s) with the live client, or a throwaway client
  from the stored row; removal never waits for it. Profile join rows for Silo carry no token
  (borrowing stores `userToken: null`); the tokens live only in the connection row.
- **Paging:** collections are `{items, page:{has_more,next_cursor}, total, window_cursor}` with
  opaque cursors; offsets are rejected. Cursors are bound to the query **and the page size**.
  `SiloClient._pageAt` keeps a bounded map per (query, page size): the adjacent page reuses
  `next_cursor`; any other offset sends `cursor=<window_cursor>&seek=<offset>` (no walking). A 400
  `invalid_cursor` (the listing changed, a search window expired) drops the map and restarts once.
  Keep query params identical across pages. A seek into a list whose first page said
  `total_exact: true` sends `skip_total=true` and reports that exact total (the cursor scope ignores
  `skip_total`; it does include `limit`, so each page size needs its own first page).
- **A–Z bar (Silo Android #888):** `SiloAlphaBarStrategy` (`library_alpha_bar_strategy.dart`) reads
  `SiloClient.fetchLetterIndex` = `POST /api/v2/catalog/letters` with body `{library_id, type,
  groups, order: asc|desc}` built from the grid's own `_catalogParams` by
  `SiloLetterIndex.requestBody` (genre/year/content_rating become the rule groups the server derives
  from those GET params; `q`/`name_prefix`/non-title sorts have no index). Answer `{total,
  letters:[{letter,count,position}], runs:[{letter,position}]}`: a tap jumps to `position` (not
  cumulative counts; a collation can put accented A after Z), the highlighted letter comes from
  `runs`. Like Plex's bar it shows only in title order (phones too), letters without titles are left
  out, and the grid loads the far range with `seek`. 404/405/501 = no index (sticky per client):
  the static `name_prefix` bar stays (hidden on phones). Each load bumps a generation so only the
  newest answer is kept. Tests: `silo_letter_index_test.dart`, `silo_alpha_bar_strategy_test.dart`,
  the Silo cases in `library_browse_tab_test.dart`.
- **Ids:** opaque strings (`movie:heat-1995`); always `Uri.encodeComponent` them in paths. Episode
  cards name their season only by series + number, so they get a synthetic parent id
  `silo-season:<n>:<seriesId>` (`SiloMappers.syntheticSeasonId`); `fetchItem`/`fetchChildren`
  resolve it. Season lists use the server's real season `content_id`. Writes (watched, rating,
  favorite) on a synthetic season resolve it to that real id first — never to the series.
- **Watch state:** cards (catalog, Home, search, similar, history) carry only
  `user_state.played`; details, season lists and episode lists carry `user_data`, Silo's watch
  rollup (`played`, `watched_count`, `unplayed_count`, `in_progress_count`, `position_seconds`).
  On a season or series the counts are episodes; on a **movie or episode `watched_count` is
  always 0** (the server never fills it for leaves; it is not a play count), so a leaf is watched
  only by `played` and `viewCount` is `played ? 1 : 0` (reading `watched_count` hid every
  watched movie/episode on detail pages, episode lists and downloads before this fix). A series
  detail has no `episode_count`: `SiloMappers.item` takes `watched_count + unplayed_count` as
  its `leafCount`. Series cards have no counts at all, so they get a check mark but no
  unwatched badge, like Silo's TV app (`TvMediaCard`: `userState.played` only).
- **Images:** URLs arrive ready-made and self-authorising (signed `exp`/`sig`, or S3 presigned).
  Resolve root-relative ones against the server **origin**, never add auth, never re-encode the query.
  `artworkStorageKey` strips the rotating signature so downloaded artwork is found again.
- **Episode parent artwork** (servers with `episode_parent_artwork`, Silo #711): episode cards and
  details carry `series_poster_url`, `series_backdrop_url`, `season_poster_url` (+ ThumbHashes,
  which Plezy does not use). `SiloMappers.item` maps them to `grandparentThumbPath`,
  `parentThumbPath` (season, else series poster) and `grandparentArtPath`/`grandparentBackdropPaths`,
  falling back to `poster_url`/`backdrop_url` on older servers. Episode heroes already prefer
  inherited art (`heroBackdropPaths`), and `spoilerSafeArt` reads `grandparentArtPath`; series and
  season art is never an episode still, so spoiler protection leaves it visible. `artPath` stays
  the episode's own backdrop. Plezy's Up Next card deliberately shows the (blurred) episode still.
- **Section rows (`item_limit`, Silo #688):** Home and library section lists send
  `item_limit=min(20, section_item_limit_max)` only when `GET /home/capabilities` advertises the
  field. The capability is read once per client (shared future, 3 s cap); a failed/slow read or a
  missing field means "send nothing" for the client's life. A 422 `validation_failed` whose
  `errors[]` has `{location: query.item_limit, code: unknown_parameter}` is read again once without
  it and the parameter is never sent again. `item_limit` is kept out of the offline cache key.
  Every row with cards has `more: true` (Silo's "Explore all"): rows are capped and Home drops
  titles other rows show, so `total_count` cannot tell whether the page holds more. The full page
  is `fetchMoreHubItemsPage` → `GET /catalog?source=section&section_id=&scope=home|library`.
- **Movie box sets** (Silo Android #646; newer than the scratchpad OpenAPI, so routes follow the
  Android client exactly): `GET /user/libraries` rows may carry `box_sets_enabled`; `fetchLibraries`
  records them (`_boxSetLibraryIds`), and nothing box-set related is ever sent to a server without
  the flag. Library browse **never** sends `group=box_set` (Silo Android #796: the server dropped it
  from the catalog group enum and answers 422), so a grid lists a collection's movies as titles. A
  card `type: "box_set"` (search, the movie page row) carries a `box_set` object (`id`, `library_id`, `title`, `overview`, `poster_url`, `backdrop_url`,
  `movie_count`, `played_count`, `first_year`, `last_year`). `SiloMappers.boxSet` makes them
  `MediaKind.collection` items with id `silo-boxset:<library>:<box set>` (leaf counts = movies /
  played), so the grid, search chips and `CollectionDetailScreen` show them unchanged. The box set
  page is `GET /catalog/box-sets/{id}?library_id=` (fields + `items` in release order; 404/410 =
  gone → `fetchItem` null); `fetchCollectionPage`/`fetchChildren`/`fetchPlayableDescendants` read it.
  Play (`JellyfinSequentialLauncher`) starts at `SiloMappers.boxSetStartIndex` (first not watched,
  else the first). Search runs `GET /catalog/box-sets?q=&limit=5` beside the titles while any library
  has box sets, prepends them, waits at most 1.5 s for them and shows none on failure (the app's
  search ranking may still reorder them). A movie page's related hubs start with a box set row
  (`GET /catalog/items/{id}/box-set[?library_id=]`, `{}` = none; only movies, only while its library
  has box sets): the films, then the box set card (Silo's "Explore all"). Never send `image_size` or
  other unknown query params to these routes (422 `unknown_parameter`). Silo collections and box sets
  are read-only: Delete / Remove from collection / Add to collection are hidden for Silo items.
- **Sort fields** unknown to the server return 422 — map only known ones (`_sortFields`).
- **Playback (protocol v3):** `GET /playback/capabilities` must be `available`, list protocol 3
  and the `sequenced_progress_v1` feature (Silo's apps refuse playback otherwise) → keep `installation_id` (409
  `installation_changed` → refetch and retry once). `POST /playback/start` with `declared` evidence
  (mpv/ExoPlayer decode almost everything; `exact` would need per-decoder `video_decode[]`).
  HDR: Plezy does not probe the panel, so `output.display.hdr_evidence` is `unknown`, which makes
  the server refuse every native HDR/Dolby Vision output. `original_http` therefore carries the
  validated claim `client_managed_dynamic_range_v1` (the player tone-maps itself, as with Plex),
  and `output.hdr_details` is always sent with `display`. Dropping either makes 4K HDR HEVC
  transcode to SDR H.264. `codecs_video_hardware` lists every codec `VideoDecodeCapabilities`
  accepts. `form_factor` is `mobile` on phones *and* tablets, `tv` on TV, `desktop` otherwise. `progressive`
  is declared but disabled, as Silo's apps do. `start_position` is 0 and Plezy seeks to resume.
  `quality_preference` is never `original` (Silo Android #613; older servers read it as "never
  convert"): the Original preset sends `auto`, presets send `720p`/`1080p`/`2160p` or `auto` plus
  `bandwidth_cap_kbps`. An `original_http` answer to a capped preset is legitimate when the source
  fits it; the "transcode unavailable" fallback is reported only when `playback_plan.source`
  (`height`, `bitrate_kbps`) exceeds the preset (`SiloPlaybackCaps.refusedCappedPreset`).
  Markers: every `marker_segments` occurrence is its own `MediaMarker` (Silo Android #694; the
  singular `intro`/`credits`/… fields hold only the first), sorted by start then end, unknown kinds
  and empty ranges dropped; the player skips each range to its own end and offers the next episode
  only from a credits range that reaches the end of the file, i.e. the last one. They are read
  from `GET /watch/{id}?file_id=<playing file>` (the server fills that version's on-demand
  markers; cached per file) and `playbackExtras` picks that version. A progress 404/410 drops the
  session row (later reports go through `/sync/progress`).
- **Resume points:** `SiloMappers.resumeOffsetMs` ports the TV app's `resumePositionSeconds`:
  none at ≤ 30 s or ≥ duration − 5 s; a played item keeps its position (re-watch stopped midway).
- **External players** get a `/direct-download/links` URL (header-free, Range, no session). Only a
  server without those links (or a 403) falls back to an untracked original-file session with
  `token=`, left to expire: an external player never reports to it.
  Progress: `POST /playback/{sid}/progress` with a strictly increasing `sequence`; stop:
  `DELETE /playback/{sid}` with a JSON body and a `stop_id` (and stop `sequence`) minted once; a
  failed stop keeps the session and is retried with the same `stop_id` on the next reload.
- **Subtitles:** the plan's `subtitle.inventory`; for `original_http` only `source:external`
  entries become sidecars (embedded ones are in the file). Subtitle routes have no signed `st`, so
  their URLs carry the short-lived access token as `token=` for players that do not forward
  headers. Such URLs live only in memory for one playback or download; never persist them.
- **Subtitles the server cannot show** (Silo Android #776): inventory rows may carry
  `unplayable: true` (e.g. an MKV `S_TEXT/WEBVTT` track stored without a codec; selecting it ends
  in `subtitle_codec_unsupported`); from older servers an **embedded** row with no codec counts the
  same (`SiloSubtitleRules.isUnplayable`; watch-detail rows use `external` instead of `source`).
  They are dropped from `MediaSourceInfo.subtitleTracks` (the other rows keep their index + 1 ids),
  from sidecars, from the detail page's streams, from download subtitle specs and from AI translate
  sources. Plezy's track sheet has no disabled rows, so they are hidden rather than listed disabled.
  On direct play mpv still lists the file's own embedded tracks (it demuxes the file itself; the
  server is not involved). Plezy's start request never names a subtitle.
- **Stored subtitles** (provider downloads and AI results) are inventory rows with `source: "downloaded"` and
  `sync_key: "stored-<id>"` (the sidecar URL also carries `downloaded_subtitle_id=<id>`); they are not in the watch
  detail's `subtitle_tracks`. They become sidecars on every delivery (direct play too) and get their own
  `MediaSubtitleTrack` with id `SiloSubtitleRules.storedTrackIdBase + <id>`, stable across reloads (a session's
  `combined_index` is not).
- **Subtitle search / download:** `POST /subtitles/search {media_file_id, languages}` → `{results, warnings}`;
  `POST /subtitles/download` (provider, subtitle_id, language, release_name, score, hearing_impaired) → `{subtitle}`
  stored on the server. No capability probe: "no providers" arrives as an error or a warning.
- **AI subtitles** (`/subtitles/ai/status|quota|translate|jobs/{id}|jobs/{id}/cancel`): status gates the row
  (`enabled` = translate, `transcribe_enabled` = transcribe; transcription without translation stays in the spoken
  language and sends no target). `translate` reads a subtitle `combined_index` (embedded non-bitmap, external or stored
  SRT/VTT); the transcribe kinds read an audio `index` (`transcribe` when the audio is already in the target). The
  request names `session_id` (Silo Android #726: a foreground job from the playhead); a 404 is resent once without it.
  Plezy polls every 2 s (transport errors keep polling, 404 = gone; the job read is the authority). **Live cues**
  (Silo's web player behaviour; Silo's Android apps ignore them): before the POST, `openAiLiveSocket` reads
  `GET /playback/sessions/control/capabilities` (`available`, `protocol` = `silo.playback-control.v2`), mints
  `POST /playback/sessions/{sid}/control/ws-ticket` (`installation_id`) and opens `…/control/ws` offering
  `silo.playback-control.v2`, `silo.ticket.<ticket>` (never in the URL), then sends a hello advertising no commands
  and never answers command frames. It must be open before the job exists (no replay). The 202's
  `live_delivery_attached` says the stream is ours; `subtitle_translation_cues` carry `{start,end,text}` in source
  seconds, playhead-first then wrapping, `job_id`/`file_id` as JSON numbers (the v2 job id is the same decimal as a
  string). `silo_live_subtitles.dart` holds the sorted cue track and parser; `SiloLiveSubtitleOverlay` draws the
  lines while the player's subtitle is hidden (`setLiveCuesShowing`), until the stored track is applied, the job
  fails, or the user picks a track (`stopLiveCues`). A socket that opens after the 6 s budget is closed. Applying a stored result:
  `onPlaybackSourceChanged(newSubtitleChoice: source(storedTrackId))` reloads (a fresh `/playback/start` lists it);
  `playback_reload.dart` asks the reload for that `source:<id>` even though the current track list lacks it (Silo only).
- **Downloads:** `POST /direct-download/links` → header-free link to the original file (Plezy's
  downloader sends no headers). The container rides in the URL fragment (`#container=mkv`), read by
  `downloadExtensionFromUrl`. External subtitle files are listed from a direct-play session opened
  only when the file has any, then left to expire. Never put the account token in a download URL.
- **Progress without a session** (downloaded file, offline queue): `POST /sync/progress` with
  `{media_item_id, position_ms, duration_ms, updated_at}`; a stop past `watchedThreshold` posts
  `/watched/{id}` instead.

- **Dismissals:** `PUT /home/dismissals/continue_watching/{id}` requires `progress_updated_at`
  (refetch the item detail when the card lacks it); `next_up` requires `series_id`.
- **Trailers & extras:** both come from the item detail (`GET /catalog/items/{id}`), which
  `fetchItem` keeps for 10 min (`_detailRows`, in-flight shared) so `fetchExtras` /
  `fetchRemoteTrailers` add no request. `extras[]` (local files: `content_id`, `kind`, `title`,
  `duration_seconds`, `file_id`, newer servers `still_url`/`still_thumbhash`) become
  `MediaKind.clip` items with raw marker `plezy_silo_extra` (`SiloMappers.isExtra/extraFileId/
  extraKind`); the Trailer button picks `kind == "trailer"`. Silo's apps play an extra with its
  `content_id` + `file_id` through normal playback (progress included), so Plezy does too:
  `getPlaybackInitialization` selects the extra's `file_id` and, if `/watch/{id}` answers 404/422
  for it, starts that file directly. Extras are clips, so the menu offers no download.
  `videos[]` (`kind`, `site`, `site_key`, `name`, `is_official`, `language`): YouTube only
  (`site` case-insensitive, non-blank `site_key`), de-duplicated, in server order, as
  `RemoteTrailer`s; the row is local extras first, then YouTube (`buildExtrasRail`). Stills come
  from `i.ytimg.com/vi/<key>/hqdefault.jpg` (`ytimg.com` is a pinned system-CA domain in
  `network_security_config.xml` / `CertificateTrust`).
- **Opening YouTube** (`youtubeTrailerRouteFor`): Android phones/tablets, Android TV/Fire TV, iOS
  and macOS play in
  YouTube's unmodified IFrame player (`youtube_player_iframe` → webview_flutter) with
  privacy-enhanced host and `origin` `https://www.youtube-nocookie.com` (a missing origin/referrer
  gives errors 152/153); any player error (101/150 embedding disabled, …) hands off to the app or
  browser. On a TV (the user's choice, unlike Silo's TV app) the bar above the player adds Back
  10 s / Play-Pause / Forward 10 s, the remote's media keys drive the player, and the web view is
  wrapped in `ExcludeFocus` (focus inside YouTube's page could not get out). Only Android
  Automotive, and any player error, hands off through
  `com.plezy/external_player` `openViewIntents`: `com.google.android.youtube.tv` with the watch
  page, then `vnd.youtube:<id>`, then the watch page. Windows/Linux open the browser (no web view
  there; never build a `YoutubePlayerController` on them). tvOS opens `youtube://watch/<id>`
  through the Runner's `openUrl`. Never extract streams (youtube_explode etc.): YouTube's terms.
- **Seek previews** (`trickplay_v1`, Silo Android #695): `createScrubPreviewSource` reads the
  watch detail (cached) and only when the streamed version (`MediaSourceInfo.mediaSourceId` = file
  id) has `trickplay_available: true` asks `GET /watch/{id}/trickplay?file_id=`. The manifest is
  refused (time-only tooltip) for another file id, any size outside 1..8192, a sheet side over
  8192, sheet indexes not exactly `0..ceil(count/(cols*rows))-1`, or a non-http(s) URL. Thumbnail
  i covers `[i*interval, (i+1)*interval)`; past the end shows the last. Sheet URLs are signed
  credentials: fetched with `SiloApi.rawHttpClient` and **no headers at all** (presigned storage
  may be another host), never logged. Sheets are held in a 12 MB LRU and served to the tooltip as
  a `SheetScrubFrame` through a private `ImageProvider` keyed by (service, layout generation,
  sheet, attempt). URLs are renewed 60 s before `expires_at` or when a sheet answers
  401/403/404/410 (one shared read, 30 s back-off); a renewal with another layout drops held
  sheets, a refused one (4xx other than 429, unusable) withdraws the previews. Unlike Android, a
  manifest that fails at open is not retried later in that playback (the player builds the seek
  bar's thumbnail hook only for an available source). Offline playback never asks.
- **Card overlays** (Silo's profile-chosen badges; silo-server `docs/architecture/card-overlays.md`, the web
  renderer, ported from Silo's Roku app e8244ee `overlays.bs`/`overlayDraw.bs` and Silo Android's
  `OverlayRegistry` incl. #816's `resolution_hdr_audio`): `SiloClient.cardOverlays` reads
  `GET /settings/overlay-config` (`enabled`, `defaults` = the document as **JSON text**, `images[]` {ref,
  width, height}) and `GET /settings/values/effective?keys=ui.card_overlays&keys=ui.card_overlays_enabled`
  together (one in-flight future; first Silo card, then every Home load via `_homeSections`, at most every
  30 s). A value counts only with `source: profile` (or no source). The profile's document wins, else the
  config's `defaults`, else the built-in one (classic, registry defaults); `ui.card_overlays_enabled` wins,
  else the config's `enabled`, else on. A 404 on either route counts as "nothing there"; any other failure
  keeps what applies, and before the first answer cards draw Plezy's own indicator. The document: v2
  (`version: 2` or `preset`+`items`) or v1 (badges by id, migrated); seven presets (minimal, classic,
  vibrant, pill, square, plate, band; unknown = classic); `style` overrides (size 0.75–2, shape, 8-digit
  background/border, 6-digit text colour, integer borderWidth 0–3, fontWeight, uppercase, shadow); per badge
  `enabled`, `position` (`top-left`, `bottom-left`, `bottom-right`, `left-edge`, `right-edge`; a stored
  `top-right` moves to the right rail, the corner belongs to the watch status), `accentColor`, `showIcon`,
  `image` and `valueImages` (refs `<64 hex>.webp`, only those the config lists; loaded from
  `<base>/api/v2/overlay-images/<ref>` through `MediaImageHelper.serverArtworkProvider`, no credentials; a
  failed one is dropped and its badge draws without it). Caps: 3 a corner, 4 a rail; a badge without a
  value takes no slot. An enabled `resolution_hdr_audio` hides resolution, hdr, audio and resolution_hdr;
  `resolution_hdr` hides resolution and hdr (the document is untouched). Data comes from the card's raw JSON
  (`SiloOverlayData.ofRaw(item.raw)`, cached per JSON object): `overlay_summary` (also on season episode
  rows), the four ratings, `content_rating`, `advisory_age`, `year`, `runtime`, `original_language`, first
  `studios`/`networks`, `show_status`; no new `MediaItem` fields (raw already round-trips). A poster scales
  the web lengths by width/185; wide cards (landscape, episode stills) draw at 1;
  a card with a progress bar (active progress, or a partly watched season's bar) lifts its bottom
  row by one inset, posters too (`SiloOverlayLayoutMath.insets`, Silo Android #882). The top row stops short
  of the top-right corner (38 px × k). Watch status (Silo Android #882, the web's `CardWatchStatus`): on a
  Silo **poster** the corner is always Silo's, whether or not badges are on or loaded: the emerald
  (#00BC7D) Lucide check for a watched item, or the episodes left (font 11 × k, 0.4 em a side + 1 px
  border, tabular figures) on a started, unfinished series/season (leaf counts, else
  `user_state.watched_count`/`unplayed_count`); `WatchedIndicator(showWatchStatus: false)` drops Plezy's
  check and unwatched pill there (progress bars stay). Silo draws no watch status on landscape artwork, so a
  **wide** Silo card keeps Plezy's check (the one indicator) and only adds badges. Plezy's "watched
  indicators"/"unwatched count" settings still gate Silo's corner. Bottom corners: one row per level from
  the bottom, a pair too wide wraps the right badge under the left (`SiloOverlayLayoutMath.bottomRows`, the
  web's `BottomRows`). Glyphs are Lucide's (lucide-react 0.576.0) and the web's Dolby Vision mark,
  drawn from path data by `lib/widgets/silo_overlay_icons.dart` (own SVG path reader; Lucide licence on the
  licenses page); wordmarks are weight 900 at 10/12 of the icon (ATMOS 9/12 with 0.5/9 em tracking);
  badge text has the presets' `tracking-wide`/`-widest`; CSS blur lengths go through `siloCssBlurRadius`;
  an uploaded icon is capped at the badge's content width. Values are kept as the API sent them (no
  trimming), so `valueImages` keys match the web's. Plex/Jellyfin/Emby cards never look a store up
  (`CardArtworkOverlays.storeFor` returns null for non-Silo items).
- **Limits:** `GET /catalog/people` caps `limit` at 100; catalog pages at 200.
- **Offline:** `fetchItem` falls back to `SiloApiCache.getMetadata` (the pinned download row) on a
  transient error; watch detail is read through the cache too.
- **Artwork and third parties:** never pass `streamHeaders` with Silo image URLs (Discord RPC skips
  them); presigned URLs may point at object storage on another host.
- **Downloads scope:** a profile's Silo downloads use its own Silo connection as the cache scope
  even on a cold start (`DownloadManagerService._siloProfileScopeId`).
- **Several accounts on one server** (Silo Android #795): already supported by identity, since a
  `SiloConnection` id is `server/user/profile` (user id from `account/me`). Each has its own row,
  encrypted tokens, client (`_jellyfinByCompoundId`), cache scope (`cacheServerId` = connection id),
  download owner scope and logout. Re-signing in as the same user and Silo profile yields the same id,
  so it updates in place. Limit: the manager keeps **one active client per server id**, so a Plezilo
  profile uses one account per server. `lib/profiles/silo_accounts.dart` enforces it:
  `add_silo_screen` puts a second account on a server the chosen profile already uses into a new,
  non-activated local profile (`persistAndBindConnection(activateFirstRunProfile: false)`, snackbar
  names it); the binder binds one Silo connection per server (`shadowedSiloConnectionIds`: default,
  then last used, then lowest id, the same order as `_siloProfileScopeId`); Borrow hides another
  account on a server the target already uses. Profile detail and Borrow name the account
  (`siloAccountLabel`). Tests: `test/services/silo/silo_multi_account_test.dart`,
  `test/profiles/silo_accounts_test.dart`.

## Known review findings (October 2026)
Fixed: page-size-bound cursors and `seek`; synthetic-season writes hitting the series; stop retry;
refused refresh resent on every call; missing `sequenced_progress_v1` check; IMDb score scale;
`duration_seconds` on versions; parallel Home/season loads; concurrent `addSiloConnection`;
device-code expiry/remint and PIN lockout (429) messages; sign-in slice (2026-10-28): tvOS deferred
URL keyboard, code renewal/denied/unreachable/429 states, no cancel after approval, logout of abandoned
sessions, PIN problem details, typed i18n errors, probe follow-up timeouts, a11y labels (spoken code,
QR, PIN/Kids tile state), Kids caption. Client slice (late October): quality `original` → `auto`,
re-watch resume, capped-preset snackbar, refresh refusal/stale-token 401, health, markers per file,
form factor cache, session rows, external-player sessions, persisted token lifetime. Integration slice: servers going offline/auth-error on their own, rotated token kept on client
replacement, logout on removal, no access token in borrowed join rows. Declined: 4-digit
PIN length (matches Silo's apps). Open follow-ups: an edit screen for an existing Silo connection (address, re-sign-in)
— today the user removes and re-adds it; music/audiobook libraries; OIDC sign-in.

## Deliberate differences from Silo's apps
- Quality changes start a fresh `POST /playback/start` for the same `file_id` (no staged replans),
  so the server never moves Plezy to another version mid-play; Silo #684 (adopt a cross-version
  replan with subtitles off) does not apply. Subtitles are chosen client-side.
- Downloads use direct links, not Silo's managed `/downloads` registry (whose file, manifest and
  artwork routes need auth headers). Plezy's downloads therefore do not show in Silo's download list.
- No OIDC/browser or network-identity ("Continue as") sign-in, no cleartext-HTTP consent prompt —
  Plezy's other backends have none either. Phones may also start a device code.
- Sign in from a phone: several accounts per session are saved only after the session ends, each with
  a Silo profile picked on the TV (Silo's TVs save accounts at once and pick a profile later on "Who's
  watching?"); no Change Account screen, a summary instead; the add-server screen advertises only
  on Android TV / Fire TV (`SiloPairingHost.supported`; phones and tablets would be listed as TVs
  by Silo's phone app, and they can scan the QR code); no cleartext-consent store (each plain-HTTP push is flagged on the consent screen instead).
- Remote Stop (Silo Android #809): `isPlayerStopKey` in `lib/focus/transport_keys.dart`; the player screen's key handler exits with `_exitPlayerRoute(stop: true)` on the first down and swallows repeats/up (TV navigation only, not Apple TV).
- YouTube trailers: Silo's apps always hand them to the YouTube app; Plezy plays them in YouTube's
  embedded player on phones, tablets, Android TV / Fire TV and macOS (falling back to the app).
  The TV detail rail holds playable `MediaItem`s only, so on TV a YouTube trailer is reached
  through the Trailer button (first YouTube `trailer`, else `teaser`, when there is no local
  trailer); the phone/desktop row shows every YouTube video after the local extras.
- Administrator-revoked downloads (Silo Android #673, `revoked_removes_local`) do not apply:
  that flag marks rows of the managed `/downloads` registry, and Plezy's direct-link downloads
  create no registry rows, so there is nothing the server can report revoked or for Plezy to
  `DELETE /api/v2/downloads/{id}`. Revisit if Plezy ever moves to the registry.
- Series-wide audio/subtitle memory (Silo Android #680: `PUT|DELETE /api/v2/audio-prefs/{series_id}`
  and `/subtitle-prefs/{series_id}` with track signatures, read back as `effective_audio_track_index`
  / `effective_subtitle_*` on the watch and item detail) is not implemented: Plezy's
  `TrackManager` persists per file part (Plex) or through account flags (Jellyfin), and Silo's
  subtitle start is resolved client-side; honouring it needs a series-scoped persister in the
  shared player plus a resolver for the signatures. Plezy saves no Silo track pick to the server.
- Box sets reuse Plezy's collection UI: no "Box set" badge, sleeves or "THIS FILM" outline, the
  card caption is the film count, Play queues the films from the next unwatched one (Silo plays
  that one film), and the movie page's row shows every film (Silo fits as many as the screen holds).
  Embedded subtitles drawn from the stream (Silo Android #770: `hls_subtitle_renditions_all_v1`,
  `native_embedded`) are not declared: Plezy keeps server sidecars.
- Theme music (Silo Android #678) is not offered: Plezy plays no theme music for any backend.
- Card overlays: Plezilo only reads the document (no editor, like Silo's TV apps), so Silo Android #882's
  save rules (settings revision, passthrough ids) do not apply. List-mode rows keep Plezy's indicator (no
  badges on their small thumbnails). Dolby Vision draws the web's own ring mark (no Dolby artwork ships) and
  the other brand marks are bold text. Text is the app's font; shadows blur for real (Flutter can). Wide
  Silo cards keep Plezy's watched check where Silo shows none. The request-status badge never has
  data (Plezilo lists no watchlist titles outside the library). Changes made in Silo's web client show on the
  next Home load, not live.
- Music, audiobooks and e-books are not mapped (`SiloMappers.item` returns null; those libraries
  are hidden). Silo's own TV app keeps music minimal; the v2 contract has no album/track types.

## Testing
- Sign-in: `test/test_helpers/silo_auth_fake.dart` (`FakeSiloAuthServer`: scripted start/poll/PIN
  answers, records requests) drives `test/services/silo/silo_device_sign_in_test.dart` (fake_async),
  `silo_auth_service_test.dart` and the widget tests in `test/screens/settings/add_silo_screen_test.dart`
  (pass `authService:`; the code panel has a perpetual spinner, so pump bounded frames, never
  `pumpAndSettle`; unmount at the end so the flow's timers stop). Keep the panel free of intrinsic
  sizing: `QrImageView` is a `LayoutBuilder` and asserts under `SliverFillRemaining(hasScrollBody: false)`.
- Temporary passwords: `FakeSiloAuthServer.temporaryPassword` / `restrictedTokens` script the
  restriction (login/refresh issue restricted tokens while it is set; `/account/password`,
  `/account/password/capability`, `/auth/refresh` and `/account/me` answers are overridable);
  `test/services/silo/silo_password_change_test.dart` covers the wire, the session and the controller,
  and `add_silo_screen_test.dart` the phone form and the TV message. Siku's mock server has no
  temporary-password switch.
- Sign in from a phone: `test/services/silo/pairing/` covers the frames and golden messages, the receiver
  state machine over an in-memory transport (`FakePairingTransport`, `FakePairingPort` in
  `test/test_helpers/silo_pairing_phone.dart`), the flow glue and `probeIdentity`, and
  `silo_pairing_host_test.dart` plays Silo's phone (`SiloPairingPhone`) over real loopback sockets
  against `SiloPairingHost` (secret, one phone at a time, malformed frames, advertisement between
  sessions). `siloPhoneSignInAccounts` (`SiloPairingPhone.signInAccounts`,
  `FakePairingTransport.signInAccounts`) plays the #810 phone: push after push, `approve` per
  `deviceStarted`, then `done`; `FakePairingPort.nextCodes` / `outcomesByCode` / `setupBindings` script
  several attempts. `FakeSiloAuthServer.hostIdentities` / `hostNames` / `profilesByToken` /
  `sessionBinding` and `approved(userId:, username:, accessToken:)` serve two servers and accounts.
  `test/screens/settings/add_silo_pairing_accounts_test.dart` saves accounts with the real persistence
  (in-memory drift, `_Binder implements ActiveProfileBinder`); read the database in the test zone while
  interleaving `runAsync` delays and pumps (a plain `runAsync` read deadlocks behind the screen's save). `add_silo_screen_test.dart` drives the screen end to end (consent, code, approval,
  profiles). The TLS-PSK handshake and NSD need a real Android device and Silo's phone app.
- Manager integration (`test/services/silo/silo_server_manager_test.dart`): `MultiServerManager(
  siloClientFactory: ...)` injects `SiloClient.forTesting` clients over a small fake server with a
  rotating refresh token; status tests run under `fakeAsync` (5 s debounce).
- Unit tests: `scripts/run_tests.sh test/services/silo` (mappers, connection/vault, client with an
  `http/testing.dart` `MockClient`, headers/form factor). Client tests cover cursor `seek`/restart,
  synthetic-season writes, refused refresh, playback start/progress/stop, downloads, sessionless
  progress, extras/remote trailers, box sets (browse grouping, page, search, movie row, servers
  without the flag) and seek previews (`silo_trickplay_test.dart`: manifest
  validation, tile mapping, sheet cache/renewal, header-free sheet fetch) (plus `test/media/remote_trailer_test.dart` and
  `test/utils/youtube_trailer_launcher_test.dart`); add one for each contract rule you change. Capability mocks must list
  `features: ['sequenced_progress_v1']`. Mock-client handlers must
  `Uri.decodeComponent(request.url.path)` — ids are percent-encoded on the wire.
- Card overlays: `test/services/silo/silo_card_overlays_test.dart` (document/style parsing, settle and
  enabled precedence, labels incl. "4K DV Atmos", placement, caps, suppression, looks/paint, store sharing,
  404/failure/known value, failed images; #882's top-right → right rail, insets/progress lift, bottom-row
  wrap cases from Android's `OverlayLayoutMathTest`, count width, the preset table),
  `test/widgets/silo_overlay_icons_test.dart` (SVG path reader, icon bounds),
  `test/widgets/silo_card_overlays_test.dart` (a Silo `MediaCard`
  with an injected store via `CardArtworkOverlays.debugStoreResolver`, Plex/Jellyfin/Emby unchanged, overlays
  off, layout geometry) and the `card overlays` group in `silo_client_test.dart` (routes, `keys` repeated,
  profile header). Mock handlers that count every request must let `/api/v2/settings/` through (Home loads
  read them). Widget tests render with the test font (boxes), so check sizes and `find.text`, not
  pictures.
- Tests that read caches need `AppDatabase.forTesting(NativeDatabase.memory())` +
  `SiloApiCache.initialize(db)` (and `PlexApiCache` for the fallback).
- End to end against Siku's mock server (any username, password `silo`; profile "Kids" PIN `1234`;
  device code approves on the third poll):
  ```bash
  git clone --depth 1 https://github.com/edrock200/Siku /tmp/siku
  (setsid nohup python3 /tmp/siku/tools/mock_server.py --port 8097 > /tmp/mock_silo.log 2>&1 &)
  ```
  Then write a throwaway `flutter test` that drives `SiloAuthService` and `SiloClient` against
  `127.0.0.1:8097`. Do **not** call `TestWidgetsFlutterBinding.ensureInitialized()` in it: that
  binding answers every real HTTP request with 400. Pass `httpClient: http.Client()` and set
  `DeviceIdentityService.debugOverride(...)`. Delete the file afterwards. The mock lacks ratings and
  direct-download routes (404), and its capabilities may omit `sequenced_progress_v1`, which makes
  Plezy refuse playback against it; test playback with `MockClient` handlers instead.
- Stop the mock with `kill <pid>` from `ps -eo pid,args | grep "[m]ock_server"`, not `pkill`.
- What cannot be verified in a cloud session: real playback, TV focus on a device, how card overlays
  look on real screens and against a real server's documents and uploaded images, real Silo
  servers, phone sign-in discovery and TLS (needs a device on a LAN with Silo's phone app; read
  `adb logcat -s SiloPairing` and the `[silo-pair]` app log lines). Say so in the report.

## Debugging user reports
- **"Signed out" / auth banner:** refresh refused (`session_expired`) → re-add the server. Check the
  persisted connection got the rotated refresh token.
- **403 `profile_verification_required`:** PIN profile without a valid `X-Profile-Token`.
- **422 `header.x-profile-id`:** a call made with `profile: false` that needs the profile.
- **4K HDR transcodes to H.264:** check the plan log line's `reason`; the claim and
  `output.hdr_details` above must be present in `client_playback_context`. A preset other than
  Original also forces a transcode.
- **Playback refused:** read the `Silo playback plan: delivery=… reason=…` log line; a
  `terminal.message` from `outcome: adaptation_unavailable` is shown to the user verbatim.
- **Download "needs a newer server":** the server lacks `/direct-download/links`.

## Added in 2.25.15 (review fixes + five features)
- **Edit / Sign in again** (`silo_connection_edit.dart`, part `add_silo_screen_edit.dart`): the edit address must answer
  `/system/identity` with the saved `serverId`; the same id (server/user/profile) replaces the row in place (id, bindings and
  download scope kept) and revokes the old session with the old tokens only (via `removeSiloConnection` before saving, so the
  old client can't write its rotated pair over the new row); an address-only save re-reads the row and saves only if unchanged
  (3 tries); another id gets a confirmation step, then the multi-account rule.
- **Series track memory** (`silo_track_prefs.dart`, `silo_series_track_choices.dart`, part `silo_client_track_prefs.dart`):
  `PUT /audio-prefs/{series_id}` `{audio_track_index (position in audio_tracks), audio_language?, track_signature?}` and
  `PUT /subtitle-prefs/{series_id}` `{subtitle_language, subtitle_track_index (= combined_index), subtitle_mode,
  track_signature?}` (Off = `"", -1, "off"`); episodes only; start applies the server's effective choice (direct play audio;
  subtitles via a port of `resolveAutoSubtitle`, Off reaches the player as `defaultSubtitleStreamIndex: -1`); manual picks are
  debounced 1.5 s, one in flight per series/kind, retried once, held in memory only; no DELETE (no Auto row).
- **Audiobooks** (`silo_audiobook.dart`, `silo_audiobook_player.dart`, part `silo_client_audiobooks.dart`,
  `lib/screens/silo/silo_audiobook_*`): mapped as `MediaKind.album` + `raw['type']=='audiobook'`, opened from
  `navigateToAlbum`; one session per part (`progress_persistence: client`), whole-book `/sync/progress`; #708 rules in
  `SiloAudiobookSessionRules`. Music stays hidden: the v2 contract has no music kinds. No mini-player/bookmarks/sleep timer.
- **Requests & Calendar** (`silo_requests.dart`, `silo_calendar.dart`, part `silo_client_requests.dart`,
  `lib/screens/silo/silo_feature_entries.dart`): profile-menu rows; requests gated by `/requests/status`
  (`SiloRequestsApi.enabled`, 30 s fresh, keeps the last answer on failure); creates/cancels never resent ("uncertain" holds
  the action); calendar regroups by device-local day, time zone sent is a best guess (`siloCalendarTimeZone`). Never add Silo
  reads to `_homeSections` (the request-counting tests in silo_client_test break).
  Remove a failed request (Silo Android #792): `SiloMediaRequest.isRemovableFailure` (outcome `failed`, no target
  `completed`), offered only while `/requests/status` says `remove_failed_supported` (`SiloRequestsApi.removeFailedSupported`,
  `canRemove`); the confirmation names the title with Keep focused (`confirmSiloRequestRemoval`); `removeFailed` sends one
  `DELETE /requests/{id}` (204, and 404 = removed elsewhere; both are announced on `requests.removals`, which My requests,
  the detail page and search's "Available to request" listen to: row dropped, title requestable via `SiloRequestState.without`).
  409 `conflict` → re-read + "changed since the list loaded"; 409 `capability_*` → status re-read; uncertain → a re-read
  decides, nothing held (a resend that landed answers 404). The 404 shows "Request removed" too (Silo shows nothing).
- **TV voice search** (Silo Android #830; not Silo-specific): `VoiceSearchService` (`com.plezy/voice_search`,
  `VoiceSearchChannel.kt`) hands listening to the system recogniser (`ACTION_RECOGNIZE_SPEECH`, free-form, no language or
  max-results extras, the assistant/voice-interaction package preferred over the recognition service when several handle
  it; manifest `<queries>` entry needed). Android TV hardware only (`isTVDevice`, not force-TV), hidden when nothing
  resolves; the mic sits right of the field (`SearchInputField.onVoiceSearch`, RIGHT field → mic → clear) and a result
  goes through `submitSearchQuery` (results take focus). No RECORD_AUDIO for it; 2.25.11's Gboard mic request is separate.
- **Managed downloads** (`silo_download_registry.dart`, `silo_managed_downloads.dart`, part `silo_client_downloads.dart`):
  used when `/capabilities/downloads` lists `bounded_creation` + `ordered_status`; reconcile then `POST /downloads` with
  `expected_revision`; PATCH status events; DELETE (queued up to 30 days offline); originals keep the header-free direct link,
  prepared copies use `/downloads/{id}/file` with auth headers on the task (stored in app-private task records); revocation
  removes local copies when `revoked_removes_local`.
- **Review fixes**: Silo tokens go through `LogRedactionManager.registerRotatingToken`; plain-HTTP consent in `_probe`;
  `checkHealth` never calls `onServerUnreachable` (probe `reportUnreachable: false`, backed-off re-check 30 s → 10 min); a
  re-sign-in that replaces a session logs the old one out; the overlay store is disposed with its client;
  `sortedBySiloBindingPreference` is the only account-order rule. Open: `removeServer` still closes Silo clients without
  logout. (Linux packaging was renamed to `com.edrock200.plezilo` / `plezilo` on 2026-11-12.)

- Profile tracks on movies (2026-11-12, the user's request): `_seriesStartAudio` / `_seriesStartSubtitle` apply the watch detail's `effective_audio_track_index` / `effective_subtitle_*` to movies too (`profileTracks`: not extras); series pending picks and PUTs stay episode-only. Plezilo's Default subtitles setting (TrackSelectionPriority.appDefault, 1b) still runs before the server's selection (priority 2).
