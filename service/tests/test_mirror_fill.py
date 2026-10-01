"""The mirror's fill worker and contract — issue #517 (epic #516, ARCH D67).

Everything here runs against a fake layer filler: a 1° grid whose `fetch`
blocks on an `Event` the test controls, so "in flight" is a state the test
holds rather than a race it hopes to win. Nothing reaches a real upstream.
"""

from __future__ import annotations

import json
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_service import mirror_fill
from plotlines_service.mirror_clip import CLIENT_KEY_HEADER, create_clip_app
from plotlines_service.mirror_fill import (
    FETCHING,
    NO_UPSTREAM_COVERAGE,
    READY,
    STAGING_PREFIX,
    AreaPlan,
    FillDeferred,
    FilledArea,
    FillPlan,
    FillWorker,
    StoreBook,
    seed_area_records,
)

KEY = "test-client-key"
_GREENSBORO = (-80.0, 36.0, -79.7, 36.2)


class FakeFiller:
    """A 1° grid. West of -170 has no upstream. `fetch` writes a staging
    file, then blocks on `release` before publishing — or raises `fail`."""

    layer = "fake"
    retry_hint_s = 7

    def __init__(self, *, payload: bytes = b"x" * 100):
        self.release = threading.Event()
        self.entered = threading.Event()
        self.calls: list[str] = []
        self.payload = payload
        self.fail: Exception | None = None
        self.defer_once: FillDeferred | None = None
        self._lock = threading.Lock()

    def plan(self, bbox, records):
        west, south, east, north = bbox
        if west < -170:
            return FillPlan(no_coverage="no upstream publishes the open Pacific")
        cell = f"cell_{int(west // 1)}_{int(south // 1)}"
        return FillPlan(areas=(AreaPlan(cell, f"fake/{cell}.bin",
                                        (west // 1, south // 1, west // 1 + 1, south // 1 + 1)),))

    def fetch(self, area, ctx):
        with self._lock:
            self.calls.append(area.area)
        if self.defer_once is not None:
            exc, self.defer_once = self.defer_once, None
            raise exc
        staged = ctx.staging_path(area.path)
        staged.write_bytes(b"partial")
        self.entered.set()
        assert self.release.wait(10), "test never released the fetch"
        if self.fail is not None:
            raise self.fail
        staged.write_bytes(self.payload)
        ctx.publish(staged, area.path)
        return FilledArea(upstream="fake-upstream")


def _store(tmp_path: Path, state: dict | None = None) -> Path:
    root = tmp_path / "store"
    root.mkdir()
    (root / "MIRROR_STATE.json").write_text(json.dumps(state or {"schema_version": 1}))
    return root


def _worker(tmp_path: Path, filler: FakeFiller, root: Path | None = None, **kw) -> FillWorker:
    root = root or (tmp_path / "store" if (tmp_path / "store").exists() else _store(tmp_path))
    return FillWorker(root, [filler], state_dir=tmp_path / "fill-state", **kw)


def _wait_state(worker: FillWorker, fill_id: str, want: str, timeout: float = 5.0) -> None:
    import time
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if worker.status(fill_id).state == want:
            return
        time.sleep(0.01)
    raise AssertionError(f"fill {fill_id} never reached {want}: {worker.status(fill_id)}")


# -- single-flight -------------------------------------------------------------


def test_concurrent_requests_for_one_missing_area_make_one_job(tmp_path: Path) -> None:
    filler = FakeFiller()
    worker = _worker(tmp_path, filler)
    try:
        with ThreadPoolExecutor(16) as pool:
            statuses = list(pool.map(lambda _: worker.request("fake", _GREENSBORO), range(16)))
        assert filler.entered.wait(5)

        assert {s.state for s in statuses} == {FETCHING}
        assert len({s.fill_id for s in statuses}) == 1
        assert sum(s.jobs_started for s in statuses) == 1
        filler.release.set()
        _wait_state(worker, statuses[0].fill_id, READY)
        assert filler.calls == ["cell_-80_36"]
    finally:
        worker.shutdown()


def test_a_request_inside_an_in_flight_area_joins_that_job(tmp_path: Path) -> None:
    filler = FakeFiller()
    worker = _worker(tmp_path, filler)
    try:
        first = worker.request("fake", _GREENSBORO)
        assert filler.entered.wait(5)
        inner = worker.request("fake", (-79.9, 36.05, -79.8, 36.1))
        assert inner.fill_id == first.fill_id
        assert inner.jobs_started == 0
        filler.release.set()
        _wait_state(worker, first.fill_id, READY)
        assert len(filler.calls) == 1
    finally:
        worker.shutdown()


def test_an_area_already_in_the_store_is_ready_at_once_with_no_job(tmp_path: Path) -> None:
    filler = FakeFiller()
    filler.release.set()
    worker = _worker(tmp_path, filler)
    try:
        first = worker.request("fake", _GREENSBORO)
        _wait_state(worker, first.fill_id, READY)

        again = worker.request("fake", _GREENSBORO)
        assert again.state == READY
        assert again.fill_id is None
        assert again.jobs_started == 0
        assert filler.calls == ["cell_-80_36"]
    finally:
        worker.shutdown()


def test_no_upstream_coverage_is_terminal_with_no_job(tmp_path: Path) -> None:
    filler = FakeFiller()
    worker = _worker(tmp_path, filler)
    try:
        status = worker.request("fake", (-175.0, 10.0, -174.0, 11.0))
        assert status.state == NO_UPSTREAM_COVERAGE
        assert status.fill_id is None
        assert "Pacific" in status.detail
        assert filler.calls == []
        assert worker.in_flight() == 0
    finally:
        worker.shutdown()


def test_a_fill_records_its_area_in_mirror_state(tmp_path: Path) -> None:
    filler = FakeFiller()
    filler.release.set()
    worker = _worker(tmp_path, filler)
    try:
        status = worker.request("fake", _GREENSBORO)
        _wait_state(worker, status.fill_id, READY)
    finally:
        worker.shutdown()
    state = json.loads((tmp_path / "store" / "MIRROR_STATE.json").read_text())
    row = state["areas"]["fake/cell_-80_36"]
    assert row["layer"] == "fake"
    assert row["path"] == "fake/cell_-80_36.bin"
    assert row["upstream"] == "fake-upstream"
    assert row["filled_at"] and row["last_read_at"]
    assert row["bytes"] == 100
    assert row["pinned"] is False
    assert state["schema_version"] == 1  # other keys survive the write


# -- failure, cooldown, deferral, timeout -----------------------------------------


def test_a_failed_fill_reports_failed_and_cools_down_before_a_new_job(tmp_path: Path) -> None:
    filler = FakeFiller()
    filler.fail = mirror_fill.FillFailed("upstream_404", "Geofabrik answered 404")
    filler.release.set()
    clock = {"t": 1000.0}
    worker = _worker(tmp_path, filler, wall_clock=lambda: clock["t"], failed_cooldown_s=300)
    try:
        status = worker.request("fake", _GREENSBORO)
        _wait_state(worker, status.fill_id, "failed:upstream_404")
        assert worker.status(status.fill_id).retry_after_s == 300

        again = worker.request("fake", _GREENSBORO)
        assert again.state == "failed:upstream_404"
        assert again.jobs_started == 0

        clock["t"] += 301
        filler.fail = None
        third = worker.request("fake", _GREENSBORO)
        assert third.jobs_started == 1
        _wait_state(worker, third.fill_id, READY)
    finally:
        worker.shutdown()


def test_a_deferred_fill_stays_fetching_with_retry_after_and_then_runs(tmp_path: Path) -> None:
    filler = FakeFiller()
    filler.defer_once = FillDeferred(0.2, "upstream allowance spent; resets soon")
    filler.release.set()
    worker = _worker(tmp_path, filler)
    try:
        status = worker.request("fake", _GREENSBORO)
        # Wait for the deferral itself rather than sleeping a fixed time: under
        # load the job may not have run yet, and the queued status carries a
        # longer hint than the deferral's (#602). `FillDeferred` floors its
        # wait at 1 s, so the window this polls for is never shorter.
        import time
        deadline = time.monotonic() + 5.0
        mid = worker.status(status.fill_id)
        while not (mid.retry_after_s is not None and mid.retry_after_s <= 1):
            assert time.monotonic() < deadline, f"fill never deferred: {mid}"
            time.sleep(0.01)
            mid = worker.status(status.fill_id)
        assert mid.state == FETCHING
        assert mid.retry_after_s is not None and mid.retry_after_s <= 1
        assert "allowance" in mid.detail
        _wait_state(worker, status.fill_id, READY)
        assert filler.calls == ["cell_-80_36", "cell_-80_36"]
    finally:
        worker.shutdown()


def test_a_job_past_its_timeout_is_failed_timeout_not_fetching_forever(tmp_path: Path) -> None:
    filler = FakeFiller()
    clock = {"t": 0.0}
    worker = _worker(tmp_path, filler, clock=lambda: clock["t"], job_timeout_s=60)
    try:
        status = worker.request("fake", _GREENSBORO)
        assert filler.entered.wait(5)
        clock["t"] = 61.0
        assert worker.status(status.fill_id).state == "failed:timeout"
    finally:
        filler.release.set()
        worker.shutdown(wait=True)


# -- restart ---------------------------------------------------------------------


def test_a_worker_killed_mid_job_leaves_no_partial_file_and_no_stuck_job(
    tmp_path: Path,
) -> None:
    filler = FakeFiller()
    filler.fail = RuntimeError("process killed")  # the first worker never publishes
    worker = _worker(tmp_path, filler)
    status = worker.request("fake", _GREENSBORO)
    assert filler.entered.wait(5)
    root = tmp_path / "store"
    staged = list(root.rglob(f"{STAGING_PREFIX}*"))
    assert staged, "the fake fetch writes a partial staging file first"

    # A fresh process over the same store and journal: the old one is "dead"
    # with its job mid-fetch.
    restarted = FillWorker(root, [FakeFiller()], state_dir=tmp_path / "fill-state")
    try:
        assert not any(p.exists() for p in staged)
        assert not (root / "fake" / "cell_-80_36.bin").exists()
        assert restarted.status(status.fill_id).state == "failed:restarted"
        assert restarted.in_flight() == 0
    finally:
        filler.release.set()
        worker.shutdown(wait=True)
        restarted.shutdown()


def test_a_queued_job_is_resumed_after_a_restart_and_a_restarted_one_is_not_cooled_down(
    tmp_path: Path,
) -> None:
    # One worker thread: the first area's fetch holds it, so the second area's
    # job is queued, never started, when the process "dies".
    filler = FakeFiller()
    worker = _worker(tmp_path, filler, failed_cooldown_s=3600)
    running = worker.request("fake", _GREENSBORO)
    assert filler.entered.wait(5)
    queued = worker.request("fake", (-78.5, 35.5, -78.2, 35.8))
    assert queued.state == FETCHING

    second = FakeFiller()
    second.release.set()
    restarted = FillWorker(tmp_path / "store", [second], state_dir=tmp_path / "fill-state",
                           failed_cooldown_s=3600)
    try:
        # The queued job had nothing in flight: it runs again, not failed.
        _wait_state(restarted, queued.fill_id, READY)
        assert restarted.status(running.fill_id).state == "failed:restarted"
        # The restart is not the upstream's verdict, so asking again starts a
        # job at once rather than waiting out the hour's cooldown.
        again = restarted.request("fake", _GREENSBORO)
        assert again.jobs_started == 1
        _wait_state(restarted, again.fill_id, READY)
    finally:
        filler.release.set()
        worker.shutdown(wait=True)
        restarted.shutdown(wait=True)


def test_a_deferred_job_is_resumed_after_a_restart(tmp_path: Path) -> None:
    filler = FakeFiller()
    filler.defer_once = FillDeferred(3600, "quota wait")
    worker = _worker(tmp_path, filler)
    status = worker.request("fake", _GREENSBORO)
    import time
    time.sleep(0.1)
    worker.shutdown(wait=True)

    restarted = FillWorker(tmp_path / "store", [FakeFiller()], state_dir=tmp_path / "fill-state")
    try:
        after = restarted.status(status.fill_id)
        assert after.state == FETCHING
        assert after.retry_after_s > 3000
    finally:
        restarted.shutdown()


# -- eviction ----------------------------------------------------------------------


def _area_row(path: str, *, read: str, pinned: bool = False, nbytes: int = 100) -> dict:
    return {"layer": "fake", "area": Path(path).stem, "path": path, "bbox": None,
            "upstream": "x", "filled_at": read, "last_read_at": read,
            "bytes": nbytes, "pinned": pinned, "seeded": False}


def test_eviction_removes_the_least_recently_read_unpinned_area_never_a_pinned_one(
    tmp_path: Path,
) -> None:
    rows = {
        "fake/oldest_pinned": _area_row("fake/oldest_pinned.bin", read="2026-01-01T00:00:00Z",
                                        pinned=True),
        "fake/old": _area_row("fake/old.bin", read="2026-02-01T00:00:00Z"),
        "fake/new": _area_row("fake/new.bin", read="2026-09-01T00:00:00Z"),
    }
    root = _store(tmp_path, {"areas": rows})
    for row in rows.values():
        (root / row["path"]).parent.mkdir(parents=True, exist_ok=True)
        (root / row["path"]).write_bytes(b"x" * 100)

    worker = _worker(tmp_path, FakeFiller(), root=root, store_cap_bytes=250)
    try:
        assert worker.evict() == ["fake/old"]
    finally:
        worker.shutdown()
    assert not (root / "fake/old.bin").exists()
    assert (root / "fake/oldest_pinned.bin").exists()
    assert (root / "fake/new.bin").exists()
    areas = json.loads((root / "MIRROR_STATE.json").read_text())["areas"]
    assert set(areas) == {"fake/oldest_pinned", "fake/new"}


def test_eviction_never_touches_pinned_areas_even_over_the_cap(tmp_path: Path) -> None:
    rows = {
        "fake/a": _area_row("fake/a.bin", read="2026-01-01T00:00:00Z", pinned=True),
        "fake/b": _area_row("fake/b.bin", read="2026-01-02T00:00:00Z", pinned=True),
    }
    root = _store(tmp_path, {"areas": rows})
    for row in rows.values():
        (root / row["path"]).parent.mkdir(parents=True, exist_ok=True)
        (root / row["path"]).write_bytes(b"x" * 100)
    worker = _worker(tmp_path, FakeFiller(), root=root, store_cap_bytes=50)
    try:
        assert worker.evict() == []
    finally:
        worker.shutdown()
    assert (root / "fake/a.bin").exists() and (root / "fake/b.bin").exists()


def test_a_fill_that_pushes_the_store_over_its_cap_evicts_the_coldest_area(
    tmp_path: Path,
) -> None:
    rows = {"fake/cold": _area_row("fake/cold.bin", read="2026-01-01T00:00:00Z")}
    root = _store(tmp_path, {"areas": rows})
    (root / "fake").mkdir()
    (root / "fake/cold.bin").write_bytes(b"x" * 100)
    filler = FakeFiller()
    filler.release.set()
    worker = _worker(tmp_path, filler, root=root, store_cap_bytes=150)
    try:
        status = worker.request("fake", _GREENSBORO)
        _wait_state(worker, status.fill_id, READY)
    finally:
        worker.shutdown(wait=True)
    assert not (root / "fake/cold.bin").exists()
    assert (root / "fake/cell_-80_36.bin").exists()


def test_a_ready_answer_stamps_last_read_at(tmp_path: Path) -> None:
    rows = {"fake/cell_-80_36": _area_row("fake/cell_-80_36.bin", read="2026-01-01T00:00:00Z")}
    root = _store(tmp_path, {"areas": rows})
    (root / "fake").mkdir()
    (root / "fake/cell_-80_36.bin").write_bytes(b"x")
    worker = _worker(tmp_path, FakeFiller(), root=root)
    try:
        assert worker.request("fake", _GREENSBORO).state == READY
    finally:
        worker.shutdown()
    row = json.loads((root / "MIRROR_STATE.json").read_text())["areas"]["fake/cell_-80_36"]
    assert row["last_read_at"] > "2026-09-01"


# -- seeding: the existing entries are the record's first rows ----------------------


def _seeded_state() -> dict:
    return {
        "basemap": {"covered_regions": {
            "wnc-corridor": {"name": "wnc-corridor", "bbox": [-84.4, 34.9, -81.0, 36.6],
                             "path": "basemap/protomaps/20250101-wnc/corridor.pmtiles",
                             "source": {"planet_build_date": "20260920"},
                             "extracted_at": "2026-09-21T00:00:00Z"}}},
        "geofabrik": {"pinned_date": "2026-09-01", "regions": {
            "wnc-corridor": {"precut_from": ["north-carolina", "tennessee"],
                             "precut_bbox": [-84.4, 34.9, -81.0, 36.6],
                             "pulled_at": "2026-09-02T00:00:00Z"}}},
    }


def test_existing_geofabrik_and_basemap_entries_seed_pinned_rows(tmp_path: Path) -> None:
    state = _seeded_state()
    assert seed_area_records(state, tmp_path)
    osm = state["areas"]["osm/wnc-corridor"]
    assert osm["path"] == "osm/geofabrik/2026-09-01/wnc-corridor.osm.pbf"
    assert osm["pinned"] and osm["seeded"]
    assert osm["upstream"] == "precut:north-carolina,tennessee"
    basemap = state["areas"]["basemap/wnc-corridor"]
    assert basemap["path"] == "basemap/protomaps/20250101-wnc/corridor.pmtiles"
    assert basemap["pinned"] and basemap["seeded"]
    assert basemap["upstream"] == "protomaps:20260920"
    assert not seed_area_records(state, tmp_path)  # idempotent


def test_a_seeded_row_goes_when_its_source_entry_goes_but_a_filled_row_stays(
    tmp_path: Path,
) -> None:
    state = _seeded_state()
    seed_area_records(state, tmp_path)
    state["areas"]["osm/greensboro"] = _area_row("osm/x.osm.pbf", read="2026-09-01T00:00:00Z")
    state["geofabrik"]["regions"].clear()
    seed_area_records(state, tmp_path)
    assert "osm/wnc-corridor" not in state["areas"]
    assert "osm/greensboro" in state["areas"]


def test_the_pull_script_carries_filled_rows_forward_instead_of_clobbering_them(
    tmp_path: Path,
) -> None:
    from test_geofabrik_pull import _load_geofabrik_pull
    pull = _load_geofabrik_pull()

    root = _store(tmp_path, _seeded_state())
    stale = pull.load_state(root / "MIRROR_STATE.json")  # a long run starts
    StoreBook(root).update(lambda s: s.setdefault("areas", {}).update(
        {"fake/filled": _area_row("fake/filled.bin", read="2026-09-01T00:00:00Z")}))
    pull.save_state(root / "MIRROR_STATE.json", stale)  # ...and ends
    assert "fake/filled" in json.loads((root / "MIRROR_STATE.json").read_text())["areas"]


def test_a_long_pull_run_applies_only_its_own_changes_to_the_state_file(
    tmp_path: Path,
) -> None:
    """A precut run holds its state for hours. Meanwhile the fill worker
    registers a cell for `/clip` (and evicts another), and the basemap script
    records a region. The run's checkpoint must apply what *it* changed and
    leave every one of those standing."""
    from test_geofabrik_pull import _load_geofabrik_pull
    pull = _load_geofabrik_pull()

    seeded = _seeded_state()
    seeded["geofabrik"]["regions"]["cell-1d-w081-n35"] = {"filled": True, "precut_bbox": [
        -81.0, 35.0, -80.0, 36.0]}
    root = _store(tmp_path, seeded)
    path = root / "MIRROR_STATE.json"
    state = pull.load_state(path)  # the run starts
    baseline = json.loads(json.dumps(state))

    def _meanwhile(s: dict) -> None:
        regions = s["geofabrik"]["regions"]
        regions["cell-1d-w080-n36"] = {"filled": True, "precut_bbox": [-80.0, 36.0, -79.0, 37.0]}
        regions.pop("cell-1d-w081-n35")  # evicted by the worker
        s["geofabrik"].setdefault("fill_sources", {})["us/nc"] = {"md5": "abc"}
        s.setdefault("basemap", {}).setdefault("covered_regions", {})["cell-2d-w080-n36"] = {
            "path": "basemap/protomaps/cells/cell-2d-w080-n36.pmtiles"}

    StoreBook(root).update(_meanwhile)
    # The run's own work: a precut cell it pinned.
    state["geofabrik"]["regions"]["priority-w080-n34"] = {"precut_bbox": [-80, 34, -78, 36]}
    pull.save_state(path, state, baseline)

    on_disk = json.loads(path.read_text())
    regions = on_disk["geofabrik"]["regions"]
    assert "priority-w080-n34" in regions  # the run's change
    assert "cell-1d-w080-n36" in regions  # the fill's registration stands
    assert "cell-1d-w081-n35" not in regions  # an evicted cell isn't re-registered
    assert on_disk["geofabrik"]["fill_sources"] == {"us/nc": {"md5": "abc"}}
    assert "cell-2d-w080-n36" in on_disk["basemap"]["covered_regions"]
    # ...and the run's in-memory copy now matches what it wrote.
    assert state == on_disk == baseline


# -- the HTTP gate ------------------------------------------------------------------


def _app(tmp_path: Path, filler: FakeFiller, **kw):
    root = tmp_path / "store" if (tmp_path / "store").exists() else _store(tmp_path)
    worker = FillWorker(root, [filler], state_dir=tmp_path / "fill-state")
    kw.setdefault("client_key", KEY)
    app = create_clip_app(root, tmp_dir=tmp_path / "scratch", fill_worker=worker, **kw)
    return TestClient(app), worker


_BODY = {"layer": "fake", "west": -80.0, "south": 36.0, "east": -79.7, "north": 36.2}


def test_post_fill_answers_202_fetching_then_get_answers_ready(tmp_path: Path) -> None:
    filler = FakeFiller()
    tc, worker = _app(tmp_path, filler)
    try:
        resp = tc.post("/fill", json=_BODY, headers={CLIENT_KEY_HEADER: KEY})
        assert resp.status_code == 202
        body = resp.json()
        assert body["state"] == FETCHING
        assert body["retry_after_s"] == 7
        assert resp.headers["retry-after"] == "7"
        filler.release.set()
        _wait_state(worker, body["fill_id"], READY)

        poll = tc.get(f"/fill/{body['fill_id']}", headers={CLIENT_KEY_HEADER: KEY})
        assert poll.status_code == 200
        assert poll.json()["state"] == READY

        again = tc.post("/fill", json=_BODY, headers={CLIENT_KEY_HEADER: KEY})
        assert again.status_code == 200
        assert again.json() == {**again.json(), "state": READY, "fill_id": None}
    finally:
        worker.shutdown()


@pytest.mark.parametrize("headers", [{}, {CLIENT_KEY_HEADER: "wrong"}, {CLIENT_KEY_HEADER: ""}])
def test_no_or_wrong_key_is_401_and_starts_no_job(tmp_path: Path, headers: dict) -> None:
    filler = FakeFiller()
    tc, worker = _app(tmp_path, filler)
    try:
        resp = tc.post("/fill", json=_BODY, headers=headers)
        assert resp.status_code == 401
        assert resp.json()["detail"]["error"] == "unauthorized_client"
        assert worker.in_flight() == 0 and filler.calls == []
    finally:
        worker.shutdown()


def test_a_mirror_with_no_key_configured_refuses_every_fill(tmp_path: Path) -> None:
    """`/clip` is open on a keyless mirror (#263's dev default); a fill is
    not, because it spends a third party's upstream."""
    filler = FakeFiller()
    tc, worker = _app(tmp_path, filler, client_key=None)
    try:
        assert tc.post("/fill", json=_BODY).status_code == 401
        assert filler.calls == []
    finally:
        worker.shutdown()


def test_the_anonymous_web_reader_cannot_start_a_fill(tmp_path: Path) -> None:
    """SPIKE-F / D59: the reader holds an opaque session cookie and never
    the client key. A cookie is not a key."""
    filler = FakeFiller()
    tc, worker = _app(tmp_path, filler)
    try:
        resp = tc.post("/fill", json=_BODY, cookies={"__Host-plotlines-read": "opaque"})
        assert resp.status_code == 401
        assert filler.calls == []
    finally:
        worker.shutdown()


def test_over_the_rate_limit_is_429_with_retry_after_and_starts_no_job(tmp_path: Path) -> None:
    filler = FakeFiller()
    tc, worker = _app(tmp_path, filler, rate_limit_per_minute=2)
    try:
        ocean = {**_BODY, "west": -175.0, "east": -174.0}  # starts no job itself
        for _ in range(2):
            assert tc.post("/fill", json=ocean, headers={CLIENT_KEY_HEADER: KEY}).status_code == 200
        resp = tc.post("/fill", json=_BODY, headers={CLIENT_KEY_HEADER: KEY})
        assert resp.status_code == 429
        assert 1 <= int(resp.headers["retry-after"]) <= 61
        assert worker.in_flight() == 0 and filler.calls == []
    finally:
        worker.shutdown()


def test_fill_and_clip_share_one_rate_limit(tmp_path: Path) -> None:
    filler = FakeFiller()
    tc, worker = _app(tmp_path, filler, rate_limit_per_minute=1)
    try:
        ocean = {**_BODY, "west": -175.0, "east": -174.0}
        assert tc.post("/fill", json=ocean, headers={CLIENT_KEY_HEADER: KEY}).status_code == 200
        clip = tc.get("/clip", params={"west": -80, "south": 36, "east": -79.7, "north": 36.2},
                      headers={CLIENT_KEY_HEADER: KEY})
        assert clip.status_code == 429
    finally:
        worker.shutdown()


def test_polling_a_fill_is_not_rate_limited(tmp_path: Path) -> None:
    filler = FakeFiller()
    tc, worker = _app(tmp_path, filler, rate_limit_per_minute=1)
    try:
        fid = tc.post("/fill", json=_BODY, headers={CLIENT_KEY_HEADER: KEY}).json()["fill_id"]
        for _ in range(5):
            assert tc.get(f"/fill/{fid}", headers={CLIENT_KEY_HEADER: KEY}).status_code == 202
        assert tc.get(f"/fill/{fid}").status_code == 401
    finally:
        filler.release.set()
        worker.shutdown()


def test_unknown_layer_and_unknown_fill_are_finished_sentences(tmp_path: Path) -> None:
    tc, worker = _app(tmp_path, FakeFiller())
    try:
        resp = tc.post("/fill", json={**_BODY, "layer": "weather"},
                       headers={CLIENT_KEY_HEADER: KEY})
        assert resp.status_code == 400
        assert resp.json()["detail"]["error"] == "unknown_layer"
        missing = tc.get("/fill/nope", headers={CLIENT_KEY_HEADER: KEY})
        assert missing.status_code == 404
        assert missing.json()["detail"]["error"] == "unknown_fill"
    finally:
        worker.shutdown()


def test_the_clip_app_without_a_worker_mounts_no_fill_route(tmp_path: Path) -> None:
    root = _store(tmp_path)
    tc = TestClient(create_clip_app(root, tmp_dir=tmp_path / "scratch"))
    assert tc.post("/fill", json=_BODY).status_code in (404, 405)
    assert tc.get("/health").json()["fill"] is None


def test_post_fill_returns_while_the_fetch_is_still_running(tmp_path: Path) -> None:
    """D66 applied to the worker: the request thread plans and enqueues;
    it never waits on `fetch`."""
    import time
    filler = FakeFiller()
    tc, worker = _app(tmp_path, filler)
    try:
        started = time.monotonic()
        resp = tc.post("/fill", json=_BODY, headers={CLIENT_KEY_HEADER: KEY})
        assert time.monotonic() - started < 1.0
        assert resp.status_code == 202
        assert filler.entered.wait(5) and not filler.release.is_set()
        assert tc.get("/health").status_code == 200
    finally:
        filler.release.set()
        worker.shutdown()


def test_a_clip_stamps_last_read_at_on_the_area_it_read(tmp_path: Path) -> None:
    from mirror_clip_fixtures import build_mirror_tree, node, write_pbf

    src = write_pbf(tmp_path / "src.osm.pbf",
                    nodes=[node(1, -82.2, 35.2, {"natural": "peak"})],
                    box=(-83.0, 34.0, -81.0, 36.0))
    root = build_mirror_tree(tmp_path / "store", regions={"the-region": src})
    worker = FillWorker(root, [FakeFiller()], state_dir=tmp_path / "fill-state")
    try:
        tc = TestClient(create_clip_app(root, tmp_dir=tmp_path / "scratch",
                                        fill_worker=worker))
        before = StoreBook(root).records()["osm/the-region"]
        assert before["last_read_at"] is None and before["pinned"]
        assert tc.get("/clip", params={"west": -82.6, "south": 34.9, "east": -81.9,
                                       "north": 35.6}).status_code == 200
    finally:
        worker.shutdown()
    assert StoreBook(root).records()["osm/the-region"]["last_read_at"]


# -- sharing the store with the mirror's own scripts (#517 follow-up) ----------------
# Found on the Pi 2026-09-29: the container runs as root, and the worker's
# state write left MIRROR_STATE.json (and its .lock) root-owned 0600, so the
# `greg`-run 1° re-cut died with PermissionError at its next state save.


def _mode(path: Path) -> int:
    return path.stat().st_mode & 0o777


def test_a_state_write_keeps_the_files_mode_and_never_leaves_0600(tmp_path: Path) -> None:
    root = _store(tmp_path, _seeded_state())
    (root / "MIRROR_STATE.json").chmod(0o644)
    StoreBook(root).update(lambda s: s.setdefault("areas", {}).update(
        {"fake/x": _area_row("fake/x.bin", read="2026-09-01T00:00:00Z")}))
    assert _mode(root / "MIRROR_STATE.json") == 0o644

    fresh = tmp_path / "fresh"
    fresh.mkdir()
    StoreBook(fresh).update(lambda s: None)
    assert _mode(fresh / "MIRROR_STATE.json") == 0o644


def test_a_lock_file_this_user_cannot_write_does_not_block_a_state_write(tmp_path: Path) -> None:
    """`flock` needs no write access; the lock is opened read-only, so a
    lock another user created never stops the worker or the scripts."""
    root = _store(tmp_path, _seeded_state())
    lock = root / "MIRROR_STATE.json.lock"
    lock.touch()
    lock.chmod(0o444)
    StoreBook(root).update(lambda s: s.setdefault("areas", {}).update(
        {"fake/x": _area_row("fake/x.bin", read="2026-09-01T00:00:00Z")}))
    assert "fake/x" in json.loads((root / "MIRROR_STATE.json").read_text())["areas"]

    from test_geofabrik_pull import _load_geofabrik_pull
    pull = _load_geofabrik_pull()
    state = pull.load_state(root / "MIRROR_STATE.json")
    pull.save_state(root / "MIRROR_STATE.json", state)
    assert _mode(root / "MIRROR_STATE.json") == 0o644


def test_the_worker_then_the_pull_script_share_the_state_file(tmp_path: Path) -> None:
    """The Pi's sequence: a keyed fill answers ready (a state write), then
    the re-cut saves its state. Both must succeed."""
    filler = FakeFiller()
    filler.release.set()
    root = _store(tmp_path, _seeded_state())
    worker = _worker(tmp_path, filler, root=root)
    try:
        _wait_state(worker, worker.request("fake", _GREENSBORO).fill_id, READY)
    finally:
        worker.shutdown()
    assert _mode(root / "MIRROR_STATE.json") == 0o644
    from test_geofabrik_pull import _load_geofabrik_pull
    pull = _load_geofabrik_pull()
    pull.save_state(root / "MIRROR_STATE.json", pull.load_state(root / "MIRROR_STATE.json"))


def test_a_published_store_file_is_world_readable(tmp_path: Path) -> None:
    filler = FakeFiller()
    filler.release.set()
    worker = _worker(tmp_path, filler)
    try:
        _wait_state(worker, worker.request("fake", _GREENSBORO).fill_id, READY)
    finally:
        worker.shutdown()
    assert _mode(tmp_path / "store" / "fake" / "cell_-80_36.bin") == 0o644


class _FakeOs:
    """Records the privilege calls `run_as_store_owner` makes."""

    def __init__(self, euid: int, store_uid: int):
        self.euid, self.store_uid = euid, store_uid
        self.calls: list = []

    def geteuid(self):
        return self.euid

    def stat(self, path):
        class _St:
            st_uid = self.store_uid
            st_gid = self.store_uid
        return _St()

    def chown(self, path, uid, gid):
        self.calls.append(("chown", Path(path).name, uid, gid))

    def setgroups(self, groups):
        self.calls.append(("setgroups", groups))

    def setgid(self, gid):
        self.calls.append(("setgid", gid))

    def setuid(self, uid):
        self.calls.append(("setuid", uid))


def test_a_root_worker_becomes_the_store_owner_after_handing_it_its_own_dirs(
    tmp_path: Path,
) -> None:
    journal = tmp_path / "fill-state"
    journal.mkdir()
    (journal / "fill_jobs.json").write_text("{}")
    ops = _FakeOs(euid=0, store_uid=1001)
    assert mirror_fill.run_as_store_owner(tmp_path / "store", [journal], ops=ops) == (1001, 1001)
    assert ("chown", "fill-state", 1001, 1001) in ops.calls
    assert ("chown", "fill_jobs.json", 1001, 1001) in ops.calls
    # Groups and gid before uid: after setuid there is no privilege left.
    assert ops.calls[-3:] == [("setgroups", []), ("setgid", 1001), ("setuid", 1001)]


def test_no_privilege_change_when_not_root_or_when_the_store_is_roots(tmp_path: Path) -> None:
    for ops in (_FakeOs(euid=1001, store_uid=1001), _FakeOs(euid=0, store_uid=0)):
        assert mirror_fill.run_as_store_owner(tmp_path, [tmp_path], ops=ops) is None
        assert ops.calls == []
