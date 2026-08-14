"""Realised route attributes — what a finished route actually *is* (FR2–FR6).

The distinction this module exists to draw: a `WeightProfile` says what the Author
*prefers*; `RouteMetrics` says what they *got*. SPIKE-03 found that FR6's min/max
bands only mean something against the second. A band on a preference weight can never
be infeasible (any number inside the band is a legal weight), which would leave A5's
"where none exists, A6 governs" clause unreachable. A band on a realised attribute —
"at least 400 m of climbing, at most 20% traffic exposure" — genuinely can be.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

import networkx as nx

from plotlines_core.scoring.profile import WeightProfile, edge_cost, features

#: Per-metric scale used to compare violations across units. Roughly "one notch an
#: Author would notice", so a 100 m climbing miss ranks against a 0.1 traffic miss.
METRIC_SCALE: dict[str, float] = {
    "distance_m": 1000.0,
    "climb_m": 100.0,
    "traffic": 0.1,
    "unpaved_frac": 0.1,
    "scenic_frac": 0.1,
}

#: Human-facing names, used verbatim in A6's conflict messages.
METRIC_LABEL: dict[str, str] = {
    "distance_m": "distance",
    "climb_m": "climbing",
    "traffic": "traffic exposure",
    "unpaved_frac": "unpaved share",
    "scenic_frac": "scenic share",
}

#: Below this surface quality an edge counts as unpaved for FR4 reporting.
_UNPAVED_BELOW = 0.6


@dataclass(frozen=True)
class RouteMetrics:
    distance_m: float
    climb_m: float
    descent_m: float
    traffic: float         # 0..1, length-weighted mean traffic stress
    unpaved_frac: float    # 0..1, share of distance on unpaved surfaces
    scenic_frac: float     # 0..1, share of distance on scenic-proxy ways
    max_grade: float
    overlap_frac: float    # 0..1, share of distance ridden more than once
    edge_count: int
    # Overlap split by where it happens. Retracing a dead-end lane to reach a café is
    # a lollipop and fine; retracing the corridor between anchors is an out-and-back
    # wearing a loop's name. One number cannot tell those apart, so there are two.
    overlap_near_frac: float = 0.0   # inside an Author-designated point's locality
    overlap_far_frac: float = 0.0    # everywhere else — the number that must stay low

    def value(self, metric: str) -> float:
        return float(getattr(self, metric))

    def to_dict(self) -> dict:
        return {k: round(v, 4) if isinstance(v, float) else v
                for k, v in asdict(self).items()}


def pick_edge(graph: nx.MultiDiGraph, u: int, v: int, profile: WeightProfile) -> dict:
    """The parallel edge the solver would have taken.

    `nx.shortest_path` returns nodes, not keys, so a MultiDiGraph leaves the parallel
    edge ambiguous. Both the solver's weight function and this use `min(edge_cost)`
    over the same dict, so they agree by construction — measuring a different edge
    than the one routed is a silent way to report a route nobody rides.
    """
    return min(graph[u][v].values(), key=lambda d: edge_cost(d, profile))


def edge_walk(graph: nx.MultiDiGraph, path: list[int],
              profile: WeightProfile) -> list[tuple[int, int, dict]]:
    return [(u, v, pick_edge(graph, u, v, profile)) for u, v in zip(path, path[1:])]


def measure(graph: nx.MultiDiGraph,
            walk: list[tuple[int, int, dict]],
            relief_nodes: frozenset[int] = frozenset()) -> RouteMetrics:
    """Summarise a walk. Elevation comes from node attributes baked in at fixture
    build; grades come from osmnx's `grade_abs`.

    `relief_nodes` is the locality around the Author's designated points; it only
    affects how overlap is *attributed*, never what the route is."""
    if not walk:
        return RouteMetrics(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0)

    total = climb = descent = 0.0
    stress_m = unpaved_m = scenic_m = 0.0
    max_grade = 0.0
    seen: dict[frozenset, float] = {}
    repeat_m = repeat_near_m = 0.0

    for u, v, data in walk:
        length, stress, quality, scenic_hit, grade = features(data)
        total += length
        stress_m += stress * length
        if quality < _UNPAVED_BELOW:
            unpaved_m += length
        if scenic_hit:
            scenic_m += length
        max_grade = max(max_grade, grade)

        # Undirected key: riding a street back the other way is still retracing it.
        key = frozenset((u, v))
        if key in seen:
            repeat_m += length
            if u in relief_nodes and v in relief_nodes:
                repeat_near_m += length
        else:
            seen[key] = length

        eu = graph.nodes[u].get("elevation")
        ev = graph.nodes[v].get("elevation")
        if eu is not None and ev is not None:
            delta = float(ev) - float(eu)
            if delta > 0:
                climb += delta
            else:
                descent -= delta

    return RouteMetrics(
        distance_m=total,
        climb_m=climb,
        descent_m=descent,
        traffic=stress_m / total if total else 0.0,
        unpaved_frac=unpaved_m / total if total else 0.0,
        scenic_frac=scenic_m / total if total else 0.0,
        max_grade=max_grade,
        overlap_frac=repeat_m / total if total else 0.0,
        edge_count=len(walk),
        overlap_near_frac=repeat_near_m / total if total else 0.0,
        overlap_far_frac=(repeat_m - repeat_near_m) / total if total else 0.0,
    )
