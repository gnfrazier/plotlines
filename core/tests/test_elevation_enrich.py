"""Unit tests for `plotlines_core.elevation.enrich.enrich_elevation` (PRD FR89).

FR89 acceptance criteria: elevation enrichment annotates *every* graph node
with its elevation and *every* edge with `elev_gain = max(0.0, elev[v] -
elev[u])` — positive gain only.
"""

from __future__ import annotations

import networkx as nx
import numpy as np
import pytest

from plotlines_core.elevation.enrich import (
    ELEV_GAIN_KEY,
    ELEVATION_KEY,
    EnrichmentReport,
    enrich_elevation,
    enrich_from_resolver,
)
from plotlines_core.elevation.interface import ElevationResolver, LocalCacheSource
from plotlines_core.elevation.sampler import ElevationSampler
from plotlines_core.graph.loader import _elevations


class FakeSampler:
    """Stands in for `ElevationSampler`: returns a scripted elevation per
    (lat, lon), no raster, no rasterio."""

    def __init__(self, elev_by_coord: dict[tuple[float, float], float], *, degraded: bool = False):
        self._elev = elev_by_coord
        self.degraded = degraded

    def sample(self, coords):
        return np.array(
            [self._elev.get((round(lat, 6), round(lon, 6)), 0.0) for lat, lon in coords],
            dtype="float64",
        )


# A tiny valley -> ridge line: node 1 low, node 2 mid, node 3 high, node 4 mid.
_NODES = {
    1: (40.0100, -105.2700, 1600.0),
    2: (40.0110, -105.2690, 1650.0),
    3: (40.0120, -105.2680, 1720.0),
    4: (40.0130, -105.2670, 1655.0),
}


def _line_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    for nid, (lat, lon, _elev) in _NODES.items():
        g.add_node(nid, y=lat, x=lon)
    # Directed both ways, as osmnx builds a two-way street.
    for u, v in [(1, 2), (2, 3), (3, 4)]:
        g.add_edge(u, v, length=140.0)
        g.add_edge(v, u, length=140.0)
    return g


def _sampler_for(graph) -> FakeSampler:
    return FakeSampler(
        {
            (round(lat, 6), round(lon, 6)): elev
            for _nid, (lat, lon, elev) in _NODES.items()
        }
    )


def test_every_node_gets_its_elevation():
    g = _line_graph()
    enrich_elevation(g, _sampler_for(g))
    for nid, (_lat, _lon, elev) in _NODES.items():
        assert g.nodes[nid][ELEVATION_KEY] == pytest.approx(elev)
    assert all(ELEVATION_KEY in data for _, data in g.nodes(data=True))


def test_every_edge_gets_positive_only_elev_gain():
    g = _line_graph()
    enrich_elevation(g, _sampler_for(g))
    for u, v, data in g.edges(data=True):
        assert ELEV_GAIN_KEY in data
        expected = max(0.0, _NODES[v][2] - _NODES[u][2])
        assert data[ELEV_GAIN_KEY] == pytest.approx(expected)
        assert data[ELEV_GAIN_KEY] >= 0.0


def test_uphill_carries_gain_downhill_is_zero():
    g = _line_graph()
    enrich_elevation(g, _sampler_for(g))
    # 1 -> 2 climbs 50 m; 2 -> 1 is the same street descending -> 0.0.
    assert g.edges[1, 2, 0][ELEV_GAIN_KEY] == pytest.approx(50.0)
    assert g.edges[2, 1, 0][ELEV_GAIN_KEY] == 0.0
    # 3 -> 4 descends 65 m -> 0.0; 4 -> 3 climbs 65 m.
    assert g.edges[3, 4, 0][ELEV_GAIN_KEY] == 0.0
    assert g.edges[4, 3, 0][ELEV_GAIN_KEY] == pytest.approx(65.0)


def test_flat_edge_has_zero_gain():
    g = nx.MultiDiGraph()
    g.add_node(1, y=40.0, x=-105.0)
    g.add_node(2, y=40.001, x=-105.0)
    g.add_edge(1, 2, length=100.0)
    sampler = FakeSampler({(40.0, -105.0): 1500.0, (40.001, -105.0): 1500.0})
    enrich_elevation(g, sampler)
    assert g.edges[1, 2, 0][ELEV_GAIN_KEY] == 0.0


def test_parallel_edges_each_annotated():
    g = nx.MultiDiGraph()
    g.add_node(1, y=40.0, x=-105.0)
    g.add_node(2, y=40.001, x=-105.0)
    k0 = g.add_edge(1, 2, length=100.0)
    k1 = g.add_edge(1, 2, length=180.0)  # a second way between the same nodes
    sampler = FakeSampler({(40.0, -105.0): 100.0, (40.001, -105.0): 130.0})
    enrich_elevation(g, sampler)
    assert g.edges[1, 2, k0][ELEV_GAIN_KEY] == pytest.approx(30.0)
    assert g.edges[1, 2, k1][ELEV_GAIN_KEY] == pytest.approx(30.0)


def test_mutates_in_place_and_returns_same_graph():
    g = _line_graph()
    out = enrich_elevation(g, _sampler_for(g))
    assert out is g


def test_report_recorded_on_graph():
    g = _line_graph()
    enrich_elevation(g, _sampler_for(g))
    report = g.graph["_pl_elev_enrichment"]
    assert isinstance(report, EnrichmentReport)
    assert report.nodes_annotated == 4
    assert report.edges_annotated == 6
    assert report.void_nodes == 0
    assert report.degraded is False


def test_loader_elevation_cache_is_consistent_after_enrichment():
    g = _line_graph()
    enrich_elevation(g, _sampler_for(g))
    elev = _elevations(g)
    assert elev is not None
    assert sorted(elev.tolist()) == sorted(e for *_r, e in _NODES.values())


def test_empty_graph_is_noop():
    g = nx.MultiDiGraph()
    out = enrich_elevation(g, FakeSampler({}))
    assert out is g
    assert out.number_of_nodes() == 0


def test_degraded_sampler_yields_flat_fully_annotated_graph():
    """FR88: a missing raster never raises. FR89's 'every node / every edge'
    still holds — the graph comes back flat, not partly annotated."""
    g = _line_graph()
    sampler = ElevationSampler("/no/such/raster.tif")
    assert sampler.degraded
    enrich_elevation(g, sampler)
    assert all(data[ELEVATION_KEY] == 0.0 for _, data in g.nodes(data=True))
    assert all(data[ELEV_GAIN_KEY] == 0.0 for _, _, data in g.edges(data=True))
    assert g.graph["_pl_elev_enrichment"].degraded is True
    assert g.graph["_pl_elev_enrichment"].void_nodes == 4


def test_enrich_from_resolver_degrades_when_no_source_covers_bbox(tmp_path):
    """The resolver hands back a degraded sampler rather than raising when no
    source has the bbox (FR88); enrichment still annotates everything."""
    g = _line_graph()
    resolver = ElevationResolver([LocalCacheSource(tmp_path)])  # empty cache
    out = enrich_from_resolver(g, resolver, (-105.28, 40.00, -105.26, 40.02))
    assert out is g
    assert all(ELEVATION_KEY in data for _, data in g.nodes(data=True))
    assert all(ELEV_GAIN_KEY in data for _, _, data in g.edges(data=True))


def test_node_missing_coordinates_is_treated_as_void_not_an_error():
    g = nx.MultiDiGraph()
    g.add_node(1, y=40.0, x=-105.0)
    g.add_node(2)  # no y/x — a malformed node, must not raise
    g.add_edge(1, 2, length=100.0)
    sampler = FakeSampler({(40.0, -105.0): 200.0})
    enrich_elevation(g, sampler)
    assert g.nodes[2][ELEVATION_KEY] == 0.0
    assert g.edges[1, 2, 0][ELEV_GAIN_KEY] == 0.0  # max(0.0, 0.0 - 200.0)
