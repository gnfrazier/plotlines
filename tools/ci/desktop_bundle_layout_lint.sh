#!/usr/bin/env bash
#
# Issue #567: the Linux desktop bundle's layout lives in two files that
# nothing else ties together. packaging/build_desktop_linux.sh puts the frozen
# sidecar and version.lock beside the client binary, and
# client/lib/data/sidecar_manager.dart looks for them there. If either moves
# without the other, a release bundle falls back to the repo-relative dev
# path, or finds nothing at all on a machine without the repo. This gate
# fails when the two disagree.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manager="$root/client/lib/data/sidecar_manager.dart"
script="$root/packaging/build_desktop_linux.sh"
status=0

require() {  # require <file> <fixed string> <what>
  if ! grep -qF -- "$2" "$1"; then
    echo "desktop bundle layout: ${1#"$root"/} no longer contains $3: $2" >&2
    status=1
  fi
}

require "$manager" "'\${exeDir.path}/sidecar/plotlines-sidecar'" "the bundled sidecar path"
require "$manager" "'\${exeDir.path}/version.lock'" "the bundled version.lock path"
require "$script" 'cp -a "$ONEDIR" "$BUNDLE/sidecar"' "the sidecar copy to <bundle>/sidecar"
require "$script" 'cp "$ROOT/packaging/version.lock" "$BUNDLE/version.lock"' "the version.lock copy"

if [[ "$status" == 0 ]]; then
  echo "desktop bundle layout: OK (sidecar/ and version.lock agree)"
fi
exit "$status"
