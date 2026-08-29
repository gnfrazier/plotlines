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
from plotlines_core.routing.access import flags_along_walk, mode_legal_graph
from plotlines_core.scoring.metrics import edge_walk
from plotlines_core.scoring.profile import WeightProfile, Weights, edge_cost


class NoRouteFound(Exception):
    """No path exists between the requested points under this graph."""


@dataclass
class Segment:
    """One routed leg. The unit `/segments/generate` returns (ARCH §7.2)."""

    mode: str
    theme: str
    distance_m: float
    # FR7/A7 — the response's own record of which shape produced it, the
    # same field the loop-family response (`_loop_to_dict`) already carries.
    # `generate_segment` only ever solves point_to_point, so this has one
    # real value; kept as a field (not hardcoded at the call site) so a
    # future non-loop-family shape routed through this function stays honest.
    shape: str = "point_to_point"
    coordinates: list[list[float]] = field(default_factory=list)  # [[lon, lat], ...]
    elevation: dict = field(default_factory=dict)
    node_count: int = 0
    solve_ms: float = 0.0
    geometry_wkt: str = ""
    # FR128/A11 — routability constraints hit along the resolved path
    # (dismount sections, barriers, fords), surfaced rather than silently
    # rolled through. See `routing.access.flags_along_walk`.
    surfaced_constraints: list[dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return asdict(self)


def _weighted_path(graph: nx.MultiDiGraph, src: int, dst: int,
                   weights: WeightProfile | Weights) -> list[int]:
    # M2 / ARCH §7.6: the solver reads its profile per edge via `weights.at(position)`,
    # never from a profile it holds directly. The scalar case returns the same object
    # for every `position`; a scoped profile (FR36) returns whichever governs it. The
    # scoping is entirely `Weights`' concern — this function is what "does not move".
    weights = Weights.of(weights)

    sx, sy = graph.nodes[src]["x"], graph.nodes[src]["y"]
    dx, dy = graph.nodes[dst]["x"], graph.nodes[dst]["y"]
    span_sq = (dx - sx) ** 2 + (dy - sy) ** 2 or 1.0

    def _position(node: int) -> float:
        """This leg's progress at `node`, 0.0 at `src` .. 1.0 at `dst` — the scalar
        projection of the node onto the straight line between them. Available from
        node coordinates alone, so the seam carries a real position from day one
        without the solver tracking accumulated distance."""
        nx_, ny_ = graph.nodes[node]["x"], graph.nodes[node]["y"]
        t = ((nx_ - sx) * (dx - sx) + (ny_ - sy) * (dy - sy)) / span_sq
        return min(1.0, max(0.0, t))

    def weight(u, v, edge_dict):
        profile = weights.at(_position(v))
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
    profile: WeightProfile | Weights,
    mode: str = "cycling",
    shape: str = "point_to_point",
    via: list[tuple[float, float]] | None = None,
    sampler: ElevationSampler | None = None,
) -> Segment:
    """Solve start → [via...] → end under `profile` and return a Segment.

    `profile` is a `WeightProfile` (scalar) or a scoped `Weights` (FR36); the
    solver reads it per edge via `weights.at(position)` either way (M2).

    `mode` (FR128/A11) filters the graph to what's legal and physically
    passable before the solve runs — see `routing.access.mode_legal_graph`.
    """
    t0 = time.perf_counter()
    weights = Weights.of(profile)
    graph = mode_legal_graph(graph, mode)

    waypoints = [start, *(via or []), end]
    nodes = [nearest_node(graph, lat, lon) for lat, lon in waypoints]

    path: list[int] = [nodes[0]]
    for src, dst in zip(nodes, nodes[1:]):
        leg = _weighted_path(graph, src, dst, weights)
        path.extend(leg[1:])

    coords_latlon = [(graph.nodes[n]["y"], graph.nodes[n]["x"]) for n in path]
    coords_lonlat = [[lon, lat] for lat, lon in coords_latlon]

    # shapely/GEOS on the hot path — this is also what a real implementation needs
    # for simplification and buffer queries.
    line = LineString(coords_lonlat)

    elevation = sampler.profile(coords_latlon) if sampler else {}
    # Measurement re-walk: the parallel-edge pick only needs a representative
    # profile, and the scoped refinement of it is out of M2's scope — the tour
    # default is exact for the scalar case and a faithful summary otherwise.
    walk = edge_walk(graph, path, weights.default)

    return Segment(
        mode=mode,
        theme=weights.default.name,
        distance_m=round(_path_length_m(graph, path), 1),
        shape=shape,
        coordinates=coords_lonlat,
        elevation=elevation,
        node_count=len(path),
        solve_ms=round((time.perf_counter() - t0) * 1000, 2),
        geometry_wkt=line.wkt if len(coords_lonlat) < 3 else line.simplify(1e-5).wkt,
        surfaced_constraints=flags_along_walk(walk),
    )
