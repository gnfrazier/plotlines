"""FR5/FR6 (Story A5) — `RouteMetrics.salience`, `measure()`'s length-weighted
mean of `interest_salience` (`routing.interest.annotate_interest`'s edge
annotation, FR98). Same shape as `traffic`'s length-weighted stress mean —
see `test_traffic_weight.py` for the precedent this mirrors.
"""

import networkx as nx
import pytest

from plotlines_core.scoring.metrics import edge_walk, measure
from plotlines_core.scoring.profile import WeightProfile

_A, _B, _C = 1, 2, 3


def _walk_graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(_A, y=40.0000, x=-105.3000, elevation=100.0)
    g.add_node(_B, y=40.0010, x=-105.3000, elevation=100.0)
    g.add_node(_C, y=40.0020, x=-105.3000, elevation=100.0)
    g.add_edge(_A, _B, length=100.0, highway="residential", interest_salience=0.8)
    g.add_edge(_B, _C, length=300.0, highway="residential")  # no salience nearby
    return g


def test_salience_defaults_to_zero_on_a_walk_with_no_annotation():
    g = nx.MultiDiGraph()
    g.add_node(_A, y=40.0, x=-105.3, elevation=100.0)
    g.add_node(_B, y=40.001, x=-105.3, elevation=100.0)
    g.add_edge(_A, _B, length=100.0, highway="residential")
    walk = edge_walk(g, [_A, _B], WeightProfile())
    assert measure(g, walk).salience == 0.0


def test_salience_is_length_weighted_across_a_mixed_walk():
    g = _walk_graph()
    walk = edge_walk(g, [_A, _B, _C], WeightProfile())
    # (0.8 * 100 + 0.0 * 300) / 400 = 0.2
    assert measure(g, walk).salience == pytest.approx(0.2)


def test_salience_is_one_when_the_entire_walk_is_maximally_salient():
    g = nx.MultiDiGraph()
    g.add_node(_A, y=40.0, x=-105.3, elevation=100.0)
    g.add_node(_B, y=40.001, x=-105.3, elevation=100.0)
    g.add_edge(_A, _B, length=100.0, highway="residential", interest_salience=1.0)
    walk = edge_walk(g, [_A, _B], WeightProfile())
    assert measure(g, walk).salience == pytest.approx(1.0)


def test_empty_walk_reports_zero_salience_not_an_error():
    g = _walk_graph()
    assert measure(g, []).salience == 0.0
