#!/usr/bin/env bash
# Copies a Plezilo preview's Android APKs to the rolling "plezilo-android-latest" release under
# fixed names, so a link (or a Fire TV Downloader code) always fetches the newest preview:
#
#   https://github.com/<repo>/releases/download/plezilo-android-latest/plezilo-<abi>.apk
#
# The old "silo-android-latest" release (plezy-silo-<abi>.apk, from before the app was renamed
# Plezilo) is no longer updated and is left as it is.
#
#   silo_android_latest.sh <preview tag>     e.g. silo-preview-2.25.1
#
# The three APKs are replaced without a gap: each new file is uploaded under a temporary name
# (next-plezilo-<abi>.apk, with retries), and only when all are up is each old asset deleted and
# the new one renamed to plezilo-<abi>.apk, so a link is missing for a moment at most, never for
# the length of an upload. The release's notes (which name the version and link the preview's
# own release) are edited last, once the files match them. Never rename the final assets or tag.
# GitHub's /releases/latest/download/ link cannot do this: it skips pre-releases, which every
# Silo preview is. The tag does not match silo-preview-*, so preview numbering ignores it.
# Needs GH_REPO and GH_TOKEN (gh CLI) with contents: write.
set -euo pipefail

: "${GH_REPO:?GH_REPO is not set}"
LATEST_TAG="plezilo-android-latest"
ABIS=(arm64-v8a armeabi-v7a x86_64)

src="${1:?usage: silo_android_latest.sh <preview tag>}"
version="${src#silo-preview-}"
echo "Reading ${src}…"
commit="$(gh release view "$src" --json targetCommitish --jq .targetCommitish)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::${src} has no commit target (${commit})"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "Downloading its APKs…"
gh release download "$src" --pattern '*.apk' --dir "$work/src"
mkdir -p "$work/out"
for abi in "${ABIS[@]}"; do
  shopt -s nullglob
  matches=("$work/src/"*"-${abi}.apk")
  shopt -u nullglob
  [[ ${#matches[@]} -eq 1 ]] || { echo "::error::${src} has ${#matches[@]} APKs for ${abi}"; exit 1; }
  cp "${matches[0]}" "$work/out/plezilo-${abi}.apk"
done
(cd "$work/out" && sha256sum -- *.apk > SHA256SUMS-latest.txt)

base="https://github.com/${GH_REPO}/releases/download/${LATEST_TAG}"
cat > "$work/notes.md" <<EOF
Always the newest Plezilo **Android** preview, under file names that never change. Currently **${version}** ([release notes](https://github.com/${GH_REPO}/releases/tag/${src})).

Direct links (they always fetch the newest preview):
- ${base}/plezilo-armeabi-v7a.apk — every Fire TV and most Android TV sticks (32-bit; also runs on 64-bit devices)
- ${base}/plezilo-arm64-v8a.apk — 64-bit phones, tablets and newer Android TV / Fire TV devices
- ${base}/plezilo-x86_64.apk — emulators and x86 devices

Fire TV **Downloader** app codes (they open these links): **5985619** (32-bit, every Fire TV; http://aftv.news/5985619) and **8032572** (64-bit; http://aftv.news/8032572).

Keep using the link or code you installed with. The 32-bit APK cannot update an install of the 64-bit one (Android sees it as an older version); to switch from 64-bit to 32-bit, uninstall Plezilo first (this removes its saved servers and downloads).

Windows and macOS downloads are on each numbered release.
EOF

# The links never depend on the tag's commit, so the release is created once and afterwards only
# its files and notes change. It is tagged at the workflow run's own commit (GITHUB_SHA): the
# workflow token is refused (HTTP 403) when it tags a commit whose workflow files differ from
# the run's, which the preview's commit can.
title="Plezilo — latest Android preview (${version})"
if ! gh release view "$LATEST_TAG" > /dev/null 2>&1; then
  echo "Creating the ${LATEST_TAG} release…"
  gh release create "$LATEST_TAG" --target "${GITHUB_SHA:-$commit}" --prerelease \
    --title "$title" --notes-file "$work/notes.md"
fi

# "<id> <name>" of each asset on the rolling release.
assets() {
  gh api "repos/${GH_REPO}/releases/tags/${LATEST_TAG}" --jq '.assets[] | "\(.id) \(.name)"'
}
asset_id() {  # <name> -> id, or nothing
  awk -v n="$1" '$2 == n {print $1; exit}' <<< "$(assets)"
}

# 1. Upload every file under a temporary name (a leftover from an interrupted run is replaced).
mkdir -p "$work/next"
for f in "$work/out/"*; do
  cp "$f" "$work/next/next-$(basename "$f")"
done
for f in "$work/next/"*; do
  for attempt in 1 2 3 4; do
    if gh release upload "$LATEST_TAG" "$f" --clobber; then break; fi
    (( attempt < 4 )) || { echo "::error::Could not upload $(basename "$f") after 4 attempts; the fixed links still serve the previous preview."; exit 1; }
    echo "Upload of $(basename "$f") failed; retrying in $((attempt * 10)) s…"
    sleep $((attempt * 10))
  done
done

# 2. Swap: delete each old asset and rename its replacement to the fixed name right away.
for f in "$work/out/"*; do
  name="$(basename "$f")"
  new_id="$(asset_id "next-${name}")"
  [[ -n "$new_id" ]] || { echo "::error::Uploaded next-${name} is missing from ${LATEST_TAG}."; exit 1; }
  old_id="$(asset_id "$name")"
  if [[ -n "$old_id" ]]; then
    gh api -X DELETE "repos/${GH_REPO}/releases/assets/${old_id}" > /dev/null
  fi
  for attempt in 1 2 3 4; do
    if gh api -X PATCH "repos/${GH_REPO}/releases/assets/${new_id}" -f name="$name" > /dev/null; then break; fi
    (( attempt < 4 )) || { echo "::error::Could not rename next-${name} to ${name}; ${base}/${name} is missing until this script runs again."; exit 1; }
    sleep $((attempt * 5))
  done
  echo "Now serving ${name}"
done

# 3. The notes and title name the version the files now are.
echo "Updating the ${LATEST_TAG} notes…"
gh release edit "$LATEST_TAG" --title "$title" --notes-file "$work/notes.md" --prerelease
echo "Latest Android links now serve ${version} (${commit::7})."
