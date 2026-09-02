"""Regressions for the concurrency findings in the #235 review.

Two failures that share a shape: a bounded, carefully-reasoned mechanism sitting
next to an unbounded one that can undo it.

`GET /health` walking the region registry without the lock (A1) is the sharper
of the two — it is the endpoint M12's `sidecar_manager` polls and restarts the
sidecar over, so a `RuntimeError` there re-opens the Buncombe restart loop that
#224 and #232 closed from the build side.
"""

from __future__ import annotations

import threading
import time

import pytest

from plotlines_service.app import (
    DIAGNOSE_JOB_CAP, DiagnoseJob, DiagnoseRegistry, Readiness, RegionState,
)


def _instant_build(monkeypatch) -> None:
    """Settle a region build immediately — these tests are about the registry
    around `build`, never about `build` itself."""
    monkeypatch.setattr(
        "plotlines_service.app.RegionState.build",
        lambda self, *a, **k: self.graph_state.succeed("graph ready"),
    )


# ── A1 — the region registry is walked under the lock ────────────────────


def test_reading_capabilities_while_regions_are_ensured_never_raises(tmp_path, monkeypatch):
    """The repro from the review: an unlocked `.items()` walk raced a
    concurrent `POST /regions` and raised `RuntimeError: dictionary changed
    size during iteration`."""
    _instant_build(monkeypatch)
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")

    errors: list[BaseException] = []
    stop = threading.Event()

    def writer() -> None:
        i = 0
        while not stop.is_set():
            state.ensure_region((-105.0 - i * 1e-4, 40.0, -104.9 - i * 1e-4, 40.1), "bike")
            i += 1

    def reader() -> None:
        while not stop.is_set():
            try:
                state.routing_capabilities()
                state.snapshot()
            except BaseException as exc:  # noqa: BLE001 — the assertion is "nothing at all"
                errors.append(exc)
                return

    threads = [threading.Thread(target=writer, daemon=True),
               threading.Thread(target=reader, daemon=True)]
    for t in threads:
        t.start()
    time.sleep(1.5)
    stop.set()
    for t in threads:
        t.join(timeout=5.0)

    state._build_pool.shutdown(wait=False, cancel_futures=True)
    assert errors == [], f"reading the registry raced a build: {errors[0]!r}"
    assert len(state.regions) > 1, "the writer never got going — test proves nothing"


def test_snapshot_is_a_copy_so_a_later_insert_cannot_disturb_a_walk(tmp_path, monkeypatch):
    """The point of returning a list rather than the live view: a caller may
    take its time over the result."""
    _instant_build(monkeypatch)
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    state.ensure_region((-105.0, 40.0, -104.9, 40.1), "bike")

    walk = state.snapshot()
    state.ensure_region((-82.8, 35.3, -82.1, 35.7), "bike")

    assert len(walk) == 1
    assert len(state.snapshot()) == 2
    state._build_pool.shutdown(wait=False, cancel_futures=True)


def test_region_lookup_still_finds_what_ensure_region_registered(tmp_path, monkeypatch):
    """`region()` took the lock too — check that didn't break the lookup, and
    that it isn't re-entering a lock `ensure_region` already holds."""
    _instant_build(monkeypatch)
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    key = state.ensure_region((-105.0, 40.0, -104.9, 40.1), "bike")

    assert state.region(key) is not None
    assert state.region("nope") is None
    state._build_pool.shutdown(wait=False, cancel_futures=True)


# ── A2 — the diagnose registry is bounded ────────────────────────────────


def test_finished_jobs_past_the_ttl_are_evicted_on_the_next_submit():
    registry = DiagnoseRegistry(ttl_s=10.0, cap=100)
    first = registry.submit(lambda job: None, now=0.0)

    # Let the pool actually finish it — eviction only ever drops *done* jobs
    # by age.
    deadline = time.perf_counter() + 5.0
    while not registry.get(first).done:
        if time.perf_counter() > deadline:
            pytest.fail("the submitted job never ran")
        time.sleep(0.005)

    registry.submit(lambda job: None, now=11.0)

    assert registry.get(first) is None, "a collected result outlived its TTL"
    assert len(registry) == 1
    registry.shutdown()


def test_an_uncollected_result_inside_the_ttl_is_still_there():
    """The TTL is the client's window to poll — it must not be so eager that a
    slow poll loses a result it was entitled to."""
    registry = DiagnoseRegistry(ttl_s=300.0, cap=100)
    job_id = registry.submit(lambda job: None, now=0.0)
    registry.submit(lambda job: None, now=60.0)

    assert registry.get(job_id) is not None
    registry.shutdown()


def test_the_cap_bounds_the_registry_even_when_nothing_is_old_enough_to_expire():
    """A client that never polls cannot pin memory: past the cap the oldest go
    regardless of age."""
    registry = DiagnoseRegistry(ttl_s=1e9, cap=5)
    ids = [registry.submit(lambda job: None, now=float(i)) for i in range(12)]

    assert len(registry) == 5
    assert all(registry.get(i) is None for i in ids[:7]), "the oldest should have gone first"
    assert registry.get(ids[-1]) is not None, "the newest submission must survive"
    registry.shutdown()


def test_the_default_cap_is_what_bounds_a_retry_loop():
    registry = DiagnoseRegistry(ttl_s=1e9)
    for i in range(DIAGNOSE_JOB_CAP + 40):
        registry.submit(lambda job: None, now=float(i))

    assert len(registry) == DIAGNOSE_JOB_CAP
    registry.shutdown()


def test_diagnoses_do_not_all_run_at_once():
    """SPIKE-02 measured diagnose at 1.3-15.0s of CPU. Unbounded threads let a
    retry loop saturate every core and starve `/health` — the same failure
    `REGION_BUILD_CONCURRENCY` exists to prevent, one endpoint over."""
    registry = DiagnoseRegistry()
    active = 0
    peak = 0
    lock = threading.Lock()

    def run(job: DiagnoseJob) -> None:
        nonlocal active, peak
        with lock:
            active += 1
            peak = max(peak, active)
        try:
            time.sleep(0.1)
        finally:
            with lock:
                active -= 1

    for _ in range(10):
        registry.submit(run)
    registry._pool.shutdown(wait=True)

    assert peak <= 2, f"{peak} diagnoses ran concurrently; the pool is bounded at 2"


def test_a_job_that_raises_still_settles_rather_than_hanging_the_poller():
    """`/segments/diagnose/{id}` answers "pending" until `done` — a worker that
    dies without setting it would poll forever."""
    registry = DiagnoseRegistry()

    def run(job: DiagnoseJob) -> None:
        try:
            raise RuntimeError("boom")
        except Exception as exc:  # noqa: BLE001 — mirrors the endpoint's own handler
            job.error = str(exc)

    job_id = registry.submit(run)
    registry._pool.shutdown(wait=True)

    job = registry.get(job_id)
    assert job.done and job.error == "boom"
    registry.shutdown()


# ── A5 — a failed tile extraction leaves a trace ─────────────────────────


def test_a_tile_extraction_failure_is_recorded_rather_than_swallowed(tmp_path, monkeypatch, caplog):
    """This was the one branch in `build` that swallowed a failure with no log
    line at all, in the file #232 instrumented for exactly this reason: a
    region that routed fine but showed no basemap had nothing to explain it.
    Tiles stay best-effort — the region must still come up ready."""
    monkeypatch.setattr("plotlines_service.app.region_lib.ensure_graph",
                        lambda region, cache_dir: tmp_path / "graph.graphml")
    monkeypatch.setattr("plotlines_service.app.load_graphml", lambda path: object())

    def explode(*_args, **_kwargs):
        raise OSError("upstream archive is truncated")

    monkeypatch.setattr("plotlines_service.app.extract_bbox", explode)

    region = RegionState("k", (-105.0, 40.0, -104.9, 40.1), "bike")
    with caplog.at_level("WARNING", logger="plotlines.sidecar"):
        region.build(tmp_path, tmp_path / "home.pmtiles")

    assert region.routing_ready, "a tile failure must never fail the region (B1)"
    assert region.tiles_error == "OSError: upstream archive is truncated"
    assert region.diagnostics()["tiles_error"] == region.tiles_error
    assert any("region tiles FAILED" in r.getMessage() for r in caplog.records)


def test_a_bbox_with_no_tile_coverage_is_not_reported_as_an_error(tmp_path, monkeypatch):
    """`NoTilesInBbox` is the expected miss, not a failure: `/tiles` answers
    404 per-request and there is nothing to root-cause."""
    from plotlines_core.tiles.extract import NoTilesInBbox

    monkeypatch.setattr("plotlines_service.app.region_lib.ensure_graph",
                        lambda region, cache_dir: tmp_path / "graph.graphml")
    monkeypatch.setattr("plotlines_service.app.load_graphml", lambda path: object())

    def no_coverage(*_args, **_kwargs):
        raise NoTilesInBbox("nothing here")

    monkeypatch.setattr("plotlines_service.app.extract_bbox", no_coverage)

    region = RegionState("k", (-105.0, 40.0, -104.9, 40.1), "bike")
    region.build(tmp_path, tmp_path / "home.pmtiles")

    assert region.routing_ready
    assert region.tiles_error is None


def test_a_retry_clears_the_previous_attempts_tile_error(tmp_path, monkeypatch):
    monkeypatch.setattr("plotlines_service.app.region_lib.ensure_graph",
                        lambda region, cache_dir: tmp_path / "graph.graphml")
    monkeypatch.setattr("plotlines_service.app.load_graphml", lambda path: object())

    calls = {"n": 0}

    def flaky(*_args, **_kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise OSError("transient")

    monkeypatch.setattr("plotlines_service.app.extract_bbox", flaky)
    monkeypatch.setattr("plotlines_service.app.Archive", lambda path: object())

    region = RegionState("k", (-105.0, 40.0, -104.9, 40.1), "bike")
    region.build(tmp_path, tmp_path / "home.pmtiles")
    assert region.tiles_error is not None

    region.build(tmp_path, tmp_path / "home.pmtiles")
    assert region.tiles_error is None, "a stale error would misreport a healthy retry"
