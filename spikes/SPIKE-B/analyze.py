"""SPIKE-B step 2 — runtime and memory of co-location analysis at bbox scale.

Issue point 1: "Measure runtime and memory at bbox scale, and how both move
with layer count and bbox area. Establish whether the cacheable-endpoint
mitigation is sufficient or whether the analysis needs bounding." (ARCH A21.)

Three sweeps, all over the real `brp` extract (Asheville-Boone, ~8,800 km2):

  area   — concentric crops of `brp` at 100/50/25/12/6/3 % of area, so the
           candidate count and cluster cost are read against extent directly.
  layers — the full box with 2, 3, 4, and all 6 OSM families live.
  dense  — the full box with candidates synthetically multiplied (jittered
           copies) to 2x .. 20x, to reach the candidate counts a genuinely
           200 km multi-day bbox in dense country would carry, which `brp`
           itself (rural mountains) does not.

`analyze_colocation` is the product's own function; nothing here reimplements
clustering.

    python spikes/SPIKE-B/analyze.py            # table
    python spikes/SPIKE-B/analyze.py --json     # results/cost.json
"""

from __future__ import annotations

import argparse
import json
import random
from dataclasses import replace
from pathlib import Path

import common
from common import Meter
from regions import BRP, SWEEP
from route import BRP_ROUTE

from plotlines_core.curation.colocate import (
    analyze_colocation_full, DEFAULTS, reviewable_cap,
)
from plotlines_core.curation.notability import Candidate
from plotlines_core.curation.providers import BBox

RESULTS = Path(__file__).parent / "results"
_LAYER_SETS = {
    "2 (historic+natural)": ("historic", "natural"),
    "3 (+sight)": ("historic", "natural", "sight"),
    "4 (+amenity)": ("amenity", "historic", "natural", "sight"),
    "6 (all)": common.ALL_LAYERS,
}


def _bbox(box) -> BBox:
    return BBox(box.west, box.south, box.east, box.north)


def _time(cands, bbox, **kw) -> dict:
    # median of 5 runs — clustering is deterministic, this just damps scheduler noise
    best = None
    for _ in range(3):
        with Meter() as m:
            props, beyond = analyze_colocation_full(cands, bbox, **kw)
        if best is None or m.seconds < best[0]:
            best = (m.seconds, m.peak_mb, len(props), beyond)
    return {"seconds": round(best[0], 4), "peak_mb": round(best[1], 2),
            "shown": best[2], "beyond_cap": best[3]}


def _densify(cands: list[Candidate], factor: int, jitter_m: float = 400.0) -> list[Candidate]:
    """`factor` jittered copies of every candidate — a synthetic dense region.
    Jitter is ~degrees for `jitter_m` so copies co-locate realistically rather
    than all landing on the original."""
    rng = random.Random(1234)
    dlat = jitter_m / 111_320.0
    out: list[Candidate] = []
    for c in cands:
        dlon = jitter_m / (111_320.0 * max(0.2, abs(__import__("math").cos(__import__("math").radians(c.coord[1])))))
        for k in range(factor):
            if k == 0:
                out.append(c)
                continue
            out.append(replace(
                c, id=f"{c.id}#{k}",
                coord=(c.coord[0] + rng.uniform(-dlon, dlon),
                       c.coord[1] + rng.uniform(-dlat, dlat)),
            ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    feats = common.load_raw_features()
    all_cands = common.candidates_for(feats)
    full_bbox = _bbox(BRP)

    report: dict = {"region": BRP.name, "area_km2": round(BRP.area_km2),
                    "raw_features": len(feats), "candidates_all_layers": len(all_cands),
                    "params": {"max_diameter_m": DEFAULTS.max_diameter_m,
                               "cap_floor": DEFAULTS.cap_floor,
                               "cap_per_route_km": DEFAULTS.cap_per_route_km},
                    "area_sweep": [], "layer_sweep": [], "dense_sweep": []}

    # --- area sweep -------------------------------------------------------- #
    for box in SWEEP:
        bb = _bbox(box)
        cands = common.crop_candidates(all_cands, box)
        row = {"frac": round(box.area_km2 / BRP.area_km2, 3),
               "area_km2": round(box.area_km2),
               "candidates": len(cands), **_time(cands, bb)}
        report["area_sweep"].append(row)

    # --- layer sweep ---------------------------------------------------------- #
    for label, layers in _LAYER_SETS.items():
        cands = common.candidates_for(feats, layers)
        row = {"layers": label, "candidates": len(cands),
               **_time(cands, full_bbox)}
        report["layer_sweep"].append(row)

    # --- dense sweep (synthetic) ------------------------------------------- #
    for factor in (1, 2, 5, 10):
        cands = _densify(all_cands, factor)
        row = {"factor": factor, "candidates": len(cands),
               **_time(cands, full_bbox)}
        report["dense_sweep"].append(row)

    # --- cap illustration ------------------------------------------------- #
    report["cap"] = {
        "no_route": reviewable_cap(DEFAULTS, None),
        "brp_route_len_km": round(_route_km(BRP_ROUTE), 1),
        "brp_route_cap": reviewable_cap(DEFAULTS, BRP_ROUTE),
    }

    if args.json:
        RESULTS.mkdir(exist_ok=True)
        (RESULTS / "cost.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
        return 0

    _print(report)
    return 0


def _route_km(route) -> float:
    from plotlines_core.curation.colocate import _polyline_len_km
    return _polyline_len_km(route)


def _print(r: dict) -> None:
    print(f"\n{r['region']}  —  {r['area_km2']:,} km2, {r['raw_features']:,} raw "
          f"features, {r['candidates_all_layers']:,} candidates (6 layers)")
    print(f"params: max_diameter_m={r['params']['max_diameter_m']}, "
          f"cap={r['params']['cap_floor']} + {r['params']['cap_per_route_km']}/route-km\n")

    print("AREA SWEEP (concentric crops of the real extract)")
    print(f"  {'area km2':>9}  {'frac':>5}  {'cands':>6}  {'ms':>7}  {'peak MB':>8}  {'clusters(shown+beyond)':>22}")
    for x in r["area_sweep"]:
        print(f"  {x['area_km2']:>9,}  {x['frac']:>5.2f}  {x['candidates']:>6,}  "
              f"{x['seconds']*1000:>7.1f}  {x['peak_mb']:>8.2f}  {x['shown']:>6}+{x['beyond_cap']}")

    print("\nLAYER SWEEP (full box, live layer set shrinking)")
    print(f"  {'layers':>22}  {'cands':>6}  {'ms':>7}  {'peak MB':>8}")
    for x in r["layer_sweep"]:
        print(f"  {x['layers']:>22}  {x['candidates']:>6,}  {x['seconds']*1000:>7.1f}  {x['peak_mb']:>8.2f}")

    print("\nDENSE SWEEP (candidates synthetically multiplied — a 200 km dense-country proxy)")
    print(f"  {'factor':>6}  {'cands':>7}  {'ms':>8}  {'peak MB':>8}")
    for x in r["dense_sweep"]:
        print(f"  {x['factor']:>5}x  {x['candidates']:>7,}  {x['seconds']*1000:>8.1f}  {x['peak_mb']:>8.2f}")

    print(f"\nCAP:  no route -> {r['cap']['no_route']}   "
          f"BRP route ({r['cap']['brp_route_len_km']} km) -> {r['cap']['brp_route_cap']}")


if __name__ == "__main__":
    raise SystemExit(main())
