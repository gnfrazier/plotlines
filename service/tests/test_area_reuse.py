"""A trip inside a held area reuses it — epic #641 (ARCH D73), story #644.

One real `.osm.pbf` grid stands in for the mirror's clip. The first trip
fetches its padded area; a second trip a block away lands inside it and must
reach routing `ready` with no `/clip` request (the fake mirror fails the
test if called), a graph that routes the same as a direct build, the same
candidates by feature id, and the area's pin in `osm_source`.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import networkx as nx
import osmium
import osmnx as ox
import pytest
from fastapi.testclient import TestClient
from osmium.osm import mutable

from plotlines_core import cache_areas
from plotlines_core.cache_layout import CacheLayout
from plotlines_core.curation.providers import BBox, OsmLayerProvider, SharedOsmFetch
from plotlines_core.curation.taxonomy import LAYERS
from plotlines_core.graph import extract_fetch
from plotlines_core.graph import regions as region_lib
from plotlines_core.graph.loader import load_graphml, nearest_node
from plotlines_service.app import create_app

#: Relative to today: `find_reusable_extract` only reuses a pin younger than
#: `MAX_PIN_AGE_DAYS`, so a fixed date would rot.
_PIN = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")
_TRIP_1 = (-105.30, 39.99, -105.25, 40.03)
#: A block south-west of trip 1 — outside its bbox, inside its padded area.
_TRIP_2 = (-105.304, 39.987, -105.254, 40.027)
_GRID = (-105.33, 39.96, -105.22, 40.06)
_STEP = 0.004


def _grid_nodes_and_ways():
    nodes, ways = [], []
    w, s, e, n = _GRID
    cols = int(round((e - w) / _STEP)) + 1
    rows = int(round((n - s) / _STEP)) + 1

    def nid(r, c):
        return 1 + r * cols + c

    for r in range(rows):
        for c in range(cols):
            nodes.append(mutable.Node(id=nid(r, c), location=(w + c * _STEP, s + r * _STEP)))
    way_id = 100_000
    for r in range(rows):
        ways.append(mutable.Way(id=way_id, nodes=[nid(r, c) for c in range(cols)],
                                tags={"highway": "residential"}))
        way_id += 1
    for c in range(cols):
        ways.append(mutable.Way(id=way_id, nodes=[nid(r, c) for r in range(rows)],
                                tags={"highway": "residential"}))
        way_id += 1
    # POIs: inside trip 2 only, inside both, and outside both (area margin).
    pois = [(-105.302, 39.989, "SW Peak"), (-105.28, 40.01, "Middle Peak"),
            (-105.252, 40.032, "NE Peak")]
    for i, (lon, lat, name) in enumerate(pois):
        nodes.append(mutable.Node(id=900_000 + i, location=(lon, lat),
                                  tags={"natural": "peak", "name": name}))
    return nodes, ways


def _write_clip(path: Path, bbox) -> Path:
    header = osmium.io.Header()
    header.add_box(osmium.osm.Box(*bbox))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    nodes, ways = _grid_nodes_and_ways()
    with osmium.SimpleWriter(str(path), header=header) as writer:
        for node in nodes:
            writer.add_node(node)
        for way in ways:
            writer.add_way(way)
    return path


@pytest.fixture
def mirror(monkeypatch):
    """`fetch_extract` (the one function that dials the mirror) as a fake
    that writes the clip — and fails the test once `closed`."""
    state = {"calls": [], "closed": False}

    def fetch(bbox, *, cache_dir, progress=None, **_kwargs):
        if state["closed"]:
            pytest.fail(f"/clip requested for {bbox} — a held area covers it")
        state["calls"].append(tuple(bbox))
        path = _write_clip(CacheLayout(cache_dir).osm_extract(tuple(bbox), _PIN), bbox)
        if progress is not None:
            progress.status = "ready"
            progress.bytes_downloaded = progress.total_bytes = path.stat().st_size
        return path

    monkeypatch.setattr(extract_fetch, "fetch_extract", fetch)
    return state


def _settle(client: TestClient) -> None:
    readiness = client.app.state.readiness
    readiness._build_pool.shutdown(wait=True)
    from concurrent.futures import ThreadPoolExecutor
    readiness._build_pool = ThreadPoolExecutor(max_workers=1)


def _route_length(graph, a, b) -> float:
    return nx.shortest_path_length(
        graph, nearest_node(graph, a[1], a[0]), nearest_node(graph, b[1], b[0]),
        weight="length")


def test_a_second_trip_inside_a_held_area_routes_with_no_clip_request(tmp_path, mirror):
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.test"))
    key1 = client.post("/regions", json={"bbox": list(_TRIP_1)}).json()["region"]
    _settle(client)
    assert mirror["calls"] == [cache_areas.pad_bbox(_TRIP_1)]

    mirror["closed"] = True
    key2 = client.post("/regions", json={"bbox": list(_TRIP_2)}).json()["region"]
    _settle(client)

    caps = client.get("/health").json()["capabilities"]
    assert caps["routing"]["regions"][key1] == {"ready": True}
    assert caps["routing"]["regions"][key2] == {"ready": True}
    assert caps["extract"]["regions"][key2]["ready"] is True
    # The second trip wrote no file of its own: one area, one graph.
    graphs = list((tmp_path / "regions").glob("*/graph.graphml"))
    assert len(graphs) == 1


def test_the_truncated_graph_routes_the_same_as_a_direct_build(tmp_path, mirror):
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.test"))
    client.post("/regions", json={"bbox": list(_TRIP_1)}).json()
    _settle(client)
    mirror["closed"] = True
    key2 = client.post("/regions", json={"bbox": list(_TRIP_2)}).json()["region"]
    _settle(client)
    truncated = client.app.state.readiness.region(key2).graph.graph

    direct_root = tmp_path / "direct"
    extent = region_lib.trip_graph_extent(_TRIP_2, cache_areas.pad_bbox(_TRIP_1))
    _write_clip(CacheLayout(direct_root).osm_extract(extent, _PIN), extent)
    direct = load_graphml(region_lib.ensure_graph(
        region_lib.region_for(extent, "bike"), direct_root)).graph

    for a, b in [((-105.30, 39.99), (-105.256, 40.024)),
                 ((-105.28, 39.995), (-105.27, 40.02))]:
        assert _route_length(truncated, a, b) == pytest.approx(
            _route_length(direct, a, b), rel=1e-6)


def test_the_second_trip_gets_the_same_candidates_as_a_direct_extraction(tmp_path, mirror):
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.test"))
    client.post("/regions", json={"bbox": list(_TRIP_1)})
    _settle(client)
    mirror["closed"] = True

    resp = client.get("/candidates", params={
        "west": _TRIP_2[0], "south": _TRIP_2[1], "east": _TRIP_2[2], "north": _TRIP_2[3],
        "layers": "natural"})
    assert resp.status_code == 200
    via_area = {c["id"] for c in resp.json()["candidates"]}

    clip = _write_clip(tmp_path / "direct" / "trip2.osm.pbf", _TRIP_2)
    direct = OsmLayerProvider()._fetch_from_local_clip(
        clip, _TRIP_2, {"natural": True})
    assert via_area == {f.id for f in direct} == {"node/900000", "node/900001"}


def test_candidates_for_a_contained_bbox_come_from_one_area_set(tmp_path, mirror):
    layout = CacheLayout(tmp_path)
    areas = cache_areas.AreaIndex.for_root(tmp_path)
    area = cache_areas.pad_bbox(_TRIP_1)
    extract_fetch.ensure_extract(area, mirror_url="http://mirror.test", cache_dir=tmp_path,
                                 areas=areas)
    fetch = SharedOsmFetch(cache_layout=layout)
    fetch.features_for(BBox(*_TRIP_2), set(LAYERS))
    # One set on disk, for the area — not one per trip.
    assert [p.name for p in layout.candidates_dir.iterdir()] == [
        layout.candidate_set(area).name]
    assert areas.resolve(_TRIP_2, cache_areas.PAYLOAD_CANDIDATES).area_bbox == area


def test_osm_source_names_the_areas_pin(tmp_path, mirror):
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.test"))
    client.post("/regions", json={"bbox": list(_TRIP_1)})
    _settle(client)
    mirror["closed"] = True
    client.post("/regions", json={"bbox": list(_TRIP_2)})
    _settle(client)
    assert client.app.state.readiness.osm_source_pin(fetched_at="2026-10-07") == \
        f"geofabrik:{_PIN}"
