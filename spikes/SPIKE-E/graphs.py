"""Offline graph rebuilding: `raw/*.json.gz` -> the four variants, entirely without
the network.

The rebuilt graph is deliberately the shape `plotlines_core` expects — OSM tags flat
on the edge dict, `x`/`y` on the node, a shapely `geometry` where the pull had one —
because the routing half's whole point is to run the *shipped* solver, legality layer
and cue derivation over it. Anything reshaped here would be measuring this file.

Two things the rebuilt graph does **not** carry, stated once:

  * **No elevation.** `scoring.profile.features` reads `grade_abs` and falls back to
    0.0, and the driving profile's `peaks` weight is 0.0, so every driving cost in
    this spike is elevation-independent by construction. That is a real limitation for
    a *time* estimate on a mountain road and it is named in the results rather than
    hidden — it is not a limitation for the route choice being measured.
  * **No `interest_salience`.** Compose-mode only, and FR29's driving leg is an
    access leg between two fixed points (ARCH §7.7).
"""

from __future__ import annotations

import gzip
import json
import math
from dataclasses import dataclass

import networkx as nx
from shapely.geometry import LineString

from filters import variant_predicate
from regions import RAW

_EARTH_R_M = 6_371_000.0


@dataclass
class Pull:
    meta: dict
    nodes: dict
    edges: list


def load(name: str) -> Pull:
    with gzip.open(RAW / f"{name}.json.gz", "rb") as handle:
        blob = json.loads(handle.read())
    return Pull(meta=blob["meta"], nodes=blob["nodes"], edges=blob["edges"])


def build(pull: Pull, variant: str | None = None) -> nx.MultiDiGraph:
    """The pull as a graph, optionally narrowed to one download variant.

    `variant=None` is the widest thing a car could use — the pull as fetched.
    """
    keep = variant_predicate(variant) if variant else (lambda _tags: True)
    graph = nx.MultiDiGraph()
    graph.graph["crs"] = "epsg:4326"

    used: set[str] = set()
    for edge in pull.edges:
        tags = edge["tags"]
        if not keep(tags):
            continue
        data = dict(tags)
        data["length"] = edge["length"]
        if "geom" in edge:
            data["geometry"] = LineString(edge["geom"])
        graph.add_edge(int(edge["u"]), int(edge["v"]), key=edge["k"], **data)
        used.add(edge["u"])
        used.add(edge["v"])

    for node in used:
        x, y = pull.nodes[node]
        graph.nodes[int(node)]["x"] = x
        graph.nodes[int(node)]["y"] = y
    return graph


def largest_strong_component(graph: nx.MultiDiGraph) -> nx.MultiDiGraph:
    """What `graph/regions.py:ensure_graph` does to every graph the product builds
    (`ox.truncate.largest_component(strongly=True)`), reimplemented on networkx so the
    offline analysis needs no osmnx. Same definition, and `tests/test_graphs.py`
    asserts the two agree on the committed control pull."""
    if graph.number_of_nodes() == 0:
        return graph
    biggest = max(nx.strongly_connected_components(graph), key=len)
    return graph.subgraph(biggest).copy()


# ------------------------------------------------------------------- geometry

def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Metres between two (lat, lon) points."""
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2.0 * _EARTH_R_M * math.asin(math.sqrt(h))


def snap(graph: nx.MultiDiGraph, lat: float, lon: float) -> tuple[int | None, float]:
    """Nearest node and its distance in metres — the measurement `nearest_node`
    performs and then throws away behind its `OutsideGraphExtent` guard. Returned
    rather than raised because "how far is the trailhead from this graph" is one of
    the two numbers the routing half exists to report."""
    best_node, best_m = None, math.inf
    for node, data in graph.nodes(data=True):
        d = haversine_m((lat, lon), (data["y"], data["x"]))
        if d < best_m:
            best_node, best_m = node, d
    return best_node, best_m


def corridor_nodes(graph: nx.MultiDiGraph, source: int, radius_m: float) -> set[int]:
    """Every node within `radius_m` of `source` **along the road**, not as the crow
    flies. The approach corridor is a driving-distance ball for the reason the whole
    spike exists: a ridge-line road 800 m away and 40 km round is not an approach to
    this trailhead, and a straight-line ball would count it as one."""
    undirected = graph.to_undirected(as_view=True)
    lengths = nx.single_source_dijkstra_path_length(
        undirected, source, cutoff=radius_m, weight="length"
    )
    return set(lengths)


def edges_within(graph: nx.MultiDiGraph, nodes: set[int]) -> list[dict]:
    """Edge dicts with both ends inside `nodes` — one entry per *way direction* as
    the graph carries it."""
    return [
        data for u, v, data in graph.edges(data=True)
        if u in nodes and v in nodes
    ]
