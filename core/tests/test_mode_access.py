"""Story A11 (issue #29) — mode-legal routability (FR128).

`routing/access.py` is where the routability-constraint column
`docs/osm_reference.md` always carried, and v1.0 never enforced, becomes
engine behaviour: access tags are hard constraints, `bicycle=dismount` is
surfaced rather than silently rolled through, barriers/fords/waterway
obstacles are accounted for, contraflow permission is honoured, and a
constraint that forces a materially worse route is named through A6's
existing conflict path (ARCH §7.9) rather than a new one.

Three layers of coverage:

  * `evaluate_edge` — the pure per-edge verdict, one test per AC bullet.
  * `mode_legal_graph` / `_add_contraflow_edges` — the graph-build-time
    transform, checked directly against the resulting graph structure.
  * `generate_loop`/`generate_segment` — the real routing entry points,
    proving the filter actually governs a solve rather than existing only
    as an unused pure function.
"""

from __future__ import annotations

import math

import networkx as nx
import pytest

from plotlines_core.routing.access import (
    MODE_CONSTRAINTS,
    climbing_access_closed,
    evaluate_edge,
    flags_along_walk,
    mode_legal_graph,
)
from plotlines_core.routing.diagnose import diagnose
from plotlines_core.routing.loops import generate_loop
from plotlines_core.routing.solve import NoRouteFound, generate_segment
from plotlines_core.scoring.bands import Band, BandSet
from plotlines_core.scoring.metrics import pick_edge
from plotlines_core.scoring.profile import WeightProfile

# ---------------------------------------------------------------------------
# evaluate_edge — hard exclusions (AC: "access tags honored as hard
# constraints")
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("value", ["no", "use_sidepath", "destination"])
def test_cycling_hard_excludes_the_listed_bicycle_access_values(value):
    verdict = evaluate_edge({"highway": "residential", "bicycle": value}, "cycling")
    assert verdict.passable is False
    assert verdict.reason == f"bicycle={value}"


def test_hiking_hard_excludes_foot_no():
    verdict = evaluate_edge({"highway": "path", "foot": "no"}, "hiking")
    assert verdict.passable is False
    assert verdict.reason == "foot=no"


@pytest.mark.parametrize("value", ["no", "private", "permit"])
def test_paddling_hard_excludes_the_listed_canoe_access_values(value):
    verdict = evaluate_edge({"waterway": "stream", "canoe": value}, "paddling")
    assert verdict.passable is False
    assert verdict.reason == f"canoe={value}"


def test_generic_access_no_excludes_when_the_mode_tag_is_silent():
    # OSM's access hierarchy: no `bicycle=*` opinion on this edge at all, so
    # the generic `access=*` tag governs.
    verdict = evaluate_edge({"highway": "residential", "access": "no"}, "cycling")
    assert verdict.passable is False
    assert verdict.reason == "access=no"


def test_a_mode_specific_grant_overrides_a_restrictive_generic_access_tag():
    # `access=private, bicycle=yes`: the mode-specific tag wins outright,
    # never merges with the generic one (real OSM access-tag semantics).
    verdict = evaluate_edge(
        {"highway": "residential", "access": "private", "bicycle": "yes"}, "cycling"
    )
    assert verdict.passable is True


def test_an_unconfigured_mode_is_unconstrained():
    # FR128: "the seed set for the modes shipping first, not a closed list."
    # A mode this module has no opinion on must route exactly as before A11.
    verdict = evaluate_edge({"highway": "residential", "bicycle": "no"}, "driving")
    assert verdict.passable is True
    assert verdict.flags == frozenset()


def test_a_merged_way_list_tag_is_checked_across_every_value_not_just_the_first():
    # Real fixture data (Boulder): `bicycle=['dismount', 'designated']` after
    # way-merging. A hard-exclusion or surfaced-constraint check that only
    # looked at the first list element could silently miss the constraint.
    verdict = evaluate_edge(
        {"highway": "path", "bicycle": ["designated", "no"]}, "cycling"
    )
    assert verdict.passable is False
    assert verdict.reason == "bicycle=no"


# ---------------------------------------------------------------------------
# evaluate_edge — surfaced constraint (AC: "bicycle=dismount sections
# surfaced explicitly rather than silently routed through")
# ---------------------------------------------------------------------------


def test_bicycle_dismount_stays_routable_but_is_flagged():
    verdict = evaluate_edge({"highway": "path", "bicycle": "dismount"}, "cycling")
    assert verdict.passable is True
    assert "bicycle=dismount" in verdict.flags


def test_dismount_paired_with_designated_in_a_merged_way_is_still_flagged():
    verdict = evaluate_edge(
        {"highway": "path", "bicycle": ["dismount", "designated"]}, "cycling"
    )
    assert verdict.passable is True
    assert "bicycle=dismount" in verdict.flags


def test_dismount_is_not_a_cycling_specific_flag_for_a_mode_it_does_not_apply_to():
    # `bicycle=dismount` says nothing about foot access.
    verdict = evaluate_edge({"highway": "path", "bicycle": "dismount"}, "hiking")
    assert verdict.passable is True
    assert verdict.flags == frozenset()


# ---------------------------------------------------------------------------
# evaluate_edge — barriers (AC: "barriers accounted for with their own
# access values")
# ---------------------------------------------------------------------------


def test_cycle_barrier_with_no_override_is_routable_but_flagged_for_cycling():
    verdict = evaluate_edge({"highway": "path", "barrier": "cycle_barrier"}, "cycling")
    assert verdict.passable is True
    assert "barrier=cycle_barrier" in verdict.flags


def test_bollard_with_no_override_is_routable_and_unflagged_for_cycling():
    # osm_reference.md: "usually still bike-passable, verify."
    verdict = evaluate_edge({"highway": "path", "barrier": "bollard"}, "cycling")
    assert verdict.passable is True
    assert verdict.flags == frozenset()


def test_gate_with_no_override_is_routable_but_flagged():
    verdict = evaluate_edge({"highway": "path", "barrier": "gate"}, "cycling")
    assert verdict.passable is True
    assert "barrier=gate" in verdict.flags


def test_gate_excluded_when_its_own_access_value_denies_the_mode():
    # `bicycle=no` on the edge is read as governing the gate sitting on it
    # (module docstring's stated simplification) — the ordinary access check
    # already catches this before the barrier check runs, and the edge ends
    # up excluded either way.
    verdict = evaluate_edge(
        {"highway": "path", "barrier": "gate", "bicycle": "no"}, "cycling"
    )
    assert verdict.passable is False
    assert verdict.reason == "bicycle=no"


def test_gate_passes_cleanly_when_its_own_access_value_grants_the_mode():
    verdict = evaluate_edge(
        {"highway": "path", "barrier": "gate", "bicycle": "yes"}, "cycling"
    )
    assert verdict.passable is True
    assert verdict.flags == frozenset()


def test_a_cycle_specific_barrier_is_not_a_pedestrian_obstacle():
    verdict = evaluate_edge({"highway": "path", "barrier": "cycle_barrier"}, "hiking")
    assert verdict.passable is True
    assert verdict.flags == frozenset()


def test_barriers_are_meaningless_on_the_paddling_graph():
    verdict = evaluate_edge({"barrier": "gate"}, "paddling")
    assert verdict.passable is True
    assert verdict.flags == frozenset()


# ---------------------------------------------------------------------------
# evaluate_edge — fords (AC: "fords ... treated as constraints")
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("value", ["yes", "stepping_stones"])
def test_a_ford_excludes_a_mode_that_cannot_cross_it(value):
    verdict = evaluate_edge({"highway": "path", "ford": value}, "cycling")
    assert verdict.passable is False
    assert verdict.reason == f"ford={value}"


@pytest.mark.parametrize("value", ["yes", "stepping_stones"])
def test_a_ford_stays_routable_but_flagged_for_a_mode_that_can_cross_it(value):
    verdict = evaluate_edge({"highway": "path", "ford": value}, "hiking")
    assert verdict.passable is True
    assert f"ford={value}" in verdict.flags


def test_ford_is_not_a_question_on_the_paddling_graph():
    verdict = evaluate_edge({"ford": "yes"}, "paddling")
    assert verdict.passable is True
    assert verdict.flags == frozenset()


# ---------------------------------------------------------------------------
# evaluate_edge — hard waterway obstacles (AC: "hard waterway obstacles
# (weir, lock_gate, waterfall, hazard) treated as constraints")
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("value", ["weir", "lock_gate", "waterfall", "hazard"])
def test_hard_waterway_obstacles_exclude_paddling(value):
    verdict = evaluate_edge({"waterway": value}, "paddling")
    assert verdict.passable is False
    assert verdict.reason == f"waterway={value}"


def test_waterway_obstacles_do_not_affect_a_mode_that_never_touches_water():
    verdict = evaluate_edge({"waterway": "weir"}, "cycling")
    assert verdict.passable is True


# ---------------------------------------------------------------------------
# climbing:access (AC: "climbing access closures respected where a station
# is authored") — the governing-rule predicate; see module docstring for why
# nothing here wires it into a station model yet.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("value", ["no", "private", "closed", "permit"])
def test_climbing_access_closed_values_are_recognised(value):
    assert climbing_access_closed({"climbing:access": value}) is True


def test_climbing_access_open_values_are_not_closed():
    assert climbing_access_closed({"climbing:access": "yes"}) is False


def test_climbing_access_absent_is_not_guessed_into_closed():
    assert climbing_access_closed({}) is False


def test_climbing_access_closed_checks_every_value_in_a_merged_list():
    assert climbing_access_closed({"climbing:access": ["yes", "no"]}) is True


# ---------------------------------------------------------------------------
# flags_along_walk — pure summarisation helper
# ---------------------------------------------------------------------------


def test_flags_along_walk_reports_only_the_flagged_hops_in_order():
    walk = [
        (1, 2, {"_pl_access_flags": ["bicycle=dismount"]}),
        (2, 3, {}),
        (3, 4, {"_pl_access_flags": ["barrier=gate"]}),
    ]
    assert flags_along_walk(walk) == [
        {"from": 1, "to": 2, "flags": ["bicycle=dismount"]},
        {"from": 3, "to": 4, "flags": ["barrier=gate"]},
    ]


# ---------------------------------------------------------------------------
# mode_legal_graph — graph-build-time transform (AC/ARCH §7.9: "edge removed
# from the mode's graph", never merely penalized)
# ---------------------------------------------------------------------------


def _two_node_graph(**edge_tags) -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(1, y=40.0, x=-105.0, elevation=100.0)
    g.add_node(2, y=40.001, x=-105.0, elevation=100.0)
    g.add_edge(1, 2, length=100.0, highway="residential", **edge_tags)
    return g


def test_mode_legal_graph_removes_a_hard_excluded_edge_entirely():
    graph = _two_node_graph(bicycle="no")
    filtered = mode_legal_graph(graph, "cycling")
    assert filtered.number_of_edges() == 0
    # the source graph itself is untouched — filtering must not mutate what
    # a concurrent request against another mode is also reading.
    assert graph.number_of_edges() == 1


def test_mode_legal_graph_keeps_and_flags_a_surfaced_constraint_edge():
    graph = _two_node_graph(bicycle="dismount")
    filtered = mode_legal_graph(graph, "cycling")
    assert filtered.number_of_edges() == 1
    data = next(iter(filtered.get_edge_data(1, 2).values()))
    assert data["_pl_access_flags"] == ["bicycle=dismount"]


def test_mode_legal_graph_passes_through_unchanged_for_an_unconfigured_mode():
    # Driving gained a `MODE_CONSTRAINTS` row with B1/FR29 (it is a routed
    # traversal mode now, not a note), so the "no opinion anywhere" case needs
    # a mode nothing configures — `multimodal.modes` has no row for this one
    # either, which is the whole point.
    graph = _two_node_graph(bicycle="no")
    assert mode_legal_graph(graph, "teleportation") is graph


def test_mode_legal_graph_is_cached_per_mode():
    graph = _two_node_graph()
    first = mode_legal_graph(graph, "cycling")
    second = mode_legal_graph(graph, "cycling")
    assert first is second


def test_mode_legal_graph_caches_separately_per_mode():
    graph = _two_node_graph(foot="no")
    cycling = mode_legal_graph(graph, "cycling")
    hiking = mode_legal_graph(graph, "hiking")
    assert cycling is not hiking
    assert cycling.number_of_edges() == 1   # foot=no doesn't touch cycling
    assert hiking.number_of_edges() == 0    # but excludes hiking


# ---------------------------------------------------------------------------
# Contraflow (AC: "contraflow permission (oneway:bicycle=no) respected")
# ---------------------------------------------------------------------------


def test_a_genuinely_one_way_edge_gets_no_contraflow_by_default():
    graph = _two_node_graph()
    filtered = mode_legal_graph(graph, "cycling")
    assert filtered.has_edge(2, 1) is False


def test_oneway_bicycle_no_adds_the_missing_contraflow_edge_for_cycling():
    graph = _two_node_graph(**{"oneway": "yes", "oneway:bicycle": "no"})
    filtered = mode_legal_graph(graph, "cycling")
    assert filtered.has_edge(2, 1) is True
    assert filtered.has_edge(1, 2) is True
    # the source graph is still genuinely one-way — the addition lives only
    # on the mode-filtered copy.
    assert graph.has_edge(2, 1) is False


def test_oneway_bicycle_no_does_not_duplicate_an_already_bidirectional_edge():
    graph = _two_node_graph(**{"oneway": "yes", "oneway:bicycle": "no"})
    graph.add_edge(2, 1, length=100.0, highway="residential")
    filtered = mode_legal_graph(graph, "cycling")
    assert filtered.number_of_edges(2, 1) == 1


def test_contraflow_is_not_added_for_a_mode_that_does_not_honour_it():
    graph = _two_node_graph(**{"oneway": "yes", "oneway:bicycle": "no"})
    filtered = mode_legal_graph(graph, "hiking")
    assert filtered.has_edge(2, 1) is False


# ---------------------------------------------------------------------------
# Real routing entry points — the filter actually governs a solve, not just
# a pure function nothing calls.
# ---------------------------------------------------------------------------


def _two_route_graph(bicycle_tag: str = "no") -> nx.MultiDiGraph:
    """A cheap, tempting direct edge and a longer, unrestricted detour.

    Deliberately much cheaper than the detour (length 10 vs 150+150+150) so
    an ordinary shortest-path solve would always prefer it — only a hard
    exclusion, not merely a cost preference, can keep a mode off it.
    """
    g = nx.MultiDiGraph()
    coords = {
        0: (40.0000, -105.3000),
        1: (40.0000, -105.2985),
        2: (40.0015, -105.3010),
        3: (40.0015, -105.2990),
    }
    for n, (lat, lon) in coords.items():
        g.add_node(n, y=lat, x=lon, elevation=100.0)
    g.add_edge(0, 1, length=10.0, highway="residential", bicycle=bicycle_tag)
    g.add_edge(1, 0, length=10.0, highway="residential", bicycle=bicycle_tag)
    for a, b in ((0, 2), (2, 0), (2, 3), (3, 2), (3, 1), (1, 3)):
        g.add_edge(a, b, length=150.0, highway="residential")
    return g


_START_XY = (40.0000, -105.3000)
_END_XY = (40.0000, -105.2985)


def test_generate_segment_never_takes_a_bicycle_no_edge_even_when_cheapest():
    graph = _two_route_graph(bicycle_tag="no")
    profile = WeightProfile("balanced")

    # Proves the test is meaningful: an unfiltered solve really would prefer
    # the excluded edge, since it's an order of magnitude cheaper.
    direct = pick_edge(graph, 0, 1, profile)
    assert direct.get("bicycle") == "no"

    segment = generate_segment(graph, _START_XY, _END_XY, profile, mode="cycling")
    assert segment.node_count == 4  # forced onto the 0-2-3-1 detour
    assert segment.surfaced_constraints == []


def test_generate_segment_takes_the_cheap_edge_for_a_mode_it_does_not_restrict():
    graph = _two_route_graph(bicycle_tag="no")
    profile = WeightProfile("balanced")
    segment = generate_segment(graph, _START_XY, _END_XY, profile, mode="hiking")
    assert segment.node_count == 2  # foot=no was never set, so the direct edge stands


def test_generate_segment_surfaces_a_dismount_edge_it_actually_used():
    graph = _two_route_graph(bicycle_tag="dismount")
    profile = WeightProfile("balanced")
    segment = generate_segment(graph, _START_XY, _END_XY, profile, mode="cycling")
    assert segment.node_count == 2  # still routable, just flagged
    assert segment.surfaced_constraints == [
        {"from": 0, "to": 1, "flags": ["bicycle=dismount"]}
    ]


def test_generate_segment_honours_contraflow_a_raw_one_way_graph_would_block():
    g = nx.MultiDiGraph()
    g.add_node(1, y=40.0, x=-105.0, elevation=100.0)
    g.add_node(2, y=40.001, x=-105.0, elevation=100.0)
    g.add_edge(1, 2, length=100.0, highway="residential",
               **{"oneway": "yes", "oneway:bicycle": "no"})
    profile = WeightProfile("balanced")

    with pytest.raises(NoRouteFound):
        generate_segment(g, (40.001, -105.0), (40.0, -105.0), profile, mode="hiking")

    # cycling gets the contraflow edge back and can make the same trip
    segment = generate_segment(g, (40.001, -105.0), (40.0, -105.0), profile, mode="cycling")
    assert segment.node_count == 2


# ---------------------------------------------------------------------------
# generate_loop / diagnose — the same lattice-plus-spur shape
# `test_via_anchor_loop.py` already established, reused here with the spur
# tagged as a hard exclusion. A mandatory via-anchor reachable only across an
# excluded edge is the deterministic way to force real infeasibility without
# fighting `generate_loop`'s emergent anchor-ring placement.
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


_CAFE = _ROWS * _COLS


def _grid_graph_with_excluded_spur(bicycle_tag: str | None = "no") -> nx.MultiDiGraph:
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

    spur_m = 50.0
    attach = _node_id(_ROWS - 1, _COLS - 1)
    alat, alon = _latlon(_ROWS - 1, _COLS - 1)
    cafe_lat = alat + spur_m / _M_PER_DEG_LAT
    cafe_lon = alon + spur_m / _M_PER_DEG_LON
    g.add_node(_CAFE, y=cafe_lat, x=cafe_lon, elevation=100.0 + 8.0 * (_ROWS - 1))
    tags = {"highway": "residential"}
    if bicycle_tag is not None:
        tags["bicycle"] = bicycle_tag
    g.add_edge(attach, _CAFE, length=spur_m, **tags)
    g.add_edge(_CAFE, attach, length=spur_m, **tags)
    return g


_PROFILE = WeightProfile("balanced")


def test_generate_loop_raises_when_the_only_approach_to_a_via_anchor_is_excluded():
    graph = _grid_graph_with_excluded_spur(bicycle_tag="no")
    cafe = (graph.nodes[_CAFE]["y"], graph.nodes[_CAFE]["x"])
    with pytest.raises(NoRouteFound):
        generate_loop(graph, _CENTER, 2600.0, _PROFILE, via=[cafe], mode="cycling")


def test_generate_loop_reaches_the_same_via_anchor_for_a_mode_it_does_not_restrict():
    graph = _grid_graph_with_excluded_spur(bicycle_tag="no")
    cafe = (graph.nodes[_CAFE]["y"], graph.nodes[_CAFE]["x"])
    loop = generate_loop(graph, _CENTER, 2600.0, _PROFILE, via=[cafe], mode="hiking")
    assert loop.closed is True
    assert loop.hit_via is True


def test_generate_loop_with_no_access_tags_at_all_is_unaffected_by_mode_filtering():
    # Regression check: an ordinary lattice with nothing to constrain must
    # still close a loop and report no surfaced constraints under the new
    # default `mode="cycling"` parameter — A11 must not change existing
    # A7/A9 behaviour for a graph with no routability tags on it.
    graph = _grid_graph_with_excluded_spur(bicycle_tag=None)
    cafe = (graph.nodes[_CAFE]["y"], graph.nodes[_CAFE]["x"])
    loop = generate_loop(graph, _CENTER, 2600.0, _PROFILE, via=[cafe])
    assert loop.closed is True
    assert loop.hit_via is True
    assert loop.surfaced_constraints == []


def test_diagnose_names_the_via_anchor_conflict_a_hard_exclusion_causes():
    # A6's existing via-implicated path (ARCH §7.9: "named through A6's
    # existing conflict path") fires exactly the same way an ordinary
    # distance conflict would — no access-specific branch was needed in
    # diagnose.py, only threading `mode` down to the searches it already runs.
    # Because the via-anchor is *completely* unreachable for cycling (not
    # merely a distance overshoot), every band — even one this scenario
    # would otherwise satisfy easily — reads as unattainable alongside it.
    graph = _grid_graph_with_excluded_spur(bicycle_tag="no")
    cafe = (graph.nodes[_CAFE]["y"], graph.nodes[_CAFE]["x"])
    bands = BandSet.of(Band("climb_m", minimum=0.0))

    result = diagnose(graph, _CENTER, 2600.0, bands, via=[cafe], mode="cycling")

    assert result.feasible is False
    assert result.via_implicated is True
    assert result.via_relaxation is not None
    assert result.via_relaxation["action"] == "drop_via_nodes"
    assert {b.metric for b in result.conflict} == {"climb_m", "distance_m"}


def test_diagnose_is_unaffected_for_a_mode_the_exclusion_does_not_apply_to():
    # Same scenario, `mode="hiking"` — `bicycle=no` never touches `foot`, so
    # the via-anchor is legally reachable. What's left is this fixture's own
    # unrelated distance-band tightness (the spur's fixed length vs. a ±10%
    # default band), never the wholesale "nothing gets there at all" that
    # cycling's real exclusion produced — the tell is that `climb_m`, trivially
    # satisfiable once the via-anchor is reachable at all, drops out of the
    # conflict entirely.
    graph = _grid_graph_with_excluded_spur(bicycle_tag="no")
    cafe = (graph.nodes[_CAFE]["y"], graph.nodes[_CAFE]["x"])
    bands = BandSet.of(Band("climb_m", minimum=0.0))

    result = diagnose(graph, _CENTER, 2600.0, bands, via=[cafe], mode="hiking")

    assert {b.metric for b in result.conflict} == {"distance_m"}
