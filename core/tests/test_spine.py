"""Unit tests for `plotlines_core.trips.spine` — Story E3 / A0, A0a (FR39,
FR117, FR118), ARCH §7.7.

E3's AC, taken in order:

  * compose mode is a first-class posture, not a variant — the promoted anchors
    are the spine, the engine reaches them (`spine_waypoints`), and A0a governs
    the distance conversation (`DistanceOutcome`);
  * the trip presents the places as its organizing structure in the itinerary
    (`compose_itinerary`), the cue sheet (`spine_cues`), and the recap
    (`recap_spine`).
"""

import pytest

from plotlines_core.content.anchor import Anchor, Role
from plotlines_core.trips.payload import Hazard, RouteMetrics, Segment, TargetDistance
from plotlines_core.trips.spine import (
    COMPOSE,
    DISPOSITIONS,
    EXPLORE,
    PLANNING_MODES,
    DistanceOutcome,
    assert_planning_mode,
    compose_itinerary,
    distance_outcome,
    planning_mode_of,
    recap_spine,
    spine_cues,
    spine_legs_from_polyline,
    spine_waypoints,
)


# --- fixtures -----------------------------------------------------------------


def _anchor(lon: float, lat: float, *, title: str, roles: list[Role] | None = None) -> Anchor:
    return Anchor(coord=[lon, lat], title=title,
                  roles=roles or [Role(kind="narrative")])


def _segment(distance_m: float | None, *, mode: str = "hiking",
             target: TargetDistance | None = None, arc: str | None = None) -> Segment:
    return Segment(
        mode=mode, shape="point_to_point", start=[0.0, 0.0], end=[0.1, 0.1],
        metrics=None if distance_m is None else RouteMetrics(distance_m=distance_m),
        target_distance=target, arc_stage=arc,
    )


def _spine_of_three() -> tuple[list[Anchor], list[Segment]]:
    anchors = [
        _anchor(-105.30, 40.00, title="Trailhead",
                roles=[Role(kind="provision")]),
        _anchor(-105.25, 40.02, title="The old mine",
                roles=[Role(kind="narrative", arc="rising")]),
        _anchor(-105.20, 40.05, title="Summit",
                roles=[Role(kind="narrative", arc="climax")]),
    ]
    segments = [_segment(4_000.0), _segment(6_000.0)]
    return anchors, segments


# --- planning mode ----------------------------------------------------------


def test_the_two_planning_modes_are_explore_and_compose():
    assert PLANNING_MODES == (EXPLORE, COMPOSE) == ("explore", "compose")


def test_assert_planning_mode_rejects_anything_else():
    assert assert_planning_mode("compose") == "compose"
    with pytest.raises(ValueError, match="planning mode"):
        assert_planning_mode("wander")


def test_a_passage_with_no_target_is_compose_one_with_a_banded_target_is_explore():
    """ARCH §7.7 — the posture is readable off the passage: distance is an
    output in compose (`target_distance is None`), an input in explore."""
    assert planning_mode_of(_segment(5_000.0)) == COMPOSE
    banded = _segment(5_000.0, target=TargetDistance(value_m=5_000.0, min_m=4_500.0,
                                                     max_m=5_500.0))
    assert planning_mode_of(banded) == EXPLORE


# --- A0a / FR118: DistanceOutcome -----------------------------------------


def test_pure_compose_reports_length_with_no_target_and_only_accept():
    outcome = distance_outcome([_segment(4_000.0), _segment(6_000.0)])
    assert outcome.realised_m == 10_000.0
    assert outcome.target_m is None
    assert outcome.deviation_m is None
    assert outcome.deviation_frac is None
    # No target to reconcile — the only move is to accept what the places produced.
    assert outcome.dispositions == ("accept",)


def test_a_target_present_quantifies_the_miss_and_offers_every_disposition():
    outcome = distance_outcome([_segment(12_000.0)], target_m=10_000.0)
    assert outcome.deviation_m == 2_000.0
    assert outcome.deviation_frac == 0.2
    assert outcome.dispositions == DISPOSITIONS == ("drop", "defer", "split", "accept")


def test_a_composed_route_shorter_than_intended_gives_a_negative_deviation():
    outcome = distance_outcome([_segment(7_500.0)], target_m=10_000.0)
    assert outcome.deviation_m == -2_500.0
    assert outcome.deviation_frac == -0.25


def test_distance_deviation_is_never_a_conflict_or_an_error():
    """ARCH §7.7's hard rule: compose-mode deviation must not route through
    `/segments/diagnose` or M13. The flags say so whatever the miss."""
    wild = distance_outcome([_segment(90_000.0)], target_m=10_000.0)
    assert wild.is_conflict is False
    assert wild.is_error is False
    assert wild.to_dict()["is_conflict"] is False
    assert wild.to_dict()["is_error"] is False
    # And they are not constructor inputs an instance can be born with.
    with pytest.raises(TypeError):
        DistanceOutcome(realised_m=1.0, is_conflict=True)  # type: ignore[call-arg]


def test_segments_with_no_solved_metrics_contribute_nothing_to_the_length():
    outcome = distance_outcome([_segment(4_000.0), _segment(None), _segment(6_000.0)])
    assert outcome.realised_m == 10_000.0


def test_outcome_to_dict_is_tagged_compose():
    assert distance_outcome([_segment(5_000.0)]).to_dict()["planning_mode"] == "compose"


def test_a_zero_target_does_not_divide_by_zero():
    outcome = distance_outcome([_segment(5_000.0)], target_m=0.0)
    assert outcome.deviation_frac is None
    assert outcome.deviation_m == 5_000.0


# --- the engine reaches the places: spine_waypoints ----------------------


def test_spine_waypoints_splits_start_via_end_and_swaps_to_lat_lon():
    anchors, _ = _spine_of_three()
    start, via, end = spine_waypoints(anchors)
    assert start == (40.00, -105.30)          # (lat, lon), swapped from [lon, lat]
    assert via == [(40.02, -105.25)]          # the interior anchors
    assert end == (40.05, -105.20)


def test_a_two_anchor_spine_has_no_via_nodes():
    anchors, _ = _spine_of_three()
    start, via, end = spine_waypoints(anchors[:2])
    assert via == []
    assert (start, end) == ((40.00, -105.30), (40.02, -105.25))


def test_spine_waypoints_needs_at_least_two_places():
    with pytest.raises(ValueError, match="at least two places"):
        spine_waypoints([_anchor(-105.0, 40.0, title="lonely")])


# --- places as the organizing structure: compose_itinerary --------------


def test_the_itinerary_is_places_first_passages_between():
    anchors, segments = _spine_of_three()
    itin = compose_itinerary(anchors, segments)

    assert itin.planning_mode == "compose"
    assert itin.spine == [a.id for a in anchors]          # order preserved
    assert [s.title for s in itin.stops] == ["Trailhead", "The old mine", "Summit"]
    # one fewer leg than stops, each sitting between two of them
    assert [leg.order for leg in itin.legs] == [0, 1]
    assert len(itin.legs) == len(itin.stops) - 1


def test_stops_carry_cumulative_distance_along_the_spine():
    anchors, segments = _spine_of_three()
    itin = compose_itinerary(anchors, segments)
    assert [s.distance_along_m for s in itin.stops] == [0.0, 4_000.0, 10_000.0]


def test_a_stop_past_an_unrouted_passage_is_unmeasured_never_zero():
    anchors, segments = _spine_of_three()
    segments[0] = _segment(None)  # first passage never solved
    itin = compose_itinerary(anchors, segments)
    assert [s.distance_along_m for s in itin.stops] == [0.0, None, None]


def test_the_itinerary_surfaces_role_kinds_and_arc_beats_per_place():
    anchors, segments = _spine_of_three()
    itin = compose_itinerary(anchors, segments)
    assert itin.stops[0].roles == ["provision"]
    assert itin.stops[0].arc_stages == []
    assert itin.stops[1].roles == ["narrative"]
    assert itin.stops[1].arc_stages == ["rising"]
    assert itin.stops[2].arc_stages == ["climax"]


def test_role_kinds_and_arc_beats_come_out_in_canonical_order():
    anchor = _anchor(-105.0, 40.0, title="Everything", roles=[
        Role(kind="station"),
        Role(kind="narrative", arc="climax"),
        Role(kind="provision"),
        Role(kind="narrative", arc="exposition"),
    ])
    itin = compose_itinerary([anchor, _anchor(-105.1, 40.1, title="b")], [_segment(1_000.0)])
    assert itin.stops[0].roles == ["narrative", "provision", "station"]
    assert itin.stops[0].arc_stages == ["exposition", "climax"]


def test_a_hazard_role_flags_the_stop():
    hot = _anchor(-105.0, 40.0, title="Ford", roles=[Role(kind="provision", hazard=True)])
    itin = compose_itinerary([hot, _anchor(-105.1, 40.1, title="b")], [_segment(1_000.0)])
    assert itin.stops[0].hazard is True
    assert itin.stops[1].hazard is False


def test_an_on_arrival_narrative_role_marks_the_stop_for_print_and_web():
    """FR116 — the paper copy shows the stop's shape but not its held content."""
    held = _anchor(-105.0, 40.0, title="The reveal",
                   roles=[Role(kind="narrative", reveal="on_arrival")])
    plain = _anchor(-105.1, 40.1, title="Open",
                    roles=[Role(kind="narrative", reveal="always_visible")])
    itin = compose_itinerary([held, plain], [_segment(1_000.0)])
    assert itin.stops[0].has_unrevealed_narrative is True
    assert itin.stops[1].has_unrevealed_narrative is False


def test_the_leg_records_its_mode_arc_and_planning_posture():
    anchors, _ = _spine_of_three()
    segments = [
        _segment(4_000.0, mode="hiking", arc="rising"),
        _segment(6_000.0, mode="cycling",
                 target=TargetDistance(value_m=6_000.0, min_m=5_000.0, max_m=7_000.0)),
    ]
    itin = compose_itinerary(anchors, segments)
    assert (itin.legs[0].mode, itin.legs[0].arc_stage) == ("hiking", "rising")
    assert itin.legs[0].planning_mode == "compose"
    assert itin.legs[1].planning_mode == "explore"   # that passage carries a band


def test_a_leg_carries_its_passage_hazards_fr27():
    """C11 — a hazard on a passage is highlighted on the itinerary alongside
    the map, elevation profile and cue sheet. Never reveal-gated (FR115)."""
    anchors, _ = _spine_of_three()
    hazard = Hazard(severity="high", title="Cattle guard", required_gear=["gloves"])
    segments = [
        Segment(mode="hiking", shape="point_to_point", start=[0.0, 0.0], end=[0.1, 0.1],
                metrics=RouteMetrics(distance_m=4_000.0), hazards=[hazard]),
        _segment(6_000.0),
    ]
    itin = compose_itinerary(anchors, segments)
    assert itin.legs[0].hazards == [hazard.to_dict()]
    assert itin.legs[1].hazards == []
    assert itin.to_dict()["legs"][0]["hazards"][0]["severity"] == "high"
    assert itin.to_dict()["legs"][1]["hazards"] is None


def test_the_itinerary_carries_its_distance_outcome():
    anchors, segments = _spine_of_three()
    itin = compose_itinerary(anchors, segments, target_m=8_000.0)
    assert itin.distance.realised_m == 10_000.0
    assert itin.distance.deviation_m == 2_000.0
    assert itin.to_dict()["distance"]["planning_mode"] == "compose"


def test_a_spine_needs_at_least_two_places():
    with pytest.raises(ValueError, match="at least two places"):
        compose_itinerary([_anchor(-105.0, 40.0, title="one")], [])


def test_the_passage_count_must_match_the_gaps_between_places():
    anchors, _ = _spine_of_three()
    with pytest.raises(ValueError, match="connecting passages"):
        compose_itinerary(anchors, [_segment(4_000.0)])          # need 2, gave 1


def test_a_roleless_anchor_is_rejected_before_it_reaches_the_itinerary():
    bad = Anchor(coord=[-105.0, 40.0], title="typeless", roles=[])
    with pytest.raises(ValueError, match="at least one role"):
        compose_itinerary([bad, _anchor(-105.1, 40.1, title="b")], [_segment(1_000.0)])


def test_an_unknown_planning_mode_is_rejected():
    anchors, segments = _spine_of_three()
    with pytest.raises(ValueError, match="planning mode"):
        compose_itinerary(anchors, segments, planning_mode="wander")


def test_the_itinerary_never_reorders_the_authors_spine():
    anchors, segments = _spine_of_three()
    reversed_anchors = list(reversed(anchors))
    itin = compose_itinerary(reversed_anchors, segments)
    assert [s.title for s in itin.stops] == ["Summit", "The old mine", "Trailhead"]


# --- the recap axis: recap_spine ---------------------------------------


def test_recap_spine_lists_plot_points_in_order():
    anchors, segments = _spine_of_three()
    itin = compose_itinerary(anchors, segments)
    recap = recap_spine(itin)
    # Trailhead is provision-only — logistics, not story — so it is off the axis.
    assert [e.title for e in recap] == ["The old mine", "Summit"]
    assert [e.order for e in recap] == [0, 1]
    assert [e.arc_stages for e in recap] == [["rising"], ["climax"]]
    assert [e.distance_along_m for e in recap] == [4_000.0, 10_000.0]


def test_a_stop_with_an_arc_beat_but_no_narrative_role_still_counts_as_a_plot_point():
    beat = _anchor(-105.0, 40.0, title="The crux pitch",
                   roles=[Role(kind="station", arc="crux")])
    plain = _anchor(-105.1, 40.1, title="Car park", roles=[Role(kind="provision")])
    itin = compose_itinerary([beat, plain], [_segment(1_000.0)])
    recap = recap_spine(itin)
    assert [e.title for e in recap] == ["The crux pitch"]


def test_recap_entries_serialize():
    anchors, segments = _spine_of_three()
    recap = recap_spine(compose_itinerary(anchors, segments))
    assert recap[0].to_dict() == {
        "order": 0, "anchor_id": anchors[1].id, "title": "The old mine",
        "arc_stages": ["rising"], "distance_along_m": 4_000.0,
    }


# --- the cue sheet: spine_cues ---------------------------------------


def test_spine_cues_places_one_cue_per_measured_stop():
    anchors, segments = _spine_of_three()
    itin = compose_itinerary(anchors, segments)
    cues = spine_cues(itin)
    assert [c.kind for c in cues] == ["start", "node", "finish"]
    assert [c.distance_along_m for c in cues] == [0.0, 4_000.0, 10_000.0]
    assert [c.instruction for c in cues] == ["Trailhead", "The old mine", "Summit"]
    assert [c.ref_id for c in cues] == [a.id for a in anchors]
    assert [c.sequence for c in cues] == [0, 1, 2]


def test_spine_cues_can_start_from_an_offset_sequence():
    anchors, segments = _spine_of_three()
    cues = spine_cues(compose_itinerary(anchors, segments), start_sequence=10)
    assert [c.sequence for c in cues] == [10, 11, 12]


def test_spine_cues_skips_an_unmeasured_stop_rather_than_guessing_zero():
    anchors, segments = _spine_of_three()
    segments[1] = _segment(None)  # summit never gets a distance
    cues = spine_cues(compose_itinerary(anchors, segments))
    assert [c.instruction for c in cues] == ["Trailhead", "The old mine"]
    # The surviving cues renumber contiguously.
    assert [c.sequence for c in cues] == [0, 1]


def test_spine_cues_serialize_through_the_payload_cue():
    anchors, segments = _spine_of_three()
    cue = spine_cues(compose_itinerary(anchors, segments))[1].to_dict()
    assert cue["kind"] == "node"
    assert cue["distance_along_m"] == 4_000.0
    assert cue["ref_id"] == anchors[1].id


# --- client day -> spine legs: spine_legs_from_polyline -----------------


# A straight three-point spine along the 40th parallel; at lat 40, 0.05 deg
# of longitude is ~4.26 km.
_PL_A = [-105.30, 40.00]
_PL_B = [-105.25, 40.00]
_PL_C = [-105.20, 40.00]


def _pl_anchors() -> list[Anchor]:
    return [
        _anchor(_PL_A[0], _PL_A[1], title="A"),
        _anchor(_PL_B[0], _PL_B[1], title="B"),
        _anchor(_PL_C[0], _PL_C[1], title="C"),
    ]


def test_one_leg_per_consecutive_anchor_pair():
    legs = spine_legs_from_polyline(_pl_anchors(), [_PL_A, _PL_B, _PL_C], mode="hiking")
    assert len(legs) == 2
    assert all(leg.mode == "hiking" and leg.shape == "point_to_point" for leg in legs)
    assert legs[0].start == _PL_A and legs[0].end == _PL_B
    assert legs[1].start == _PL_B and legs[1].end == _PL_C


def test_leg_distance_is_the_polyline_span_between_the_two_anchors():
    legs = spine_legs_from_polyline(_pl_anchors(), [_PL_A, _PL_B, _PL_C], mode="hiking")
    assert legs[0].metrics is not None
    assert legs[0].metrics.distance_m == pytest.approx(4_260, abs=40)
    assert legs[1].metrics.distance_m == pytest.approx(4_260, abs=40)


def test_the_legs_feed_compose_itinerary_directly():
    anchors = _pl_anchors()
    legs = spine_legs_from_polyline(anchors, [_PL_A, _PL_B, _PL_C], mode="hiking")
    itin = compose_itinerary(anchors, legs)
    assert itin.spine == [a.id for a in anchors]
    assert itin.stops[-1].distance_along_m == pytest.approx(8_520, abs=80)


def test_no_polyline_yields_metric_less_legs():
    legs = spine_legs_from_polyline(_pl_anchors(), None, mode="cycling")
    assert [leg.metrics for leg in legs] == [None, None]
    # and the itinerary then degrades to "unmeasured, never zero"
    itin = compose_itinerary(_pl_anchors(), legs)
    assert [s.distance_along_m for s in itin.stops] == [0.0, None, None]


def test_a_one_or_zero_point_polyline_is_treated_as_no_polyline():
    legs = spine_legs_from_polyline(_pl_anchors(), [_PL_A], mode="hiking")
    assert [leg.metrics for leg in legs] == [None, None]


def test_spine_legs_needs_at_least_two_places():
    with pytest.raises(ValueError, match="at least two places"):
        spine_legs_from_polyline([_anchor(-105.0, 40.0, title="lonely")], None, mode="hiking")


def test_anchors_out_of_polyline_order_never_produce_a_negative_leg():
    # C then A along the polyline, but the spine lists A -> C: the span clamps
    # to zero rather than going negative.
    legs = spine_legs_from_polyline(
        [_anchor(_PL_C[0], _PL_C[1], title="C"), _anchor(_PL_A[0], _PL_A[1], title="A")],
        [_PL_A, _PL_B, _PL_C],
        mode="hiking",
    )
    assert legs[0].metrics is not None
    assert legs[0].metrics.distance_m >= 0.0
