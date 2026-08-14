"""Searching weight space for a route inside every band (FR6, Story A5).

The engine does not get to *choose* a route's climbing or traffic directly; it chooses
weights, and the graph decides what those weights produce. So satisfying a `BandSet`
is a search over weight vectors, scored by how far the resulting route falls outside
the bands.

Two phases, and the split matters for SPIKE-02:

  1. **Probe** — evaluate a fixed archetype set that deliberately pushes each metric
     toward its extremes. This maps the *attainable envelope*: the range of climbing,
     traffic, and surface this graph can actually deliver at this distance. A band
     outside that envelope is unsatisfiable no matter how the search continues, and
     that is a fact about the terrain, not about the search budget.
  2. **Descend** — coordinate descent from the best archetype, which handles the
     ordinary case where the bands are attainable but no archetype happens to land
     inside all of them at once.

**This search is incomplete and says so.** Failing to find a satisfying route proves
only that none was found within budget. Phase 1 is what lets the engine distinguish
"the terrain cannot do this" (sound) from "we did not find it" (not sound), and
SPIKE-02 reports which of the two it is rather than blurring them.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

import networkx as nx

from plotlines_core.routing.loops import Loop, generate_loop
from plotlines_core.routing.solve import NoRouteFound
from plotlines_core.scoring.bands import BandSet
from plotlines_core.scoring.metrics import RouteMetrics
from plotlines_core.scoring.profile import TUNABLE, WeightProfile

#: Weight vectors chosen to drive each metric toward an extreme, so the probe phase
#: brackets what the graph can do. Names appear verbatim in SPIKE-02 explanations.
ARCHETYPES: tuple[WeightProfile, ...] = (
    WeightProfile("balanced"),
    WeightProfile("direct", quiet=0.1, surface=0.3, scenic=0.0, directness=0.95),
    WeightProfile("flat", quiet=0.3, surface=0.4, scenic=0.2, directness=0.7, peaks=-1.0),
    WeightProfile("climby", quiet=0.2, surface=0.3, scenic=0.2, directness=0.1, peaks=1.0),
    WeightProfile("quiet", quiet=1.0, surface=0.5, scenic=0.5, directness=0.2),
    WeightProfile("quiet_climby", quiet=1.0, surface=0.4, scenic=0.4, directness=0.1,
                  peaks=1.0),
    WeightProfile("quiet_flat", quiet=1.0, surface=0.5, scenic=0.3, directness=0.3,
                  peaks=-1.0),
    WeightProfile("scenic", quiet=0.8, surface=0.5, scenic=1.0, directness=0.15),
    WeightProfile("paved", quiet=0.6, surface=1.0, scenic=0.3, directness=0.4),
    WeightProfile("rough", quiet=0.8, surface=0.0, scenic=0.7, directness=0.2),
)

_STEPS = (0.5, 0.25)


@dataclass
class Attempt:
    profile: WeightProfile
    metrics: RouteMetrics
    penalty: float
    loop: Loop = field(repr=False)

    def to_dict(self) -> dict:
        return {
            "profile": self.profile.name,
            "weights": {k: round(getattr(self.profile, k), 3) for k in TUNABLE},
            "penalty": round(self.penalty, 4),
            **self.loop.summary(),
        }


@dataclass
class SearchResult:
    feasible: bool
    best: Attempt | None
    bands: BandSet
    solves: int
    elapsed_ms: float
    envelope: dict[str, tuple[float, float]]
    attempts: list[Attempt] = field(repr=False, default_factory=list)
    error: str | None = None

    def violations(self):
        if self.best is None:
            return []
        return self.bands.violations(self.best.metrics)

    def to_dict(self) -> dict:
        return {
            "feasible": self.feasible,
            "solves": self.solves,
            "elapsed_ms": round(self.elapsed_ms, 1),
            "bands": self.bands.describe(),
            "best": self.best.to_dict() if self.best else None,
            "violations": [
                {"metric": b.metric, "band": b.describe(),
                 "got": round(self.best.metrics.value(b.metric), 4),
                 "shortfall": round(b.shortfall(self.best.metrics.value(b.metric)), 4),
                 "notches": round(n, 2)}
                for b, n in self.violations()
            ],
            "envelope": {k: [round(lo, 4), round(hi, 4)]
                         for k, (lo, hi) in self.envelope.items()},
            "error": self.error,
        }


#: Metrics reported by `probe_envelope`, i.e. everything a band can be set on.
ENVELOPE_METRICS = ("distance_m", "climb_m", "traffic", "unpaved_frac", "scenic_frac")


def probe_envelope(
    graph: nx.MultiDiGraph,
    start: tuple[float, float],
    target_m: float,
    *,
    via: list[tuple[float, float]] | None = None,
    loop_iterations: int = 3,
) -> dict[str, tuple[float, float]]:
    """What this place can actually deliver at this distance, per metric.

    The archetype set only, with no bands and no descent. This is the number an
    Author-facing UI wants: band sliders should open on the range that exists here,
    not on an abstract 0–5, which is how a request becomes infeasible before anyone
    has asked for anything unreasonable.
    """
    seen: dict[str, list[float]] = {m: [] for m in ENVELOPE_METRICS}
    for profile in ARCHETYPES:
        try:
            loop = generate_loop(graph, start, target_m, profile, via=via,
                                 max_iterations=loop_iterations)
        except NoRouteFound:
            continue
        for metric in ENVELOPE_METRICS:
            seen[metric].append(loop.metrics.value(metric))
    return {m: (min(v), max(v)) for m, v in seen.items() if v}


def search_bands(
    graph: nx.MultiDiGraph,
    start: tuple[float, float],
    target_m: float,
    bands: BandSet,
    *,
    via: list[tuple[float, float]] | None = None,
    budget: int = 30,
    seed_profile: WeightProfile | None = None,
    loop_iterations: int = 3,
    keep_attempts: bool = False,
) -> SearchResult:
    """Look for a route satisfying every band. Returns the closest miss if none is."""
    t0 = time.perf_counter()
    attempts: list[Attempt] = []
    envelope: dict[str, tuple[float, float]] = {}
    solves = 0
    error: str | None = None

    def run(profile: WeightProfile) -> Attempt | None:
        nonlocal solves, error
        try:
            loop = generate_loop(graph, start, target_m, profile, via=via,
                                 max_iterations=loop_iterations)
        except NoRouteFound as exc:
            error = str(exc)
            return None
        solves += 1
        attempt = Attempt(profile, loop.metrics, bands.penalty(loop.metrics), loop)
        if keep_attempts:
            attempts.append(attempt)
        for band in bands:
            value = loop.metrics.value(band.metric)
            lo, hi = envelope.get(band.metric, (value, value))
            envelope[band.metric] = (min(lo, value), max(hi, value))
        return attempt

    # --- phase 1: probe the attainable envelope
    best: Attempt | None = None
    seeds = list(ARCHETYPES)
    if seed_profile is not None:
        seeds.insert(0, seed_profile)
    for profile in seeds:
        if solves >= budget:
            break
        attempt = run(profile)
        if attempt is None:
            continue
        if best is None or attempt.penalty < best.penalty:
            best = attempt
        if best.penalty == 0.0:
            break

    if best is None:
        return SearchResult(False, None, bands, solves,
                            (time.perf_counter() - t0) * 1000.0, envelope,
                            attempts, error or "no route from any archetype")

    # --- phase 2: coordinate descent from the best archetype
    for step in _STEPS:
        if best.penalty == 0.0:
            break
        improved = True
        while improved and solves < budget:
            improved = False
            for name, (low, high) in TUNABLE.items():
                if solves >= budget or best.penalty == 0.0:
                    break
                current = getattr(best.profile, name)
                for candidate in (current + step, current - step):
                    if not low <= candidate <= high or solves >= budget:
                        continue
                    base = best.profile.name.split("+", 1)[0]
                    trial = run(best.profile.replace(
                        name=f"{base}+tuned", **{name: candidate}))
                    if trial is not None and trial.penalty < best.penalty - 1e-9:
                        best, improved = trial, True
                        break

    return SearchResult(
        feasible=best.penalty == 0.0 and bands.satisfied_by(best.metrics),
        best=best, bands=bands, solves=solves,
        elapsed_ms=(time.perf_counter() - t0) * 1000.0,
        envelope=envelope, attempts=attempts, error=error,
    )
