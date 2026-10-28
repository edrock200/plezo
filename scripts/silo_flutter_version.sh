#!/usr/bin/env bash
# Prints the Flutter version upstream's build.yml pins, so the Silo preview workflows build with
# the same SDK as upstream's releases. Fails when build.yml and the setup-flutter-git action
# (used for Windows arm64) name different versions.
#
#   silo_flutter_version.sh [<build.yml> [<setup-flutter-git action.yml>]]
set -euo pipefail

build_yml="${1:-.github/workflows/build.yml}"
action_yml="${2:-.github/actions/setup-flutter-git/action.yml}"

from_build="$(sed -n 's/^[[:space:]]*FLUTTER_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' "$build_yml" | head -n1)"
# shellcheck disable=SC2016 # a literal $version in action.yml
from_action="$(sed -n 's/^[[:space:]]*\$version[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)".*$/\1/p' "$action_yml" | head -n1)"

[[ -n "$from_build" ]] || { echo "::error::No FLUTTER_VERSION in $build_yml" >&2; exit 1; }
[[ -n "$from_action" ]] || { echo "::error::No \$version in $action_yml" >&2; exit 1; }
if [[ "$from_build" != "$from_action" ]]; then
  echo "::error::$build_yml pins Flutter $from_build but $action_yml pins $from_action" >&2
  exit 1
fi
echo "$from_build"
