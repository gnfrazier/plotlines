"""SPIKE-B step 3 — tune the ranking function and set the reviewable cap.

Issue points 2 and 3, ARCH Q12 / FR105a / N4a:

  * the salience x tightness trade-off (already in `colocate._noisy_or` +
    the tightness multiplier — this script shows what it produces);
  * whether **corridor proximity should dominate** the ranking once a route
    exists, or merely influence it — compared here as four treatments;
  * the **reviewable cap** — what number, justified against PRD §5.4a's
    worked review pass and the measured proposal-count-vs-scale curve.

Run against PRD §5.4a's own scenario: the Grandfather Mountain / Linville
sub-box of `brp`, the four layers §5.4a implies (historic, natural, sight,
amenity), and the digitised Parkway as the route.

    python spikes/SPIKE-B/ranking.py
    python spikes/SPIKE-B/ranking.py --json    # results/ranking.json
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import replace
from pathlib import Path

import common
from regions import BRP, SWEEP, WORKED_PASS
from route import BRP_ROUTE

from plotlines_core.curation.colocate import (
    analyze_colocation_full, by_corridor_proximity, ClusterProposal,
    ColocationParams, DEFAULTS, reviewable_cap, _polyline_len_km,
)
from plotlines_core.curation.providers import BBox

RESULTS = Path(__file__).parent / "results"
WORKED_LAYERS = ("amenity", "historic", "natural", "sight")
UNCAPPED = replace(DEFAULTS, cap_floor=1_000_000)

# §5.4a's two bulk-review actions (N4a).
BULK_REJECT_BELOW_SALIENCE = 0.55   # "bulk-rejects below a salience threshold"
OFF_ROUTE_M = 1200.0                 # "provision clusters along a road they aren't using"


def _bbox(box) -> BBox:
    return BBox(box.west, box.south, box.east, box.north)


def _dominant_sort(props: list[ClusterProposal]) -> list[ClusterProposal]:
    """Corridor proximity as the *primary* key: bucket distance-to-route into
    250 m / 1 km / 3 km / beyond bands, then salience x tightness within a
    band. This is the 'proximity dominates' treatment Q12 asks about."""
    def band(d: float | None) -> int:
        if d is None:
            return 0
        return 0 if d <= 250 else 1 if d <= 1000 else 2 if d <= 3000 else 3
    return sorted(
        props,
        key=lambda p: (band(p.distance_to_route_m),
                       -(p.salience_score * (0.6 + 0.4 * p.tightness))),
    )


def _treatments(cands, bb) -> dict[str, list[ClusterProposal]]:
    """Four ways to treat corridor proximity, all over the same proposals:
      default        — salience x tightness, route ignored in the sort (N4a)
      corridor resort— by_corridor_proximity: the opt-in resorted view
      corridor d=800 — the same resort with an aggressive decay (rejected)
      dominant bands — proximity as the PRIMARY key (the 'dominates' option)
    """
    withroute, _ = analyze_colocation_full(cands, bb, UNCAPPED, route=BRP_ROUTE)
    return {
        "default (salience x tightness)": withroute,
        "corridor resort d=2500": by_corridor_proximity(withroute, DEFAULTS),
        "corridor resort d=800": by_corridor_proximity(
            withroute, replace(DEFAULTS, corridor_decay_m=800.0)),
        "dominant (distance bands)": _dominant_sort(withroute),
    }


def _fmt(p: ClusterProposal) -> str:
    d = "" if p.distance_to_route_m is None else f" @{p.distance_to_route_m/1000:.1f}km"
    return (f"{p.rank_score:.3f} {p.kind:20} n={len(p.members):2} "
            f"s={p.salience_score:.2f} t={p.tightness:.2f}{d}  {p.name[:34]}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    feats = common.load_raw_features()
    cands = common.candidates_for(feats, WORKED_LAYERS)
    bb = _bbox(WORKED_PASS)
    ew, ns = WORKED_PASS.span_km
    route_km = _polyline_len_km(BRP_ROUTE)

    treatments = _treatments(cands, bb)
    base = treatments["default (salience x tightness)"]
    withroute = base

    # --- §5.4a worked pass, re-run post-SPIKE-A ---------------------------- #
    # §5.4a (written before SPIKE-A) had 43 proposals, 19 of them single-tree
    # / small-park noise. SPIKE-A's Stage-1 gates removed that class, so the
    # bulk-salience-reject action now bites on "real but minor" clusters, not
    # tree noise. Reject on the *best member's* salience (§5.4a's intent:
    # "these features aren't notable"), not the noisy-OR aggregate.
    n_total = len(base)

    def smax(p) -> float:
        return max(m.salience for m in p.members)

    bulk_rejected = [p for p in withroute if smax(p) < BULK_REJECT_BELOW_SALIENCE]
    off_route = [p for p in withroute
                 if p not in bulk_rejected
                 and (p.distance_to_route_m or 0) > OFF_ROUTE_M]
    remaining = [p for p in withroute
                 if p not in bulk_rejected and p not in off_route]

    worked = {
        "bbox_km": [round(ew), round(ns)],
        "proposals_total": n_total,
        "prd_5_4a_reference": {"proposals": 43, "tree_park_noise": 19,
                               "off_route_provision": 6, "remaining": 18},
        "bulk_reject_below_member_salience": {
            "threshold": BULK_REJECT_BELOW_SALIENCE, "removed": len(bulk_rejected)},
        "off_route_filter": {"over_m": OFF_ROUTE_M, "removed": len(off_route)},
        "remaining_to_judge": len(remaining),
        "default_top_10": [_fmt(p) for p in base[:10]],
        "top_after_filters": [_fmt(p) for p in remaining[:8]],
    }

    # --- corridor treatment comparison ------------------------------------- #
    # a genuinely major sight several km off the drawn route — should stay near
    # the top under a sane treatment, sink under 'dominant'.
    def find(name_frag, lst):
        for i, p in enumerate(lst):
            if name_frag.lower() in p.name.lower():
                return i + 1, p
        return None, None

    # "Does the ranking put the right ones near the top?" (issue point 3).
    # Ground truth = recognizable Blue Ridge destinations a real Author
    # promotes on this tour. Track each one's rank under every treatment.
    GROUND_TRUTH = ["Wiseman's View", "Linville Caverns", "Plunge Basin",
                    "Beacon Heights", "Wilson Center", "Erwin's View",
                    "Grandmother", "Rough Ridge"]

    comparison: dict = {"treatments": {}, "ground_truth_ranks": {}}
    for label, lst in treatments.items():
        comparison["treatments"][label] = {"top10": [_fmt(p) for p in lst[:10]]}
    for name in GROUND_TRUTH:
        ranks = {}
        for label, lst in treatments.items():
            r, _ = find(name, lst)
            ranks[label] = r
        comparison["ground_truth_ranks"][name] = ranks

    # --- cap justification ------------------------------------------------- #
    # proposal count vs scale, from the area sweep crops
    allc = common.candidates_for(feats)
    scale_rows = []
    for box in SWEEP:
        c = common.crop_candidates(allc, box)
        full, _ = analyze_colocation_full(c, _bbox(box), UNCAPPED)
        scale_rows.append({"area_km2": round(box.area_km2),
                           "candidates": len(c), "proposals": len(full)})
    cap = {
        "formula": "cap_floor + round(cap_per_route_km * route_km)",
        "cap_floor": DEFAULTS.cap_floor,
        "cap_per_route_km": DEFAULTS.cap_per_route_km,
        "no_route": reviewable_cap(DEFAULTS),
        "worked_pass_route_cap": reviewable_cap(DEFAULTS, BRP_ROUTE),
        "route_km": round(route_km, 1),
        "proposals_vs_scale": scale_rows,
        "note": (
            "Proposals grow ~linearly with area (~1 per 18 km2), so a pure "
            "area cap would 10x on a 200 km bbox. Tie the cap to route length "
            "where a route exists: a longer tour has more worth reviewing, "
            "but it grows with corridor km (~1D) not bbox area (~2D). 30 "
            "floor covers §5.4a's ~40; 0.5/route-km puts a 250 km tour at "
            "~155, the rest shown as '+N beyond', never truncated (N4a)."
        ),
    }

    report = {"scenario": "PRD §5.4a — Grandfather Mtn / Linville, 4 layers, BRP route",
              "worked_pass": worked, "corridor_comparison": comparison, "cap": cap}

    if args.json:
        RESULTS.mkdir(exist_ok=True)
        (RESULTS / "ranking.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
        return 0

    _print(report)
    return 0


def _print(r: dict) -> None:
    w = r["worked_pass"]
    ref = w["prd_5_4a_reference"]
    print(f"\n=== {r['scenario']} ===")
    print(f"box {w['bbox_km'][0]}x{w['bbox_km'][1]} km   "
          f"{w['proposals_total']} proposals  (PRD §5.4a illustrative: {ref['proposals']})\n")
    print("  default sort (salience x tightness) — the reviewable head:")
    for row in w["default_top_10"]:
        print(f"    {row}")
    br = w["bulk_reject_below_member_salience"]
    orf = w["off_route_filter"]
    print(f"\n  N4a bulk filters:")
    print(f"    reject best-member salience < {br['threshold']}   -> -{br['removed']}"
          f"   (§5.4a removed {ref['tree_park_noise']} tree/park; SPIKE-A already gates those)")
    print(f"    filter distance-from-route  > {orf['over_m']/1000:.1f} km  -> -{orf['removed']}"
          f"   (§5.4a removed {ref['off_route_provision']})")
    print(f"    remaining to judge individually: {w['remaining_to_judge']}"
          f"   (§5.4a: {ref['remaining']})")

    c = r["corridor_comparison"]
    print("\n  CORRIDOR TREATMENT (Q12) — top 10 each:")
    for label, e in c["treatments"].items():
        print(f"\n   -- {label}")
        for row in e["top10"]:
            print(f"      {row}")
    print("\n  ground-truth destination ranks under each treatment:")
    hdr = list(next(iter(c["ground_truth_ranks"].values())).keys())
    print(f"    {'destination':<18} " + " ".join(f"{h[:16]:>16}" for h in hdr))
    for name, ranks in c["ground_truth_ranks"].items():
        print(f"    {name:<18} " + " ".join(f"{str(ranks[h]):>16}" for h in hdr))

    cap = r["cap"]
    print("\n  CAP")
    print("    proposals vs scale (uncapped):")
    for row in cap["proposals_vs_scale"]:
        print(f"      {row['area_km2']:>6,} km2   {row['candidates']:>5,} cand   "
              f"{row['proposals']:>4} proposals")
    print(f"    formula: {cap['formula']}")
    print(f"    no route -> {cap['no_route']}    "
          f"BRP {cap['route_km']} km -> {cap['worked_pass_route_cap']}")
    print(f"    {cap['note']}")


if __name__ == "__main__":
    raise SystemExit(main())
