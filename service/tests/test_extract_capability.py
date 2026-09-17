"""`GET /health`'s `capabilities.extract` and its `POST /regions` trigger —
issue #274 (Phase 3.2 of epic #272; PRD FR120/FR121; review §8(1)-(2),
§11.5).

`RegionState.build` calls `plotlines_core.graph.extract_fetch.ensure_extract`
directly; these tests monkeypatch that one call site (the same "stub the one
network-shaped seam" discipline `test_health.py`'s `_no_network_overpass`
uses for `ox.graph_from_bbox`) rather than opening a real socket — the wire
contract itself (headers, byte streaming, honest exceptions) is covered in
`core/tests/test_extract_fetch.py` and the server side in
`test_mirror_clip_server.py`.
"""

from __future__ import annotations

import time
from pathlib import Path

import osmnx as ox
import pytest
from fastapi.testclient import TestClient

from plotlines_core.graph import extract_fetch
from plotlines_service.app import create_app

_BBOX = [-105.30, 39.99, -105.25, 40.03]  # SPIKE-00's Boulder fixture bbox


@pytest.fixture(autouse=True)
def _no_network_overpass(monkeypatch):
    """Every test here either never reaches the graph build or supplies its
    own fake — none should depend on network access (issue #154's
    `test_health.py` discipline, applied here too since `RegionState.build`
    still runs both steps)."""
    def _refuse(*_args, **_kwargs):
        raise RuntimeError("no network access in this test")
    monkeypatch.setattr(ox, "graph_from_bbox", _refuse)


def _settle_builds(client: TestClient) -> None:
    client.app.state.readiness._build_pool.shutdown(wait=True)


def _wait_for(client: TestClient, predicate, timeout: float = 20.0) -> dict:
    deadline = time.perf_counter() + timeout
    body = client.get("/health").json()
    while not predicate(body["capabilities"]):
        if time.perf_counter() > deadline:
            raise AssertionError(f"timed out waiting for capabilities: {body['capabilities']}")
        time.sleep(0.02)
        body = client.get("/health").json()
    return body


def _stub_graph(monkeypatch) -> None:
    """A tiny synthetic graph so the (unrelated, independent) region graph
    step settles `ready` instead of `failed` — several tests below assert
    on the extract capability alone and don't want a `failed` routing
    capability muddying that."""
    import networkx as nx

    def _fake_graph(*_args, **_kwargs):
        g = nx.MultiDiGraph()
        g.add_node(1, y=40.0, x=-105.28)
        g.add_node(2, y=40.01, x=-105.27)
        g.add_edge(1, 2, length=100.0)
        g.add_edge(2, 1, length=100.0)
        g.graph["crs"] = "epsg:4326"
        return g

    monkeypatch.setattr(ox, "graph_from_bbox", _fake_graph)


# --- configured/unconfigured shape -----------------------------------------

def test_extract_capability_reports_unconfigured_by_default(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    caps = client.get("/health").json()["capabilities"]
    assert caps["extract"] == {"configured": False}


def test_extract_capability_reports_configured_with_no_regions_yet(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))
    caps = client.get("/health").json()["capabilities"]
    assert caps["extract"] == {"configured": True, "regions": {}}


# --- FR120: nothing downloads before an Author declares an extent ---------

def test_a_fresh_install_with_no_trip_makes_no_extract_request(tmp_path: Path, monkeypatch) -> None:
    def _explode(*_args, **_kwargs):
        raise AssertionError("no extract request should fire with no POST /regions call")

    monkeypatch.setattr(extract_fetch, "ensure_extract", _explode)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))

    for _ in range(3):
        client.get("/health")  # polling /health alone must never trigger a fetch


def test_unconfigured_mirror_never_calls_ensure_extract(tmp_path: Path, monkeypatch) -> None:
    def _explode(*_args, **_kwargs):
        raise AssertionError("ensure_extract must not run when --mirror-clip-url is unset")

    monkeypatch.setattr(extract_fetch, "ensure_extract", _explode)
    client = TestClient(create_app(tmp_path))  # no mirror_clip_url

    client.post("/regions", json={"bbox": _BBOX})
    _settle_builds(client)


# --- POST /regions triggers the download, independent of the graph --------

def test_post_regions_populates_the_extract_capability(tmp_path: Path, monkeypatch) -> None:
    _stub_graph(monkeypatch)

    def _fake_ensure_extract(bbox, *, mirror_url, cache_dir, client_key=None,
                              progress=None, **_kwargs):
        progress.status = "ready"
        progress.bytes_downloaded = 12345
        progress.total_bytes = 12345
        return cache_dir / "fake.osm.pbf"

    monkeypatch.setattr(extract_fetch, "ensure_extract", _fake_ensure_extract)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))

    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    _settle_builds(client)

    caps = client.get("/health").json()["capabilities"]
    assert caps["extract"]["configured"] is True
    assert caps["extract"]["regions"][key] == {"ready": True}
    # Independent capability: the (stubbed) graph build ran and settled too.
    assert caps["routing"]["regions"][key] == {"ready": True}


def test_extract_progress_is_observed_bytes_not_a_time_estimate(tmp_path: Path, monkeypatch) -> None:
    import threading

    _stub_graph(monkeypatch)
    release = threading.Event()

    def _fake_ensure_extract(bbox, *, mirror_url, cache_dir, client_key=None,
                              progress=None, **_kwargs):
        progress.status = "downloading"
        progress.detail = "requesting mirror clip"
        progress.total_bytes = 1000
        progress.bytes_downloaded = 250
        release.wait(timeout=5.0)
        progress.status = "ready"
        progress.bytes_downloaded = 1000
        return cache_dir / "fake.osm.pbf"

    monkeypatch.setattr(extract_fetch, "ensure_extract", _fake_ensure_extract)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]

    try:
        body = _wait_for(
            client, lambda c: c["extract"]["regions"].get(key, {}).get("bytes_downloaded", 0) > 0,
        )
        entry = body["capabilities"]["extract"]["regions"][key]
        assert entry["ready"] is False
        assert entry["bytes_downloaded"] == 250
        assert entry["total_bytes"] == 1000
        assert entry["progress"] == 0.25
    finally:
        release.set()
        _settle_builds(client)


def test_reused_extract_is_marked_ready_and_reused(tmp_path: Path, monkeypatch) -> None:
    _stub_graph(monkeypatch)

    def _fake_ensure_extract(bbox, *, mirror_url, cache_dir, client_key=None,
                              progress=None, **_kwargs):
        progress.status = "ready"
        progress.reused = True
        progress.bytes_downloaded = 42
        progress.total_bytes = 42
        return cache_dir / "cached.osm.pbf"

    monkeypatch.setattr(extract_fetch, "ensure_extract", _fake_ensure_extract)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    _settle_builds(client)

    entry = client.get("/health").json()["capabilities"]["extract"]["regions"][key]
    assert entry == {"ready": True, "reused": True}


# --- honest failure surface, and independence from routing ----------------

def test_no_extract_coverage_is_distinct_from_mirror_unreachable(tmp_path: Path, monkeypatch) -> None:
    _stub_graph(monkeypatch)

    def _fake_ensure_extract(bbox, *, mirror_url, cache_dir, client_key=None,
                              progress=None, **_kwargs):
        progress.status = "failed"
        progress.detail = "no_mirror_coverage"
        raise extract_fetch.NoExtractCoverage(
            "The Plotlines map-data mirror doesn't have OSM data for this area yet."
        )

    monkeypatch.setattr(extract_fetch, "ensure_extract", _fake_ensure_extract)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    _settle_builds(client)

    entry = client.get("/health").json()["capabilities"]["extract"]["regions"][key]
    assert entry["ready"] is False
    assert entry["reason"] == "failed:no_mirror_coverage"


def test_mirror_unreachable_reads_distinctly_from_no_coverage(tmp_path: Path, monkeypatch) -> None:
    _stub_graph(monkeypatch)

    def _fake_ensure_extract(bbox, *, mirror_url, cache_dir, client_key=None,
                              progress=None, **_kwargs):
        progress.status = "failed"
        progress.detail = "unreachable"
        raise extract_fetch.MirrorUnreachable(
            "Couldn't reach the Plotlines map-data mirror to prepare local map data."
        )

    monkeypatch.setattr(extract_fetch, "ensure_extract", _fake_ensure_extract)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    _settle_builds(client)

    entry = client.get("/health").json()["capabilities"]["extract"]["regions"][key]
    assert entry["ready"] is False
    assert entry["reason"] == "failed:unreachable"


def test_an_extract_failure_never_blocks_the_routing_capability(tmp_path: Path, monkeypatch) -> None:
    _stub_graph(monkeypatch)

    def _fake_ensure_extract(bbox, *, mirror_url, cache_dir, client_key=None,
                              progress=None, **_kwargs):
        progress.status = "failed"
        progress.detail = "unreachable"
        raise extract_fetch.MirrorUnreachable("mirror down")

    monkeypatch.setattr(extract_fetch, "ensure_extract", _fake_ensure_extract)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    _settle_builds(client)

    caps = client.get("/health").json()["capabilities"]
    assert caps["extract"]["regions"][key]["ready"] is False
    # B1: one capability's failure never blocks another. The graph build
    # (stubbed to a synthetic graph) settles ready regardless.
    assert caps["routing"]["regions"][key] == {"ready": True}


def test_an_unexpected_extract_exception_never_crashes_the_build(tmp_path: Path, monkeypatch) -> None:
    _stub_graph(monkeypatch)

    def _fake_ensure_extract(*_args, **_kwargs):
        raise ValueError("something unrelated broke")

    monkeypatch.setattr(extract_fetch, "ensure_extract", _fake_ensure_extract)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    _settle_builds(client)

    caps = client.get("/health").json()["capabilities"]
    assert caps["extract"]["regions"][key]["reason"].startswith("failed:ValueError")
    assert caps["routing"]["regions"][key] == {"ready": True}
