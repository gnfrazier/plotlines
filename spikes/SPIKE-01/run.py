"""SPIKE-01 — Via-node loop routing (FR8a, Story A9).

Spike question: generate loops through 1, 2, and 3 forced via-nodes on a real graph;
measure solve time and route quality vs. an unconstrained themed loop.

Decides: whether A9 is promotable to MVP — specifically whether "via-node" and
"start/destination" are the same constraint primitive, which is the condition A9's own
priority note sets for promotion.

Five experiments:
  A  via-count sweep 0→3, two themes, three regions — cost and quality vs baseline
  B  re-ride ablation — penalty × relief radius, with overlap split corridor vs spur
  C  spur via — what the relief zone costs when it is switched off
  D  primitive identity — is one solver really serving all four route shapes?
  E  infeasible via — does A9's "hand it to A6" clause actually work?
"""

from __future__ import annotations

from plotlines_core.routing.diagnose import diagnose
from plotlines_core.routing.loops import (
    DEFAULT_RELIEF_FRAC, DEFAULT_REUSE_PENALTY, generate_loop, solve_circuit,
)
from plotlines_core.routing.solve import NoRouteFound
from plotlines_core.scoring.bands import Band, BandSet
from plotlines_core.scoring.metrics import edge_walk, measure
from plotlines_core.scoring.profile import THEMES

TARGET_M = 20_000.0
THEME_KEYS = ("balanced", "quiet_scenic")


def _via_sweep(bench) -> list[dict]:
    rows = []
    for key, loaded in bench.regions.items():
        for theme_key in THEME_KEYS:
            profile = THEMES[theme_key]
            baseline = None
            for count in (0, 1, 2, 3):
                via = bench.via_points(key, count)
                try:
                    loop = generate_loop(loaded.graph, loaded.region.centre,
                                         TARGET_M, profile, via=via)
                except NoRouteFound as exc:
                    rows.append({"region": key, "theme": theme_key, "via_count": count,
                                 "error": str(exc)})
                    continue
                row = {"region": key, "theme": theme_key, "via_count": count,
                       **loop.summary()}
                if count == 0:
                    baseline = loop
                elif baseline is not None:
                    # Quality vs the unconstrained themed loop: does forcing the route
                    # through a node make it cost more per metre in theme terms?
                    row["cost_vs_baseline"] = round(
                        loop.mean_cost_per_m / baseline.mean_cost_per_m, 4)
                    row["solve_ms_vs_baseline"] = round(
                        loop.solve_ms / baseline.solve_ms, 2) if baseline.solve_ms else None
                rows.append(row)
    return rows


def _reuse_ablation(bench) -> list[dict]:
    """The retracing question, over both knobs at once.

    A flat re-ride penalty has to answer two different questions with one number:
    "don't ride the corridor back" and "you may ride the café's dead-end lane back".
    It cannot. The sweep crosses the penalty with a relief radius around the Author's
    designated points, and reports overlap split by where it happened — corridor
    (`far`, the failure) versus anchor locality (`near`, the lollipop stick).
    """
    rows = []
    for key, loaded in bench.regions.items():
        for reuse in (1.0, 2.0, 4.0, 8.0, 12.0, 20.0):
            for frac in (0.0, 0.03, DEFAULT_RELIEF_FRAC, 0.08):
                for count in (0, 1, 2):
                    loop = generate_loop(
                        loaded.graph, loaded.region.centre, TARGET_M,
                        THEMES["balanced"], via=bench.via_points(key, count),
                        reuse_penalty=reuse, relief_frac=frac)
                    rows.append({"region": key, "reuse_penalty": reuse,
                                 "relief_frac": frac, "via_count": count,
                                 **loop.summary()})
    return rows


def _spur_via(bench) -> list[dict]:
    """The case the relief zone exists for: a via-node that can only be reached by
    riding a lane both ways. Relief off, the engine must either skip it (it cannot —
    vias are mandatory) or pay the full penalty and distort the loop to avoid it."""
    rows = []
    for key, loaded in bench.regions.items():
        for frac in (0.0, DEFAULT_RELIEF_FRAC):
            loop = generate_loop(loaded.graph, loaded.region.centre, TARGET_M,
                                 THEMES["balanced"], via=bench.via_points(key, 2),
                                 relief_frac=frac)
            rows.append({"region": key, "relief_frac": frac, **loop.summary()})
    return rows


def _primitive_identity(bench) -> list[dict]:
    """All four FR7/FR8a shapes, built from `solve_circuit` and nothing else.

    If each shape needs its own solver, A9 is a feature with its own cost and stays
    P1. If they are one call with a different anchor list, A9 is nearly free.
    """
    rows = []
    key = "boulder"
    loaded = bench.regions[key]
    graph, profile = loaded.graph, THEMES["balanced"]
    start = bench.snap(key, loaded.region.centre)
    away = [bench.snap(key, p) for p in bench.via_points(key, 3)]

    shapes = {
        "point_to_point": ([start, away[0]], False),
        "out_and_back":   ([start, away[0]], True),
        "loop":           ([start, away[0], away[1]], True),
        "loop_via_1":     ([start, away[2]], True),
        "loop_via_2":     ([start, away[0], away[2]], True),
    }
    for name, (anchors, close) in shapes.items():
        circuit = solve_circuit(graph, anchors, profile, close=close)
        walk = edge_walk(graph, circuit.path, profile)
        metrics = measure(graph, walk)
        rows.append({
            "shape": name, "anchors": len(anchors), "closed_flag": close,
            "solver": "solve_circuit", "solver_calls": circuit.calls,
            "distance_m": round(metrics.distance_m, 1),
            "overlap_frac": round(metrics.overlap_frac, 4),
            "returns_to_start": circuit.path[0] == circuit.path[-1],
        })
    return rows


def _infeasible_via(bench) -> dict:
    """A9: 'if a via-node makes the loop infeasible within the distance envelope,
    A6's conflict-explanation path governs.' Force that: a via 8 km out on a 10 km
    loop cannot be reached and returned from inside the envelope."""
    key = "boulder"
    loaded = bench.regions[key]
    via = bench.via_points(key, 1, radius_m=8_000.0)
    bands = BandSet.of(Band("distance_m", minimum=8_000.0, maximum=11_000.0))
    result = diagnose(loaded.graph, loaded.region.centre, 10_000.0, bands,
                      via=via, budget=12, filter_budget=6)
    return {"region": key, "target_m": 10_000.0, "via_radius_m": 8_000.0,
            **result.to_dict()}


def run(bench) -> dict:
    return {
        "spike": "SPIKE-01",
        "question": "Can a loop be constrained through mandatory via-nodes while "
                    "honouring weights and target distance, at acceptable cost?",
        "target_m": TARGET_M,
        "via_sweep": _via_sweep(bench),
        "reuse_ablation": _reuse_ablation(bench),
        "spur_via": _spur_via(bench),
        "primitive_identity": _primitive_identity(bench),
        "infeasible_via": _infeasible_via(bench),
    }
