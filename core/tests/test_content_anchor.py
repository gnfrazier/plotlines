"""Unit tests for `plotlines_core.content.anchor` (PRD FR106, FR110, Story O1)."""

import pytest

from plotlines_core.content.anchor import (
    ARC_STAGES,
    ROLE_KINDS,
    Anchor,
    AnchorProvenance,
    MediaRef,
    Polygon,
    ProvisionDetail,
    ResupplyInfo,
    Role,
    StationActivity,
    WaterSource,
)
from plotlines_core.trips.payload import Trip

# A closed square ring, wound counter-clockwise (canonical exterior winding).
_SQUARE_CCW = [
    [-105.28, 40.01], [-105.27, 40.01], [-105.27, 40.02], [-105.28, 40.02], [-105.28, 40.01],
]


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


# --- FR108, FR126 / O3 — polygon area geometry ---------------------------


def test_anchor_area_round_trips_as_a_polygon_feature():
    anchor = Anchor(
        coord=[-105.275, 40.015],
        area=Polygon(coordinates=[_SQUARE_CCW]),
        roles=[Role(kind="narrative")],
    )
    out = anchor.to_dict()
    assert out["area"] == {"type": "Polygon", "coordinates": [_SQUARE_CCW], "source": "authored"}


def test_anchor_with_no_area_omits_it_and_behaves_as_a_point():
    # O2's AC extended to polygons: an anchor with no area costs nothing.
    anchor = Anchor(coord=[0.0, 0.0], roles=[Role(kind="narrative")])
    assert anchor.to_dict()["area"] is None
    assert anchor.contains_point([0.0, 0.0]) is False


def test_polygon_ring_must_be_closed():
    open_ring = [[-105.28, 40.01], [-105.27, 40.01], [-105.27, 40.02], [-105.28, 40.02]]
    with pytest.raises(ValueError, match="not closed"):
        Polygon(coordinates=[open_ring]).to_dict()


def test_polygon_ring_needs_at_least_four_positions():
    with pytest.raises(ValueError, match="at least 4"):
        Polygon(coordinates=[[[0.0, 0.0], [1.0, 0.0], [0.0, 0.0]]]).to_dict()


def test_polygon_winding_is_normalised_not_rejected():
    # D37 — an Author's drawing order must not affect the stored/serialized
    # form; a clockwise exterior ring is silently reversed to canonical CCW.
    clockwise = list(reversed(_SQUARE_CCW))
    out = Polygon(coordinates=[clockwise]).to_dict()
    assert out["coordinates"] == [_SQUARE_CCW]


def test_polygon_rejects_invalid_source():
    with pytest.raises(ValueError, match="polygon source"):
        Polygon(coordinates=[_SQUARE_CCW], source="solved")


def test_polygon_contains_point_true_inside_false_outside_and_on_edge_deterministic():
    square = Polygon(coordinates=[_SQUARE_CCW])
    assert square.contains_point([-105.275, 40.015]) is True
    assert square.contains_point([-105.29, 40.015]) is False


def test_polygon_contains_point_respects_a_hole():
    outer = [[-105.30, 40.00], [-105.20, 40.00], [-105.20, 40.10], [-105.30, 40.10], [-105.30, 40.00]]
    hole = [[-105.27, 40.03], [-105.23, 40.03], [-105.23, 40.07], [-105.27, 40.07], [-105.27, 40.03]]
    donut = Polygon(coordinates=[outer, hole])
    assert donut.contains_point([-105.29, 40.01]) is True  # inside outer, outside hole
    assert donut.contains_point([-105.25, 40.05]) is False  # inside the hole


def test_anchor_area_serves_as_a_cluster_boundary_not_point_plus_radius():
    # FR108's AC in miniature: an Author placed the anchor's coord near one
    # edge of the district, and a point well inside the boundary but far
    # from that coord (further than any sane point-radius) is still "in."
    anchor = Anchor(
        coord=[-105.2799, 40.0101],
        area=Polygon(coordinates=[_SQUARE_CCW]),
        roles=[Role(kind="narrative")],
    )
    far_corner_but_inside = [-105.271, 40.019]
    assert anchor.contains_point(far_corner_but_inside) is True


def test_role_area_falls_back_to_anchor_area_then_none():
    anchor_area = Polygon(coordinates=[_SQUARE_CCW])
    anchor = Anchor(coord=[0.0, 0.0], area=anchor_area, roles=[
        Role(kind="narrative", id="r1"),
        Role(kind="provision", id="r2", area=Polygon(coordinates=[[
            [1.0, 1.0], [2.0, 1.0], [2.0, 2.0], [1.0, 2.0], [1.0, 1.0],
        ]])),
    ])
    narrative, provision = anchor.roles
    assert anchor.role_area(narrative) is anchor_area
    assert anchor.role_area(provision) is provision.area
    assert anchor.role_area(provision) is not anchor_area


def test_role_area_is_none_when_neither_role_nor_anchor_has_one():
    anchor = Anchor(coord=[0.0, 0.0], roles=[Role(kind="narrative", id="r1")])
    assert anchor.role_area(anchor.roles[0]) is None


# --- FR115 / O5 — hazard/technical-crux hard constraint ------------------


def test_role_hazard_defaults_to_false_and_is_always_written():
    role = Role(kind="narrative")
    out = role.to_dict()
    assert role.hazard is False
    assert out["hazard"] is False  # never pruned at False (mirrors polygon.source)


def test_role_hazard_paired_with_on_arrival_is_rejected():
    # FR115 is a hard constraint — "cannot be set otherwise by any Author" —
    # so the invalid combination is unrepresentable, not merely discouraged.
    with pytest.raises(ValueError, match="FR115"):
        Role(kind="narrative", hazard=True, reveal="on_arrival")


def test_role_hazard_with_no_reveal_or_always_visible_is_accepted():
    assert Role(kind="station", hazard=True).hazard is True
    assert Role(kind="station", hazard=True, reveal="always_visible").hazard is True


def test_role_hazard_is_orthogonal_to_kind():
    for kind in ROLE_KINDS:
        assert Role(kind=kind, hazard=True).to_dict()["hazard"] is True


# --- FR38 / O6 — arc stage on a role -------------------------------------


def test_role_arc_defaults_to_none_and_is_omitted():
    role = Role(kind="narrative")
    assert role.arc is None
    assert role.to_dict()["arc"] is None


def test_role_arc_round_trips_for_every_stage():
    for stage in ARC_STAGES:
        role = Role(kind="narrative", arc=stage)
        assert role.to_dict()["arc"] == stage


def test_role_arc_is_orthogonal_to_kind():
    # The crux of a day's story can land on any role kind — a station role
    # (a climb) is as valid a climax as a narrative one (a viewpoint).
    for kind in ROLE_KINDS:
        assert Role(kind=kind, arc="climax").to_dict()["arc"] == "climax"


def test_invalid_arc_stage_is_rejected():
    with pytest.raises(ValueError, match="arc stage"):
        Role(kind="narrative", arc="denouement")


def test_role_arc_coexists_with_hazard_and_reveal():
    # FR38 is orthogonal to FR115/FR114 — a hazard role can carry an arc
    # stage (the crux often *is* the technical crux), and arc never loosens
    # the hazard/on_arrival constraint.
    role = Role(kind="station", hazard=True, arc="crux")
    out = role.to_dict()
    assert out["hazard"] is True
    assert out["arc"] == "crux"


def test_national_monument_narrative_role_carries_the_climax():
    # O6's worked case in miniature: the statue (narrative role) is the
    # climax; the restroom (provision role) carries no arc beat at all.
    anchor = Anchor(
        coord=[-105.27, 40.02],
        title="Independence Monument",
        roles=[
            Role(kind="narrative", reveal="on_arrival", arc="climax"),
            Role(kind="provision", reveal="always_visible"),
        ],
    )
    out = anchor.to_dict()
    by_kind = {r["kind"]: r for r in out["roles"]}
    assert by_kind["narrative"]["arc"] == "climax"
    assert by_kind["provision"]["arc"] is None


# --------------------------------------------------------------------------
# FR109, FR16b, FR24 / O4 — station activity on a station role
# --------------------------------------------------------------------------


def test_station_activity_round_trips_with_type_duration_gear_and_difficulty():
    role = Role(
        kind="station",
        activity=StationActivity(
            activity_type="climbing",
            expected_duration_s=3 * 3600.0,
            required_gear=["helmet", "harness", "rope"],
            difficulty="5.10c sport, 6 pitches",
        ),
    )
    out = role.to_dict()["activity"]
    assert out == {
        "activity_type": "climbing",
        "duration_s": 10800.0,
        "required_gear": ["helmet", "harness", "rope"],
        "difficulty": "5.10c sport, 6 pitches",
    }


def test_station_activity_is_omitted_when_absent_and_role_behaves_as_before():
    before = Role(kind="station").to_dict()
    assert before["activity"] is None  # pruned at the Trip level, absent on the wire


def test_activity_on_a_non_station_role_is_rejected():
    # FR109 — an activity belongs to a station role only.
    for kind in ("narrative", "provision"):
        with pytest.raises(ValueError, match="station role only"):
            Role(kind=kind, activity=StationActivity(activity_type="climbing"))


def test_activity_type_must_be_a_non_empty_string():
    for bad in ("", "   "):
        with pytest.raises(ValueError, match="non-empty string"):
            StationActivity(activity_type=bad)


def test_activity_duration_is_optional_and_rejects_negative_or_non_finite():
    assert StationActivity(activity_type="sauna").expected_duration_s is None
    with pytest.raises(ValueError, match="non-negative"):
        StationActivity(activity_type="sauna", expected_duration_s=-60.0)
    with pytest.raises(ValueError, match="non-finite"):
        StationActivity(activity_type="sauna", expected_duration_s=float("inf"))


def test_activity_gear_and_difficulty_default_empty_and_prune():
    out = Role(
        kind="station", activity=StationActivity(activity_type="hot_spring")
    ).to_dict()["activity"]
    assert out == {
        "activity_type": "hot_spring",
        "duration_s": None,
        "required_gear": None,
        "difficulty": None,
    }


def test_activity_type_is_a_free_string_not_bound_to_the_registry():
    # FR144 posture — a plugin may name an activity this build has never
    # heard of, and the model stores it without complaint (the registry
    # supplies labels/defaults for the known set, it is not a gate).
    role = Role(kind="station", activity=StationActivity(activity_type="via_ferrata"))
    assert role.to_dict()["activity"]["activity_type"] == "via_ferrata"


def test_station_activity_coexists_with_hazard_and_arc_on_the_same_role():
    role = Role(
        kind="station",
        hazard=True,
        arc="crux",
        activity=StationActivity(activity_type="canyoneering", expected_duration_s=4 * 3600.0),
    )
    out = role.to_dict()
    assert out["hazard"] is True
    assert out["arc"] == "crux"
    assert out["activity"]["activity_type"] == "canyoneering"


# --------------------------------------------------------------------------
# FR25 / C9 — provision detail (water, resupply) on a provision role
# --------------------------------------------------------------------------


def test_provision_water_round_trips_potable():
    role = Role(kind="provision", provision=ProvisionDetail(water=WaterSource(potable=True)))
    assert role.to_dict()["provision"] == {"water": {"potable": True}, "resupply": None}


def test_provision_water_round_trips_filter_required():
    role = Role(kind="provision", provision=ProvisionDetail(water=WaterSource(potable=False)))
    assert role.to_dict()["provision"]["water"] == {"potable": False}


def test_provision_resupply_round_trips_hours_and_notes():
    role = Role(
        kind="provision",
        provision=ProvisionDetail(
            resupply=ResupplyInfo(hours="Mon-Sat 8-6", notes="Cash only, no cards")
        ),
    )
    out = role.to_dict()["provision"]["resupply"]
    assert out == {"hours": "Mon-Sat 8-6", "notes": "Cash only, no cards"}


def test_provision_detail_may_carry_both_water_and_resupply():
    # A trailhead store that also has a tap — one anchor, one provision role.
    detail = ProvisionDetail(
        water=WaterSource(potable=True), resupply=ResupplyInfo(hours="daylight hours"),
    )
    out = Role(kind="provision", provision=detail).to_dict()["provision"]
    assert out["water"] == {"potable": True}
    assert out["resupply"]["hours"] == "daylight hours"


def test_provision_detail_is_omitted_when_absent():
    before = Role(kind="provision").to_dict()
    assert before["provision"] is None


def test_provision_detail_on_a_non_provision_role_is_rejected():
    for kind in ("narrative", "station"):
        with pytest.raises(ValueError, match="provision role only"):
            Role(kind=kind, provision=ProvisionDetail(water=WaterSource(potable=True)))


def test_empty_provision_detail_is_rejected():
    # Neither water nor resupply set is meaningless — nothing for an
    # itinerary or a checklist to show.
    with pytest.raises(ValueError, match="water/resupply"):
        ProvisionDetail()


def test_empty_resupply_info_is_rejected():
    with pytest.raises(ValueError, match="hours/notes"):
        ResupplyInfo()


def test_provision_detail_coexists_with_reveal_and_arc_on_the_same_role():
    role = Role(
        kind="provision",
        reveal="always_visible",
        arc="rising",
        provision=ProvisionDetail(water=WaterSource(potable=True)),
    )
    out = role.to_dict()
    assert out["reveal"] == "always_visible"
    assert out["arc"] == "rising"
    assert out["provision"]["water"]["potable"] is True


def test_trip_carries_anchors_and_prunes_when_empty():
    empty = Trip(title="Empty")
    assert "anchors" not in empty.to_dict()

    trip = Trip(title="Has anchors", anchors=[
        Anchor(coord=[0.0, 0.0], roles=[Role(kind="narrative")]),
    ])
    out = trip.to_dict()
    assert len(out["anchors"]) == 1
    assert out["anchors"][0]["roles"][0]["kind"] == "narrative"
