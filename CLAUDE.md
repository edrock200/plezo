# Plezy (with Silo support) — project rules for Claude Code

Plezy is a Flutter client for Plex, Jellyfin, Emby and **Silo** on Android, Android TV, iOS, tvOS,
macOS, Windows and Linux. This fork (`edrock200/plezo`) adds Silo as a fourth backend; upstream is
`edde746/plezy`. Read `CONTRIBUTING.md` for the general workflow; this file adds what an agent needs.

## Skills in this repo
- `.claude/skills/silo-backend/SKILL.md` — how the Silo integration works, the Silo `/api/v2`
  contract rules it relies on, and how to test it against a mock server. Use for any change under
  `lib/services/silo/` or anything Silo-related.
- `.claude/skills/media-backend-integration/SKILL.md` — the checklist for adding or changing a
  server backend (enum, `MediaItem` union, connection persistence, server manager, profile binder,
  caches, UI, tests). Use before touching `MediaBackend`, `Connection` or `MultiServerManager`.
- `.claude/skills/android-preview-release/SKILL.md` — building, publishing and verifying the
  Android preview APKs.

## Commands
- Toolchain: Flutter **3.47.x** (CI pins 3.47.1; Dart 3.13). `flutter pub get --enforce-lockfile`.
- Analyze: `flutter analyze lib test` — must report no issues (infos count too).
- Format: `dart format <changed files>` (page width 120 comes from `analysis_options.yaml`).
  Never run `dart format` over all of `lib/`: it rewrites generated `*.g.dart` / `*.freezed.dart`
  files whose committed formatting came from build_runner. If it happens, `git checkout` them.
- Tests: `scripts/run_tests.sh` (all, ~7 min on 4 cores) or `scripts/run_tests.sh <paths>`.
- Codegen after changing freezed/json models: `dart run build_runner build --delete-conflicting-outputs`
  (or `scripts/codegen.sh`). Only commit generated files whose source you changed; revert any
  unrelated `*.g.dart` the run rewrote.
- Translations: edit `lib/i18n/en.i18n.json` (other locales fall back to English), then `dart run slang`.
- Running `flutter` as root prints a "Woah!" warning; ignore it.

## Architecture in one screen
- `MediaBackend` (`lib/media/media_backend.dart`): `plex`, `jellyfin`, `emby`, `silo`.
  `usesMediaBrowserApi` is true only for Jellyfin/Emby; **"not Plex" does not mean MediaBrowser**.
- `MediaItem` (`lib/media/media_item.dart`) is a sealed freezed union: `PlexMediaItem`,
  `JellyfinMediaItem` (Jellyfin + Emby via `dialect`), `SiloMediaItem`.
- `MediaServerClient` (`lib/media/media_server_client.dart`): the neutral client interface (~90
  members). Implementations: `PlexClient`, `JellyfinClient`, `SiloClient`
  (`lib/services/silo/silo_client.dart` + `silo_client_playback.dart` part).
- `Connection` (`lib/connection/connection.dart`) is sealed: `PlexAccountConnection`,
  `JellyfinConnection`, `SiloConnection`. Persisted by `ConnectionRegistry`; credentials are
  encrypted by `CredentialVault` — every token key of a new kind must be listed in
  `_tokenKeysForKind` or it is stored in plaintext.
- `MultiServerManager` owns live clients. Jellyfin and Silo clients are per-connection, tracked in
  `_jellyfinByCompoundId` (historic name) with one active client per server id.
- `ActiveProfileBinder` binds a Plezy profile's connections to clients (`_bindMediaBrowser`,
  `_bindSilo`). Plezy profiles are local; a Silo connection is one account acting as one Silo profile.
- Offline/download metadata lives in per-backend `ApiCache`s (`PlexApiCache`, `JellyfinApiCache`,
  `SiloApiCache`), registered in `main.dart`. `ApiCache.forBackend` silently falls back to Plex for an
  unregistered backend.

## Rules
- Silo: `/api/v2` only, never v1. Details and pitfalls are in the `silo-backend` skill.
- The app is one build for phone, tablet, desktop and TV. Every new screen must work with touch
  **and** D-pad: use `FocusableButton`, `FocusableTextFormField`, `FocusableWrapper` and give each
  focusable a `FocusNode` with explicit `onNavigateUp/Down` where the default order is wrong. TV
  detection is `PlatformDetector.isTV()`.
- Adding a value to `MediaBackend` or a `Connection` subclass breaks exhaustive switches across
  `lib/` **and** `test/` (`test/test_helpers/media_items.dart`, catalog tests). Run
  `flutter analyze lib test` to find them; follow the `media-backend-integration` skill.
- Product names: "Silo" is Silo Media L.L.C.'s trademark. Refer to it only as the server Plezy
  connects to; the Silo badge (`assets/silo_icon.svg`) is our own generic glyph, not Silo's logo.
- Branches: work on the session's `ccr-*` branch. Do not open a PR or merge into `main` unless the
  user asks (they have declined a PR so far); say plainly that branch-only changes (README too)
  are not visible on `main`.
- Shared code paths: do not use "not Plex" as "MediaBrowser" (`usesMediaBrowserApi`), and do not
  send `client.streamHeaders` to URLs that are not the server's own media (Silo artwork is
  self-authorising and may live on another host). Check every `== MediaBackend.plex` /
  `is! PlexClient` branch when changing backend behaviour.
- Concurrency in clients: share one in-flight future for repeated reads (`_homeSections`,
  token refresh, `addSiloConnection`) and fetch independent rows with `Future.wait`.
- PRs: `CONTRIBUTING.md` requires stating which AI model(s) were used. Commit messages follow
  Conventional Commits (`feat(silo): …`, `fix(home): …`) with a plain-language body.

## Environment notes (cloud sessions)
- The Android SDK is not preinstalled. `dl.google.com` must be allowed in the environment's network
  settings to install it (see the `android-preview-release` skill). There is no `/dev/kvm`, so an
  Android emulator cannot run; verify APKs with `apksigner` / `aapt2` and test on a device.
- `gh` is not available; use the GitHub MCP tools. Releases are created by the preview workflow, not
  from the session.
- Previews are versioned 2.22.N (patch +1 per preview; the workflow picks N). Never hand-pick tags.
- Release pages show the plain-language change log in `docs/silo-preview-changelog.md`; update it
  for every preview (see the `android-preview-release` skill).
- The preview workflow cancels an in-progress build when anything else is pushed to the same
  branch. After a `[release-apk]` push, wait for the release before pushing docs or fixes.
- `dart`/`flutter` live in `/opt/flutter/bin` (add it to `PATH`). Silo's server and Android repos
  can be sparse-cloned into the scratchpad for contract checks (see the `silo-backend` skill).

## Reviews
- A full-build review (e.g. "Fable review") is done in parallel slices: Silo client core, sign-in
  UI, app integration (server manager, downloads, offline sync), workflow/docs. Verify every finding
  against the code and Silo's contract or Android app before fixing; record declined ones and why
  (e.g. 4-digit PINs match Silo's apps). Report what was fixed, declined and left as follow-up.
