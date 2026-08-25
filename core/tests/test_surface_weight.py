"""FR4 (Story A3) — the surface weight ("paved"/"gravel"/"singletrack"): each class
independently 0.0-5.0 decimal on the Author-facing side, mapped to
`WeightProfile.surface_paved`/`surface_gravel`/`surface_singletrack`'s solver-internal
bipolar -1.0..1.0 scale by `weight_profile.dart`'s `surfaceWeightsFromAuthor`, the same
shape and reason as FR2's `peaks` (`profile.py`'s module doc / SPIKE-03: a unipolar dial
can only ever tolerate a class, never seek it).

Before this story the solver's `surface` dial was a single unipolar 0.0..1.0 "prefer
good pavement" scalar with no way to positively seek gravel or singletrack — the exact
gap SPIKE-03 measured (no unpaved-minimum band was ever satisfiable). No test
previously existed for `surface_bucket`'s classification or `edge_cost`'s surface term.
"""

import networkx as nx
import pytest

from plotlines_core.routing.solve import _weighted_path
from plotlines_core.scoring.metrics import edge_walk, measure
from plotlines_core.scoring.profile import WeightProfile, edge_cost, features, surface_bucket

# Isolates the surface terms: every other weight is zero, so only `highway`/`surface`
# and the three surface_* fields drive `edge_cost`'s penalty.
_NEUTRAL = dict(quiet=0.0, scenic=0.0, directness=0.0, peaks=0.0)


def _profile(**surface_weights) -> WeightProfile:
    return WeightProfile(**_NEUTRAL, **surface_weights)


# ---------------------------------------------------------------------------
# surface_bucket — the three-way classification
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("surface", ["asphalt", "paved", "concrete", "paving_stones"])
def test_paved_surface_tag_classifies_as_paved(surface):
    assert surface_bucket("residential", {"surface": surface}) == "paved"


@pytest.mark.parametrize("surface", ["gravel", "fine_gravel", "compacted", "dirt"])
def test_unpaved_surface_on_a_road_class_classifies_as_gravel(surface):
    assert surface_bucket("track", {"surface": surface}) == "gravel"
    assert surface_bucket("residential", {"surface": surface}) == "gravel"


@pytest.mark.parametrize("surface", ["gravel", "dirt", "ground", "rock"])
def test_unpaved_surface_on_a_trail_way_classifies_as_singletrack(surface):
    assert surface_bucket("path", {"surface": surface}) == "singletrack"
    assert surface_bucket("bridleway", {"surface": surface}) == "singletrack"


def test_untagged_surface_on_a_trail_way_classifies_as_singletrack():
    # SPIKE-03 measured surface tag coverage as low as 24.5% — a narrow trail way
    # with no surface tag is still the strongest available signal for singletrack.
    assert surface_bucket("path", {}) == "singletrack"


def test_untagged_surface_elsewhere_is_unknown():
    assert surface_bucket("residential", {}) is None
    assert surface_bucket("track", {}) is None


def test_paved_surface_on_a_trail_way_still_classifies_as_paved():
    # A paved path/bridleway is a greenway, not singletrack (osm_reference.md's
    # greenway note) — tread material wins over way width when both are tagged.
    assert surface_bucket("path", {"surface": "asphalt"}) == "paved"


def test_unrecognised_surface_value_is_unknown():
    assert surface_bucket("residential", {"surface": "some_future_osm_tag"}) is None


# ---------------------------------------------------------------------------
# edge_cost — the three surface terms
# ---------------------------------------------------------------------------


def test_seeking_gravel_discounts_a_gravel_edge():
    edge = {"length": 100.0, "highway": "track", "surface": "gravel"}
    neutral_cost = edge_cost(edge, _profile())
    seek_cost = edge_cost(edge, _profile(surface_gravel=1.0))
    assert seek_cost < neutral_cost


def test_avoiding_gravel_charges_a_gravel_edge():
    edge = {"length": 100.0, "highway": "track", "surface": "gravel"}
    neutral_cost = edge_cost(edge, _profile())
    avoid_cost = edge_cost(edge, _profile(surface_gravel=-1.0))
    assert avoid_cost > neutral_cost


def test_seeking_singletrack_discounts_a_singletrack_edge_but_not_a_gravel_edge():
    singletrack = {"length": 100.0, "highway": "path", "surface": "dirt"}
    gravel = {"length": 100.0, "highway": "track", "surface": "gravel"}
    profile = _profile(surface_singletrack=1.0)
    assert edge_cost(singletrack, profile) < edge_cost(singletrack, _profile())
    assert edge_cost(gravel, profile) == edge_cost(gravel, _profile())


def test_seeking_paved_discounts_a_paved_edge_and_charges_nothing_else():
    paved = {"length": 100.0, "highway": "residential", "surface": "asphalt"}
    gravel = {"length": 100.0, "highway": "track", "surface": "gravel"}
    profile = _profile(surface_paved=1.0)
    assert edge_cost(paved, profile) < edge_cost(paved, _profile())
    assert edge_cost(gravel, profile) == edge_cost(gravel, _profile())


def test_classes_are_independent_seeking_gravel_does_not_move_a_paved_edge():
    paved = {"length": 100.0, "highway": "residential", "surface": "asphalt"}
    assert edge_cost(paved, _profile(surface_gravel=1.0)) == edge_cost(paved, _profile())


def test_edge_with_unknown_surface_is_unaffected_by_any_surface_weight():
    unknown = {"length": 100.0, "highway": "residential"}
    costs = {
        edge_cost(unknown, _profile(surface_paved=p, surface_gravel=g, surface_singletrack=s))
        for p, g, s in ((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (-1.0, -1.0, -1.0))
    }
    assert len(costs) == 1


def test_edge_cost_is_monotonically_non_increasing_in_gravel_weight_for_a_gravel_edge():
    edge = {"length": 100.0, "highway": "track", "surface": "gravel"}
    costs = [edge_cost(edge, _profile(surface_gravel=w)) for w in (-1.0, -0.5, 0.0, 0.5, 1.0)]
    assert costs == sorted(costs, reverse=True)
    assert costs[0] > costs[-1]


def test_edge_cost_stays_strictly_positive_at_full_seek():
    edge = {"length": 100.0, "highway": "path", "surface": "dirt"}
    assert edge_cost(edge, _profile(surface_singletrack=1.0)) > 0.0


def test_features_carries_the_surface_bucket():
    edge = {"length": 100.0, "highway": "path", "surface": "dirt"}
    assert features(edge)[5] == "singletrack"


# ---------------------------------------------------------------------------
# A synthetic graph with three A -> D routes over paved, gravel, and singletrack
# surface — the AC's own framing, "the engine can be pointed at seeking gravel or
# singletrack".
#
#   A --(400m, residential, asphalt)---------------------------> D   (paved)
#   A --(150m, track, gravel)--> M --(150m, track, gravel)-----> D   (gravel, shortest)
#   A --(230m, path, dirt)-----> S --(230m, path, dirt)--------> D   (singletrack, longest)
# ---------------------------------------------------------------------------

_A, _D, _M, _S = 1, 2, 3, 4


def _three_surfaces_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(_A, y=40.0000, x=-105.3000, elevation=100.0)
    g.add_node(_D, y=40.0050, x=-105.2950, elevation=100.0)
    g.add_node(_M, y=40.0025, x=-105.2975, elevation=100.0)
    g.add_node(_S, y=40.0020, x=-105.2980, elevation=100.0)
    g.add_edge(_A, _D, length=400.0, highway="residential", surface="asphalt")
    g.add_edge(_A, _M, length=150.0, highway="track", surface="gravel")
    g.add_edge(_M, _D, length=150.0, highway="track", surface="gravel")
    g.add_edge(_A, _S, length=230.0, highway="path", surface="dirt")
    g.add_edge(_S, _D, length=230.0, highway="path", surface="dirt")
    return g


def _solve(graph: nx.MultiDiGraph, profile: WeightProfile):
    path = _weighted_path(graph, _A, _D, profile)
    walk = edge_walk(graph, path, profile)
    return path, measure(graph, walk).unpaved_frac


def test_indifferent_profile_takes_the_shortest_route():
    graph = _three_surfaces_graph()
    path, _ = _solve(graph, _profile())
    assert path == [_A, _M, _D]  # 300m, shortest of the three


def test_seeking_gravel_outright_takes_the_gravel_route():
    graph = _three_surfaces_graph()
    path, _ = _solve(graph, _profile(surface_gravel=1.0))
    assert path == [_A, _M, _D]


def test_seeking_singletrack_outright_takes_the_singletrack_route():
    # AC: "the engine can be pointed at seeking ... singletrack" — both the paved
    # (400m) and gravel (300m) routes are shorter, so only a real seek (not mere
    # tolerance) picks singletrack (460m) over either.
    graph = _three_surfaces_graph()
    path, _ = _solve(graph, _profile(surface_singletrack=1.0))
    assert path == [_A, _S, _D]


def test_avoiding_both_unpaved_classes_takes_the_paved_route_despite_being_longest():
    graph = _three_surfaces_graph()
    path, _ = _solve(graph, _profile(surface_gravel=-1.0, surface_singletrack=-1.0))
    assert path == [_A, _D]


def test_realised_surface_breakdown_shifts_with_the_weights():
    # AC: "the route's surface breakdown is reported and shifts with the weights."
    graph = _three_surfaces_graph()
    _, paved_unpaved_frac = _solve(graph, _profile(surface_gravel=-1.0, surface_singletrack=-1.0))
    _, gravel_unpaved_frac = _solve(graph, _profile(surface_gravel=1.0))
    _, singletrack_unpaved_frac = _solve(graph, _profile(surface_singletrack=1.0))
    assert paved_unpaved_frac == 0.0
    assert gravel_unpaved_frac == pytest.approx(1.0)
    assert singletrack_unpaved_frac == pytest.approx(1.0)
