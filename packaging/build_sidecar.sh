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
COLLECT_DATA=(rasterio pyproj osmnx)
COLLECT_SUBMODULES=(rasterio pyproj)
COPY_METADATA=(osmnx click attrs pydantic)

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

case "$TARGET" in
  pyinstaller-*)
    args=(--name plotlines-sidecar --noconfirm --clean
          --distpath "$DIST" --workpath "$WORK" --specpath "$WORK"
          --add-data "$ROOT/packaging/version.lock${DATA_SEP}."
          # The committed home-region PMTiles archive (FR96, issue #154) —
          # `tiles_paths.py` resolves it under sys._MEIPASS at this same
          # relative path.
          --add-data "$ROOT/service/plotlines_service/data/home_region.pmtiles${DATA_SEP}plotlines_service/data")
    [[ "$TARGET" == *onefile ]] && args+=(--onefile) || args+=(--onedir)
    for p in "${COLLECT_DATA[@]}";       do args+=(--collect-data "$p"); done
    for p in "${COLLECT_SUBMODULES[@]}"; do args+=(--collect-submodules "$p"); done
    for p in "${COPY_METADATA[@]}";      do args+=(--copy-metadata "$p"); done
    for p in "${EXCLUDE[@]}";            do args+=(--exclude-module "$p"); done
    exec "$VENV_BIN/pyinstaller$EXE" "${args[@]}" "$ENTRY"
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
