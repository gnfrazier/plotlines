"""Regression for issue #492: `RegionState.build` made up to four sequential
outbound calls (mirror-clip extract, graph, tiles, elevation), each bounded
only by a library-level socket timeout that does not cover a stalled
`getaddrinfo` DNS lookup (the same #488/#490 class of gap) and none wrapped
in a caller-side deadline. A hang in any of them — especially tiles or
elevation, which run *after* `graph_state.succeed(...)` — used to occupy
`Readiness._build_pool`'s one worker (`REGION_BUILD_CONCURRENCY = 1`)
indefinitely, so every later `POST /regions` for a different bbox queued
forever with no honest reason on `/health`.

`RegionState.build` now runs each phase through `_run_build_phase` on a
dedicated pool, one per phase *type* (`RegionBuildPhasePools`), and gives up
on it after a per-phase deadline regardless of whether the phase's own call
ever returns — the #488 shape applied to the build pool, with a pool per
phase type so a stuck phase of one type can never hold an unrelated phase
(this build's own next one, or a different region's) to *its* ceiling too.
A `pending` region that has sat queued behind another region's build for too
long is separately caught by the build-queue watchdog
(`Readiness._apply_build_queue_watchdog`), and a region whose graph is ready
but whose build worker is still past it (tiles/elevation in flight) is
marked `finishing` on `/health` rather than reading identical to a fully
finished build.
"""

from __future__ import annotations

import threading
import time

from plotlines_service import app as app_module
from plotlines_service.app import Readiness, RegionBuildPhasePools, RegionState


def _fast_graph(monkeypatch) -> None:
    """Settle the graph phase instantly with no network/disk I/O — these
    tests are about the *other* phases, or about the registry around them,
    never about `ensure_graph` itself."""
    monkeypatch.setattr(
        app_module.region_lib, "ensure_graph",
        lambda region, cache_dir: region.graph_path(cache_dir))
    monkeypatch.setattr(app_module, "load_graphml", lambda path: object())


def _wait_until(predicate, timeout: float = 5.0, interval: float = 0.02) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


# ── Phase 1: a hung tiles fetch never blocks the region's own build() call ──


def test_a_stuck_tiles_phase_degrades_to_tiles_error_instead_of_hanging(
    tmp_path, monkeypatch,
):
    monkeypatch.setattr(app_module, "_TILES_PHASE_TIMEOUT_S", 0.2)
    _fast_graph(monkeypatch)

    unblock = threading.Event()

    def hung_extract_bbox(source, bbox, out_path, **kwargs):
        unblock.wait(timeout=15.0)
        raise AssertionError("should have been abandoned, not run to completion")

    monkeypatch.setattr(app_module, "extract_bbox", hung_extract_bbox)

    region = RegionState("k", (-105.0, 40.0, -104.9, 40.1), "bike")
    pools = RegionBuildPhasePools.create()
    try:
        start = time.monotonic()
        region.build(tmp_path, tmp_path / "home.pmtiles", build_phase_pools=pools)
        elapsed = time.monotonic() - start
    finally:
        unblock.set()
        pools.shutdown()

    assert elapsed < 2.0, f"build() waited {elapsed:.2f}s on a stuck tiles phase"
    assert region.graph_state.ready, "the graph phase itself never touched tiles"
    assert region.tiles_error is not None
    assert "RegionBuildPhaseTimeout" in region.tiles_error


# ── Phase 1, end to end: region B is not left pending behind region A ──────


def test_a_stuck_tiles_phase_on_one_region_does_not_leave_a_second_region_pending(
    tmp_path, monkeypatch,
):
    """The issue's own acceptance bullet: "a blocked tiles phase on region A
    must not leave region B pending past the bound." Both regions run
    through the real `Readiness`/`ensure_region` path, on the real
    single-worker `_build_pool`."""
    monkeypatch.setattr(app_module, "_TILES_PHASE_TIMEOUT_S", 0.2)
    _fast_graph(monkeypatch)

    unblock = threading.Event()

    def hung_extract_bbox(source, bbox, out_path, **kwargs):
        unblock.wait(timeout=15.0)
        raise AssertionError("should have been abandoned, not run to completion")

    monkeypatch.setattr(app_module, "extract_bbox", hung_extract_bbox)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    bbox_a = (-105.0, 40.0, -104.9, 40.1)
    bbox_b = (-106.0, 41.0, -105.9, 41.1)

    try:
        key_a = state.ensure_region(bbox_a, "bike")
        key_b = state.ensure_region(bbox_b, "bike")

        settled_a = _wait_until(lambda: state.regions[key_a].graph_state.ready)
        settled_b = _wait_until(lambda: state.regions[key_b].graph_state.ready)
    finally:
        unblock.set()
        state.shutdown()

    assert key_a != key_b
    assert settled_a, "region A's own graph phase should have succeeded fast"
    assert settled_b, (
        "region B stayed pending behind region A's stuck tiles phase — the "
        "single build-pool worker was wedged")


# ── Phase 2 (graph): a hung ensure_graph degrades honestly, worker recovers ─


def test_a_stuck_graph_phase_fails_honestly_without_hanging_the_worker(
    tmp_path, monkeypatch,
):
    monkeypatch.setattr(app_module, "_GRAPH_PHASE_TIMEOUT_S", 0.2)

    unblock = threading.Event()

    def hung_ensure_graph(region, cache_dir):
        unblock.wait(timeout=15.0)
        raise AssertionError("should have been abandoned, not run to completion")

    monkeypatch.setattr(app_module.region_lib, "ensure_graph", hung_ensure_graph)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    bbox_a = (-105.0, 40.0, -104.9, 40.1)
    bbox_b = (-106.0, 41.0, -105.9, 41.1)

    try:
        key_a = state.ensure_region(bbox_a, "bike")
        key_b = state.ensure_region(bbox_b, "bike")

        settled_a = _wait_until(lambda: state.regions[key_a].graph_state.settled)
        # Region B's own graph phase is real too (same hung fake), but the
        # point is that it gets a *turn* at all within a bounded time rather
        # than sitting behind A forever.
        settled_b = _wait_until(lambda: state.regions[key_b].graph_state.settled)
    finally:
        unblock.set()
        state.shutdown()

    assert settled_a and settled_b
    assert state.regions[key_a].graph_state.status == "failed"
    assert "time" in state.regions[key_a].graph_state.detail.lower()


# ── Phase 4 (elevation): a hung fetch leaves sampler=None, never hangs ──────


def test_a_stuck_elevation_phase_leaves_sampler_none_instead_of_hanging(
    tmp_path, monkeypatch,
):
    monkeypatch.setattr(app_module, "_ELEVATION_PHASE_TIMEOUT_S", 0.2)
    _fast_graph(monkeypatch)

    unblock = threading.Event()

    def hung_qa_proxy_fetch(base_url, bbox, dest):
        unblock.wait(timeout=15.0)
        raise AssertionError("should have been abandoned, not run to completion")

    monkeypatch.setattr(app_module, "qa_proxy_fetch", hung_qa_proxy_fetch)

    region = RegionState("k", (-105.0, 40.0, -104.9, 40.1), "bike")
    pools = RegionBuildPhasePools.create()
    try:
        start = time.monotonic()
        region.build(tmp_path, tmp_path / "home.pmtiles",
                    elevation_upstream="http://elevation.invalid/dem",
                    build_phase_pools=pools)
        elapsed = time.monotonic() - start
    finally:
        unblock.set()
        pools.shutdown()

    assert elapsed < 2.0, f"build() waited {elapsed:.2f}s on a stuck elevation phase"
    assert region.graph_state.ready
    assert region.sampler is None


# ── Visibility: graph ready, worker still finishing tiles/elevation ────────


def test_finishing_flag_set_while_worker_is_past_graph_ready(tmp_path, monkeypatch):
    _fast_graph(monkeypatch)

    release = threading.Event()
    reached_tiles = threading.Event()

    def paused_extract_bbox(source, bbox, out_path, **kwargs):
        reached_tiles.set()
        release.wait(timeout=15.0)
        raise app_module.NoTilesInBbox("no coverage (test)")

    monkeypatch.setattr(app_module, "extract_bbox", paused_extract_bbox)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    bbox = (-105.0, 40.0, -104.9, 40.1)
    try:
        key = state.ensure_region(bbox, "bike")
        assert reached_tiles.wait(timeout=5.0), "tiles phase never started"
        assert _wait_until(lambda: state.regions[key].graph_state.ready)

        capability = state.regions[key].routing_capability()
        assert capability["ready"] is True
        assert capability.get("finishing") is True

        release.set()
        assert _wait_until(lambda: not state.regions[key].build_in_progress)
        capability = state.regions[key].routing_capability()
        assert capability == {"ready": True}
    finally:
        release.set()
        state.shutdown()


# ── The build-queue watchdog ────────────────────────────────────────────


def test_watchdog_reports_a_pending_region_stuck_behind_a_wedged_build(
    tmp_path, monkeypatch,
):
    """A build that itself never returns (worse than any phase timeout could
    produce — the scenario the phase deadlines above exist to prevent from
    recurring for a *new* reason) still leaves a queued region an honest,
    named reason rather than a silent `pending` forever."""
    monkeypatch.setattr(app_module, "BUILD_QUEUE_WATCHDOG_S", 0.2)

    release = threading.Event()

    def wedged_build(self, *args, **kwargs):
        release.wait(timeout=15.0)
        self.graph_state.succeed("graph ready")

    monkeypatch.setattr(app_module.RegionState, "build", wedged_build)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    bbox_a = (-105.0, 40.0, -104.9, 40.1)
    bbox_b = (-106.0, 41.0, -105.9, 41.1)

    try:
        key_a = state.ensure_region(bbox_a, "bike")
        key_b = state.ensure_region(bbox_b, "bike")

        def watchdog_fired() -> bool:
            state.routing_capabilities()  # runs the watchdog as a side effect
            return state.regions[key_b].graph_state.status == "failed"

        assert _wait_until(watchdog_fired, timeout=5.0)
        reason = state.regions[key_b].routing_capability()["reason"]
        # FR145 — no raw internal cache key in the Author-facing sentence;
        # the blocker is named in the server log instead (see the WARNING
        # this same watchdog pass emits).
        assert key_a not in reason
        assert "building" in reason.lower(), reason
        # Not a real failure — #247's cooldown must not apply to a region
        # that has simply never had its turn yet.
        assert state.regions[key_b].failed_at is None
        assert state.regions[key_b].requeue_cooldown_remaining(time.monotonic()) == 0.0
    finally:
        release.set()
        state.shutdown()


def test_watchdog_marked_region_still_builds_once_its_real_turn_comes(
    tmp_path, monkeypatch,
):
    """The queued submission the watchdog fired *about* is left in place —
    once the active build finally finishes, region B still gets built for
    real, exactly once (issue #492's generation guard against the requeue
    path double-submitting behind it)."""
    monkeypatch.setattr(app_module, "BUILD_QUEUE_WATCHDOG_S", 0.2)

    release = threading.Event()
    attempts_by_key: dict[str, int] = {}
    lock = threading.Lock()
    # Concurrency is pinned to one worker and submissions are FIFO, so the
    # *very first* `build()` call to run is guaranteed to be region A's —
    # blocking on call order rather than on `self`/`key` sidesteps the race
    # between the worker thread starting A's build and the main thread
    # finishing its own bookkeeping about which region is "A".
    first_call_done = [False]

    def counted_build(self, *args, **kwargs):
        with lock:
            attempts_by_key[self.key] = attempts_by_key.get(self.key, 0) + 1
            is_first_ever_call = not first_call_done[0]
            first_call_done[0] = True
        if is_first_ever_call:
            release.wait(timeout=15.0)
        self.graph_state.succeed("graph ready")

    monkeypatch.setattr(app_module.RegionState, "build", counted_build)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    bbox_a = (-105.0, 40.0, -104.9, 40.1)
    bbox_b = (-106.0, 41.0, -105.9, 41.1)

    try:
        key_a = state.ensure_region(bbox_a, "bike")
        key_b = state.ensure_region(bbox_b, "bike")

        def watchdog_fired() -> bool:
            state.routing_capabilities()
            return state.regions[key_b].graph_state.status == "failed"

        assert _wait_until(watchdog_fired, timeout=5.0)

        # The Author's manual "Try again" while B is still genuinely queued
        # behind A — this must not spawn a second, duplicate build.
        state.ensure_region(bbox_b, "bike", manual=True)

        release.set()
        assert _wait_until(lambda: state.regions[key_b].graph_state.ready, timeout=5.0)
    finally:
        release.set()
        state.shutdown()

    assert attempts_by_key.get(key_b) == 1, (
        f"region B built {attempts_by_key.get(key_b)} times; expected exactly 1 "
        "— the watchdog-triggered retry must supersede, not duplicate, the "
        "still-queued original submission")
