#!/usr/bin/env bash
# SPIKE-J (#266) — freeze the probe entry point with pyosmium added.
#
# Deliberately a fork of packaging/build_sidecar.sh rather than a flag on it:
# this spike does not touch the real sidecar's entry point or build script
# (service/pyproject.toml keeps pyosmium as the `mirror-clip` extra, out of
# the frozen sidecar's import graph, specifically until this spike answers
# whether it can go back in — see that file's comment). Same COLLECT_DATA /
# COLLECT_SUBMODULES / COPY_METADATA / EXCLUDE lists as the production
# script, so the tree this measures is the same shape as SPIKE-00's baseline
# plus exactly one new dependency — osmium.
#
#   ./spikes/SPIKE-J/build_probe.sh
#
# Same venv as packaging/build_sidecar.sh ($ROOT/.venv) — pyosmium is
# installed into it as an extra step, not a separate venv, so PyInstaller
# resolves every other dependency identically to the production build.
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) WINDOWS=1 ;;
  *)                    WINDOWS=0 ;;
esac

if [[ "$WINDOWS" == 1 ]]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -W)"
  export MSYS2_ARG_CONV_EXCL='*'
  VENV_BIN_DIR=Scripts
  EXE=.exe
  DATA_SEP=';'
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  VENV_BIN_DIR=bin
  EXE=
  DATA_SEP=':'
fi

VENV="$ROOT/.venv"
VENV_BIN="$VENV/$VENV_BIN_DIR"
ENTRY="$ROOT/spikes/SPIKE-J/probe_entry.py"
DIST="$ROOT/spikes/SPIKE-J/dist/probe"
WORK="${PLOTLINES_BUILD_WORK:-$ROOT/spikes/SPIKE-J/build}"

# Same three lines packaging/build_sidecar.sh carries, plus osmium. osmium's
# compiled extension (libosmium/protozero statically linked in, expat + zlib
# dynamically) is exactly the kind of dependency SPIKE-00 §6 says to treat as
# guilty until a fresh build proves otherwise — hence collecting both its
# data and its submodules rather than assuming a plain import is enough.
COLLECT_DATA=(rasterio pyproj osmnx osmium)
COLLECT_SUBMODULES=(rasterio pyproj osmium)
COPY_METADATA=(osmnx click attrs pydantic osmium)
EXCLUDE=(pyogrio pandas.tests numpy.tests)

mkdir -p "$DIST" "$WORK"

args=(--name plotlines-spike-j-probe --noconfirm --clean --onedir
      --distpath "$DIST" --workpath "$WORK" --specpath "$WORK"
      # Same --add-data as packaging/build_sidecar.sh (version.lock, the 8.3
      # MB home_region.pmtiles basemap) — omitting these would understate
      # the baseline by an asset that has nothing to do with osmium, and the
      # size delta this spike reports needs to isolate exactly one variable.
      --add-data "$ROOT/packaging/version.lock${DATA_SEP}."
      --add-data "$ROOT/service/plotlines_service/data/home_region.pmtiles${DATA_SEP}plotlines_service/data")
for p in "${COLLECT_DATA[@]}";       do args+=(--collect-data "$p"); done
for p in "${COLLECT_SUBMODULES[@]}"; do args+=(--collect-submodules "$p"); done
for p in "${COPY_METADATA[@]}";      do args+=(--copy-metadata "$p"); done
for p in "${EXCLUDE[@]}";            do args+=(--exclude-module "$p"); done
exec "$VENV_BIN/pyinstaller$EXE" "${args[@]}" "$ENTRY"
