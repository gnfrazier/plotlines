"""Unit tests for per-capability `/health` readiness — PRD FR121, FR91;
ARCH §8.3 (breaking change B1); Story M12a.

`create_app` spawns a background thread that loads the graph then the
elevation sampler (`Readiness.load`), so most assertions here need to poll
`/health` until the capability under test has settled rather than reading it
once — the whole point of this story is that different capabilities settle
at different times.
"""

from __future__ import annotations

import shutil
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_service.app import create_app
from plotlines_service.version import VERSION

FIXTURE_CACHE_DIR = Path(__file__).resolve().parents[2] / "spikes" / "SPIKE-00" / "cache"
GRAPH_FILE = "boulder_bike.graphml"
DEM_FILE = "boulder_dem.tif"


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
    # No graph/DEM at tmp_path — the load thread will fail quickly — but
    # tiles/layers have no startup dependency at all (B1) and must read
    # ready on the very first call, before the load thread has even run.
    client = TestClient(create_app(tmp_path))
    caps = client.get("/health").json()["capabilities"]
    assert caps["tiles"] == {"ready": True}
    assert caps["layers"]["ready"] is True
    assert caps["layers"]["per_layer"]
    assert all(state == "ready" for state in caps["layers"]["per_layer"].values())


def test_routing_and_elevation_start_not_ready(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    caps = client.get("/health").json()["capabilities"]
    assert caps["routing"]["ready"] is False
    assert caps["elevation"]["ready"] is False


def test_missing_cache_settles_to_failed_with_reason(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    body = _wait_for(client, lambda c: not c["routing"].get("progress") and "reason" in c["routing"])
    routing = body["capabilities"]["routing"]
    elevation = body["capabilities"]["elevation"]
    assert routing["ready"] is False
    assert routing["reason"].startswith("graph_failed:")
    assert elevation["ready"] is False
    assert elevation["reason"].startswith("failed:")


def test_routing_endpoint_503_names_the_reason_while_not_ready(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    _wait_for(client, lambda c: c["routing"]["reason"].startswith("graph_failed:"))
    resp = client.post("/segments/generate", json={
        "start": {"lat": 40.0, "lon": -105.3},
        "end": {"lat": 40.01, "lon": -105.29},
        "mode": "cycling",
        "shape": "point_to_point",
        "theme": "balanced",
    })
    assert resp.status_code == 503
    assert "routing not ready" in resp.json()["detail"]
    assert "graph_failed" in resp.json()["detail"]


@pytest.mark.skipif(
    not (FIXTURE_CACHE_DIR / GRAPH_FILE).exists() or not (FIXTURE_CACHE_DIR / DEM_FILE).exists(),
    reason="SPIKE-00 fixture graph/DEM not present in this checkout",
)
def test_graph_and_elevation_both_ready_unlocks_routing() -> None:
    client = TestClient(create_app(FIXTURE_CACHE_DIR))
    body = _wait_for(client, lambda c: c["routing"]["ready"] is True)
    caps = body["capabilities"]
    assert caps["elevation"] == {"ready": True}
    assert caps["routing"] == {"ready": True}
    assert caps["tiles"]["ready"] is True
    assert caps["layers"]["ready"] is True

    resp = client.post("/segments/generate", json={
        "start": {"lat": 40.0175, "lon": -105.2797},
        "end": {"lat": 40.02, "lon": -105.275},
        "mode": "cycling",
        "shape": "point_to_point",
        "theme": "balanced",
    })
    assert resp.status_code == 200


@pytest.mark.skipif(
    not (FIXTURE_CACHE_DIR / GRAPH_FILE).exists(),
    reason="SPIKE-00 fixture graph not present in this checkout",
)
def test_elevation_failure_does_not_block_routing_forever(tmp_path: Path) -> None:
    # Copy only the graph file — elevation enrichment has nothing to open
    # and must fail, but that must not wedge routing readiness forever
    # (FR121: never blocking the app).
    shutil.copy(FIXTURE_CACHE_DIR / GRAPH_FILE, tmp_path / GRAPH_FILE)
    client = TestClient(create_app(tmp_path))

    body = _wait_for(client, lambda c: c["routing"]["ready"] is True)
    caps = body["capabilities"]
    assert caps["elevation"]["ready"] is False
    assert caps["elevation"]["reason"].startswith("failed:")
    assert caps["routing"] == {"ready": True}


def test_routing_reports_elevation_enriching_reason_while_graph_is_ready() -> None:
    # A graph-only fixture load is fast; assert the *shape* ARCH §8.3
    # documents for the in-between state rather than trying to catch the
    # narrow timing window, by driving the CapabilityState directly.
    from plotlines_service.app import CapabilityState, Readiness

    state = Readiness()
    state.graph_state.succeed("graph loaded")
    state.elevation_state.start("opening elevation")
    cap = state.routing_capability()
    assert cap["ready"] is False
    assert cap["reason"] == "elevation_enriching"
    assert 0.0 <= cap["progress"] < 1.0
    assert cap["eta_s"] > 0
    assert isinstance(state.elevation_state, CapabilityState)


def test_health_exposes_matched_app_and_sidecar_version(tmp_path: Path) -> None:
    # A8/M12's version-mismatch refusal itself lives client-side and is
    # unchanged by this story; this only checks `/health` still surfaces the
    # two fields that comparison would read.
    client = TestClient(create_app(tmp_path))
    body = client.get("/health").json()
    assert body["app_version"] == VERSION
    assert body["sidecar_version"] == VERSION
