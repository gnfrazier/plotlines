"""SPIKE-B step 5 — rejection memory survives a re-run with a new layer.

Issue point 5 (FR110, N4a, ARCH §4.4): "confirm re-running after adding a
layer preserves every prior rejection and marks what is new. This is stateful
behaviour the ranking has to survive."

Scenario, following PRD §5.4a:
  1. run the analysis over the worked-pass box with a route;
  2. the Author bulk-rejects a filter set — every provision cluster more than
     1.2 km off the route (§5.4a's "six provision clusters along a road they
     aren't using"). Their member-id sets become the trip's rejection set
     (ARCH §4.4: "a small rejection set, not the cluster itself");
  3. re-run with a plugin battlefield/manor-house layer added, passing the
     rejection set back in;
  4. assert: no rejected cluster reappears — including ones a plugin feature
     joined (membership changed, but the Author already said no to that
     spot) — and `diff_runs` flags exactly the genuinely-new proposals.

    python spikes/SPIKE-B/rejection.py
"""

from __future__ import annotations

import argparse
import json
from dataclasses import replace
from pathlib import Path

import common
from plugin import _plugin_candidates_near
from regions import WORKED_PASS
from route import BRP_ROUTE

from plotlines_core.curation.colocate import (
    analyze_colocation_full, diff_runs, DEFAULTS,
)
from plotlines_core.curation.providers import BBox

RESULTS = Path(__file__).parent / "results"
OFF_ROUTE_M = 1200.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    feats = common.load_raw_features()
    cands = common.candidates_for(feats, ("amenity", "historic", "natural", "sight"))
    bb = BBox(WORKED_PASS.west, WORKED_PASS.south, WORKED_PASS.east, WORKED_PASS.north)
    big = replace(DEFAULTS, cap_floor=1_000_000)

    # 1. first run ------------------------------------------------------------- #
    run1, _ = analyze_colocation_full(cands, bb, big, route=BRP_ROUTE)

    # 2. bulk-reject: provision clusters > 1.2 km off route ------------------- #
    rejected_props = [p for p in run1
                      if p.kind.startswith("provision")
                      and (p.distance_to_route_m or 0) > OFF_ROUTE_M]
    rejection_set = [p.member_key for p in rejected_props]
    rejected_ids = {p.id for p in rejected_props}

    # 3. re-run with a plugin layer + the rejection set --------------------- #
    in_box = common.crop_candidates(cands, WORKED_PASS)
    # aim some plugin features at members of rejected clusters, to test that a
    # rejected spot stays rejected even when its membership changes.
    rej_member_anchors = []
    rej_ids_flat = {mid for k in rejection_set for mid in k}
    for c in in_box:
        if c.id in rej_ids_flat:
            rej_member_anchors.append(c)
    anchors = (rej_member_anchors[:4]
               + [c for c in in_box if c.role_affinity == "narrative"][::11][:4])
    plugin = _plugin_candidates_near(anchors)

    run2_no_memory, _ = analyze_colocation_full(
        cands + plugin, bb, big, route=BRP_ROUTE)
    run2, _ = analyze_colocation_full(
        cands + plugin, bb, big, route=BRP_ROUTE, rejected=rejection_set)

    # 4. checks ----------------------------------------------------------------- #
    reappeared = [p for p in run2 if p.id in rejected_ids]
    # a rejected spot whose membership changed because a plugin feature joined
    changed_but_suppressed = []
    run2_ids = {p.id for p in run2}
    for p in run2_no_memory:
        if p.id in rejected_ids:
            continue
        for k in rejection_set:
            inter = len(p.member_key & k)
            if inter and inter >= 0.6 * len(p.member_key | k) and p.id not in run2_ids:
                changed_but_suppressed.append((p.name, sorted(p.member_key)))
                break

    marked = diff_runs(run1, run2)
    new_ones = [p for p in marked if p.is_new]
    carried = [p for p in marked if not p.is_new]
    plugin_in_new = sum(
        1 for p in new_ones
        if any(m.candidate_id.startswith("plugin/") for m in p.members))

    report = {
        "run1_proposals": len(run1),
        "bulk_rejected": len(rejected_props),
        "run2_proposals_no_memory": len(run2_no_memory),
        "run2_proposals_with_memory": len(run2),
        "rejected_reappeared": len(reappeared),
        "rejected_spots_suppressed_despite_membership_change": len(changed_but_suppressed),
        "changed_but_suppressed_sample": changed_but_suppressed[:5],
        "marked_new": len(new_ones),
        "marked_carried_over": len(carried),
        "plugin_features_among_new": plugin_in_new,
        "new_sample": [f"{p.name}  {p.kind}  new={p.is_new}" for p in new_ones[:8]],
    }

    ok = (len(reappeared) == 0
          and len(run2) == len(run2_no_memory) - len(rejected_props)
          and plugin_in_new > 0)
    report["PASS"] = ok

    if args.json:
        RESULTS.mkdir(exist_ok=True)
        (RESULTS / "rejection.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
        return 0 if ok else 1

    print("\n=== rejection memory across a re-run with a new layer ===")
    print(f"  run 1:                       {report['run1_proposals']} proposals")
    print(f"  bulk-rejected (provision >1.2km off route): {report['bulk_rejected']}")
    print(f"  run 2 (plugin added, no memory):   {report['run2_proposals_no_memory']}")
    print(f"  run 2 (plugin added, w/ memory):   {report['run2_proposals_with_memory']}")
    print(f"  rejected clusters that reappeared: {report['rejected_reappeared']}   (want 0)")
    print(f"  rejected spots kept out despite a plugin feature joining them: "
          f"{report['rejected_spots_suppressed_despite_membership_change']}")
    for name, ids in report["changed_but_suppressed_sample"]:
        print(f"      - {name}")
    print(f"\n  diff_runs vs run 1:  {report['marked_new']} new, "
          f"{report['marked_carried_over']} carried over")
    print(f"  plugin-bearing proposals among the 'new' set: {report['plugin_features_among_new']}")
    for s in report["new_sample"]:
        print(f"      {s}")
    print(f"\n  PASS: {ok}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
