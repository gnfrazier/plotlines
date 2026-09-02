"""B1 — region graph builds are serialised (`REGION_BUILD_CONCURRENCY`).

Regression for the Buncombe County incident: `Readiness.ensure_region` used to
spawn an unbounded daemon thread per distinct `(bbox, network_type)` key, so a
client that ensured several regions at once (a trip declaring bike + hike +
drive — a distinct `network_type` graph each) ran every county-scale OSMnx
build in parallel. That pegged every core, starved the trivial `/health`
handler of the GIL, and drove M12 to restart the sidecar mid-build — whose
restart re-issued the same fan-out.
"""

from __future__ import annotations

import threading
import time

from plotlines_service.app import REGION_BUILD_CONCURRENCY, Readiness


def test_concurrent_ensure_region_calls_do_not_build_in_parallel(tmp_path, monkeypatch):
    assert REGION_BUILD_CONCURRENCY == 1, "this test pins the serialised default"

    active = 0
    peak = 0
    lock = threading.Lock()

    def fake_build(self, cache_dir, tiles_upstream, allow_unmirrored=False):
        nonlocal active, peak
        with lock:
            active += 1
            peak = max(peak, active)
        try:
            time.sleep(0.15)
        finally:
            with lock:
                active -= 1
        self.graph_state.succeed("graph ready")

    monkeypatch.setattr("plotlines_service.app.RegionState.build", fake_build)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    # Five *distinct* bboxes -> five distinct keys -> a build apiece, all
    # submitted back-to-back the way the client's per-mode / per-revision
    # calls arrive.
    for i in range(5):
        state.ensure_region((-105.0 - i * 0.01, 40.0, -104.9 - i * 0.01, 40.1), "bike")

    # Join: shutdown(wait=True) blocks until every queued build has run.
    state._build_pool.shutdown(wait=True)

    assert peak == 1, f"region builds ran {peak}-wide; expected serialised"
    assert len(state.regions) == 5
    assert all(r.routing_ready for r in state.regions.values())


def test_same_key_ensured_twice_still_builds_once(tmp_path, monkeypatch):
    builds = 0
    lock = threading.Lock()

    def fake_build(self, cache_dir, tiles_upstream, allow_unmirrored=False):
        nonlocal builds
        with lock:
            builds += 1
        self.graph_state.succeed("graph ready")

    monkeypatch.setattr("plotlines_service.app.RegionState.build", fake_build)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    bbox = (-105.0, 40.0, -104.9, 40.1)
    k1 = state.ensure_region(bbox, "bike")
    k2 = state.ensure_region(bbox, "bike")
    state._build_pool.shutdown(wait=True)

    assert k1 == k2
    assert builds == 1


def test_ensure_region_requeues_a_settled_failed_region(tmp_path, monkeypatch):
    """issue #229 — a `POST /regions` for a bbox whose build has settled
    `failed` (Overpass unreachable) resets the capability and re-queues the
    build, so the client's "Try again" is a real retry, not a no-op."""
    attempts = 0
    lock = threading.Lock()

    def fake_build(self, cache_dir, tiles_upstream, allow_unmirrored=False):
        nonlocal attempts
        with lock:
            attempts += 1
            n = attempts
        if n == 1:
            self.graph_state.fail("Couldn't reach the map-data service ...")
        else:
            self.graph_state.succeed("graph ready")

    monkeypatch.setattr("plotlines_service.app.RegionState.build", fake_build)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    bbox = (-105.0, 40.0, -104.9, 40.1)

    k1 = state.ensure_region(bbox, "bike")
    state._build_pool.shutdown(wait=True)
    assert state.regions[k1].graph_state.status == "failed"

    # A fresh pool for the retry submission (the first shutdown closed it).
    from concurrent.futures import ThreadPoolExecutor
    state._build_pool = ThreadPoolExecutor(max_workers=1)
    k2 = state.ensure_region(bbox, "bike")
    state._build_pool.shutdown(wait=True)

    assert k1 == k2
    assert attempts == 2
    assert state.regions[k1].routing_ready
