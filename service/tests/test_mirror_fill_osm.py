"""The OSM layer's fill — issue #518 (epic #516, ARCH D67).

A fake Geofabrik (a local HTTP server that records every request) serves one
tiny synthetic North Carolina extract, its `.md5` and `.poly`, and the mirror
holds an `index-v1.json` naming it. Everything else is the real code path:
`/clip` → `FillWorker` → `OsmFiller` → `geofabrik_pull.pull_region` →
`mirror_clip.clip_bbox` precut → `/clip` again.
"""

from __future__ import annotations

import hashlib
import http.server
import json
import threading
import time
from datetime import timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from mirror_clip_fixtures import node, write_pbf

from plotlines_service.mirror_clip import CLIENT_KEY_HEADER, create_clip_app
from plotlines_service.mirror_fill import READY, FillWorker, StoreBook
from plotlines_service.mirror_fill_osm import (
    OsmFiller,
    cells_for,
    covering_regions,
    parse_index,
)

KEY = "k"
PIN = "2026-09-18"
NC = "north-america/us/north-carolina"
NC_BOX = (-84.4, 33.8, -75.4, 36.6)
GREENSBORO = {"west": -79.9, "south": 36.05, "east": -79.75, "north": 36.15}
RALEIGH = {"west": -78.7, "south": 35.75, "east": -78.6, "north": 35.85}
OCEAN = {"west": -60.5, "south": 30.1, "east": -60.4, "north": 30.2}


def _ring(box):
    w, s, e, n = box
    return [[w, s], [e, s], [e, n], [w, n], [w, s]]


def _feature(fid, parent, path, box):
    props = {"id": fid, "urls": {"pbf": f"https://download.geofabrik.de/{path}-latest.osm.pbf"}}
    if parent:
        props["parent"] = parent
    return {"type": "Feature", "properties": props,
            "geometry": {"type": "MultiPolygon", "coordinates": [[_ring(box)]]}}


INDEX = {"type": "FeatureCollection", "features": [
    _feature("north-america", None, "north-america", (-170, 5, -50, 84)),
    _feature("us", "north-america", "north-america/us", (-125, 24, -66, 50)),
    _feature("us-south", "north-america", "north-america/us-south", (-107, 24, -75, 40)),
    _feature("us/north-carolina", "north-america", NC, NC_BOX),
]}


def _nc_pbf(tmp_path: Path) -> bytes:
    path = write_pbf(tmp_path / "nc-src.osm.pbf", nodes=[
        node(1, -79.8, 36.1, {"name": "Greensboro"}),
        node(2, -78.65, 35.8, {"name": "Raleigh"}),
        node(3, -82.55, 35.6, {"name": "Asheville"}),
    ], box=NC_BOX)
    return path.read_bytes()


class _Handler(http.server.BaseHTTPRequestHandler):
    routes: dict = {}
    log: list = []

    def do_GET(self):  # noqa: N802
        self.log.append(self.path)
        body = self.routes.get(self.path)
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


@pytest.fixture
def geofabrik(tmp_path):
    pbf = _nc_pbf(tmp_path)
    digest = hashlib.md5(pbf).hexdigest()
    poly = ("nc\nouter\n" + "".join(f"   {x} {y}\n" for x, y in _ring(NC_BOX)) + "END\nEND\n")
    log: list = []
    handler = type("H", (_Handler,), {"log": log, "routes": {
        f"/{NC}-latest.osm.pbf": pbf,
        f"/{NC}-latest.osm.pbf.md5": f"{digest}  north-carolina-latest.osm.pbf\n".encode(),
        f"/{NC}.poly": poly.encode(),
    }})
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_port}", log
    server.shutdown()


def _mirror(tmp_path: Path, *, regions: dict | None = None) -> Path:
    root = tmp_path / "mirror"
    pin_dir = root / "osm" / "geofabrik" / PIN
    pin_dir.mkdir(parents=True)
    (pin_dir / "index-v1.json").write_text(json.dumps(INDEX))
    (root / "MIRROR_STATE.json").write_text(json.dumps({
        "schema_version": 1,
        "geofabrik": {"pinned_date": PIN, "regions": regions or {}}}))
    return root


def _app(tmp_path, root, base_url):
    filler = OsmFiller(root, base_url=base_url, request_spacing=timedelta(0))
    worker = FillWorker(root, [filler], state_dir=tmp_path / "fill-state")
    app = create_clip_app(root, tmp_dir=tmp_path / "scratch", client_key=KEY,
                          fill_worker=worker)
    return TestClient(app), worker


def _clip(tc, bbox):
    return tc.get("/clip", params=bbox, headers={CLIENT_KEY_HEADER: KEY})


def _wait_ready(worker, fill_id, timeout=20.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = worker.status(fill_id)
        if status.state == READY:
            return status
        assert status.state == "fetching", status
        time.sleep(0.05)
    raise AssertionError(f"fill never landed: {worker.status(fill_id)}")


def _body_downloads(log):
    return [p for p in log if p.endswith(".osm.pbf")]


# -- the acceptance path ----------------------------------------------------------


def test_a_greensboro_miss_fills_its_cell_and_the_next_clip_is_a_store_hit(
    tmp_path: Path, geofabrik,
) -> None:
    base_url, log = geofabrik
    root = _mirror(tmp_path)
    tc, worker = _app(tmp_path, root, base_url)
    try:
        first = _clip(tc, GREENSBORO)
        assert first.status_code == 202
        assert first.json()["state"] == "fetching"
        assert int(first.headers["retry-after"]) >= 1
        fill_id = first.json()["fill"]["fill_id"]
        _wait_ready(worker, fill_id)

        requests_after_fill = list(log)
        assert _body_downloads(requests_after_fill) == [f"/{NC}-latest.osm.pbf"]

        second = _clip(tc, GREENSBORO)
        assert second.status_code == 200
        assert second.headers["x-plotlines-clip-source-regions"] == "cell-1d-w080-n36"
        assert second.headers["x-plotlines-clip-source-pin"] == PIN
        assert log == requests_after_fill  # a store hit: no Geofabrik request
    finally:
        worker.shutdown()

    state = json.loads((root / "MIRROR_STATE.json").read_text())
    cell = state["geofabrik"]["regions"]["cell-1d-w080-n36"]
    assert cell["precut_bbox"] == [-80.0, 36.0, -79.0, 37.0]
    assert cell["precut_from"] == [NC]
    # The full-state source is bookkept, but never registered for /clip to
    # scan whole.
    assert NC not in state["geofabrik"]["regions"]
    assert state["geofabrik"]["fill_sources"][NC]["md5"]
    row = state["areas"]["osm/cell-1d-w080-n36"]
    assert row["pinned"] is False and row["upstream"] == f"geofabrik:{NC}@{PIN}"


def test_a_bbox_no_geofabrik_region_covers_is_terminal_with_no_job_or_request(
    tmp_path: Path, geofabrik,
) -> None:
    base_url, log = geofabrik
    root = _mirror(tmp_path)
    tc, worker = _app(tmp_path, root, base_url)
    try:
        resp = _clip(tc, OCEAN)
        assert resp.status_code == 404
        assert resp.json()["detail"]["error"] == "no_upstream_coverage"
        assert worker.in_flight() == 0
        assert log == []
    finally:
        worker.shutdown()


def test_two_fills_in_one_state_inside_a_day_download_it_once(
    tmp_path: Path, geofabrik,
) -> None:
    base_url, log = geofabrik
    root = _mirror(tmp_path)
    tc, worker = _app(tmp_path, root, base_url)
    try:
        _wait_ready(worker, _clip(tc, GREENSBORO).json()["fill"]["fill_id"])
        _wait_ready(worker, _clip(tc, RALEIGH).json()["fill"]["fill_id"])
        assert _clip(tc, RALEIGH).status_code == 200
    finally:
        worker.shutdown()
    assert _body_downloads(log) == [f"/{NC}-latest.osm.pbf"]
    # The second fill made no request at all: pull_region's 24 h cadence
    # skipped even the .md5 check.
    assert log.count(f"/{NC}-latest.osm.pbf.md5") == 1


def test_a_bbox_already_inside_a_seeded_precut_is_clipped_with_no_fill(
    tmp_path: Path, geofabrik,
) -> None:
    base_url, log = geofabrik
    root = _mirror(tmp_path, regions={"priority-w080-n36": {
        "precut_from": [NC], "precut_bbox": [-80.0, 36.0, -79.0, 37.0],
        "pulled_at": "2026-09-25T00:00:00Z"}})
    write_pbf(root / "osm" / "geofabrik" / PIN / "priority-w080-n36.osm.pbf",
              nodes=[node(1, -79.8, 36.1)], box=(-80.0, 36.0, -79.0, 37.0))
    tc, worker = _app(tmp_path, root, base_url)
    try:
        resp = _clip(tc, GREENSBORO)
        assert resp.status_code == 200
        assert resp.headers["x-plotlines-clip-source-regions"] == "priority-w080-n36"
        assert log == [] and worker.in_flight() == 0
    finally:
        worker.shutdown()


def test_a_fill_for_the_rest_of_a_clamped_priority_square_supersedes_it(
    tmp_path: Path, geofabrik,
) -> None:
    base_url, _ = geofabrik
    root = _mirror(tmp_path, regions={"priority-w080-n36": {
        "precut_from": [NC], "precut_bbox": [-80.0, 36.0, -79.9, 36.02],
        "pulled_at": "2026-09-25T00:00:00Z"}})
    write_pbf(root / "osm" / "geofabrik" / PIN / "priority-w080-n36.osm.pbf",
              nodes=[node(9, -79.95, 36.01)], box=(-80.0, 36.0, -79.9, 36.02))
    tc, worker = _app(tmp_path, root, base_url)
    try:
        _wait_ready(worker, _clip(tc, GREENSBORO).json()["fill"]["fill_id"])
        assert _clip(tc, GREENSBORO).headers["x-plotlines-clip-source-regions"] == "cell-1d-w080-n36"
    finally:
        worker.shutdown()
    regions = json.loads((root / "MIRROR_STATE.json").read_text())["geofabrik"]["regions"]
    assert "priority-w080-n36" not in regions
    assert (root / "osm" / "geofabrik" / PIN / "priority-w080-n36.osm.pbf").exists()


def test_evicting_a_filled_cell_unregisters_it_for_clip(tmp_path: Path, geofabrik) -> None:
    base_url, _ = geofabrik
    root = _mirror(tmp_path)
    tc, worker = _app(tmp_path, root, base_url)
    try:
        _wait_ready(worker, _clip(tc, GREENSBORO).json()["fill"]["fill_id"])
        worker.store_cap_bytes = 1
        assert worker.evict() == ["osm/cell-1d-w080-n36"]
    finally:
        worker.shutdown()
    state = json.loads((root / "MIRROR_STATE.json").read_text())
    assert "cell-1d-w080-n36" not in state["geofabrik"]["regions"]
    assert not (root / "osm" / "geofabrik" / PIN / "cell-1d-w080-n36.osm.pbf").exists()


def test_a_geofabrik_outage_is_a_failed_fill_not_a_coverage_answer(
    tmp_path: Path,
) -> None:
    root = _mirror(tmp_path)
    tc, worker = _app(tmp_path, root, "http://127.0.0.1:9")  # nothing listens
    try:
        fid = _clip(tc, GREENSBORO).json()["fill"]["fill_id"]
        deadline = time.monotonic() + 10
        while worker.status(fid).state == "fetching" and time.monotonic() < deadline:
            time.sleep(0.05)
        assert worker.status(fid).state == "failed:upstream_unavailable"
        again = _clip(tc, GREENSBORO)
        assert again.status_code == 503
        assert again.json()["detail"]["error"] == "fill_failed"
        assert int(again.headers["retry-after"]) > 0
    finally:
        worker.shutdown()


def test_a_keyless_mirror_never_starts_an_osm_fill_from_clip(tmp_path: Path, geofabrik) -> None:
    base_url, log = geofabrik
    root = _mirror(tmp_path)
    filler = OsmFiller(root, base_url=base_url, request_spacing=timedelta(0))
    worker = FillWorker(root, [filler], state_dir=tmp_path / "fill-state")
    tc = TestClient(create_clip_app(root, tmp_dir=tmp_path / "scratch", fill_worker=worker))
    try:
        resp = tc.get("/clip", params=GREENSBORO)
        assert resp.status_code == 404
        assert resp.json()["detail"]["error"] == "no_mirror_coverage"
        assert log == [] and worker.in_flight() == 0
    finally:
        worker.shutdown()


# -- the pieces -----------------------------------------------------------------------


def test_cells_for_splits_on_the_grid_and_ignores_an_edge_touch() -> None:
    assert [c[0] for c in cells_for((-79.9, 36.05, -79.75, 36.15))] == ["cell-1d-w080-n36"]
    assert [c[0] for c in cells_for((-80.0, 36.0, -79.7, 36.2))] == ["cell-1d-w080-n36"]
    assert [c[0] for c in cells_for((-80.1, 35.9, -79.9, 36.1))] == [
        "cell-1d-w081-n35", "cell-1d-w081-n36", "cell-1d-w080-n35", "cell-1d-w080-n36"]
    assert [c[0] for c in cells_for((-79.9, 36.05, -79.75, 36.15), 2.0)] == ["cell-2d-w080-n36"]


def test_covering_regions_prefers_the_state_over_overlapping_leaf_aggregates() -> None:
    regions = parse_index(INDEX)
    assert {r.id for r in regions} == {"us", "us-south", "us/north-carolina"}
    assert [r.path for r in covering_regions(regions, (-79.9, 36.05, -79.75, 36.15))] == [NC]
    # Outside North Carolina, but inside `us` and `us-south`: the smaller.
    assert [r.path for r in covering_regions(regions, (-90.1, 30.0, -90.0, 30.1))] == [
        "north-america/us-south"]
    assert covering_regions(regions, (-60.5, 30.1, -60.4, 30.2)) == []


def test_a_mirror_without_an_index_fails_the_fill_honestly(tmp_path: Path) -> None:
    root = _mirror(tmp_path)
    (root / "osm" / "geofabrik" / PIN / "index-v1.json").unlink()
    filler = OsmFiller(root, request_spacing=timedelta(0))
    worker = FillWorker(root, [filler], state_dir=tmp_path / "fill-state")
    try:
        status = worker.request("osm", (-79.9, 36.05, -79.75, 36.15))
        deadline = time.monotonic() + 10
        while worker.status(status.fill_id).state == "fetching" and time.monotonic() < deadline:
            time.sleep(0.05)
        assert worker.status(status.fill_id).state == "failed:no_index"
    finally:
        worker.shutdown()


def test_the_records_seed_the_filled_cell_as_an_unpinned_row(tmp_path: Path, geofabrik) -> None:
    base_url, _ = geofabrik
    root = _mirror(tmp_path)
    tc, worker = _app(tmp_path, root, base_url)
    try:
        _wait_ready(worker, _clip(tc, GREENSBORO).json()["fill"]["fill_id"])
    finally:
        worker.shutdown()
    row = StoreBook(root).records()["osm/cell-1d-w080-n36"]
    assert row["seeded"] is False and row["pinned"] is False
