"""FR109, FR16b, FR24 / O4 — the station-activity registry
(`plotlines_core.multimodal.station_activities`).

O4's AC: "adding a new activity type is a config entry, not code." These tests
pin that the registry behaves like `modes`/`disciplines` (a row of data, an
optional `registry=` extension seam, unknown keys tolerated) and that the
"never a travel mode" invariant (punch-list §2.6) still holds now that the key
set lives here rather than inline in `modes.py`.
"""

import pytest

from plotlines_core.multimodal import station_activities as sa
from plotlines_core.multimodal.disciplines import DISCIPLINES
from plotlines_core.multimodal.modes import (
    STATION_ACTIVITIES,
    TRANSPORT_NOTE_MODES,
    TRAVERSAL_MODES,
    is_station_activity,
)


def test_registry_keys_match_their_entries():
    for key, activity in sa.ACTIVITY_TYPES.items():
        assert activity.key == key


def test_fr109_named_three_are_present():
    for named in ("climbing", "canyoneering", "jumaring"):
        assert sa.is_activity_type(named)
        assert sa.activity_type(named) is not None


def test_key_set_is_disjoint_from_every_travel_axis():
    keys = set(sa.STATION_ACTIVITY_KEYS)
    assert not keys & set(TRAVERSAL_MODES)
    assert not keys & set(TRANSPORT_NOTE_MODES)
    assert not keys & set(DISCIPLINES)


def test_modes_re_exports_the_same_key_set():
    # `modes.STATION_ACTIVITIES` is now a re-export, not a second definition.
    assert STATION_ACTIVITIES is sa.STATION_ACTIVITY_KEYS
    assert set(STATION_ACTIVITIES) == set(sa.ACTIVITY_TYPES)


@pytest.mark.parametrize("activity", ["climbing", "canyoneering", "jumaring"])
def test_is_station_activity_still_answers_for_the_named_three(activity):
    # Punch-list §2.6's fail signal is "climbing or canyoneering appears
    # anywhere in a travel mode list" — `is_station_activity` is what keeps
    # the pickers honest, and it must survive the key set moving modules.
    assert is_station_activity(activity)


def test_the_travel_mode_schema_enum_still_carries_no_station_activity():
    import json
    from pathlib import Path

    schema = json.loads(
        (Path(__file__).resolve().parents[2] / "docs" / "schemas" / "trip_payload.schema.json")
        .read_text()
    )
    assert not set(sa.STATION_ACTIVITY_KEYS) & set(schema["$defs"]["travel_mode"]["enum"])


def test_label_falls_through_to_the_raw_key_for_an_unknown_activity():
    # FR144 posture, mirrored from `modes.mode_label`: an activity a plugin
    # declared is nameable even without a term of its own.
    assert sa.activity_label("climbing") == "Climbing"
    assert sa.activity_label("via_ferrata") == "via_ferrata"


def test_default_duration_is_none_for_an_unknown_activity():
    assert sa.default_duration_s_for("via_ferrata") is None
    assert sa.default_duration_s_for("climbing") == 3 * 3600.0


def test_lookups_accept_an_injected_registry_without_touching_the_global():
    custom = {
        "via_ferrata": sa.ActivityType(
            key="via_ferrata", label="Via ferrata", medium="land",
            default_duration_s=2 * 3600.0,
        ),
    }
    assert sa.is_activity_type("via_ferrata", custom)
    assert not sa.is_activity_type("climbing", custom)
    assert sa.activity_label("via_ferrata", custom) == "Via ferrata"
    assert sa.all_activity_type_keys(custom) == ["via_ferrata"]
    # The module global is untouched.
    assert not sa.is_activity_type("via_ferrata")


def test_activity_type_rejects_a_bad_medium():
    with pytest.raises(ValueError, match="medium"):
        sa.ActivityType(key="x", label="X", medium="air", default_duration_s=None)


def test_activity_type_rejects_a_negative_default_duration():
    with pytest.raises(ValueError, match="non-negative"):
        sa.ActivityType(key="x", label="X", medium="land", default_duration_s=-1.0)
