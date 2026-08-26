"""Unit tests for `plotlines_core.trips.compose` (FR19/FR38, Stories C3/O6).

Scoped to the new O6 behaviour — day composition may close a day at a
resolution-stage anchor rather than only at a distance threshold — plus the
plain `Segment.arc_stage` round trip it depends on. Pre-existing `compose_day`/
`split_trip` behaviour (transitions, roll-ups) had no prior coverage and is
out of this story's scope.
"""

from plotlines_core.trips.compose import compose_day, split_trip
from plotlines_core.trips.payload import Day, Node, RouteMetrics, Segment


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
