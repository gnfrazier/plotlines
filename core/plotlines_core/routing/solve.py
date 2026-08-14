"""Route solving and the Segment result (ARCH §6.2 `routing/`, §7.2).

SPIKE-00 scope: a real weighted solve over a real graph, producing a real Segment with
geometry and an elevation profile. Loop shapes, the full via-node constraint treatment
(FR8a — that is SPIKE-01's question), and conflict relaxation (FR9 — SPIKE-02) are
explicitly not answered here.
"""

from __future__ import annotations

import time
from dataclasses import asdict, dataclass, field

import networkx as nx
from shapely.geometry import LineString

from plotlines_core.elevation.sampler import ElevationSampler
from plotlines_core.graph.loader import nearest_node
from plotlines_core.scoring.profile import WeightProfile, edge_cost


class NoRouteFound(Exception):
    """No path exists between the requested points under this graph."""


@dataclass
class Segment:
    """One routed leg. The unit `/segments/generate` returns (ARCH §7.2)."""

    mode: str
    theme: str
    distance_m: float
    coordinates: list[list[float]] = field(default_factory=list)  # [[lon, lat], ...]
    elevation: dict = field(default_factory=dict)
    node_count: int = 0
    solve_ms: float = 0.0
    geometry_wkt: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


def _weighted_path(graph: nx.MultiDiGraph, src: int, dst: int,
                   profile: WeightProfile) -> list[int]:
    def weight(u, v, edge_dict):
        # MultiDiGraph: pick the cheapest parallel edge
        return min(edge_cost(d, profile) for d in edge_dict.values())

    try:
        return nx.shortest_path(graph, src, dst, weight=weight)
    except (nx.NetworkXNoPath, nx.NodeNotFound) as exc:
        raise NoRouteFound(f"no path from {src} to {dst}") from exc


def _path_length_m(graph: nx.MultiDiGraph, path: list[int]) -> float:
    total = 0.0
    for u, v in zip(path, path[1:]):
        total += min(float(d.get("length", 0.0)) for d in graph[u][v].values())
    return total


def generate_segment(
    graph: nx.MultiDiGraph,
    start: tuple[float, float],
    end: tuple[float, float],
    profile: WeightProfile,
    mode: str = "cycling",
    via: list[tuple[float, float]] | None = None,
    sampler: ElevationSampler | None = None,
) -> Segment:
    """Solve start → [via...] → end under `profile` and return a Segment."""
    t0 = time.perf_counter()

    waypoints = [start, *(via or []), end]
    nodes = [nearest_node(graph, lat, lon) for lat, lon in waypoints]

    path: list[int] = [nodes[0]]
    for src, dst in zip(nodes, nodes[1:]):
        leg = _weighted_path(graph, src, dst, profile)
        path.extend(leg[1:])

    coords_latlon = [(graph.nodes[n]["y"], graph.nodes[n]["x"]) for n in path]
    coords_lonlat = [[lon, lat] for lat, lon in coords_latlon]

    # shapely/GEOS on the hot path — this is also what a real implementation needs
    # for simplification and buffer queries.
    line = LineString(coords_lonlat)

    elevation = sampler.profile(coords_latlon) if sampler else {}

    return Segment(
        mode=mode,
        theme=profile.name,
        distance_m=round(_path_length_m(graph, path), 1),
        coordinates=coords_lonlat,
        elevation=elevation,
        node_count=len(path),
        solve_ms=round((time.perf_counter() - t0) * 1000, 2),
        geometry_wkt=line.wkt if len(coords_lonlat) < 3 else line.simplify(1e-5).wkt,
    )
