#!/usr/bin/env bash
# Picks the version and Android build number of a Silo preview release.
#
#   silo_preview_version.sh next <pubspec version> <commit>
#       The next preview of <commit>: prints version=, build=, tag= and reused=.
#       Every preview adds 0.1 (the user's decision, 2026-11-12): the version is
#       <major>.<minor + 1>.0 of the highest existing silo-preview-* tag (2.26.6 -> 2.27.0 ->
#       2.28.0), or pubspec's <major>.<minor>.0 when that is higher, so a deleted release never
#       hands its tag out again. If the highest tag already points at <commit> (the APK build
#       published first), it is reused (reused=true) instead of numbering a new one.
#       The build is max(pubspec build + 1, last preview build + 1), so an upstream merge that
#       resets pubspec's version still installs as an update.
#   silo_preview_version.sh build-of <tag>
#       The build number recorded for an existing preview release (prints the number).
#   silo_preview_version.sh latest
#       The highest-versioned existing preview release: prints tag=, version=, build=.
#
# Every release records its build in the asset named by BUILD_ASSET ("build=<n>"). Releases made
# before that are derived from the scheme they were built with: 2.22.N had build 152+N.
# Needs GH_REPO and GH_TOKEN (gh CLI).
set -euo pipefail

BUILD_ASSET="silo-preview-build.txt"
: "${GH_REPO:?GH_REPO is not set}"

# All silo-preview-* tags (including tags whose release was deleted) with their commit, as
# "<tag> <commit>" lines.
tag_commits() {
  local refs
  refs="$(gh api --paginate "repos/${GH_REPO}/git/matching-refs/tags/silo-preview-" \
    --jq '.[] | "\(.ref | ltrimstr("refs/tags/")) \(.object.type) \(.object.sha)"')"
  while read -r tag type sha; do
    [[ -n "$tag" ]] || continue
    # Annotated tags point at a tag object; follow it to the commit.
    if [[ "$type" == tag ]]; then
      sha="$(gh api "repos/${GH_REPO}/git/tags/${sha}" --jq .object.sha)"
    fi
    echo "$tag $sha"
  done <<< "$refs"
}

# The build a release recorded, or the one its tag scheme implies; empty when unknown.
build_of() {
  local tag="$1" content version
  if content="$(gh release download "$tag" --pattern "$BUILD_ASSET" --output - 2> /dev/null)"; then
    content="$(sed -n 's/^build=\([0-9][0-9]*\)$/\1/p' <<< "$content")"
    if [[ -n "$content" ]]; then echo "$content"; return; fi
  fi
  version="${tag#silo-preview-}"
  if [[ "$version" =~ ^2\.22\.([0-9]+)$ ]]; then
    echo $((152 + BASH_REMATCH[1]))
  fi
}

# The highest build of any earlier preview: tries tags from the highest version down until one
# has a known build. Prints 0 when there is none.
last_build() {
  local tag b
  while read -r tag; do
    [[ -n "$tag" ]] || continue
    b="$(build_of "$tag")"
    if [[ -n "$b" ]]; then echo "$b"; return; fi
    echo "::warning::No recorded build number for $tag; skipped." >&2
  done < <(awk '{print $1}' <<< "$ALL_TAGS" | grep -E '^silo-preview-[0-9]+\.[0-9]+\.[0-9]+$' | sort -t- -k3 -V -r)
  echo 0
}

cmd="${1:-}"
case "$cmd" in
  next)
    pub="${2:?pubspec version}"; commit="${3:?commit}"
    name="${pub%%+*}"; pub_build="${pub#*+}"
    [[ "$pub" == *+* && "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$pub_build" =~ ^[0-9]+$ ]] \
      || { echo "::error::Unexpected pubspec version '$pub'" >&2; exit 1; }
    pub_major="${name%%.*}"; rest="${name#*.}"; pub_minor="${rest%%.*}"
    ALL_TAGS="$(tag_commits)"
    highest="$(awk '{print $1}' <<< "$ALL_TAGS" | grep -E '^silo-preview-[0-9]+\.[0-9]+\.[0-9]+$' \
      | sed 's/^silo-preview-//' | sort -V | tail -n1)"
    if [[ -n "$highest" ]]; then
      highest_commit="$(awk -v t="silo-preview-$highest" '$1 == t {print $2}' <<< "$ALL_TAGS")"
      if [[ "$highest_commit" == "$commit" ]]; then
        tag="silo-preview-${highest}"
        build="$(build_of "$tag")"
        [[ -n "$build" ]] || { echo "::error::$tag was made from this commit but records no build number" >&2; exit 1; }
        printf 'version=%s\nbuild=%s\ntag=%s\nreused=true\n' "$highest" "$build" "$tag"
        exit 0
      fi
      h_major="${highest%%.*}"; h_rest="${highest#*.}"; h_minor="${h_rest%%.*}"
      next_major=$h_major; next_minor=$(( h_minor + 1 ))
    else
      next_major=$pub_major; next_minor=$pub_minor
    fi
    # pubspec's major.minor wins when upstream has moved past the previews.
    if (( pub_major > next_major || (pub_major == next_major && pub_minor > next_minor) )); then
      next_major=$pub_major; next_minor=$pub_minor
    fi
    version="${next_major}.${next_minor}.0"
    tag="silo-preview-${version}"
    if grep -q "^${tag} " <<< "$ALL_TAGS"; then
      echo "::error::Tag $tag already exists" >&2; exit 1
    fi
    last="$(last_build)"
    build=$(( pub_build + 1 ))
    (( build > last )) || build=$(( last + 1 ))
    printf 'version=%s\nbuild=%s\ntag=%s\nreused=false\n' "$version" "$build" "$tag"
    ;;
  build-of)
    tag="${2:?tag}"
    build="$(build_of "$tag")"
    [[ -n "$build" ]] || { echo "::error::No recorded build number for $tag" >&2; exit 1; }
    echo "$build"
    ;;
  latest)
    tag="$(gh release list --limit 1000 --json tagName \
      --jq '.[].tagName | select(test("^silo-preview-[0-9]+\\.[0-9]+\\.[0-9]+$"))' | sort -t- -k3 -V | tail -n1)"
    [[ -n "$tag" ]] || { echo "::error::No numbered Silo preview release to attach to." >&2; exit 1; }
    build="$(build_of "$tag")"
    [[ -n "$build" ]] || { echo "::error::No recorded build number for $tag" >&2; exit 1; }
    printf 'tag=%s\nversion=%s\nbuild=%s\n' "$tag" "${tag#silo-preview-}" "$build"
    ;;
  *)
    echo "usage: $0 next <pubspec version> <commit> | build-of <tag> | latest" >&2; exit 2
    ;;
esac
