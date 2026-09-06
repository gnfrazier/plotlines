"""Pi5 QA/UAT caching elevation proxy — companion to epic #264, not #148.

Exercises `plotlines_service.elevation_proxy.create_proxy_app` against a
stubbed OpenTopography opener — never touches the real network or a real
API key. See `service/plotlines_service/elevation_proxy.py`.
"""

from __future__ import annotations

import io
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
    touches the network."""

    def __init__(self, body: bytes = b"fake-dem-bytes") -> None:
        self.body = body
        self.calls = 0

    def open(self, url, timeout=None):
        self.calls += 1
        return io.BytesIO(self.body)


class _FailingOpener:
    def open(self, url, timeout=None):
        raise OSError("connection refused")


def _client(tmp_path: Path, *, ceiling: int | None = 50, opener=None) -> tuple[TestClient, _FakeOpener]:
    opener = opener or _FakeOpener()
    key = OpenTopographyKey(token="test-token", tier=KeyTier.FREE_NON_ACADEMIC)
    ledger = CallLedger(tmp_path / "ledger.json", ceiling=ceiling)
    client = OpenTopographyClient(key, ledger, opener=opener)
    app = create_proxy_app(tmp_path, client=client)
    return TestClient(app), opener


def test_repeated_bbox_is_served_from_cache_after_one_upstream_fetch(tmp_path: Path) -> None:
    tc, opener = _client(tmp_path)
    r1 = tc.get("/dem", params=_P1)
    assert r1.status_code == 200
    assert opener.calls == 1

    r2 = tc.get("/dem", params=_P1)
    assert r2.status_code == 200
    assert r2.content == r1.content
    assert opener.calls == 1  # second hit is a cache hit, no second fetch


def test_ceiling_spent_returns_503_but_a_cached_bbox_still_serves(tmp_path: Path) -> None:
    tc, opener = _client(tmp_path, ceiling=1)
    r1 = tc.get("/dem", params=_P1)
    assert r1.status_code == 200
    assert opener.calls == 1

    r2 = tc.get("/dem", params=_P2)  # distinct bbox, ceiling already spent
    assert r2.status_code == 503
    assert r2.json()["detail"]["error"] == "free_tier_exhausted"
    assert "Retry-After" in r2.headers
    assert opener.calls == 1  # refused before the wire — no second spend

    r3 = tc.get("/dem", params=_P1)  # already-cached bbox: ceiling doesn't matter
    assert r3.status_code == 200
    assert opener.calls == 1


def test_missing_query_param_is_422(tmp_path: Path) -> None:
    tc, _ = _client(tmp_path)
    resp = tc.get("/dem", params={"west": 10.0, "south": 46.0, "east": 14.0})
    assert resp.status_code == 422


def test_upstream_fetch_failure_is_502(tmp_path: Path) -> None:
    tc, _ = _client(tmp_path, opener=_FailingOpener())
    resp = tc.get("/dem", params=_P1)
    assert resp.status_code == 502
    assert resp.json()["detail"]["error"] == "upstream_fetch_failed"


def test_proxy_health_reports_remaining_calls(tmp_path: Path) -> None:
    tc, opener = _client(tmp_path, ceiling=5)
    body = tc.get("/health").json()
    assert body["ready"] is True
    assert body["remaining_calls_24h"] == 5

    tc.get("/dem", params=_P1)
    body2 = tc.get("/health").json()
    assert body2["remaining_calls_24h"] == 4
