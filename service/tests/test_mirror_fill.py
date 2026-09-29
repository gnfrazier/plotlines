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
        import time
        time.sleep(0.05)
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
