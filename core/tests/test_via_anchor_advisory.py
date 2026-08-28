"""Story A9a (issue #27) — routing a loop through *three or more* designated
via-anchors while still returning to start (FR8a).

`routing/loops.py` already routes an arbitrary-length via list generically —
A9 (`test_via_anchor_loop.py`) proved one or two. What A9a adds is the
product position SPIKE-01's finding was reframed into: past two via-anchors
the places fix the loop's length, so in **explore mode the target distance
becomes advisory** — it is reported, never chased, and any deviation is
surfaced through A6's relaxation path rather than as a conflict. In
**compose mode** (`target_m is None`) distance is already a reported outcome
(FR118), so there is no target to downgrade.

This covers A9a's AC directly:

  * three or more via-anchors are each reached and the loop still closes;
  * `scoring.bands` stops folding in the default `distance_m` band once the
    via count crosses `ADVISORY_VIA_THRESHOLD`, so the explore search no
    longer descends against a distance the vias have pinned;
  * `routing.diagnose` marks such a request `distance_advisory`, never names
    distance in the conflict set, and — when the realised length missed the
    target — reports `kind="advisory"` with an A6-shaped relaxation offer;
  * an Author-authored `distance_m` band still wins even past the threshold.
"""

from __future__ import annotations

import math

import networkx as nx

from plotlines_core.routing.diagnose import Diagnosis, _mark_distance_advisory, diagnose
from plotlines_core.routing.loops import generate_loop
from plotlines_core.scoring.bands import (
    ADVISORY_VIA_THRESHOLD, Band, BandSet, default_distance_band,
    distance_is_advisory, ensure_distance_band,
)
from plotlines_core.scoring.profile import WeightProfile

# ---------------------------------------------------------------------------
# A routable 9x9 lattice — the same shape `test_via_anchor_loop.py` and
# `test_band_search.py` both route against.
# ---------------------------------------------------------------------------

_ROWS = _COLS = 9
_SPACING_M = 150.0
_CENTER = (40.0000, -105.3000)
_M_PER_DEG_LAT = 111_320.0
_M_PER_DEG_LON = 111_320.0 * math.cos(math.radians(_CENTER[0]))


def _latlon(r: int, c: int) -> tuple[float, float]:
    clat, clon = _CENTER
    lat = clat + (r - _ROWS // 2) * _SPACING_M / _M_PER_DEG_LAT
    lon = clon + (c - _COLS // 2) * _SPACING_M / _M_PER_DEG_LON
    return lat, lon


def _node_id(r: int, c: int) -> int:
    return r * _COLS + c


def _grid_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    for r in range(_ROWS):
        for c in range(_COLS):
            lat, lon = _latlon(r, c)
            g.add_node(_node_id(r, c), y=lat, x=lon, elevation=100.0 + 8.0 * r)
    for r in range(_ROWS):
        for c in range(_COLS):
            n = _node_id(r, c)
            if c + 1 < _COLS:
                e = _node_id(r, c + 1)
                g.add_edge(n, e, length=_SPACING_M, highway="residential")
                g.add_edge(e, n, length=_SPACING_M, highway="residential")
            if r + 1 < _ROWS:
                e = _node_id(r + 1, c)
                g.add_edge(n, e, length=_SPACING_M, highway="residential")
                g.add_edge(e, n, length=_SPACING_M, highway="residential")
    return g


_START = _CENTER
_PROFILE = WeightProfile("balanced")

#: Three via-anchors near three different corners of the lattice. Any loop
#: through all three is well over a kilometre; pairing them with an 800 m
#: target guarantees a positive deviation to assert on.
_THREE_VIA = [_latlon(1, 7), _latlon(7, 7), _latlon(7, 1)]
_FOUR_VIA = [_latlon(1, 7), _latlon(7, 7), _latlon(7, 1), _latlon(1, 1)]
_SMALL_TARGET_M = 800.0


# ---------------------------------------------------------------------------
# The policy: `distance_is_advisory` / `ADVISORY_VIA_THRESHOLD` — pure, no graph
# ---------------------------------------------------------------------------


def test_threshold_is_three():
    assert ADVISORY_VIA_THRESHOLD == 3


def test_distance_is_not_advisory_below_the_threshold():
    assert distance_is_advisory(20_000.0, 0) is False
    assert distance_is_advisory(20_000.0, 1) is False
    assert distance_is_advisory(20_000.0, 2) is False


def test_distance_is_advisory_at_and_past_the_threshold():
    assert distance_is_advisory(20_000.0, 3) is True
    assert distance_is_advisory(20_000.0, 6) is True


def test_distance_is_never_advisory_in_compose_mode():
    # `target_m is None` is compose (ARCH §7.7): distance is already a
    # reported outcome (FR118), so there is nothing for the via count to
    # downgrade — no matter how many anchors form the spine.
    assert distance_is_advisory(None, 0) is False
    assert distance_is_advisory(None, 7) is False


# ---------------------------------------------------------------------------
# `ensure_distance_band` — withholds the default band once the target is
# advisory, still honours an Author-authored one
# ---------------------------------------------------------------------------


def test_default_distance_band_is_still_added_with_two_via_anchors():
    augmented = ensure_distance_band(BandSet.of(), 20_000.0, via_count=2)
    assert any(b.metric == "distance_m" for b in augmented)


def test_default_distance_band_is_withheld_with_three_via_anchors():
    bands = BandSet.of(Band("climb_m", minimum=100.0))
    augmented = ensure_distance_band(bands, 20_000.0, via_count=3)
    assert augmented is bands
    assert not any(b.metric == "distance_m" for b in augmented)


def test_an_authored_distance_band_still_wins_past_the_threshold():
    authored = Band("distance_m", minimum=18_000.0, maximum=22_000.0)
    bands = BandSet.of(authored)
    augmented = ensure_distance_band(bands, 20_000.0, via_count=5)
    assert augmented is bands
    distance_bands = [b for b in augmented if b.metric == "distance_m"]
    assert distance_bands == [authored]


def test_compose_mode_still_adds_no_band_regardless_of_via_count():
    bands = BandSet.of(Band("climb_m", minimum=100.0))
    assert ensure_distance_band(bands, None, via_count=5) is bands


# ---------------------------------------------------------------------------
# AC: "Three or more via-anchors; the route passes through each and returns
# to start."
# ---------------------------------------------------------------------------


def test_three_via_anchors_are_all_reached_and_the_loop_closes():
    loop = generate_loop(_grid_graph(), _START, 2600.0, _PROFILE, via=_THREE_VIA)
    assert loop.closed is True
    assert loop.hit_via is True
    assert len(loop.via_nodes) == 3
    assert all(n in loop.path for n in loop.via_nodes)
    assert loop.path[0] == loop.path[-1]


def test_four_via_anchors_are_all_reached_in_order_and_the_loop_closes():
    loop = generate_loop(_grid_graph(), _START, 3200.0, _PROFILE, via=_FOUR_VIA)
    assert loop.hit_via is True
    assert len(loop.via_nodes) == 4
    positions = [loop.path.index(n) for n in loop.via_nodes]
    assert positions == sorted(positions)


def test_an_undersized_target_with_three_via_anchors_returns_best_effort_not_an_exception():
    # The vias fix the length well above 800 m; this must come back as a
    # large positive `distance_error`, never a raised error — that best-effort
    # result is exactly what A6/`diagnose` then reports as advisory.
    loop = generate_loop(_grid_graph(), _START, _SMALL_TARGET_M, _PROFILE, via=_THREE_VIA)
    assert loop.hit_via is True
    assert loop.closed is True
    assert loop.distance_error is not None
    assert loop.distance_error > 0.14  # past the ±14% A9 still held to


# ---------------------------------------------------------------------------
# AC: "in explore mode target distance becomes advisory and the deviation is
# surfaced with A6's relaxation path"
# ---------------------------------------------------------------------------


def test_diagnose_marks_a_three_via_request_distance_advisory():
    result = diagnose(_grid_graph(), _START, _SMALL_TARGET_M, BandSet.of(),
                      via=_THREE_VIA, budget=12, filter_budget=6)
    assert result.distance_advisory is True
    # distance is never named as the thing that conflicts — the vias fixed it
    assert not any(b.metric == "distance_m" for b in result.conflict)


def test_diagnose_reports_the_deviation_as_advisory_with_an_a6_shaped_relaxation():
    result = diagnose(_grid_graph(), _START, _SMALL_TARGET_M, BandSet.of(),
                      via=_THREE_VIA, budget=12, filter_budget=6)

    assert result.feasible is True
    assert result.kind == "advisory"

    dev = result.advisory_deviation
    assert dev is not None
    assert dev["deviates"] is True
    assert dev["realised_m"] > _SMALL_TARGET_M
    assert dev["target_m"] == _SMALL_TARGET_M
    assert dev["distance_error"] > 0.0
    # the five A0a affordances, adapted to a via-anchor loop
    assert dev["affordances"] == [
        "drop_via_anchor", "move_via_anchor", "widen_target", "accept",
    ]

    relax = dev["relaxation"]
    assert relax["metric"] == "distance_m"
    # A6's `Relaxation.to_dict()` shape, so the client renders it the same way
    assert set(relax) == {"metric", "from", "to", "trade_off", "reached_by"}
    assert "no route was found" not in relax["trade_off"]


def test_advisory_fields_round_trip_through_to_dict():
    result = diagnose(_grid_graph(), _START, _SMALL_TARGET_M, BandSet.of(),
                      via=_THREE_VIA, budget=12, filter_budget=6)
    payload = result.to_dict()
    assert payload["distance_advisory"] is True
    assert payload["advisory_deviation"] is not None
    assert payload["kind"] == "advisory"


def _feasible_diagnosis(realised_m: float) -> Diagnosis:
    """A `Diagnosis` shaped like a feasible, no-conflict band solve whose
    best-effort loop realised `realised_m` — the input `_mark_distance_advisory`
    decorates."""
    return Diagnosis(
        feasible=True, kind="none", conflict=[], explanation="all bands satisfied",
        relaxations=[], envelope={}, solves=1, elapsed_ms=1.0,
        best_effort={"profile": "balanced", "distance_m": realised_m,
                     "climb_m": 40.0, "traffic": 0.2},
    )


def test_mark_advisory_leaves_kind_none_when_the_realised_length_lands_in_band():
    target_m = 20_000.0
    within = default_distance_band(target_m).minimum + 1.0  # just inside the band
    result = _feasible_diagnosis(within)

    _mark_distance_advisory(result, target_m, BandSet.of())

    assert result.distance_advisory is True
    assert result.advisory_deviation is not None
    assert result.advisory_deviation["deviates"] is False
    assert "relaxation" not in result.advisory_deviation
    # no deviation → no panel: the request routed inside the target after all
    assert result.kind == "none"


def test_mark_advisory_promotes_kind_to_advisory_when_the_realised_length_misses():
    target_m = 20_000.0
    over = default_distance_band(target_m).maximum + 5_000.0
    result = _feasible_diagnosis(over)

    _mark_distance_advisory(result, target_m, BandSet.of(Band("climb_m", maximum=50.0)))

    assert result.kind == "advisory"
    dev = result.advisory_deviation
    assert dev["deviates"] is True
    assert dev["relaxation"]["reached_by"] == "balanced"
    # the trade-off names the other band's realised value and verdict
    assert "climb" in dev["relaxation"]["trade_off"].lower()


def test_mark_advisory_without_a_best_effort_route_still_flags_advisory():
    result = Diagnosis(
        feasible=False, kind="unattainable", conflict=[Band("climb_m", minimum=9e4)],
        explanation="this is a limit of the terrain", relaxations=[], envelope={},
        solves=1, elapsed_ms=1.0, best_effort=None,
    )
    _mark_distance_advisory(result, 20_000.0, BandSet.of())
    assert result.distance_advisory is True
    assert result.advisory_deviation is None
    assert "advisory" in result.explanation


# ---------------------------------------------------------------------------
# AC: a genuine conflict on some *other* band is still diagnosed normally,
# with distance simply absent from the conflict set.
# ---------------------------------------------------------------------------


def test_an_unattainable_non_distance_band_still_diagnoses_past_the_threshold():
    impossible_climb = Band("climb_m", minimum=99_000.0)  # nothing on this grid
    result = diagnose(_grid_graph(), _START, _SMALL_TARGET_M,
                      BandSet.of(impossible_climb), via=_THREE_VIA,
                      budget=12, filter_budget=6)
    assert result.feasible is False
    assert result.distance_advisory is True
    assert {b.metric for b in result.conflict} == {"climb_m"}
