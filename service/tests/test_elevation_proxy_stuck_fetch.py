"""A stuck OpenTopography fetch never holds a request — issues #495 and
#520.

#495 found `GET /dem` holding a lock across the whole fetch, whose socket
timeout does not cover a stalled DNS lookup (#488). It moved the fetch to a
pool behind a deadline. #520 goes further: `/dem` answers `202 fetching` at
once and the fill worker runs the fetch, so no request thread waits on it
at all. This drives an `opener.open` that never returns — worse than any
real DNS hang — and asserts `/dem` answers at once, `/health` and a cached
`/dem` for another bbox stay fast, and the stuck job is reported
`failed:timeout` rather than `fetching` forever.
"""

from __future__ import annotations

import io
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
    """Blocks on `unblock` rather than ever touching the network. Bounded at
    15 s so a broken test can't hang the suite; every test releases it."""

    def __init__(self, unblock: threading.Event) -> None:
        self._unblock = unblock

    def open(self, url, timeout=None):
        self._unblock.wait(timeout=15.0)
        raise RuntimeError("released by the test")


class _FastOpener:
    def open(self, url, timeout=None):
        return io.BytesIO(b"fake-dem-bytes")


def _app(tmp_path: Path, opener):
    key = OpenTopographyKey(token="test-token", tier=KeyTier.FREE_NON_ACADEMIC)
    ledger = CallLedger(tmp_path / "ledger.json", ceiling=50)
    client = OpenTopographyClient(key, ledger, opener=opener)
    return create_proxy_app(tmp_path, client=client)


def test_a_miss_answers_at_once_while_the_fetch_hangs(tmp_path):
    unblock = threading.Event()
    app = _app(tmp_path, _HungOpener(unblock))
    tc = TestClient(app)
    try:
        start = time.monotonic()
        resp = tc.get("/dem", params=_P1)
        elapsed = time.monotonic() - start
        assert resp.status_code == 202
        assert elapsed < 1.0, f"/dem waited {elapsed:.2f}s on a stuck fetch"

        start = time.monotonic()
        assert tc.get("/health").status_code == 200
        assert time.monotonic() - start < 1.0
    finally:
        unblock.set()
        app.state.fill_worker.shutdown(wait=True)


def test_a_cached_bbox_is_not_blocked_by_a_stuck_fetch_for_another(tmp_path):
    warm = _app(tmp_path, _FastOpener())
    warm_tc = TestClient(warm)
    fill_id = warm_tc.get("/dem", params=_P2).json()["fill"]["fill_id"]
    deadline = time.monotonic() + 5
    while warm_tc.get(f"/fill/{fill_id}").json()["state"] == "fetching":
        assert time.monotonic() < deadline
        time.sleep(0.02)
    warm.state.fill_worker.shutdown(wait=True)

    unblock = threading.Event()
    app = _app(tmp_path, _HungOpener(unblock))
    tc = TestClient(app)
    try:
        assert tc.get("/dem", params=_P1).status_code == 202
        time.sleep(0.05)
        start = time.monotonic()
        second = tc.get("/dem", params=_P2)
        assert second.status_code == 200
        assert time.monotonic() - start < 1.0
    finally:
        unblock.set()
        app.state.fill_worker.shutdown(wait=True)


def test_a_fetch_past_its_deadline_is_failed_timeout_not_fetching_forever(tmp_path, monkeypatch):
    monkeypatch.setattr(proxy_module, "_DEM_FETCH_TIMEOUT_S", 0.2)
    unblock = threading.Event()
    app = _app(tmp_path, _HungOpener(unblock))
    tc = TestClient(app)
    try:
        fill_id = tc.get("/dem", params=_P1).json()["fill"]["fill_id"]
        time.sleep(0.5)
        assert tc.get(f"/fill/{fill_id}").json()["state"] == "failed:timeout"
    finally:
        unblock.set()
        app.state.fill_worker.shutdown(wait=True)
