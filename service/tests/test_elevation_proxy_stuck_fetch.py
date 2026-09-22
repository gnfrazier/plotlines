"""Regression for issue #495: `GET /dem` held its one module-level
`threading.Lock` across the *whole* OpenTopography fetch
(`client.fetch` -> `opener.open(url, timeout=120)`, whose timeout does not
cover a stalled DNS lookup — #488's finding, unchanged by which client makes
the call). A stalled resolver held the lock indefinitely: every later `/dem`
call, for *any* bbox, blocked on `Lock.acquire()` with no bound of its own,
and the ledger/authorize step was inside the same lock, so even an
already-cached bbox was stuck behind it.

`get_dem` now dispatches the fetch to its own single-worker pool
(`fetch_pool`, the #488 shape) and gives up after `_DEM_FETCH_TIMEOUT_S`
regardless of whether `client.fetch` ever returns, with `lock` released
before the dispatch — held only for the fast, network-free bookkeeping
(`cache.get` / `authorize` / `reserve`). This drives an `opener.open` that
never returns at all — worse than any real DNS hang — and asserts the
deadline holds, `/health` stays fast throughout, and a cache-hit `/dem` for a
*different* bbox is never made to wait on the stuck one.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

from fastapi.testclient import TestClient

from plotlines_core.elevation.keys import CallLedger, KeyTier, OpenTopographyClient, OpenTopographyKey
from plotlines_service import elevation_proxy as proxy_module
from plotlines_service.elevation_proxy import create_proxy_app

_P1 = {"west": 10.0, "south": 46.0, "east": 14.0, "north": 50.0}
_P2 = {"west": 20.0, "south": 46.0, "east": 24.0, "north": 50.0}


class _HungOpener:
    """Stands in for `urllib.request.OpenerDirector`: blocks on `unblock`
    rather than ever touching the network — a stand-in for a stalled DNS
    resolver, worse than anything a real timeout would produce. Bounded at
    15s purely so a broken test can't hang the whole suite — the test always
    calls `unblock.set()` itself, well before that."""

    def __init__(self, unblock: threading.Event) -> None:
        self._unblock = unblock

    def open(self, url, timeout=None):
        self._unblock.wait(timeout=15.0)
        raise RuntimeError("should never be reached — test releases first")


def _client(tmp_path: Path, opener) -> TestClient:
    key = OpenTopographyKey(token="test-token", tier=KeyTier.FREE_NON_ACADEMIC)
    ledger = CallLedger(tmp_path / "ledger.json", ceiling=50)
    client = OpenTopographyClient(key, ledger, opener=opener)
    return TestClient(create_proxy_app(tmp_path, client=client))


def test_a_stuck_fetch_gives_up_by_its_deadline_with_a_503(tmp_path, monkeypatch):
    monkeypatch.setattr(proxy_module, "_DEM_FETCH_TIMEOUT_S", 0.2)
    unblock = threading.Event()
    tc = _client(tmp_path, _HungOpener(unblock))

    try:
        start = time.monotonic()
        resp = tc.get("/dem", params=_P1)
        elapsed = time.monotonic() - start
    finally:
        unblock.set()

    assert elapsed < 2.0, f"/dem waited {elapsed:.2f}s on a stuck fetch"
    assert resp.status_code == 503
    assert resp.json()["detail"]["error"] == "upstream_fetch_timed_out"
    assert "Retry-After" in resp.headers


def test_health_answers_while_a_fetch_is_stuck(tmp_path, monkeypatch):
    monkeypatch.setattr(proxy_module, "_DEM_FETCH_TIMEOUT_S", 15.0)
    unblock = threading.Event()
    tc = _client(tmp_path, _HungOpener(unblock))

    dem_thread = threading.Thread(target=lambda: tc.get("/dem", params=_P1))
    dem_thread.start()
    time.sleep(0.05)  # let the stuck fetch actually claim the pool worker

    try:
        start = time.monotonic()
        health = tc.get("/health")
        elapsed = time.monotonic() - start
    finally:
        unblock.set()
        dem_thread.join(timeout=5.0)

    assert health.status_code == 200
    assert health.json()["ready"] is True
    assert elapsed < 1.0, (
        f"/health took {elapsed:.2f}s with a stuck /dem fetch in flight — "
        "it never takes `lock` at all")


def test_a_cache_hit_for_a_different_bbox_is_not_blocked_by_a_stuck_fetch(
    tmp_path, monkeypatch,
):
    monkeypatch.setattr(proxy_module, "_DEM_FETCH_TIMEOUT_S", 15.0)
    unblock = threading.Event()
    tc = _client(tmp_path, _HungOpener(unblock))

    # Warm P2's cache first, with a fetch that returns immediately.
    key = OpenTopographyKey(token="test-token", tier=KeyTier.FREE_NON_ACADEMIC)
    ledger = CallLedger(tmp_path / "warm-ledger.json", ceiling=50)

    import io

    class _FastOpener:
        def open(self, url, timeout=None):
            return io.BytesIO(b"fake-dem-bytes")

    warm_client = OpenTopographyClient(key, ledger, opener=_FastOpener())
    warm_tc = TestClient(create_proxy_app(tmp_path, client=warm_client))
    warm = warm_tc.get("/dem", params=_P2)
    assert warm.status_code == 200

    dem_thread = threading.Thread(target=lambda: tc.get("/dem", params=_P1))
    dem_thread.start()
    time.sleep(0.05)  # let the stuck P1 fetch actually claim the pool worker

    try:
        start = time.monotonic()
        # Same cache dir as `tc`'s proxy (`tmp_path`), so this is a genuine
        # cache hit against the file `warm_tc` just wrote — served by `tc`'s
        # own `lock`-guarded bookkeeping, never the stuck fetch pool.
        second = tc.get("/dem", params=_P2)
        elapsed = time.monotonic() - start
    finally:
        unblock.set()
        dem_thread.join(timeout=5.0)

    assert second.status_code == 200
    assert elapsed < 1.0, (
        f"/dem for a different, already-cached bbox took {elapsed:.2f}s "
        "with an unrelated bbox's fetch stuck — it must never wait on "
        "`lock` for longer than the fast bookkeeping")
