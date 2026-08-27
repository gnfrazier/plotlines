"""Serialize the calibrated notability ruleset to versioned JSON.

ARCH §4.3 wants the ruleset as "versioned config, not code" so tuning is not a
release. Today it lives in `core/plotlines_core/curation/taxonomy.py` as a tuple
of dataclasses; this script is the proof that it *is* pure data — it round-trips
to `results/notability_ruleset.v{N}.json` with nothing lost. Moving the loader
into `core` (reading this JSON at import instead of the literal tuple) is a small
follow-up the spike recommends but does not itself make.

    python spikes/SPIKE-A/export_ruleset.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "core"))

from plotlines_core.curation.notability import RULESET_VERSION  # noqa: E402
from plotlines_core.curation.taxonomy import (  # noqa: E402
    _UNCATALOGED_WILDCARD_WEIGHT, TAXONOMY,
)

HERE = Path(__file__).parent


def rule_to_dict(r) -> dict:
    q = r.qualification
    out = {
        "layer": r.layer,
        "key": r.key,
        "value": r.value,
        "base_weight": r.base_weight,
        "role_affinity": r.role_affinity,
    }
    if r.value_weights:
        out["value_weights"] = dict(r.value_weights)
    gate = {}
    if q.requires_any:
        gate["requires_any"] = list(q.requires_any)
    if q.requires_value:
        gate["requires_value"] = {k: list(v) for k, v in q.requires_value.items()}
    if q.min_area_m2 is not None:
        gate["min_area_m2"] = q.min_area_m2
    if gate:
        out["qualification"] = gate
    return out


def main() -> int:
    doc = {
        "ruleset_version": RULESET_VERSION,
        "uncataloged_wildcard_weight": _UNCATALOGED_WILDCARD_WEIGHT,
        "calibrated_by": "SPIKE-A (issue #158), 2026-08-27, extracts: avl / lwr / sgv",
        "rules": [rule_to_dict(r) for r in TAXONOMY],
    }
    out = HERE / "results" / f"notability_ruleset.v{RULESET_VERSION}.json"
    out.write_text(json.dumps(doc, indent=2), encoding="utf-8")
    print(f"wrote {out}  ({len(doc['rules'])} rules, version {RULESET_VERSION})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
