"""SPIKE-J freeze probe — the PyInstaller entry point under test.

Not the sidecar. `packaging/sidecar_entry.py` is untouched by this spike — see
`README.md` for why a separate probe, not the real entry, is what gets frozen
here. This script exercises exactly the shape Phase 3's path T will need at
runtime (SPIKE-I #265's finding): read a clipped `.osm.pbf` with pyosmium,
produce OSM elements in Overpass's response shape, hand them to osmnx's own
graph pipeline. It also imports `plotlines_core.graph.regions` so the frozen
tree includes the same core graph-building dependencies
(osmnx/shapely/networkx/pyproj) the real sidecar already ships (SPIKE-00)
rather than a leaner tree that would understate the size delta.

Usage (identical unfrozen or frozen — `sys.argv[0]` is the only thing that
changes under PyInstaller):

    probe_entry.py --pbf FILE --bbox W,S,E,N [--network-type bike]

Prints one JSON object to stdout and exits 0 on success. Any exception prints
a traceback to stderr and exits 1 — a silent hang or a truncated read must not
be able to look like a pass to the CI matrix driving this.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import traceback
from typing import Any

# Imported and never called. This is the entire reason the size comparison in
# RESULTS.md is valid: without this import, PyInstaller's static analysis
# would bundle a leaner tree than packaging/sidecar_entry.py's (no FastAPI,
# no uvicorn, no route modules), and the measured delta would be pyosmium
# minus a service surface it never had to give up — the wrong number. This
# line makes the probe's import graph a superset of the real sidecar's, so
# osmium is the *only* thing this build adds over packaging/build_sidecar.sh's
# output built the same day on the same runner.
import plotlines_service.__main__  # noqa: F401


def _read_pbf(pbf_path: str, bbox: tuple[float, float, float, float], network_type: str) -> dict[str, Any]:
    import osmium
    from osmnx import _overpass
    from shapely.geometry import LineString, Point, box

    west, south, east, north = bbox
    polygon = box(west, south, east, north)

    # osmnx's own filter string for this network type, parsed rather than
    # hand-copied — see spikes/SPIKE-I/elements.py for why that matters. Kept
    # inline here (not imported from the SPIKE-I module) so this probe has no
    # import dependency on another spike's directory.
    import re

    clause_re = re.compile(r'\["(?P<key>[^"]+)"(?:(?P<op>!~|~|!=|=)"(?P<value>[^"]*)")?\]')
    way_filter = _overpass._get_network_filter(network_type)
    clauses = []
    for m in clause_re.finditer(way_filter):
        clauses.append((m.group("key"), m.group("op"), m.group("value")))

    def way_passes(tags: dict[str, str]) -> bool:
        for key, op, value in clauses:
            present = key in tags
            if op is None:
                ok = present
            elif op == "!~":
                ok = (not present) or re.search(value, tags[key]) is None
            elif op == "~":
                ok = present and re.search(value, tags[key]) is not None
            elif op == "=":
                ok = present and tags[key] == value
            elif op == "!=":
                ok = (not present) or tags[key] != value
            else:  # pragma: no cover - osmnx emits no other operator
                ok = False
            if not ok:
                return False
        return True

    class WayCollector(osmium.SimpleHandler):
        def __init__(self) -> None:
            super().__init__()
            self.ways: dict[int, dict[str, Any]] = {}
            self.needed_nodes: set[int] = set()
            self.ways_considered = 0

        def way(self, w) -> None:
            tags = {t.k: t.v for t in w.tags}
            if "highway" not in tags:
                return
            self.ways_considered += 1
            if not way_passes(tags):
                return
            coords = [(nr.location.lon, nr.location.lat) for nr in w.nodes if nr.location.valid()]
            if len(coords) < 2 or not LineString(coords).intersects(polygon):
                return
            refs = [nr.ref for nr in w.nodes]
            self.ways[w.id] = {"type": "way", "id": w.id, "nodes": refs, "tags": tags}
            self.needed_nodes.update(refs)

    class NodeCollector(osmium.SimpleHandler):
        def __init__(self, needed: set[int]) -> None:
            super().__init__()
            self._needed = needed
            self.nodes: dict[int, dict[str, Any]] = {}

        def node(self, n) -> None:
            if n.id in self._needed and n.location.valid():
                tags = {t.k: t.v for t in n.tags}
                self.nodes[n.id] = {
                    "type": "node", "id": n.id,
                    "lat": n.location.lat, "lon": n.location.lon, "tags": tags,
                }

    ways = WayCollector()
    ways.apply_file(pbf_path, locations=True)
    nodes = NodeCollector(ways.needed_nodes)
    nodes.apply_file(pbf_path)

    elements: list[dict[str, Any]] = []
    elements.extend(nodes.nodes[i] for i in sorted(nodes.nodes))
    elements.extend(ways.ways[i] for i in sorted(ways.ways))

    return {
        "version": 0.6,
        "generator": "plotlines SPIKE-J freeze probe",
        "elements": elements,
    }, ways.ways_considered


def _build_graph(response_json: dict[str, Any], network_type: str):
    from osmnx import graph as oxgraph, settings, simplification, truncate

    bidirectional = network_type in settings.bidirectional_network_types
    graph = oxgraph._create_graph([response_json], bidirectional)
    graph = truncate.largest_component(graph, strongly=False)
    graph = simplification.simplify_graph(graph)
    return graph


def run(pbf_path: str, bbox: tuple[float, float, float, float], network_type: str) -> dict[str, Any]:
    # Force the same core import graph the real sidecar bundles (SPIKE-00),
    # so this probe's size delta is against an equivalent tree rather than a
    # leaner one that would understate pyosmium's cost.
    from plotlines_core.graph.regions import PLOTLINES_NODE_TAGS, PLOTLINES_WAY_TAGS

    started = time.monotonic()
    response_json, ways_considered = _read_pbf(pbf_path, bbox, network_type)
    read_s = time.monotonic() - started

    t0 = time.monotonic()
    graph = _build_graph(response_json, network_type)
    build_s = time.monotonic() - t0

    return {
        "ok": True,
        "ways_considered": ways_considered,
        "elements_read": len(response_json["elements"]),
        "nodes": graph.number_of_nodes(),
        "edges": graph.number_of_edges(),
        "read_s": round(read_s, 4),
        "build_s": round(build_s, 4),
        "plotlines_way_tags_count": len(PLOTLINES_WAY_TAGS),
        "plotlines_node_tags_count": len(PLOTLINES_NODE_TAGS),
        "frozen": bool(getattr(sys, "frozen", False)),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pbf", required=True)
    parser.add_argument("--bbox", required=True, help="west,south,east,north")
    parser.add_argument("--network-type", default="bike")
    args = parser.parse_args()

    bbox = tuple(float(v) for v in args.bbox.split(","))
    if len(bbox) != 4:
        print("--bbox must be west,south,east,north", file=sys.stderr)
        return 2

    try:
        result = run(args.pbf, bbox, args.network_type)
    except Exception:  # noqa: BLE001 - a failure here IS the spike's finding
        traceback.print_exc()
        print(json.dumps({"ok": False}))
        return 1

    if result["nodes"] < 2 or result["edges"] < 1:
        result["ok"] = False
        print(json.dumps(result))
        print("graph came back empty or disconnected", file=sys.stderr)
        return 1

    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
