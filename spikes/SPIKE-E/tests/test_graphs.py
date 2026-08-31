"""The offline rebuild, checked against the committed pulls and against osmnx."""

from __future__ import annotations

import pytest

import graphs
from regions import APPROACHES, RAW

pytestmark = pytest.mark.skipif(
    not (RAW / "boulder-graph.json.gz").exists(),
    reason="raw pulls not present — run probe.py",
)


def test_rebuilt_graph_carries_what_plotlines_core_reads():
    pull = graphs.load("boulder-graph")
    graph = graphs.build(pull, "drive_track")
    node, data = next(iter(graph.nodes(data=True)))
    assert {"x", "y"} <= set(data)
    _u, _v, edge = next(iter(graph.edges(data=True)))
    assert "length" in edge and "highway" in edge
    assert any("geometry" in d for _u, _v, d in graph.edges(data=True))


def test_variants_are_nested_narrowest_to_widest():
    pull = graphs.load("bigsandy-graph")
    sizes = [graphs.build(pull, v).number_of_edges()
             for v in ("drive", "drive_service", "drive_track", "drive_track_private")]
    assert sizes == sorted(sizes)
    assert sizes[0] < sizes[-1]


def test_largest_strong_component_matches_osmnx():
    """`graph/regions.py` truncates every product graph with
    `ox.truncate.largest_component(strongly=True)`; the offline reimplementation has
    to mean the same thing or the variant tables measure the wrong graph."""
    ox = pytest.importorskip("osmnx")
    graph = graphs.build(graphs.load("boulder-graph"), "drive")
    mine = graphs.largest_strong_component(graph)
    theirs = ox.truncate.largest_component(graph, strongly=True)
    assert set(mine.nodes) == set(theirs.nodes)


def test_corridor_is_a_driving_distance_ball_not_a_straight_line_one():
    """A ridge road 800 m away and 40 km round is not an approach to this trailhead."""
    pull = graphs.load("middlefork-graph")
    graph = graphs.build(pull, "drive_track")
    node, _ = graphs.snap(graph, *APPROACHES["middlefork"].origin)
    near = graphs.corridor_nodes(graph, node, 2_000.0)
    far = graphs.corridor_nodes(graph, node, 15_000.0)
    assert near < far
    straight_line_within_2km = {
        n for n, d in graph.nodes(data=True)
        if graphs.haversine_m((graph.nodes[node]["y"], graph.nodes[node]["x"]),
                              (d["y"], d["x"])) <= 2_000.0
    }
    assert not straight_line_within_2km <= near


def test_snap_reports_distance_rather_than_raising():
    """`graph.loader.nearest_node` raises past 3 km; "how far is the trailhead from
    this graph" is a number this spike has to report, not an exception it swallows."""
    graph = graphs.build(graphs.load("bigsandy-graph"), "drive")
    node, metres = graphs.snap(graph, *APPROACHES["bigsandy"].destination)
    assert node is not None
    assert 0.0 < metres < 3_000.0
