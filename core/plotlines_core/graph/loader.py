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


def _distances(graph: nx.MultiDiGraph, lat: float, lon: float
               ) -> tuple[np.ndarray, np.ndarray]:
    ids, nlat, nlon = _node_arrays(graph)
    plat, plon = np.radians(lat), np.radians(lon)
    dlat, dlon = nlat - plat, nlon - plon
    a = np.sin(dlat / 2.0) ** 2 + np.cos(plat) * np.cos(nlat) * np.sin(dlon / 2.0) ** 2
    return ids, 2.0 * _EARTH_R_M * np.arcsin(np.sqrt(a))


#: Snap tolerance beyond which a coordinate is treated as outside this graph's
#: region rather than merely far from a road (issue #154 — the previously
#: unguarded `argmin` snapped an Asheville coordinate to the edge of the
#: Boulder fixture and returned a Boulder route with no error at all).
#: Generous relative to real node spacing (dense urban graphs: metres; the
#: sparsest rural fixture in this repo: rarely more than a few hundred
#: metres) but tiny next to a cross-region distance (Boulder, CO -> Asheville,
#: NC is ~2,000 km) — the guard exists to catch "wrong region", not to
#: tighten in-region snapping.
DEFAULT_MAX_SNAP_M = 3000.0


class OutsideGraphExtent(ValueError):
    """The coordinate is farther from any routable node than `max_snap_m`
    allows — almost certainly a coordinate outside this graph's region
    rather than merely off-road. A `ValueError` subclass so every existing
    `except ValueError` handler already catches it (ARCH §7.2's honest-422
    contract) without those call sites needing to change."""


def nearest_node(graph: nx.MultiDiGraph, lat: float, lon: float, *,
                 max_snap_m: float | None = DEFAULT_MAX_SNAP_M) -> int:
    """Snap a coordinate to the nearest routable node.

    Deliberately *not* `osmnx.distance.nearest_nodes`: on an unprojected graph that
    requires scikit-learn, which drags scikit-learn + scipy into the frozen sidecar
    for one k-NN query (SPIKE-00 finding). A vectorised haversine over the node array
    is exact, fast enough at MVP graph sizes, and costs nothing in binary size.

    Raises `OutsideGraphExtent` when the nearest node is farther than
    `max_snap_m` — pass `max_snap_m=None` to disable the guard (existing
    within-graph callers that already know the coordinate is valid, e.g. a
    node id round-tripped through the same graph, have no need of it).
    """
    ids, dist = _distances(graph, lat, lon)
    idx = int(np.argmin(dist))
    if max_snap_m is not None and dist[idx] > max_snap_m:
        raise OutsideGraphExtent(
            f"({lat}, {lon}) is {dist[idx] / 1000:.1f} km from the nearest graph "
            f"node — outside this graph's region (max snap {max_snap_m / 1000:.1f} km)"
        )
    return int(ids[idx])


def nodes_within(graph: nx.MultiDiGraph, node: int, radius_m: float) -> set[int]:
    """Every node within `radius_m` straight-line of `node`.

    Straight-line, not network, distance: this is used to draw a *locality* around an
    anchor, and a network-distance ball would take the shape of the very roads the
    caller is about to re-price, which is circular.
    """
    if radius_m <= 0:
        return {int(node)}
    ids, dist = _distances(graph, float(graph.nodes[node]["y"]),
                          float(graph.nodes[node]["x"]))
    return {int(n) for n in ids[dist <= radius_m]}


def _elevations(graph: nx.MultiDiGraph) -> np.ndarray | None:
    cached = graph.graph.get("_pl_node_elev")
    if cached is not None:
        return cached
    ids, _, _ = _node_arrays(graph)
    try:
        elev = np.array([float(graph.nodes[n]["elevation"]) for n in ids],
                        dtype="float64")
    except (KeyError, TypeError, ValueError):
        return None
    graph.graph["_pl_node_elev"] = elev
    return elev


def elevation_biased_node(graph: nx.MultiDiGraph, lat: float, lon: float,
                          radius_m: float, bias: float) -> int:
    """Nearest node, but allowed to trade proximity for height within `radius_m`.

    SPIKE-03 finding: on a loop, realised climbing is set far more by *where the
    shaping anchors sit* than by any edge weight — the solver can only choose among
    ways between two fixed points, and if both sit on the valley floor there is no
    hill to find. A climbing weight with no say in anchor placement is a weight with
    almost no leverage. `bias` is `WeightProfile.peaks`: positive pulls anchors uphill,
    negative pulls them onto the flat, zero reproduces `nearest_node` exactly.
    """
    if not bias or radius_m <= 0:
        return nearest_node(graph, lat, lon)
    elev = _elevations(graph)
    if elev is None:
        return nearest_node(graph, lat, lon)

    ids, dist = _distances(graph, lat, lon)
    near = dist <= radius_m
    if not near.any():
        return int(ids[int(np.argmin(dist))])

    local = elev[near]
    spread = float(local.max() - local.min())
    if spread <= 0:
        return int(ids[int(np.argmin(dist))])

    # Height gain in units of local relief, minus the detour it costs, in units of
    # the search radius. Equal footing keeps a tiny hill from dragging an anchor far.
    height = (local - local.min()) / spread
    detour = dist[near] / radius_m
    score = bias * height - 0.5 * detour
    return int(ids[near][int(np.argmax(score))])
