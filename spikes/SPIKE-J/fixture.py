"""A tiny, fully synthetic `.osm.pbf` for the freeze probe — never a real
Geofabrik download or a committed binary asset, same spirit as
`service/tests/mirror_clip_fixtures.py` (issue #262) and `tiles_helpers.py`.

This is not a parity fixture — SPIKE-I already measured parity against real
extracts (#265, RESULTS.md). SPIKE-J only needs bytes that exercise pyosmium's
real read path (a two-pass way/node handler over an actual `.osm.pbf`, not a
mock) and produce a graph with more than one node, so a frozen build that
silently returns an empty/broken read does not read as a pass.
"""

from __future__ import annotations

from pathlib import Path

import osmium
from osmium.osm import mutable

# A small connected grid, well inside this bbox, with real `highway` tags so
# osmnx's `bike` filter keeps every way. Coordinates are arbitrary — this is
# not a real place.
BBOX: tuple[float, float, float, float] = (-105.30, 40.00, -105.25, 40.05)

_NODES = [
    (1, -105.290, 40.010),
    (2, -105.285, 40.010),
    (3, -105.280, 40.010),
    (4, -105.285, 40.015),
    (5, -105.285, 40.020),
]

_WAYS = [
    (101, [1, 2, 3], {"highway": "residential", "surface": "paved"}),
    (102, [2, 4, 5], {"highway": "track", "tracktype": "grade2"}),
]


def write_fixture_pbf(path: Path) -> Path:
    header = osmium.io.Header()
    west, south, east, north = BBOX
    header.add_box(osmium.osm.Box(west, south, east, north))

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()

    with osmium.SimpleWriter(str(path), header=header) as writer:
        for node_id, lon, lat in _NODES:
            writer.add_node(mutable.Node(id=node_id, location=(lon, lat), tags={}))
        for way_id, node_ids, tags in _WAYS:
            writer.add_way(mutable.Way(id=way_id, nodes=node_ids, tags=tags))
    return path


if __name__ == "__main__":
    import sys

    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("fixture.osm.pbf")
    write_fixture_pbf(out)
    print(f"wrote {out} ({out.stat().st_size} bytes)")
