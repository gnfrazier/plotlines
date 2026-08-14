"""One setup, one teardown, three spikes.

SPIKE-01/02/03 all need the same expensive thing: real graphs with elevation and
grades, parsed into memory. Loading them once and handing the same `Bench` to each
spike is the only reason running them together is cheaper than running them apart.

`Bench` also owns the boring guarantees a spike result is worthless without:
determinism (fixed via-node bearings, no RNG anywhere), and honest timing (graph load
excluded from solve timings, since a request never pays it).
"""

from __future__ import annotations

import json
import platform
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import networkx as nx

from plotlines_core.graph.loader import load_graphml, nearest_node
from plotlines_core.routing.loops import offset
from plotlines_core.scoring.profile import features

SPIKES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from regions import REGIONS, Region  # noqa: E402


@dataclass
class Loaded:
    region: Region
    graph: nx.MultiDiGraph
    load_seconds: float
    stats: dict = field(default_factory=dict)


@dataclass
class Bench:
    regions: dict[str, Loaded] = field(default_factory=dict)
    started: str = ""

    @classmethod
    def setup(cls, keys: list[str] | None = None) -> Bench:
        bench = cls(started=datetime.now(timezone.utc).isoformat(timespec="seconds"))
        for key in keys or list(REGIONS):
            region = REGIONS[key]
            loaded = load_graphml(region.graph_path)
            graph = loaded.graph
            # Warm the per-edge feature cache once, outside every measured solve, so
            # the first scenario is not charged for tag parsing the rest get free.
            for _, _, data in graph.edges(data=True):
                features(data)
            bench.regions[key] = Loaded(
                region=region, graph=graph, load_seconds=loaded.load_seconds,
                stats=_graph_stats(graph, region),
            )
        return bench

    def teardown(self) -> None:
        self.regions.clear()

    def __enter__(self) -> Bench:
        return self

    def __exit__(self, *exc) -> None:
        self.teardown()

    def via_points(self, key: str, count: int, *,
                   radius_m: float = 3500.0) -> list[tuple[float, float]]:
        """`count` deterministic via-points around a region's centre.

        Fixed bearings rather than sampled nodes: a spike that picks its own via-nodes
        at random cannot be re-run to check a number.
        """
        lat, lon = self.regions[key].region.centre
        bearings = (60.0, 180.0, 300.0, 120.0)[:count]
        return [offset(lat, lon, b, radius_m) for b in bearings]

    def snap(self, key: str, point: tuple[float, float]) -> int:
        return nearest_node(self.regions[key].graph, *point)

    def environment(self) -> dict:
        return {
            "started_utc": self.started,
            "python": sys.version.split()[0],
            "platform": f"{platform.system()} {platform.machine()}",
            "regions": {k: v.stats | {"load_seconds": round(v.load_seconds, 2)}
                        for k, v in self.regions.items()},
        }


def _graph_stats(graph: nx.MultiDiGraph, region: Region) -> dict:
    """Graph shape plus OSM tag coverage.

    Tag coverage is reported because it bounds what the spikes can conclude: a surface
    band cannot be honoured on edges OSM never tagged, and reading a 0% unpaved result
    as "no gravel here" rather than "no `surface` tag here" would be a wrong answer
    dressed as a measurement.
    """
    total = tagged_surface = tagged_grade = 0
    length = 0.0
    for _, _, data in graph.edges(data=True):
        total += 1
        edge_len, _, _, _, grade = features(data)
        length += edge_len
        if data.get("surface"):
            tagged_surface += 1
        if grade:
            tagged_grade += 1
    return {
        "name": region.name,
        "character": region.character,
        "nodes": graph.number_of_nodes(),
        "edges": total,
        "network_km": round(length / 1000.0, 1),
        "surface_tagged_pct": round(100.0 * tagged_surface / total, 1) if total else 0.0,
        "graded_pct": round(100.0 * tagged_grade / total, 1) if total else 0.0,
    }


def timed(fn, *args, **kwargs):
    t0 = time.perf_counter()
    out = fn(*args, **kwargs)
    return out, (time.perf_counter() - t0) * 1000.0


def write_results(spike: str, payload: dict) -> Path:
    path = SPIKES / spike / "results" / "results.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n")
    return path
