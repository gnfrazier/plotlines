"""The matcher, on a hand-built graph where the right answer is known.

The published numbers come from real feeds against real graphs; these tests
exist so that a change to the matcher which would move those numbers fails
here first, on a case small enough to reason about.
"""

from __future__ import annotations

import networkx as nx
import pytest

import matching
import normalize


def _graph() -> nx.MultiDiGraph:
    """Two parallel east–west roads ~40 m apart, plus a north–south cross
    street through the first — the three-way ambiguity every road-side feed
    creates."""
    g = nx.MultiDiGraph()
    # ~40 m of latitude is 0.00036 degrees.
    g.add_node(1, x=-91.20, y=43.80)
    g.add_node(2, x=-91.19, y=43.80)
    g.add_node(3, x=-91.20, y=43.80036)
    g.add_node(4, x=-91.19, y=43.80036)
    g.add_node(5, x=-91.195, y=43.7995)
    g.add_node(6, x=-91.195, y=43.8010)
    g.add_edge(1, 2, 0, name="Main Street", highway="secondary", length=800.0)
    g.add_edge(3, 4, 0, name="Frontage Road", highway="residential", length=800.0)
    g.add_edge(5, 6, 0, name="Cross Street", highway="residential", length=170.0)
    return g


def _event(coords, kind="line", names=("Main Street",)) -> normalize.RoadEvent:
    return normalize.RoadEvent(id="e1", source_id="test", kind="work-zone",
                               impact="some-lanes-closed", road_names=names,
                               geometry=tuple(coords), geometry_kind=kind)


def test_a_line_event_takes_its_own_road_and_not_the_parallel_one():
    g = _graph()
    index = matching.EdgeIndex(g)
    hits, stats = matching.match_events(
        g, index, [_event([(-91.1990, 43.80), (-91.1930, 43.80)])])
    assert stats.events_matched == 1
    assert set(hits) == {(1, 2, 0)}


def test_bearing_is_what_rejects_the_cross_street():
    """A distance-only match takes the cross street too — this is the check
    that stops a work zone on the highway flagging every side road."""
    g = _graph()
    index = matching.EdgeIndex(g)
    event = _event([(-91.1960, 43.80), (-91.1940, 43.80)])
    strict, _ = matching.match_events(g, index, [event])
    loose, _ = matching.match_events(g, index, [event], bearing_tolerance_deg=90.0)
    assert (5, 6, 0) not in strict
    assert (5, 6, 0) in loose


def test_a_point_published_event_cannot_rule_the_cross_street_out():
    """The measured cost of publishing a linear event as a location
    (RESULTS §3): with no heading there is nothing to reject with."""
    g = _graph()
    index = matching.EdgeIndex(g)
    hits, _ = matching.match_events(g, index, [_event([(-91.1950, 43.80)], kind="point")])
    assert (1, 2, 0) in hits
    assert (5, 6, 0) in hits


def test_an_event_outside_the_graph_extent_is_dropped_before_any_geometry_work():
    """The feeds are statewide with no bbox parameter on the wire, so this
    filter is the client's and it runs first."""
    g = _graph()
    index = matching.EdgeIndex(g)
    hits, stats = matching.match_events(
        g, index, [_event([(-88.00, 43.05), (-87.99, 43.05)])])
    assert hits == {}
    assert stats.events_locatable == 1
    assert stats.events_in_bbox == 0


def test_name_agreement_is_measured_but_never_required():
    """A name filter would have dropped 50.8% of rural and 83.5% of urban
    matches in the real run; agreement is reported instead of enforced."""
    g = _graph()
    index = matching.EdgeIndex(g)
    hits, stats = matching.match_events(
        g, index, [_event([(-91.1990, 43.80), (-91.1930, 43.80)],
                          names=("CTH B",))])
    assert set(hits) == {(1, 2, 0)}          # matched anyway
    assert stats.name_agreement_rate == 0.0  # and the disagreement is visible


@pytest.mark.parametrize("event_name,edge_name,expected", [
    ("WIS 142 WB", "state highway 142", True),
    ("US 14/61", "us 14", True),
    ("CTH B", "county road b", True),
    ("I 94 EB", "eastbound", False),      # a direction word is not identity
    ("Main Street", "frontage road", False),
])
def test_name_token_overlap(event_name, edge_name, expected):
    assert matching.names_agree((event_name,), edge_name) is expected


def test_a_polygon_event_matches_by_containment_not_by_heading():
    g = _graph()
    index = matching.EdgeIndex(g)
    ring = [(-91.201, 43.799), (-91.189, 43.799),
            (-91.189, 43.801), (-91.201, 43.801), (-91.201, 43.799)]
    hits, stats = matching.match_events(g, index, [_event(ring, kind="polygon")])
    assert stats.events_matched == 1
    assert len(hits) == 3  # a weather advisory covers everything under it
