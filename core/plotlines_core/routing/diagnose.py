"""Naming the conflict and proposing the nearest relaxation (FR9, Story A6).

A6's acceptance criteria are specific: on infeasibility, name *the specific*
conflicting constraints, offer nearest relaxations *each stating its trade-off*,
applyable in one action — never a raw error, never a silent drop. That rules out
"no route found" and it equally rules out quietly returning a route that misses a
band. This module produces the third thing.

SPIKE-02 found the honest answer splits in two, and conflating them is the trap:

  * **Unattainable alone** — the band is outside what this graph can produce at this
    distance at *any* weights. "No loop from here climbs 800 m in 20 km." This is a
    fact about the terrain; relaxing anything else cannot help, and the only useful
    offer is a smaller number or a different place.
  * **Conflicting in combination** — each band is individually reachable, but not
    simultaneously. "Both are possible separately; the climbing is on the highway."
    Here the useful offer is which *one* to loosen, and by how little.

Reported precision is bounded by the search underneath (`search.py` is incomplete):
a combination conflict is stated as "not found", never as "proven impossible".
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

import networkx as nx

from plotlines_core.routing.search import Attempt, SearchResult, search_bands
from plotlines_core.scoring.bands import Band, BandSet, ensure_distance_band, format_value
from plotlines_core.scoring.metrics import METRIC_LABEL, METRIC_SCALE, RouteMetrics


@dataclass
class Relaxation:
    """One applyable change to one band, with what it costs the Author."""

    band: Band
    proposed: Band
    reached_by: str          # which weight archetype got there
    trade_off: str
    metrics: RouteMetrics = field(repr=False)

    def to_dict(self) -> dict:
        return {
            "metric": self.band.metric,
            "from": self.band.describe(),
            "to": self.proposed.describe(),
            "trade_off": self.trade_off,
            "reached_by": self.reached_by,
        }


@dataclass
class Diagnosis:
    feasible: bool
    kind: str                       # "none" | "unattainable" | "combination"
    conflict: list[Band]
    explanation: str
    relaxations: list[Relaxation]
    envelope: dict[str, tuple[float, float]]
    solves: int
    elapsed_ms: float
    best_effort: dict | None = None
    #: Set when the via-nodes, not the terrain, are what make the request impossible.
    via_implicated: bool = False
    via_relaxation: dict | None = None

    def to_dict(self) -> dict:
        return {
            "feasible": self.feasible,
            "kind": self.kind,
            "conflict": [b.describe() for b in self.conflict],
            "explanation": self.explanation,
            "via_implicated": self.via_implicated,
            "via_relaxation": self.via_relaxation,
            "relaxations": [r.to_dict() for r in self.relaxations],
            "envelope": {k: [round(lo, 4), round(hi, 4)]
                         for k, (lo, hi) in self.envelope.items()},
            "solves": self.solves,
            "elapsed_ms": round(self.elapsed_ms, 1),
            "best_effort": self.best_effort,
        }


#: Headroom added when widening a band, as a fraction of the value and of the metric's
#: own scale (whichever is larger).
_RELAXATION_MARGIN = 0.05


def _offer(band: Band, value: float) -> Band:
    """Widen `band` to admit `value`, plus a margin.

    Widening to *exactly* the best value ever observed produces an offer with no
    headroom, and SPIKE-02 caught it failing: Davis's climbing relaxation was pinned
    at the 26 m maximum seen during diagnosis, and re-solving under the relaxed band
    took a slightly different descent and landed just under it. The offer was correct
    to within a metre and still did not route. An offer the Author can act on has to
    survive being re-solved, so it carries margin.
    """
    margin = max(_RELAXATION_MARGIN * abs(value),
                 _RELAXATION_MARGIN * METRIC_SCALE.get(band.metric, 1.0))
    if band.minimum is not None and value < band.minimum:
        return band.widened_to(value - margin)
    if band.maximum is not None and value > band.maximum:
        return band.widened_to(value + margin)
    return band.widened_to(value)


def _trade_off(band: Band, attempt: Attempt, bands: BandSet) -> str:
    """What the Author gives up by accepting this relaxation."""
    others = []
    for other in bands:
        if other.metric == band.metric:
            continue
        value = attempt.metrics.value(other.metric)
        verdict = "still inside" if other.satisfied_by(value) else "now outside"
        others.append(f"{METRIC_LABEL.get(other.metric, other.metric)} "
                      f"{format_value(other.metric, value)} ({verdict} its band)")
    got = format_value(band.metric, attempt.metrics.value(band.metric))
    tail = "; ".join(others) if others else "no other band affected"
    return f"accepts {band.label} of {got}; {tail}"


def _nearest_relaxation(band: Band, attempts: list[Attempt],
                        bands: BandSet) -> Relaxation | None:
    """Smallest widening of `band` admitting a route that meets every other band."""
    others = bands.without(band)
    candidates = [a for a in attempts if others.satisfied_by(a.metrics)]
    if not candidates:
        return None
    best = min(candidates,
               key=lambda a: abs(band.shortfall(a.metrics.value(band.metric))))
    value = best.metrics.value(band.metric)
    if band.satisfied_by(value):
        return None
    return Relaxation(band=band, proposed=_offer(band, value),
                      reached_by=best.profile.name,
                      trade_off=_trade_off(band, best, bands),
                      metrics=best.metrics)


def diagnose(
    graph: nx.MultiDiGraph,
    start: tuple[float, float],
    target_m: float,
    bands: BandSet,
    *,
    via: list[tuple[float, float]] | None = None,
    budget: int = 30,
    filter_budget: int = 16,
    mode: str = "cycling",
) -> Diagnosis:
    """Route if possible; otherwise explain what conflicts and how to loosen it.

    `mode` (FR128/A11) is threaded to every search below, so a route ruled out
    only because it crossed a `bicycle=no` way or an unpassable ford is diagnosed
    the same way any other terrain limit is — through this function's existing
    unattainable/combination split, with no separate access-conflict path needed
    (ARCH §7.9: "named through A6's existing conflict path").
    """
    t0 = time.perf_counter()
    solves = 0

    # FR8/A8: fold distance into the same constraint set every check below
    # uses — `search_bands` applies this too, but naming a distance conflict
    # (the unattainable/deletion-filter logic further down) needs it present
    # in *this* function's own `bands`, not just inside the search's descent.
    bands = ensure_distance_band(bands, target_m)

    full: SearchResult = search_bands(graph, start, target_m, bands, via=via,
                                      budget=budget, keep_attempts=True, mode=mode)
    solves += full.solves
    if full.feasible:
        return Diagnosis(True, "none", [], "all bands satisfied", [],
                         full.envelope, solves,
                         (time.perf_counter() - t0) * 1000.0,
                         full.best.to_dict() if full.best else None)

    attempts = full.attempts

    # --- is any single band unattainable on its own?
    unattainable: list[Band] = []
    for band in bands:
        if any(band.satisfied_by(a.metrics.value(band.metric)) for a in attempts):
            continue  # already reached once, so it is attainable alone
        solo = search_bands(graph, start, target_m, BandSet.of(band), via=via,
                            budget=filter_budget, mode=mode)
        solves += solo.solves
        if not solo.feasible:
            unattainable.append(band)

    if unattainable:
        # A via-node is a constraint too, and when it is the binding one, blaming the
        # terrain sends the Author to loosen a setting that was never the problem.
        # A9 makes this concrete: a café 8 km out cannot sit on a 10 km loop, and the
        # useful offer is "drop the café or accept 16 km", not "this area is flat".
        via_note = None
        if via:
            without = search_bands(graph, start, target_m,
                                   BandSet(tuple(unattainable)), via=None,
                                   budget=filter_budget, mode=mode)
            solves += without.solves
            if without.feasible:
                names = " and ".join(b.describe() for b in unattainable)
                return Diagnosis(
                    False, "combination", unattainable,
                    f"The via-node{'s' if len(via) > 1 else ''} conflict with {names}: "
                    f"the same request routes without {'them' if len(via) > 1 else 'it'}. "
                    f"Drop or move the via-node, or widen the band.",
                    [], full.envelope, solves,
                    (time.perf_counter() - t0) * 1000.0,
                    full.best.to_dict() if full.best else None,
                    via_implicated=True,
                    via_relaxation={
                        "action": "drop_via_nodes",
                        "via_count": len(via),
                        "trade_off": "the route no longer passes the designated "
                                     "node(s), but every band is satisfied",
                        "verified_routes": True,
                    })
            via_note = ("the via-node(s) do not lift this: the request fails without "
                        "them too")

        parts = []
        if via_note:
            parts.append(via_note)
        for band in unattainable:
            lo, hi = full.envelope.get(band.metric, (0.0, 0.0))
            parts.append(
                f"{band.describe()} — nothing reachable from here at this distance "
                f"goes beyond {format_value(band.metric, hi)} "
                f"(range seen {format_value(band.metric, lo)}–{format_value(band.metric, hi)})"
            )
        relaxations = []
        for band in unattainable:
            lo, hi = full.envelope[band.metric]
            reachable = hi if (band.minimum is not None
                               and band.minimum > hi) else lo
            near = min(attempts,
                       key=lambda a: abs(a.metrics.value(band.metric) - reachable))
            relaxations.append(Relaxation(
                band=band, proposed=_offer(band, reachable),
                reached_by=near.profile.name,
                trade_off=_trade_off(band, near, bands), metrics=near.metrics))
        return Diagnosis(
            False, "unattainable", unattainable,
            "This is a limit of the terrain, not of the other settings: "
            + "; ".join(parts),
            relaxations, full.envelope, solves,
            (time.perf_counter() - t0) * 1000.0,
            full.best.to_dict() if full.best else None)

    # --- every band is individually reachable: find the irreducible conflicting set
    # Deletion filter: drop a band; if the rest is still infeasible, that band was
    # never part of the conflict. O(n) searches instead of the 2^n subset sweep.
    conflict = list(bands.bands)
    for band in list(conflict):
        if len(conflict) <= 2:
            break
        reduced = BandSet(tuple(b for b in conflict if b is not band))
        probe = search_bands(graph, start, target_m, reduced, via=via,
                             budget=filter_budget, mode=mode)
        solves += probe.solves
        if not probe.feasible:
            conflict = [b for b in conflict if b is not band]

    conflict_set = BandSet(tuple(conflict))
    relaxations = [r for r in (_nearest_relaxation(b, attempts, conflict_set)
                               for b in conflict) if r is not None]

    names = " and ".join(b.describe() for b in conflict)
    explanation = (
        f"Each of these is reachable on its own, but no route was found meeting them "
        f"together: {names}. Loosen one."
    )
    return Diagnosis(False, "combination", conflict, explanation, relaxations,
                     full.envelope, solves, (time.perf_counter() - t0) * 1000.0,
                     full.best.to_dict() if full.best else None)
