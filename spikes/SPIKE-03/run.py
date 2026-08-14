"""SPIKE-03 — Min/max weight-band convergence (FR6, Story A5).

Spike question: run realistic competing bands (e.g. high climbing-min + low
traffic-max) across varied geographies; measure how often a valid route exists and
whether it's good.

Done when: band behaviour is characterised well enough to set sensible default ranges
and know how often A6's conflict path will fire.

So the run produces exactly those two things:

  A  **envelope** — what each region can actually deliver at this distance. This is
     what default band ranges should be derived from; a slider that opens on a range
     the terrain cannot reach manufactures infeasibility out of nothing.
  B  **grid** — a climbing-min × traffic-max sweep per region, which is the
     "how often does A6 fire" number, measured rather than guessed.
  C  **width** — how narrow a two-sided band can get before it stops converging.
  D  **quality** — when a route is found, is it any good, or merely inside the bands?
"""

from __future__ import annotations

from plotlines_core.routing.search import ENVELOPE_METRICS, probe_envelope, search_bands
from plotlines_core.scoring.bands import Band, BandSet

TARGET_M = 20_000.0

CLIMB_MINS = (100.0, 200.0, 300.0, 400.0)
TRAFFIC_MAXES = (0.15, 0.25, 0.35)
#: Two-sided climbing bands of shrinking width, centred on each region's midpoint.
WIDTH_FRACTIONS = (0.40, 0.20, 0.10, 0.05)


def _envelopes(bench) -> dict:
    out = {}
    for key, loaded in bench.regions.items():
        envelope = probe_envelope(loaded.graph, loaded.region.centre, TARGET_M)
        out[key] = {m: [round(lo, 3), round(hi, 3)]
                    for m, (lo, hi) in envelope.items()}
        out[key]["_spread"] = {
            m: round(hi - lo, 3) for m, (lo, hi) in envelope.items()
        }
    return out


def _grid(bench) -> list[dict]:
    rows = []
    for key, loaded in bench.regions.items():
        for climb_min in CLIMB_MINS:
            for traffic_max in TRAFFIC_MAXES:
                bands = BandSet.of(Band("climb_m", minimum=climb_min),
                                   Band("traffic", maximum=traffic_max))
                result = search_bands(loaded.graph, loaded.region.centre, TARGET_M,
                                      bands, budget=30)
                best = result.best
                rows.append({
                    "region": key,
                    "climb_min_m": climb_min,
                    "traffic_max": traffic_max,
                    "feasible": result.feasible,
                    "solves": result.solves,
                    "elapsed_ms": round(result.elapsed_ms, 1),
                    "climb_m": round(best.metrics.climb_m, 1) if best else None,
                    "traffic": round(best.metrics.traffic, 4) if best else None,
                    "distance_m": round(best.metrics.distance_m, 1) if best else None,
                    "overlap_frac": round(best.metrics.overlap_frac, 4) if best else None,
                    "winning_profile": best.profile.name if best else None,
                    "worst_violation": (
                        result.violations()[0][0].metric if result.violations() else None),
                })
    return rows


def _widths(bench) -> list[dict]:
    """Two-sided bands. A min/max pair is strictly harder than either bound alone."""
    rows = []
    for key, loaded in bench.regions.items():
        envelope = probe_envelope(loaded.graph, loaded.region.centre, TARGET_M)
        lo, hi = envelope["climb_m"]
        centre = (lo + hi) / 2.0
        for frac in WIDTH_FRACTIONS:
            half = centre * frac
            bands = BandSet.of(Band("climb_m", minimum=centre - half,
                                    maximum=centre + half))
            result = search_bands(loaded.graph, loaded.region.centre, TARGET_M,
                                  bands, budget=30)
            rows.append({
                "region": key,
                "band_half_width_frac": frac,
                "band": bands.describe(),
                "centred_on_m": round(centre, 1),
                "feasible": result.feasible,
                "solves": result.solves,
                "elapsed_ms": round(result.elapsed_ms, 1),
                "climb_m": round(result.best.metrics.climb_m, 1) if result.best else None,
            })
    return rows


def _quality(bench) -> list[dict]:
    """A route inside the bands can still be a bad route. Check the other axes."""
    rows = []
    for key, loaded in bench.regions.items():
        envelope = probe_envelope(loaded.graph, loaded.region.centre, TARGET_M)
        c_lo, c_hi = envelope["climb_m"]
        t_lo, t_hi = envelope["traffic"]
        # A request sitting well inside what this region can do.
        bands = BandSet.of(
            Band("climb_m", minimum=c_lo + 0.5 * (c_hi - c_lo)),
            Band("traffic", maximum=t_hi - 0.4 * (t_hi - t_lo)),
        )
        result = search_bands(loaded.graph, loaded.region.centre, TARGET_M, bands,
                              budget=30)
        best = result.best
        rows.append({
            "region": key,
            "bands": bands.describe(),
            "feasible": result.feasible,
            "solves": result.solves,
            "distance_error": (round(best.loop.distance_error, 4)
                               if best and best.loop.distance_error is not None else None),
            "overlap_frac": round(best.metrics.overlap_frac, 4) if best else None,
            "max_grade": round(best.metrics.max_grade, 4) if best else None,
            "closed": best.loop.closed if best else None,
            "metrics": best.metrics.to_dict() if best else None,
        })
    return rows


def run(bench) -> dict:
    grid = _grid(bench)
    by_region = {}
    for key in bench.regions:
        rows = [r for r in grid if r["region"] == key]
        by_region[key] = {
            "cells": len(rows),
            "feasible": sum(r["feasible"] for r in rows),
            "feasible_pct": round(100.0 * sum(r["feasible"] for r in rows) / len(rows), 1),
            "median_solves": sorted(r["solves"] for r in rows)[len(rows) // 2],
            "max_elapsed_ms": max(r["elapsed_ms"] for r in rows),
        }
    return {
        "spike": "SPIKE-03",
        "question": "Does compromise-finding across bounded (min/max) weights "
                    "converge to a good route, or do bands over-constrain?",
        "target_m": TARGET_M,
        "metrics_banded": list(ENVELOPE_METRICS),
        "envelopes": _envelopes(bench),
        "grid": grid,
        "grid_summary": by_region,
        "band_widths": _widths(bench),
        "quality": _quality(bench),
        "overall": {
            "cells": len(grid),
            "feasible": sum(r["feasible"] for r in grid),
            "feasible_pct": round(100.0 * sum(r["feasible"] for r in grid) / len(grid), 1),
        },
    }
