---
name: tofa-backend
description: How Plezilo talks to a tofa media server (tofa.tv): the public HTTP API at /api/v1, the account-first device-flow sign-in through api.tofa.tv, server-scoped tokens and their refresh, API keys, profiles (X-Profile-Id / X-Profile-Token), connection candidates and the cloud relay, the item model (movies and shows, seasons and episodes nested in the show, playback per media file), image URLs, playback negotiation with /stream/{id}/info, progress and watched writes, and the unit traps. Use for any change under lib/services/tofa/ or anything tofa-related, and before reading the 1.6 MB API spec.
---

# tofa backend

tofa is a self-hosted media server (beta, server 0.14.x in Nov 2026). Its public API reference is
`https://docs.tofa.tv/api.html`, generated from `https://docs.tofa.tv/api-spec.json` (OpenAPI 3.1,
277 paths, 854 schemas, ~1.6 MB). Do not commit the spec; fetch it into the scratchpad and query it
with a script. Guides worth reading: `docs.tofa.tv/use-the-api`, `/how-playback-works`,
`/how-your-devices-connect`, `/live-events-api`.

The open-source **tofa for Kodi** add-on (`github.com/tofatv/tofa-for-kodi`, GPL-2.0) is the best
record of behaviour the spec does not state; several facts below were measured by its authors
against live servers. Read it for facts only and write our own code: do not copy its source.

tofa is feature-detected, not version-matched: `GET /api/v1/system/info` returns `version`,
`api_version` and `capabilities` (strings such as `sync.user_state`, `ws.watch_state_changed`,
`auth.api_key_metadata_scope`). Additive changes land in any release.

## Signing in

There is **no username/password endpoint** on the server. Two ways in:

1. **Device flow (normal users).** Account-first, the way tofa's own apps and Kodi do it:
   - `POST https://api.tofa.tv/device/code` with JSON `{"client_name": "...", "client_type": "..."}`
     and **no `server_id`** → `device_code`, `user_code` (e.g. `ABCD-EFGH`), `verification_uri`
     (`https://app.tofa.tv/link`), `verification_uri_complete`, `expires_in` (600), `interval` (5),
     optional `qr_code_svg`. Show the code and link (or a QR of `verification_uri_complete`).
   - Poll `POST https://api.tofa.tv/device/token` as a **form post**
     (`grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=...`) every `interval`
     seconds. Errors `authorization_pending` (keep polling), `slow_down` (add 5 s), `expired_token`
     / `invalid_grant` / `access_denied` (stop). Success gives a **cloud** `access_token` (short,
     ~15 min) and a cloud `refresh_token`.
   - `GET https://api.tofa.tv/servers` with the cloud token → `items[]` of the account's owned and
     shared servers (`id`, `name`, `connect_url`, `connection.local_ip`/`port` for owners). Skip
     items without `connect_url`. Let the user pick when there is more than one.
   - `POST https://api.tofa.tv/servers/{server_id}/server-session` with the cloud token → the
     durable **server-scoped** pair (`access_token` ~30 days, `refresh_token` ~90 days,
     `expires_in`). This is the token for every server call.
   - Refresh the server token with `POST https://api.tofa.tv/servers/{server_id}/device-token/refresh`
     JSON `{"refresh_token": ...}`. Refresh the cloud token (needed only to list servers again) with
     `POST https://api.tofa.tv/auth/token/refresh`. The two families are separate.
   - **Persist every refresh response's `refresh_token` before doing anything else with it.**
     Tokens rotate (server tokens once they are 24 h old); reusing a retired one can revoke the whole
     session family. Pair once per install; never re-run the device flow on start-up.
   - The older per-server flow (call `GET /api/v1/auth/status` on the server for `server_id` and
     `connect_url`, then pass `server_id` to `/device/code`) yields a server-scoped token directly
     and still works; it needs the server address up front.
2. **API key (server admins).** Created in the web app (Admin > Settings > API) or with
   `POST /api/v1/auth/api-keys`. Secret starts `tofa_`, sent as `Authorization: Bearer tofa_...`.
   Works only on direct connections (LAN, own domain/tunnel), **not through the relay**. Scopes:
   full admin, read only (cannot play), read only + stop streams, read only + metadata edits, and
   watch-sync keys (one user; progress/watched/watchlist only). Only a full-admin key can play.

`GET /api/v1/auth/status` is the one unauthenticated call: `claimed`, `server_id`, `connect_url`.
Use it to probe that an address is a tofa server (a 401 from other routes also means "it answered").

## Reaching the server

A server can have several addresses; try them best first and keep the first that answers:
- LAN: `http://<local_ip>:<port>` (default port 33333) or the `lan-direct` candidate
  (`https://192-168-1-50.<id>.lan.tofa.tv:33333`, valid TLS).
- `connect_url` / `wan-direct` (`https://<id>.direct.tofa.tv:33333`), plus custom access URLs.
- The cloud relay: `https://api.tofa.tv/servers/{server_id}/relay` + the normal `/api/v1/...` path.
  It proxies the API only (root answers 404); 503 `server_relay_not_connected` means retry later.
- `GET https://api.tofa.tv/servers/{id}/connection-info` (any account token) returns `candidates`
  with `type` (`lan-direct`, `wan-direct`, `relay`, unknown types may appear: skip them) and
  `stagger_ms` for racing.

**Build URLs by string concatenation, not URI resolution**: a base with a path (the relay) loses it
under RFC 3986 `resolve`, which turned every poster into a 404 in Kodi.

## Request headers

- `Authorization: Bearer <server token or API key>` on every `/api/v1` call.
- Client identity: `X-Tofa-Client` (our app name), `X-Tofa-Client-Version`, `X-Tofa-Platform`,
  `X-Tofa-Device-Name`, `X-Tofa-Device-Model`, `X-Tofa-OS-Version` (ASCII), and a stable
  `X-Tofa-Device-Id` per install. The playback dashboard shows these.
- Profiles: `X-Profile-Id: <uuid>` for an unlocked profile, `X-Profile-Token` for a locked one
  (from `POST /api/v1/profiles/{id}/verify-pin`; ~4 h, slides when a heartbeat returns a new
  `X-Profile-Token` + `X-Profile-Token-Expires-At` response header). Without either, requests act
  as the account's primary profile. `GET /api/v1/profiles` lists them (`is_locked`, `is_kids`,
  `is_primary`, `library_ids`, `avatar_image_url`, `avatar_color`).

## Item model

- Libraries: `GET /api/v1/libraries` → `[LibraryResponse]` (`id`, `name`, `media_type`
  `movie|tv|other`, `library_kind`, `sort_order`), already narrowed to the acting profile.
- Lists: `GET /api/v1/media?library_id=&media_type=&page=&per_page=&sort=&order=&q=&genre=&year=&letter=&watched=`
  → `{items: [MediaSummary], page, per_page, total, total_pages}`. Pages count from 1.
- A **show is one media item**; its seasons and episodes come nested in
  `GET /api/v1/media/{id}` (`MediaDetail.seasons[]` → `SeasonWithEpisodes` with `episodes[]` →
  `EpisodeWithFiles` with `files[]`). Episodes have their own `id` and `season_id`, but there is no
  per-episode detail endpoint: keep the show detail and look episodes up in it. Pass
  `local_images=true` so cast photos come from the server.
- Playable things are **media files** (`MediaFile.id`, `duration_ms`, `audio_tracks`,
  `subtitle_tracks`, codecs, `hdr`, `resolution`, `part_number`/`part_count`, `edition`). A movie
  has `MediaDetail.files[]`; an episode has `files[]`. Several files = versions/editions.
- Watch state is per **file**: `GET/PUT /api/v1/media/{file_id}/progress`,
  `POST /api/v1/media/progress/batch` `{media_file_ids}` → `{items}` (missing ids are simply
  absent). Summaries carry `watched`, `watch_mark {state, progress_percent, episodes_left}` and
  `unwatched_episode_count` for shows. `MediaDetail.next_up` names the episode/file to play next.
- Rows: `GET /api/v1/users/me/continue` (`ContinueWatchingItem`: `media_id`, `media_file_id`,
  `episode_id`, `season_number`, `episode_number`, `position_ms`, `duration_ms`, `progress_percent`,
  `kind`), `GET /api/v1/browse/sections`, `GET /api/v1/media/binge-ready`, `/users/me/suggested`,
  `/users/me/watchlist`, `GET /api/v1/media/{id}/similar` (`owned`, `requestable`).
- Search: `GET /api/v1/search?q=&limit=` → `{movies: [MediaSummary] (movies AND shows), actors,
  collections, discover}`. `discover` entries are not in the library.
- Collections: `GET /api/v1/collections`, `GET /api/v1/collections/{id}`.
- External ids: only `MediaDetail.provider_ids[]` (`provider` = `tmdb|imdb|tvdb`); list views have
  `tmdb_id` only. Look up by provider, never by position.

## Images

`poster_path`, `backdrop_path`, `backdrop_thumb`, `logo_path`, `still_path` are **not**
server-relative URLs. Rules (from the web app's `resolveImageUrl`, recorded by Kodi):
- empty → no image;
- starts with `http` and is on the server's own host → append `?st=<image token>`;
- starts with `http` elsewhere (tofa's public metadata CDN for discover items) → use as is, never
  add our token;
- otherwise → `<base>/cache/<path without leading slash>?st=<image token>` (keep an existing
  `/cache/` prefix). Optional `&w=` for posters. Without `/cache/` the server answers HTTP 200 with
  the web app's HTML, not an image.
- The image token comes from `GET /api/v1/auth/image-token` (`token`, `expires_in` ≈ 1 h; the
  server keeps it stable for the hour). Cache it and refresh a minute early so image URLs (and the
  image cache keys) stay identical; key cached images on the path, never on the tokenised URL.
- `GET /api/v1/artwork/{media_id}/{kind}?st=` (`poster|backdrop|backdrop_thumb|logo`) also serves
  a title's art by id.

## Playback

- `GET /api/v1/stream/{file_id}/info` negotiates and **creates a stream session** (unless
  `dry_run=true`). Declare what the player takes: `direct_play_video_codecs`
  (e.g. `hevc,h264,vp9,av1,mpeg2video,vc1`), `direct_play_audio_codecs`
  (`truehd,dts,dtshd,eac3,ac3,aac,flac,pcm,opus,mp3,mp2`), `direct_play_containers`
  (`mkv,mp4,m2ts,ts,avi,mov,webm`), `transcode_video_codecs` (`hevc,h264`), `hdr_supported`,
  `dolby_vision_supported`, `max_bitrate`, `quality_mode` (`original` when the user chose
  Original), `audio_stream_index`, `subtitle_track_id`, `resume_ticks`.
- Response `PlaybackInfoResponse`: `play_method` (DirectPlay / remux / transcode), `stream_url`,
  `session_id`, `session_token`, `start_position_ticks`, `duration_ms`, `audio_tracks`,
  `subtitle_tracks`, `quality_tiers`, `transcode_reasons`. **`stream_url` is server-relative**
  (`/api/v1/stream/{id}/direct?st=...` or an HLS master playlist) despite the spec calling it
  ready to use: prefix the base URL by concatenation. It already carries its `st`; mpv needs no
  auth headers for it.
- `/api/v1/stream/s/{session_id}/*` (progress, stopped, seek, audio, quality, subtitles, segments)
  is authorised by `?st=<session_token>` **only**; a missing `st` is a 400 even with a valid
  Bearer.
- Heartbeat: `POST /api/v1/stream/s/{session_id}/progress?st=` with
  `{"position_ticks", "is_paused", "ended"}` roughly every 10–15 s. End with
  `POST .../stopped?st=` (idempotent) or `DELETE /api/v1/stream/s/{session_id}?st=` so the server
  frees the transcode slot.
- **Units trap:** `position_ticks`, `resume_ticks` and `start_position_ticks` are **100-ns ticks**
  (ms × 10 000). `PUT /api/v1/media/{file_id}/progress` takes **milliseconds** (`position_ms`).
  Mixing them up silently writes positions 10 000× too small.
- `resume_ticks=0` means "start at the beginning"; omitting it lets the server resume.
- 503 from `/stream/info` can mean the host is at its stream limit; retry once.
- Subtitles: text tracks are separate (`/stream/s/{id}/subtitles/{index}/full.vtt` etc.);
  `subtitle_contract_version=2` adds `track_id` and `representations[].format`.

## Writes

- Progress outside a session (offline sync): `PUT /api/v1/media/{file_id}/progress`
  `{"position_ms", "ended"}`.
- Watched: `PUT /api/v1/media/{file_id}/watched` `{"watched": bool}`; whole season
  `PUT /api/v1/seasons/{season_id}/watched`; whole show `PUT /api/v1/shows/{id}/watched`.
- Hide from Continue Watching without touching progress: `POST/DELETE /api/v1/users/me/dismiss/{media_id}`.
- Watchlist: `POST/DELETE /api/v1/users/me/watchlist/{media_id}`.
- Batches (sync tools): `POST /api/v1/media/watched/batch`, up to 500 items, all-or-nothing.

## Live events

`wss://<base>/api/v1/ws`, first frame `{"type":"auth","token":"<token>"}`, wait for
`{"type":"auth_ok"}`. Pushes playback, library-change and scan events, and `WatchStateChanged`.
Not replayed: refetch state after every connect and after an `EventsMissed` frame.

## In Plezilo

- Backend id `tofa` (`MediaBackend.tofa`). It is **not** a MediaBrowser server
  (`usesMediaBrowserApi` is false) and not Plex; check every `== MediaBackend.plex` and
  `usesMediaBrowserApi` branch when changing shared code (see the `media-backend-integration` skill).
- Code lives in `lib/services/tofa/`: `tofa_api.dart` (HTTP, headers, token refresh),
  `tofa_auth_service.dart` (device flow, server list, server session), `tofa_client.dart`
  (`MediaServerClient`), `tofa_mappers.dart` (JSON → `MediaItem`), `tofa_api_cache.dart`.
- Item ids: a show's id is the media id; seasons and episodes keep their own tofa ids and the
  client remembers which show each belongs to (`parentId`/`grandparentId` on the `MediaItem`).
  A playable `MediaItem` (movie, episode) carries its first available file's id for playback,
  progress and watched calls.
- "tofa" is the product's own lower-case name. Refer to it only as a server Plezilo connects to;
  no tofa logo is bundled (the badge is a neutral letter mark).
