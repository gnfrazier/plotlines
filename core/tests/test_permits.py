"""Story C10 — permits, land-access rules, and parking passes (PRD FR26).

Covers the model half of C10's acceptance criteria:

  * a permit attaches to a passage or a promoted anchor, with a status,
    confirmation number, and documents/links;
  * status is a closed enum, enforced in the model, not just the schema;
  * `trips.permits.collect_permits` is the single traversal every permit
    surface reads;
  * `permit_checklist` is the pre-trip checklist FR26 asks for, ordered so
    the permits that still need attention lead.
"""

import json
from pathlib import Path

import pytest

from plotlines_core.content.anchor import Anchor, Role
from plotlines_core.trips.payload import PERMIT_STATUSES, Permit, Trip
from plotlines_core.trips.permits import (
    NEEDS_ATTENTION_STATUSES,
    collect_permits,
    permit_checklist,
)

_SCHEMA = json.loads(
    (Path(__file__).resolve().parents[2] / "docs" / "schemas" / "trip_payload.schema.json")
    .read_text()
)


def _trip(permits: list[Permit], anchors: list[Anchor] | None = None) -> Trip:
    return Trip(title="Test trip", permits=permits, anchors=anchors or [])


# --- the model: status is a closed enum, enforced here ---------------------


def test_status_enum_matches_the_schema():
    assert set(PERMIT_STATUSES) == set(_SCHEMA["$defs"]["permit_status"]["enum"])


def test_permit_rejects_a_status_outside_the_enum():
    with pytest.raises(ValueError, match="status"):
        Permit(title="Backcountry permit", status="pending")


@pytest.mark.parametrize("status", PERMIT_STATUSES)
def test_every_named_status_constructs(status):
    assert Permit(title="Backcountry permit", status=status).status == status


def test_permit_title_must_be_a_non_empty_string():
    for bad in ("", "   "):
        with pytest.raises(ValueError, match="non-empty string"):
            Permit(title=bad)


def test_permit_pins_to_a_segment_or_an_anchor_but_not_both():
    Permit(title="Wilderness permit", anchor_id="anchor-1")
    Permit(title="Shuttle parking pass", segment_id="segment-1")
    Permit(title="Neither", status="required")  # a trip-wide obligation
    with pytest.raises(ValueError, match="mutually exclusive"):
        Permit(title="Both", anchor_id="anchor-1", segment_id="segment-1")


def test_permit_carries_confirmation_number_link_and_note():
    permit = Permit(
        title="River-corridor put-in permit",
        status="confirmed",
        confirmation_number="RVR-2026-0091",
        link="https://parks.example.gov/permits/RVR-2026-0091",
        note="Print two copies — one for the truck.",
    )
    d = permit.to_dict()
    assert d["confirmation_number"] == "RVR-2026-0091"
    assert d["link"].endswith("RVR-2026-0091")
    assert d["note"].startswith("Print two copies")


def test_emitted_dict_keys_match_the_schema():
    allowed = set(_SCHEMA["$defs"]["permit"]["properties"])
    emitted = set(Permit(title="Backcountry permit", anchor_id="a1").to_dict())
    assert emitted <= allowed, emitted - allowed
    assert "anchor_id" in allowed


def test_trip_carries_permits_and_prunes_when_empty():
    assert "permits" not in Trip(title="Empty").to_dict()
    out = _trip([Permit(title="Backcountry permit")]).to_dict()
    assert len(out["permits"]) == 1
    assert out["permits"][0]["title"] == "Backcountry permit"


# --- collect_permits: one traversal, with placement -------------------------


def test_collect_reads_trip_permits_in_order():
    permits = [
        Permit(title="First", status="required"),
        Permit(title="Second", status="confirmed"),
    ]
    located = collect_permits(_trip(permits))
    assert [lp.permit.title for lp in located] == ["First", "Second"]


def test_collect_scopes_trip_passage_and_anchor():
    permits = [
        Permit(title="Annual pass", status="confirmed"),
        Permit(title="Put-in permit", status="required", segment_id="seg-1"),
        Permit(title="Trailhead permit", status="required", anchor_id="anchor-1"),
    ]
    located = collect_permits(_trip(permits))
    assert [lp.scope for lp in located] == ["trip", "passage", "anchor"]


def test_collect_resolves_anchor_title():
    anchor = Anchor(id="anchor-1", coord=[0.0, 0.0], title="Ranger Station",
                     roles=[Role(kind="provision")])
    permit = Permit(title="Backcountry permit", anchor_id="anchor-1")
    located = collect_permits(_trip([permit], anchors=[anchor]))
    assert located[0].anchor_title == "Ranger Station"


def test_needs_attention_is_everything_short_of_confirmed():
    assert set(NEEDS_ATTENTION_STATUSES) == {"required", "applied", "denied"}
    for status in NEEDS_ATTENTION_STATUSES:
        assert collect_permits(_trip([Permit(title="x", status=status)]))[0].needs_attention
    assert not collect_permits(_trip([Permit(title="x", status="confirmed")]))[0].needs_attention


# --- permit_checklist: FR26's pre-trip checklist ----------------------------


def test_checklist_orders_worst_first_denied_then_required_then_applied_then_confirmed():
    permits = [
        Permit(title="Confirmed one", status="confirmed"),
        Permit(title="Denied one", status="denied"),
        Permit(title="Applied one", status="applied"),
        Permit(title="Required one", status="required"),
    ]
    checklist = permit_checklist(_trip(permits))
    assert [lp.permit.status for lp in checklist.permits] == [
        "denied", "required", "applied", "confirmed",
    ]


def test_checklist_tallies_needs_attention_and_is_clear():
    all_confirmed = permit_checklist(_trip([
        Permit(title="a", status="confirmed"), Permit(title="b", status="confirmed"),
    ]))
    assert all_confirmed.needs_attention_count == 0
    assert all_confirmed.is_clear

    mixed = permit_checklist(_trip([
        Permit(title="a", status="confirmed"), Permit(title="b", status="required"),
    ]))
    assert mixed.needs_attention_count == 1
    assert not mixed.is_clear


def test_checklist_is_clear_on_an_empty_trip():
    # No permits is not the same claim as "everything confirmed," but the
    # boolean itself reads the same way — a caller wanting "is there
    # anything to show" checks `.permits`, not `.is_clear` (documented on
    # `PermitChecklist.is_clear`).
    assert permit_checklist(_trip([])).is_clear
