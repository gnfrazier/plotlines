"""FR37 / E1 — `trips.payload.Segment`/`Day` carry their own `note`/`media`,
distinct from a `content.anchor.Role`'s (already existed before this story).
Schema authority is `docs/schemas/trip_payload.schema.json` (ARCH D28);
`_assert_known_keys` checks emitted dict keys against each `$def`'s own
`properties` so a field this module writes can never silently drift from
what the schema (`additionalProperties: false` everywhere) actually allows —
deliberately dependency-free (no `jsonschema`, unlike SPIKE-20's own
harness) since this project's `core` venv doesn't carry that package.
"""

import json
from pathlib import Path

import pytest

from plotlines_core.content import anchor as content_anchor
from plotlines_core.trips import payload

_SCHEMA = json.loads(
    (Path(__file__).resolve().parents[2] / "docs" / "schemas" / "trip_payload.schema.json")
    .read_text()
)
_DEFS = _SCHEMA["$defs"]


def _assert_known_keys(obj: dict, def_name: str) -> None:
    allowed = set(_DEFS[def_name]["properties"])
    unknown = set(obj) - allowed
    assert not unknown, f"{def_name} dict has keys {def_name} schema doesn't allow: {unknown}"


def test_segment_note_and_media_round_trip_into_the_dict():
    segment = payload.Segment(
        mode="cycling",
        shape="loop",
        note="Watch for loose gravel on the descent.",
        media=[payload.MediaRef(kind="image", path="descent.jpg", caption="The switchback")],
    )
    d = segment.to_dict()
    assert d["note"] == "Watch for loose gravel on the descent."
    assert d["media"] == [{
        "id": segment.media[0].id, "kind": "image", "path": "descent.jpg",
        "caption": "The switchback", "bytes": None, "duration_s": None,
    }]
    _assert_known_keys(d, "segment")
    _assert_known_keys(d["media"][0], "media_ref")


def test_segment_with_no_note_or_media_omits_both_keys():
    """Rule 3 (payload.py's module doc): absent means unset, never `null`."""
    d = payload.Segment(mode="cycling", shape="loop").to_dict()
    assert d["note"] is None
    assert d["media"] is None


def test_day_note_and_media_round_trip_distinct_from_any_segment_or_role_content():
    day = payload.Day(
        index=1,
        note="Camp at the shelter tonight.",
        media=[payload.MediaRef(kind="image", path="shelter.jpg")],
        segments=[payload.Segment(mode="hiking", shape="loop", note="passage-only note")],
    )
    d = day.to_dict()
    assert d["note"] == "Camp at the shelter tonight."
    assert d["media"][0]["path"] == "shelter.jpg"
    # The day's own note/media are independent of its segment's.
    assert d["segments"][0]["note"] == "passage-only note"
    assert d["segments"][0]["media"] is None
    _assert_known_keys(d, "day")
    _assert_known_keys(d["segments"][0], "segment")


@pytest.mark.parametrize("kind", ["image", "audio", "video", "document", "link"])
def test_role_passage_and_day_content_each_stay_within_their_own_defs_shape(kind):
    # E1's AC names three content homes — role, passage (segment), day.
    # Role-level note/media already existed before this story
    # (`content.anchor.Role`); this exercises all three against the same
    # schema authority in one place.
    day = payload.Day(
        index=1,
        note="Day note",
        media=[payload.MediaRef(kind=kind, path="day.jpg")],
        segments=[payload.Segment(
            mode="cycling", shape="loop",
            note="Passage note",
            media=[payload.MediaRef(kind=kind, path="passage.jpg")],
        )],
    )
    day_dict = day.to_dict()
    _assert_known_keys(day_dict, "day")
    _assert_known_keys(day_dict["media"][0], "media_ref")
    segment_dict = day_dict["segments"][0]
    _assert_known_keys(segment_dict, "segment")
    _assert_known_keys(segment_dict["media"][0], "media_ref")

    role = content_anchor.Role(
        kind="narrative", note="Role note",
        media=[content_anchor.MediaRef(kind=kind, path="role.jpg")],
    )
    role_dict = role.to_dict()
    assert role_dict["note"] == "Role note"
    _assert_known_keys(role_dict, "role")
    _assert_known_keys(role_dict["media"][0], "media_ref")
