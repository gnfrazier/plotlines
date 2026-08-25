"""Unit tests for `plotlines_core.graph.loader.nearest_node`'s snap guard
(issue #154 — the previously unguarded `argmin` silently returned a node from
the wrong region for a coordinate thousands of km away)."""

import networkx as nx
import pytest

from plotlines_core.graph.loader import OutsideGraphExtent, nearest_node

# A tiny 3-node line graph over Boulder, CO — real coordinates, no network call.
_BOULDER_NODES = {
    1: (40.0150, -105.2705),
    2: (40.0160, -105.2700),
    3: (40.0170, -105.2695),
}


def _boulder_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    for node_id, (lat, lon) in _BOULDER_NODES.items():
        g.add_node(node_id, y=lat, x=lon)
    g.add_edge(1, 2, length=100.0)
    g.add_edge(2, 3, length=100.0)
    return g


def test_snaps_to_nearest_node_within_tolerance():
    graph = _boulder_graph()
    # A few metres off node 2.
    node = nearest_node(graph, 40.0160, -105.2701)
    assert node == 2


def test_coordinate_outside_region_raises_outside_graph_extent():
    graph = _boulder_graph()
    # Asheville, NC — ~2,000 km from the Boulder fixture (issue #154's example).
    with pytest.raises(OutsideGraphExtent):
        nearest_node(graph, 35.5951, -82.5515)


def test_outside_graph_extent_is_a_value_error():
    # Every existing `except ValueError` handler (ARCH §7.2's honest-422
    # contract) must catch this without being rewritten.
    assert issubclass(OutsideGraphExtent, ValueError)


def test_custom_max_snap_m_is_honoured():
    graph = _boulder_graph()
    # ~120 m from node 2 (roughly one grid step) — inside the 3 km default,
    # outside a tight 50 m guard.
    with pytest.raises(OutsideGraphExtent):
        nearest_node(graph, 40.0170, -105.2680, max_snap_m=50.0)


def test_guard_can_be_disabled():
    graph = _boulder_graph()
    node = nearest_node(graph, 35.5951, -82.5515, max_snap_m=None)
    assert node in _BOULDER_NODES
