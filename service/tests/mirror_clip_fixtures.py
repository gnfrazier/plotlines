"""Shared mirror-tree and `.osm.pbf` fixture builders for
`test_mirror_clip.py` and `test_mirror_clip_server.py` (issue #262) — tiny,
fully synthetic extracts, never a real Geofabrik download or committed spike
asset, same spirit as `tiles_helpers.py`."""

from __future__ import annotations

import json
from pathlib import Path

import osmium
from osmium.osm import mutable


def write_pbf(
    path: Path,
    *,
    nodes: list[mutable.Node] | None = None,
    ways: list[mutable.Way] | None = None,
    relations: list[mutable.Relation] | None = None,
    box: tuple[float, float, float, float] | None = None,
) -> Path:
    """Write a tiny `.osm.pbf` with an explicit header `box` (west, south,
    east, north) when given — real Geofabrik extracts always declare one;
    `box=None` exercises the "unknown coverage" fallback in
    `select_covering_extracts`."""
    header = osmium.io.Header()
    if box is not None:
        west, south, east, north = box
        header.add_box(osmium.osm.Box(west, south, east, north))
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    with osmium.SimpleWriter(str(path), header=header) as writer:
        for n in nodes or []:
            writer.add_node(n)
        for w in ways or []:
            writer.add_way(w)
        for r in relations or []:
            writer.add_relation(r)
    return path


def node(id_: int, lon: float, lat: float, tags: dict[str, str] | None = None) -> mutable.Node:
    return mutable.Node(id=id_, location=(lon, lat), tags=tags or {})


def way(id_: int, node_ids: list[int], tags: dict[str, str] | None = None) -> mutable.Way:
    return mutable.Way(id=id_, nodes=node_ids, tags=tags or {})


def relation(
    id_: int, members: list[tuple[str, int, str]], tags: dict[str, str] | None = None
) -> mutable.Relation:
    return mutable.Relation(id=id_, members=members, tags=tags or {})


def build_mirror_tree(
    root: Path,
    *,
    pinned_date: str = "2026-09-01",
    regions: dict[str, Path],
) -> Path:
    """Scaffold `MIRROR_STATE.json` plus `osm/geofabrik/<pinned_date>/` the
    way `geofabrik_pull.py` leaves it, pointing at pre-built `.osm.pbf`
    fixtures already written under `regions[name]` (see `write_pbf`) —
    `discover_region_extracts` reads state, never a directory listing
    (Q6)."""
    dest_dir = root / "osm" / "geofabrik" / pinned_date
    dest_dir.mkdir(parents=True, exist_ok=True)
    region_entries = {}
    for name, src in regions.items():
        dest = dest_dir / f"{name}.osm.pbf"
        dest.write_bytes(src.read_bytes())
        region_entries[name] = {"pulled_at": "2026-09-01T00:00:00Z", "md5": "deadbeef"}

    state = {
        "geofabrik": {
            "pinned_date": pinned_date,
            "regions": region_entries,
        }
    }
    (root / "MIRROR_STATE.json").write_text(json.dumps(state, indent=2))
    return root
