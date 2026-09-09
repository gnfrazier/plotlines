"""Unit tests for `plotlines_core.multimodal.legacy` — issue #315.

`mountain_biking` / `packrafting` / `riverboarding` left the `travel_mode`
enum. A trip payload written before the change must still load: the migration
rewrites the removed values to the `(category, discipline)` they became,
before the payload is validated against the schema.
"""

import pytest

from plotlines_core.multimodal.disciplines import DISCIPLINES
from plotlines_core.multimodal.legacy import (
    LEGACY_MODE_ALIASES,
    canonical_mode,
    migrate_payload_modes,
)
from plotlines_core.multimodal.modes import TRAVERSAL_MODES


def test_every_alias_maps_to_a_real_category_and_discipline():
    for old, (category, disc) in LEGACY_MODE_ALIASES.items():
        assert old not in TRAVERSAL_MODES
        assert category in TRAVERSAL_MODES
        assert disc in DISCIPLINES
        assert DISCIPLINES[disc].category == category


def test_canonical_mode_folds_a_removed_value_onto_its_category():
    assert canonical_mode("mountain_biking") == "cycling"
    assert canonical_mode("packrafting") == "paddling"
    assert canonical_mode("cycling") == "cycling"
    assert canonical_mode("teleportation") == "teleportation"


def _payload_with(mode: str, *, discipline: str | None = None) -> dict:
    seg: dict = {"id": "s1", "mode": mode, "shape": "point_to_point"}
    if discipline is not None:
        seg["discipline"] = discipline
    return {
        "schema_version": "1.7.0",
        "days": [{
            "id": "d1", "index": 1, "kind": "route",
            "segments": [seg],
            "transitions": [{"from_mode": mode, "to_mode": "hiking"}],
            "metrics": {"by_mode": [{"mode": mode, "bound": "max",
                                     "limit_m": 1.0, "realised_m": 1.0}]},
        }],
    }


def test_migrate_rewrites_segment_mode_and_seeds_discipline():
    out = migrate_payload_modes(_payload_with("mountain_biking"))
    seg = out["days"][0]["segments"][0]
    assert seg["mode"] == "cycling"
    assert seg["discipline"] == "mountain"


def test_migrate_does_not_clobber_an_explicit_discipline():
    out = migrate_payload_modes(_payload_with("mountain_biking", discipline="gravel"))
    seg = out["days"][0]["segments"][0]
    assert seg["mode"] == "cycling"
    assert seg["discipline"] == "gravel"


def test_migrate_rewrites_transitions_and_rollups():
    out = migrate_payload_modes(_payload_with("packrafting"))
    day = out["days"][0]
    assert day["transitions"][0]["from_mode"] == "paddling"
    assert day["transitions"][0]["to_mode"] == "hiking"
    assert day["metrics"]["by_mode"][0]["mode"] == "paddling"


def test_migrate_is_idempotent_and_a_no_op_for_current_payloads():
    clean = _payload_with("cycling", discipline="road")
    once = migrate_payload_modes(clean)
    twice = migrate_payload_modes(once)
    assert once == clean
    assert twice == once


def test_migrate_does_not_mutate_the_input():
    src = _payload_with("mountain_biking")
    migrate_payload_modes(src)
    assert src["days"][0]["segments"][0]["mode"] == "mountain_biking"


@pytest.mark.parametrize("payload", [{}, {"days": []}, {"days": [{"id": "d1"}]}])
def test_migrate_tolerates_sparse_payloads(payload):
    assert isinstance(migrate_payload_modes(payload), dict)
