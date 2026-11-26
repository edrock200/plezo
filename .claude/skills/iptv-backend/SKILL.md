---
name: iptv-backend
description: How Plezilo's IPTV sources work (MediaBackend.iptv, the sixth backend) — M3U/M3U8 playlists, Xtream Codes logins and XMLTV guides read and stored on the device, Live TV with groups, catch-up, reminders, the IPTV player OSD, Xtream movies and series, local recording — and how to change, test and debug them. Use whenever you touch lib/services/iptv/, IptvConnection, IptvMediaItem, the add-source or source-settings screens, the Live TV Channels tab or group bar, the IPTV live OSD, or when a user reports an IPTV playlist, guide, catch-up, playback or recording problem.
---

# IPTV sources (`MediaBackend.iptv`)

An IPTV source is something the user brings: an M3U playlist (address or file) or an Xtream Codes login,
plus XMLTV guides. There is no media server: Plezilo reads the playlist and guide itself, stores them in its
own database and plays the provider's stream addresses directly. Follow `media-backend-integration` for the
app wiring; this skill holds the formats, the architecture and the pitfalls.

## Rules (non-negotiable)

- **No sources ship with the app.** No sample playlists, no provider names, no links to IPTV services, no
  wording that suggests where to get streams. Test data lives in `test/` and names `*.example` / `iptv.test`
  hosts only.
- **Credentials:** the playlist address, the Xtream server, username and password and the guide addresses are
  encrypted at rest (`CredentialVault._tokenKeysForKind('iptv')`: `m3uUrl`, `xtreamServer`, `xtreamUsername`,
  `xtreamPassword`, `epgUrls` — the guide list is stored as one newline-joined string for that reason).
- **Never log a stream or API address.** Xtream URLs carry the login in the path (`/live/u/p/1.ts`) or the
  query (`player_api.php?username=&password=`). `IptvClient._registerSecrets` registers the password,
  username, server and playlist addresses with `LogRedactionManager`; every log line still names only
  decisions (`[iptv] …`), counts and status codes. The database stores no Xtream stream URL: channels keep
  their `xtream_id`, the address is built when played or recorded.
- Decisions are logged with the `[iptv]` prefix.

## Architecture

| Piece | File |
|---|---|
| Connection (settings, secrets) | `IptvConnection` in `lib/connection/connection.dart` (id `iptv-<time><random>`, no `:`; also the server id) |
| Item variant | `MediaItem.iptv` / `IptvMediaItem` (`lib/media/media_item.dart`); ids in `iptv_ids.dart` (`m`, `s`, `s<id>.<n>`, `e<series>.<ep>`, `c<channel>`, `r<recording>`) |
| Capabilities | `ServerCapabilities.iptv`: liveTv, liveTvDvr (local recording), richHubs, continueWatchingRemoval, no transcoding |
| M3U parser | `m3u_parser.dart` (line-based, constant memory) |
| XMLTV parser | `xmltv_parser.dart` (XML events via `package:xml` `XmlEventDecoder`, gzip sniffed by magic bytes) |
| Xtream API | `xtream_api.dart` (`player_api.php` actions, `xmltv.php`, stream and timeshift URLs) |
| Catch-up URLs | `iptv_catchup.dart` (`default`/`append`/`shift`/`flussonic`/`xc`, placeholders) |
| Guide matching | `iptv_epg_matching.dart` (manual → `tvg-id` exact/case-insensitive → normalised name) |
| Database | `iptv_store.dart`: `IptvDatabase` is its **own** drift database (`iptv.sqlite`, plain SQL, no codegen), `IptvStore` the queries |
| Refresh | `iptv_sync_worker.dart` (the import), `iptv_sync_service.dart` (scheduling, background isolate, status) |
| Client | `iptv_client.dart` (+ parts `iptv_client_live.dart`, `iptv_client_dvr.dart`) |
| Cache | `IptvApiCache` (detail items only), registered in `main.dart` |
| Recording, reminders, parental gate | `iptv_recorder.dart`, `iptv_reminders.dart`, `iptv_parental.dart` |
| Removal | `iptv_source_cleanup.dart` (called by `ProfileConnectionCleanup`) |
| Screens | `lib/screens/settings/add_iptv_screen.dart`, `iptv_source_settings_screen.dart`, `iptv_group_editor_screen.dart`, `iptv_channel_editor_screen.dart`; Live TV: `tabs/channels_tab.dart`, `live_tv_group_bar.dart`, `iptv_live_actions.dart`; player: `video_player/live_channel_zapper.dart`, `video_player/parts/live_osd.dart`, `widgets/video_controls/iptv/live_channel_osd.dart` |

Why a separate database: guides of hundreds of thousands of rows must not weigh on the app database's
migrations, backups or tvOS recovery store, and a source's data must be droppable at once. The main isolate
opens it with `NativeDatabase.createInBackground` (queries never run on the UI isolate); the refresh worker
opens the same file in its own isolate (`IptvDatabase.openSync`); WAL mode lets both work.

### Refresh

- `IptvSyncService.watch` is called by `MultiServerManager.addIptvConnection` (every bind). It checks every
  15 min; a source is refreshed when its playlist or guide is older than its interval (or never read; a
  failure is retried after 30 min). `refresh()` shares a running refresh of the same source and runs sources
  one at a time.
- The work runs in `Isolate.run` (`_spawn(job)`: the closure holds only the job; `IptvConnection` is plain
  data). Progress comes back over a `SendPort` into `statusOf(id)` (the settings page shows it).
- Playlist: channels are replaced in one transaction. Ids are stable across refreshes — Xtream `x<stream_id>`,
  M3U `sha1(group, name, tvg-id)[:16]` (`~2` for duplicates) — because favourites, recents and the user's
  channel changes are keyed by them. Stream addresses often carry rotating tokens, so they are not part of
  the id.
- Guide: every guide address (the user's, then the source's own: header `url-tvg`/`x-tvg-url`, or Xtream
  `xmltv.php`) is streamed into `programmes_staging`, then swapped in with one transaction
  (`commitProgrammeImport`), so the guide is never seen half imported. Only guide channels some playlist
  channel can use are kept (wanted ids and normalised names), only inside the window (past N days for
  catch-up, future M days), and a guide channel already covered by an earlier guide is skipped. If every
  guide fails the previous guide stays.
- After either import `rematch` stores each channel's guide id. Time shift is applied when read
  (`source epgShiftMinutes + channel shiftMinutes + tvg-shift hours`), never stored.
- `IptvDataRevision.bump(id)` after a refresh or a user change; `onSourceUpdated` (wired in `MainScreen`)
  re-checks Live TV availability and libraries; the Live TV screen reloads on `IptvDataRevision.changes` and
  `IptvParentalGate.revision`.

### Live TV

- `IptvClient.shownChannels()` is the one channel list: hidden channels, hidden groups and (while locked) the
  parental groups left out, group order (user's, then source's), playlist order inside, numbered by
  `numberChannels` (user's number, then `tvg-chno`/Xtream `num` in playlist mode, the rest after the highest
  number; duplicates renumbered). Cached per parental/data revision.
- `_IptvLiveTvSupport` implements `LiveTvSupport`, `LiveTvChannelGroups` (groups, recents) and
  `LiveTvRecordedItems`. Favourites are local (`favorites` table), `serverSlice` mode, store key
  `iptv:<id>`.
- `LiveTvChannel` gained `group`, `catchupDays`, `radio` (not in JSON). The group bar and Channels tab appear
  only when a Live TV source implements `LiveTvChannelGroups`, so Plex/Jellyfin/Tofa are unchanged.
- `IptvLiveSession`: `streamUrlAt()` is the live address; for a catch-up channel `captureBuffer` spans the
  archive (`catchup-days` back to now) and `streamUrlAt(offset)` builds the archive address for that point
  (the live edge, within 45 s, plays live again). The player's existing time-shift machinery does the rest
  (seek bar, skip, "watch from start", `startLivePlaylistFromBeginning` = mpv `live_start_index=0` only on
  time-shifted opens; plain live opens never get it). `reportTimeline` returns a fresh window. `recover()`
  waits with back-off (1, 2, 4, 8, 15 s), probing the address, then hands itself back.
  `LiveTvStreamHeaders` carries the source's and the channel's user-agent/referrer to every open
  (`_openLiveStream` reads it from the session).
- `LiveTvSessionArgs.startAtEpoch` starts a tune at a chosen point of the window (catch-up of a past
  programme); IPTV launches default to joining live (`navigateToLiveTv` maps `ask` to `live` for IPTV).

### Player OSD (IPTV only)

`_initLiveOsd` builds a `LiveChannelZapper` (pure, tested) and a `LiveChannelOsdController` when the session
is IPTV. `PlexVideoControls.liveKeyHandler` offers keys to it first. With the controls down: Up/Down,
Channel±, Page Up/Down zap (queued); digits type a number (1.8 s timeout, OK commits; exact number, else
prefix); Last/`L` or a lone `0` recalls; Info/`I` banner; Menu/`M` raises the controls; OK opens the mini
guide; Left opens it on a channel without an archive (with one, Left/Right seek). With the controls up only
digits and Channel± keys are taken. Back is untouched. The mini guide offers Watch from start, Record and
Player controls above the channel list.

### Xtream movies and series

Libraries `movies` / `series` (only with `includeVod` and rows present). Categories are the genre filter
(`MediaFilterField.genre` → category ids) and the Genres tab. Details come from `get_vod_info` /
`get_series_info` (cached 30 min in memory, shared in-flight, mapped items also in `IptvApiCache` for a slow
or offline provider). Progress and watched state are local (`progress` table); past 90 % counts as watched;
Continue Watching rows are built from the stored `meta`. `marksWatchedOnPlaybackStopped` is false, so the
player's explicit mark is what stores "watched". Downloads are off (`MediaBackend.supportsDownloads`).

### Recording

`IptvRecorder` (foreground only): TS copied byte for byte with reconnects; HLS by polling the best variant and
appending segments. Files in `<app support>/iptv_recordings/<id>.ts`. `restore()` at start-up marks cut-off
recordings `failed/interrupted`, missed ones `failed/missed`, re-arms scheduled ones. The DVR adapter offers
single airings only (template "Record episode"); `cancelGrab` cancels; finished recordings list through
`LiveTvRecordedItems` and play from `file://`.

## Formats and quirks the parsers accept

- M3U: BOM, CRLF, no `#EXTM3U`, blank lines, attributes glued to the duration (`-1tvg-id=`), unquoted or
  single-quoted values, commas inside quotes, commas in the title, `#EXTGRP`, `#EXTVLCOPT:http-user-agent /
  http-referrer / http-origin`, `#KODIPROP:inputstream.adaptive.stream_headers|manifest_headers`, and
  `url|User-Agent=…&Referer=…` (URL-encoded values; the suffix wins). Header `url-tvg`/`x-tvg-url`/`tvg-url`
  (comma-separated), `catchup`, `catchup-source`, `catchup-days`, `tvg-shift` (playlist-wide defaults).
- XMLTV: `YYYYMMDDhhmmss ±hhmm` (seconds/zone optional; no zone = UTC; `+02:00` accepted), CDATA, entities,
  `episode-num` `xmltv_ns` (zero-based) and `onscreen`, a programme without `stop` lasts an hour, gzip
  whatever the URL says, UTF-8 with malformed bytes replaced.
- Xtream: numbers as strings, `tv_archive` as `1`/`"1"`, rows as a list or an object keyed by index,
  `epg_listings` titles/descriptions in base64, series `episodes` as an object keyed by season or a list of
  lists, `backdrop_path` as list or string. `auth: 0` or HTTP 401/403 = refused login (`HealthStatus.authError`).
  An unreachable provider still reads as online when the device has data (channels and guide are local).
- Archive time in Xtream timeshift URLs is the server's local time: the offset is derived from
  `server_info.time_now` vs `timestamp_now` (rounded to 15 min).

## Unverified (needs a real provider or device)

- Catch-up URL shapes per provider (`flussonic` variants, `default` templates with unusual placeholders,
  whether a given Xtream server wants the path or `timeshift.php` route — the latter is a source setting).
- Xtream servers whose `xmltv.php` is huge or broken: the short guide (`get_short_epg`) only backs the
  banner and mini guide, not the grid.
- mpv/ExoPlayer honouring `User-Agent`/`Referer` sent as stream headers on every provider.
- HLS recording of providers with encrypted segments (not supported: segments are copied as fetched) and
  recordings while the app is in the background on Android/iOS (the OS may suspend it).
- 100–300 MB guides on low-RAM TV boxes: designed for it (streaming, batches of 2000/5000 rows, a staging
  swap) but only tested with ~20 MB synthetic guides.

## Declined, and why

- **System notifications for reminders**: needs a notification plugin with per-platform setup (Android
  receivers and exact-alarm permission, iOS/macOS authorisation, Windows/Linux toasts) and a scheduler that
  survives the app being closed; Plezilo has none. Reminders fire inside the app while it is open.
- **Background/server-side recording**: Plezilo has no service that runs while closed; recordings run while
  the app runs and are marked failed when cut off.
- **Series recording rules**: would need a guide match by title on every refresh; single airings only.
- **M3U VOD entries as libraries**: M3U has no reliable movie/series typing; every M3U entry is a channel.
- **Encrypted streams / DRM (`#KODIPROP` licence keys)**: recorded for diagnostics only, not used.
- **Server-side favourites or progress**: Xtream has none; both are per device.

## Testing

- Unit tests: `test/services/iptv/` (parsers with 60k-entry and 200k-programme synthetic inputs, catch-up
  templates, sync and client against the fake provider, connection/vault/removal, reminders, recording);
  `test/screens/video_player/live_channel_zapper_test.dart`; widgets: `test/screens/settings/add_iptv_screen_test.dart`,
  `iptv_source_settings_screen_test.dart`, `test/screens/livetv/live_tv_iptv_test.dart`,
  `test/widgets/video_controls/live_channel_osd_test.dart`.
- `test/services/iptv/fake_iptv_server.dart` is a fake provider: `player_api.php` (every action used),
  `xmltv.php`, `/playlist.m3u`, `/epg.xml(.gz)` and dummy TS streams. `start()` binds a real socket;
  `respond(uri)` answers in process (`fakeIptvHttpClient` in `iptv_test_helpers.dart`) for widget tests,
  where sockets are blocked. Widget tests turn `logos` off (image loading needs platform plugins there).
- By hand: `dart run scripts/iptv_fake_server.dart --port 8899 --channels 50`, then add
  `http://127.0.0.1:8899/playlist.m3u` (M3U) or server `http://127.0.0.1:8899`, user `demo`, password
  `secret` (Xtream). From an Android emulator the host is `10.0.2.2`. The dummy streams are not decodable
  video; they exercise the plumbing (recording, reconnects), not the picture.
- Widget-test pitfall: futures created outside the test's fake-async zone (in `setUp`) never complete inside
  `testWidgets`; `LiveChannelZapper` therefore creates its queue lazily. DB work in widget tests needs
  `tester.runAsync`.
