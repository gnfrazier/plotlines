#!/usr/bin/env bash
# Copies the SPIKE-14 WNC-corridor archive into the §6.3 mirror tree under
# its own honest build id, and records which region it covers in
# MIRROR_STATE.json's `basemap` section (issue #257, Phase 1.3 of epic #264;
# docs/Plotlines_OSM_Acquisition_Review.md §6.2/§6.3, addendum finding G3/1b,
# checklist item 13).
#
# This is a *stand-in* for the real Protomaps planet build
# (plotlines_core.tiles.mirror.MIRROR_ARCHIVE_URL) — the mirror does not
# carry a planet archive (§6.2: "do not put a planet archive on it"). Naming
# the stand-in `planet.pmtiles` would make a one-corridor file look like
# whole-planet coverage: any bbox outside WNC would fail as a silent miss
# that reads as a mirror bug. It goes in under `basemap/protomaps/<build
# id>-wnc/corridor.pmtiles` instead, so the honest scope is visible in the
# path itself, and MIRROR_STATE.json names the covered region so a consumer
# can tell "outside coverage" from "mirror broken" without opening the file.
#
# Usage: ./copy_basemap_standin.sh [ROOT] [SOURCE_ARCHIVE]
#   ROOT defaults to /srv/plotlines-mirror (the production path) — pass a
#   scratch directory for a local dry run against build_tree.sh's output.
#   SOURCE_ARCHIVE defaults to a repo-relative path to
#   spikes/SPIKE-14/tiles/wnc-corridor.pmtiles, which only resolves when this
#   script is run from a full checkout. spikes/SPIKE-14/tiles/ is gitignored
#   (a locally-built 118 MB spike artifact, not a repo file) — deploying to
#   the Pi means scp/rsync-ing that archive onto the host first and passing
#   its path explicitly, the same way deploy/mirror itself is scp'd over.
#
# Requires: build_tree.sh already run against ROOT (MIRROR_STATE.json must
# exist — this script only ever edits its `basemap` key, never its
# `geofabrik` key, which belongs to the #258/#260 sync client).
set -euo pipefail

ROOT="${1:-/srv/plotlines-mirror}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ARCHIVE="${2:-$HERE/../../spikes/SPIKE-14/tiles/wnc-corridor.pmtiles}"

# Keep in lockstep with core/plotlines_core/tiles/mirror.py's
# WNC_CORRIDOR_BUILD_ID / WNC_CORRIDOR_BBOX / WNC_CORRIDOR_REGION_NAME —
# service/tests/test_mirror_deploy_config.py asserts these three literals
# against that module so the two can't silently drift apart.
BUILD_ID="20250101-wnc"
REGION_NAME="wnc-corridor"
# west south east north — read directly off the archive's own PMTiles header
# (min_lon_e7/min_lat_e7/max_lon_e7/max_lat_e7), not asserted.
BBOX_WEST="-83.6"
BBOX_SOUTH="35.2"
BBOX_EAST="-81.0"
BBOX_NORTH="36.4"

if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
	echo "error: source archive not found at $SOURCE_ARCHIVE" >&2
	echo "  spikes/SPIKE-14/tiles/ is gitignored — copy the archive onto" >&2
	echo "  this host first and pass its path as the second argument." >&2
	exit 1
fi

STATE_FILE="$ROOT/MIRROR_STATE.json"
if [[ ! -f "$STATE_FILE" ]]; then
	echo "error: $STATE_FILE does not exist — run build_tree.sh against" >&2
	echo "  $ROOT first." >&2
	exit 1
fi

DEST_DIR="$ROOT/basemap/protomaps/$BUILD_ID"
DEST="$DEST_DIR/corridor.pmtiles"

mkdir -p "$DEST_DIR"
cp "$SOURCE_ARCHIVE" "$DEST"

# MIRROR_STATE.json's `geofabrik` key is owned by the #258/#260 sync client
# and must survive this untouched — only `basemap` is ours to write, so this
# merges rather than overwrites the file.
python3 - "$STATE_FILE" "$BUILD_ID" "$REGION_NAME" \
	"$BBOX_WEST" "$BBOX_SOUTH" "$BBOX_EAST" "$BBOX_NORTH" <<'PYEOF'
import json
import sys

state_path, build_id, region_name, west, south, east, north = sys.argv[1:]

with open(state_path) as f:
	state = json.load(f)

state["basemap"] = {
	"build_id": build_id,
	"covered_regions": [
		{
			"name": region_name,
			"bbox": [float(west), float(south), float(east), float(north)],
		},
	],
}

with open(state_path, "w") as f:
	json.dump(state, f, indent=2)
	f.write("\n")
PYEOF

echo "Basemap stand-in copied to $DEST"
echo "MIRROR_STATE.json basemap.covered_regions now names $REGION_NAME"
