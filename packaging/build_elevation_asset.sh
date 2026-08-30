#!/usr/bin/env bash
# FR90 — pack the shipped home-region elevation raster into its versioned
# tarball asset.
#
#   ./packaging/build_elevation_asset.sh <source-dem.tif> [out-dir]
#
# <source-dem.tif> is a GeoTIFF DEM covering the Buncombe County, NC home region
# (GEDTM30 via OpenTopography — FR85 — clipped to the bbox in
# core/plotlines_core/elevation/region_asset.py:HOME_REGION_BBOX). [out-dir]
# defaults to packaging/dist/elevation/.
#
# The output is plotlines-elevation-buncombe-nc-v<N>.tar.gz — a flat tarball of
# the raster (named as the LocalCacheSource stem) plus a manifest carrying the
# provider, CC BY licence (FR86), and version. Consumers extract it with the
# one-time setup step in packaging/README.md ("Elevation region asset"):
#   tar -C "<cache-dir>" -xf "<tarball>"
# on every platform, Windows included — never a PowerShell `>` redirection.
#
# Runs on Linux/macOS and on Windows under Git Bash, same as build_sidecar.sh.
set -euo pipefail

SRC="${1:?usage: build_elevation_asset.sh <source-dem.tif> [out-dir]}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${2:-$ROOT/packaging/dist/elevation}"

if [[ ! -f "$SRC" ]]; then
  echo "source DEM not found: $SRC" >&2
  exit 1
fi

PYTHON="${PYTHON:-python}"

"$PYTHON" - "$SRC" "$OUT" <<'PY'
import sys

from plotlines_core.elevation.region_asset import HOME_REGION_ASSET, build_region_asset

src, out = sys.argv[1], sys.argv[2]
tarball = build_region_asset(src, out)
print(f"built {tarball}")
print(f"  region : {HOME_REGION_ASSET.region_name}")
print(f"  bbox   : {HOME_REGION_ASSET.bbox}")
print(f"  version: v{HOME_REGION_ASSET.version}")
print()
print("one-time setup step (see packaging/README.md):")
print(f'  tar -C "<elevation-cache-dir>" -xf "{tarball}"')
PY
