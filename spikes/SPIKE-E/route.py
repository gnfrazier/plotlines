"""The routing half (ARCH Q14) — the shipped solver, driving mode, real approaches.

Everything measured here runs through `plotlines_core` as the product would call it:
`multimodal.modes.weights_for("driving")` for the profile, `routing.access` for
legality, `routing.solve.generate_segment` for the solve, `trips.cues` for the sheet.
Nothing in this file re-implements a scoring decision — a spike that reimplements the
thing it is measuring measures itself (SPIKE-14's lesson from the other direction).

Four questions, in the order the issue asks them:

  1. **Does the graph contain the last mile?** Per variant: node/edge counts, how far
     the trailhead snaps, and whether the route arrives or stops short.
  2. **Does the solver produce a sane route on it**, or flee to pavement? Per variant:
     length, surface and highway composition, detour against the widest graph.
  3. **Do driving's weights do anything?** The same solve under a sweep of
     `surface_paved` and `directness`, compared by edge set. A dial that changes no
     route is not a tuned weight, it is decoration.
  4. **Is the reported time honest?** `base_speed_kmh=60.0` flat against a
     surface-aware estimate over the same route.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

import networkx as nx

from graphs import haversine_m, largest_strong_component, snap
from plotlines_core.graph.loader import DEFAULT_MAX_SNAP_M
from plotlines_core.multimodal.modes import base_speed_kmh, weights_for
from plotlines_core.routing.access import constraints_for, evaluate_edge, mode_legal_graph
from plotlines_core.routing.solve import NoRouteFound, generate_segment
from plotlines_core.scoring.metrics import edge_walk
from plotlines_core.scoring.profile import surface_bucket

DRIVING = "driving"

#: Speed by road character, km/h — **pre-registered**, and the ratios are the point,
#: not the absolute values. Sources are the OSM `smoothness` wiki's own vehicle
#: classes and the US Forest Service's posted 15–25 mph on maintenance-level 2–3
#: roads. Used only to price the *shipped* flat 60 km/h against something that reads
#: the tags already on the edge; a real implementation is B7/FR16's job, not this
#: spike's.
SPEED_KMH: dict[str, float] = {
    "paved_major": 90.0,     # trunk/primary/secondary, paved
    "paved_minor": 60.0,     # tertiary/unclassified/residential, paved
    "gravel_road": 45.0,     # unpaved but graded: `compacted`, `fine_gravel`, grade1-2
    "rough_road": 25.0,      # `gravel`/`dirt`/`ground`, `smoothness=bad`, grade3
    "track": 20.0,           # highway=track with no better signal
    "very_rough": 12.0,      # `smoothness=very_bad`+, grade4-5, `4wd_only=yes`
}

_MAJOR = frozenset({"motorway", "trunk", "primary", "secondary",
                    "motorway_link", "trunk_link", "primary_link", "secondary_link"})
_GRADED = frozenset({"compacted", "fine_gravel", "gravel", "pebblestone"})
_ROUGH_SURFACE = frozenset({"dirt", "ground", "earth", "unpaved", "grass", "sand", "mud"})


def _first(value):
    return value[0] if isinstance(value, list) and value else value


def _tag(data: dict, key: str) -> str | None:
    value = _first(data.get(key))
    return str(value).lower() if value is not None else None


def speed_kmh(data: dict) -> float:
    """A surface-aware speed for one edge, from tags the edge already carries."""
    highway = _tag(data, "highway") or "unclassified"
    surface = _tag(data, "surface")
    smoothness = _tag(data, "smoothness")
    tracktype = _tag(data, "tracktype")

    if _tag(data, "4wd_only") == "yes":
        return SPEED_KMH["very_rough"]
    if smoothness in ("very_bad", "horrible", "very_horrible", "impassable"):
        return SPEED_KMH["very_rough"]
    if tracktype in ("grade4", "grade5"):
        return SPEED_KMH["very_rough"]
    if smoothness == "bad" or tracktype == "grade3" or surface in _ROUGH_SURFACE:
        return SPEED_KMH["rough_road"]
    if surface in _GRADED or tracktype in ("grade1", "grade2"):
        return SPEED_KMH["gravel_road"]
    if highway == "track":
        return SPEED_KMH["track"]
    if highway in _MAJOR:
        return SPEED_KMH["paved_major"]
    return SPEED_KMH["paved_minor"]


# ---------------------------------------------------------------------- solve

@dataclass
class Solve:
    variant: str
    ok: bool
    reason: str = ""
    nodes: int = 0
    edges: int = 0
    nodes_truncated: int = 0
    edges_truncated: int = 0
    legal_edges: int = 0
    excluded: dict = field(default_factory=dict)
    origin_snap_m: float = 0.0
    dest_snap_m: float = 0.0
    dest_outside_guard: bool = False
    distance_m: float = 0.0
    #: Cold: the first solve on a freshly built graph, which pays `scoring.profile.
    #: features`' per-edge tag parse. Warm: the same solve again. SPIKE-01/02/03's
    #: harness warms that cache outside its measured solves; a real sidecar pays it
    #: once per region, so both numbers are reported rather than one being chosen.
    solve_ms: float = 0.0
    solve_ms_warm: float = 0.0
    #: Straight-line metres from the end of the solved route to the real trailhead —
    #: "did it arrive", which a distance and a solve time cannot answer between them.
    arrival_gap_m: float = 0.0
    detour_ratio: float = 0.0
    composition: dict = field(default_factory=dict)
    surface_km: dict = field(default_factory=dict)
    highway_km: dict = field(default_factory=dict)
    surfaced_constraints: list = field(default_factory=list)
    time_flat_min: float = 0.0
    time_surface_aware_min: float = 0.0
    edge_key_set: frozenset = frozenset()


def _exclusion_reasons(graph: nx.MultiDiGraph) -> dict:
    """Why the legality layer removes what it removes, counted per reason — the
    number `mode_legal_graph` computes and discards."""
    reasons: dict[str, int] = {}
    for _u, _v, data in graph.edges(data=True):
        verdict = evaluate_edge(data, DRIVING)
        if not verdict.passable:
            reasons[verdict.reason or "unknown"] = reasons.get(verdict.reason or "unknown", 0) + 1
    return dict(sorted(reasons.items(), key=lambda kv: -kv[1]))


def _composition(walk) -> tuple[dict, dict, float, float]:
    """Kilometres by surface bucket and by highway class, plus the two time
    estimates."""
    surface_km: dict[str, float] = {}
    highway_km: dict[str, float] = {}
    flat_speed = base_speed_kmh(DRIVING) or 60.0
    total_m = 0.0
    hours_aware = 0.0
    for _u, _v, data in walk:
        length = float(data.get("length", 0.0))
        total_m += length
        highway = _tag(data, "highway") or "unclassified"
        bucket = surface_bucket(highway, data) or "unknown"
        surface_km[bucket] = round(surface_km.get(bucket, 0.0) + length / 1000.0, 3)
        highway_km[highway] = round(highway_km.get(highway, 0.0) + length / 1000.0, 3)
        hours_aware += (length / 1000.0) / speed_kmh(data)
    flat_min = (total_m / 1000.0) / flat_speed * 60.0
    return surface_km, highway_km, round(flat_min, 1), round(hours_aware * 60.0, 1)


def solve_one(pull_graph: nx.MultiDiGraph, approach, variant: str,
              profile=None) -> Solve:
    """One (approach, variant) solve, through the product's own entry points."""
    result = Solve(variant=variant, ok=False,
                   nodes=pull_graph.number_of_nodes(),
                   edges=pull_graph.number_of_edges())

    # What `graph/regions.py:ensure_graph` does to every graph the product builds.
    graph = largest_strong_component(pull_graph)
    result.nodes_truncated = graph.number_of_nodes()
    result.edges_truncated = graph.number_of_edges()
    if result.nodes_truncated == 0:
        result.reason = "empty after strong-component truncation"
        return result

    result.excluded = _exclusion_reasons(graph)
    legal = mode_legal_graph(graph, DRIVING)
    result.legal_edges = legal.number_of_edges()

    _, result.origin_snap_m = snap(legal, *approach.origin)
    dest_node, result.dest_snap_m = snap(legal, *approach.destination)
    result.dest_outside_guard = result.dest_snap_m > DEFAULT_MAX_SNAP_M

    profile = profile or weights_for(DRIVING)
    try:
        started = time.perf_counter()
        segment = generate_segment(
            graph, approach.origin, approach.destination, profile, mode=DRIVING,
        )
        elapsed_ms = (time.perf_counter() - started) * 1000.0
    except (NoRouteFound, ValueError) as exc:
        result.reason = f"{type(exc).__name__}: {exc}"
        return result

    started = time.perf_counter()
    generate_segment(graph, approach.origin, approach.destination, profile, mode=DRIVING)
    warm_ms = (time.perf_counter() - started) * 1000.0

    result.ok = True
    result.distance_m = segment.distance_m
    result.solve_ms = round(elapsed_ms, 1)
    result.solve_ms_warm = round(warm_ms, 1)
    result.surfaced_constraints = segment.surfaced_constraints
    end_lon, end_lat = segment.coordinates[-1]
    result.arrival_gap_m = round(
        haversine_m(approach.destination, (end_lat, end_lon)), 1)

    walk = _walk(legal, approach, profile)
    result.edge_key_set = frozenset(
        (u, v) for u, v, _ in walk
    )
    surface_km, highway_km, flat, aware = _composition(walk)
    result.surface_km = surface_km
    result.highway_km = highway_km
    result.time_flat_min = flat
    result.time_surface_aware_min = aware
    paved = surface_km.get("paved", 0.0)
    total_km = sum(surface_km.values()) or 1.0
    result.composition = {
        "km": round(total_km, 2),
        "paved_pct": round(100.0 * paved / total_km, 1),
        "unknown_pct": round(100.0 * surface_km.get("unknown", 0.0) / total_km, 1),
    }
    return result


def _walk(legal_graph: nx.MultiDiGraph, approach, profile):
    """The solved path as an edge walk, re-derived with the same functions
    `generate_segment` uses internally (it returns coordinates, not edges, and the
    composition questions are all about edges)."""
    from plotlines_core.graph.loader import nearest_node
    from plotlines_core.routing.solve import _weighted_path

    src = nearest_node(legal_graph, *approach.origin, max_snap_m=None)
    dst = nearest_node(legal_graph, *approach.destination, max_snap_m=None)
    path = _weighted_path(legal_graph, src, dst, profile)
    return edge_walk(legal_graph, path, profile)


# ------------------------------------------------------------ weight sweep

def weight_sweep(pull_graph: nx.MultiDiGraph, approach, variant: str) -> list[dict]:
    """Does anything about driving's `WeightProfile` change the route?

    The sweep is over the two weights that could plausibly matter to an access leg:
    `surface_paved` (the one non-default surface dial driving ships) and `directness`
    (which multiplies *every* penalty by `1 - directness` in `edge_cost`, so at 0.95
    it scales the rest of the profile to a twentieth before it is applied).
    """
    base = weights_for(DRIVING)
    cases = [
        ("shipped", base),
        ("surface_paved=-1", base.replace(surface_paved=-1.0)),
        ("surface_paved=0", base.replace(surface_paved=0.0)),
        ("surface_paved=+1", base.replace(surface_paved=1.0)),
        ("directness=0.5", base.replace(directness=0.5)),
        ("directness=0.5,surface_paved=+1", base.replace(directness=0.5, surface_paved=1.0)),
        ("directness=0.0,surface_paved=+1", base.replace(directness=0.0, surface_paved=1.0)),
    ]
    out = []
    reference: frozenset | None = None
    for label, profile in cases:
        solved = solve_one(pull_graph, approach, variant, profile=profile)
        if reference is None:
            reference = solved.edge_key_set
        overlap = (len(solved.edge_key_set & reference) / len(reference)) if reference else 0.0
        out.append({
            "case": label,
            "ok": solved.ok,
            "km": round(solved.distance_m / 1000.0, 2),
            "paved_pct": solved.composition.get("paved_pct"),
            "identical_to_shipped": solved.edge_key_set == reference,
            "edge_overlap_pct": round(100.0 * overlap, 1),
        })
    return out


def driving_constraints() -> dict:
    """The legality row driving actually routes under, reported so the results do not
    have to be taken on trust."""
    constraints = constraints_for(DRIVING)
    return {
        "access_key": constraints.access_key,
        "excluded_values": sorted(constraints.excluded_values),
        "generic_excluded_values": sorted(constraints.generic_excluded_values),
        "ford_passable": constraints.ford_passable,
    }
