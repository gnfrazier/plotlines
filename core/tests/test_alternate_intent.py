"""FR20 / C4 [AMENDED v2.0] — an alternate carries one of two authoring intents.

`accommodation` is the v1.0 fitness ladder (bypass/easiest, extension/challenge)
that adjusts effort only. `branch` is the new story-shaped choice: a path with
its own content — its own anchors, narration, and reveal policy. This module
pins the payload shape and the cue-sheet wording for both; the H6 effort-toggle
guard (a branch is never an accommodation choice) is covered on the Dart side in
`client/test/character_variant_test.dart`.

Schema authority is `docs/schemas/trip_payload.schema.json`; `_assert_known_keys`
checks every emitted key against the `alternate` `$def` so a field this module
writes can never drift from what the schema allows.
"""

import json
import math
from pathlib import Path

import pytest

from plotlines_core.trips import payload
from plotlines_core.trips.cues import Route, alternate_cues

_SCHEMA = json.loads(
    (Path(__file__).resolve().parents[2] / "docs" / "schemas" / "trip_payload.schema.json")
    .read_text()
)
_ALTERNATE_KEYS = set(_SCHEMA["$defs"]["alternate"]["properties"])


def _assert_known_keys(obj: dict) -> None:
    unknown = set(obj) - _ALTERNATE_KEYS
    assert not unknown, f"alternate dict has keys the schema forbids: {unknown}"


def _line(*coords: list[float]) -> payload.LineString:
    return payload.LineString(coordinates=list(coords))


_STEP_DEG = 100.0 / (math.cos(math.radians(40.0)) * math.pi * 6_371_000.0 / 180.0)


def _route() -> Route:
    coords = [[-105.30 + _STEP_DEG * i, 40.0] for i in range(11)]
    return Route(coords=coords, cumulative_m=[100.0 * i for i in range(11)], edges=[])


# --------------------------------------------------------------------- shape

def test_intent_defaults_to_accommodation_and_carries_no_branch_content():
    alt = payload.Alternate(kind="bypass", geometry=_line([0, 0], [1, 1]))
    assert alt.intent == "accommodation"
    d = alt.to_dict()
    assert d["intent"] == "accommodation"
    assert d["note"] is None
    assert d["anchor_ids"] is None
    assert d["narration"] is None
    assert d["reveal"] is None
    _assert_known_keys(d)


def test_a_branch_alternate_round_trips_its_own_content():
    alt = payload.Alternate(
        kind="extension",
        geometry=_line([0, 0], [1, 1]),
        intent="branch",
        label="The long way past the abandoned mine",
        note="Adds 4 km and a 200 m climb; passes the mine headframe and the "
        "miners' cemetery.",
        anchor_ids=["anc-mine", "anc-cemetery"],
        narration=payload.Narration(trigger_distance_m=150.0, text="The mine."),
        reveal="on_arrival",
    )
    d = alt.to_dict()
    assert d["intent"] == "branch"
    assert d["note"].startswith("Adds 4 km")
    assert d["anchor_ids"] == ["anc-mine", "anc-cemetery"]
    assert d["narration"]["trigger_distance_m"] == 150.0
    assert d["reveal"] == "on_arrival"
    _assert_known_keys(d)


def test_an_accommodation_alternate_carrying_branch_content_is_rejected():
    with pytest.raises(ValueError, match="branch-alternate content"):
        payload.Alternate(
            kind="bypass",
            geometry=_line([0, 0], [1, 1]),
            note="a story beat on an effort toggle",
        )
    with pytest.raises(ValueError, match="branch-alternate content"):
        payload.Alternate(
            kind="bypass",
            geometry=_line([0, 0], [1, 1]),
            anchor_ids=["anc-1"],
        )


def test_an_unknown_intent_is_rejected():
    with pytest.raises(ValueError, match="is not one of"):
        payload.Alternate(kind="bypass", geometry=_line([0, 0], [1, 1]), intent="ladder")


def test_a_branch_alternate_with_no_content_is_still_valid():
    """Intent is the distinction; the content fields are optional even on a
    branch (an Author may tag the intent before writing the path's story)."""
    alt = payload.Alternate(kind="bypass", geometry=_line([0, 0], [1, 1]), intent="branch")
    assert alt.to_dict()["intent"] == "branch"


# --------------------------------------------------------------------- cues

def test_an_accommodation_alternate_is_cued_as_an_effort_option():
    alt = payload.Alternate(
        kind="bypass", geometry=_line([0, 0]), label="Skip the ridge", diverges_at_m=300.0,
    )
    cues = alternate_cues(_route(), [alt])
    assert len(cues) == 1
    assert cues[0].kind == "alternate"
    assert cues[0].instruction == "Bypass available: Skip the ridge"
    assert cues[0].distance_along_m == 300.0
    assert cues[0].ref_id == alt.id


def test_a_branch_alternate_is_cued_as_a_choice():
    alt = payload.Alternate(
        kind="extension",
        geometry=_line([0, 0]),
        intent="branch",
        label="The long way past the mine",
        diverges_at_m=400.0,
    )
    cues = alternate_cues(_route(), [alt])
    assert cues[0].instruction == "Branch — The long way past the mine"
    assert cues[0].distance_along_m == 400.0


def test_a_branch_alternate_is_cued_at_the_divergence_projected_from_geometry():
    """No explicit diverges_at_m: the cue lands where the branch leaves the route."""
    start = [-105.30 + _STEP_DEG * 6, 40.0]
    alt = payload.Alternate(
        kind="bypass", geometry=_line(start, [start[0], 40.01]), intent="branch",
        label="Detour",
    )
    cues = alternate_cues(_route(), [alt])
    assert cues[0].distance_along_m == pytest.approx(600.0, abs=1.0)
    assert cues[0].instruction == "Branch — Detour"
