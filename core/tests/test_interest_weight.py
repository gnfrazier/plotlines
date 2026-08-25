"""FR5/FR98 (Story A4) — the interest weight: a single 0.0-5.0 Author-facing
scalar mapped to `WeightProfile.interest`'s solver-internal 0.0..1.0 scale by
`weight_profile.dart`'s `interestFromAuthor` (ordinary `w = ui / 5.0`, unlike
`peaks`/`surface_*` — there is no bipolar "avoid good places" case).

Before this story `poi_density`/`poi_types` existed only in the Author-facing
payload and were never read by the solver at all (MVP punchlist §2.17b's fail
signal: "the scorer maximizes POI count rather than salience"). This is the
first test of `routing.interest.annotate_interest` (the join between
`curation.notability`'s salience-scored candidates and the routing graph) and
of `edge_cost`'s `interest` term.
"""

from dataclasses import dataclass

import networkx as nx
import pytest

from plotlines_core.routing.interest import DEFAULT_INTEREST_RADIUS_M, annotate_interest
from plotlines_core.routing.solve import _weighted_path
from plotlines_core.scoring.metrics import edge_walk, measure
from plotlines_core.scoring.profile import WeightProfile, edge_cost

# Isolates the interest term: every other weight is zero, so only
# `interest_salience` and `interest` drive `edge_cost`'s penalty.
_NEUTRAL = dict(quiet=0.0, scenic=0.0, directness=0.0, peaks=0.0)


def _profile(interest: float) -> WeightProfile:
    return WeightProfile(interest=interest, **_NEUTRAL)


@dataclass(frozen=True)
class _Candidate:
    """A minimal stand-in for `curation.notability.Candidate` — only the
    `coord`/`salience` fields `annotate_interest` actually reads."""

    coord: tuple[float, float]  # (lon, lat)
    salience: float


# ---------------------------------------------------------------------------
# edge_cost — the interest term, given a pre-annotated edge
# ---------------------------------------------------------------------------


def test_seeking_interest_discounts_a_salient_edge():
    edge = {"length": 100.0, "highway": "residential", "interest_salience": 0.8}
    neutral_cost = edge_cost(edge, _profile(0.0))
    seek_cost = edge_cost(edge, _profile(1.0))
    assert seek_cost < neutral_cost


def test_zero_interest_weight_is_indifferent_to_a_salient_edge():
    edge = {"length": 100.0, "highway": "residential", "interest_salience": 0.8}
    assert edge_cost(edge, _profile(0.0)) == pytest.approx(100.0)


def test_edge_with_no_salience_is_unaffected_by_the_interest_weight():
    edge = {"length": 100.0, "highway": "residential"}
    costs = {edge_cost(edge, _profile(w)) for w in (0.0, 0.25, 0.5, 0.75, 1.0)}
    assert len(costs) == 1


def test_edge_cost_is_monotonically_non_increasing_in_interest_for_a_salient_edge():
    edge = {"length": 100.0, "highway": "residential", "interest_salience": 1.0}
    costs = [edge_cost(edge, _profile(w)) for w in (0.0, 0.25, 0.5, 0.75, 1.0)]
    assert costs == sorted(costs, reverse=True)
    assert costs[0] > costs[-1]


def test_edge_cost_stays_strictly_positive_at_full_seek_and_full_salience():
    edge = {"length": 100.0, "highway": "residential", "interest_salience": 1.0}
    assert edge_cost(edge, _profile(1.0)) > 0.0


def test_higher_salience_is_discounted_more_than_lower_salience():
    low = {"length": 100.0, "highway": "residential", "interest_salience": 0.2}
    high = {"length": 100.0, "highway": "residential", "interest_salience": 0.9}
    profile = _profile(1.0)
    assert edge_cost(high, profile) < edge_cost(low, profile)


# ---------------------------------------------------------------------------
# annotate_interest — the candidate/graph join
# ---------------------------------------------------------------------------

_A, _D, _M, _S = 1, 2, 3, 4


#: M and S sit ~445m apart — well outside `DEFAULT_INTEREST_RADIUS_M` (150m) of
#: each other — so a candidate snapped onto one never bleeds salience onto the
#: other. `length` on each leg is independent of this real geo distance, same
#: as every other weight's synthetic graph in this test suite: `annotate_interest`
#: reads node coordinates (haversine), `edge_cost`/Dijkstra read `length`.
def _base_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(_A, y=40.0000, x=-105.3000, elevation=100.0)
    g.add_node(_D, y=40.0000, x=-105.2900, elevation=100.0)
    g.add_node(_M, y=40.0020, x=-105.2950, elevation=100.0)
    g.add_node(_S, y=39.9980, x=-105.2950, elevation=100.0)
    g.add_edge(_A, _M, length=150.0, highway="residential")
    g.add_edge(_M, _D, length=150.0, highway="residential")
    g.add_edge(_A, _S, length=149.0, highway="residential")
    g.add_edge(_S, _D, length=149.0, highway="residential")
    return g


def test_edges_near_a_candidate_are_annotated_with_its_salience():
    graph = _base_graph()
    candidates = [_Candidate(coord=(-105.2950, 40.0020), salience=0.9)]  # at M
    annotate_interest(graph, candidates)
    for u, v, data in graph.edges(data=True):
        if _M in (u, v):
            assert data["interest_salience"] == pytest.approx(0.9)


def test_edges_far_from_every_candidate_carry_no_key():
    graph = _base_graph()
    candidates = [_Candidate(coord=(-105.2950, 40.0020), salience=0.9)]  # at M only
    annotate_interest(graph, candidates)
    for u, v, data in graph.edges(data=True):
        if _M not in (u, v):
            assert "interest_salience" not in data


def test_multiple_candidates_near_one_edge_take_the_highest_salience_not_the_sum():
    # MVP punchlist §2.17b's fail signal: "the scorer maximizes POI count rather
    # than salience." Five low-salience candidates stacked at S must not out-value
    # the single high-salience one at M — see the routing test below for the
    # end-to-end version of this same claim.
    graph = _base_graph()
    candidates = [_Candidate(coord=(-105.2950, 39.9980), salience=0.2) for _ in range(5)]
    annotate_interest(graph, candidates)
    for u, v, data in graph.edges(data=True):
        if _S in (u, v):
            assert data["interest_salience"] == pytest.approx(0.2)


def test_a_candidate_with_zero_or_negative_salience_annotates_nothing():
    graph = _base_graph()
    candidates = [_Candidate(coord=(-105.2950, 40.0020), salience=0.0)]
    annotate_interest(graph, candidates)
    assert all("interest_salience" not in data for _u, _v, data in graph.edges(data=True))


def test_a_candidate_far_outside_the_radius_is_skipped_without_raising():
    graph = _base_graph()
    # ~1100 km away — nowhere near any node, let alone within radius_m.
    candidates = [_Candidate(coord=(0.0, 0.0), salience=0.9)]
    annotate_interest(graph, candidates, radius_m=DEFAULT_INTEREST_RADIUS_M)
    assert all("interest_salience" not in data for _u, _v, data in graph.edges(data=True))


def test_a_second_annotation_pass_clears_a_stale_score():
    graph = _base_graph()
    annotate_interest(graph, [_Candidate(coord=(-105.2950, 40.0020), salience=0.9)])
    assert any(data.get("interest_salience") for _u, _v, data in graph.edges(data=True))
    annotate_interest(graph, [])  # live layer set changed; nothing notable any more
    assert all("interest_salience" not in data for _u, _v, data in graph.edges(data=True))


# ---------------------------------------------------------------------------
# End to end: two near-equal-length A -> D routes, one past a single
# high-salience candidate, one past several low-salience candidates — the
# AC's own framing, "favours higher-salience candidates ... rather than
# maximizing a count".
#
#   A --(150m)--> M --(150m)--> D   one candidate,  salience 0.9
#   A --(149m)--> S --(149m)--> D   five candidates, salience 0.2 each
# ---------------------------------------------------------------------------


def _one_high_vs_many_low_graph() -> nx.MultiDiGraph:
    graph = _base_graph()
    candidates = [
        _Candidate(coord=(-105.2950, 40.0020), salience=0.9),  # at M
        *[_Candidate(coord=(-105.2950, 39.9980), salience=0.2) for _ in range(5)],  # at S
    ]
    return annotate_interest(graph, candidates)


def _solve(graph: nx.MultiDiGraph, profile: WeightProfile):
    path = _weighted_path(graph, _A, _D, profile)
    walk = edge_walk(graph, path, profile)
    return path, measure(graph, walk).distance_m


def test_indifferent_profile_takes_the_shorter_low_salience_route():
    graph = _one_high_vs_many_low_graph()
    path, _ = _solve(graph, _profile(0.0))
    assert path == [_A, _S, _D]  # 298m, shorter than the 300m via M


def test_seeking_interest_takes_the_single_high_salience_route_despite_more_length_and_fewer_places():
    graph = _one_high_vs_many_low_graph()
    path, _ = _solve(graph, _profile(1.0))
    assert path == [_A, _M, _D]


def test_realised_distance_shifts_with_the_weight_as_a_side_effect_of_seeking_quality():
    graph = _one_high_vs_many_low_graph()
    _, indifferent_distance = _solve(graph, _profile(0.0))
    _, seeking_distance = _solve(graph, _profile(1.0))
    assert seeking_distance > indifferent_distance
