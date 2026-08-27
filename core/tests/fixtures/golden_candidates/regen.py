"""Regenerate `mixed_bbox_expected.json` from `mixed_bbox_input.json`.

The golden candidate set (ARCH §15.1) locks what the notability ruleset emits
for a fixed, hand-curated input covering every SPIKE-A calibration case: the
`historic=*` sub-weight tail, the `denotation`-value tree gate, name-only vs
heritage-signalled bridges and places of worship, park name/area qualification,
and the FR104 provisions. A change to `taxonomy.py` that moves any line here is
either a bug or a reviewed ruleset decision — never silent.

    python core/tests/fixtures/golden_candidates/regen.py
"""

from __future__ import annotations

import json
from pathlib import Path

from plotlines_core.curation.notability import RawFeature, score_notability, RULESET_VERSION
from plotlines_core.curation.taxonomy import LAYERS

HERE = Path(__file__).parent


def main() -> None:
    spec = json.loads((HERE / "mixed_bbox_input.json").read_text())
    raw = [
        RawFeature(id=f["id"], coord=(-82.55, 35.59), tags=f["tags"], area_m2=f["area_m2"])
        for f in spec["features"]
    ]
    cands = score_notability(raw, live_layers=LAYERS)
    out = {
        "ruleset_version": RULESET_VERSION,
        "note": "SPIKE-A (#158) golden candidate set. Regenerate with regen.py.",
        "candidate_count": len(cands),
        "candidates": [
            {"id": c.id, "salience": round(c.salience, 4), "layer": c.layer,
             "role_affinity": c.role_affinity, "title": c.title}
            for c in cands
        ],
    }
    (HERE / "mixed_bbox_expected.json").write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote mixed_bbox_expected.json — {len(cands)} candidates, ruleset {RULESET_VERSION}")


if __name__ == "__main__":
    main()
