"""Regression for issue #493: `GET /geocode` held `_NOMINATIM_LOCK`
(`plotlines_core.osm_identity`) with a plain, unbounded `with` across the
*whole* `ox.geocode_to_gdf` call, running it directly on the shared FastAPI
thread pool `/health`/`/layers`/`/tiles` also answer on. `ox.geocode_to_gdf`
makes a live Nominatim call whose DNS lookup has no timeout of its own (no
synchronous transport's does — the same finding #488 made against the
mirror-state fetch, applying here identically): one stalled lookup held the
lock indefinitely, occupied a shared-pool thread for as long as it took, and
left every later `/geocode` blocked on `Lock.acquire()` with no bound of its
own.

`_geocode_via_nominatim` now dispatches the call to its own single-worker
pool (`Readiness._geocode_pool`, the #488 shape) and gives up after
`_GEOCODE_FETCH_TIMEOUT_S` regardless of whether the call itself ever
returns; `nominatim_rate_limit` bounds the wait to *acquire* its pacing lock
with `timeout=NOMINATIM_LOCK_TIMEOUT_S`, raising `NominatimBusy` (a 503,
never a bare hang) rather than waiting on an already-stuck holder forever.
This drives an `ox.geocode_to_gdf` that never returns at all — worse than
any real DNS hang — and asserts both deadlines hold and `/layers` stays
fast throughout.
"""

from __future__ import annotations

import threading
import time

import osmnx as ox
from fastapi.testclient import TestClient

from plotlines_service import app as app_module


def test_a_stuck_geocode_does_not_block_other_endpoints(tmp_path, monkeypatch):
    monkeypatch.setattr(app_module, "_GEOCODE_FETCH_TIMEOUT_S", 0.2)

    # Bounded at 15s purely so a broken test can't hang the whole suite —
    # the test always calls `unblock.set()` itself, well before that, once
    # it no longer needs the fetch to be stuck.
    unblock = threading.Event()

    def hung_geocode(query):
        unblock.wait(timeout=15.0)
        raise RuntimeError("should never be reached — test releases first")

    monkeypatch.setattr(ox, "geocode_to_gdf", hung_geocode)

    client = TestClient(app_module.create_app(tmp_path))

    geocode_result: dict = {}

    def call_geocode() -> None:
        start = time.monotonic()
        resp = client.get("/geocode", params={"q": "Asheville, NC"})
        geocode_result["elapsed"] = time.monotonic() - start
        geocode_result["status"] = resp.status_code
        geocode_result["body"] = resp.json()

    geocode_thread = threading.Thread(target=call_geocode)
    geocode_thread.start()
    # Let the stuck fetch actually claim its worker before racing /layers.
    time.sleep(0.05)

    try:
        start = time.monotonic()
        layers_resp = client.get("/layers")
        layers_elapsed = time.monotonic() - start
    finally:
        geocode_thread.join(timeout=5.0)
        unblock.set()  # release the now-orphaned geocode worker
        client.app.state.readiness.shutdown()

    assert not geocode_thread.is_alive(), "/geocode never returned"
    assert geocode_result["elapsed"] < 2.0, (
        "/geocode should give up on a stuck fetch, not wait on it")
    assert geocode_result["status"] == 503
    assert "didn't answer" in geocode_result["body"]["detail"]

    assert layers_resp.status_code == 200
    assert layers_elapsed < 1.0, (
        f"/layers took {layers_elapsed:.2f}s with a stuck geocode fetch in "
        "flight — it must never share a thread pool with /geocode")


def test_a_second_geocode_does_not_wait_forever_behind_a_stuck_one(
    tmp_path, monkeypatch,
):
    """A `/geocode` call arriving while another is still stuck inside its
    own (much longer) fetch deadline must give up waiting for the pacing
    lock on its own, shorter deadline — never block for as long as the
    stuck call's own ceiling, let alone forever."""
    monkeypatch.setattr(app_module, "NOMINATIM_LOCK_TIMEOUT_S", 0.2)
    monkeypatch.setattr(app_module, "_GEOCODE_FETCH_TIMEOUT_S", 15.0)

    unblock = threading.Event()

    def hung_geocode(query):
        unblock.wait(timeout=15.0)
        raise RuntimeError("should never be reached — test releases first")

    monkeypatch.setattr(ox, "geocode_to_gdf", hung_geocode)

    client = TestClient(app_module.create_app(tmp_path))

    first_started = threading.Event()

    def call_first() -> None:
        first_started.set()
        client.get("/geocode", params={"q": "first"})

    first_thread = threading.Thread(target=call_first)
    first_thread.start()
    first_started.wait(timeout=5.0)
    time.sleep(0.05)  # let the first call actually claim the pacing lock

    try:
        start = time.monotonic()
        second_resp = client.get("/geocode", params={"q": "second"})
        second_elapsed = time.monotonic() - start
    finally:
        unblock.set()
        first_thread.join(timeout=5.0)
        client.app.state.readiness.shutdown()

    assert second_resp.status_code == 503
    assert "another geocode" in second_resp.json()["detail"]
    assert second_elapsed < 2.0, (
        f"the second /geocode took {second_elapsed:.2f}s — it must give up "
        "waiting for the pacing lock on its own deadline, not the first "
        "call's much longer fetch deadline")
