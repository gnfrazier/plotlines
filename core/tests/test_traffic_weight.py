"""FR3 (Story A2) — the traffic-tolerance weight ("cars"): 0.0-5.0 decimal on the
Author-facing side, mapped to `WeightProfile.quiet`'s solver-internal 0.0..1.0 scale
by `weight_profile.dart`'s `quietFromTraffic` (inverted — see `profile.py`'s module
doc: a high "cars" tolerance means *low* aversion to traffic).

Also exercises ARCH D33 / SPIKE-03 §5's traffic-stress model directly: rural/
low-signal roads must not be floored by their `highway=*` tag alone, only by a real
`maxspeed`/`lanes` capacity signal. No test previously existed for either the `quiet`
term in `edge_cost` or the D33 stress-baseline behaviour.
"""

import networkx as nx
import pytest

from plotlines_core.routing.solve import _weighted_path
from plotlines_core.scoring.metrics import edge_walk, measure
from plotlines_core.scoring.profile import (
    WeightProfile,
    _has_capacity_signal,
    _lane_count,
    _maxspeed_kmh,
    edge_cost,
    features,
)

# Isolates the quiet term: every other weight is zero, so only `highway`/`maxspeed`/
# `lanes` and `quiet` drive `edge_cost`'s penalty.
_NEUTRAL = dict(surface=0.0, scenic=0.0, directness=0.0, peaks=0.0)


def _profile(quiet: float) -> WeightProfile:
    return WeightProfile(quiet=quiet, **_NEUTRAL)


# ---------------------------------------------------------------------------
# D33 — rural/low-signal roads are the zero-stress baseline
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("highway", ["tertiary", "secondary", "primary", "trunk", "unclassified"])
def test_low_signal_class_with_no_contrary_signal_is_zero_stress(highway):
    edge = {"length": 100.0, "highway": highway}
    length, stress, quality, scenic_hit, grade = features(edge)
    assert stress == 0.0


@pytest.mark.parametrize("highway", ["tertiary", "secondary", "primary", "trunk", "unclassified"])
def test_low_signal_class_with_high_maxspeed_reaches_its_class_ceiling(highway):
    calm = features({"length": 100.0, "highway": highway})
    signalled = features({"length": 100.0, "highway": highway, "maxspeed": "80"})
    assert signalled[1] > calm[1]
    assert signalled[1] > 0.0


@pytest.mark.parametrize("highway", ["tertiary", "secondary", "primary", "trunk", "unclassified"])
def test_low_signal_class_with_many_lanes_reaches_its_class_ceiling(highway):
    calm = features({"length": 100.0, "highway": highway})
    signalled = features({"length": 100.0, "highway": highway, "lanes": "4"})
    assert signalled[1] > calm[1]
    assert signalled[1] > 0.0


def test_unrecognised_highway_class_also_defaults_to_zero_stress_absent_a_signal():
    # `_TRAFFIC_STRESS.get(highway, 0.5)` is the ceiling for an unknown class, but an
    # unknown/untagged class is exactly the "no signal" case D33 governs.
    _, stress, _, _, _ = features({"length": 100.0, "highway": "some_future_osm_tag"})
    assert stress == 0.0


@pytest.mark.parametrize("highway", ["cycleway", "path", "track", "footway", "living_street", "residential"])
def test_explicit_calm_classes_are_unaffected_by_maxspeed_or_lanes(highway):
    # These tags are decisive on their own (D33's carve-out) — a residential street
    # posted at 80 km/h with 4 lanes does not stop being a residential street.
    calm = features({"length": 100.0, "highway": highway})
    with_signal = features({"length": 100.0, "highway": highway, "maxspeed": "80", "lanes": "4"})
    assert calm[1] == with_signal[1]


def test_maxspeed_just_below_the_signal_threshold_stays_at_baseline():
    below = features({"length": 100.0, "highway": "tertiary", "maxspeed": "45"})
    assert below[1] == 0.0


def test_lanes_just_below_the_signal_threshold_stays_at_baseline():
    below = features({"length": 100.0, "highway": "secondary", "lanes": "3"})
    assert below[1] == 0.0


# ---------------------------------------------------------------------------
# maxspeed/lanes tag parsing
# ---------------------------------------------------------------------------


def test_maxspeed_parses_bare_kmh():
    assert _maxspeed_kmh("50") == pytest.approx(50.0)


def test_maxspeed_parses_explicit_mph():
    assert _maxspeed_kmh("35 mph") == pytest.approx(35 * 1.60934)


def test_maxspeed_parses_first_of_a_merged_way_list():
    assert _maxspeed_kmh(["80", "60"]) == pytest.approx(80.0)


def test_maxspeed_non_numeric_convention_is_no_signal():
    assert _maxspeed_kmh("national") is None


def test_maxspeed_absent_is_no_signal():
    assert _maxspeed_kmh(None) is None


def test_lane_count_parses_string_int():
    assert _lane_count("2") == 2


def test_lane_count_non_numeric_is_no_signal():
    assert _lane_count("some") is None


def test_has_capacity_signal_false_with_neither_tag():
    assert _has_capacity_signal({}) is False


# ---------------------------------------------------------------------------
# edge_cost — the quiet term
# ---------------------------------------------------------------------------


def test_low_tolerance_charges_a_stressed_edge():
    busy = {"length": 100.0, "highway": "secondary", "maxspeed": "80"}
    neutral_cost = edge_cost(busy, _profile(0.0))
    low_tolerance_cost = edge_cost(busy, _profile(1.0))
    assert low_tolerance_cost > neutral_cost


def test_high_tolerance_is_indifferent_to_a_stressed_edge():
    busy = {"length": 100.0, "highway": "secondary", "maxspeed": "80"}
    assert edge_cost(busy, _profile(0.0)) == pytest.approx(100.0)


def test_quiet_edge_is_unaffected_by_tolerance():
    quiet_edge = {"length": 100.0, "highway": "residential"}
    calm = features(quiet_edge)
    assert calm[1] == pytest.approx(0.3)
    costs = {edge_cost(quiet_edge, _profile(q)) for q in (0.0, 0.25, 0.5, 0.75, 1.0)}
    # residential's own stress is nonzero, so distinct quiet weights still cost
    # differently — this asserts the *rural low-signal* road is what's flat, not
    # every road. See test_zero_stress_edge_is_unaffected_by_tolerance below.
    assert len(costs) > 1


def test_zero_stress_edge_is_unaffected_by_tolerance():
    rural = {"length": 100.0, "highway": "tertiary"}  # no maxspeed/lanes signal
    costs = {edge_cost(rural, _profile(q)) for q in (0.0, 0.25, 0.5, 0.75, 1.0)}
    assert len(costs) == 1


def test_edge_cost_is_monotonically_non_decreasing_in_quiet_for_a_stressed_edge():
    busy = {"length": 100.0, "highway": "primary", "maxspeed": "90"}
    costs = [edge_cost(busy, _profile(q)) for q in (0.0, 0.25, 0.5, 0.75, 1.0)]
    assert costs == sorted(costs)
    assert costs[0] < costs[-1]


# ---------------------------------------------------------------------------
# A synthetic graph with two A -> D routes of equal-ish length: a short, direct
# route on a signalled arterial (busy), and a longer route on a quiet residential
# street — the AC's own framing, "quiet roads against direct urban egress".
#
#   A --(400m, secondary, maxspeed=90 -> stress 0.75)-------------> D   (direct)
#   A --(250m, residential)--> M --(250m, residential)------------> D   (quiet, longer)
# ---------------------------------------------------------------------------

_A, _D, _M = 1, 2, 3


def _direct_vs_quiet_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(_A, y=40.0000, x=-105.3000, elevation=100.0)
    g.add_node(_D, y=40.0050, x=-105.2950, elevation=100.0)
    g.add_node(_M, y=40.0025, x=-105.2975, elevation=100.0)
    g.add_edge(_A, _D, length=400.0, highway="secondary", maxspeed="90")
    g.add_edge(_A, _M, length=250.0, highway="residential")
    g.add_edge(_M, _D, length=250.0, highway="residential")
    return g


def _solve_traffic(graph: nx.MultiDiGraph, quiet: float):
    profile = _profile(quiet)
    path = _weighted_path(graph, _A, _D, profile)
    walk = edge_walk(graph, path, profile)
    return path, measure(graph, walk).traffic


def test_high_tolerance_takes_the_direct_busy_route():
    graph = _direct_vs_quiet_graph()
    path, _ = _solve_traffic(graph, 0.0)
    assert path == [_A, _D]


def test_low_tolerance_measurably_favors_the_lower_road_class_alternative():
    # AC: "at low tolerance the route measurably favors lower road classes where an
    # alternative exists" — the quiet, longer, residential route wins outright.
    graph = _direct_vs_quiet_graph()
    direct_path, direct_traffic = _solve_traffic(graph, 0.0)
    quiet_path, quiet_traffic = _solve_traffic(graph, 1.0)
    assert quiet_path == [_A, _M, _D]
    assert quiet_traffic < direct_traffic


def test_realised_traffic_exposure_decreases_monotonically_as_tolerance_drops():
    graph = _direct_vs_quiet_graph()
    tolerances = (0.0, 0.25, 0.5, 0.75, 1.0)  # rising "quiet" = falling car tolerance
    exposures = [_solve_traffic(graph, q)[1] for q in tolerances]
    assert exposures == sorted(exposures, reverse=True)
    assert exposures[0] > exposures[-1]
