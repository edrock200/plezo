---
name: android-preview-release
description: Build, publish and verify Plezy's Android preview APKs (the "Plezy with Silo" pre-releases). Use when the user asks for an APK, a test build, a release, or to put a build in GitHub Releases; when the preview workflow fails; or when installing the Android SDK in a cloud session to check an APK.
---

# Android preview builds

## How a preview is published
- Workflow: `.github/workflows/silo-preview-apk.yml`. It runs on a push to a `ccr-**` or `silo/**`
  branch **only when the head commit message contains `[release-apk]`**. The upstream
  `build.yml` cannot be used: it only runs from `main` and needs the upstream signing secrets.
- It builds `flutter build apk --release --split-per-abi` (Flutter 3.47.1, Java 21) in about 13
  minutes and publishes a GitHub **pre-release** tagged `silo-preview-<version>-<shortsha>` with
  `plezy-silo-<version>-<sha>-{arm64-v8a,armeabi-v7a,x86_64}.apk` and `SHA256SUMS.txt`.
- Signing: the repository's `ANDROID_KEYSTORE_BASE64`/`ANDROID_STORE_PASSWORD`/`ANDROID_KEY_PASSWORD`/
  `ANDROID_KEY_ALIAS` secrets when set; otherwise a keystore generated once and kept in the Actions
  cache (`silo-preview-keystore-v1`), so later previews install as updates while the cache lives.
  Caches are branch-scoped: a new branch generates a new key. Without `key.properties` a release
  build would be **unsigned** and uninstallable — never remove the signing step.
- Package id stays `com.edde746.plezy`: previews replace (and cannot update) a store-installed
  Plezy. Making them install side by side would need the hard-coded provider authorities
  (`AndroidManifest.xml`, `ExternalPlayerChannel.kt`, `SystemShelfArtworkProvider.AUTHORITY` and its
  tests) to follow `applicationId` first.

## Steps
1. Make sure `flutter analyze lib test` and `scripts/run_tests.sh` pass; CI does not run tests in
   this workflow.
2. Commit with `[release-apk]` in the message (a real change, not an empty commit) and push.
3. Watch it with the GitHub MCP tools: `actions_list` (`list_workflow_runs`, branch filter) →
   `list_workflow_jobs`; on failure `get_job_logs` with `failed_only`. `gh` is not available.
4. Confirm with `list_releases` (fields `tag_name`, `html_url`, `prerelease`).
5. Verify the artifacts (below) before telling the user it is ready.

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
