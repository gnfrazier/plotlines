"""Unit tests for `plotlines_core.trips.dashboard` — Story D1 / MVP (FR31),
with the FR16 time model it leans on.

D1's AC, line by line:

  * a persistent panel with **active-passage, day-total, and trip-total**
    distance and elevation **by mode** (`build_dashboard` scopes, `roll_up`
    reuse);
  * **with FR16**, moving time / elapsed time (**station durations included**) /
    ETA (`moving_time_s`, `day_hold_s`, `eta`);
  * **updates on every add / edit / reorder** — `build_dashboard` is a pure
    function of the trip, so re-running it after an edit is the next state.
"""

import pytest

from plotlines_core.trips.dashboard import (
    PACE_CUSTOM,
    PACE_SYSTEM_DEFAULT,
    Dashboard,
    build_dashboard,
    eta,
    moving_time_s,
)
from plotlines_core.trips.payload import Day, RouteMetrics, Segment, Trip


# --- fixtures --------------------------------------------------------------


def _seg(mode: str, dist: float, climb: float = 0.0, descent: float = 0.0,
         *, id_: str | None = None, title: str | None = None) -> Segment:
    kw = {"id": id_} if id_ else {}
    return Segment(
        mode=mode, shape="point_to_point", title=title,
        start=[0.0, 0.0], end=[0.1, 0.1],
        metrics=RouteMetrics(distance_m=dist, climb_m=climb, descent_m=descent),
        **kw,
    )


def _trip() -> Trip:
    day1 = Day(index=1, kind="route", segments=[
        _seg("cycling", 20_000.0, 300.0, 250.0, id_="s1", title="River path"),
        _seg("hiking", 5_000.0, 400.0, 120.0, id_="s2", title="Ridge scramble"),
    ])
    day2 = Day(index=2, kind="route", segments=[
        _seg("cycling", 30_000.0, 150.0, 500.0, id_="s3", title="Descent to town"),
    ])
    return Trip(title="Three ways over the range", id="trip-1", days=[day1, day2])


# --- moving_time_s: the FR16 pace helper --------------------------------


def test_system_default_pace_comes_from_the_mode_registry():
    # hiking base speed is 5.0 km/h → 3600 s for 5 km.
    assert moving_time_s(5_000.0, "hiking") == pytest.approx(3_600.0)
    # cycling base speed is 15.0 km/h → 1200 s for 5 km.
    assert moving_time_s(5_000.0, "cycling") == pytest.approx(1_200.0)


def test_a_caller_supplied_pace_overrides_the_system_default():
    # 10 km/h → 1800 s for 5 km, regardless of hiking's 5 km/h default.
    assert moving_time_s(5_000.0, "hiking", {"hiking": 10.0}) == pytest.approx(1_800.0)


def test_a_mode_absent_from_the_override_still_falls_back_to_its_default():
    assert moving_time_s(5_000.0, "cycling", {"hiking": 10.0}) == pytest.approx(1_200.0)


def test_a_mode_with_no_pace_returns_none_rather_than_a_fabricated_one():
    assert moving_time_s(5_000.0, "transit") is None
    assert moving_time_s(5_000.0, "teleportation") is None
    assert moving_time_s(5_000.0, "hiking", {"hiking": 0.0}) is None
    assert moving_time_s(5_000.0, "hiking", {"hiking": -3.0}) is None


# --- eta --------------------------------------------------------------


def test_eta_is_start_plus_elapsed_as_a_utc_stamp():
    assert eta("2026-08-28T08:00:00Z", 3_600.0) == "2026-08-28T09:00:00Z"


def test_eta_accepts_a_naive_start_and_an_offset_start():
    assert eta("2026-08-28T08:00:00", 90 * 60) == "2026-08-28T09:30:00Z"
    assert eta("2026-08-28T08:00:00+02:00", 3_600.0) == "2026-08-28T07:00:00Z"


# --- distance & elevation, the three scopes, by mode -----------------


def test_day_totals_sum_their_passages_distance_and_elevation():
    board = build_dashboard(_trip())
    d1, d2 = board.days
    assert d1.metrics.total.distance_m == 25_000.0
    assert d1.metrics.total.climb_m == 700.0
    assert d1.metrics.total.descent_m == 370.0
    assert d2.metrics.total.distance_m == 30_000.0


def test_trip_total_sums_every_passage():
    board = build_dashboard(_trip())
    assert board.trip_total.total.distance_m == 55_000.0
    assert board.trip_total.total.climb_m == 850.0
    assert board.trip_total.total.descent_m == 870.0


def test_by_mode_splits_distance_across_modes_at_every_scope():
    board = build_dashboard(_trip())
    assert board.days[0].metrics.by_mode["cycling"].distance_m == 20_000.0
    assert board.days[0].metrics.by_mode["hiking"].distance_m == 5_000.0
    assert set(board.trip_total.by_mode) == {"cycling", "hiking"}
    assert board.trip_total.by_mode["cycling"].distance_m == 50_000.0
    assert board.trip_total.by_mode["hiking"].distance_m == 5_000.0


def test_the_active_passage_scope_is_that_one_segment():
    board = build_dashboard(_trip(), active_segment_id="s2")
    assert board.active_passage.segment_id == "s2"
    assert board.active_passage.mode == "hiking"
    assert board.active_passage.title == "Ridge scramble"
    assert board.active_passage.day_index == 1
    assert board.active_passage.metrics.distance_m == 5_000.0
    assert board.active_passage.metrics.climb_m == 400.0


def test_no_active_passage_is_requested_leaves_that_scope_empty():
    assert build_dashboard(_trip()).active_passage is None


def test_an_unknown_active_segment_id_is_rejected():
    with pytest.raises(ValueError, match="not in trip"):
        build_dashboard(_trip(), active_segment_id="nope")


# --- the FR16 time model on the dashboard ---------------------------


def test_moving_time_rolls_up_per_mode_at_system_default_pace():
    board = build_dashboard(_trip())
    # day 1: 20 km cycling @ 15 km/h = 4800 s; 5 km hiking @ 5 km/h = 3600 s.
    assert board.days[0].metrics.by_mode["cycling"].moving_time_s == pytest.approx(4_800.0)
    assert board.days[0].metrics.by_mode["hiking"].moving_time_s == pytest.approx(3_600.0)
    assert board.days[0].metrics.total.moving_time_s == pytest.approx(8_400.0)
    assert board.pace_source == PACE_SYSTEM_DEFAULT
    assert board.days[0].metrics.total.pace_source == PACE_SYSTEM_DEFAULT


def test_a_speed_override_is_used_and_marks_the_pace_source_custom():
    board = build_dashboard(_trip(), speeds={"cycling": 30.0})
    # 20 km @ 30 km/h = 2400 s.
    assert board.days[0].metrics.by_mode["cycling"].moving_time_s == pytest.approx(2_400.0)
    assert board.pace_source == PACE_CUSTOM
    assert board.days[0].metrics.by_mode["cycling"].pace_source == PACE_CUSTOM


def test_elapsed_time_is_moving_time_plus_the_station_hold_for_that_day():
    trip = _trip()
    board = build_dashboard(trip, day_hold_s={trip.days[0].id: 5_400.0})
    total = board.days[0].metrics.total
    assert total.moving_time_s == pytest.approx(8_400.0)
    assert total.elapsed_time_s == pytest.approx(13_800.0)   # 8400 + 5400
    assert board.days[0].hold_s == 5_400.0
    # the hold belongs to no mode — per-mode lines carry moving time only
    assert board.days[0].metrics.by_mode["hiking"].elapsed_time_s is None


def test_day_eta_is_the_day_start_plus_its_elapsed_time():
    trip = _trip()
    board = build_dashboard(
        trip,
        day_hold_s={trip.days[0].id: 5_400.0},
        day_start_at={trip.days[0].id: "2026-08-28T06:00:00Z"},
    )
    # 06:00 + 13800 s (3 h 50 m) = 09:50.
    assert board.days[0].eta == "2026-08-28T09:50:00Z"
    assert board.days[1].eta is None   # no start supplied for day 2


def test_trip_eta_folds_in_every_days_hold():
    trip = _trip()
    board = build_dashboard(
        trip,
        day_hold_s={trip.days[0].id: 3_600.0, trip.days[1].id: 1_800.0},
        trip_start_at="2026-08-28T06:00:00Z",
    )
    # moving: 4800 + 3600 (day1) + 7200 (day2: 30km @ 15) = 15600; holds 5400.
    assert board.trip_total.total.moving_time_s == pytest.approx(15_600.0)
    assert board.trip_total.total.elapsed_time_s == pytest.approx(21_000.0)
    assert board.trip_hold_s == 5_400.0
    assert board.trip_eta == "2026-08-28T11:50:00Z"   # 06:00 + 5 h 50 m


def test_a_leg_with_no_pace_leaves_the_scope_total_time_unset_not_understated():
    trip = _trip()
    trip.days[0].segments.append(_seg("transit", 40_000.0, id_="s-train"))
    board = build_dashboard(trip)
    total = board.days[0].metrics.total
    assert total.moving_time_s is None
    assert total.elapsed_time_s is None
    assert total.pace_source is None
    # the modes that *do* have a pace still report theirs
    assert board.days[0].metrics.by_mode["cycling"].moving_time_s == pytest.approx(4_800.0)


def test_with_no_time_inputs_the_dashboard_is_still_the_distance_elevation_panel():
    board = build_dashboard(_trip())
    # System-default moving time is always available, and with no station hold
    # elapsed == moving (there is nothing to add). ETA still needs a start time.
    assert board.days[0].metrics.total.moving_time_s == pytest.approx(8_400.0)
    assert board.days[0].metrics.total.elapsed_time_s == pytest.approx(8_400.0)
    assert board.days[0].eta is None
    assert board.trip_eta is None
    assert board.trip_hold_s is None


# --- updates on every add / edit / reorder --------------------------


def test_reordering_passages_within_a_day_is_reflected_but_totals_are_stable():
    trip = _trip()
    before = build_dashboard(trip)
    trip.days[0].segments.reverse()
    after = build_dashboard(trip)
    # order changed (by_mode now lists hiking first), the day total did not
    assert before.days[0].metrics.total.distance_m == after.days[0].metrics.total.distance_m
    assert list(before.days[0].metrics.by_mode) == ["cycling", "hiking"]
    assert list(after.days[0].metrics.by_mode) == ["hiking", "cycling"]


def test_editing_a_passages_metrics_moves_every_scope_it_feeds():
    trip = _trip()
    trip.days[0].segments[0].metrics.distance_m = 26_000.0   # +6 km on s1
    board = build_dashboard(trip)
    assert board.days[0].metrics.total.distance_m == 31_000.0
    assert board.trip_total.total.distance_m == 61_000.0
    assert board.trip_total.by_mode["cycling"].distance_m == 56_000.0


def test_adding_a_passage_grows_the_day_and_trip_totals():
    trip = _trip()
    trip.days[1].segments.append(_seg("hiking", 2_000.0, 90.0))
    board = build_dashboard(trip)
    assert board.days[1].metrics.total.distance_m == 32_000.0
    assert board.days[1].metrics.by_mode["hiking"].distance_m == 2_000.0
    assert board.trip_total.total.distance_m == 57_000.0


def test_building_the_dashboard_never_mutates_the_trips_own_metrics():
    trip = _trip()
    build_dashboard(trip, active_segment_id="s3",
                    day_hold_s={trip.days[0].id: 600.0})
    for day in trip.days:
        for segment in day.segments:
            assert segment.metrics.moving_time_s is None
            assert segment.metrics.elapsed_time_s is None
            assert segment.metrics.pace_source is None


# --- shape / serialization ---------------------------------------


def test_a_rest_day_with_no_passages_produces_an_empty_scope_not_a_crash():
    trip = _trip()
    trip.days.append(Day(index=3, kind="rest"))
    board = build_dashboard(trip)
    assert board.days[2].metrics.total is None
    assert board.days[2].to_dict()["metrics"]["total"] is None


def test_dashboard_to_dict_carries_every_scope():
    trip = _trip()
    board = build_dashboard(
        trip, active_segment_id="s1",
        day_hold_s={trip.days[0].id: 600.0},
        trip_start_at="2026-08-28T06:00:00Z",
    )
    wire = board.to_dict()
    assert wire["trip_id"] == "trip-1"
    assert wire["pace_source"] == PACE_SYSTEM_DEFAULT
    assert wire["active_passage"]["segment_id"] == "s1"
    assert len(wire["days"]) == 2
    assert wire["trip_total"]["total"]["distance_m"] == 55_000.0
    assert wire["trip_eta"].endswith("Z")
    assert isinstance(board, Dashboard)
