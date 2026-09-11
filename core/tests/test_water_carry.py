"""Story C9 — water-carry distance between sources (PRD FR25).

Covers the model half of C9's acceptance criteria that outlives any one
screen:

  * a water-source anchor is a `provision`-kind role carrying
    `ProvisionDetail.water` (potable or filter-required);
  * `collect_water_sources` is the single traversal every water surface reads;
  * `water_carry_for_day` places each source on the day's route and reports
    the gaps between consecutive ones, in route order;
  * a source too far from this day's route is reported (`.off_route`), never
    silently dropped.
"""

import pytest

from plotlines_core.content.anchor import Anchor, ProvisionDetail, Role, WaterSource as RoleWater
from plotlines_core.trips.cues import haversine_m
from plotlines_core.trips.payload import Day, LineString, Segment, Trip
from plotlines_core.trips.water_carry import (
    SNAP_TOLERANCE_M,
    collect_water_sources,
    water_carry_for_day,
    water_carry_rollup,
)

# A straight line north along one meridian — five vertices, four ~1112 m legs.
_LON = -105.30
_LATS = [40.00, 40.01, 40.02, 40.03, 40.04]
_LINE = [[_LON, lat] for lat in _LATS]


def _provision_anchor(anchor_id: str, coord, *, potable: bool, title: str | None = None) -> Anchor:
    return Anchor(
        id=anchor_id, coord=coord, title=title,
        roles=[Role(kind="provision", provision=ProvisionDetail(water=RoleWater(potable=potable)))],
    )


def _day_with_route(day_id: str = "day-1", index: int = 1) -> Day:
    return Day(
        id=day_id, index=index,
        segments=[Segment(id="seg-1", mode="hiking", shape="point_to_point",
                           geometry=LineString(coordinates=_LINE))],
    )


# --- collect_water_sources: one traversal -----------------------------------


def test_collect_reads_only_provision_roles_with_water_set():
    tap = _provision_anchor("a-tap", _LINE[1], potable=True, title="Trailhead tap")
    resupply_only = Anchor(
        id="a-store", coord=_LINE[2], title="General store",
        roles=[Role(kind="provision", provision=None)],
    )
    narrative_only = Anchor(id="a-view", coord=_LINE[3], title="Overlook",
                             roles=[Role(kind="narrative")])
    trip = Trip(title="t", anchors=[tap, resupply_only, narrative_only])
    sources = collect_water_sources(trip)
    assert [s.anchor_id for s in sources] == ["a-tap"]
    assert sources[0].potable is True
    assert sources[0].title == "Trailhead tap"


def test_collect_reports_filter_required_sources_too():
    spring = _provision_anchor("a-spring", _LINE[1], potable=False, title="Cold Spring")
    sources = collect_water_sources(Trip(title="t", anchors=[spring]))
    assert sources[0].potable is False


# --- water_carry_for_day: placement and gaps --------------------------------


def test_two_sources_on_route_produce_one_leg_in_route_order():
    v1 = _provision_anchor("a1", _LINE[1], potable=True, title="Spring 1")
    v3 = _provision_anchor("a3", _LINE[3], potable=True, title="Spring 3")
    sources = collect_water_sources(Trip(title="t", anchors=[v3, v1]))  # deliberately out of order
    report = water_carry_for_day(_day_with_route(), sources)

    assert len(report.legs) == 1
    leg = report.legs[0]
    assert (leg.from_anchor_id, leg.to_anchor_id) == ("a1", "a3")
    assert leg.from_title == "Spring 1"
    assert leg.to_title == "Spring 3"

    expected_m = (haversine_m(tuple(_LINE[1]), tuple(_LINE[2]))
                  + haversine_m(tuple(_LINE[2]), tuple(_LINE[3])))
    assert leg.distance_m == pytest.approx(expected_m, abs=0.5)


def test_three_sources_produce_two_legs_summing_to_the_span():
    v0 = _provision_anchor("a0", _LINE[0], potable=True)
    v2 = _provision_anchor("a2", _LINE[2], potable=True)
    v4 = _provision_anchor("a4", _LINE[4], potable=True)
    sources = collect_water_sources(Trip(title="t", anchors=[v0, v2, v4]))
    report = water_carry_for_day(_day_with_route(), sources)

    assert [(leg.from_anchor_id, leg.to_anchor_id) for leg in report.legs] == [
        ("a0", "a2"), ("a2", "a4"),
    ]
    total_span = haversine_m(tuple(_LINE[0]), tuple(_LINE[1])) + \
        haversine_m(tuple(_LINE[1]), tuple(_LINE[2])) + \
        haversine_m(tuple(_LINE[2]), tuple(_LINE[3])) + \
        haversine_m(tuple(_LINE[3]), tuple(_LINE[4]))
    assert sum(leg.distance_m for leg in report.legs) == pytest.approx(total_span, abs=1.0)


def test_a_single_source_produces_no_legs():
    v1 = _provision_anchor("a1", _LINE[1], potable=True)
    report = water_carry_for_day(_day_with_route(), collect_water_sources(Trip(title="t", anchors=[v1])))
    assert report.legs == []
    assert report.off_route == []


def test_no_sources_at_all_is_the_common_case_not_an_error():
    report = water_carry_for_day(_day_with_route(), [])
    assert report.legs == []
    assert report.off_route == []


def test_source_far_from_the_route_is_reported_off_route_not_dropped():
    on_route = _provision_anchor("a1", _LINE[1], potable=True)
    far = _provision_anchor("a-far", [_LON + 1.0, 41.0], potable=True, title="Town spigot")
    sources = collect_water_sources(Trip(title="t", anchors=[on_route, far]))
    report = water_carry_for_day(_day_with_route(), sources)
    assert report.legs == []  # only one source actually on this day's route
    assert [s.anchor_id for s in report.off_route] == ["a-far"]


def test_source_just_within_the_snap_tolerance_is_placed():
    # ~1 metre of longitude offset at this latitude is well under
    # SNAP_TOLERANCE_M; the anchor still counts as "on the route."
    near = _provision_anchor("a-near", [_LON + 0.00001, _LATS[2]], potable=True)
    report = water_carry_for_day(_day_with_route(), collect_water_sources(
        Trip(title="t", anchors=[near])))
    assert report.off_route == []
    assert SNAP_TOLERANCE_M > 0  # sanity: the constant is a real distance, not zero


def test_a_day_with_no_solved_geometry_reports_every_source_off_route():
    rest_day = Day(id="rest", index=2, kind="rest")
    v1 = _provision_anchor("a1", _LINE[1], potable=True)
    sources = collect_water_sources(Trip(title="t", anchors=[v1]))
    report = water_carry_for_day(rest_day, sources)
    assert report.legs == []
    assert [s.anchor_id for s in report.off_route] == ["a1"]


# --- water_carry_rollup: the trip-wide bundle -------------------------------


def test_rollup_carries_one_report_per_day_and_the_shared_source_list():
    v1 = _provision_anchor("a1", _LINE[1], potable=True)
    v3 = _provision_anchor("a3", _LINE[3], potable=False)
    trip = Trip(title="t", days=[_day_with_route(), Day(id="d2", index=2, kind="rest")],
                anchors=[v1, v3])
    out = water_carry_rollup(trip)
    assert len(out["water_sources"]) == 2
    assert len(out["by_day"]) == 2
    assert out["by_day"][0]["day_index"] == 1
    assert len(out["by_day"][0]["legs"]) == 1
    assert out["by_day"][1]["day_index"] == 2
    assert out["by_day"][1]["legs"] == []
