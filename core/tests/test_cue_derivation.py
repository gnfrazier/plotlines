"""The derived half of the cue sheet — turns, surfaces, coalescing, merging.

#235 B1. `cues.py` reported 76% line coverage while a mutation run killed 3 of
25 mutants: the module was executed, almost exclusively through the service
endpoint test, and its decisions were asserted nowhere. Every threshold in
`CueSettings` could be inverted and the suite stayed green.

`test_cue_transitions.py` is the companion to this file and deliberately stays
scoped to B3's transition path. This one covers what a Character actually reads
off a handlebar: which junctions become turns, which do not, how several turns
inside twenty metres become one line, and what `derive_cue_sheet` assembles.

Geometry is synthetic and exact — a straight line stepped in known increments,
with bends composed by hand — because the assertions here are about thresholds,
not about whether OSMnx drew a curve. `graph` is a real `networkx.MultiDiGraph`
so `turn_cues`' `to_undirected` / `degree` calls are the real ones.
"""

from __future__ import annotations

import math

import networkx as nx
import pytest

from plotlines_core.trips.cues import (
    Cue,
    CueSettings,
    Route,
    RouteEdge,
    _coalesce_turns,
    _merge,
    _retrace_pass,
    bearing_deg,
    cues_per_window,
    derive_cue_sheet,
    haversine_m,
    same_way,
    signed_turn,
    surface_class,
    surface_cues,
    turn_cues,
    way_name,
)

_LAT = 40.0
#: Degrees of longitude that make 1 m at 40°N — lets a test say "100 m east".
_M_LON = 1.0 / (math.cos(math.radians(_LAT)) * math.pi * 6_371_000.0 / 180.0)
_M_LAT = 1.0 / (math.pi * 6_371_000.0 / 180.0)


def _east(metres: float) -> list[float]:
    return [-105.30 + _M_LON * metres, _LAT]


def _at(east_m: float, north_m: float) -> list[float]:
    return [-105.30 + _M_LON * east_m, _LAT + _M_LAT * north_m]


def _route(coords: list[list[float]]) -> Route:
    cumulative = [0.0]
    for a, b in zip(coords, coords[1:]):
        cumulative.append(cumulative[-1] + haversine_m(tuple(a), tuple(b)))
    return Route(coords=coords, cumulative_m=cumulative, edges=[])


# ── geometry primitives ──────────────────────────────────────────────────


def test_a_bearing_is_measured_clockwise_from_north():
    assert bearing_deg((0.0, 0.0), (0.0, 1.0)) == pytest.approx(0.0, abs=0.5)
    assert bearing_deg((0.0, 0.0), (1.0, 0.0)) == pytest.approx(90.0, abs=0.5)
    assert bearing_deg((0.0, 1.0), (0.0, 0.0)) == pytest.approx(180.0, abs=0.5)


@pytest.mark.parametrize("before,after,expected", [
    (0.0, 90.0, 90.0),      # right
    (0.0, 270.0, -90.0),    # left, the short way round
    (350.0, 10.0, 20.0),    # across north
    (10.0, 350.0, -20.0),
    (0.0, 180.0, 180.0),    # a reversal
])
def test_a_turn_is_signed_and_takes_the_short_way_round(before, after, expected):
    """Sign is what "left" and "right" mean, and 350°->10° must read as a 20°
    bear right rather than a 340° sweep the other way."""
    assert signed_turn(before, after) == pytest.approx(expected)


def test_bearing_before_averages_the_window_rather_than_the_last_vertex():
    """At 10 m the kerb radius dominates; the window is why a cue says "turn
    left" and not "bear left then left"."""
    coords = [_at(0, 0), _at(30, 0), _at(60, 0), _at(60, 30)]
    route = _route(coords)

    # Arriving at index 2 over a 25 m window: still due east.
    assert route.bearing_before(2, 25.0) == pytest.approx(90.0, abs=1.0)
    # Leaving index 2 over the same window: due north.
    assert route.bearing_after(2, 25.0) == pytest.approx(0.0, abs=1.0)


def test_the_window_walk_stops_at_the_ends_of_the_route():
    """`bearing_before` at the first vertex has nothing behind it — the loop
    guard is what stops it walking off the front of the list."""
    route = _route([_east(0), _east(100), _east(200)])
    assert route.bearing_before(0, 25.0) is None
    assert route.bearing_after(len(route.coords) - 1, 25.0) is None


def test_a_window_wider_than_the_route_falls_back_to_what_there_is():
    """A 25 m window on a 5 m route must still produce a bearing rather than
    None, or a short connector would cue nothing at all."""
    route = _route([_east(0), _east(5), _east(10)])
    assert route.bearing_before(1, 500.0) is not None
    assert route.bearing_after(1, 500.0) is not None


def test_a_window_shorter_than_one_segment_still_uses_the_adjacent_vertex():
    """`start = max(0, index - 1)` — the fallback that keeps a 1 m window from
    returning None on a coarse polyline."""
    route = _route([_east(0), _east(100), _east(200)])
    assert route.bearing_before(1, 0.5) == pytest.approx(90.0, abs=1.0)


def test_the_window_spans_every_vertex_inside_it_not_just_the_previous_one():
    """The fallback to `index - 1` applies only when the walk found nothing —
    it must not replace a walk that legitimately crossed several vertices.

    Here 30 m of northbound run is followed by a 10 m eastbound tail. Over a
    25 m window the arriving bearing is the blend (~18°); collapsing to the
    last vertex alone would report a due-east 90° and turn a left-hand dogleg
    into a straight-on.
    """
    route = _route([_at(0, 0), _at(0, 30), _at(10, 30)])

    assert route.bearing_before(2, 25.0) == pytest.approx(18.4, abs=1.5)


def test_the_leaving_window_likewise_spans_every_vertex_inside_it():
    route = _route([_at(0, 0), _at(10, 0), _at(10, 30)])

    assert route.bearing_after(0, 25.0) == pytest.approx(18.4, abs=1.5)


def test_point_at_interpolates_between_vertices():
    route = _route([_east(0), _east(100)])
    midpoint = route.point_at(50.0)
    assert midpoint[0] == pytest.approx(_east(50)[0], abs=1e-6)


def test_point_at_clamps_past_the_end_rather_than_extrapolating():
    route = _route([_east(0), _east(100)])
    assert route.point_at(10_000.0) == route.coords[-1]


def test_project_finds_the_nearest_point_and_its_offset():
    route = _route([_east(0), _east(100), _east(200)])
    along, offset = route.project(_at(50, 10))
    assert along == pytest.approx(50.0, abs=1.0)
    assert offset == pytest.approx(10.0, abs=1.0)


# ── way identity and labelling ───────────────────────────────────────────


def test_two_edges_of_the_same_named_way_are_the_same_way():
    """Name first — that is what a rider verifies against a signpost."""
    assert same_way({"name": "Broadway"}, {"name": "Broadway"})
    assert not same_way({"name": "Broadway"}, {"name": "Pearl"})


def test_unnamed_edges_fall_back_to_shared_osm_ids():
    """54% of Boulder's edges are unnamed; ids are weaker than a name but do not
    confuse two different service roads the way a label would."""
    assert same_way({"osmid": 12}, {"osmid": [12, 13]})
    assert not same_way({"osmid": 12}, {"osmid": 99})


def test_an_unnamed_continuation_of_a_named_way_is_still_the_same_way():
    """The name test needs *both* sides named before it can decide. A named
    stretch running into an unnamed one that shares its OSM id is the same road
    — treating the missing name as a mismatch would cue "turn" every time a
    road's tagging ran out, which on 54%-unnamed coverage is constant."""
    assert same_way({"name": "Broadway", "osmid": 1}, {"osmid": 1})
    assert same_way({"osmid": 1}, {"name": "Broadway", "osmid": 1})
    assert not same_way({"name": "Broadway", "osmid": 1}, {"osmid": 99})


def test_a_named_way_never_matches_a_differently_named_one_via_ids():
    """Name wins outright when both sides have one — otherwise a shared id on a
    renamed stretch would suppress a real turn."""
    assert not same_way({"name": "Broadway", "osmid": 12},
                        {"name": "Pearl", "osmid": 12})


def test_a_multi_valued_name_takes_the_first():
    assert way_name({"name": ["Broadway", "US-36"]}) == "Broadway"
    assert way_name({}) is None


# ── surface classification ───────────────────────────────────────────────


@pytest.mark.parametrize("tags,expected", [
    ({"surface": "asphalt"}, "paved"),
    ({"surface": "gravel"}, "gravel"),
    ({}, None),
    ({"surface": "unknown-to-us"}, None),
])
def test_a_surface_is_classified_or_left_unknown(tags, expected):
    """Unknown is unknown: a gap in tagging must not read as a change."""
    assert surface_class(tags) == expected


def _surface_route(runs: list[tuple[str | None, float]]) -> Route:
    """A route of consecutive `(surface, length_m)` edges."""
    edges: list[RouteEdge] = []
    at = 0.0
    for index, (surface, length) in enumerate(runs):
        data = {} if surface is None else {"surface": surface}
        edges.append(RouteEdge(u=index, v=index + 1, data=data, start_m=at,
                               end_m=at + length, start_index=index,
                               end_index=index + 1))
        at += length
    coords = [_east(e.start_m) for e in edges] + [_east(at)]
    return Route(coords=coords, cumulative_m=[e.start_m for e in edges] + [at],
                 edges=edges)


def test_a_sustained_surface_change_is_announced():
    cues, stats = surface_cues(
        _surface_route([("asphalt", 500.0), ("gravel", 500.0)]), CueSettings())

    assert [c.instruction for c in cues] == ["Surface changes to gravel"]
    assert cues[0].distance_along_m == 500.0
    assert stats["emitted"] == 1
    assert stats["raw_transitions"] == 1


def test_a_short_apron_is_not_a_surface_change():
    """"A 20 m concrete apron across a driveway is not a surface change." Below
    `surface_min_run_m` it is suppressed, and the count is reported."""
    cues, stats = surface_cues(
        _surface_route([("asphalt", 500.0), ("gravel", 20.0), ("asphalt", 500.0)]),
        CueSettings())

    assert cues == []
    assert stats["suppressed_short"] == 2


def test_a_run_is_judged_against_the_setting_not_a_hardcoded_length():
    route = _surface_route([("asphalt", 200.0), ("gravel", 200.0)])
    assert surface_cues(route, CueSettings(surface_min_run_m=150.0))[1]["emitted"] == 1
    assert surface_cues(route, CueSettings(surface_min_run_m=400.0))[1]["emitted"] == 0


def test_a_gap_in_tagging_neither_opens_nor_closes_a_cue():
    """The filter that matters on thin coverage: only a *known* class following a
    different *known* class is a change. Untagged edges are skipped entirely, so
    paved-unknown-paved is one run, not two changes."""
    cues, stats = surface_cues(
        _surface_route([("asphalt", 500.0), (None, 500.0), ("asphalt", 500.0)]),
        CueSettings())

    assert cues == []
    assert stats["known_runs"] == 1


def test_consecutive_edges_of_the_same_class_are_one_run():
    _cues, stats = surface_cues(
        _surface_route([("asphalt", 300.0), ("asphalt", 300.0), ("gravel", 300.0)]),
        CueSettings())
    assert stats["known_runs"] == 2
    assert stats["emitted"] == 1


# ── turn derivation ──────────────────────────────────────────────────────


def _turn_graph(degree: int = 3, *, names: tuple[str, str] = ("A", "B")) -> nx.MultiDiGraph:
    """A -> junction -> B, with `degree - 2` extra stubs off the junction so
    `undirected.degree(junction)` is exactly `degree`."""
    g = nx.MultiDiGraph()
    g.add_edge(1, 2, name=names[0], osmid=1)
    g.add_edge(2, 3, name=names[1], osmid=2)
    for extra in range(degree - 2):
        g.add_edge(2, 100 + extra, name=f"stub{extra}", osmid=50 + extra)
    return g


def _bend_route(turn_deg: float, *, leg_m: float = 100.0) -> Route:
    """Two legs meeting at a junction, the second rotated `turn_deg` clockwise."""
    heading = math.radians(turn_deg)
    a = _at(0, 0)
    b = _at(leg_m, 0)
    c = _at(leg_m + leg_m * math.cos(heading), leg_m * -math.sin(heading))
    coords = [a, b, c]
    cumulative = [0.0, leg_m, leg_m * 2]
    edges = [
        RouteEdge(u=1, v=2, data={"name": "A", "osmid": 1}, start_m=0.0,
                  end_m=leg_m, start_index=0, end_index=1),
        RouteEdge(u=2, v=3, data={"name": "B", "osmid": 2}, start_m=leg_m,
                  end_m=leg_m * 2, start_index=1, end_index=2),
    ]
    return Route(coords=coords, cumulative_m=cumulative, edges=edges)


def test_a_real_turn_at_a_junction_is_cued_with_its_target():
    """"Turn left" with no object is the cue people misread — the rider needs to
    know what they are turning onto."""
    cues, stats = turn_cues(_turn_graph(), _bend_route(-90.0), CueSettings())

    assert len(cues) == 1
    assert cues[0].instruction == "Turn left onto B"
    assert cues[0].modifier == "left"
    assert cues[0].distance_along_m == 100.0
    assert stats["emitted"] == 1
    assert stats["junctions"] == 1


@pytest.mark.parametrize("turn_deg,modifier,text", [
    (-90.0, "left", "Turn left"),
    (90.0, "right", "Turn right"),
    (-35.0, "slight_left", "Bear left"),
    (35.0, "slight_right", "Bear right"),
    (-130.0, "sharp_left", "Sharp left"),
    (130.0, "sharp_right", "Sharp right"),
])
def test_the_bearing_change_picks_the_modifier(turn_deg, modifier, text):
    """Every band in `_modifier`. Inverting any of `slight_deg`/`sharp_deg`
    silently relabels manoeuvres — the rider is told to bear left at a 130°
    hairpin."""
    cues, _ = turn_cues(_turn_graph(), _bend_route(turn_deg), CueSettings())

    assert cues[0].modifier == modifier
    assert cues[0].instruction.startswith(text)


def test_a_gentle_bend_is_continue_and_emits_nothing():
    """Below `straight_deg` a junction says "continue", which is to say it says
    nothing."""
    cues, stats = turn_cues(_turn_graph(), _bend_route(10.0), CueSettings())

    assert cues == []
    assert stats["bend_below_threshold"] == 1
    assert stats["emitted"] == 0


def test_the_straight_threshold_is_the_setting_not_a_constant():
    route = _bend_route(35.0)
    assert turn_cues(_turn_graph(), route, CueSettings(straight_deg=30.0))[1]["emitted"] == 1
    assert turn_cues(_turn_graph(), route, CueSettings(straight_deg=45.0))[1]["emitted"] == 0


def test_a_bend_with_nowhere_else_to_go_is_not_a_decision():
    """"Boulder's switchbacks live here: real geometry, no decision." Degree 2
    means the road bent and the rider had no choice to make."""
    cues, stats = turn_cues(_turn_graph(degree=2), _bend_route(-90.0), CueSettings())

    assert cues == []
    assert stats["no_alternative"] == 1


def test_the_junction_degree_threshold_is_the_setting():
    route = _bend_route(-90.0)
    graph = _turn_graph(degree=3)
    assert turn_cues(graph, route, CueSettings(junction_min_degree=3))[1]["emitted"] == 1
    assert turn_cues(graph, route, CueSettings(junction_min_degree=4))[1]["emitted"] == 0


def test_a_reversal_is_cued_even_at_a_dead_end():
    """"A dead end has degree 1" — and the turnaround on a spur is the one cue
    nobody may miss, so it overrides the degree filter."""
    cues, stats = turn_cues(_turn_graph(degree=2), _bend_route(179.0), CueSettings())

    assert len(cues) == 1
    assert cues[0].modifier == "uturn"
    assert stats["reversals"] == 1


def test_a_reversal_at_a_true_dead_end_reads_as_the_end_of_the_road():
    """Degree 1: there is no way to name, so "Turn back at the end" rather than
    "Turn back onto ...", which would be nonsense."""
    graph = nx.MultiDiGraph()
    graph.add_edge(1, 2, name="A", osmid=1)
    cues, _ = turn_cues(graph, _bend_route(179.0), CueSettings())

    assert cues[0].instruction == "Turn back at the end"


def test_always_cue_reversal_can_be_turned_off():
    route = _bend_route(179.0)
    graph = _turn_graph(degree=2)
    assert turn_cues(graph, route, CueSettings(always_cue_reversal=False))[1]["emitted"] == 0


def test_staying_on_the_same_road_is_not_a_manoeuvre():
    """"A greenway bends through 60° at every bridge and keeps its own name
    throughout" — the single largest source of noise on a path-heavy route."""
    graph = _turn_graph(names=("Boulder Creek Path", "Boulder Creek Path"))
    route = _bend_route(-60.0)
    route.edges[0].data = {"name": "Boulder Creek Path", "osmid": 1}
    route.edges[1].data = {"name": "Boulder Creek Path", "osmid": 1}

    cues, stats = turn_cues(graph, route, CueSettings())

    assert cues == []
    assert stats["same_way_continuation"] == 1


def test_a_sharp_turn_onto_your_own_road_is_still_announced():
    """"Above `sharp_deg` the rule lifts, because a reversal on your own road
    still has to be announced." """
    graph = _turn_graph(names=("Same", "Same"))
    route = _bend_route(-130.0)
    route.edges[0].data = {"name": "Same", "osmid": 1}
    route.edges[1].data = {"name": "Same", "osmid": 1}

    cues, _ = turn_cues(graph, route, CueSettings())

    assert len(cues) == 1
    assert cues[0].modifier == "sharp_left"


def test_same_way_suppression_can_be_turned_off():
    graph = _turn_graph(names=("Same", "Same"))
    route = _bend_route(-60.0)
    route.edges[0].data = {"name": "Same", "osmid": 1}
    route.edges[1].data = {"name": "Same", "osmid": 1}

    assert turn_cues(graph, route, CueSettings(suppress_same_way=False))[1]["emitted"] == 1


def test_an_unnamed_way_is_described_by_its_kind():
    """A rider needs to know whether they are looking for a road or a trail."""
    graph = _turn_graph()
    route = _bend_route(-90.0)
    route.edges[1].data = {"highway": "cycleway", "osmid": 2}

    cues, _ = turn_cues(graph, route, CueSettings())

    assert cues[0].instruction == "Turn left onto the bike path"


def test_a_retraced_edge_marks_its_turn():
    graph = _turn_graph()
    route = _bend_route(-90.0)
    route.edges[1].repeat = 1

    cues, _ = turn_cues(graph, route, CueSettings())

    assert cues[0].retrace is True


# ── coalescing several turns into one manoeuvre ──────────────────────────


def _turn(distance_m: float, modifier: str, onto: str = "Main") -> Cue:
    text = {"left": "Turn left", "right": "Turn right",
            "slight_left": "Bear left", "slight_right": "Bear right",
            "sharp_left": "Sharp left", "sharp_right": "Sharp right",
            "uturn": "Turn back"}[modifier]
    return Cue(sequence=0, distance_along_m=distance_m, kind="turn",
               instruction=f"{text} onto {onto}", modifier=modifier)


def test_a_staggered_crossing_becomes_one_jog_cue():
    """"Four cues in twenty metres at a single path/road interchange. A rider
    executing it makes one decision, so it is one line." """
    coalesced = _coalesce_turns(
        [_turn(100.0, "left", "Crossing"), _turn(120.0, "right", "Pearl")],
        CueSettings())

    assert len(coalesced) == 1
    assert coalesced[0].instruction == "Jog left then right onto Pearl"
    assert coalesced[0].modifier == "jog_left_right"


def test_a_jog_the_other_way_reads_the_other_way_round():
    coalesced = _coalesce_turns(
        [_turn(100.0, "right"), _turn(120.0, "left")], CueSettings())

    assert coalesced[0].instruction.startswith("Jog right then left")
    assert coalesced[0].modifier == "jog_right_left"


def test_two_turns_the_same_way_coalesce_without_becoming_a_jog():
    """A jog is a there-and-back. Two lefts in twenty metres is one left, not
    "jog left then left"."""
    coalesced = _coalesce_turns(
        [_turn(100.0, "left"), _turn(115.0, "left")], CueSettings())

    assert len(coalesced) == 1
    assert coalesced[0].modifier == "left"
    assert "Jog" not in coalesced[0].instruction


def test_turns_further_apart_than_the_jog_window_stay_separate():
    coalesced = _coalesce_turns(
        [_turn(100.0, "left"), _turn(200.0, "right")], CueSettings())

    assert len(coalesced) == 2


def test_the_jog_window_is_the_setting():
    cues = [_turn(100.0, "left"), _turn(130.0, "right")]
    assert len(_coalesce_turns(cues, CueSettings(jog_window_m=40.0))) == 1
    assert len(_coalesce_turns(cues, CueSettings(jog_window_m=20.0))) == 2


def test_a_uturn_never_coalesces_into_a_neighbouring_turn():
    """"A U-turn never coalesces — it is the spur turnaround, and it is the one
    cue on the sheet nobody may miss." """
    coalesced = _coalesce_turns(
        [_turn(100.0, "left"), _turn(110.0, "uturn")], CueSettings())

    assert len(coalesced) == 2
    assert coalesced[1].modifier == "uturn"


def test_two_adjacent_uturns_are_one_turnaround_seen_twice():
    """"An artefact of how the circuit re-enters a node, not two manoeuvres."""
    coalesced = _coalesce_turns(
        [_turn(100.0, "uturn"), _turn(115.0, "uturn")], CueSettings())

    assert len(coalesced) == 1
    assert coalesced[0].modifier == "uturn"


def test_two_uturns_far_apart_are_two_turnarounds():
    coalesced = _coalesce_turns(
        [_turn(100.0, "uturn"), _turn(900.0, "uturn")], CueSettings())
    assert len(coalesced) == 2


def test_a_coalesced_cue_keeps_the_retrace_flag_of_either_half():
    a = _turn(100.0, "left")
    b = Cue(sequence=0, distance_along_m=115.0, kind="turn",
            instruction="Turn right onto Pearl", modifier="right", retrace=True)

    assert _coalesce_turns([a, b], CueSettings())[0].retrace is True


def test_coalescing_an_empty_sheet_is_a_no_op():
    assert _coalesce_turns([], CueSettings()) == []


# ── the merge pass ───────────────────────────────────────────────────────


def _cue(distance_m: float, kind: str, text: str) -> Cue:
    return Cue(sequence=0, distance_along_m=distance_m, kind=kind, instruction=text)


def test_advisory_crowding_collapses_into_one_line():
    """"Two POIs and a surface note within 20 m are one line on a cue sheet." """
    merged, stats = _merge(
        [_cue(100.0, "node", "Point of interest: Overlook"),
         _cue(110.0, "surface", "Surface changes to gravel")],
        CueSettings())

    assert len(merged) == 1
    assert merged[0].instruction == (
        "Point of interest: Overlook (Surface changes to gravel)")
    assert stats["merged_away"] == 1


def test_the_higher_priority_cue_keeps_its_own_voice():
    """The absorbed cue goes in parentheses; the kept one leads. A surface note
    must not become the headline over a node."""
    merged, _ = _merge(
        [_cue(110.0, "surface", "Surface changes to gravel"),
         _cue(100.0, "node", "Point of interest: Overlook")],
        CueSettings())

    assert merged[0].kind == "node"
    assert merged[0].instruction.startswith("Point of interest")


def test_a_hazard_beside_a_turn_stays_two_lines():
    """"A rider who reads one line and looks up must not have missed the other."
    The asymmetry is the whole point of the rule."""
    merged, _ = _merge(
        [_cue(100.0, "turn", "Turn left onto Main"),
         _cue(105.0, "hazard", "Weir — portage river left")],
        CueSettings())

    assert len(merged) == 2
    assert {c.kind for c in merged} == {"turn", "hazard"}


def test_a_hazard_leads_when_it_shares_a_distance_with_a_turn():
    merged, _ = _merge(
        [_cue(100.0, "turn", "Turn left"), _cue(100.0, "hazard", "Weir")],
        CueSettings())
    assert merged[0].kind == "hazard"


def test_two_turns_never_merge_into_each_other():
    """Coalescing is `_coalesce_turns`' job and has its own rules; the merge pass
    must not quietly do a second, blunter version of it."""
    merged, _ = _merge(
        [_cue(100.0, "turn", "Turn left onto Main"),
         _cue(110.0, "turn", "Turn right onto Pearl")],
        CueSettings())

    assert len(merged) == 2


def test_cues_further_apart_than_the_merge_window_stay_separate():
    merged, _ = _merge(
        [_cue(100.0, "node", "A"), _cue(400.0, "surface", "B")], CueSettings())
    assert len(merged) == 2


def test_the_merge_window_is_the_setting():
    cues = [_cue(100.0, "node", "A"), _cue(120.0, "surface", "B")]
    assert len(_merge(cues, CueSettings(merge_window_m=25.0))[0]) == 1
    assert len(_merge(cues, CueSettings(merge_window_m=10.0))[0]) == 2


def test_the_merged_sheet_is_ordered_and_sequenced_from_zero():
    merged, _ = _merge(
        [_cue(900.0, "node", "C"), _cue(100.0, "node", "A"), _cue(500.0, "node", "B")],
        CueSettings())

    assert [c.instruction for c in merged] == ["A", "B", "C"]
    assert [c.sequence for c in merged] == [0, 1, 2]


def test_merging_an_empty_sheet_is_a_no_op():
    merged, stats = _merge([], CueSettings())
    assert merged == []
    assert stats == {"before": 0, "merged_away": 0, "after": 0}


# ── the retrace pass ─────────────────────────────────────────────────────


def _retrace_route(span: tuple[float, float]) -> Route:
    edge = RouteEdge(u=1, v=2, data={}, start_m=span[0], end_m=span[1],
                     start_index=0, end_index=1, repeat=1)
    return Route(coords=[_east(0), _east(1000)], cumulative_m=[0.0, 1000.0],
                 edges=[edge])


def test_a_cue_standing_on_road_already_ridden_is_marked():
    """"The instruction is right, the context is missing." SPIKE-01's lollipop:
    a rider turns off a road they were supposed to stay on."""
    cues = [_cue(500.0, "turn", "Turn left onto Main")]
    stats = _retrace_pass(cues, _retrace_route((400.0, 600.0)))

    assert cues[0].retrace is True
    assert stats["cues_marked"] == 1
    assert stats["retraced_span_m"] == 200.0


def test_a_cue_outside_every_retraced_span_is_left_alone():
    cues = [_cue(900.0, "turn", "Turn left")]
    _retrace_pass(cues, _retrace_route((400.0, 600.0)))
    assert cues[0].retrace is None


def test_the_finish_of_a_loop_is_not_labelled_a_retrace():
    """"A loop finishes where it started, so its last cue always sits on road
    already ridden. Saying so adds nothing: 'Arrive (retrace)' is noise." """
    cues = [_cue(500.0, "start", "Start"), _cue(500.0, "finish", "Finish")]
    stats = _retrace_pass(cues, _retrace_route((0.0, 1000.0)))

    assert all(c.retrace is None for c in cues)
    assert stats["cues_marked"] == 0


# ── density reporting ────────────────────────────────────────────────────


def test_cues_are_bucketed_by_window_so_the_peak_is_visible():
    """"The peak matters, not just the mean" — a sheet that averages 3/km but
    puts 15 in one kilometre is not glanceable."""
    cues = [_cue(float(m), "turn", "t") for m in (10, 20, 30, 1500, 2500)]
    assert cues_per_window(cues, 1000.0, 3000.0) == [3, 1, 1, 0]


def test_a_cue_past_the_last_window_lands_in_it_rather_than_overflowing():
    cues = [_cue(9999.0, "turn", "t")]
    assert cues_per_window(cues, 1000.0, 1000.0) == [0, 1]


def test_a_zero_length_route_has_no_windows():
    assert cues_per_window([_cue(0.0, "turn", "t")], 1000.0, 0.0) == []


# ── derive_cue_sheet, end to end ─────────────────────────────────────────


def _grid_graph() -> tuple[nx.MultiDiGraph, list[tuple[int, int, dict]]]:
    """A dog-leg: 300 m east on Broadway, 300 m north on Pearl. Node 2 carries
    two extra stubs so the corner is a real junction."""
    g = nx.MultiDiGraph()
    g.add_node(1, x=_at(0, 0)[0], y=_at(0, 0)[1])
    g.add_node(2, x=_at(300, 0)[0], y=_at(300, 0)[1])
    g.add_node(3, x=_at(300, 300)[0], y=_at(300, 300)[1])
    g.add_edge(1, 2, 0, name="Broadway", osmid=1, length=300.0, surface="asphalt")
    g.add_edge(2, 3, 0, name="Pearl", osmid=2, length=300.0, surface="gravel")
    for extra, node in enumerate((90, 91), start=0):
        g.add_node(node, x=_at(300, -100 - extra)[0], y=_at(300, -100 - extra)[1])
        g.add_edge(2, node, 0, name=f"stub{extra}", osmid=50 + extra, length=100.0)
    # A walk is `(u, v, edge_data)` triples — the shape `scoring.metrics.edge_walk`
    # hands the solver's path to every consumer, this module included.
    walk = [(1, 2, g.edges[1, 2, 0]), (2, 3, g.edges[2, 3, 0])]
    return g, walk


def test_a_derived_sheet_opens_at_the_start_and_closes_at_the_finish():
    """The two cues every sheet has, whatever the geometry — and the finish sits
    at the route's own length, not at zero."""
    graph, walk = _grid_graph()
    sheet, stats = derive_cue_sheet(graph, walk, segment_id="s1")

    assert sheet.cues[0].kind == "start"
    assert sheet.cues[0].instruction == "Start"
    assert sheet.cues[-1].kind == "finish"
    assert sheet.cues[-1].distance_along_m == pytest.approx(stats["route_m"], abs=0.5)


def test_the_derived_sheet_carries_the_turn_at_the_corner():
    """The corner is also where the surface changes to gravel, so the two cues
    fall inside the merge window and become one line — the turn leading, the
    surface note in parentheses. Asserted here rather than contrived apart
    because a rider really does meet both at once, and "Turn left onto Pearl
    (Surface changes to gravel)" is the sheet doing its job."""
    graph, walk = _grid_graph()
    sheet, _ = derive_cue_sheet(graph, walk)

    turns = [c for c in sheet.cues if c.kind == "turn"]
    assert len(turns) == 1
    assert turns[0].instruction == "Turn left onto Pearl (Surface changes to gravel)"
    assert turns[0].modifier == "left"
    assert not [c for c in sheet.cues if c.kind == "surface"], \
        "the surface cue was absorbed, not emitted a second time"


def test_custom_start_and_finish_labels_reach_the_sheet():
    graph, walk = _grid_graph()
    sheet, _ = derive_cue_sheet(graph, walk, start_label="Leave the trailhead",
                                finish_label="Arrive at camp")

    assert sheet.cues[0].instruction == "Leave the trailhead"
    assert sheet.cues[-1].instruction == "Arrive at camp"


def test_every_cue_is_stamped_with_the_segment_it_belongs_to():
    graph, walk = _grid_graph()
    sheet, _ = derive_cue_sheet(graph, walk, segment_id="seg-7")

    assert {c.segment_id for c in sheet.cues} == {"seg-7"}
    assert sheet.segment_ids == ["seg-7"]


def test_the_sheet_records_where_it_came_from():
    graph, walk = _grid_graph()
    sheet, _ = derive_cue_sheet(graph, walk, generated_at="2026-09-02T00:00:00Z")

    assert sheet.generated_at == "2026-09-02T00:00:00Z"
    assert sheet.generator == "plotlines-core cues/1.0"


def test_the_stats_separate_derived_cues_from_authored_ones():
    """"The algorithm chooses how many turn and surface cues to emit, and has no
    business thinning the Author's own hazards, stops and transitions." The
    density ceiling is judged on the derived half alone."""
    graph, walk = _grid_graph()
    _sheet, stats = derive_cue_sheet(graph, walk)

    assert stats["derived_cues"] + stats["authored_cues"] == stats["cues"]
    assert stats["derived_cues"] == sum(
        stats["by_kind"].get(k, 0) for k in ("turn", "surface"))
    assert stats["within_legibility_ceiling"] is True


def test_a_sheet_over_the_density_ceiling_says_so_rather_than_hiding_turns():
    """"The honest failure is 'this route is busy', not 'we hid some turns'."""
    graph, walk = _grid_graph()
    _sheet, stats = derive_cue_sheet(
        graph, walk, settings=CueSettings(legible_cues_per_km=0.1))

    assert stats["within_legibility_ceiling"] is False


def test_density_is_reported_per_kilometre_of_actual_route():
    """`route.length_m / 1000.0 or 1.0` guards a zero-length route from dividing
    by zero — it must not become a flat "per 1 km" for every route. On this
    600 m dog-leg the two answers differ by a factor of 1.67, which is the
    difference between a sheet reading as legible and as crowded."""
    graph, walk = _grid_graph()
    sheet, stats = derive_cue_sheet(graph, walk)

    length_km = stats["route_m"] / 1000.0
    assert length_km == pytest.approx(0.6, abs=0.05)
    assert stats["cues_per_km"] == pytest.approx(len(sheet.cues) / length_km, abs=0.05)
    assert stats["cues_per_km"] > len(sheet.cues), "density was measured against a flat 1 km"


def test_the_stats_carry_each_pass_s_own_counts():
    graph, walk = _grid_graph()
    _sheet, stats = derive_cue_sheet(graph, walk)

    for key in ("turns", "surfaces", "nodes", "merge", "retrace"):
        assert isinstance(stats[key], dict), f"{key} stats missing"
    assert stats["edges"] == 2
    assert stats["route_m"] > 0
