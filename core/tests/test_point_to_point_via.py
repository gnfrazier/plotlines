"""Issue #589 — a point-to-point solve passes through each via point, in order.

The client's "Route through this" (ARCH D71) only puts a node's coordinate into
`Segment.via`. Everything that makes the route actually go there is
`generate_segment`'s `start → [via…] → end`, which until now was exercised for
loops (`test_via_anchor_loop.py`) but never pinned for point-to-point.

The graph is a two-row ladder. Its direct route runs along the bottom row, so
any visit to the top row is the via doing its job:

    4 ---- 5 ---- 6        y = 40.01
    |      |      |
    1 ---- 2 ---- 3        y = 40.00
"""

from __future__ import annotations

import networkx as nx

from plotlines_core.routing.solve import generate_segment
from plotlines_core.scoring.profile import WeightProfile

_DIRECT = WeightProfile("direct", directness=1.0)

_NODES = {
    1: (40.00, -105.30), 2: (40.00, -105.29), 3: (40.00, -105.28),
    4: (40.01, -105.30), 5: (40.01, -105.29), 6: (40.01, -105.28),
}


def _ladder() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    for n, (y, x) in _NODES.items():
        g.add_node(n, y=y, x=x)
    for u, v, length in ((1, 2, 850.0), (2, 3, 850.0), (4, 5, 850.0), (5, 6, 850.0),
                         (1, 4, 1110.0), (2, 5, 1110.0), (3, 6, 1110.0)):
        g.add_edge(u, v, length=length, highway="residential")
        g.add_edge(v, u, length=length, highway="residential")
    return g


def _visits(seg, node: int) -> list[int]:
    """Indexes in the solved line where it stands on `node`."""
    y, x = _NODES[node]
    return [i for i, (lon, lat) in enumerate(seg.coordinates) if (lat, lon) == (y, x)]


def test_without_via_the_route_stays_on_the_direct_row():
    seg = generate_segment(_ladder(), _NODES[1], _NODES[3], _DIRECT)
    assert not _visits(seg, 5)


def test_a_single_via_bends_the_route_through_it():
    seg = generate_segment(_ladder(), _NODES[1], _NODES[3], _DIRECT, via=[_NODES[5]])
    assert _visits(seg, 5)
    assert seg.coordinates[0] == [_NODES[1][1], _NODES[1][0]]
    assert seg.coordinates[-1] == [_NODES[3][1], _NODES[3][0]]


def test_via_points_are_visited_in_the_order_given():
    graph = _ladder()
    forward = generate_segment(graph, _NODES[1], _NODES[3], _DIRECT,
                               via=[_NODES[4], _NODES[6]])
    assert _visits(forward, 4)[0] < _visits(forward, 6)[0]

    # The order is the Author's, not the solver's: reversed, 6 comes first
    # even though that doubles back.
    reversed_ = generate_segment(graph, _NODES[1], _NODES[3], _DIRECT,
                                 via=[_NODES[6], _NODES[4]])
    assert _visits(reversed_, 6)[0] < _visits(reversed_, 4)[0]
    assert reversed_.distance_m > forward.distance_m


def test_a_via_off_the_graph_is_reached_at_its_snapped_node():
    # A point placed beside the road, ~50 m north of node 5, snaps to node 5.
    # The solver counts it as reached; how far that is from where the Author
    # put it is the client's report (`viaReach`, kViaReachedM), not the solver's.
    beside = (40.0105, -105.29)
    seg = generate_segment(_ladder(), _NODES[1], _NODES[3], _DIRECT, via=[beside])
    assert _visits(seg, 5)
