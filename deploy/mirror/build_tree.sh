#!/usr/bin/env bash
# Scaffold the §6.3 mirror tree layout (issue #256, docs/
# Plotlines_OSM_Acquisition_Review.md §6.3/§6.0). Idempotent: safe to re-run
# — it only ever creates directories and (re)writes Plotlines' own static
# licence files; it never touches MIRROR_STATE.json if that file already
# exists, so it cannot clobber pull-state written later by the Geofabrik
# sync client (#258/#260) or the basemap stand-in copy (#257).
#
# Bucket portability (Q6-C): every path created here is a plain nested
# directory that maps 1:1 onto an object-storage key prefix — no symlink, no
# server-side rewrite, nothing a directory listing is required to resolve.
#
# Usage: ./build_tree.sh [ROOT]
#   ROOT defaults to /srv/plotlines-mirror (the production path). Pass a
#   scratch directory to build a tree for local Caddy validation.
set -euo pipefail

ROOT="${1:-/srv/plotlines-mirror}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p \
	"$ROOT/basemap/protomaps" \
	"$ROOT/osm/geofabrik"

# 1a: licence artifacts are part of the layout from the start, not
# remembered later. These are Plotlines' own static files, safe to
# overwrite on every run.
cp "$HERE/COPYRIGHT.txt" "$ROOT/COPYRIGHT.txt"
cp "$HERE/osm/COPYRIGHT.txt" "$ROOT/osm/COPYRIGHT.txt"

# MIRROR_STATE.json is derived state owned by the sync client (#258/#260) and
# the basemap copy step (#257) — seed an empty skeleton only if nothing has
# written real state yet.
if [[ ! -f "$ROOT/MIRROR_STATE.json" ]]; then
	cp "$HERE/MIRROR_STATE.example.json" "$ROOT/MIRROR_STATE.json"
fi

# index-v1.json is deliberately not created here. Geofabrik's technical
# documentation does not state a licence for that index file distinct from
# the OSM data it points at (finding L4), so it is not mirrored/redistributed
# pending the definitive check under #259 — see osm/COPYRIGHT.txt.
# MIRROR_STATE.json is Plotlines' own covering-set record in its place.

echo "Mirror tree scaffolded at $ROOT"
