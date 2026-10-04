"""Issue #248 — an empty Overpass response (a bbox/mode with no routable
ways) must reach the client as a finished sentence, never as
`InsufficientResponseError: ...` leaking through `RegionState.build`'s
generic `except Exception` branch, and must not be retried."""

from __future__ import annotations

import time
from pathlib import Path

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


def test_empty_response_surfaces_as_a_finished_sentence_not_a_type_repr(
    tmp_path: Path, monkeypatch,
):
    def boom(*_a, **_k):
        raise region_lib.NoRoutableWaysError(
            "The drawn area has no routable ways for this mode. Try a "
            "larger area or a different mode."
        )

    monkeypatch.setattr(region_lib, "ensure_graph", boom)

    client = TestClient(create_app(tmp_path))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    entry = _wait(client, key, lambda e: "drawn area" in e.get("reason", ""))

    # Message-contract test (house style): verbatim, no `NoRoutableWaysError`
    # type name and no exception-repr prefix the generic branch would add.
    # `failed:` is `CapabilityState.to_dict`'s own status prefix, not one this
    # story adds.
    assert entry["reason"] == (
        "failed:The drawn area has no routable ways for this mode. Try a "
        "larger area or a different mode."
    )
    assert "NoRoutableWaysError" not in entry["reason"]
    assert entry["reason"].endswith(".")

    diag = client.get(f"/regions/{key}/diagnostics").json()
    assert diag["last_error"] == (
        "The drawn area has no routable ways for this mode. Try a larger "
        "area or a different mode."
    )
    assert "NoRoutableWaysError" not in diag["last_error"]


def test_empty_response_settles_failed_without_looping(tmp_path: Path, monkeypatch):
    """Not a transient failure (#248) — one build attempt settles the region
    `failed`, the same as any other failure, rather than the region spinning
    back through `ensure_graph`."""
    calls = 0

    def boom(*_a, **_k):
        nonlocal calls
        calls += 1
        raise region_lib.NoRoutableWaysError(
            "The drawn area has no routable ways for this mode. Try a "
            "larger area or a different mode."
        )

    monkeypatch.setattr(region_lib, "ensure_graph", boom)

    client = TestClient(create_app(tmp_path))
    key = client.post("/regions", json={"bbox": _BBOX}).json()["region"]
    _wait(client, key, lambda e: "drawn area" in e.get("reason", ""))

    assert calls == 1


def test_a_degenerate_bbox_is_refused_before_any_build(tmp_path: Path, monkeypatch):
    """Issue #628 — a 110 m × 6 m box (a press with almost no drag) is a 422
    with a sentence, not a region: no clip, no graph, no elevation call."""
    def never(*_a, **_k):
        raise AssertionError("a degenerate bbox must never reach a build")
    monkeypatch.setattr(region_lib, "ensure_graph", never)

    client = TestClient(create_app(tmp_path))
    resp = client.post("/regions", json={
        "bbox": [-81.67098, 36.12753, -81.66975, 36.12758]})
    assert resp.status_code == 422
    detail = resp.json()["detail"]
    assert "too small to route in" in detail
    assert detail.endswith(".")
    assert client.get("/health").json()["capabilities"]["routing"].get("regions", {}) == {}
