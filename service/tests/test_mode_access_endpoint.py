"""Story A11 (issue #29) — mode-legal routability (FR128), exercised over
`/segments/generate`'s real HTTP surface.

Named `..._endpoint` rather than matching its core counterpart's basename:
neither test directory carries an `__init__.py`, so two `test_mode_access.py`
files make a combined `pytest core/tests service/tests` run die at collection
with an import-file mismatch. The suites run separately in CI, but a developer
pointing pytest at both should not hit that (#235 C).

`core/tests/test_mode_access.py` covers `routing/access.py` and the
`generate_loop`/`generate_segment` entry points directly; what only the
service layer can catch is whether `mode` on the request actually reaches
the solve, and whether `_loop_to_dict`/`Segment.to_dict()` actually carry
`surfaced_constraints` over the wire rather than computing it and dropping it,
the same class of gap A9 (issue #26) found in the overlap-split fields.

Starts from `conftest.py`'s `boulder_region` (the committed SPIKE-00 Boulder
fixture graph, pre-seeded) for a real, ready region, then swaps in a
small synthetic graph with known routability tags — hunting for real-world
coordinates that happen to cross a `bicycle=no`/`dismount` way in the Boulder
extract would make this test fragile against fixture regeneration; a
synthetic graph makes the constraint's presence and effect exact.
"""

from __future__ import annotations

import networkx as nx
from fastapi.testclient import TestClient

from plotlines_core.graph.loader import LoadedGraph


_START = {"lat": 40.0000, "lon": -105.3000}
_END = {"lat": 40.0000, "lon": -105.2985}


def _two_route_graph(bicycle_tag: str) -> nx.MultiDiGraph:
    """The same cheap-direct-edge-vs-legal-detour shape
    `core/tests/test_mode_access.py` uses, so only a hard exclusion (never
    merely a cost preference) can keep a restricted mode off the shortcut."""
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


def _swap_in_graph(client: TestClient, key: str, graph: nx.MultiDiGraph) -> None:
    region = client.app.state.readiness.region(key)
    region.graph = LoadedGraph(graph=graph, source=region.graph.source, load_seconds=0.0)


def test_segments_generate_detours_a_cyclist_around_a_bicycle_no_edge(boulder_region) -> None:
    client, key = boulder_region
    _swap_in_graph(client, key, _two_route_graph(bicycle_tag="no"))

    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END, "shape": "point_to_point",
        "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["node_count"] == 4  # forced onto the 0-2-3-1 detour
    assert body["surfaced_constraints"] == []


def test_segments_generate_takes_the_direct_edge_for_a_mode_it_does_not_restrict(boulder_region) -> None:
    client, key = boulder_region
    _swap_in_graph(client, key, _two_route_graph(bicycle_tag="no"))

    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END, "shape": "point_to_point",
        "mode": "hiking", "theme": "balanced",
    })
    assert resp.status_code == 200
    assert resp.json()["node_count"] == 2  # foot=no was never set


def test_segments_generate_surfaces_a_dismount_edge_over_the_wire(boulder_region) -> None:
    client, key = boulder_region
    _swap_in_graph(client, key, _two_route_graph(bicycle_tag="dismount"))

    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END, "shape": "point_to_point",
        "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["node_count"] == 2  # still routable
    assert body["surfaced_constraints"] == [
        {"from": 0, "to": 1, "flags": ["bicycle=dismount"],
         "distance_along_m": 0.0, "length_m": 10.0}
    ]


def test_segments_generate_loop_response_carries_surfaced_constraints_field(boulder_region) -> None:
    # Regression guard on `_loop_to_dict`, the same class of gap A9 found:
    # the field must reach the wire even when it's empty, not be silently
    # dropped by the response shaper.
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": {"lat": 40.0175, "lon": -105.2797},
        "shape": "loop", "target_m": 2000.0, "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    assert "surfaced_constraints" in resp.json()


# --- B1 / FR130 / #315 — a discipline is configuration, over the wire ------


def test_segments_generate_takes_a_discipline_and_echoes_it(boulder_region) -> None:
    """#315 — a `cycling` passage with the `mountain` discipline solves on the
    profile that discipline carries (the one `mountain_biking` used to carry as
    a mode), with no second scorer, and the response echoes `discipline` the
    way it echoes `mode`/`theme`."""
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": {"lat": 40.0175, "lon": -105.2797},
        "shape": "loop", "target_m": 2000.0,
        "mode": "cycling", "discipline": "mountain",
    })
    assert resp.status_code == 200
    assert resp.json()["discipline"] == "mountain"


def test_a_discipline_name_also_works_as_a_theme_string(boulder_region) -> None:
    """A discipline is nameable as a `theme` too, and so is a `travel_mode`
    value #315 removed — `theme="mountain_biking"` resolves to the `mountain`
    discipline's profile, so an un-migrated request still weights correctly."""
    client, key = boulder_region
    for theme in ("mountain", "mountain_biking"):
        resp = client.post("/segments/generate", json={
            "region": key, "start": {"lat": 40.0175, "lon": -105.2797},
            "shape": "loop", "target_m": 2000.0, "mode": "cycling", "theme": theme,
        })
        assert resp.status_code == 200, theme


def test_a_string_that_is_neither_a_theme_nor_a_mode_is_still_422(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": {"lat": 40.0175, "lon": -105.2797},
        "shape": "loop", "target_m": 2000.0, "mode": "cycling", "theme": "teleportation",
    })
    assert resp.status_code == 422


def test_a_legacy_mountain_biking_mode_inherits_cyclings_legality_over_the_wire(boulder_region) -> None:
    """#315 — an un-migrated `mode="mountain_biking"` is folded onto `cycling`
    by the request validator, so `bicycle=no` still closes the direct edge to
    it, with no `mountain_biking` row in `MODE_CONSTRAINTS`."""
    client, key = boulder_region
    _swap_in_graph(client, key, _two_route_graph(bicycle_tag="no"))

    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END, "shape": "point_to_point",
        "mode": "mountain_biking", "theme": "balanced",
    })
    assert resp.status_code == 200
    assert resp.json()["node_count"] == 4  # forced onto the same 0-2-3-1 detour
    assert resp.json()["mode"] == "cycling"  # the validator canonicalised it
