"""Unit tests for `plotlines_core.trips.compose` (FR11/FR19/FR38, Stories
B2/C3/O6).

Two stories' worth, kept in one file because they exercise one function:

  * O6 — day composition may close a day at a resolution-stage anchor rather
    than only at a distance threshold, plus the `Segment.arc_stage` round trip
    it depends on.
  * B2 (FR11) — a day is an *ordered* sequence of passages, and the composer
    owns the adjacency measurement: each transition's `gap_m` and the warning
    flag above the threshold. Left uncovered when O6 was built (that story's
    header called it out of scope); it is this story's whole subject.
"""

import pytest

from plotlines_core.trips.compose import compose_day, haversine_m, split_trip
from plotlines_core.trips.payload import (
    Day, DEFAULT_GAP_WARN_M, LineString, Node, RouteMetrics, Segment, Transition,
)


def _segment(distance_m: float, *, nodes: list[Node] | None = None) -> Segment:
    return Segment(
        mode="hiking", shape="point_to_point", start=[0.0, 0.0], end=[0.0, 0.1],
        metrics=RouteMetrics(distance_m=distance_m), nodes=nodes or [],
    )


def _resolution_node(distance_along_m: float) -> Node:
    return Node(kind="poi", coord=[0.0, 0.1], distance_along_m=distance_along_m,
                arc_stage="resolution")


# --- Segment.arc_stage — plain field round trip ---------------------------


def test_segment_arc_stage_defaults_to_none_and_is_omitted():
    segment = _segment(1000.0)
    assert segment.arc_stage is None
    assert segment.to_dict()["arc_stage"] is None


def test_segment_arc_stage_round_trips():
    segment = _segment(1000.0)
    segment.arc_stage = "rising"
    assert segment.to_dict()["arc_stage"] == "rising"


# --- FR38 / O6 — a day may close at a resolution-stage anchor -------------


def test_short_day_without_resolution_node_breaches_the_min():
    day = compose_day([_segment(10_000.0)], [], index=1)
    trip = split_trip([day], limits={"hiking": {"min_m": 20_000.0}})
    breaches = trip.days[0].metrics.limit_breaches
    assert len(breaches) == 1
    assert breaches[0].bound == "min"


def test_short_day_ending_at_resolution_anchor_is_exempt_from_min_breach():
    segment = _segment(10_000.0, nodes=[_resolution_node(10_000.0)])
    day = compose_day([segment], [], index=1)
    trip = split_trip([day], limits={"hiking": {"min_m": 20_000.0}})
    assert trip.days[0].metrics.limit_breaches == []


def test_resolution_exemption_does_not_excuse_a_max_breach():
    # Closing the story early is fine; running long past the band is still
    # flagged — the arc doesn't excuse an over-length day.
    segment = _segment(50_000.0, nodes=[_resolution_node(50_000.0)])
    day = compose_day([segment], [], index=1)
    trip = split_trip([day], limits={"hiking": {"min_m": 20_000.0, "max_m": 40_000.0}})
    breaches = trip.days[0].metrics.limit_breaches
    assert len(breaches) == 1
    assert breaches[0].bound == "max"


def test_resolution_node_only_exempts_when_it_is_the_terminal_node():
    # A resolution beat earlier on the route doesn't make the day's actual
    # end a deliberate close — only the last node (by distance) counts.
    segment = _segment(10_000.0, nodes=[
        _resolution_node(1_000.0),
        Node(kind="poi", coord=[0.0, 0.1], distance_along_m=10_000.0, arc_stage="rising"),
    ])
    day = compose_day([segment], [], index=1)
    trip = split_trip([day], limits={"hiking": {"min_m": 20_000.0}})
    breaches = trip.days[0].metrics.limit_breaches
    assert len(breaches) == 1
    assert breaches[0].bound == "min"


def test_resolution_node_with_no_distance_along_is_still_the_terminal_when_alone():
    # A node that never got a distance stamped still closes the day if it's
    # the only node — the conservative "unpositioned sorts first" rule in
    # `_ends_at_resolution` doesn't apply when there's nothing to sort against.
    segment = _segment(10_000.0, nodes=[
        Node(kind="poi", coord=[0.0, 0.1], arc_stage="resolution"),
    ])
    day = compose_day([segment], [], index=1)
    trip = split_trip([day], limits={"hiking": {"min_m": 20_000.0}})
    assert trip.days[0].metrics.limit_breaches == []


def test_day_with_no_nodes_is_not_exempt():
    day = compose_day([_segment(10_000.0)], [], index=1)
    trip = split_trip([day], limits={"hiking": {"min_m": 20_000.0}})
    breaches = trip.days[0].metrics.limit_breaches
    assert len(breaches) == 1
    assert breaches[0].bound == "min"


def test_rest_day_with_no_segments_is_not_exempt_and_has_no_breach():
    day = compose_day([], [], index=1, kind="rest")
    trip = split_trip([day], limits={"hiking": {"min_m": 20_000.0}})
    assert trip.days[0].metrics.limit_breaches == []


# --- FR11 / B2 — passage order and the adjacency gap ----------------------


def _leg(id_: str, start: list[float], end: list[float], mode: str = "cycling") -> Segment:
    return Segment(id=id_, mode=mode, shape="point_to_point", start=start, end=end)


def test_the_default_gap_threshold_is_500_m():
    """FR11's "a set distance apart", and the PRD's own worked example."""
    assert DEFAULT_GAP_WARN_M == 500.0


def test_a_transition_carries_the_measured_gap_and_both_modes():
    ride = _leg("s1", [-105.30, 40.00], [-105.29, 40.00], "cycling")
    paddle = _leg("s2", [-105.29, 40.00], [-105.25, 40.00], "paddling")
    transition = Transition(from_segment_id="s1", to_segment_id="s2")

    day = compose_day([ride, paddle], [transition])

    assert day.transitions[0].gap_m == 0.0
    assert day.transitions[0].gap_warning is False
    # Modes are filled in from the segments themselves — an Author never has
    # to restate what the two legs already say.
    assert day.transitions[0].from_mode == "cycling"
    assert day.transitions[0].to_mode == "paddling"


def test_endpoints_further_apart_than_the_threshold_warn():
    ride = _leg("s1", [-105.30, 40.00], [-105.30, 40.00])
    hike = _leg("s2", [-105.29, 40.00], [-105.25, 40.00], "hiking")

    day = compose_day([ride, hike], [Transition(from_segment_id="s1", to_segment_id="s2")])

    assert day.transitions[0].gap_warning is True
    assert day.transitions[0].gap_m == pytest.approx(852.0, abs=5.0)


def test_the_threshold_is_exclusive_and_configurable():
    ride = _leg("s1", [-105.30, 40.00], [-105.30, 40.00])
    hike = _leg("s2", [-105.29, 40.00], [-105.25, 40.00], "hiking")

    def warned(gap_warn_m: float) -> bool:
        day = compose_day([ride, hike],
                          [Transition(from_segment_id="s1", to_segment_id="s2")],
                          gap_warn_m=gap_warn_m)
        return day.transitions[0].gap_warning

    gap = haversine_m([-105.30, 40.00], [-105.29, 40.00])
    assert warned(gap) is False  # "more than", not "at least"
    assert warned(gap - 1.0) is True
    assert warned(2000.0) is False


def test_the_gap_is_measured_from_the_solved_geometry_when_there_is_one():
    """The authored endpoint is where the Author pointed; the geometry's last
    vertex is where the route actually comes out. The second is the one a
    Character stands on."""
    ride = Segment(
        id="s1", mode="cycling", shape="point_to_point",
        start=[-105.30, 40.00], end=[-105.30, 40.00],
        geometry=LineString(coordinates=[[-105.30, 40.00], [-105.29, 40.00]]),
    )
    hike = _leg("s2", [-105.29, 40.00], [-105.25, 40.00], "hiking")

    day = compose_day([ride, hike], [Transition(from_segment_id="s1", to_segment_id="s2")])

    # Measured against the geometry's tail, which meets the hike exactly —
    # against the authored `end` this would have been an 852 m gap.
    assert day.transitions[0].gap_m == 0.0
    assert day.transitions[0].gap_warning is False


def test_a_transition_joining_non_adjacent_passages_is_rejected():
    """FR11 — the order *is* the day. A transition that does not sit between
    two neighbours describes a sequence the day does not have, and composing
    it anyway would produce a document no surface could render honestly."""
    legs = [_leg(f"s{i}", [-105.30, 40.00], [-105.29, 40.00]) for i in (1, 2, 3)]
    with pytest.raises(ValueError, match="non-adjacent"):
        compose_day(legs, [Transition(from_segment_id="s1", to_segment_id="s3")])


def test_a_transition_referencing_a_passage_from_another_day_is_rejected():
    legs = [_leg("s1", [-105.30, 40.00], [-105.29, 40.00])]
    with pytest.raises(ValueError, match="not in this day"):
        compose_day(legs, [Transition(from_segment_id="s1", to_segment_id="elsewhere")])


def test_reordering_the_same_passages_re_measures_the_gaps():
    """The composer measures against the segments it is actually given, so the
    same three legs in a different order produce different warnings — which is
    what makes B2's reorder meaningful rather than cosmetic."""
    a = _leg("a", [-105.30, 40.00], [-105.30, 40.00])
    b = _leg("b", [-105.29, 40.00], [-105.29, 40.00])
    c = _leg("c", [-105.30, 40.00], [-105.30, 40.00])

    forward = compose_day([a, b, c], [
        Transition(from_segment_id="a", to_segment_id="b"),
        Transition(from_segment_id="b", to_segment_id="c"),
    ])
    assert [t.gap_warning for t in forward.transitions] == [True, True]

    swapped = compose_day([a, c, b], [
        Transition(from_segment_id="a", to_segment_id="c"),
        Transition(from_segment_id="c", to_segment_id="b"),
    ])
    assert [t.gap_warning for t in swapped.transitions] == [False, True]


def test_an_unpositioned_passage_leaves_the_gap_unmeasured_never_zero():
    a = Segment(id="a", mode="cycling", shape="loop")
    b = _leg("b", [-105.29, 40.00], [-105.25, 40.00])

    day = compose_day([a, b], [Transition(from_segment_id="a", to_segment_id="b")])

    assert day.transitions[0].gap_m is None
    assert day.transitions[0].gap_warning is False


def test_a_transitions_author_instructions_survive_composition():
    """FR12 / B3 — composition owns the *measurement*, never the content: a
    transition is passed in because a mode change is an Author's decision with
    instructions attached, not something a composer can infer."""
    node = Node(kind="transition", coord=[-105.29, 40.00],
                instructions="Stash the bikes behind the outhouse.")
    day = compose_day(
        [_leg("s1", [-105.30, 40.00], [-105.29, 40.00]),
         _leg("s2", [-105.29, 40.00], [-105.25, 40.00], "hiking")],
        [Transition(from_segment_id="s1", to_segment_id="s2", node=node)],
    )
    assert day.transitions[0].node.instructions == "Stash the bikes behind the outhouse."


def test_a_composed_day_serializes_its_transitions():
    day = compose_day(
        [_leg("s1", [-105.30, 40.00], [-105.30, 40.00]),
         _leg("s2", [-105.29, 40.00], [-105.25, 40.00], "hiking")],
        [Transition(id="t1", from_segment_id="s1", to_segment_id="s2")],
    )
    wire = day.to_dict()["transitions"][0]
    assert wire["id"] == "t1"
    assert wire["from_mode"] == "cycling"
    assert wire["to_mode"] == "hiking"
    assert wire["gap_warning"] is True
    assert wire["gap_m"] == pytest.approx(852.0, abs=5.0)
