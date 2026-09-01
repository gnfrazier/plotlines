"""Real region graphs through the product's own path.

The spike question is "measure the fetch-and-annotate step **against a real
graph build**", so the denominator has to be a real build: `graph.regions.
ensure_graph` — the same Overpass pull, the same simplification, the same
barrier fold, the same strongly-connected truncation the app performs when an
Author draws a bbox. A fixture read would answer a different question.

Builds are cached under `spikes/SPIKE-17/cache/` and **not committed** (a
GraphML for an 800 km² bbox is tens of MB); the timings from the cold build
are recorded in `results/run_spike.json`, which is committed. A re-run on a
warm cache reports the load time instead and says so.
"""

from __future__ import annotations

import time
from pathlib import Path

from plotlines_core.curation.providers import BBox
from plotlines_core.graph.loader import load_graphml
from plotlines_core.graph.regions import ensure_graph, region_for

CACHE = Path(__file__).resolve().parent / "cache"

#: (west, south, east, north). Both are real places with real feed coverage.
REGIONS: dict[str, tuple[float, float, float, float]] = {
    # ~777 km², rural Driftless Area — deliberately close to SPIKE-D's 704 km²
    # TRIP bbox so the timing compares, and deliberately the terrain D33 says
    # class-inferred traffic stress is wrong about.
    "driftless-lacrosse": (-91.35, 43.70, -91.00, 43.95),
    # ~270 km², dense urban — the density contrast, 5x the events in a third
    # of the area.
    "milwaukee": (-88.05, 42.95, -87.85, 43.10),
}


def bbox_of(name: str) -> BBox:
    west, south, east, north = REGIONS[name]
    return BBox(west=west, south=south, east=east, north=north)


def region_graph(name: str, *, network_type: str = "bike") -> dict:
    """Build (or load) one region graph, timed. Returns the graph plus what
    the timing actually measured, so a warm run never reports a build time it
    did not pay."""
    bbox = REGIONS[name]
    region = region_for(bbox, network_type=network_type)
    path = region.graph_path(CACHE)
    was_cached = path.exists()
    # osmnx keeps its own Overpass response cache (`configure_overpass_cache`).
    # A build whose *own* response is in there is a rebuild, not a cold build,
    # and the difference is most of the time. The flag below is the weaker,
    # honest statement it can make cheaply: whether that shared directory had
    # any prior content at all — a second region in one run sees `True` while
    # still paying a full Overpass round trip for its own bbox.
    overpass_cache = CACHE / "overpass"
    overpass_warm = overpass_cache.exists() and any(overpass_cache.iterdir())

    t0 = time.perf_counter()
    ensure_graph(region, CACHE)
    build_s = time.perf_counter() - t0

    loaded = load_graphml(path)
    return {
        "name": name,
        "bbox": bbox,
        "network_type": network_type,
        "graph": loaded.graph,
        "nodes": loaded.node_count,
        "edges": loaded.edge_count,
        "cold_build": not was_cached,
        "overpass_cache_warm": overpass_warm,
        "build_seconds": round(build_s, 2),
        "load_seconds": round(loaded.load_seconds, 2),
        "graphml_bytes": path.stat().st_size,
    }
