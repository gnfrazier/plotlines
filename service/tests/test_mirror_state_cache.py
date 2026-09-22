"""Issue #367 (rescoped by #434): `MirrorStateCache` is what makes it safe
for `--mirror-state-url` to default on. `/health` is polled every 2s for the
life of the session (`SidecarManager`, `client/lib/data/sidecar_manager.dart:
652`); without a cache, that is a request to the mirror on the same 2s
cadence from process start, before any extent has been declared — the
posture #274's first acceptance box refuses for `/clip` (D41/D57). This
module covers the cache itself (unit-level, an injectable clock) and its
wiring into `/health` (one real fetch behind however many polls land inside
one TTL window).
"""

from __future__ import annotations

import time

from fastapi.testclient import TestClient

from plotlines_service.app import (
    MirrorStateCache,
    _MIRROR_STATE_CACHE_TTL_S,
    _mirror_capability,
)
from plotlines_service import app as app_module


# ─────────────────────────────────────────────────────────────────────────
# Unit-level: MirrorStateCache in isolation
# ─────────────────────────────────────────────────────────────────────────


def test_a_second_fetch_within_the_ttl_reuses_the_cached_result(monkeypatch):
    calls = []

    def fetch(source, pool):
        calls.append(source)
        return {"configured": True, "stale": False}

    monkeypatch.setattr(app_module, "_fetch_mirror_capability", fetch)

    cache = MirrorStateCache(clock=iter([0.0, 10.0]).__next__)
    first = cache.get_or_fetch("state.json", pool=None)
    second = cache.get_or_fetch("state.json", pool=None)

    assert first == {"configured": True, "stale": False}
    assert second == first
    assert calls == ["state.json"], "the second call inside the TTL must not re-fetch"


def test_a_fetch_past_the_ttl_refetches(monkeypatch):
    calls = []

    def fetch(source, pool):
        calls.append(source)
        return {"configured": True, "stale": False}

    monkeypatch.setattr(app_module, "_fetch_mirror_capability", fetch)

    times = iter([0.0, _MIRROR_STATE_CACHE_TTL_S + 1.0])
    cache = MirrorStateCache(clock=lambda: next(times))
    cache.get_or_fetch("state.json", pool=None)
    cache.get_or_fetch("state.json", pool=None)

    assert calls == ["state.json", "state.json"], (
        "a call past the TTL must refetch rather than serve the stale entry")


def test_a_fetch_failure_is_cached_too(monkeypatch):
    """Issue #434's whole reason for filing the cache half of #367: an
    unreachable mirror must not be re-dialled every 2s poll any more than a
    reachable one is re-read every poll."""
    calls = []

    def fetch(source, pool):
        calls.append(source)
        return {"configured": True, "stale": True, "error": "mirror state fetch timed out"}

    monkeypatch.setattr(app_module, "_fetch_mirror_capability", fetch)

    cache = MirrorStateCache(clock=lambda: 0.0)
    first = cache.get_or_fetch("http://mirror.invalid/MIRROR_STATE.json", pool=None)
    second = cache.get_or_fetch("http://mirror.invalid/MIRROR_STATE.json", pool=None)

    assert first == second
    assert calls == ["http://mirror.invalid/MIRROR_STATE.json"], (
        "a cached failure must not be re-fetched inside the TTL either")


def test_different_sources_are_cached_independently(monkeypatch):
    monkeypatch.setattr(
        app_module, "_fetch_mirror_capability",
        lambda source, pool: {"configured": True, "stale": False, "source": source})

    cache = MirrorStateCache(clock=lambda: 0.0)
    a = cache.get_or_fetch("a.json", pool=None)
    b = cache.get_or_fetch("b.json", pool=None)

    assert a["source"] == "a.json"
    assert b["source"] == "b.json"


def test_no_cache_given_fetches_every_time(monkeypatch):
    """`_mirror_capability`'s pre-#367 uncached behaviour, preserved for any
    caller that does not pass a `cache` (there are none left in `app.py`
    itself, but the parameter defaults to `None` on purpose — see its
    docstring)."""
    calls = []
    monkeypatch.setattr(
        app_module, "_fetch_mirror_capability",
        lambda source, pool: calls.append(source) or {"configured": True, "stale": False})

    _mirror_capability("state.json", pool=None)
    _mirror_capability("state.json", pool=None)

    assert calls == ["state.json", "state.json"]


def test_an_unconfigured_source_never_reaches_the_cache():
    cache = MirrorStateCache(clock=lambda: 0.0)
    assert _mirror_capability(None, pool=None, cache=cache) == {"configured": False}
    assert cache._entries == {}


# ─────────────────────────────────────────────────────────────────────────
# Integration: repeated /health polls inside one TTL window share one fetch
# ─────────────────────────────────────────────────────────────────────────


def test_repeated_health_polls_inside_the_ttl_fetch_the_mirror_once(tmp_path, monkeypatch):
    calls = []

    def fetch(source):
        calls.append(source)
        return {"schema_version": 1, "basemap": {}, "geofabrik": {}}

    monkeypatch.setattr(app_module, "load_mirror_state", fetch)

    client = TestClient(app_module.create_app(
        tmp_path, mirror_state_url="http://mirror.invalid/MIRROR_STATE.json"))
    try:
        for _ in range(5):
            resp = client.get("/health")
            assert resp.json()["capabilities"]["mirror"]["configured"] is True
    finally:
        client.app.state.readiness.shutdown()

    assert len(calls) == 1, (
        f"expected one fetch behind five polls inside the TTL, got {len(calls)} "
        "— a poll must answer from MirrorStateCache, not re-dial the mirror")


def test_a_health_poll_past_the_ttl_refetches(tmp_path, monkeypatch):
    calls = []

    def fetch(source):
        calls.append(source)
        return {"schema_version": 1, "basemap": {}, "geofabrik": {}}

    monkeypatch.setattr(app_module, "load_mirror_state", fetch)
    monkeypatch.setattr(app_module, "_MIRROR_STATE_CACHE_TTL_S", 0.05)

    client = TestClient(app_module.create_app(
        tmp_path, mirror_state_url="http://mirror.invalid/MIRROR_STATE.json"))
    try:
        client.get("/health")
        time.sleep(0.1)
        client.get("/health")
    finally:
        client.app.state.readiness.shutdown()

    assert len(calls) == 2, (
        "a poll landing after the TTL must refetch rather than serve the "
        "expired entry")
