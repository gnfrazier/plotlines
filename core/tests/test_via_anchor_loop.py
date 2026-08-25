"""Story A9 (issue #26) — routing a loop through one or two designated
via-anchors while still returning to start (FR8a).

`routing/loops.py` already implements this generically (SPIKE-01's point:
via-anchor, start, destination, loop and out-and-back are one solver call
with a different anchor list) but, like A6 before it (issue #23), had no
dedicated pytest coverage exercising that path — `generate_loop`/
`solve_circuit` were only ever reached indirectly through `search.py`'s own
tests, which never inspect `closed`/`hit_via`/the overlap split at all.

This covers A9's AC directly: one or two via-anchors are honoured absolutely
and the loop still closes on itself; target distance is still honoured
around them; the result is a genuine loop rather than an out-and-back, with
any road ridden twice reported (`overlap_near_frac`/`overlap_far_frac`);
and a via-anchor that cannot fit the distance envelope produces a best-effort
result rather than raising, which is what lets A6 (diagnose.py, already
tested in test_conflict_diagnosis.py) name it as the binding constraint.
"""

from __future__ import annotations

import math

import networkx as nx
import pytest

from plotlines_core.routing.loops import generate_loop, solve_circuit
from plotlines_core.routing.solve import NoRouteFound
from plotlines_core.scoring.profile import WeightProfile

# ---------------------------------------------------------------------------
# A routable lattice, the same shape `test_band_search.py` already proved
# `generate_loop` works against, plus one dead-end spur (`_CAFE`) hung off a
# single edge — the literal "café on a dead-end lane" `loops.py`'s module
# docstring and `DEFAULT_RELIEF_FRAC` describe. A spur is the deterministic
# way to exercise the near/far overlap split: reaching it *must* retrace that
# one edge (near, licensed), while the rest of a lattice this well-connected
# has no need to retrace anything (far, must stay low).
# ---------------------------------------------------------------------------

_ROWS = _COLS = 9
_SPACING_M = 150.0
_CENTER = (40.0000, -105.3000)
_M_PER_DEG_LAT = 111_320.0
_M_PER_DEG_LON = 111_320.0 * math.cos(math.radians(_CENTER[0]))


def _node_id(r: int, c: int) -> int:
    return r * _COLS + c


def _latlon(r: int, c: int) -> tuple[float, float]:
    clat, clon = _CENTER
    lat = clat + (r - _ROWS // 2) * _SPACING_M / _M_PER_DEG_LAT
    lon = clon + (c - _COLS // 2) * _SPACING_M / _M_PER_DEG_LON
    return lat, lon


#: Node ids are snapped through a numpy int64 array (`graph/loader.py`), so
#: the café spur needs an integer id too — one past the grid's own range.
_CAFE = _ROWS * _COLS


def _grid_graph(*, with_cafe_spur: bool = False) -> nx.MultiDiGraph:
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

    if with_cafe_spur:
        # Hangs off the grid's edge, away from any lattice shortcut, reached
        # by exactly one short edge — the only way there is back the same
        # way. Short on purpose: `generate_loop`'s relief zone (near-via
        # "lollipop" allowance) is a fraction of the target distance, and the
        # whole spur has to fit inside it for the overlap to attribute as
        # "near" rather than "far".
        spur_m = 50.0
        attach = _node_id(_ROWS - 1, _COLS - 1)
        alat, alon = _latlon(_ROWS - 1, _COLS - 1)
        cafe_lat = alat + spur_m / _M_PER_DEG_LAT
        cafe_lon = alon + spur_m / _M_PER_DEG_LON
        g.add_node(_CAFE, y=cafe_lat, x=cafe_lon, elevation=100.0 + 8.0 * (_ROWS - 1))
        g.add_edge(attach, _CAFE, length=spur_m, highway="residential")
        g.add_edge(_CAFE, attach, length=spur_m, highway="residential")

    return g


_START = _CENTER
_PROFILE = WeightProfile("balanced")


# ---------------------------------------------------------------------------
# AC: "One or two via-anchors on a loop; the route passes through each and
# returns to start."
# ---------------------------------------------------------------------------


def test_one_via_anchor_is_reached_and_the_loop_closes():
    via = _latlon(2, 6)
    loop = generate_loop(_grid_graph(), _START, 2400.0, _PROFILE, via=[via])
    assert loop.closed is True
    assert loop.hit_via is True
    assert loop.path[0] == loop.path[-1]
    assert len(loop.via_nodes) == 1
    assert loop.via_nodes[0] in loop.path


def test_two_via_anchors_are_both_reached_and_the_loop_closes():
    via_a, via_b = _latlon(2, 6), _latlon(6, 2)
    loop = generate_loop(_grid_graph(), _START, 3000.0, _PROFILE, via=[via_a, via_b])
    assert loop.closed is True
    assert loop.hit_via is True
    assert len(loop.via_nodes) == 2
    assert all(n in loop.path for n in loop.via_nodes)


def test_via_anchors_appear_on_the_path_in_the_order_the_author_gave_them():
    # solve_circuit chains legs in list order — the second via-anchor must
    # not be visited before the first, since that would not be "the same
    # order the Author designated them in."
    via_a, via_b = _latlon(2, 6), _latlon(6, 2)
    loop = generate_loop(_grid_graph(), _START, 3000.0, _PROFILE, via=[via_a, via_b])
    node_a, node_b = loop.via_nodes
    assert loop.path.index(node_a) < loop.path.index(node_b)


# ---------------------------------------------------------------------------
# AC: "weights and target distance still honored around them"
# ---------------------------------------------------------------------------


def test_target_distance_is_still_approximately_honoured_with_one_via_anchor():
    via = _latlon(2, 6)
    target_m = 2400.0
    loop = generate_loop(_grid_graph(), _START, target_m, _PROFILE, via=[via])
    assert loop.distance_error is not None
    # Generous bound — this asserts the shaping search is still doing its
    # job around a mandatory via-anchor, not pinning to `generate_loop`'s own
    # tighter default tolerance which A8's own tests already cover.
    assert abs(loop.distance_error) < 0.35


def test_target_distance_is_still_approximately_honoured_with_two_via_anchors():
    via_a, via_b = _latlon(2, 6), _latlon(6, 2)
    target_m = 3000.0
    loop = generate_loop(_grid_graph(), _START, target_m, _PROFILE, via=[via_a, via_b])
    assert loop.distance_error is not None
    assert abs(loop.distance_error) < 0.35


def test_a_peaks_weight_still_reaches_the_via_anchor_and_closes():
    # AC's "weights ... still honored around them" the other direction: a
    # non-neutral weight must not break via-anchor delivery or closure.
    via = _latlon(2, 6)
    climby = WeightProfile("climby", peaks=1.0)
    loop = generate_loop(_grid_graph(), _START, 2400.0, climby, via=[via])
    assert loop.closed is True
    assert loop.hit_via is True


# ---------------------------------------------------------------------------
# AC: "a genuine loop rather than an out-and-back, with any road ridden
# twice reported"
# ---------------------------------------------------------------------------


def test_a_dead_end_via_anchor_retraces_only_its_own_spur_not_the_whole_loop():
    graph = _grid_graph(with_cafe_spur=True)
    cafe_lat, cafe_lon = graph.nodes[_CAFE]["y"], graph.nodes[_CAFE]["x"]
    loop = generate_loop(graph, _START, 2600.0, _PROFILE, via=[(cafe_lat, cafe_lon)])

    assert loop.closed is True
    assert loop.hit_via is True
    assert loop.metrics is not None
    # The spur is the *only* way to the café, so reaching it and leaving it
    # must retrace that one edge — and it is attributed as "near" (licensed),
    # not counted against the loop being genuine.
    assert loop.metrics.overlap_near_frac > 0.0
    # The rest of this well-connected lattice has no structural need to
    # retrace anything, and the reuse penalty exists precisely to steer the
    # solver off any road it has already ridden out in the corridor.
    assert loop.metrics.overlap_far_frac < 0.1


def test_summary_reports_the_overlap_split_a9_needs_surfaced():
    # `Loop.summary()` is what `service/plotlines_service/app.py`'s
    # `_loop_to_dict` reads to answer "any road ridden twice reported" over
    # the wire — pin its shape here so a future refactor of `summary()`
    # cannot silently drop what the API contract depends on.
    via = _latlon(2, 6)
    loop = generate_loop(_grid_graph(), _START, 2400.0, _PROFILE, via=[via])
    summary = loop.summary()
    for key in ("overlap_frac", "overlap_near_frac", "overlap_far_frac", "closed", "hit_via"):
        assert key in summary


# ---------------------------------------------------------------------------
# AC: "if a via-anchor makes the loop infeasible within the distance
# envelope, A6 governs and names the via-anchor — not the terrain — as the
# binding constraint." A6's naming itself (`diagnose.py`) is already covered
# by `test_conflict_diagnosis.py`; what belongs here is the AC's
# precondition — that `generate_loop` hands back a best-effort result
# instead of raising, which is what makes that diagnosis possible at all.
# ---------------------------------------------------------------------------


def test_an_unreachable_target_with_a_via_anchor_returns_a_best_effort_not_an_exception():
    # The via-anchor alone is ~600 m of lattice distance from start each way;
    # asking for a 200 m loop through it cannot be honoured, but the via is
    # still mandatory, so this must come back as a large `distance_error`,
    # never a raised `NoRouteFound`.
    via = _latlon(2, 6)
    loop = generate_loop(_grid_graph(), _START, 200.0, _PROFILE, via=[via])
    assert loop.hit_via is True
    assert loop.closed is True
    assert loop.distance_error is not None
    assert loop.distance_error > 0.35  # materially larger than what was asked for


# ---------------------------------------------------------------------------
# `solve_circuit` itself — the primitive `generate_loop` and `search.py`
# both sit on top of. A via-anchor is `anchors`, never `optional`.
# ---------------------------------------------------------------------------


def test_solve_circuit_closes_a_two_via_circuit_back_on_its_start():
    graph = _grid_graph()
    start = _node_id(4, 4)
    via_a, via_b = _node_id(2, 6), _node_id(6, 2)
    circuit = solve_circuit(graph, [start, via_a, via_b], _PROFILE, close=True)
    assert circuit.path[0] == start
    assert circuit.path[-1] == start
    assert via_a in circuit.path
    assert via_b in circuit.path


def test_solve_circuit_never_drops_an_unreachable_via_anchor_as_optional():
    # `generate_loop`/the service layer never add via-anchors to `optional` —
    # only the synthesised shaping ring gets that treatment. Calling
    # `solve_circuit` the same way a via-anchor request does (nothing marked
    # optional) must raise rather than silently continue without it.
    graph = _grid_graph()
    start = _node_id(4, 4)
    isolated = "island"
    graph.add_node(isolated, y=41.0, x=-106.0, elevation=100.0)  # far away, no edges at all
    with pytest.raises(NoRouteFound):
        solve_circuit(graph, [start, isolated], _PROFILE, close=True)
