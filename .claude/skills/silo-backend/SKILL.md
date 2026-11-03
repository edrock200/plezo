---
name: silo-backend
description: How Plezilo's (this Plezy fork's) Silo media-server backend works and how to change, test and debug it. Use whenever you touch lib/services/silo/, the Silo sign-in screen (lib/screens/settings/add_silo_screen.dart), SiloConnection, SiloMediaItem or SiloApiCache; when a Silo user reports sign-in, browsing, playback, subtitle, download or progress problems; when checking Plezy against Silo's API contract or its Android/Android TV apps; or when running the Silo mock server.
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
  advertisement), `st`, `srv`. Transport: **TLS-PSK**, key `silo-companion-pairing-v1`, identity
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
  phone. **Plezilo signs in to one server per session**: a push after a sign-in answers `failed
  auth_failed` (Silo's TVs take several). Tokens never cross the LAN. Golden frames are those of
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
  Keep query params identical across pages.
- **Ids:** opaque strings (`movie:heat-1995`); always `Uri.encodeComponent` them in paths. Episode
  cards name their season only by series + number, so they get a synthetic parent id
  `silo-season:<n>:<seriesId>` (`SiloMappers.syntheticSeasonId`); `fetchItem`/`fetchChildren`
  resolve it. Season lists use the server's real season `content_id`. Writes (watched, rating,
  favorite) on a synthetic season resolve it to that real id first — never to the series.
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
  Plezy polls every 2 s (transport errors keep polling, 404 = gone) and ignores live cues. Applying a stored result:
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
- **Limits:** `GET /catalog/people` caps `limit` at 100; catalog pages at 200.
- **Offline:** `fetchItem` falls back to `SiloApiCache.getMetadata` (the pinned download row) on a
  transient error; watch detail is read through the cache too.
- **Artwork and third parties:** never pass `streamHeaders` with Silo image URLs (Discord RPC skips
  them); presigned URLs may point at object storage on another host.
- **Downloads scope:** a profile's Silo downloads use its own Silo connection as the cache scope
  even on a cold start (`DownloadManagerService._siloProfileScopeId`).

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
- Sign in from a phone: one server per session (see above); the add-server screen advertises on
  Android phones and tablets as well as TVs (Silo's phone app then lists them as TVs); no
  cleartext-consent store (each plain-HTTP push is flagged on the consent screen instead).
- YouTube trailers: Silo's apps always hand them to the YouTube app; Plezy plays them in YouTube's
  embedded player on phones, tablets and macOS (falling back to the app), hands off only on TV.
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
  sessions). `add_silo_screen_test.dart` drives the screen end to end (consent, code, approval,
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
- What cannot be verified in a cloud session: real playback, TV focus on a device, real Silo
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
