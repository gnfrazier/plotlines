"""End-to-end wiring for issue #275 (Phase 3.3 of epic #272) — `ensure_graph`
and `OsmLayerProvider.fetch` reading a single mirror clip instead of calling
Overpass.

`RegionState.build` already calls `graph.extract_fetch.ensure_extract` (issue
#274) to land a clip on disk; these tests monkeypatch that one call site to
actually write a tiny synthetic `.osm.pbf` (rather than the no-op stub
`test_extract_capability.py` uses, which never touches disk) at the exact
`CacheLayout.osm_extract(bbox, pin)` location the real fetch would use, then
assert both `POST /regions` and `GET /candidates` succeed for that bbox with
`ox.graph_from_bbox` / `ox.features_from_bbox` stubbed to raise — the literal
"public Overpass endpoints blocked at the firewall" acceptance scenario —
and that both consumers read the one clip that one fetch produced.
"""

from __future__ import annotations

import time
from pathlib import Path

import osmium
import osmnx as ox
import pytest
from fastapi.testclient import TestClient
from osmium.osm import mutable

from plotlines_core.cache_layout import CacheLayout
from plotlines_core.graph import extract_fetch
from plotlines_service.app import create_app

_BBOX = [-105.30, 39.99, -105.25, 40.03]
_PIN = "2026-09-01"


def _clip_node(id_: int, lon: float, lat: float, tags: dict[str, str] | None = None):
    return mutable.Node(id=id_, location=(lon, lat), tags=tags or {})


def _clip_way(id_: int, node_ids: list[int], tags: dict[str, str] | None = None):
    return mutable.Way(id=id_, nodes=node_ids, tags=tags or {})


def _write_real_clip(cache_dir: Path) -> Path:
    """A tiny, real `.osm.pbf` at exactly the on-disk location
    `graph.extract_fetch.ensure_extract` would have written it to: one
    routable way for the graph consumer, one tagged POI node for the
    candidates consumer, in the same file."""
    bbox = tuple(_BBOX)
    path = CacheLayout(cache_dir).osm_extract(bbox, _PIN)
    path.parent.mkdir(parents=True, exist_ok=True)
    with osmium.SimpleWriter(str(path)) as writer:
        writer.add_node(_clip_node(1, -105.29, 40.00))
        writer.add_node(_clip_node(2, -105.28, 40.01))
        writer.add_node(_clip_node(3, -105.27, 40.02, {"natural": "peak", "name": "Clip Peak"}))
        writer.add_way(_clip_way(10, [1, 2], {"highway": "residential"}))
    return path


@pytest.fixture(autouse=True)
def _overpass_blocked(monkeypatch):
    """Every test in this file stands in for "the public Overpass endpoints
    are blocked at the firewall" — both transports this issue swaps must
    never be called when a clip is already cached."""
    def _refuse_graph(*_args, **_kwargs):
        raise AssertionError("ensure_graph must not touch Overpass when a local clip is cached")

    def _refuse_candidates(*_args, **_kwargs):
        raise AssertionError("OsmLayerProvider.fetch must not touch Overpass "
                             "when a local clip is cached")

    monkeypatch.setattr(ox, "graph_from_bbox", _refuse_graph)
    monkeypatch.setattr(ox, "features_from_bbox", _refuse_candidates)


def _fake_ensure_extract(bbox, *, mirror_url, cache_dir, client_key=None,
                         progress=None, **_kwargs):
    path = _write_real_clip(cache_dir)
    if progress is not None:
        size = path.stat().st_size
        progress.status = "ready"
        progress.bytes_downloaded = size
        progress.total_bytes = size
    return path


def _settle_builds(client: TestClient) -> None:
    client.app.state.readiness._build_pool.shutdown(wait=True)


def test_post_regions_builds_a_graph_from_the_clip_with_overpass_blocked(
    tmp_path: Path, monkeypatch,
) -> None:
    monkeypatch.setattr(extract_fetch, "ensure_extract", _fake_ensure_extract)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))

    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    _settle_builds(client)

    caps = client.get("/health").json()["capabilities"]
    assert caps["routing"]["regions"][key] == {"ready": True}
    assert caps["extract"]["regions"][key] == {"ready": True}


def test_candidates_reads_the_same_clip_the_region_build_fetched(
    tmp_path: Path, monkeypatch,
) -> None:
    """The heart of #275's acceptance: one bbox, one clip fetch
    (`extract_fetch.ensure_extract` is called at most once below), and both
    `/regions` (graph) and `/candidates` (POIs) succeed reading it."""
    calls = {"n": 0}

    def _counting_fake_ensure_extract(*args, **kwargs):
        calls["n"] += 1
        return _fake_ensure_extract(*args, **kwargs)

    monkeypatch.setattr(extract_fetch, "ensure_extract", _counting_fake_ensure_extract)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))

    client.post("/regions", json={"bbox": _BBOX})
    _settle_builds(client)

    resp = client.get("/candidates", params={
        "west": _BBOX[0], "south": _BBOX[1], "east": _BBOX[2], "north": _BBOX[3],
        "layers": "natural",
    })

    assert resp.status_code == 200
    body = resp.json()
    ids = {c["id"] for c in body["candidates"]}
    assert ids == {"node/3"}
    assert body["layers_served"] == ["natural"]
    assert body["layers_unavailable"] == {}

    # extract_fetch.ensure_extract only ever runs from RegionState.build
    # (POST /regions); /candidates reads the file that call already wrote.
    assert calls["n"] == 1
