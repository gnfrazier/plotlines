"""Unit tests for per-capability `/health` readiness — PRD FR121, FR91,
FR120; ARCH §8.3 (breaking change B1); Story M12a; issue #154.

Before #154, `create_app` eagerly loaded one committed Boulder fixture graph
at startup and `/health.capabilities.routing` was a single process-wide
flag. Now routing is per-region (D41: every trip bbox gets its own graph,
never a process-wide default) and nothing loads until a client calls
`POST /regions` — these tests exercise that lifecycle instead.
"""

from __future__ import annotations

import time
from pathlib import Path

import osmnx as ox
import pytest
from fastapi.testclient import TestClient

from plotlines_core.graph import regions as region_lib
from plotlines_service.app import create_app
from plotlines_service.version import VERSION

_BBOX = [-105.30, 39.99, -105.25, 40.03]  # SPIKE-00's Boulder fixture bbox
_MISSING_BBOX = [-1.0, -1.0, 1.0, 1.0]     # never pre-seeded in the cache


@pytest.fixture(autouse=True)
def _no_network_overpass(monkeypatch):
    """`ensure_graph` hits a live Overpass call on a cache miss — every test
    in this module either pre-seeds the cache (no call made) or expects the
    build to fail, so nothing here should ever depend on network access."""
    def _refuse(*_args, **_kwargs):
        raise RuntimeError("no network access in this test")
    monkeypatch.setattr(ox, "graph_from_bbox", _refuse)


def _wait_for(client: TestClient, predicate, timeout: float = 20.0) -> dict:
    """Poll `/health` until `predicate(capabilities)` is true or time out."""
    deadline = time.perf_counter() + timeout
    body = client.get("/health").json()
    while not predicate(body["capabilities"]):
        if time.perf_counter() > deadline:
            raise AssertionError(f"timed out waiting for capabilities: {body['capabilities']}")
        time.sleep(0.05)
        body = client.get("/health").json()
    return body


def test_tiles_and_layers_are_ready_immediately(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    caps = client.get("/health").json()["capabilities"]
    assert caps["tiles"] == {"ready": True}
    assert caps["layers"]["ready"] is True
    assert caps["layers"]["per_layer"]
    assert all(state == "ready" for state in caps["layers"]["per_layer"].values())


def test_elevation_reports_a_fixed_not_ready_reason(tmp_path: Path) -> None:
    # Issue #154's explicit scoping note: elevation acquisition is gated on
    # FR87 (#148) and never attempted here, so it never blocks routing.
    client = TestClient(create_app(tmp_path))
    caps = client.get("/health").json()["capabilities"]
    assert caps["elevation"]["ready"] is False
    assert "reason" in caps["elevation"]


def test_routing_regions_is_empty_before_any_region_is_ensured(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    caps = client.get("/health").json()["capabilities"]
    assert caps["routing"] == {"regions": {}}


def test_post_regions_returns_202_and_a_key(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    resp = client.post("/regions", json={"bbox": _MISSING_BBOX})
    assert resp.status_code == 202
    key = resp.json()["region"]
    assert key == region_lib.region_key(tuple(_MISSING_BBOX), "bike")


def test_post_regions_is_idempotent_for_the_same_bbox(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    first = client.post("/regions", json={"bbox": _MISSING_BBOX}).json()["region"]
    second = client.post("/regions", json={"bbox": _MISSING_BBOX}).json()["region"]
    assert first == second


def test_a_region_with_no_cache_and_no_network_settles_to_failed(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    key = client.post("/regions", json={"bbox": _MISSING_BBOX}).json()["region"]
    body = _wait_for(
        client, lambda c: c["routing"]["regions"].get(key, {}).get("reason", "")
                          .startswith("failed:"),
    )
    region = body["capabilities"]["routing"]["regions"][key]
    assert region["ready"] is False
    assert region["reason"].startswith("failed:")
    assert "RuntimeError" in region["reason"]


def test_routing_endpoint_404s_for_an_unknown_region(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    resp = client.post("/segments/generate", json={
        "region": "never-ensured",
        "start": {"lat": 40.0, "lon": -105.3},
        "end": {"lat": 40.01, "lon": -105.29},
        "shape": "point_to_point",
        "theme": "balanced",
    })
    assert resp.status_code == 404


def test_routing_endpoint_503s_naming_the_reason_while_not_ready(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    key = client.post("/regions", json={"bbox": _MISSING_BBOX}).json()["region"]
    _wait_for(client, lambda c: c["routing"]["regions"].get(key, {}).get("reason", "")
             .startswith("failed:"), timeout=30.0)
    resp = client.post("/segments/generate", json={
        "region": key,
        "start": {"lat": 0.0, "lon": 0.0},
        "end": {"lat": 0.01, "lon": 0.01},
        "shape": "point_to_point",
        "theme": "balanced",
    })
    assert resp.status_code == 503
    assert "routing not ready" in resp.json()["detail"]
    assert "failed:" in resp.json()["detail"]


@pytest.mark.skipif(
    not (Path(__file__).resolve().parents[2] / "spikes" / "SPIKE-00" / "cache"
        / "boulder_bike.graphml").exists(),
    reason="SPIKE-00 fixture graph not present in this checkout",
)
def test_a_pre_cached_region_becomes_ready_without_network(tmp_path: Path) -> None:
    import shutil

    fixture = (Path(__file__).resolve().parents[2] / "spikes" / "SPIKE-00" / "cache"
              / "boulder_bike.graphml")
    key = region_lib.region_key(tuple(_BBOX), "bike")
    dest = tmp_path / "regions" / key / "graph.graphml"
    dest.parent.mkdir(parents=True)
    shutil.copy(fixture, dest)

    client = TestClient(create_app(tmp_path))
    got_key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    assert got_key == key

    body = _wait_for(client, lambda c: c["routing"]["regions"].get(key, {}).get("ready") is True)
    assert body["capabilities"]["routing"]["regions"][key] == {"ready": True}


def test_health_exposes_matched_app_and_sidecar_version(tmp_path: Path) -> None:
    # A8/M12's version-mismatch refusal itself lives client-side and is
    # unchanged by this story; this only checks `/health` still surfaces the
    # two fields that comparison would read.
    client = TestClient(create_app(tmp_path))
    body = client.get("/health").json()
    assert body["app_version"] == VERSION
    assert body["sidecar_version"] == VERSION
