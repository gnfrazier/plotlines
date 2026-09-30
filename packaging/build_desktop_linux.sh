#!/usr/bin/env bash
#
# Assemble a runnable Linux desktop bundle: the Flutter client with the frozen
# sidecar and version.lock beside it, where SidecarManager looks for them
# (issue #567; client/lib/data/sidecar_manager.dart `_resolveBinaryPath` /
# the client version read: `<exeDir>/sidecar/plotlines-sidecar`,
# `<exeDir>/version.lock`). Unsigned; desktop-MVP scope (Linux, LAN, the Pi
# mirror). Windows/macOS installers and signing: packaging/TODO.md.
#
# Usage (from anywhere):
#   packaging/build_desktop_linux.sh               # freeze sidecar + build client + bundle
#   packaging/build_desktop_linux.sh --skip-sidecar  # reuse packaging/dist/pyinstaller-onedir
#
# Upstream defines come from the environment only, never from a file in the
# tree (packaging/README.md, "Mirror client key"). Each is passed through when
# set and non-empty:
#   PLOTLINES_MIRROR_CLIP_CLIENT_KEY  PLOTLINES_MIRROR_URL  PLOTLINES_MIRROR_STATE_URL
#   PLOTLINES_ELEVATION_UPSTREAM      PLOTLINES_TILES_UPSTREAM
#
# Output: packaging/dist/desktop/plotlines-linux-x64-<version>.tar.gz

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_SIDECAR=0
for arg in "$@"; do
  case "$arg" in
    --skip-sidecar) SKIP_SIDECAR=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != Linux ]]; then
  echo "refusing: this script builds the Linux bundle only" >&2
  exit 2
fi

VERSION="$(grep -v '^[[:space:]]*#' "$ROOT/packaging/version.lock" | sed '/^[[:space:]]*$/d' | head -n1 | tr -d '[:space:]')"
ONEDIR="$ROOT/packaging/dist/pyinstaller-onedir/plotlines-sidecar"
BUNDLE="$ROOT/client/build/linux/x64/release/bundle"
OUT_DIR="$ROOT/packaging/dist/desktop"
NAME="plotlines-linux-x64-$VERSION"

echo "==> Plotlines $VERSION"

# 1. The sidecar, frozen onedir (packaging/TODO.md Q4).
if [[ "$SKIP_SIDECAR" == 0 ]]; then
  "$ROOT/packaging/build_sidecar.sh" pyinstaller-onedir
fi
[[ -x "$ONEDIR/plotlines-sidecar" ]] || { echo "no frozen sidecar at $ONEDIR" >&2; exit 1; }

# 2. The client, with whichever upstream defines the environment carries.
DEFINES=()
for var in PLOTLINES_MIRROR_CLIP_CLIENT_KEY PLOTLINES_MIRROR_URL PLOTLINES_MIRROR_STATE_URL \
           PLOTLINES_ELEVATION_UPSTREAM PLOTLINES_TILES_UPSTREAM; do
  if [[ -n "${!var:-}" ]]; then
    DEFINES+=("--dart-define=$var=${!var}")
    echo "    define $var (set)"
  fi
done
if [[ -z "${PLOTLINES_MIRROR_CLIP_CLIENT_KEY:-}" ]]; then
  echo "    note: no PLOTLINES_MIRROR_CLIP_CLIENT_KEY — the mirror answers /clip 401 unless it is set at run time"
fi
(cd "$ROOT/client" && flutter build linux --release "${DEFINES[@]}")

# 3. The sidecar and version.lock beside the client binary.
rm -rf "$BUNDLE/sidecar"
cp -a "$ONEDIR" "$BUNDLE/sidecar"
cp "$ROOT/packaging/version.lock" "$BUNDLE/version.lock"

# 4. Paired versions (ARCH §12.1, A8) — the client refuses a mismatch at
#    runtime; refusing it here is cheaper.
SIDECAR_VERSION="$("$BUNDLE/sidecar/plotlines-sidecar" --version | tr -d '[:space:]')"
if [[ "$SIDECAR_VERSION" != "$VERSION" ]]; then
  echo "version mismatch: sidecar reports '$SIDECAR_VERSION', version.lock says '$VERSION'" >&2
  exit 1
fi
echo "    sidecar --version = $SIDECAR_VERSION (matches version.lock)"

# 5. The home-region elevation raster (FR90), when one has been built by
#    packaging/build_elevation_asset.sh. Installed once into the cache dir;
#    see INSTALL.txt.
rm -rf "$BUNDLE/elevation"
shopt -s nullglob
ELEVATION=("$ROOT"/packaging/dist/elevation/plotlines-elevation-*.tar.gz)
shopt -u nullglob
if (( ${#ELEVATION[@]} > 0 )); then
  mkdir -p "$BUNDLE/elevation"
  cp "${ELEVATION[@]}" "$BUNDLE/elevation/"
  echo "    elevation asset(s): ${ELEVATION[*]##*/}"
else
  echo "    note: no elevation asset built — the home region has no shipped raster in this bundle"
fi

# 6. Install notes, then the tarball.
cat > "$BUNDLE/INSTALL.txt" <<NOTES
Plotlines $VERSION — Linux desktop (unsigned, desktop-MVP build)

Run:
  ./plotlines_client

The app starts its own sidecar from ./sidecar/ and keeps its caches under
  \$XDG_DATA_HOME/com.example.plotlines_client/sidecar_cache
(~/.local/share/com.example.plotlines_client/sidecar_cache by default).

Map data comes from the Plotlines mirror at https://tiles.plotlines.app by
default. On a LAN mirror, point that name at it (e.g. an /etc/hosts line
"<mirror-ip> tiles.plotlines.app") or run with
  PLOTLINES_MIRROR_URL=http://<mirror-host> ./plotlines_client
The /clip key, if this build was made without one:
  PLOTLINES_MIRROR_CLIP_CLIENT_KEY=<key> ./plotlines_client

Home-region elevation (only if ./elevation/ is present), once:
  mkdir -p ~/.local/share/com.example.plotlines_client/sidecar_cache/elevation
  tar -C ~/.local/share/com.example.plotlines_client/sidecar_cache/elevation -xf elevation/plotlines-elevation-*.tar.gz
NOTES

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$BUNDLE" "$STAGE/$NAME"
tar -C "$STAGE" -czf "$OUT_DIR/$NAME.tar.gz" "$NAME"
echo "==> $OUT_DIR/$NAME.tar.gz ($(du -h "$OUT_DIR/$NAME.tar.gz" | cut -f1))"
