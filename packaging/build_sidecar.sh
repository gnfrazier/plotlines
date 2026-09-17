#!/usr/bin/env bash
# Build the frozen sidecar. SPIKE-00 deliverable (ARCH §4, Q4/Q5).
#
#   ./packaging/build_sidecar.sh pyinstaller-onefile
#   ./packaging/build_sidecar.sh pyinstaller-onedir
#   ./packaging/build_sidecar.sh nuitka
#
# Runs on Linux/macOS and on Windows under Git Bash (`shell: bash` on a
# windows-latest CI runner is the same thing). One script rather than a parallel
# .ps1 on purpose: the flag sets below are not decoration — each one is a build
# failure this spike actually hit and fixed — and maintaining two copies of them is
# how a platform silently stops getting a fix. See
# spikes/SPIKE-00/results/RESULTS.md for the failure log and
# spikes/SPIKE-00/results/WINDOWS.md for what differs on Windows.
set -euo pipefail

TARGET="${1:-pyinstaller-onedir}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) WINDOWS=1 ;;
  *)                    WINDOWS=0 ;;
esac

if [[ "$WINDOWS" == 1 ]]; then
  # `pwd` under MSYS yields /c/Users/… , which the native Windows Python behind
  # PyInstaller cannot resolve; -W yields C:/Users/… . And because every path we
  # hand the freezer is then already Windows-form, MSYS argument mangling can only
  # corrupt it — notably the `SRC;DEST` of --add-data, whose separator MSYS would
  # otherwise read as a path-list delimiter.
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)"
  export MSYS2_ARG_CONV_EXCL='*'
  VENV_BIN_DIR=Scripts   # not bin/
  EXE=.exe
  DATA_SEP=';'           # PyInstaller splits --add-data on the host's os.pathsep
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  VENV_BIN_DIR=bin
  EXE=
  DATA_SEP=':'
fi

VENV="$ROOT/.venv"
VENV_BIN="$VENV/$VENV_BIN_DIR"
ENTRY="$ROOT/packaging/sidecar_entry.py"
DIST="$ROOT/packaging/dist/$TARGET"
WORK="${PLOTLINES_BUILD_WORK:-$ROOT/packaging/build}"

# rasterio and pyproj load Cython submodules dynamically — static analysis misses
# them (rasterio.serde was the first crash). osmnx reads its own dist metadata at
# import time, so the .dist-info must ship too.
#
# osmium (issue #275, Phase 3.3 of epic #272) moved out of service/pyproject
# .toml's `mirror-clip` extra into a base dependency once SPIKE-J (#266)
# measured it safe to freeze — PARITY on all four targets at +3.4-4.5 MB. Its
# compiled extension (libosmium/protozero statically linked in, expat + zlib
# dynamically) is exactly the class of dependency SPIKE-00 §6 says to treat as
# guilty until a fresh build proves otherwise, so it gets the same
# collect-data/collect-submodules/copy-metadata treatment as rasterio/pyproj —
# these three entries are `spikes/SPIKE-J/build_probe.sh`'s own, unchanged.
COLLECT_DATA=(rasterio pyproj osmnx osmium)
COLLECT_SUBMODULES=(rasterio pyproj osmium)
COPY_METADATA=(osmnx click attrs pydantic osmium)

# pyogrio vendors a SECOND complete GDAL build alongside rasterio's — 87 MB of pure
# duplication (25% of the unstripped tree). Nothing on the sidecar's path uses it:
# we read GraphML and GeoTIFF, not shapefiles/GeoPackage.
#
# TRIPWIRE: exactly two calls break — geopandas.read_file() and
# GeoDataFrame.to_file(). Anything reading a shapefile/GeoPackage/other OGR vector
# format needs pyogrio back, and it fails at RUNTIME, not build time.
#
# GeoJSON export/import (FR43/FR68/FR70/FR71) is NOT affected: it is plain JSON via
# shapely.geometry.mapping/shape, verified inside a frozen build. Write GeoJSON as
# JSON — never via to_file() — which also lets each feature carry its own property
# schema, as FR43/FR68 require. See spikes/SPIKE-00/results/RESULTS.md §5.
EXCLUDE=(pyogrio pandas.tests numpy.tests)

mkdir -p "$DIST" "$WORK"

# Third-party software notices (issue #267, addendum L5) — generated fresh
# from whatever is actually installed in this venv, never hand-maintained, so
# a dependency bump cannot leave it stale. Only a pyinstaller-* target embeds
# PyInstaller's own bootloader (and therefore relies on its GPL bootloader
# exception); nuitka needs no such check. `generate_third_party_licenses.py`
# raises on an empty or (where required) PyInstaller-less environment, which
# `set -euo pipefail` turns into a build failure here — the `-s` check below
# is a second, cheap belt-and-suspenders gate against a script that somehow
# exited 0 having written nothing.
NOTICES="$DIST/THIRD_PARTY_LICENSES"
NOTICES_ARGS=(--output "$NOTICES")
[[ "$TARGET" == pyinstaller-* ]] || NOTICES_ARGS+=(--no-require-pyinstaller)
"$VENV_BIN/python$EXE" "$ROOT/packaging/generate_third_party_licenses.py" "${NOTICES_ARGS[@]}"
[[ -s "$NOTICES" ]] || { echo "THIRD_PARTY_LICENSES missing or empty — refusing to freeze" >&2; exit 1; }

case "$TARGET" in
  pyinstaller-*)
    args=(--name plotlines-sidecar --noconfirm --clean
          --distpath "$DIST" --workpath "$WORK" --specpath "$WORK"
          --add-data "$ROOT/packaging/version.lock${DATA_SEP}."
          # The committed home-region PMTiles archive (FR96, issue #154) —
          # `tiles_paths.py` resolves it under sys._MEIPASS at this same
          # relative path.
          --add-data "$ROOT/service/plotlines_service/data/home_region.pmtiles${DATA_SEP}plotlines_service/data"
          # THIRD_PARTY_LICENSES (issue #267) — `licensing.software_notices`
          # resolves it under sys._MEIPASS the same way version.lock is read.
          --add-data "$NOTICES${DATA_SEP}.")
    [[ "$TARGET" == *onefile ]] && args+=(--onefile) || args+=(--onedir)
    for p in "${COLLECT_DATA[@]}";       do args+=(--collect-data "$p"); done
    for p in "${COLLECT_SUBMODULES[@]}"; do args+=(--collect-submodules "$p"); done
    for p in "${COPY_METADATA[@]}";      do args+=(--copy-metadata "$p"); done
    for p in "${EXCLUDE[@]}";            do args+=(--exclude-module "$p"); done
    # Not `exec` — the no-GPL-binary gate below (issue #275, addendum 2a/L1)
    # has to run after the freeze completes, in this same process.
    "$VENV_BIN/pyinstaller$EXE" "${args[@]}" "$ENTRY"
    ;;
  nuitka)
    # Nuitka standalone shells out to patchelf for ELF builds. The PyPI wheel
    # provides it inside the venv, which keeps the build off sudo and off the system
    # package set. Windows needs no patchelf; it wants a C compiler instead, and
    # --assume-yes-for-downloads lets Nuitka fetch its own MinGW64 rather than
    # requiring a Visual Studio install.
    export PATH="$VENV_BIN:$PATH"
    args=(--standalone --assume-yes-for-downloads
          --output-dir="$WORK/nuitka" --output-filename="plotlines-sidecar$EXE"
          --include-data-files="$ROOT/packaging/version.lock=version.lock"
          --include-data-files="$ROOT/service/plotlines_service/data/home_region.pmtiles=plotlines_service/data/home_region.pmtiles"
          --include-data-files="$NOTICES=THIRD_PARTY_LICENSES"
          --nofollow-import-to=tkinter --nofollow-import-to=matplotlib
          # editable installs are resolved by a .pth finder Nuitka does not follow
          --include-package=plotlines_core --include-package=plotlines_service)
    for p in "${COLLECT_DATA[@]}";       do args+=(--include-package-data="$p"); done
    for p in "${COLLECT_SUBMODULES[@]}"; do args+=(--include-package="$p"); done
    for p in "${COPY_METADATA[@]}";      do args+=(--include-distribution-metadata="$p"); done
    for p in "${EXCLUDE[@]}";            do args+=(--nofollow-import-to="$p"); done
    "$VENV_BIN/python$EXE" -m nuitka "${args[@]}" "$ENTRY"
    rm -rf "$DIST" && mkdir -p "$(dirname "$DIST")"
    mv "$WORK/nuitka/sidecar_entry.dist" "$DIST"
    ;;
  *)
    echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

# No GPL-licensed binary anywhere in the shipped artifact (issue #275,
# addendum 2a/L1) — mechanical, not remembered: this is what
# `spikes/SPIKE-J/check_no_gpl.py` proved out before osmium moved into the
# real freeze above, promoted here to `packaging/check_no_gpl.py` so every
# freeze runs it, not just the spike's probe build. `$DIST` covers both
# PyInstaller layouts (`plotlines-sidecar/` for onedir, the bare executable
# for onefile — the binary-tree scan finds nothing to flag either way,
# correctly, since neither ships a file literally named `osmium`) and
# nuitka's standalone tree.
"$VENV_BIN/python$EXE" "$ROOT/packaging/check_no_gpl.py" --venv "$VENV" --dist "$DIST"
