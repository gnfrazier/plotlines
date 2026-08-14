"""SPIKE-02 — Conflict detection & relaxation (FR9, Story A6).

Spike question: construct several deliberately-infeasible weight/constraint
combinations; determine whether the engine can identify the binding constraints and
compute a minimal relaxation.

The bar A6 sets is higher than "detect infeasibility", so this spike checks three
things, not one:

  1. **Names the right constraints.** Each scenario declares what it expects
     (`unattainable` vs `combination`, and which metrics), and the run records
     whether the diagnosis matched. A conflict report that blames the wrong setting
     is worse than none.
  2. **Does not cry wolf.** Feasible controls are included. An engine that reports a
     conflict for a satisfiable request fails A6 just as badly.
  3. **The relaxation actually works.** Every proposed relaxation is applied and
     re-solved. "Offer a relaxation" is only meaningful if taking the offer produces
     a route — an untested suggestion is the silent compromise A6 forbids.
"""

from __future__ import annotations

from plotlines_core.routing.diagnose import diagnose
from plotlines_core.routing.search import search_bands
from plotlines_core.scoring.bands import Band, BandSet

TARGET_M = 20_000.0

#: (id, region, bands, expected kind, expected metrics named, why it is here)
SCENARIOS = [
    ("flat_town_wants_mountains", "davis",
     BandSet.of(Band("climb_m", minimum=300.0)),
     "unattainable", {"climb_m"},
     "One band, no competition: the terrain simply has no climbing to give."),

    ("nowhere_climbs_this_much", "boulder",
     BandSet.of(Band("climb_m", minimum=1500.0), Band("traffic", maximum=0.40)),
     "unattainable", {"climb_m"},
     "An impossible number beside a slack one — the slack band must not be blamed."),

    ("climb_without_traffic", "boulder",
     BandSet.of(Band("climb_m", minimum=280.0), Band("traffic", maximum=0.14)),
     "combination", {"climb_m", "traffic"},
     "The classic FR9 case: both reachable alone, the climbing is up the busy road."),

    # Predicted "combination"; the engine routed it. The prediction was wrong, not the
    # engine — on this graph scenic and quiet *correlate* (the scenic ways are bike
    # paths, and bike paths carry no cars), so the two bands reinforce rather than
    # compete. Kept as a control precisely because it caught a wrong intuition.
    ("scenic_and_silent", "boulder",
     BandSet.of(Band("scenic_frac", minimum=0.55), Band("traffic", maximum=0.12)),
     "none", set(),
     "Predicted to conflict; does not. Scenic and quiet correlate here."),

    ("gravel_minimum", "viroqua",
     BandSet.of(Band("unpaved_frac", minimum=0.30)),
     "unattainable", {"unpaved_frac"},
     "Probes FR4's weight shape, not the terrain — see the surface finding."),

    ("three_way", "boulder",
     BandSet.of(Band("climb_m", minimum=260.0), Band("traffic", maximum=0.15),
                Band("scenic_frac", minimum=0.45)),
     # Expect TWO named, not three: the deletion filter should discover that the
     # scenic band is not part of the conflict and drop it. Naming all three would be
     # the failure mode — it sends the Author to loosen a constraint that binds nothing.
     "combination", {"climb_m", "traffic"},
     "Three bands: does the deletion filter narrow to the ones that actually bind?"),

    # --- controls: these must come back feasible, with no conflict named
    ("control_easy", "boulder",
     BandSet.of(Band("climb_m", minimum=100.0), Band("traffic", maximum=0.45)),
     "none", set(),
     "False-positive check: comfortably satisfiable."),

    ("control_snug", "viroqua",
     BandSet.of(Band("climb_m", minimum=200.0), Band("traffic", maximum=0.45)),
     "none", set(),
     "False-positive check with less slack."),
]


def _replace(bands: BandSet, old: Band, new: Band) -> BandSet:
    return BandSet(tuple(new if b is old else b for b in bands))


def _verify_relaxations(loaded, bands: BandSet, diagnosis) -> list[dict]:
    """Apply each offered relaxation on its own and re-solve. Does it deliver?"""
    checks = []
    for relaxation in diagnosis.relaxations:
        relaxed = _replace(bands, relaxation.band, relaxation.proposed)
        result = search_bands(loaded.graph, loaded.region.centre, TARGET_M,
                              relaxed, budget=24)
        checks.append({
            "metric": relaxation.band.metric,
            "from": relaxation.band.describe(),
            "to": relaxation.proposed.describe(),
            "trade_off": relaxation.trade_off,
            "applying_it_routes": result.feasible,
            "solves": result.solves,
        })
    return checks


def run(bench) -> dict:
    rows = []
    for name, region_key, bands, expect_kind, expect_metrics, why in SCENARIOS:
        loaded = bench.regions[region_key]
        diagnosis = diagnose(loaded.graph, loaded.region.centre, TARGET_M, bands,
                             budget=30, filter_budget=16)
        named = {b.metric for b in diagnosis.conflict}
        checks = _verify_relaxations(loaded, bands, diagnosis)
        rows.append({
            "scenario": name,
            "region": region_key,
            "why": why,
            "bands": bands.describe(),
            "expected_kind": expect_kind,
            "kind": diagnosis.kind,
            "kind_correct": diagnosis.kind == expect_kind,
            "expected_metrics": sorted(expect_metrics),
            "named_metrics": sorted(named),
            "naming_correct": named == expect_metrics,
            "feasible": diagnosis.feasible,
            "explanation": diagnosis.explanation,
            "relaxations": [r.to_dict() for r in diagnosis.relaxations],
            "relaxation_checks": checks,
            "relaxations_all_work": bool(checks) and all(
                c["applying_it_routes"] for c in checks),
            "solves": diagnosis.solves,
            "elapsed_ms": round(diagnosis.elapsed_ms, 1),
            "envelope": {k: [round(lo, 3), round(hi, 3)]
                         for k, (lo, hi) in diagnosis.envelope.items()},
        })

    conflicts = [r for r in rows if r["expected_kind"] != "none"]
    controls = [r for r in rows if r["expected_kind"] == "none"]
    return {
        "spike": "SPIKE-02",
        "question": "Can the solver name which constraints conflict and propose the "
                    "nearest relaxation, rather than returning an empty result?",
        "target_m": TARGET_M,
        "scenarios": rows,
        "totals": {
            "scenarios": len(rows),
            "kind_correct": sum(r["kind_correct"] for r in rows),
            "naming_correct": sum(r["naming_correct"] for r in rows),
            "false_positives": sum(not r["feasible"] for r in controls),
            "conflicts_with_working_relaxation": sum(
                r["relaxations_all_work"] for r in conflicts),
            "conflict_scenarios": len(conflicts),
            "median_solves": sorted(r["solves"] for r in rows)[len(rows) // 2],
            "max_elapsed_ms": max(r["elapsed_ms"] for r in rows),
        },
    }
