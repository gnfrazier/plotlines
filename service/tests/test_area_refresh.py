"""Stale-while-revalidate on trip open — epic #641 (ARCH D73), story #649.

A live trip whose held area is past its TTL opens at once from what is on
disk — routing `ready` with the mirror blocked forever — while one
background refresh per stale payload replaces it. A failed refresh is never
latched: the held data keeps serving and the next open tries again.
"""

from __future__ import annotations

import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import pytest

from plotlines_core import cache_areas
from plotlines_core.cache_layout import CacheLayout
from plotlines_core.graph import extract_fetch
from plotlines_service import app as app_mod
from plotlines_service.app import Readiness
from test_area_reuse import _TRIP_1, _TRIP_2, _write_clip
from tiles_helpers import build_archive

DAY = 86_400.0


def _pin(*, days_ago: int) -> str:
    """A Geofabrik pin relative to today (a fixed date would age past
    `MAX_PIN_AGE_DAYS` and stop being reusable)."""
    return (datetime.now(timezone.utc) - timedelta(days=days_ago)).strftime("%Y-%m-%d")


class Clock:
    def __init__(self) -> None:
        self.t = 1_800_000_000.0

    def __call__(self) -> float:
        return self.t


class Mirror:
    """`fetch_extract` and `extract_bbox` stand-ins. `mode` is "ok" (writes a
    clip under `pin`), "block" (waits until released), or "fail"."""

    def __init__(self) -> None:
        self.mode = "ok"
        self.pin = _pin(days_ago=3)
        self.clip_calls: list[tuple] = []
        self.tile_calls: list[tuple] = []
        self.extracts_made = 0
        self.release = threading.Event()

    def fetch(self, bbox, *, cache_dir, progress=None, **_kwargs):
        self.clip_calls.append(tuple(bbox))
        if self.mode == "block":
            self.release.wait(timeout=20)
            raise extract_fetch.MirrorUnreachable("released")
        if self.mode == "fail":
            raise extract_fetch.MirrorUnreachable("The Plotlines mirror didn't answer.")
        path = _write_clip(CacheLayout(cache_dir).osm_extract(tuple(bbox), self.pin), bbox)
        if progress is not None:
            progress.status = "ready"
            progress.bytes_downloaded = progress.total_bytes = path.stat().st_size
        return path

    def extract(self, upstream, box, out_path, *, allow_unmirrored=False, max_zoom=None,
                stats=None):
        self.tile_calls.append(tuple(box))
        self.extracts_made += 1
        out_path.parent.mkdir(parents=True, exist_ok=True)
        # A different length each time, so the archive's fingerprint moves.
        payload = b"t" * self.extracts_made
        build_archive(out_path, {(0, 0, 0): payload}, bounds=tuple(box))
        return out_path


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def mirror(monkeypatch):
    m = Mirror()
    monkeypatch.setattr(extract_fetch, "fetch_extract", m.fetch)
    monkeypatch.setattr(app_mod, "extract_bbox", m.extract)
    yield m
    m.release.set()


def _readiness(tmp_path, clock) -> Readiness:
    return Readiness(tmp_path, tmp_path / "upstream.pmtiles", allow_unmirrored=True,
                     mirror_clip_url="http://mirror.test",
                     area_index=cache_areas.AreaIndex(tmp_path, clock=clock))


def _open(state: Readiness, bbox) -> str:
    key = state.ensure_region(bbox, "bike")
    state._build_pool.shutdown(wait=True)
    state._build_pool = ThreadPoolExecutor(max_workers=1)
    return key


def _drain_refreshes(state: Readiness) -> None:
    """Wait until no refresh is in flight."""
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        with state._lock:
            if not state._refresh_inflight:
                return
        time.sleep(0.01)
    raise AssertionError("refreshes never settled")


def _wait_for(predicate) -> None:
    deadline = time.monotonic() + 10
    while not predicate():
        assert time.monotonic() < deadline, "timed out"
        time.sleep(0.01)


def _held_then_stale(tmp_path, clock, mirror) -> None:
    """A first session plans trip 1, then 46 days pass."""
    first = _readiness(tmp_path, clock)
    _open(first, _TRIP_1)
    first.shutdown()
    mirror.clip_calls.clear()
    mirror.tile_calls.clear()
    clock.t += 46 * DAY


def test_a_past_ttl_trip_opens_ready_with_the_mirror_blocked(tmp_path, clock, mirror):
    _held_then_stale(tmp_path, clock, mirror)
    mirror.mode = "block"
    state = _readiness(tmp_path, clock)
    key = _open(state, _TRIP_1)  # returns although the mirror never answers

    region = state.region(key)
    cap = region.routing_capability()
    assert cap["ready"] is True and cap["refreshing"] is True
    assert region.tiles_capability() == {"ready": True, "refreshing": True}
    # The only mirror request is the background refresh's.
    _wait_for(lambda: mirror.clip_calls)
    assert mirror.clip_calls == [cache_areas.pad_bbox(_TRIP_1)]
    mirror.release.set()
    state.shutdown()


def test_exactly_one_refresh_per_stale_payload(tmp_path, clock, mirror):
    _held_then_stale(tmp_path, clock, mirror)
    mirror.mode = "block"
    state = _readiness(tmp_path, clock)
    _open(state, _TRIP_1)
    _open(state, _TRIP_1)   # opened again
    _open(state, _TRIP_2)   # another trip in the same area
    _wait_for(lambda: mirror.clip_calls and mirror.tile_calls)
    time.sleep(0.1)
    assert len(mirror.clip_calls) == 1
    assert len(mirror.tile_calls) == 1
    mirror.release.set()
    state.shutdown()


def test_a_refresh_advances_the_pin_and_fingerprint_and_the_next_solve_uses_it(
        tmp_path, clock, mirror):
    _held_then_stale(tmp_path, clock, mirror)
    mirror.pin = _pin(days_ago=1)
    state = _readiness(tmp_path, clock)
    key = _open(state, _TRIP_1)
    region = state.region(key)
    old_graph = region.graph
    old_identity = region.tiles_archive.info().identity
    _drain_refreshes(state)
    _drain_refreshes(state)

    area = cache_areas.pad_bbox(_TRIP_1)
    graph_hit = state.areas.resolve(_TRIP_1, cache_areas.graph_payload("bike"))
    assert graph_hit.area_bbox == area and graph_hit.pin == _pin(days_ago=1)
    assert not graph_hit.stale and graph_hit.fetched_at == clock.t
    assert state.areas.resolve(_TRIP_1, cache_areas.PAYLOAD_EXTRACT).pin == _pin(days_ago=1)
    assert region.graph is not old_graph
    assert region.tiles_archive.info().identity != old_identity
    assert "refreshing" not in region.routing_capability()
    assert state.osm_source_pin(fetched_at="2026-10-07") == f"geofabrik:{_pin(days_ago=1)}"
    # The superseded pin's extract is gone, so its directory can be swept.
    old_pin_dir = CacheLayout(tmp_path).extracts_dir / _pin(days_ago=3)
    assert not any(old_pin_dir.iterdir())
    state.shutdown()


def test_a_failed_refresh_leaves_everything_serving_and_the_next_open_retries(
        tmp_path, clock, mirror, monkeypatch):
    _held_then_stale(tmp_path, clock, mirror)
    mirror.mode = "fail"
    state = _readiness(tmp_path, clock)
    key = _open(state, _TRIP_1)
    _drain_refreshes(state)
    region = state.region(key)
    assert region.routing_capability() == {"ready": True}
    assert region.tiles_capability()["ready"] is True
    assert len(mirror.clip_calls) == 1

    # Inside the cooldown, a reopen does not hammer the mirror…
    _open(state, _TRIP_1)
    _drain_refreshes(state)
    assert len(mirror.clip_calls) == 1
    # …and after it, the next open tries again (never latched).
    monkeypatch.setattr(app_mod, "REFRESH_RETRY_COOLDOWN_S", 0.0)
    mirror.mode = "ok"
    _open(state, _TRIP_1)
    _drain_refreshes(state)
    assert len(mirror.clip_calls) == 2
    assert not state.areas.resolve(_TRIP_1, cache_areas.graph_payload("bike")).stale
    state.shutdown()


def test_offline_a_past_ttl_trip_opens_from_held_data_with_no_failure(
        tmp_path, clock, mirror):
    _held_then_stale(tmp_path, clock, mirror)
    mirror.mode = "fail"
    state = _readiness(tmp_path, clock)
    key = _open(state, _TRIP_1)
    _drain_refreshes(state)
    region = state.region(key)
    assert region.routing_capability() == {"ready": True}
    assert region.extract_capability()["ready"] is True
    assert region.tiles_capability() == {"ready": True}
    state.shutdown()
