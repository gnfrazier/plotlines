"""Graph loading and caching (ARCH §6.2 `graph/`).

SPIKE-00 scope: load a cached GraphML off disk. Construction-from-Overpass,
simplification policy, and cache invalidation are deliberately out of scope here —
this exists so the frozen sidecar has a real OSMnx/networkx graph to route on.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path

import networkx as nx
import numpy as np
import osmnx as ox


@dataclass(frozen=True)
class LoadedGraph:
    graph: nx.MultiDiGraph
    source: Path
    load_seconds: float

    @property
    def node_count(self) -> int:
        return self.graph.number_of_nodes()

    @property
    def edge_count(self) -> int:
        return self.graph.number_of_edges()


def load_graphml(path: str | Path) -> LoadedGraph:
    """Load a cached graph. Raises FileNotFoundError if the cache dir has no graph."""
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"no cached graph at {path}")
    t0 = time.perf_counter()
    graph = ox.io.load_graphml(path)
    return LoadedGraph(graph=graph, source=path, load_seconds=time.perf_counter() - t0)


_EARTH_R_M = 6_371_000.0


def _node_arrays(graph: nx.MultiDiGraph) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Cache node ids + coords on the graph so repeated snapping is cheap."""
    cached = graph.graph.get("_pl_node_arrays")
    if cached is not None:
        return cached
    ids = np.fromiter(graph.nodes, dtype=np.int64, count=graph.number_of_nodes())
    lats = np.array([graph.nodes[n]["y"] for n in ids], dtype="float64")
    lons = np.array([graph.nodes[n]["x"] for n in ids], dtype="float64")
    arrays = (ids, np.radians(lats), np.radians(lons))
    graph.graph["_pl_node_arrays"] = arrays
    return arrays


def nearest_node(graph: nx.MultiDiGraph, lat: float, lon: float) -> int:
    """Snap a coordinate to the nearest routable node.

    Deliberately *not* `osmnx.distance.nearest_nodes`: on an unprojected graph that
    requires scikit-learn, which drags scikit-learn + scipy into the frozen sidecar
    for one k-NN query (SPIKE-00 finding). A vectorised haversine over the node array
    is exact, fast enough at MVP graph sizes, and costs nothing in binary size.
    """
    ids, nlat, nlon = _node_arrays(graph)
    plat, plon = np.radians(lat), np.radians(lon)
    dlat, dlon = nlat - plat, nlon - plon
    a = np.sin(dlat / 2.0) ** 2 + np.cos(plat) * np.cos(nlat) * np.sin(dlon / 2.0) ** 2
    dist = 2.0 * _EARTH_R_M * np.arcsin(np.sqrt(a))
    return int(ids[int(np.argmin(dist))])
