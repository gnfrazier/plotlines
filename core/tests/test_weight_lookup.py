"""Story M2 (issue #130) — the solver resolves weights per edge via
`weights.at(position)` (FR36, ARCH §7.6).

M2 is an architectural-seam story: scoped/segment-varying weighting is future
work, but the *lookup* through which it will arrive exists from day one. These
tests pin the three acceptance criteria:

  * the solver obtains weights through `weights.at(position)`;
  * the scalar case returns the same profile object on every call, for every
    position, and produces byte-identical routes whether the caller passes a
    `WeightProfile` or the `Weights` wrapper around it;
  * introducing scopes changes only the lookup — a scoped `Weights` flows
    through `_weighted_path` / `generate_segment` unchanged, and where a single
    scope covers the whole route it is indistinguishable from passing that
    scope's profile directly.
"""

from __future__ import annotations

import networkx as nx

from plotlines_core.routing.solve import _weighted_path, generate_segment
from plotlines_core.scoring.profile import (
    WeightProfile,
    Weights,
    WeightScope,
    edge_cost,
)

# ---------------------------------------------------------------------------
# Weights.at — the lookup itself
# ---------------------------------------------------------------------------

_SCALAR = WeightProfile("scalar", quiet=0.7)


def test_scalar_at_returns_the_same_object_every_call():
    weights = Weights.of(_SCALAR)
    got = [weights.at(p) for p in (0.0, 0.1, 0.5, 0.9, 1.0)]
    assert all(g is _SCALAR for g in got)


def test_scalar_at_ignores_position_and_needs_no_argument():
    weights = Weights.of(_SCALAR)
    assert weights.at() is _SCALAR
    assert weights.at(0.0) is weights.at(1.0)


def test_of_passes_a_weights_through_unchanged():
    weights = Weights.of(_SCALAR)
    assert Weights.of(weights) is weights


def test_of_wraps_a_bare_profile():
    weights = Weights.of(_SCALAR)
    assert isinstance(weights, Weights)
    assert weights.default is _SCALAR


# ---------------------------------------------------------------------------
# Weights.scoped — the future case, exercised through the same seam
# ---------------------------------------------------------------------------

_DEFAULT = WeightProfile("tour", quiet=0.2)
_DAY = WeightProfile("day-2", quiet=0.9, scenic=0.9)
_PASSAGE = WeightProfile("morning-climb", peaks=1.0)


def test_scoped_returns_the_governing_profile_then_falls_back_to_default():
    weights = Weights.scoped(_DEFAULT, [(0.25, 0.75, _DAY)])
    assert weights.at(0.0) is _DEFAULT
    assert weights.at(0.24) is _DEFAULT
    assert weights.at(0.25) is _DAY       # half-open: start is inside
    assert weights.at(0.5) is _DAY
    assert weights.at(0.75) is _DEFAULT   # half-open: end is outside
    assert weights.at(1.0) is _DEFAULT


def test_scoped_first_covering_scope_wins():
    weights = Weights.scoped(
        _DEFAULT,
        [(0.0, 0.5, _DAY), (0.3, 1.0, _PASSAGE)],
    )
    assert weights.at(0.4) is _DAY        # both cover 0.4; the first listed wins
    assert weights.at(0.6) is _PASSAGE


def test_scoped_accepts_weightscope_objects_too():
    weights = Weights.scoped(_DEFAULT, [WeightScope(0.0, 1.0, _DAY)])
    assert weights.at(0.5) is _DAY


def test_empty_scope_list_is_just_the_scalar_case():
    weights = Weights.scoped(_DEFAULT, [])
    assert weights.at(0.3) is _DEFAULT


# ---------------------------------------------------------------------------
# The solver reads through the lookup — a synthetic two-route graph where the
# profile in force decides which way the solve goes.
#
#   A --(quiet lane, 1200m, high traffic-stress)------------------> B
#   A --(busy road,  1000m, low  traffic-stress)------------------> B
#
# `quiet` high  -> the longer low-stress lane; `quiet` ~0 -> the short road.
# ---------------------------------------------------------------------------

_A, _B = 1, 2

_QUIET = WeightProfile("quiet", quiet=1.0, directness=0.0)
_DIRECT = WeightProfile("direct", quiet=0.0, directness=1.0)


def _two_route_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(_A, y=40.0000, x=-105.3000)
    g.add_node(_B, y=40.0000, x=-105.2800)
    # The scenic-but-long option: a calm residential lane.
    g.add_edge(_A, _B, length=1200.0, highway="residential")
    # The short option: a hostile trunk road (a real posted speed is what lifts
    # its traffic stress off the D33 baseline).
    g.add_edge(_A, _B, length=1000.0, highway="trunk", maxspeed="100")
    return g


def test_weighted_path_accepts_a_bare_profile_and_a_weights_wrapper():
    graph = _two_route_graph()
    bare = _weighted_path(graph, _A, _B, _QUIET)
    wrapped = _weighted_path(graph, _A, _B, Weights.of(_QUIET))
    assert bare == wrapped == [_A, _B]


def test_solver_follows_whichever_profile_the_lookup_yields():
    graph = _two_route_graph()

    # Scalar quiet -> takes the calm 1200 m lane.
    quiet_walk = _weighted_path(graph, _A, _B, _QUIET)
    quiet_edge = min(graph[quiet_walk[0]][quiet_walk[1]].values(),
                     key=lambda d: edge_cost(d, _QUIET))
    assert quiet_edge["highway"] == "residential"

    # Scalar direct -> takes the short 1000 m trunk road.
    direct_walk = _weighted_path(graph, _A, _B, _DIRECT)
    direct_edge = min(graph[direct_walk[0]][direct_walk[1]].values(),
                      key=lambda d: edge_cost(d, _DIRECT))
    assert direct_edge["highway"] == "trunk"


def test_single_scope_over_whole_route_matches_passing_that_profile_directly():
    graph = _two_route_graph()
    whole = Weights.scoped(_DIRECT, [(0.0, 1.0001, _QUIET)])

    scoped_edge = min(
        graph[_A][_B].values(),
        key=lambda d: edge_cost(d, whole.at(0.5)),
    )
    scalar_edge = min(
        graph[_A][_B].values(),
        key=lambda d: edge_cost(d, _QUIET),
    )
    assert scoped_edge["highway"] == scalar_edge["highway"] == "residential"


# ---------------------------------------------------------------------------
# generate_segment — the public entry point is transparent to the wrapper
# ---------------------------------------------------------------------------


def _routable_line() -> nx.MultiDiGraph:
    """A --B--C--D chain with parallel calm/short options on the middle leg."""
    g = nx.MultiDiGraph()
    coords = {1: -105.300, 2: -105.290, 3: -105.280, 4: -105.270}
    for n, x in coords.items():
        g.add_node(n, y=40.0, x=x)
    for u, v in ((1, 2), (2, 3), (3, 4)):
        g.add_edge(u, v, length=900.0, highway="residential")
        g.add_edge(v, u, length=900.0, highway="residential")
    return g


def test_generate_segment_scalar_profile_and_wrapper_are_identical():
    graph = _routable_line()
    start, end = (40.0, -105.300), (40.0, -105.270)

    bare = generate_segment(graph, start, end, _QUIET, mode="cycling")
    wrapped = generate_segment(graph, start, end, Weights.of(_QUIET), mode="cycling")

    assert bare.coordinates == wrapped.coordinates
    assert bare.distance_m == wrapped.distance_m
    assert bare.theme == wrapped.theme == "quiet"


def test_generate_segment_accepts_a_scoped_weights():
    graph = _routable_line()
    start, end = (40.0, -105.300), (40.0, -105.270)

    scoped = Weights.scoped(_DIRECT, [(0.4, 0.6, _QUIET)])
    seg = generate_segment(graph, start, end, scoped, mode="cycling")

    # Reaches the destination and reports the tour-default identity, not a scope's.
    assert seg.coordinates[0] == [-105.300, 40.0]
    assert seg.coordinates[-1] == [-105.270, 40.0]
    assert seg.theme == "direct"
