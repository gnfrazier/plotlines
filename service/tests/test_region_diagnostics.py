"""Issue #232 — instrumentation for a region build that keeps failing or
never settles: the full last-failure traceback (which `/health` does not
carry), per-phase timings, and an attempt counter that exposes a requeue
storm.
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.graph import regions as region_lib
from plotlines_service.app import create_app

_BBOX = [-82.83, 35.36, -82.14, 35.79]  # Buncombe County


def _wait(client: TestClient, key: str, pred, timeout=10.0):
    deadline = time.perf_counter() + timeout
    while time.perf_counter() < deadline:
        entry = client.get("/health").json()["capabilities"]["routing"]["regions"].get(key, {})
        if pred(entry):
            return entry
        time.sleep(0.02)
    raise AssertionError(f"region {key} never satisfied {pred}")


def test_diagnostics_404_for_an_unknown_region(tmp_path: Path):
    client = TestClient(create_app(tmp_path))
    assert client.get("/regions/deadbeef/diagnostics").status_code == 404


def test_diagnostics_carries_the_full_traceback_of_a_failed_build(tmp_path, monkeypatch):
    def boom(*_a, **_k):
        raise RuntimeError("largest_component: graph has no strongly connected core")

    monkeypatch.setattr(region_lib, "ensure_graph", boom)

    client = TestClient(create_app(tmp_path))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    _wait(client, key, lambda e: e.get("reason", "").startswith("failed:"))

    diag = client.get(f"/regions/{key}/diagnostics").json()
    assert diag["state"] == "failed"
    assert diag["attempts"] == 1
    assert diag["last_error"] == (
        "RuntimeError: largest_component: graph has no strongly connected core"
    )
    assert "Traceback (most recent call last)" in diag["last_traceback"]
    assert "RuntimeError" in diag["last_traceback"]
    assert "total" in diag["timings_s"]


def test_health_attempts_counter_climbs_on_every_requeue(tmp_path, monkeypatch):
    """A `POST /regions` for a settled-failed bbox re-queues the build (issue
    #229). The `attempts` field on the `/health` routing entry makes a
    runaway requeue loop visible: it climbs by one each time.

    The post-failure cooldown (issue #247) is zeroed here so this stays a test
    of the counter, not of the interval — the cooldown itself is covered in
    `test_regions_build_serialised.py`."""
    monkeypatch.setattr("plotlines_service.app.REGION_REQUEUE_COOLDOWN_S", 0.0)

    def boom(*_a, **_k):
        raise RuntimeError("nope")

    monkeypatch.setattr(region_lib, "ensure_graph", boom)

    client = TestClient(create_app(tmp_path))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    entry = _wait(client, key, lambda e: e.get("reason", "").startswith("failed:"))
    assert entry["attempts"] == 1

    client.post("/regions", json={"bbox": _BBOX})
    entry = _wait(client, key, lambda e: e.get("attempts") == 2)

    client.post("/regions", json={"bbox": _BBOX})
    _wait(client, key, lambda e: e.get("attempts") == 3)


def test_ensure_region_logs_its_decision(tmp_path, monkeypatch, caplog):
    monkeypatch.setattr("plotlines_service.app.REGION_REQUEUE_COOLDOWN_S", 0.0)

    def boom(*_a, **_k):
        raise RuntimeError("nope")

    monkeypatch.setattr(region_lib, "ensure_graph", boom)
    client = TestClient(create_app(tmp_path))

    with caplog.at_level("INFO", logger="plotlines.sidecar"):
        key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
        _wait(client, key, lambda e: e.get("reason", "").startswith("failed:"))
        client.post("/regions", json={"bbox": _BBOX})
        _wait(client, key, lambda e: e.get("attempts") == 2)

    text = caplog.text
    assert "decision=NEW_BUILD" in text
    assert "decision=REQUEUE_AFTER_FAILURE" in text
    assert "region build FAILED" in text
