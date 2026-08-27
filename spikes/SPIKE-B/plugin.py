"""SPIKE-B step 4 — role suggestion by affinity union, incl. a plugin layer.

Issue point 4: "Verify the two proposal kinds read differently — narrative
clusters vs. provision clusters — and that role suggestion by affinity union
(FR105, ARCH D47) produces sensible role sets, including for a plugin layer's
own declared affinities."

This is the ARCH §0 failure mode's regression test (punch-list 4.17): a plugin
brings types that appear in **no** PRD example — `battlefield`, `manor_house`,
`covered_bridge` — plus `crag`, whose declared affinity is `station` (a role
the built-in OSM taxonomy never assigns from analysis). Co-location analysis
must cluster them alongside OSM candidates and propose role sets **from their
declared affinity**, with no core change.

A plugin `LayerProvider` (ARCH §14.2) ships its own taxonomy; here we model
that as a small set of `Candidate`s the provider emits directly, each carrying
its declared `role_affinity` and `salience`, and mix them into the real `brp`
candidate stream near real OSM features so genuine mixed clusters form.

    python spikes/SPIKE-B/plugin.py
"""

from __future__ import annotations

import argparse
import json
from dataclasses import replace
from pathlib import Path

import common
from regions import WORKED_PASS

from plotlines_core.curation.colocate import analyze_colocation_full, DEFAULTS
from plotlines_core.curation.notability import Candidate
from plotlines_core.curation.providers import BBox

RESULTS = Path(__file__).parent / "results"

# A plugin's declared taxonomy (ARCH D47): type -> (primary affinity, salience).
PLUGIN_TAXONOMY = {
    "battlefield": ("narrative", 0.8),
    "manor_house": ("narrative", 0.75),
    "covered_bridge": ("narrative", 0.6),
    "crag": ("station", 0.7),          # the station-affinity path analysis never had
}


def _plugin_candidates_near(anchors: list[Candidate]) -> list[Candidate]:
    """Drop plugin features ~35 m from real in-bbox OSM candidates so each
    lands in the same cluster — the "plugin type co-located with OSM types"
    case. Two copies of every plugin type, each next to a different anchor, so
    every declared affinity (narrative x3, station) is exercised."""
    out: list[Candidate] = []
    slot = 0
    for t, (aff, sal) in PLUGIN_TAXONOMY.items():
        for rep in range(2):
            a = anchors[slot % len(anchors)]
            slot += 1
            out.append(Candidate(
                id=f"plugin/{t}/{rep}",
                coord=(a.coord[0] + 0.0004, a.coord[1] + 0.00025),
                layer="heritage_plugin",
                salience=sal,
                role_affinity=aff,
                tags={"type": t, "name": f"{t.replace('_', ' ').title()} {rep}"},
                title=f"{t.replace('_', ' ').title()} {rep}",
            ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    feats = common.load_raw_features()
    cands = common.candidates_for(feats, ("amenity", "historic", "natural", "sight"))
    bb = BBox(WORKED_PASS.west, WORKED_PASS.south, WORKED_PASS.east, WORKED_PASS.north)
    big = replace(DEFAULTS, cap_floor=1_000_000)

    base, _ = analyze_colocation_full(cands, bb, big)

    # attach plugin features to a spread of real IN-BBOX candidates: some
    # narrative (viewpoints), some provision (amenities), so every union is hit.
    in_box = common.crop_candidates(cands, WORKED_PASS)
    narr = [c for c in in_box if c.role_affinity == "narrative"][::7][:6]
    prov = [c for c in in_box if c.role_affinity == "provision"][::9][:4]
    plugin = _plugin_candidates_near(narr + prov)
    withplugin, _ = analyze_colocation_full(cands + plugin, bb, big)

    # 1. kinds read differently -------------------------------------------- #
    kinds = sorted({p.kind for p in withplugin})
    pure_narr = [p for p in withplugin if p.kind == "narrative"][:3]
    pure_prov = [p for p in withplugin if p.kind == "provision"][:3]
    mixed = [p for p in withplugin if p.kind == "narrative+provision"][:3]

    # 2. plugin participation + affinity union ---------------------------------- #
    plugin_props = [p for p in withplugin
                    if any(m.candidate_id.startswith("plugin/") for m in p.members)]
    station_props = [p for p in withplugin if "station" in p.role_affinities]

    report = {
        "kinds_present": kinds,
        "sample_narrative": [_p(p) for p in pure_narr],
        "sample_provision": [_p(p) for p in pure_prov],
        "sample_mixed": [_p(p) for p in mixed],
        "proposals_without_plugin": len(base),
        "proposals_with_plugin": len(withplugin),
        "plugin_bearing_proposals": [_p(p) for p in plugin_props],
        "station_role_proposals": [_p(p) for p in station_props],
    }

    if args.json:
        RESULTS.mkdir(exist_ok=True)
        (RESULTS / "plugin.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
        return 0

    print("\n=== proposal KINDS read differently (issue point 4) ===")
    print(f"kinds present: {report['kinds_present']}")
    for label, sample in (("narrative -> plot point", pure_narr),
                          ("provision -> rest stop", pure_prov),
                          ("narrative+provision -> major stop", mixed)):
        print(f"\n  {label}")
        for p in sample:
            print(f"    {p.name[:30]:30} roles={p.role_affinities}  "
                  f"[{', '.join(sorted({m.type for m in p.members}))[:60]}]")

    print("\n=== PLUGIN layer — affinity union, no core change (punch-list 4.17) ===")
    print(f"proposals: {len(base)} without plugin -> {len(withplugin)} with it")
    print("\n  proposals containing a plugin type:")
    for p in plugin_props:
        pm = [m for m in p.members if m.candidate_id.startswith("plugin/")]
        om = [m for m in p.members if not m.candidate_id.startswith("plugin/")]
        print(f"    {p.name[:26]:26} kind={p.kind:20} roles={p.role_affinities}")
        for m in pm:
            print(f"        plugin: {m.type:16} affinity={m.role_affinity} sal={m.salience}")
        for m in om[:3]:
            print(f"        osm:    {m.type:16} affinity={m.role_affinity}")

    print("\n  proposals that gained the STATION role (from the plugin's crag):")
    for p in station_props:
        print(f"    {p.name[:26]:26} roles={p.role_affinities}  kind={p.kind}")
    if not station_props:
        print("    (none — crag did not co-locate; rerun places it near an OSM feature)")

    return 0


def _p(p):
    return {"name": p.name, "kind": p.kind, "roles": list(p.role_affinities),
            "members": [{"type": m.type, "affinity": m.role_affinity,
                         "salience": m.salience} for m in p.members]}


if __name__ == "__main__":
    raise SystemExit(main())
