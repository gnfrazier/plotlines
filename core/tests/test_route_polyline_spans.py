"""Issue #205 — `route_polyline`'s RouteEdge spans must tile the polyline.

`start_index` for every edge after the first was set to `len(coords)` *before*
the edge's own geometry was appended. Since the previous edge's last point is
this edge's first point (and is never re-appended), that index pointed at the
edge's *second* vertex, so each span began one sub-segment late and the spans
covered strictly less than `route.length_m`.
"""

import networkx as nx
from shapely.geometry import LineString

from plotlines_core.trips.cues import route_polyline


def _line_graph():
    g = nx.MultiDiGraph()
    for n, (x, y) in {1: (0.0, 0.0), 2: (0.01, 0.0), 3: (0.02, 0.0)}.items():
        g.add_node(n, x=x, y=y)
    g.add_edge(1, 2, length=1113.0,
               geometry=LineString([(0.0, 0.0), (0.005, 0.0), (0.01, 0.0)]))
    g.add_edge(2, 3, length=1113.0,
               geometry=LineString([(0.01, 0.0), (0.015, 0.0), (0.02, 0.0)]))
    return g


def test_spans_tile_the_polyline():
    g = _line_graph()
    walk = [(1, 2, g[1][2][0]), (2, 3, g[2][3][0])]
    route = route_polyline(g, walk)

    covered = sum(e.end_m - e.start_m for e in route.edges)
    assert abs(covered - route.length_m) < 1e-6

    # And they abut: each edge starts exactly where the previous one ended.
    assert route.edges[0].start_m == 0.0
    for prev, nxt in zip(route.edges, route.edges[1:]):
        assert nxt.start_m == prev.end_m


def test_span_indices_bracket_the_edge_geometry():
    g = _line_graph()
    walk = [(1, 2, g[1][2][0]), (2, 3, g[2][3][0])]
    route = route_polyline(g, walk)

    for edge in route.edges:
        assert route.cumulative_m[edge.start_index] == edge.start_m
        assert route.cumulative_m[edge.end_index] == edge.end_m
    # Second edge's start vertex is the shared junction, not a point past it.
    assert route.edges[1].start_index == route.edges[0].end_index
