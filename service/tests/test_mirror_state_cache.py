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
    MIRROR_NOT_CHECKED_YET,
    MirrorStateCache,
    _MIRROR_STATE_CACHE_TTL_S,
    _mirror_capability,
)
from plotlines_service import app as app_module


# ─────────────────────────────────────────────────────────────────────────
# Unit-level: MirrorStateCache in isolation
# ─────────────────────────────────────────────────────────────────────────


class _InlinePool:
    """Runs a submitted read at once, so a unit test sees its result land
    before the next `get_or_fetch` without threads or sleeps."""

    def submit(self, fn, *args):
        fn(*args)


class _HeldPool:
    """Records a submitted read without running it: a read still in flight."""

    def __init__(self) -> None:
        self.submitted: list = []

    def submit(self, fn, *args):
        self.submitted.append((fn, args))


def _counting_read(monkeypatch, result=None):
    calls: list[str] = []

    def read(source):
        calls.append(source)
        return dict(result or {"configured": True, "stale": False, "source": source})

    monkeypatch.setattr(app_module, "_read_mirror_capability", read)
    return calls


def test_the_first_call_answers_not_checked_yet_without_waiting(monkeypatch):
    """Issue #536: `/health` never waits on the mirror, even the first time."""
    _counting_read(monkeypatch)
    cache = MirrorStateCache(clock=lambda: 0.0)
    pool = _HeldPool()

    assert cache.get_or_fetch("state.json", pool) == MIRROR_NOT_CHECKED_YET
    assert len(pool.submitted) == 1


def test_a_second_call_within_the_ttl_reuses_the_cached_result(monkeypatch):
    calls = _counting_read(monkeypatch)
    cache = MirrorStateCache(clock=lambda: 0.0)

    cache.get_or_fetch("state.json", _InlinePool())
    second = cache.get_or_fetch("state.json", _InlinePool())
    third = cache.get_or_fetch("state.json", _InlinePool())

    assert second == {"configured": True, "stale": False, "source": "state.json"}
    assert third == second
    assert calls == ["state.json"], "a call inside the TTL must not re-read"


def test_past_the_ttl_the_stale_entry_is_served_while_one_refresh_runs(monkeypatch):
    """Issue #536: the TTL decides when to refresh, not when to block."""
    calls = _counting_read(monkeypatch)
    now = {"t": 0.0}
    cache = MirrorStateCache(clock=lambda: now["t"])
    cache.get_or_fetch("state.json", _InlinePool())

    now["t"] = _MIRROR_STATE_CACHE_TTL_S + 1.0
    held = _HeldPool()
    first = cache.get_or_fetch("state.json", held)
    second = cache.get_or_fetch("state.json", held)

    assert first == {"configured": True, "stale": False, "source": "state.json"}
    assert second == first
    assert len(held.submitted) == 1, "one refresh per source, however many polls"
    assert calls == ["state.json"]


def test_a_read_in_flight_past_the_fetch_timeout_reports_timed_out(monkeypatch):
    _counting_read(monkeypatch)
    now = {"t": 0.0}
    cache = MirrorStateCache(clock=lambda: now["t"])
    held = _HeldPool()
    cache.get_or_fetch("state.json", held)

    now["t"] = app_module._MIRROR_STATE_FETCH_TIMEOUT_S + 0.1
    result = cache.get_or_fetch("state.json", held)

    assert result == {"configured": True, "stale": True,
                      "error": "mirror state fetch timed out"}
    assert len(held.submitted) == 1, "a stuck read is not doubled up behind"

    fn, args = held.submitted[0]
    fn(*args)  # the stuck read finally lands
    assert cache.get_or_fetch("state.json", held)["stale"] is False


def test_a_fetch_failure_is_cached_too(monkeypatch):
    """Issue #434's whole reason for filing the cache half of #367: an
    unreachable mirror must not be re-dialled every 2s poll any more than a
    reachable one is re-read every poll."""
    failure = {"configured": True, "stale": True, "error": "unreachable"}
    calls = _counting_read(monkeypatch, failure)
    cache = MirrorStateCache(clock=lambda: 0.0)

    cache.get_or_fetch("http://mirror.invalid/MIRROR_STATE.json", _InlinePool())
    second = cache.get_or_fetch("http://mirror.invalid/MIRROR_STATE.json", _InlinePool())
    third = cache.get_or_fetch("http://mirror.invalid/MIRROR_STATE.json", _InlinePool())

    assert second == third == failure
    assert calls == ["http://mirror.invalid/MIRROR_STATE.json"]


def test_different_sources_are_cached_independently(monkeypatch):
    _counting_read(monkeypatch)
    cache = MirrorStateCache(clock=lambda: 0.0)
    cache.get_or_fetch("a.json", _InlinePool())
    cache.get_or_fetch("b.json", _InlinePool())

    assert cache.get_or_fetch("a.json", _InlinePool())["source"] == "a.json"
    assert cache.get_or_fetch("b.json", _InlinePool())["source"] == "b.json"


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
