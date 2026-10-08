---
name: silo-backend
description: How Plezy's Silo media-server backend works and how to change, test and debug it. Use whenever you touch lib/services/silo/, the Silo sign-in screen (lib/screens/settings/add_silo_screen.dart), SiloConnection, SiloMediaItem or SiloApiCache; when a Silo user reports sign-in, browsing, playback, subtitle, download or progress problems; when checking Plezy against Silo's API contract or its Android/Android TV apps; or when running the Silo mock server.
---

# Silo backend for Plezy

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
| `lib/services/silo/silo_auth_service.dart` | Pre-connection calls: address probing, password login, device-code flow, profiles, PIN, `buildConnection` |
| `lib/services/silo/silo_client.dart` | `SiloClient` (`MediaServerClient`): libraries, cursor paging, items/seasons/episodes, hubs, search, watch state, collections, images |
| `lib/services/silo/silo_client_playback.dart` | `part`: playback v3 start, sidecars, progress/stop, sessionless progress, downloads, markers |
| `lib/services/silo/silo_playback_caps.dart` | What the player declares (`client_capabilities`, `client_playback_context`) |
| `lib/services/silo/silo_mappers.dart` | Pure JSON → `MediaItem`/`MediaVersion`/chapters/markers; watch-detail helpers shared with offline playback |
| `lib/services/silo/silo_api_cache.dart` | `SiloApiCache`: serialized items (`silo:item/<id>`) and pinned watch detail for downloads |
| `lib/screens/settings/add_silo_screen.dart` | Add-server UI: address → code or password → Silo profile (+PIN) → persist and bind |
| `lib/connection/connection.dart` | `SiloConnection` (id `serverId/userId/profileId`) |
| `lib/services/cached_playback_metadata_service.dart` | Offline markers/tracks for downloaded Silo items |

## Contract rules the code depends on
- **Headers:** every request sends `Accept: application/json` and `X-Silo-Device-Id/-Name/-Platform`,
  `X-Silo-Client` (`Plezy`), `-Client-Version`, `-Client-Family`. Family is a closed set
  (`tv|mobile|tablet|desktop|web`) and selects `profile_client` settings rows, so tablets must say
  `tablet` (600 dp shortest side, decided once per process). Platform is `android-tv` on Android TV.
- **Profiles:** almost every content route needs `X-Profile-Id`; PIN-locked profiles also need
  `X-Profile-Token` from `POST /profiles/{id}/verify-pin`. A Plezy connection is one Silo profile.
  Auto-select a single profile only when it has no PIN (as Silo's apps do).
- **Tokens:** access tokens are short-lived; refresh proactively (≤ min(60 s, lifetime/2) left) and
  on 401 under one in-flight refresh. A refused refresh token is remembered and not sent again. **Refresh tokens rotate**: persist every new pair
  (`SiloClient.onConnectionUpdated` → `ConnectionRegistry.upsert`). `MultiServerManager` keeps the
  live client when a re-bind arrives with an older, already-rotated refresh token
  (`SiloClient.ownsRefreshToken`) — replacing it would revive a dead token.
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
- **Sort fields** unknown to the server return 422 — map only known ones (`_sortFields`).
- **Playback (protocol v3):** `GET /playback/capabilities` must be `available`, list protocol 3
  and the `sequenced_progress_v1` feature (Silo's apps refuse playback otherwise) → keep `installation_id` (409
  `installation_changed` → refetch and retry once). `POST /playback/start` with `declared` evidence
  (mpv/ExoPlayer decode almost everything; `exact` would need per-decoder `video_decode[]`).
  `form_factor` is `mobile` on phones *and* tablets, `tv` on TV, `desktop` otherwise. `progressive`
  is declared but disabled, as Silo's apps do. `start_position` is 0 and Plezy seeks to resume.
  Progress: `POST /playback/{sid}/progress` with a strictly increasing `sequence`; stop:
  `DELETE /playback/{sid}` with a JSON body and a `stop_id` (and stop `sequence`) minted once; a
  failed stop keeps the session and is retried with the same `stop_id` on the next reload.
- **Subtitles:** the plan's `subtitle.inventory`; for `original_http` only `source:external`
  entries become sidecars (embedded ones are in the file). Subtitle routes have no signed `st`, so
  their URLs carry the short-lived access token as `token=` for players that do not forward
  headers. Such URLs live only in memory for one playback or download; never persist them.
- **Downloads:** `POST /direct-download/links` → header-free link to the original file (Plezy's
  downloader sends no headers). The container rides in the URL fragment (`#container=mkv`), read by
  `downloadExtensionFromUrl`. External subtitle files are listed from a direct-play session opened
  only when the file has any, then left to expire. Never put the account token in a download URL.
- **Progress without a session** (downloaded file, offline queue): `POST /sync/progress` with
  `{media_item_id, position_ms, duration_ms, updated_at}`; a stop past `watchedThreshold` posts
  `/watched/{id}` instead.

- **Dismissals:** `PUT /home/dismissals/continue_watching/{id}` requires `progress_updated_at`
  (refetch the item detail when the card lacks it); `next_up` requires `series_id`.
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
device-code expiry/remint and PIN lockout (429) messages. Declined: 4-digit PIN length (matches
Silo's apps). Open follow-ups: an edit screen for an existing Silo connection (address, re-sign-in)
— today the user removes and re-adds it; music/audiobook libraries; OIDC sign-in.

## Deliberate differences from Silo's apps
- Downloads use direct links, not Silo's managed `/downloads` registry (whose file, manifest and
  artwork routes need auth headers). Plezy's downloads therefore do not show in Silo's download list.
- No OIDC/browser or network-identity ("Continue as") sign-in, no cleartext-HTTP consent prompt —
  Plezy's other backends have none either. Phones may also start a device code.
- Music, audiobooks and e-books are not mapped (`SiloMappers.item` returns null; those libraries
  are hidden). Silo's own TV app keeps music minimal; the v2 contract has no album/track types.

## Testing
- Unit tests: `scripts/run_tests.sh test/services/silo` (mappers, connection/vault, client with an
  `http/testing.dart` `MockClient`, headers/form factor). Client tests cover cursor `seek`/restart,
  synthetic-season writes, refused refresh, playback start/progress/stop, downloads and sessionless
  progress; add one for each contract rule you change. Capability mocks must list
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
  servers. Say so in the report.

## Debugging user reports
- **"Signed out" / auth banner:** refresh refused (`session_expired`) → re-add the server. Check the
  persisted connection got the rotated refresh token.
- **403 `profile_verification_required`:** PIN profile without a valid `X-Profile-Token`.
- **422 `header.x-profile-id`:** a call made with `profile: false` that needs the profile.
- **Playback refused:** read the `Silo playback plan: delivery=… reason=…` log line; a
  `terminal.message` from `outcome: adaptation_unavailable` is shown to the user verbatim.
- **Download "needs a newer server":** the server lacks `/direct-download/links`.
