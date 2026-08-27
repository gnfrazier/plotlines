"""Golden candidate set (ARCH §15.1) — the curation tier's golden-route test.

SPIKE-A (#158) calibrated the notability ruleset against real extracts. This
locks its output: a fixed hand-curated input covering every calibration case
must produce exactly the committed candidate list, at exactly the committed
salience. A `taxonomy.py` change that moves any line is a deliberate ruleset
change and must move `mixed_bbox_expected.json` with it (via `regen.py`).
"""

import json
from pathlib import Path

import pytest

from plotlines_core.curation.notability import RawFeature, RULESET_VERSION, score_notability
from plotlines_core.curation.taxonomy import LAYERS

FIX = Path(__file__).parent / "fixtures" / "golden_candidates"


def _load():
    spec = json.loads((FIX / "mixed_bbox_input.json").read_text())
    expected = json.loads((FIX / "mixed_bbox_expected.json").read_text())
    raw = [
        RawFeature(id=f["id"], coord=(-82.55, 35.59), tags=f["tags"], area_m2=f["area_m2"])
        for f in spec["features"]
    ]
    return raw, expected


def test_golden_candidate_set_is_unchanged():
    raw, expected = _load()
    got = score_notability(raw, live_layers=LAYERS)
    got_rows = [
        {"id": c.id, "salience": round(c.salience, 4), "layer": c.layer,
         "role_affinity": c.role_affinity, "title": c.title}
        for c in got
    ]
    assert got_rows == expected["candidates"], (
        "notability output drifted from the golden set — if this is a deliberate "
        "ruleset change, rerun core/tests/fixtures/golden_candidates/regen.py"
    )


def test_golden_fixture_matches_current_ruleset_version():
    _, expected = _load()
    assert expected["ruleset_version"] == RULESET_VERSION, (
        "golden set was generated against a different RULESET_VERSION; regenerate it"
    )


@pytest.mark.parametrize("dropped_id", [
    "tree_avenue", "tree_urban", "tree_bare",   # denotation-value gate
    "park_small_unnamed",                        # name-or-area gate
    "bridge_plain",                              # name is not a notability signal for bridges
    "pow_plain",                                 # place_of_worship needs a heritage/wiki signal
    "attraction_bare",                           # attraction needs a name
    "shop_bakery", "bench",                      # no taxonomy rule at all
])
def test_known_noise_is_filtered(dropped_id):
    raw, _ = _load()
    got_ids = {c.id for c in score_notability(raw, live_layers=LAYERS)}
    assert dropped_id not in got_ids


def test_calibration_ordering_holds():
    # The point of FR98(a): a historic district and a castle outrank a plain
    # historic building, which outranks a boundary stone, which outranks
    # `historic=yes`. And a street tree never outranks any of them.
    raw, _ = _load()
    by_id = {c.id: c.salience for c in score_notability(raw, live_layers=LAYERS)}
    assert by_id["castle"] > by_id["hist_building"] > by_id["hist_boundary"] > by_id["hist_yes"]
    assert by_id["hist_district"] >= 0.85
    assert "tree_avenue" not in by_id
