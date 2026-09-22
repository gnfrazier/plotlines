"""Regression for issue #488: `/health` polls `capabilities.mirror`'s
`MIRROR_STATE.json` fetch every 2s for the life of the session
(`SidecarManager`, `client/lib/data/sidecar_manager.dart:652`), and every
sync FastAPI endpoint — `/health` included — shares one process-wide thread
pool. `load_mirror_state`'s DNS lookup has no timeout of its own (no
synchronous transport's does — see that function's docstring), so a stalled
resolver (the WSL-DNS-timing class of bug `#466` already hit once) used to be
able to hang a `/health` poll's thread indefinitely; enough of those piling
up starved unrelated, otherwise-near-instant endpoints like `/layers` and
`/tiles`.

`_mirror_capability` now runs the fetch on its own single-worker pool
(`Readiness._mirror_state_pool`) and gives up on it after
`_MIRROR_STATE_FETCH_TIMEOUT_S` regardless of whether the fetch itself ever
returns. This drives a `load_mirror_state` that never returns at all — a
stand-in for a permanently stalled resolver, worse than anything a real
timeout would produce — and asserts `/health` still answers promptly and
`/layers` (on the shared pool) is untouched while the stuck fetch is still
occupying its own pool.
"""

from __future__ import annotations

import threading
import time

from fastapi.testclient import TestClient

from plotlines_service import app as app_module


def test_a_stuck_mirror_state_fetch_does_not_block_other_endpoints(tmp_path, monkeypatch):
    monkeypatch.setattr(app_module, "_MIRROR_STATE_FETCH_TIMEOUT_S", 0.2)

    # Bounded at 15s purely so a broken test can't hang the whole suite —
    # the test always calls `unblock.set()` itself, well before that, once
    # it no longer needs the fetch to be stuck.
    unblock = threading.Event()

    def hung_fetch(source):
        unblock.wait(timeout=15.0)
        return {"schema_version": 1, "basemap": {}, "geofabrik": {}}

    monkeypatch.setattr(app_module, "load_mirror_state", hung_fetch)

    client = TestClient(app_module.create_app(
        tmp_path, mirror_state_url="http://mirror.invalid/MIRROR_STATE.json"))

    health_result: dict = {}

    def poll_health() -> None:
        start = time.monotonic()
        resp = client.get("/health")
        health_result["elapsed"] = time.monotonic() - start
        health_result["body"] = resp.json()

    health_thread = threading.Thread(target=poll_health)
    health_thread.start()
    # Let the stuck fetch actually claim its worker before racing /layers
    # against it.
    time.sleep(0.05)

    try:
        start = time.monotonic()
        layers_resp = client.get("/layers")
        layers_elapsed = time.monotonic() - start
    finally:
        health_thread.join(timeout=5.0)
        unblock.set()  # release the now-orphaned mirror-state worker
        client.app.state.readiness.shutdown()

    assert not health_thread.is_alive(), "/health never returned"
    assert health_result["elapsed"] < 2.0, (
        "/health should give up on a stuck fetch, not wait on it")
    mirror = health_result["body"]["capabilities"]["mirror"]
    assert mirror["stale"] is True
    assert "error" in mirror

    assert layers_resp.status_code == 200
    assert layers_elapsed < 1.0, (
        f"/layers took {layers_elapsed:.2f}s with a stuck mirror-state fetch "
        "in flight — it must never share a thread pool with /health's poll")


def test_repeated_polls_against_a_stuck_fetch_never_touch_the_shared_pool(
    tmp_path, monkeypatch,
):
    """The client polls `/health` every 2s regardless of whether the last
    poll's mirror fetch ever finished. Each poll submits a fresh fetch onto
    the dedicated single-worker pool (never the shared one), so however many
    polls stack up behind one stuck fetch, `/layers` must stay fast.

    Issue #367's `MirrorStateCache` would otherwise answer polls 2-5 from
    the first poll's cached (timed-out) result without touching the pool
    again — a real behaviour change worth having (see
    `test_mirror_state_cache.py`), but not what *this* regression is about,
    so the TTL is collapsed to 0 to keep every poll a genuine fresh fetch."""
    monkeypatch.setattr(app_module, "_MIRROR_STATE_FETCH_TIMEOUT_S", 0.1)
    monkeypatch.setattr(app_module, "_MIRROR_STATE_CACHE_TTL_S", 0.0)

    unblock = threading.Event()

    def hung_fetch(source):
        unblock.wait(timeout=15.0)
        return {"schema_version": 1, "basemap": {}, "geofabrik": {}}

    monkeypatch.setattr(app_module, "load_mirror_state", hung_fetch)

    client = TestClient(app_module.create_app(
        tmp_path, mirror_state_url="http://mirror.invalid/MIRROR_STATE.json"))

    try:
        # Five polls back to back, as if the sidecar's 2s poll loop had been
        # running against a resolver that never comes back.
        for _ in range(5):
            resp = client.get("/health")
            assert resp.json()["capabilities"]["mirror"]["stale"] is True

        start = time.monotonic()
        layers_resp = client.get("/layers")
        layers_elapsed = time.monotonic() - start
    finally:
        unblock.set()
        client.app.state.readiness.shutdown()

    assert layers_resp.status_code == 200
    assert layers_elapsed < 1.0, (
        f"/layers took {layers_elapsed:.2f}s after five stuck mirror-state "
        "fetches queued up — a growing backlog on the dedicated pool must "
        "still never spawn threads on the shared one")
