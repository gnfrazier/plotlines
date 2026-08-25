"""FR2 (Story A1) — the climbing weight ("peaks"): 0.0-5.0 decimal on the
Author-facing side, mapped to `WeightProfile.peaks`'s -1.0..1.0 bipolar scale
internally (`scoring/profile.py`'s module doc). No test previously existed for
`edge_cost`'s peaks term, `elevation_biased_node`'s anchor bias, or the AC's own
claims — "engine biases toward/away from gain relative to the setting while
honoring origin/destination" and "total gain moves monotonically as the weight
rises across regenerations" — so this file exercises both the per-edge formula
and a real (synthetic) route solve.
"""

import networkx as nx
import pytest

from plotlines_core.graph.loader import elevation_biased_node
from plotlines_core.routing.solve import _weighted_path
from plotlines_core.scoring.metrics import edge_walk, measure
from plotlines_core.scoring.profile import WeightProfile, edge_cost

# Isolates the peaks term: every other weight is zero, so only `grade_abs` and
# `peaks` drive `edge_cost`'s penalty.
_NEUTRAL = dict(quiet=0.0, surface=0.0, scenic=0.0, directness=0.0)


def _profile(peaks: float) -> WeightProfile:
    return WeightProfile(peaks=peaks, **_NEUTRAL)


# ---------------------------------------------------------------------------
# edge_cost — the per-edge formula
# ---------------------------------------------------------------------------


def test_seeking_climbing_discounts_a_steep_edge():
    steep = {"length": 100.0, "grade_abs": 0.12}
    neutral_cost = edge_cost(steep, _profile(0.0))
    seek_cost = edge_cost(steep, _profile(1.0))
    assert seek_cost < neutral_cost


def test_avoiding_climbing_charges_a_steep_edge():
    steep = {"length": 100.0, "grade_abs": 0.12}
    neutral_cost = edge_cost(steep, _profile(0.0))
    avoid_cost = edge_cost(steep, _profile(-1.0))
    assert avoid_cost > neutral_cost


def test_edge_cost_is_monotonically_non_increasing_in_peaks_for_a_climbing_edge():
    steep = {"length": 100.0, "grade_abs": 0.12}
    costs = [edge_cost(steep, _profile(p)) for p in (-1.0, -0.5, 0.0, 0.5, 1.0)]
    assert costs == sorted(costs, reverse=True)
    # Not just non-increasing — genuinely responsive across the sweep.
    assert costs[0] > costs[-1]


def test_edge_cost_stays_strictly_positive_at_full_seek():
    # "A 'seek climbing' weight must never buy a negative edge" (profile.py).
    steep = {"length": 100.0, "grade_abs": 0.12}
    assert edge_cost(steep, _profile(1.0)) > 0.0


def test_flat_edge_is_unaffected_by_peaks():
    flat = {"length": 100.0, "grade_abs": 0.0}
    costs = {edge_cost(flat, _profile(p)) for p in (-1.0, -0.5, 0.0, 0.5, 1.0)}
    assert len(costs) == 1


def test_grade_saturates_above_the_saturation_point():
    at_saturation = {"length": 100.0, "grade_abs": 0.12}
    past_saturation = {"length": 100.0, "grade_abs": 0.30}
    assert edge_cost(at_saturation, _profile(1.0)) == pytest.approx(
        edge_cost(past_saturation, _profile(1.0))
    )


# ---------------------------------------------------------------------------
# A synthetic graph with three A -> D routes of increasing steepness, so a
# real weighted solve (the same `_weighted_path` `routing.solve.generate_segment`
# calls) can be checked end to end. All three routes are the same rough
# distance-in-length-units order of magnitude; only grade and elevation differ.
#
#   A --(flat, 1000m, grade 0.00)------------------------------> D
#   A --(550m, grade 0.06)--> M --(550m, grade 0.06)------------> D   (climbs to 180m, back to 100m)
#   A --(650m, grade 0.12)--> S --(650m, grade 0.12)------------> D   (climbs to 350m, back to 100m)
# ---------------------------------------------------------------------------

_A, _D, _M, _S = 1, 2, 3, 4


def _three_routes_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(_A, y=40.0000, x=-105.3000, elevation=100.0)
    g.add_node(_D, y=40.0050, x=-105.2950, elevation=100.0)
    g.add_node(_M, y=40.0025, x=-105.2975, elevation=180.0)
    g.add_node(_S, y=40.0020, x=-105.2980, elevation=350.0)
    g.add_edge(_A, _D, length=1000.0, grade_abs=0.0)
    g.add_edge(_A, _M, length=550.0, grade_abs=0.06)
    g.add_edge(_M, _D, length=550.0, grade_abs=0.06)
    g.add_edge(_A, _S, length=650.0, grade_abs=0.12)
    g.add_edge(_S, _D, length=650.0, grade_abs=0.12)
    return g


def _solve_climb_m(graph: nx.MultiDiGraph, peaks: float) -> float:
    profile = _profile(peaks)
    path = _weighted_path(graph, _A, _D, profile)
    walk = edge_walk(graph, path, profile)
    return measure(graph, walk).climb_m


def test_avoids_the_climb_when_peaks_is_negative():
    graph = _three_routes_graph()
    assert _solve_climb_m(graph, -1.0) == 0.0


def test_seeks_the_climb_when_peaks_is_positive():
    graph = _three_routes_graph()
    # The steepest route (climbs to 350m from a 100m start/end) wins outright
    # once peaks is pushed all the way to "seek".
    assert _solve_climb_m(graph, 1.0) == pytest.approx(250.0)


def test_total_gain_moves_monotonically_as_peaks_rises_across_regenerations():
    graph = _three_routes_graph()
    peaks_values = (-1.0, -0.5, 0.0, 0.35, 1.0)
    climbs = [_solve_climb_m(graph, p) for p in peaks_values]

    assert climbs == sorted(climbs)  # never decreases as peaks rises
    assert climbs[0] < climbs[-1]  # and it is genuinely responsive, not flat throughout
    # Three distinct routes really were chosen along the way, not just two.
    assert len(set(climbs)) == 3


def test_origin_and_destination_are_honoured_regardless_of_peaks():
    graph = _three_routes_graph()
    for peaks in (-1.0, -0.5, 0.0, 0.35, 1.0):
        path = _weighted_path(graph, _A, _D, _profile(peaks))
        assert path[0] == _A
        assert path[-1] == _D


# ---------------------------------------------------------------------------
# elevation_biased_node — the loop-shape lever ("realised climbing is set far
# more by where the shaping anchors sit than by any edge weight", loader.py).
# ---------------------------------------------------------------------------

_NEAR, _LOW, _HIGH = 10, 11, 12
_QUERY_LAT, _QUERY_LON = 40.0000, -105.3000
_M_PER_DEGREE_LAT = 111_320.0


def _anchor_candidates_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    # ~5 m from the query point, middling elevation.
    g.add_node(_NEAR, y=_QUERY_LAT + 5.0 / _M_PER_DEGREE_LAT, x=_QUERY_LON, elevation=140.0)
    # ~150 m away in one direction, low ground.
    g.add_node(_LOW, y=_QUERY_LAT + 150.0 / _M_PER_DEGREE_LAT, x=_QUERY_LON, elevation=90.0)
    # ~150 m away in the other direction, high ground.
    g.add_node(_HIGH, y=_QUERY_LAT - 150.0 / _M_PER_DEGREE_LAT, x=_QUERY_LON, elevation=190.0)
    return g


def test_zero_bias_reproduces_nearest_node():
    graph = _anchor_candidates_graph()
    node = elevation_biased_node(graph, _QUERY_LAT, _QUERY_LON, radius_m=200.0, bias=0.0)
    assert node == _NEAR


def test_positive_bias_pulls_the_anchor_uphill():
    graph = _anchor_candidates_graph()
    node = elevation_biased_node(graph, _QUERY_LAT, _QUERY_LON, radius_m=200.0, bias=1.0)
    assert node == _HIGH


def test_negative_bias_pulls_the_anchor_onto_flat_low_ground():
    graph = _anchor_candidates_graph()
    node = elevation_biased_node(graph, _QUERY_LAT, _QUERY_LON, radius_m=200.0, bias=-1.0)
    assert node == _LOW
