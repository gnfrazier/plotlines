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

Issue #536 moved the read off `/health` entirely: `MirrorStateCache` answers
from the cache (or "not checked yet") at once and refreshes in the
background, one read per source at a time. These tests now pin that shape:
`/health` never waits, a read stuck past `_MIRROR_STATE_FETCH_TIMEOUT_S`
reports as timed out, and polls behind a stuck read never start another.
"""

from __future__ import annotations

import threading
import time

from fastapi.testclient import TestClient

from plotlines_service import app as app_module


def _stuck_client(tmp_path, monkeypatch):
    unblock = threading.Event()
    calls: list[str] = []

    def hung_fetch(source):
        calls.append(source)
        unblock.wait(timeout=15.0)
        return {"schema_version": 1, "basemap": {}, "geofabrik": {}}

    monkeypatch.setattr(app_module, "load_mirror_state", hung_fetch)
    client = TestClient(app_module.create_app(
        tmp_path, mirror_state_url="http://mirror.invalid/MIRROR_STATE.json"))
    return client, unblock, calls


def test_a_stuck_mirror_state_fetch_does_not_block_health_or_other_endpoints(
    tmp_path, monkeypatch,
):
    monkeypatch.setattr(app_module, "_MIRROR_STATE_FETCH_TIMEOUT_S", 0.2)
    client, unblock, calls = _stuck_client(tmp_path, monkeypatch)
    try:
        start = time.monotonic()
        first = client.get("/health").json()["capabilities"]["mirror"]
        health_elapsed = time.monotonic() - start

        start = time.monotonic()
        layers_resp = client.get("/layers")
        layers_elapsed = time.monotonic() - start

        time.sleep(0.3)  # past the fetch timeout, the read still stuck
        later = client.get("/health").json()["capabilities"]["mirror"]
    finally:
        unblock.set()  # release the orphaned mirror-state worker
        client.app.state.readiness.shutdown()

    assert health_elapsed < 0.5, (
        f"/health took {health_elapsed:.2f}s — it must answer from the cache, "
        "never wait on the mirror")
    assert first == {"configured": True, "stale": False, "checked": False}
    assert later["stale"] is True
    assert later["error"] == "mirror state fetch timed out"

    assert layers_resp.status_code == 200
    assert layers_elapsed < 1.0, (
        f"/layers took {layers_elapsed:.2f}s with a stuck mirror-state fetch "
        "in flight — it must never share a thread pool with /health's poll")
    assert len(calls) == 1


def test_repeated_polls_against_a_stuck_fetch_start_one_read(tmp_path, monkeypatch):
    """Issue #536's single-flight half: the client polls `/health` every 2s
    regardless of whether the last read ever finished. With the TTL
    collapsed to 0, every poll wants a refresh; none may start a second read
    while the first is still out, and `/layers` stays fast throughout."""
    monkeypatch.setattr(app_module, "_MIRROR_STATE_FETCH_TIMEOUT_S", 0.1)
    monkeypatch.setattr(app_module, "_MIRROR_STATE_CACHE_TTL_S", 0.0)
    client, unblock, calls = _stuck_client(tmp_path, monkeypatch)
    try:
        for _ in range(5):
            start = time.monotonic()
            client.get("/health")
            assert time.monotonic() - start < 0.5

        start = time.monotonic()
        layers_resp = client.get("/layers")
        layers_elapsed = time.monotonic() - start
    finally:
        unblock.set()
        client.app.state.readiness.shutdown()

    assert len(calls) == 1, f"expected one read behind five polls, got {len(calls)}"
    assert layers_resp.status_code == 200
    assert layers_elapsed < 1.0
