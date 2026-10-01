"""Issue #597 — a point-to-point route is drawn along the road, not as chords.

`generate_segment` used to return the junction path alone, so on osmnx's
simplified graph every bend between two junctions came back as a straight
chord (up to 183 m off the road on a real Greensboro passage). It now draws
through `route_polyline`, the same polyline the loop shapes return, and samples
elevation along it.
"""

from __future__ import annotations

import networkx as nx
from shapely.geometry import LineString

from plotlines_core.routing.solve import generate_segment
from plotlines_core.scoring.profile import WeightProfile

_DIRECT = WeightProfile("direct", directness=1.0)

# A junction-to-junction road with a bend ~1.1 km north of the chord.
_A = (40.00, -105.30)
_B = (40.00, -105.28)
_BEND = (-105.29, 40.01)  # lon, lat


def _bent_road() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(1, y=_A[0], x=_A[1])
    g.add_node(2, y=_B[0], x=_B[1])
    geom = LineString([(_A[1], _A[0]), _BEND, (_B[1], _B[0])])
    g.add_edge(1, 2, length=3000.0, highway="residential", geometry=geom)
    g.add_edge(2, 1, length=3000.0, highway="residential",
               geometry=LineString(list(geom.coords)[::-1]))
    return g


class _RecordingSampler:
    """Stands in for `ElevationSampler`: records what it was asked to sample."""

    def __init__(self) -> None:
        self.asked: list[tuple[float, float]] = []

    def profile(self, coords_latlon):
        self.asked = list(coords_latlon)
        return {}


def test_the_line_follows_the_edge_geometry_through_the_bend():
    seg = generate_segment(_bent_road(), _A, _B, _DIRECT)
    assert list(_BEND) in seg.coordinates
    assert seg.coordinates[0] == [_A[1], _A[0]]
    assert seg.coordinates[-1] == [_B[1], _B[0]]


def test_elevation_is_sampled_along_the_road_not_the_chord():
    sampler = _RecordingSampler()
    generate_segment(_bent_road(), _A, _B, _DIRECT, sampler=sampler)
    assert (_BEND[1], _BEND[0]) in sampler.asked


def test_distance_is_still_the_path_length():
    seg = generate_segment(_bent_road(), _A, _B, _DIRECT)
    assert seg.distance_m == 3000.0
