---
name: tofa-backend
description: Tofa media-server API facts for Plezilo's fifth backend (sign-in with the device flow, browsing, playback negotiation, progress, watched state, profiles). Use whenever you touch lib/services/tofa/, TofaConnection, TofaMediaItem, the Tofa sign-in screen, or when a Tofa user reports a sign-in, browsing, playback or progress problem; and before writing code against any Tofa endpoint.
---

# Tofa backend

Tofa (tofa.tv) is a self-hosted media server (beta) with a cloud service at `https://api.tofa.tv` that handles
sign-in and remote access. Plezilo talks to it as `MediaBackend.tofa`, its fifth server type. Follow the
`media-backend-integration` skill for the app wiring. This skill holds the Tofa contract.

## Sources (read the spec, don't remember it)

- Media-server OpenAPI 3.1: `https://docs.tofa.tv/api-spec.json` (about 1.6 MB, "tofa Media Server API (public)").
  Read v0.14.0 on 2026-11-25: 277 paths, 854 schemas.
- Cloud sign-in OpenAPI: `https://docs.tofa.tv/cloud-api-spec.json` (`api.tofa.tv`, no `/api/v1` prefix).
- Guides: `https://docs.tofa.tv/use-the-api.html` (auth), `live-events-api.html` (WebSocket),
  `how-playback-works.html`, `how-your-devices-connect.html`, `subtitles.html`. `https://docs.tofa.tv/api.md` is a
  text version of both specs' index plus the guides.
- The specs are licensed **Proprietary**: never commit them to this repo. Download them to the scratchpad and query
  them with `scripts/tofa_spec.py SPEC paths|op <path>…|schema <Name>…`.
- The pages at `docs.tofa.tv/api.html` are rendered by Scalar from the JSON. A web fetch of the page shows only
  the index. Use the JSON.
- Tofa is in beta and "additive changes can land in any release". Feature-detect with `GET /api/v1/system/info`
  (`api_version` integer, `capabilities` list of strings); never version-match.

## Auth

### Device flow (the only sign-in Plezilo implements; it works on TV)

1. `GET {server}/api/v1/auth/status` (no auth) returns `AuthStatusResponse`: `claimed`, `claim_pending`,
   `server_id` (nullable), `connect_url` (e.g. `https://api.tofa.tv`). An unclaimed server or one with no `server_id`
   cannot sign in. Say so, and never guess.
2. `POST {connect_url}/device/code` with JSON `{server_id, client_name: "Plezilo", client_type}`. The response holds
   `device_code`, `user_code`, `verification_uri`, `verification_uri_complete`, `expires_in` (600), `interval` (5)
   and an optional `qr_code_svg`. Show the code and a QR code of `verification_uri_complete`.
3. Poll `POST {connect_url}/device/token`, **form-encoded** (`application/x-www-form-urlencoded`; JSON gets a 415):
   `grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=…`. Every `interval` seconds the answer is 400
   `{"error":"authorization_pending"}`; polling too fast gets 400 `slow_down`, so add 5 s and continue; any other
   error ends the flow. Success returns `TokenResponse`: `access_token` (a 30-day JWT scoped to that server),
   `refresh_token` (90-day), `token_type` "Bearer", `expires_in`.
4. Call the server with `Authorization: Bearer <access_token>`.

### Refresh

- `POST {connect_url}/servers/{server_id}/device-token/refresh` with JSON `{refresh_token}`. No bearer is needed.
- The refresh token rotates once it is 24 hours old. **Persist the returned pair before discarding the old one**:
  reusing a retired refresh token revokes the whole session family.
- Share one in-flight refresh future, as Silo does. 401 means the sign-in is gone: ask the user to sign in again.

### Other ways in (not implemented)

- Account-first flow: the device flow without `server_id` gives a 15-minute cloud token. Then `GET /servers` returns
  `ServerListResponse.items[]`: `id`, `name`, `role`, `online`, `connect_url`, `connection`. Then
  `POST /servers/{id}/server-session` returns the 30-day pair. This lists every server the account can use; a
  candidate for "find my servers".
- API keys (`tofa_…`) are admin-made and work only on direct connections. Don't offer them as sign-in.
- Sign-out: there is no device-token revoke in the public spec. Forget the tokens locally.

### Profiles

- `GET /api/v1/profiles` returns `[ProfileResponse]`: `id`, `name`, `is_kids`, `is_locked`, `is_primary`,
  `avatar_color`, `avatar_image_url`, `library_ids`, `max_content_rating`.
- Every watch-state call acts on the active profile. Send `X-Profile-Id: <id>`.
- A locked profile needs `POST /api/v1/profiles/{id}/verify-pin` with `{pin, remember_device}`. It returns
  `{profile_token, expires_at}`; send that as `X-Profile-Token`. It returns 429 after too many tries.
- One Plezilo connection is one Tofa account acting as one Tofa profile, like Silo.

### Scoped `st` tokens for URLs a player fetches

- Players can't send headers, so URLs they fetch carry `?st=…`.
- `GET /api/v1/auth/image-token` returns `{token, expires_in}` for artwork. Cache it and renew it before
  `expires_in`.
- Artwork URLs are `GET /api/v1/artwork/{media_id}/{kind}?st=…&w=&h=`, where `kind` is `poster`, `backdrop`,
  `backdrop_thumb` or `logo`. The server answers 302 to the image.
- Playback URLs come ready from `/stream/{id}/info` (`stream_url`, plus `session_token` for the session routes).
- Never send the bearer to an artwork URL. Use the `st` token only.

## Browsing

- `GET /api/v1/libraries` returns `[LibraryResponse]`: `id`, `name`, `media_type` (`movie`|`tv`|`other`),
  `library_kind` (`movie`|`tv`|`other`|`mixed`) and `sort_order`. The list is already narrowed to the profile.
- `GET /api/v1/browse/sections` returns `{sections:[BrowseSection]}`: `key`, `kind`, `name`, `media_type`,
  `library_id`, `total`.
- `GET /api/v1/media` returns `PaginatedResponse_MediaSummary` with `items`, `page`, `per_page`, `total` and
  `total_pages`.
  - Paging: `page`, `per_page`.
  - Filters: `library_id`, `media_type`, `genre`/`genres`, `year`, `year_from`/`year_to`, `watched`, `q`, `letter`,
    `available_only`, `fold_sets`.
  - Sorting: `sort` + `order`. **The sort values are free strings the spec does not enumerate.** Check them on a
    server, and fall back to the server default.
- `MediaSummary` fields:
  - `id`, `media_type`, `title`, `overview`, `release_date`, `runtime_minutes`, `genres`, `rating`, `library_id`.
  - Artwork paths: `poster_path`, `backdrop_path`, `backdrop_thumb`, `logo_path`. Their format is unverified (a path
    or a URL); for images prefer the `/artwork/{id}/{kind}` route.
  - Watch state: `watched`, `watch_mark` (`state`: `none`|`watched`|`episodes_left`, `progress_percent`,
    `episodes_left`), `unwatched_episode_count`.
  - `tmdb_id`.
- `GET /api/v1/media/{id}` returns `MediaDetail`, which is `Media` plus:
  - `files: [MediaFile]` (movies);
  - `seasons: [SeasonWithEpisodes]` (series), each `Season` (`id`, `season_number`, `title`, `poster_path`) plus
    `episodes: [EpisodeWithFiles]`. An episode has `id`, `season_id`, `episode_number`, `episode_number_end`,
    `title`, `overview`, `air_date`, `still_path`, `runtime_minutes`, `files: [MediaFile]`;
  - `next_up` (`episode_id`, `season_id`, `media_file_id`, `position_ms`, `kind`: `resume`|`next_up`|`rewatch`);
  - `provider_ids` (match by `provider`, never by index);
  - `cast` / `crew`, `youtube_trailer_id`.
  A series detail therefore carries its whole tree. There is no separate seasons or episodes list endpoint.
- **Ids.** Titles (movie or series) are `media_id`. Seasons and episodes have their own ids. **Playback, progress
  and watched state are per file**: `media_file_id` = `MediaFile.id`.
  - `PUT /media/{id}/watched` and `/media/{id}/progress` take a **file** id.
  - Seasons: `PUT /seasons/{season_id}/watched`. Shows: `PUT /shows/{id}/watched`.
  - Pick a file explicitly. Use `GET /media/{id}/versions` (returns `VersionSelection` with a recommended file
    id), never `files[0]`.
- `MediaFile` fields: `id`, `media_id`, `episode_id`, `duration_ms`, `container`, `video_codec`, `audio_codec`,
  `height`, `hdr`, `dolby_vision_profile`, `audio_tracks`, `subtitle_tracks`, `edition`, `part_number`/`part_count`.
- Home:
  - `GET /api/v1/users/me/continue` returns `[ContinueWatchingItem]`: `kind` (`resume`|`next_up`), `media_id`,
    `media_file_id`, `episode_id`, `season_number`, `episode_number`, `title`, `episode_title`, `position_ms`,
    `duration_ms`, `progress_percent`, artwork paths.
  - `GET /api/v1/users/me/suggested`, `GET /api/v1/collections/home-rows`, `POST /api/v1/media/latest-episodes`.
    Read their schemas before use.
- Search: `GET /api/v1/search?q=&limit=&movie_limit=` returns `SearchResponse` with `movies: [MediaSummary]` (movies
  and shows), `actors`, `collections` and `discover` (titles not in the library; leave them out).
- Similar: `GET /api/v1/media/{id}/similar`. Collections: `GET /api/v1/collections`, `/collections/{id}`.
- Watchlist:
  - `GET /api/v1/users/me/watchlist`;
  - `POST` / `DELETE /api/v1/users/me/watchlist/{media_id}`.
  There are no favorites.
- Dismiss from Continue Watching: `POST /api/v1/users/me/dismiss/{media_id}`.

## Playback

`GET /api/v1/stream/{media_file_id}/info` negotiates playback and creates a stream session.

**Query parameters**
- Codec lists (comma-separated; **unverified**, so check on a server):
  - `direct_play_video_codecs`, `direct_play_audio_codecs`, `direct_play_containers`;
  - `hls_video_codecs`, `hls_audio_codecs`, `transcode_video_codecs`, `stereo_only_audio_codecs`.
- Display: `hdr_supported`, `hevc_10bit_supported`, `h264_10bit_supported`, `dolby_vision_supported`,
  `dolby_vision_profile_5_supported`, `prefer_hdr10`.
- Bandwidth: `max_bitrate`, `measured_throughput_kbps`, `quality_mode`.
- Tracks: `audio_stream_index`, `audio_sink_channels`, `subtitle_track_id`, `include_text_subtitles`,
  `client_render_bitmap_subtitles`, `burn_subtitle_index`.
- Other: `resume_ticks`, `force_method`, `dry_run`.

**Headers**
- `X-Tofa-Client: Plezilo`, `X-Tofa-Client-Version`, `X-Tofa-Platform` (`android`, `ios`, `tvos`, `web` seen),
  `X-Tofa-Device-Name`, `X-Tofa-Device-Model`, `X-Tofa-OS-Version`.
- `X-Profile-Id` (and `X-Profile-Token` for a locked profile).

**Ticks.** Tofa ticks are 100 ns: 10,000 per ms, 10,000,000 per second. `resume_ticks` and `position_ticks` use them.
Omitting `resume_ticks` lets the server resolve the resume point and return it.

**Response: `PlaybackInfoResponse`**
- `play_method`: `DirectPlay`|`DirectStream`|`Transcode`. `decision_mode`: `DirectFile`|`HlsRemux`|
  `HlsCopyVideoTranscodeAudio`|`HlsFullTranscode`.
- `stream_url`: the file URL or the HLS master playlist, with `st` included. If it is relative, resolve it against
  the server base.
- `session_id`, `session_token`.
- `start_position_ticks`: the resolved resume point. Open there.
- `duration_ms`.
- Tracks: `audio_tracks` (`index`, `codec`, `language`, `title`, `channels`), `selected_audio_stream_index`,
  `subtitle_tracks` (`index`, `track_id`, `codec`, `language`, `forced`, `sdh`, `external`, `render`: `text`|`bitmap`),
  `burn_in_subtitle_tracks`, `font_attachments`.
- Diagnostics: `quality_tiers`, `transcode_reasons`, `transcode_reason_codes`, `decision_trace_id` (log it).
- A 503 means the remote stream cap or relay is not reachable. Show its `message`.

**Session routes** (`st` = `session_token`):
- Progress: `POST /stream/s/{session_id}/progress?st=` with `ProgressReport {position_ticks, is_paused, ended}`,
  answered 204. **410 means the session is gone**: stop reporting. Don't restart it silently.
- Stopped: `POST /stream/s/{session_id}/stopped?st=`. It is idempotent; send it on every close.
- End: `DELETE /stream/s/{session_id}`.
- Switch tracks: `POST …/audio`, `POST …/subtitle-selection`, `POST …/quality`, `POST …/seek`. Read each body
  in the spec before use.

**Subtitles**
- Text tracks come out as session files: `…/subtitles/{index}/full.vtt` (also `full.ass`, `playlist.m3u8`). Add
  `?st=`.
- Bitmap tracks (PGS `full.sup`, VobSub `full.idx` / `full.sub`) are drawn by the client.
- Per-file list: `GET /api/v1/stream/{id}/subtitles`.

**Progress outside playback**: `PUT /api/v1/media/{file_id}/progress` with `{position_ms, ended}`.

**Watched**
- `PUT /api/v1/media/{file_id}/watched` with `{watched, watched_at?}` returns `WatchProgressResponse`
  (`position_ms`, `completed`, `completed_at`, `last_watched_at`).
- Batch: `POST /media/watched/batch`, at most 500 items; one bad id fails the batch.
- The server marks a file watched at the end credits or past 90% (an admin can set 70-95%), and also marks earlier
  episodes watched by default.

## Errors

- `ErrorResponse`: `error` (a code string), `message` (text people can read), optional `code`, `limit`,
  `active_streams`, `stop_message`.
- Show `message` and log `error`.
- `admin_stopped` refusals may carry `stop_message`.
- 403 is access or profile, 404 is an unknown id, 503 is relay or server busy. Retry 503 once with back-off.

## Live events (not used yet)

- `ws(s)://{server}/api/v1/ws`. Authenticate with the first frame `{"type":"auth","token":…}`; the server answers
  `{"type":"auth_ok"}`.
- Events are `WsEvent` frames: `StreamStarted`/`Progress`/`Stopped`, `MediaAdded`/`Updated`/`Deleted`,
  `WatchStateChanged` (capability `ws.watch_state_changed`) and `EventsMissed` (refetch).
- Keepalive: the server pings every 30 s. Events are never replayed.

## Connecting from away

`how-your-devices-connect.html` describes three paths, local, direct and relay, raced in that order. The relay base
is `https://api.tofa.tv/servers/{id}/relay` with the API path appended. It answers 503 `server_relay_not_connected`
when the server's channel is down. The free tier allows one 2 Mbps relayed stream. Plezilo's first version connects
to the address the user typed (LAN or custom URL); relay support is a follow-up.

## Testing

- No public Tofa server is available. Unit-test the client against a fake HTTP layer whose recorded answers follow
  the spec's schemas (ids made up, no tokens).
- For anything the spec leaves open (sort values, codec list format, artwork path format), say in code that it is
  unverified and fail closed.
- Never let tests write progress or watched state to a real server.

## In Plezilo

- Code: `lib/services/tofa/`:
  - `tofa_api.dart`: HTTP, `X-Tofa-*` headers (with `X-Tofa-Device-Id`, the app's per-install client id), token
    refresh, connection-failure counting, 503 `server_relay_not_connected` retries.
  - `tofa_auth_service.dart`: server probe, device flow (`TofaDeviceSignIn`, also `.account` for account-first
    sign-in), `GET /servers`, `server-session`, profiles, verify-pin.
  - `tofa_client.dart` plus its parts: `_home` (Home rows), `_quickview` (chapters, markers, previews), `_downloads`,
    `_connect` (address race).
  - `tofa_mappers.dart`, `tofa_library_options.dart` (facets → sorts/filters), `tofa_downloads.dart` (download record,
    qualities, offline extras), `tofa_endpoints.dart` (connection-info, race), `tofa_playback_caps.dart`,
    `tofa_api_cache.dart`.
  - Sign-in screen: `lib/screens/settings/add_tofa_screen.dart`. Tests: `test/services/tofa/` (fake server in
    `tofa_fixtures.dart`, routes by path, host or prefix) and `test/screens/settings/add_tofa_screen_test.dart`.
- Item ids: titles keep the media id; seasons are `tofa-season:{mediaId}/{seasonId}`, episodes
  `tofa-episode:{mediaId}/{episodeId}` (one `/media/{id}` read serves the whole series tree). File ids live in
  `raw['tofa_file_ids']`; a detail's watch state comes from `POST /media/progress/batch`; watched writes for files use
  `POST /media/watched/batch`.
- Artwork is `tofa-artwork:{mediaId}/{kind}` in the item and becomes `/api/v1/artwork/...?st=` in
  `TofaClient.thumbnailUrl` (image token renewed at 80% of `expires_in`). Raw `*_path` values are never used.
- A refreshed pair is persisted (`ConnectionRegistry.updateTofaSession`, awaited) **before** the client uses it.
- Playback picks the requested file, else `/versions`' recommended file, else the only file; with several files and
  no recommendation it refuses to play. `resume_ticks` is always sent. Text subtitles: external ones on a direct play,
  all of them on a remux/transcode, as `full.vtt?st=` sidecars.
- **Sorts and filters** come only from `GET /media/facets` (`sorts`, `default_sort`, `default_order`, `genres`,
  `quality`, `letters`, `watched` counts, `years`); `/media`'s own `sort`/`order`/`watched`/`quality`/`letter` are
  plain strings in the spec. `order` is sent only when `default_order` is `asc`/`desc`. Genres tab:
  `GET /media/genres`.
- **Home**: Recently Added (only when the facets list a date-added sort: `added_at`, `created_at` or `date_added`,
  sent with `order=desc`), `/users/me/suggested` (`items`), `/media/binge-ready` (seasons), `/users/me/watchlist`
  (owned titles), `/collections/home-rows` (`pinned_collection` rows), all with `Future.wait`.
  `latest-episodes` and `browse/sections` make no row.
- **Watchlist**: `MembershipListsClient` (in `silo_memberships.dart`) is the neutral interface the detail page and card
  menu use; Silo has Watchlist + Favorites, Tofa Watchlist only. Tofa titles carry no watchlist flag: the client reads
  the list (2-minute freshness) and answers through `SiloMembershipStore`'s `known` hook.
- **QuickView** (`/media/{file}/quickview`): chapters (`start_ticks`, chapter images with the image token), segments
  → markers by `segment_type` (intro/opening, recap, credit/outro/ending, preview; others left out), tiles → the
  Jellyfin trickplay reader (`JellyfinTrickplayService.forSheets`), sheets `/quickview/tiles/{w}/{i}?st=`.
- **Downloads**: `POST /download/register` (`device_id`, `media_file_id`, `quality_key` = a `download_options` tag,
  `client_request_id`); bytes `GET /stream/{file}/download?quality=&st=<auth.token>`; text subtitles from
  `subtitle_manifest` with the `X-Tofa-Device-Id` header; 409/503 → `GET /download/prepare/{client_request_id}` →
  `DownloadNotReadyException`. The record (no tokens) is pinned in `TofaApiCache`; offline playback reads its tracks
  and skip segments (`CachedPlaybackMetadataService`), offline progress goes up as `POST /playback/offlineProgress`
  with a rising `monotonic_seq`; deleting the copy sends `DELETE /download/{id}` (`TofaDownloadTracker`).
- **Connecting**: on the first health check and after the server stopped answering, the client races the entered
  address and `GET {cloud}/servers/{id}/connection-info`'s candidates (documented in the API guide, "Reach the server
  from anywhere"; not in the cloud OpenAPI) in order with `stagger_ms`; the relay base
  `{cloud}/servers/{id}/relay` is added when not listed. Two connection failures in a row rerun it (at most every
  15 s). On the relay, playback shows a bandwidth notice (`PlaybackInitializationResult.playbackNotice`).
- **Account-first sign-in**: device flow without `server_id` (cloud token) → `GET /servers` → pick → `POST
  /servers/{id}/server-session`; the connection's address is the server's `connect_url`, else its relay.
- Not in this version: external players, playlists, collections pages, people, live TV, sign-out revoke (none in the
  public spec), multi-part files beyond part 1, live events.
- Unverified on a real server (all fail closed and are marked in code): codec-list format; `max_bitrate` unit;
  `force_method` values; that the facets' `watched` field names are `/media?watched=` values; `segment_type` names;
  that `auth.token` is the download route's `st` and `quality` takes the option's tag; that `request_id` of the
  preparation route is the `client_request_id`; `bandwidth_limit`'s unit (not turned into a cap); whether
  `stream_url`/HLS variants keep `st`, also through the relay; relative URL base; wrong-PIN status;
  `X-Tofa-Platform` values for desktops; avatar URLs needing a bearer.
