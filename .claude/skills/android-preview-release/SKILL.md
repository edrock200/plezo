---
name: android-preview-release
description: Build, publish and verify Plezy's Android preview APKs (the "Plezy with Silo" pre-releases). Use when the user asks for an APK, a test build, a release, or to put a build in GitHub Releases; when the preview workflow fails; or when installing the Android SDK in a cloud session to check an APK.
---

# Android preview builds

## How a preview is published
- Workflow: `.github/workflows/silo-preview-apk.yml`. It runs on a push to a `ccr-**` or `silo/**`
  branch **only when the head commit's first line contains `[release-apk]`** (markers in the body are
  ignored since a body mentioning `[release-apk]` once published an unintended 2.22.4). The upstream
  `build.yml` cannot be used: it only runs from `main` and needs the upstream signing secrets.
- It builds `flutter build apk --release --split-per-abi` (Java 21, the Flutter version upstream's
  `build.yml` pins in `FLUTTER_VERSION`, read by `scripts/silo_flutter_version.sh`, which also
  checks `setup-flutter-git` names the same one) in about 13 minutes and publishes a GitHub
  **pre-release** versioned `<pubspec major.minor>.N` (the user's choice): N is one above the highest
  existing `silo-preview-<major.minor>.*` **tag** (tags of deleted releases count, so a number is
  never reused), at least pubspec's patch + 1. After the 2.25.0 upstream merge the first preview is
  2.25.1. Tagged `silo-preview-<version>`, titled "Plezy <version> with Silo".
- Build number (Android versionCode) = max(pubspec build + N, last preview's build + 1), so a
  preview always installs as an update, even when an upstream merge moves pubspec's version (2.22.5
  was build 157; pubspec 2.25.0+157 makes 2.25.1 build 158). Each release records its build in a
  `silo-preview-build.txt` asset (`build=<n>`) that the next preview and the desktop builds read
  back; releases from before that are derived from their scheme (2.22.N → 152+N). All of this is
  `scripts/silo_preview_version.sh` (`next`, `latest`, `build-of`); test it locally with a fake
  `gh` on `PATH`. The workflow refuses to publish if the tag already exists or this commit already
  has a preview. `SUPPORTER_MODE` is left unset (perks off), like upstream's GitHub APK.
- Tags are pure versions because GitHub lists releases by the version in the tag (short-sha tags
  sorted by their letters and put older builds first). Assets: `plezy-silo-<version>-<sha>-{arm64-v8a,armeabi-v7a,x86_64}.apk`,
  `SHA256SUMS.txt` and `silo-preview-build.txt`.
- Signing: the repository's `ANDROID_KEYSTORE_BASE64`/`ANDROID_STORE_PASSWORD`/`ANDROID_KEY_PASSWORD`/
  `ANDROID_KEY_ALIAS` secrets when set; otherwise a keystore generated once and kept in the Actions
  cache, so later previews install as updates while the cache lives. With a
  `PREVIEW_KEYSTORE_PASSPHRASE` secret the cached keystore and password are encrypted
  (`openssl enc -aes-256-cbc -pbkdf2`, cache key `silo-preview-keystore-enc-v1`); a plaintext key
  cached earlier (`silo-preview-keystore-v1`) is restored as a fallback, keeps signing, and is saved
  encrypted under the new key. Without the secret the key stays plaintext and the job warns.
  Caches are branch-scoped and evicted after 7 days unused: a new branch, or a gap of a week,
  generates a new key and the next preview will not install over the last one. Recommend that the
  user add the `ANDROID_*` secrets for a stable key; never promise updates without them. Without `key.properties` a release
  build would be **unsigned** and uninstallable — never remove the signing step.
- Package id stays `com.edde746.plezy`: previews replace (and cannot update) a store-installed
  Plezy. Making them install side by side would need the hard-coded provider authorities
  (`AndroidManifest.xml`, `ExternalPlayerChannel.kt`, `SystemShelfArtworkProvider.AUTHORITY` and its
  tests) to follow `applicationId` first.

## Windows and macOS builds
- Workflow: `.github/workflows/silo-preview-desktop.yml`. A `gate` job reads the release marker from
  the commit's first line; `resolve` picks the code and version; then:
  - Windows (`SUPPORTER_MODE=msstore`, as upstream): x64 on `windows-latest`, arm64 on
    `windows-11-arm` (Flutter from `setup-flutter-git`), bundle checked like upstream's (required
    files present; no `*.pdb`, `plezy.lib`, `plezy.exp`, `simdutf.lib`), packaged with
    `windows/build-installer.ps1` into `plezy-silo-<v>-windows-installer.exe` and
    `…-windows-{x64,arm64}-portable.7z` + `SHA256SUMS-windows.txt`.
  - macOS (`SUPPORTER_MODE=unlocked`, as upstream): universal app on `macos-26`, signed **ad hoc** (no Developer ID), checked with
    `codesign --verify --deep --strict` and its `CFBundleShortVersionString`, packaged as
    `plezy-silo-<v>-macos.dmg` + `SHA256SUMS-macos.txt`. Users must allow it once in
    System Settings › Privacy & Security › Open Anyway (or `xattr -dr com.apple.quarantine`).
    With an Apple Developer account, port upstream `build.yml`'s import/sign/notarize steps.
- `[release-apk]` builds both from the same commit with the same version and build number, and
  waits for the Android release to attach; it stops at once if the APK run for that commit failed
  or was cancelled, and checks the release's commit and recorded build before uploading.
  `[release-desktop]`, `[release-windows]` or `[release-macos]` builds from the commit of the
  highest-versioned preview release and attaches to it.
- Never pass `ENABLE_UPDATE_CHECK=true` (the updater reads upstream Plezy's feed). Both apps keep
  Plezy's app id, so they replace an installed Plezy.
- Each build takes 10–25 minutes; verify the attached files and checksums. Running the apps is the
  user's step.

## Lessons from past previews
- **2.22.5:** the cached preview keystore had been evicted (no build for 18 days), so the APK got
  a new signing key and cannot update 2.22.4. Before announcing a preview, compare
  `apksigner verify --print-certs` with the previous release; if the SHA-256 differs, say in the
  notes that Android users must uninstall first. Only the `ANDROID_*` secrets prevent this.
- **2.22.5:** in a `set -euo pipefail` step, `curl/gh … | base64 -d | grep -m1 …` fails at
  random with "base64: Broken pipe" (grep exits early, base64 gets SIGPIPE). Decode into a
  variable first, then search it.
- **2.25.0 merge:** numbering by "count of releases + 1" reused a deleted release's tag, and
  "pubspec build + N" would have restarted below the last preview's build after an upstream merge.
  Number from the highest existing tag and keep the build above the last recorded one.

## Release notes (change log)
- Every release page carries a plain-language change log from `docs/silo-preview-changelog.md`
  (written for users, not developers: what they will notice, no class names or API routes).
- Before a `[release-apk]` push, write the notes under `## Next preview`. The build puts that
  section (plus the "Which APK" and install notes from `scripts/silo_release_notes.py`) on the new
  release.
- After the release is published, rename `## Next preview` to `## <tag>` and add a fresh empty
  `## Next preview`. Pushing the file runs `.github/workflows/silo-release-notes.yml`, which
  rewrites every listed release's page with its section (`gh release edit` with the workflow's
  token). Fix an old release's notes the same way: edit its section and push.
- The session cannot edit releases itself (the GitHub MCP tools have no release edit and `gh` has
  no valid token); always go through the change log file.

## Steps
1. Make sure `flutter analyze lib test` and `scripts/run_tests.sh` pass; CI does not run tests in
   this workflow.
2. Write the `## Next preview` notes in the change log. Commit with `[release-apk]` in the message (a real change, not an empty commit) and push.
   The workflow's concurrency group cancels an in-progress build on **any** later push to the same
   branch (even one without `[release-apk]`, whose own job is skipped). Commit follow-up docs
   locally and push them only after the release is published.
3. Watch it with the GitHub MCP tools: `actions_list` (`list_workflow_runs`, branch filter) →
   `list_workflow_jobs`; on failure `get_job_logs` with `failed_only`. `gh` is installed but has no
   valid token, so it cannot be used.
4. Confirm with `list_releases` (fields `tag_name`, `html_url`, `prerelease`). A background
   `curl` loop on `releases/download/<tag>/SHA256SUMS.txt` (HTTP 200 when published) is a cheap
   way to wait without polling the API.
5. Verify the artifacts (below) before telling the user it is ready.
6. Rename the change log section to the tag and push (no `[release-apk]`); check the notes run
   with `list_workflow_runs` and the page with `get_release_by_tag`.

## Verifying an APK in a cloud session
The Android SDK is not preinstalled and `dl.google.com` must be allowed in the environment's
network settings (ask the user; you cannot change it). Then:
```bash
export ANDROID_HOME=/opt/android-sdk
mkdir -p $ANDROID_HOME/cmdline-tools && cd /tmp
curl -sSL -o cmdtools.zip https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip
unzip -q -o cmdtools.zip -d $ANDROID_HOME/cmdline-tools && mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest
yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses >/dev/null
$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager "build-tools;35.0.0"
```
Download the release assets from `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>`, then:
- `sha256sum -c SHA256SUMS.txt`
- `build-tools/35.0.0/apksigner verify --verbose <apk>` → `Verifies` (v2/v3 only; no v1 `META-INF`
  signature is expected) and `--print-certs` for the signer.
- `build-tools/35.0.0/aapt2 dump badging <apk>` → package, `leanback-launchable-activity` (Android
  TV launcher entry) and `native-code`.
- Feature presence: `unzip -l` for assets (e.g. `assets/flutter_assets/assets/silo_icon.svg`) and
  `unzip -p <apk> lib/arm64-v8a/libapp.so | strings | grep <route>` for compiled Dart code.
There is no `/dev/kvm`, so an emulator cannot run; on-device testing is the user's step — say so.

## Which APK to recommend
- `arm64-v8a`: most phones, tablets, Nvidia Shield, recent Fire TV and Google TV devices.
- `armeabi-v7a`: 32-bit devices, including Chromecast with Google TV and many TV sticks.
- `x86_64`: emulators and x86 devices.
