"""Loop and via-node routing (FR7, FR8, FR8a — Stories A7, A8, A9).

SPIKE-01's central finding is expressed by the shape of this module: there is no
`generate_loop` and separate `generate_via_loop`. There is one circuit solver over an
ordered anchor list, and the difference between a plain loop, a loop through a café,
and a point-to-point leg is only *which anchors go in the list*. That is the exact
condition A9's priority note names for promoting FR8a out of P1.

Two things a naive chained-shortest-path circuit gets wrong, both handled here:

  * **Retracing.** Start → via → start over an unmodified graph returns the same road
    twice: an out-and-back wearing a loop's name. Edges already used are re-priced for
    subsequent legs (`reuse_penalty`), which is what makes the return leg find new road.
  * **Distance.** Anchors fix a circuit's length. Honouring FR8's target means moving
    the synthesised anchors until the achieved distance lands in the envelope, so the
    solver runs several times per request.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass, field

import networkx as nx

from plotlines_core.graph.loader import (
    elevation_biased_node, nearest_node, nodes_within,
)
from plotlines_core.routing.solve import NoRouteFound
from plotlines_core.scoring.metrics import RouteMetrics, edge_walk, measure
from plotlines_core.scoring.profile import WeightProfile, edge_cost

_EARTH_R_M = 6_371_000.0

#: Multiplier applied to an edge already ridden earlier in the circuit, *away* from any
#: Author-designated point. High on purpose: out in the corridor, riding the same road
#: back is the out-and-back failure and there is almost always another way round.
#: Chosen by sweep (SPIKE-01 §5): ×8 with relief gives the lowest corridor overlap of
#: any setting that does not also cost distance conformance. Higher values keep
#: shaving overlap but start distorting the loop to avoid road it should just reuse.
DEFAULT_REUSE_PENALTY = 8.0

#: Multiplier for re-ridden road *inside* an anchor's locality. Near-neutral, because
#: a café on a dead-end lane can only be reached by riding that lane both ways. This
#: is the "lollipop": a spur ridden twice, hung off a loop ridden once.
DEFAULT_RELIEF_PENALTY = 1.25

#: Radius of that locality, as a fraction of the target distance. 5% of a 20 km loop
#: is a 1 km ball — enough for a spur, far too small to hide a doubled-back corridor.
#: At 10% the zones grew until they covered most of a small loop and "near" overlap hit
#: 38%: the relief stops licensing a spur and starts concealing the out-and-back.
DEFAULT_RELIEF_FRAC = 0.05

#: Road distance exceeds straight-line distance; the anchor radius is seeded assuming
#: this much detour, then corrected by measurement.
_DETOUR_GUESS = 1.30


@dataclass
class Loop:
    path: list[int]
    walk: list[tuple[int, int, dict]] = field(repr=False, default_factory=list)
    metrics: RouteMetrics | None = None
    anchors: list[int] = field(default_factory=list)
    via_nodes: list[int] = field(default_factory=list)
    solve_ms: float = 0.0
    solver_calls: int = 0
    iterations: int = 0
    target_m: float | None = None
    closed: bool = False
    hit_via: bool = False
    mean_cost_per_m: float = 0.0

    @property
    def distance_error(self) -> float | None:
        """Signed fractional miss against the target distance."""
        if not self.target_m or self.metrics is None:
            return None
        return (self.metrics.distance_m - self.target_m) / self.target_m

    def summary(self) -> dict:
        return {
            "distance_m": round(self.metrics.distance_m, 1) if self.metrics else None,
            "target_m": self.target_m,
            "distance_error": (round(self.distance_error, 4)
                               if self.distance_error is not None else None),
            "overlap_frac": round(self.metrics.overlap_frac, 4) if self.metrics else None,
            "overlap_far_frac": (round(self.metrics.overlap_far_frac, 4)
                                 if self.metrics else None),
            "overlap_near_frac": (round(self.metrics.overlap_near_frac, 4)
                                  if self.metrics else None),
            "climb_m": round(self.metrics.climb_m, 1) if self.metrics else None,
            "traffic": round(self.metrics.traffic, 4) if self.metrics else None,
            "scenic_frac": round(self.metrics.scenic_frac, 4) if self.metrics else None,
            "unpaved_frac": round(self.metrics.unpaved_frac, 4) if self.metrics else None,
            "salience": round(self.metrics.salience, 4) if self.metrics else None,
            "mean_cost_per_m": round(self.mean_cost_per_m, 4),
            "node_count": len(self.path),
            "closed": self.closed,
            "hit_via": self.hit_via,
            "via_count": len(self.via_nodes),
            "solve_ms": round(self.solve_ms, 1),
            "solver_calls": self.solver_calls,
            "iterations": self.iterations,
        }


def offset(lat: float, lon: float, bearing_deg: float, distance_m: float
           ) -> tuple[float, float]:
    """Destination point from a start, bearing, and great-circle distance."""
    br = math.radians(bearing_deg)
    ang = distance_m / _EARTH_R_M
    lat1, lon1 = math.radians(lat), math.radians(lon)
    lat2 = math.asin(math.sin(lat1) * math.cos(ang)
                     + math.cos(lat1) * math.sin(ang) * math.cos(br))
    lon2 = lon1 + math.atan2(math.sin(br) * math.sin(ang) * math.cos(lat1),
                             math.cos(ang) - math.sin(lat1) * math.sin(lat2))
    return math.degrees(lat2), math.degrees(lon2)


def _leg_weight(profile: WeightProfile, used: set, reuse: float,
                relief_nodes: frozenset[int] = frozenset(),
                relief: float = DEFAULT_RELIEF_PENALTY):
    """Cost function for one leg, with a locality-aware re-ride charge.

    An edge already ridden is charged `reuse` — unless it lies wholly inside the
    locality of an Author-designated point, where it is charged `relief` instead.
    Both endpoints must be inside, so the relief zone cannot leak along a corridor
    that merely starts near an anchor.
    """
    def weight(u, v, edge_dict):
        cost = min(edge_cost(d, profile) for d in edge_dict.values())
        if frozenset((u, v)) not in used:
            return cost
        near = u in relief_nodes and v in relief_nodes
        return cost * (relief if near else reuse)
    return weight


@dataclass
class _Circuit:
    path: list[int]
    calls: int
    skipped: int = 0


def solve_circuit(graph: nx.MultiDiGraph, anchors: list[int], profile: WeightProfile,
                  *, reuse_penalty: float = DEFAULT_REUSE_PENALTY,
                  relief_nodes: frozenset[int] = frozenset(),
                  relief_penalty: float = DEFAULT_RELIEF_PENALTY,
                  optional: frozenset[int] = frozenset(),
                  close: bool = True) -> _Circuit:
    """Chain shortest paths through `anchors`, re-pricing road already ridden.

    This is the single primitive. `anchors == [a, b]` with `close=False` is a
    point-to-point segment; `[start, via, ...]` with `close=True` is FR8a.

    `optional` anchors are dropped if unreachable instead of failing the request.
    OSM graphs contain nodes that are weakly connected but not *directed*-reachable —
    the far side of a one-way pair, a service road off a dual carriageway — and a
    synthesised shaping anchor can land on one. Those are arbitrary, so skipping one
    costs nothing. A via-node is never optional: the Author asked for it by name, and
    quietly dropping it would be the silent compromise FR9 forbids.
    """
    if len(anchors) < 2:
        raise ValueError("a circuit needs at least two anchors")

    sequence = [*anchors, anchors[0]] if close else list(anchors)
    used: set = set()
    path: list[int] = [sequence[0]]
    calls = skipped = 0
    src = sequence[0]

    for index, dst in enumerate(sequence[1:], start=1):
        if src == dst:
            continue
        weight = _leg_weight(profile, used, reuse_penalty,
                             relief_nodes, relief_penalty)
        try:
            leg = nx.shortest_path(graph, src, dst, weight=weight)
        except (nx.NetworkXNoPath, nx.NodeNotFound) as exc:
            is_last = index == len(sequence) - 1
            if dst in optional and not is_last:
                skipped += 1
                continue
            raise NoRouteFound(f"no path from {src} to {dst}") from exc
        calls += 1
        used.update(frozenset((u, v)) for u, v in zip(leg, leg[1:]))
        path.extend(leg[1:])
        src = dst

    return _Circuit(path=path, calls=calls, skipped=skipped)


#: How far a shaping anchor may be pulled off its bearing point to find high (or
#: flat) ground, as a fraction of the ring radius.
_ANCHOR_SEARCH_FRAC = 0.35


def _anchor_ring(graph: nx.MultiDiGraph, lat: float, lon: float, radius_m: float,
                 count: int, base_bearing: float, bias: float = 0.0) -> list[int]:
    """`count` routable nodes spaced evenly by bearing around a centre.

    `bias` is the profile's `peaks`. It moves anchors, not edge costs — see
    `elevation_biased_node`: on a loop that is where climbing is really decided.
    """
    nodes: list[int] = []
    for i in range(count):
        bearing = (base_bearing + i * 360.0 / count) % 360.0
        alat, alon = offset(lat, lon, bearing, radius_m)
        node = elevation_biased_node(graph, alat, alon,
                                     radius_m * _ANCHOR_SEARCH_FRAC, bias)
        if node not in nodes:
            nodes.append(node)
    return nodes


def generate_out_and_back(
    graph: nx.MultiDiGraph,
    start: tuple[float, float],
    profile: WeightProfile,
    *,
    via: list[tuple[float, float]] | None = None,
    end: tuple[float, float] | None = None,
    target_m: float | None = None,
    tolerance: float = 0.15,
    max_iterations: int = 6,
    base_bearing: float = 0.0,
) -> Loop:
    """A7's out-and-back: out to a point, and back along the same corridor.

    **Not a literal node-for-node reversal of the outbound path.** The graph
    is directed — a one-way street has no reverse edge to walk back along —
    so naively reversing the outbound node list KeyErrors on the first
    one-way it crossed (found running this against the Boulder fixture: a
    turnaround chosen past a one-way segment made the return leg
    unwalkable). The return leg is instead its own plain shortest-path solve
    from the turnaround back through the via-nodes to `start`, with no reuse
    penalty — `generate_loop`'s reuse penalty exists to push a *loop's*
    return leg off the outbound road, and applying it here would fight the
    shape out-and-back is asking for. On ordinary bidirectional streets a
    plain reverse solve reproduces the outbound road anyway; it legitimately
    diverges only where a one-way forces it to, which is the honest answer,
    not a bug to route around.

    Either `end` (a fixed turnaround the Author picked) or `target_m` (search
    for one) must be given. `end` is honoured exactly, the same way a via-node
    is; `target_m` is honoured as an envelope, the same way FR8 treats it for
    a loop, because a single search point has only one degree of freedom to
    hit an exact round-trip distance with.
    """
    if end is None and target_m is None:
        raise ValueError("out-and-back needs an end point or a target distance")

    t0 = time.perf_counter()
    slat, slon = start
    start_node = nearest_node(graph, slat, slon)
    via_nodes = [nearest_node(graph, vlat, vlon) for vlat, vlon in (via or [])]

    def _leg(a: int, b: int, mids: list[int]) -> _Circuit:
        return solve_circuit(graph, [a, *mids, b], profile, close=False)

    calls = 0
    if end is not None:
        elat, elon = end
        turnaround = nearest_node(graph, elat, elon)
        out = _leg(start_node, turnaround, via_nodes)
        calls += out.calls
        iterations = 1
    else:
        assert target_m is not None
        one_way = target_m / 2.0 / _DETOUR_GUESS
        best: _Circuit | None = None
        best_error = math.inf
        iterations = 0
        for _ in range(max_iterations):
            iterations += 1
            turnaround = elevation_biased_node(
                graph, *offset(slat, slon, base_bearing, one_way),
                one_way * _ANCHOR_SEARCH_FRAC, profile.peaks,
            )
            attempt = _leg(start_node, turnaround, via_nodes)
            calls += attempt.calls
            walk = edge_walk(graph, attempt.path, profile)
            one_way_m = measure(graph, walk).distance_m
            error = abs(2 * one_way_m - target_m) / target_m if target_m else 0.0
            if error < best_error:
                best, best_error = attempt, error
            if error <= tolerance:
                break
            scale = (target_m / 2.0) / one_way_m if one_way_m else 1.0
            one_way *= min(max(scale, 0.4), 2.5)
        assert best is not None
        out = best
        turnaround = out.path[-1]

    ret = _leg(turnaround, start_node, list(reversed(via_nodes)))
    calls += ret.calls
    full_path = out.path + ret.path[1:]

    walk = edge_walk(graph, full_path, profile)
    metrics = measure(graph, walk)
    total_cost = sum(edge_cost(d, profile) for _, _, d in walk)

    return Loop(
        path=full_path,
        walk=walk,
        metrics=metrics,
        anchors=[start_node, *via_nodes, turnaround],
        via_nodes=via_nodes,
        solve_ms=(time.perf_counter() - t0) * 1000.0,
        solver_calls=calls,
        iterations=iterations,
        target_m=target_m,
        closed=full_path[0] == full_path[-1],
        hit_via=all(n in set(out.path) for n in via_nodes),
        mean_cost_per_m=total_cost / metrics.distance_m if metrics.distance_m else 0.0,
    )


def generate_loop(
    graph: nx.MultiDiGraph,
    start: tuple[float, float],
    target_m: float,
    profile: WeightProfile,
    *,
    via: list[tuple[float, float]] | None = None,
    reuse_penalty: float = DEFAULT_REUSE_PENALTY,
    relief_penalty: float = DEFAULT_RELIEF_PENALTY,
    relief_frac: float = DEFAULT_RELIEF_FRAC,
    tolerance: float = 0.15,
    max_iterations: int = 6,
    shaping_steps: tuple[int, ...] = (0, 1),
    base_bearing: float = 0.0,
) -> Loop:
    """A loop from `start` back to `start`, through every via-node, near `target_m`.

    Via-nodes are honoured absolutely — they are anchors, so the path cannot skip
    them. Target distance is honoured *as an envelope*: synthesised shaping anchors are
    added, and pushed out or pulled in, until the achieved distance lands within
    `tolerance`, or the budget is spent. When the vias alone already exceed the target,
    no amount of shaping can shrink the loop; that is the infeasibility A9 hands to A6,
    and this returns its closest attempt rather than pretending to have complied.
    """
    t0 = time.perf_counter()
    slat, slon = start
    start_node = nearest_node(graph, slat, slon)
    via_nodes = [nearest_node(graph, vlat, vlon) for vlat, vlon in (via or [])]

    # Relief is granted only around points the Author actually asked for — the start
    # and the via-nodes. The synthesised shaping anchors are arbitrary artefacts of
    # hitting a target distance; nobody needs to reach one twice, so exempting road
    # near them would just re-open the out-and-back the high penalty is closing.
    relief_radius = relief_frac * target_m
    relief_nodes: frozenset[int] = frozenset()
    if relief_penalty != reuse_penalty and relief_radius > 0:
        relief_nodes = frozenset().union(*(
            nodes_within(graph, n, relief_radius) for n in (start_node, *via_nodes)
        ))

    calls = 0
    best: _Circuit | None = None
    best_metrics: RouteMetrics | None = None
    best_error = math.inf
    iterations = 0

    # Two nested searches, both serving FR8's distance envelope. The inner one moves
    # the shaping ring in or out. The outer one changes *how many* shaping anchors
    # there are, because the ring radius alone cannot always reach the target: with
    # few anchors the circuit is a thin there-and-back triangle whose length is capped,
    # and no radius fixes that. Measured, one shaping anchor left Davis stuck at
    # −22.6% while two landed it at +7.1%; the regions disagree about which is right,
    # so the engine tries rather than assumes. Early exit keeps the common case cheap.
    # A closed circuit needs three anchors to enclose area; with fewer it degenerates
    # into a there-and-back whose length is capped no matter how far out the ring goes.
    # The start supplies one and each via supplies another, so the shaping ring only
    # has to make up the difference — which is why the floor falls as vias are added.
    floor = max(2 - len(via_nodes), 1)

    for step in shaping_steps:
        extra = floor + step
        radius = target_m / (5.196 * _DETOUR_GUESS) if target_m else 0.0
        for _ in range(max_iterations):
            iterations += 1
            ring = _anchor_ring(graph, slat, slon, radius, extra,
                                base_bearing + 180.0 / max(extra, 1),
                                bias=profile.peaks)
            anchors = [start_node, *via_nodes,
                       *[n for n in ring if n != start_node and n not in via_nodes]]
            if len(anchors) < 2:
                raise NoRouteFound("could not place any anchor away from the start node")

            circuit = solve_circuit(graph, anchors, profile,
                                    reuse_penalty=reuse_penalty,
                                    relief_nodes=relief_nodes,
                                    relief_penalty=relief_penalty,
                                    optional=frozenset(ring), close=True)
            calls += circuit.calls
            walk = edge_walk(graph, circuit.path, profile)
            metrics = measure(graph, walk, relief_nodes=relief_nodes)

            error = abs(metrics.distance_m - target_m) / target_m if target_m else 0.0
            if error < best_error:
                best, best_metrics, best_error = circuit, metrics, error
            if error <= tolerance:
                break

            # Secant-ish correction: circuit length scales roughly with the radius.
            scale = target_m / metrics.distance_m if metrics.distance_m else 1.0
            radius *= min(max(scale, 0.4), 2.5)

        if best_error <= tolerance:
            break

    assert best is not None and best_metrics is not None
    walk = edge_walk(graph, best.path, profile)
    total_cost = sum(edge_cost(d, profile) for _, _, d in walk)

    return Loop(
        path=best.path,
        walk=walk,
        metrics=best_metrics,
        anchors=[start_node, *via_nodes],
        via_nodes=via_nodes,
        solve_ms=(time.perf_counter() - t0) * 1000.0,
        solver_calls=calls,
        iterations=iterations,
        target_m=target_m,
        closed=best.path[0] == best.path[-1],
        hit_via=all(n in set(best.path) for n in via_nodes),
        mean_cost_per_m=total_cost / best_metrics.distance_m if best_metrics.distance_m else 0.0,
    )
