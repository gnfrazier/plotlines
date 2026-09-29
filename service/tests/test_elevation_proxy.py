"""Pi5 QA/UAT caching elevation proxy on the fill contract — issue #520
(epic #516, ARCH D67); first built for epic #264.

Exercises `plotlines_service.elevation_proxy.create_proxy_app` against a
stubbed OpenTopography opener — never touches the real network or a real
API key. A miss is `202 fetching` and a poll, never a blocking fetch; a
spent allowance is a wait with `retry_after_s`, never flat terrain.
"""

from __future__ import annotations

import io
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from fastapi.testclient import TestClient

from plotlines_core.elevation.keys import (
    CallLedger,
    KeyTier,
    OpenTopographyClient,
    OpenTopographyKey,
)
from plotlines_service.elevation_proxy import create_proxy_app

_P1 = {"west": 10.0, "south": 46.0, "east": 14.0, "north": 50.0}
_P2 = {"west": 20.0, "south": 46.0, "east": 24.0, "north": 50.0}


class _FakeOpener:
    """Stands in for `urllib.request.OpenerDirector` — counts calls, never
    touches the network. `gate`, when given, holds each call open."""

    def __init__(self, body: bytes = b"fake-dem-bytes", gate: threading.Event | None = None):
        self.body = body
        self.calls = 0
        self.gate = gate
        self._lock = threading.Lock()

    def open(self, url, timeout=None):
        with self._lock:
            self.calls += 1
        if self.gate is not None:
            assert self.gate.wait(10)
        return io.BytesIO(self.body)


class _FailingOpener:
    calls = 0

    def open(self, url, timeout=None):
        raise OSError("connection refused")


def _client(tmp_path: Path, *, ceiling: int | None = 50, opener=None, client_key=None):
    opener = opener or _FakeOpener()
    key = OpenTopographyKey(token="test-token", tier=KeyTier.FREE_NON_ACADEMIC)
    ledger = CallLedger(tmp_path / "ledger.json", ceiling=ceiling)
    client = OpenTopographyClient(key, ledger, opener=opener)
    app = create_proxy_app(tmp_path, client=client, client_key=client_key)
    return TestClient(app), opener, app


def _settle(tc: TestClient, fill_id: str, *, headers=None, timeout: float = 10.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        body = tc.get(f"/fill/{fill_id}", headers=headers or {}).json()
        if body["state"] != "fetching":
            return body
        time.sleep(0.02)
    raise AssertionError(f"fill {fill_id} still fetching")


def test_an_unwarmed_area_is_fetching_then_ready_then_a_cache_hit(tmp_path: Path) -> None:
    tc, opener, app = _client(tmp_path)
    try:
        r1 = tc.get("/dem", params=_P1)
        assert r1.status_code == 202
        assert r1.json()["state"] == "fetching"
        assert int(r1.headers["retry-after"]) >= 1
        assert _settle(tc, r1.json()["fill"]["fill_id"])["state"] == "ready"

        r2 = tc.get("/dem", params=_P1)
        assert r2.status_code == 200
        assert r2.content == b"fake-dem-bytes"
        r3 = tc.get("/dem", params=_P1)
        assert r3.status_code == 200
        assert opener.calls == 1  # every later request is a cache hit
    finally:
        app.state.fill_worker.shutdown()


def test_concurrent_misses_for_one_bbox_spend_one_call(tmp_path: Path) -> None:
    gate = threading.Event()
    tc, opener, app = _client(tmp_path, opener=_FakeOpener(gate=gate))
    try:
        with ThreadPoolExecutor(8) as pool:
            responses = list(pool.map(lambda _: tc.get("/dem", params=_P1), range(8)))
        assert {r.status_code for r in responses} == {202}
        assert len({r.json()["fill"]["fill_id"] for r in responses}) == 1
        gate.set()
        _settle(tc, responses[0].json()["fill"]["fill_id"])
        assert opener.calls == 1
    finally:
        gate.set()
        app.state.fill_worker.shutdown()


def test_a_spent_allowance_is_a_wait_until_the_reset_and_spends_nothing(tmp_path: Path) -> None:
    tc, opener, app = _client(tmp_path, ceiling=1)
    try:
        r1 = tc.get("/dem", params=_P1)
        _settle(tc, r1.json()["fill"]["fill_id"])
        assert opener.calls == 1

        r2 = tc.get("/dem", params=_P2)  # distinct bbox, allowance spent
        assert r2.status_code == 202
        fill = r2.json()["fill"]
        assert fill["state"] == "fetching"
        # The ledger frees its one call ~24 h after it was spent.
        assert 23 * 3600 < fill["retry_after_s"] <= 24 * 3600
        assert "allowance" in fill["detail"]
        time.sleep(0.1)
        again = tc.get(f"/fill/{fill['fill_id']}").json()
        assert again["state"] == "fetching"  # a wait, not failed, not flat
        assert opener.calls == 1  # refused before the wire — nothing spent

        assert tc.get("/dem", params=_P1).status_code == 200  # cached serves
    finally:
        app.state.fill_worker.shutdown()


def test_missing_query_param_is_422(tmp_path: Path) -> None:
    tc, _, app = _client(tmp_path)
    try:
        resp = tc.get("/dem", params={"west": 10.0, "south": 46.0, "east": 14.0})
        assert resp.status_code == 422
    finally:
        app.state.fill_worker.shutdown()


def test_an_upstream_failure_is_a_failed_fill_then_a_503_never_a_raster(tmp_path: Path) -> None:
    tc, _, app = _client(tmp_path, opener=_FailingOpener())
    try:
        first = tc.get("/dem", params=_P1)
        assert first.status_code == 202
        settled = _settle(tc, first.json()["fill"]["fill_id"])
        assert settled["state"] == "failed:upstream_fetch_failed"
        again = tc.get("/dem", params=_P1)
        assert again.status_code == 503
        assert again.json()["detail"]["error"] == "upstream_fetch_failed"
        assert int(again.headers["retry-after"]) > 0
        assert not list(tmp_path.rglob("*.tif"))
    finally:
        app.state.fill_worker.shutdown()


def test_proxy_health_reports_remaining_calls(tmp_path: Path) -> None:
    tc, _, app = _client(tmp_path, ceiling=5)
    try:
        body = tc.get("/health").json()
        assert body["ready"] is True
        assert body["remaining_calls_24h"] == 5
        _settle(tc, tc.get("/dem", params=_P1).json()["fill"]["fill_id"])
        assert tc.get("/health").json()["remaining_calls_24h"] == 4
    finally:
        app.state.fill_worker.shutdown()


def test_with_a_client_key_a_miss_needs_it_but_a_cached_dem_does_not(tmp_path: Path) -> None:
    tc, opener, app = _client(tmp_path, client_key="k")
    try:
        assert tc.get("/dem", params=_P1).status_code == 401
        assert opener.calls == 0
        r = tc.get("/dem", params=_P1, headers={"X-Plotlines-Client-Key": "k"})
        _settle(tc, r.json()["fill"]["fill_id"], headers={"X-Plotlines-Client-Key": "k"})
        assert tc.get("/dem", params=_P1).status_code == 200  # a hit is open
        assert tc.post("/fill", json={"layer": "elevation", **_P2}).status_code == 401
    finally:
        app.state.fill_worker.shutdown()


def test_post_fill_is_the_same_contract(tmp_path: Path) -> None:
    tc, opener, app = _client(tmp_path)
    try:
        resp = tc.post("/fill", json={"layer": "elevation", **_P1})
        assert resp.status_code == 202
        _settle(tc, resp.json()["fill_id"])
        again = tc.post("/fill", json={"layer": "elevation", **_P1})
        assert again.status_code == 200 and again.json()["state"] == "ready"
        assert opener.calls == 1
    finally:
        app.state.fill_worker.shutdown()


def test_a_restart_mid_fetch_leaves_no_partial_dem_and_no_stuck_job(tmp_path: Path) -> None:
    gate = threading.Event()
    tc, _, app = _client(tmp_path, opener=_FakeOpener(gate=gate))
    fill_id = tc.get("/dem", params=_P1).json()["fill"]["fill_id"]
    time.sleep(0.1)
    elevation_dir = next(p for p in tmp_path.rglob("*") if p.is_dir() and p.name == "elevation")
    (elevation_dir / "tmpabc.part").write_bytes(b"half")  # what a killed fetch leaves

    tc2, _, app2 = _client(tmp_path)
    try:
        assert not list(elevation_dir.glob("*.part"))
        assert not list(elevation_dir.glob(".fill-*"))
        assert tc2.get(f"/fill/{fill_id}").json()["state"] == "failed:restarted"
    finally:
        gate.set()
        app.state.fill_worker.shutdown(wait=True)
        app2.state.fill_worker.shutdown()


# -- the pre-warm script against the real proxy, over a real socket ------------------


def _serve(app):
    import socket

    import uvicorn

    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 10
    while not server.started:
        assert time.monotonic() < deadline
        time.sleep(0.02)
    return server, thread, f"http://127.0.0.1:{port}"


def test_the_prewarm_script_follows_a_fill_to_the_raster(tmp_path: Path) -> None:
    """#520: `deploy/elevation/prewarm_cache.py` used to get the raster from
    one blocking `/dem`. It now gets `202`, polls `/fill/{id}` and reads the
    raster once the fill lands — and a spent allowance still reads as the
    ceiling (`EXHAUSTED`), not a hang."""
    from test_prewarm_cache import pc

    _, opener, app = _client(tmp_path, ceiling=1)
    server, thread, root = _serve(app)
    try:
        ok = pc.prewarm_one_detailed(f"{root}/dem", tuple(_P1.values()), timeout=20,
                                     sleep=lambda s: time.sleep(min(s, 0.05)))
        assert ok.outcome is pc.PrewarmOutcome.OK
        assert ok.bytes_len == len(b"fake-dem-bytes")
        spent = pc.prewarm_one_detailed(f"{root}/dem", tuple(_P2.values()), timeout=20,
                                        sleep=lambda s: time.sleep(min(s, 0.05)))
        assert spent.outcome is pc.PrewarmOutcome.EXHAUSTED
        assert spent.retry_after_s and spent.retry_after_s > 3600
        assert opener.calls == 1
    finally:
        server.should_exit = True
        thread.join(5)
        app.state.fill_worker.shutdown()
