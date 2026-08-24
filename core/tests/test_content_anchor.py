"""Unit tests for `plotlines_core.content.anchor` (PRD FR106, FR110, Story O1)."""

import pytest

from plotlines_core.content.anchor import Anchor, AnchorProvenance, MediaRef, Role
from plotlines_core.trips.payload import Trip


def test_anchor_round_trips_with_one_role():
    anchor = Anchor(coord=[-105.2705, 40.0150], title="Independence Monument",
                     roles=[Role(kind="narrative")])
    out = anchor.to_dict()
    assert out["coord"] == [-105.2705, 40.015]
    assert out["title"] == "Independence Monument"
    assert len(out["roles"]) == 1
    assert out["roles"][0]["kind"] == "narrative"


def test_national_monument_is_one_anchor_two_roles_one_pin():
    # FR106's worked case: narrative + provision on the SAME anchor, not two.
    anchor = Anchor(
        coord=[-105.27, 40.02],
        title="Independence Monument",
        roles=[
            Role(kind="narrative", reveal="on_arrival", note="The statue's story."),
            Role(kind="provision", reveal="always_visible", note="Restrooms, water."),
        ],
    )
    out = anchor.to_dict()
    assert len(out["roles"]) == 2
    kinds = {r["kind"] for r in out["roles"]}
    assert kinds == {"narrative", "provision"}
    # One id, one coord — one pin, one arrival — regardless of the role count.
    assert out["id"] == anchor.id
    assert out["coord"] == [-105.27, 40.02]


def test_anchor_without_a_role_is_rejected():
    # FR106: an anchor with no role is exactly the "type field" bug the role-set
    # design exists to prevent — must not silently serialize.
    anchor = Anchor(coord=[0.0, 0.0], roles=[])
    with pytest.raises(ValueError, match="at least one role"):
        anchor.to_dict()


def test_reveal_and_content_may_be_left_unset_at_promotion():
    # O1's AC: "per-role reveal policy and content set here or later."
    anchor = Anchor(coord=[0.0, 0.0], roles=[Role(kind="station")])
    out = anchor.to_dict()
    role = out["roles"][0]
    assert "reveal" not in role or role["reveal"] is None
    assert role["title"] is None
    assert role["note"] is None
    assert role["media"] is None


def test_invalid_role_kind_is_rejected():
    with pytest.raises(ValueError, match="role kind"):
        Role(kind="scenic")


def test_invalid_reveal_policy_is_rejected():
    with pytest.raises(ValueError, match="reveal policy"):
        Role(kind="narrative", reveal="sometimes")


def test_provenance_is_copied_not_a_reference():
    # ARCH §4.2/P10: source_id is carried for same-session dedup only, never
    # dereferenced — this test only asserts it is a plain copied value.
    anchor = Anchor(
        coord=[0.0, 0.0],
        roles=[Role(kind="provision")],
        provenance=AnchorProvenance(kind="candidate", source_id="cand-1",
                                     layer="amenity", tags={"amenity": "toilets"}),
    )
    out = anchor.to_dict()
    assert out["provenance"] == {
        "kind": "candidate", "source_id": "cand-1",
        "layer": "amenity", "tags": {"amenity": "toilets"},
    }


def test_invalid_provenance_kind_is_rejected():
    with pytest.raises(ValueError, match="provenance kind"):
        AnchorProvenance(kind="guess")


def test_role_media_serializes_via_media_ref():
    role = Role(kind="narrative", media=[MediaRef(kind="audio", path="audio/statue.mp3")])
    out = role.to_dict()
    assert out["media"] == [{
        "id": role.media[0].id, "kind": "audio", "path": "audio/statue.mp3",
        "caption": None, "bytes": None, "duration_s": None,
    }]


def test_anchor_coord_is_rounded_to_seven_decimals():
    anchor = Anchor(coord=[-105.270512345, 40.015098765], roles=[Role(kind="station")])
    out = anchor.to_dict()
    assert out["coord"] == [-105.2705123, 40.0150988]


def test_anchor_coord_rejects_non_finite():
    anchor = Anchor(coord=[float("nan"), 0.0], roles=[Role(kind="station")])
    with pytest.raises(ValueError, match="non-finite"):
        anchor.to_dict()


def test_role_offset_round_trips_and_is_rounded():
    # FR107 / O2: the overlook 400 m up the spur from the parking lot.
    role = Role(kind="narrative", coord=[-105.270512345, 40.020098765])
    out = role.to_dict()
    assert out["coord"] == [-105.2705123, 40.0200988]


def test_role_with_no_offset_omits_coord():
    # O2's AC: "an anchor with no offsets behaves exactly as a single point."
    role = Role(kind="narrative")
    assert role.to_dict()["coord"] is None


def test_role_offset_rejects_non_finite():
    role = Role(kind="narrative", coord=[float("nan"), 0.0])
    with pytest.raises(ValueError, match="non-finite"):
        role.to_dict()


def test_role_geometry_falls_back_to_anchor_coord_when_role_has_no_offset():
    anchor = Anchor(coord=[-105.27, 40.02], roles=[Role(kind="narrative", id="r1")])
    assert anchor.role_geometry(anchor.roles[0]) == [-105.27, 40.02]


def test_role_geometry_uses_the_roles_own_offset_when_set():
    # FR107's worked case: parking-lot anchor, narrative role 400 m up a spur.
    anchor = Anchor(
        coord=[-105.27, 40.02],
        roles=[Role(kind="narrative", id="r1", coord=[-105.266, 40.024])],
    )
    assert anchor.role_geometry(anchor.roles[0]) == [-105.266, 40.024]


def test_anchor_with_no_role_offsets_behaves_as_a_single_point():
    # Every role geometry resolves to the anchor's own coord when no role
    # carries an offset — the "costs nothing" half of O2's AC.
    anchor = Anchor(
        coord=[0.0, 0.0],
        roles=[Role(kind="narrative"), Role(kind="provision")],
    )
    assert all(anchor.role_geometry(r) == [0.0, 0.0] for r in anchor.roles)


def test_trip_carries_anchors_and_prunes_when_empty():
    empty = Trip(title="Empty")
    assert "anchors" not in empty.to_dict()

    trip = Trip(title="Has anchors", anchors=[
        Anchor(coord=[0.0, 0.0], roles=[Role(kind="narrative")]),
    ])
    out = trip.to_dict()
    assert len(out["anchors"]) == 1
    assert out["anchors"][0]["roles"][0]["kind"] == "narrative"
