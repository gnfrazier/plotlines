"""Unit tests for `plotlines_core.multimodal.disciplines` — issue #315.

The discipline registry is the second axis under a traversal category (Model B).
It mirrors `modes.py`'s contract, so these tests mirror `test_modes.py`'s:

  * every discipline names a real category and carries a real `WeightProfile`;
  * the schema's `$defs/discipline` enum cannot drift from the registry;
  * a discipline is configuration, not a scorer branch — the one shared
    `edge_cost` prices a discipline's profile with no `if` on the discipline;
  * disciplines are disjoint from modes, note modes and station activities;
  * an unknown discipline falls through rather than raising (FR144's posture).
"""

import json
from pathlib import Path

import pytest

from plotlines_core.multimodal.disciplines import (
    DISCIPLINES,
    Discipline,
    all_discipline_keys,
    category_of,
    discipline,
    disciplines_for,
    is_discipline,
    weights_for_discipline,
)
from plotlines_core.multimodal.modes import (
    EXTENDED,
    FIRST_CLASS,
    STATION_ACTIVITIES,
    TRANSPORT_NOTE_MODES,
    TRAVERSAL_MODES,
    weights_for,
)
from plotlines_core.scoring.profile import WeightProfile, edge_cost

_SCHEMA = Path(__file__).resolve().parents[2] / "docs" / "schemas" / "trip_payload.schema.json"

#: The owner's #315 comment: difficulty grading is in scope for the land
#: categories (Cycle, Foot) and out for Paddle / Ski (the data would come from a
#: plugin). `grades_difficulty` records that; nothing reads it yet.
_GRADES_DIFFICULTY = {
    "road": True, "gravel": True, "mountain": True,
    "hike": True, "run": True, "trail_run": True,
    "canoe": False, "kayak": False, "packraft": False, "riverboard": False,
    "nordic": False, "skimo": False, "backcountry": False, "resort": False,
    "street": False, "high_clearance": False,
}


# --- the MVP set --------------------------------------------------------------


def test_the_registry_is_the_mvp_discipline_set():
    assert set(DISCIPLINES) == {
        "road", "gravel", "mountain",
        "hike", "run", "trail_run",
        "canoe", "kayak", "packraft", "riverboard",
        "nordic", "skimo", "backcountry", "resort",
        "street", "high_clearance",
    }


@pytest.mark.parametrize("category,expected", [
    ("cycling", ["road", "gravel", "mountain"]),
    ("hiking", ["hike", "run", "trail_run"]),
    ("paddling", ["canoe", "kayak", "packraft", "riverboard"]),
    ("cross_country_skiing", ["nordic", "skimo", "backcountry", "resort"]),
    ("driving", ["street", "high_clearance"]),
])
def test_disciplines_for_covers_each_category(category, expected):
    assert disciplines_for(category) == expected


def test_every_discipline_carries_its_domain_parameters():
    for key, d in DISCIPLINES.items():
        assert d.key == key
        assert d.category in TRAVERSAL_MODES
        assert d.tier in {FIRST_CLASS, EXTENDED}
        assert isinstance(d.weights, WeightProfile)
        assert isinstance(d.grades_difficulty, bool)
        assert d.label and d.label != key
        assert category_of(key) == d.category


def test_grades_difficulty_matches_the_owners_table():
    assert {k: d.grades_difficulty for k, d in DISCIPLINES.items()} == _GRADES_DIFFICULTY


def test_reused_ex_mode_profiles_are_carried_verbatim():
    """`mountain` / `packraft` / `riverboard` reuse the weight profiles the
    removed `mountain_biking` / `packrafting` / `riverboarding` modes carried —
    one source of tuning, not two."""
    mtb = DISCIPLINES["mountain"].weights
    assert (mtb.surface_singletrack, mtb.surface_gravel, mtb.surface_paved) == (1.0, 0.5, -0.6)
    assert mtb.peaks == pytest.approx(0.4)
    assert DISCIPLINES["packraft"].weights.quiet == 1.0
    assert DISCIPLINES["gravel"].weights.surface_gravel == 1.0


# --- schema parity ---------------------------------------------------------


def test_the_schema_discipline_enum_matches_the_registry():
    schema = json.loads(_SCHEMA.read_text())
    assert schema["$defs"]["discipline"]["enum"] == all_discipline_keys()


def test_the_segment_def_carries_an_optional_discipline():
    schema = json.loads(_SCHEMA.read_text())
    seg = schema["$defs"]["segment"]
    assert seg["properties"]["discipline"]["$ref"] == "#/$defs/discipline"
    assert "discipline" not in seg["required"]


# --- disjointness (the #315 invariant, as an assertion) --------------------


def test_a_discipline_is_never_also_a_mode_or_a_station_activity():
    keys = set(DISCIPLINES)
    assert not keys & set(TRAVERSAL_MODES)
    assert not keys & set(TRANSPORT_NOTE_MODES)
    assert not keys & STATION_ACTIVITIES


@pytest.mark.parametrize("activity", ["climbing", "canyoneering", "jumaring"])
def test_station_activities_are_not_disciplines(activity):
    assert not is_discipline(activity)
    assert activity not in all_discipline_keys()


# --- FR144 posture: an unknown discipline falls through -------------------


def test_lookups_fall_through_for_an_unknown_discipline():
    assert discipline("wingfoiling") is None
    assert not is_discipline("wingfoiling")
    assert category_of("wingfoiling") is None
    assert weights_for_discipline("wingfoiling") == WeightProfile()
    assert disciplines_for("teleportation") == []


def test_the_registry_arg_lets_a_new_discipline_be_exercised_without_a_global():
    registry = {
        **DISCIPLINES,
        "fatbike": Discipline(
            key="fatbike", label="Fat bike", category="cycling", tier=EXTENDED,
            weights=WeightProfile(name="fatbike", surface_gravel=0.8, surface_paved=-0.4),
            grades_difficulty=True,
        ),
    }
    assert is_discipline("fatbike", registry)
    assert category_of("fatbike", registry) == "cycling"
    assert "fatbike" in disciplines_for("cycling", registry)


# --- FR130: a discipline's profile is a real scoring input ----------------


def test_a_disciplines_profile_is_a_real_scoring_input_not_decoration():
    """The `mountain` discipline seeks singletrack outright and avoids pavement
    (FR4's bipolar dials); against plain cycling that has to show up as a
    cheaper trail edge and a dearer paved one under the one shared scorer —
    with no branch on the discipline anywhere in the call. (Moved here from
    `test_modes.py` when #315 turned `mountain_biking` into a discipline.)"""
    trail = {"highway": "path", "length": 100.0}
    road = {"highway": "residential", "surface": "asphalt", "length": 100.0}
    mtb = weights_for_discipline("mountain")
    plain = weights_for("cycling")
    assert edge_cost(trail, mtb) < edge_cost(trail, plain)
    assert edge_cost(road, mtb) > edge_cost(road, plain)
