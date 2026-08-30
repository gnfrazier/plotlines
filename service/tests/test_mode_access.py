"""Story A11 (issue #29) — mode-legal routability (FR128), exercised over
`/segments/generate`'s real HTTP surface.

`core/tests/test_mode_access.py` covers `routing/access.py` and the
`generate_loop`/`generate_segment` entry points directly; what only the
service layer can catch is whether `mode` on the request actually reaches
the solve, and whether `_loop_to_dict`/`Segment.to_dict()` actually carry
`surfaced_constraints` over the wire rather than computing it and dropping it,
the same class of gap A9 (issue #26) found in the overlap-split fields.

Reuses `test_segment_shape.py`'s pattern of pre-seeding the committed
SPIKE-00 Boulder fixture graph for a real, ready region, then swaps in a
small synthetic graph with known routability tags — hunting for real-world
coordinates that happen to cross a `bicycle=no`/`dismount` way in the Boulder
extract would make this test fragile against fixture regeneration; a
synthetic graph makes the constraint's presence and effect exact.
"""

from __future__ import annotations

import shutil
import time
from pathlib import Path

import networkx as nx
import pytest
from fastapi.testclient import TestClient

from plotlines_core.graph import regions as region_lib
from plotlines_core.graph.loader import LoadedGraph
from plotlines_service.app import create_app

_FIXTURE_GRAPH = (Path(__file__).resolve().parents[2] / "spikes" / "SPIKE-00" / "fixtures"
                  / "boulder_bike.graphml")
_BOULDER_BBOX = [-105.30, 39.99, -105.25, 40.03]  # SPIKE-00's own fixture bbox

pytestmark = pytest.mark.skipif(
    not _FIXTURE_GRAPH.exists(),
    reason="SPIKE-00 fixture graph not present in this checkout",
)

_START = {"lat": 40.0000, "lon": -105.3000}
_END = {"lat": 40.0000, "lon": -105.2985}


def _client_with_boulder_region(tmp_path: Path) -> tuple[TestClient, str]:
    key = region_lib.region_key(tuple(_BOULDER_BBOX), "bike")
    dest = tmp_path / "regions" / key / "graph.graphml"
    dest.parent.mkdir(parents=True)
    shutil.copy(_FIXTURE_GRAPH, dest)

    client = TestClient(create_app(tmp_path))
    got_key = client.post("/regions", json={"bbox": _BOULDER_BBOX}).json()["region"]
    assert got_key == key

    deadline = time.perf_counter() + 20.0
    while not client.get("/health").json()["capabilities"]["routing"]["regions"][key]["ready"]:
        if time.perf_counter() > deadline:
            raise AssertionError("Boulder region never became ready")
        time.sleep(0.02)
    return client, key


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


def test_segments_generate_detours_a_cyclist_around_a_bicycle_no_edge(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
    _swap_in_graph(client, key, _two_route_graph(bicycle_tag="no"))

    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END, "shape": "point_to_point",
        "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["node_count"] == 4  # forced onto the 0-2-3-1 detour
    assert body["surfaced_constraints"] == []


def test_segments_generate_takes_the_direct_edge_for_a_mode_it_does_not_restrict(
    tmp_path: Path,
) -> None:
    client, key = _client_with_boulder_region(tmp_path)
    _swap_in_graph(client, key, _two_route_graph(bicycle_tag="no"))

    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END, "shape": "point_to_point",
        "mode": "hiking", "theme": "balanced",
    })
    assert resp.status_code == 200
    assert resp.json()["node_count"] == 2  # foot=no was never set


def test_segments_generate_surfaces_a_dismount_edge_over_the_wire(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
    _swap_in_graph(client, key, _two_route_graph(bicycle_tag="dismount"))

    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END, "shape": "point_to_point",
        "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["node_count"] == 2  # still routable
    assert body["surfaced_constraints"] == [
        {"from": 0, "to": 1, "flags": ["bicycle=dismount"]}
    ]


def test_segments_generate_loop_response_carries_surfaced_constraints_field(
    tmp_path: Path,
) -> None:
    # Regression guard on `_loop_to_dict`, the same class of gap A9 found:
    # the field must reach the wire even when it's empty, not be silently
    # dropped by the response shaper.
    client, key = _client_with_boulder_region(tmp_path)
    resp = client.post("/segments/generate", json={
        "region": key, "start": {"lat": 40.0175, "lon": -105.2797},
        "shape": "loop", "target_m": 2000.0, "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    assert "surfaced_constraints" in resp.json()


# --- B1 / FR130 — a traversal mode is configuration, over the wire ---------


def test_segments_generate_accepts_a_traversal_mode_name_as_a_theme(tmp_path: Path) -> None:
    """FR130 — a mode's own `WeightProfile` entry is nameable, so a mountain-
    biking passage solves on the weights its registry row carries and no second
    scorer. The named-theme catalogue is untouched by this."""
    client, key = _client_with_boulder_region(tmp_path)
    resp = client.post("/segments/generate", json={
        "region": key, "start": {"lat": 40.0175, "lon": -105.2797},
        "shape": "loop", "target_m": 2000.0,
        "mode": "mountain_biking", "theme": "mountain_biking",
    })
    assert resp.status_code == 200
    assert resp.json()["theme"] == "mountain_biking"


def test_a_string_that_is_neither_a_theme_nor_a_mode_is_still_422(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
    resp = client.post("/segments/generate", json={
        "region": key, "start": {"lat": 40.0175, "lon": -105.2797},
        "shape": "loop", "target_m": 2000.0, "mode": "cycling", "theme": "teleportation",
    })
    assert resp.status_code == 422


def test_a_mountain_biking_passage_inherits_cyclings_legality_over_the_wire(
    tmp_path: Path,
) -> None:
    """The alias resolves on the service's own path, not just in a unit test:
    `bicycle=no` closes the direct edge to a mountain bike, with no
    `mountain_biking` row in `MODE_CONSTRAINTS`."""
    client, key = _client_with_boulder_region(tmp_path)
    _swap_in_graph(client, key, _two_route_graph(bicycle_tag="no"))

    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END, "shape": "point_to_point",
        "mode": "mountain_biking", "theme": "balanced",
    })
    assert resp.status_code == 200
    assert resp.json()["node_count"] == 4  # forced onto the same 0-2-3-1 detour
