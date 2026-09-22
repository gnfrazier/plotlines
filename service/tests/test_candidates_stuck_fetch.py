"""Regression for issue #490: `/candidates`'s Overpass round trip runs
through `plotlines_core.osm_identity.OSM_SETTINGS_LOCK` for the length of a
whole attempt, with no caller-side deadline of its own on what osmnx does
underneath it — the same shape #488 found in `capabilities.mirror`'s fetch.
`/candidates` is a sync FastAPI endpoint sharing its thread pool with
`/health`, `/layers`, `/tiles`, so a stuck fetch used to be able to starve
all of them for as long as the fetch (or the lock it was waiting on) never
returned.

`_fetch_candidates` now runs `LayerRegistry.fetch_candidates_all` on its own
single-worker pool (`Readiness._candidate_fetch_pool`) and gives up after
`_CANDIDATE_FETCH_TIMEOUT_S` regardless of whether the fetch itself ever
returns — the #488 treatment applied to the candidate path. This asserts
`/candidates` still answers promptly with an honest per-layer timeout and
that `/layers` (on the shared pool) is untouched while the stuck fetch is
still occupying its own pool.
"""

from __future__ import annotations

import threading
import time

from fastapi.testclient import TestClient

from plotlines_core.curation.registry import LayerRegistry
from plotlines_service import app as app_module


def test_a_stuck_candidate_fetch_does_not_block_other_endpoints(tmp_path, monkeypatch):
    monkeypatch.setattr(app_module, "_CANDIDATE_FETCH_TIMEOUT_S", 0.2)

    # Bounded at 15s purely so a broken test can't hang the whole suite —
    # the test always calls `unblock.set()` itself, well before that, once
    # it no longer needs the fetch to be stuck.
    unblock = threading.Event()

    def hung_fetch_candidates_all(self, bbox, layers):
        unblock.wait(timeout=15.0)
        return [], {}

    monkeypatch.setattr(LayerRegistry, "fetch_candidates_all", hung_fetch_candidates_all)

    client = TestClient(app_module.create_app(tmp_path))

    candidates_result: dict = {}

    def call_candidates() -> None:
        start = time.monotonic()
        resp = client.get(
            "/candidates",
            params={"west": 0.0, "south": 0.0, "east": 0.01, "north": 0.01,
                    "layers": "historic"},
        )
        candidates_result["elapsed"] = time.monotonic() - start
        candidates_result["body"] = resp.json()

    candidates_thread = threading.Thread(target=call_candidates)
    candidates_thread.start()
    # Let the stuck fetch actually claim its worker before racing /layers
    # against it.
    time.sleep(0.05)

    try:
        start = time.monotonic()
        layers_resp = client.get("/layers")
        layers_elapsed = time.monotonic() - start
    finally:
        candidates_thread.join(timeout=5.0)
        unblock.set()  # release the now-orphaned candidate-fetch worker
        client.app.state.readiness.shutdown()

    assert not candidates_thread.is_alive(), "/candidates never returned"
    assert candidates_result["elapsed"] < 2.0, (
        "/candidates should give up on a stuck fetch, not wait on it")
    body = candidates_result["body"]
    assert body["layers_unavailable"] == {
        "historic": "failed:candidate_fetch_timed_out"}
    assert body["layers_served"] == []

    assert layers_resp.status_code == 200
    assert layers_elapsed < 1.0, (
        f"/layers took {layers_elapsed:.2f}s with a stuck candidate fetch "
        "in flight — it must never share a thread pool with /candidates")


def test_repeated_candidate_calls_against_a_stuck_fetch_never_touch_the_shared_pool(
    tmp_path, monkeypatch,
):
    """Every `/candidates` call submits a fresh fetch onto the dedicated
    single-worker pool (never the shared one), so however many calls stack
    up behind one stuck fetch, `/layers` must stay fast."""
    monkeypatch.setattr(app_module, "_CANDIDATE_FETCH_TIMEOUT_S", 0.1)

    unblock = threading.Event()

    def hung_fetch_candidates_all(self, bbox, layers):
        unblock.wait(timeout=15.0)
        return [], {}

    monkeypatch.setattr(LayerRegistry, "fetch_candidates_all", hung_fetch_candidates_all)

    client = TestClient(app_module.create_app(tmp_path))

    try:
        for _ in range(5):
            resp = client.get(
                "/candidates",
                params={"west": 0.0, "south": 0.0, "east": 0.01, "north": 0.01,
                        "layers": "historic"},
            )
            assert resp.json()["layers_unavailable"] == {
                "historic": "failed:candidate_fetch_timed_out"}

        start = time.monotonic()
        layers_resp = client.get("/layers")
        layers_elapsed = time.monotonic() - start
    finally:
        unblock.set()
        client.app.state.readiness.shutdown()

    assert layers_resp.status_code == 200
    assert layers_elapsed < 1.0, (
        f"/layers took {layers_elapsed:.2f}s after five stuck candidate "
        "fetches queued up — a growing backlog on the dedicated pool must "
        "still never spawn threads on the shared one")
