#!/usr/bin/env bash
# Copies a Silo preview's Android APKs to the rolling "silo-android-latest" release under fixed
# names, so a link (or a Fire TV Downloader code) always fetches the newest preview:
#
#   https://github.com/<repo>/releases/download/silo-android-latest/plezy-silo-<abi>.apk
#
#   silo_android_latest.sh <preview tag>     e.g. silo-preview-2.25.1
#
# The release's tag is moved to the preview's commit, the three APKs are replaced in place
# (same asset names), and its notes name the version and link the preview's own release.
# GitHub's /releases/latest/download/ link cannot do this: it skips pre-releases, which every
# Silo preview is. The tag does not match silo-preview-*, so preview numbering ignores it.
# Needs GH_REPO and GH_TOKEN (gh CLI) with contents: write.
set -euo pipefail

: "${GH_REPO:?GH_REPO is not set}"
LATEST_TAG="silo-android-latest"
ABIS=(arm64-v8a armeabi-v7a x86_64)

src="${1:?usage: silo_android_latest.sh <preview tag>}"
version="${src#silo-preview-}"
commit="$(gh release view "$src" --json targetCommitish --jq .targetCommitish)"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::${src} has no commit target (${commit})"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gh release download "$src" --pattern '*.apk' --dir "$work/src"
mkdir -p "$work/out"
for abi in "${ABIS[@]}"; do
  shopt -s nullglob
  matches=("$work/src/"*"-${abi}.apk")
  shopt -u nullglob
  [[ ${#matches[@]} -eq 1 ]] || { echo "::error::${src} has ${#matches[@]} APKs for ${abi}"; exit 1; }
  cp "${matches[0]}" "$work/out/plezy-silo-${abi}.apk"
done
(cd "$work/out" && sha256sum -- *.apk > SHA256SUMS-latest.txt)

base="https://github.com/${GH_REPO}/releases/download/${LATEST_TAG}"
cat > "$work/notes.md" <<EOF
Always the newest Plezy-with-Silo **Android** preview, under file names that never change. Currently **${version}** ([release notes](https://github.com/${GH_REPO}/releases/tag/${src})).

Direct links (they always fetch the newest preview):
- ${base}/plezy-silo-armeabi-v7a.apk — every Fire TV and most Android TV sticks (32-bit; also runs on 64-bit devices)
- ${base}/plezy-silo-arm64-v8a.apk — 64-bit phones, tablets and newer Android TV / Fire TV devices
- ${base}/plezy-silo-x86_64.apk — emulators and x86 devices

Windows and macOS downloads are on each numbered release.
EOF

# Point the tag at the preview's commit (create it the first time).
if gh api "repos/${GH_REPO}/git/ref/tags/${LATEST_TAG}" > /dev/null 2>&1; then
  gh api -X PATCH "repos/${GH_REPO}/git/refs/tags/${LATEST_TAG}" -f sha="$commit" -F force=true > /dev/null
else
  gh api -X POST "repos/${GH_REPO}/git/refs" -f ref="refs/tags/${LATEST_TAG}" -f sha="$commit" > /dev/null
fi

if gh release view "$LATEST_TAG" > /dev/null 2>&1; then
  gh release edit "$LATEST_TAG" --title "Plezy with Silo — latest Android preview (${version})" \
    --notes-file "$work/notes.md" --prerelease
else
  gh release create "$LATEST_TAG" --verify-tag --prerelease \
    --title "Plezy with Silo — latest Android preview (${version})" --notes-file "$work/notes.md"
fi
gh release upload "$LATEST_TAG" "$work/out/"* --clobber
echo "Latest Android links now serve ${version} (${commit::7})."
