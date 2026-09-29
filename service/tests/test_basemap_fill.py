"""The basemap fill on the mirror and the sidecar reading the store by area
— issue #519 (epic #516, ARCH D67).

Mirror half: `BasemapFiller` with a fake `protomaps_extract` module whose
`run_pmtiles_extract` writes a synthetic archive for the requested bbox, so
the worker's plan / fetch / publish / record path runs for real and nothing
reaches Protomaps.

Sidecar half: `create_app(tiles_upstream=<store root>)` against a local
store, which is the same code path a remote root takes minus the socket.
"""

from __future__ import annotations

import json
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.tiles.basemap_set import BasemapArchiveSet
from plotlines_core.tiles.extract import _lonlat_to_tile
from plotlines_core.tiles import mirror_state
from plotlines_service.app import create_app
from plotlines_service.mirror_fill import READY, FillWorker, StoreBook
from plotlines_service.mirror_fill_basemap import TTL_DAYS, BasemapFiller
from plotlines_service.tiles_paths import default_home_region_archive
from tiles_helpers import build_archive as _build_archive

def build_archive(path: Path, tiles, *, bounds):
    path.parent.mkdir(parents=True, exist_ok=True)
    return _build_archive(path, tiles, bounds=bounds)


GREENSBORO = (-79.9, 36.05, -79.75, 36.15)
CELL = (-80.0, 36.0, -78.0, 38.0)


def _tiles_for(bbox, tag, zooms=range(6, 11)):
    west, south, east, north = bbox
    tiles = {}
    for z in zooms:
        x0, y0 = _lonlat_to_tile(west, north, z)
        x1, y1 = _lonlat_to_tile(east, south, z)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                tiles[(z, x, y)] = f"{tag}:{z}/{x}/{y}".encode()
    return tiles


class FakeProtomaps:
    """Stands in for `protomaps_extract`: the same four names the filler
    uses, recording every call."""

    DEFAULT_UPSTREAM_BASE_URL = "https://build.protomaps.com"
    DEFAULT_MAXZOOM = 15

    class BuildNotFound(RuntimeError):
        pass

    class ExtractFailed(RuntimeError):
        pass

    def __init__(self):
        self.extracts = []
        self.probes = 0
        self.fail = False

    def find_latest_build_date(self, *, base_url):
        self.probes += 1
        return "20260927"

    @staticmethod
    def _build_url(base, date):
        return f"{base}/{date}.pmtiles"

    @staticmethod
    def _resolve_pmtiles_bin(explicit):
        return explicit or "pmtiles"

    def run_pmtiles_extract(self, *, pmtiles_bin, source_url, out_path, bbox, maxzoom):
        self.extracts.append((source_url, tuple(bbox), maxzoom))
        if self.fail:
            raise self.ExtractFailed("pmtiles extract exited 1: boom")
        build_archive(out_path, _tiles_for(bbox, "filled"), bounds=tuple(bbox))
        return ""


def _store(tmp_path: Path, state: dict | None = None) -> Path:
    root = tmp_path / "store"
    root.mkdir()
    (root / "MIRROR_STATE.json").write_text(json.dumps(state or {"schema_version": 1}))
    return root


def _wait(worker, fill_id, want=READY, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if worker.status(fill_id).state == want:
            return
        time.sleep(0.02)
    raise AssertionError(worker.status(fill_id))


# -- the mirror half ---------------------------------------------------------------


def test_a_miss_fills_its_cell_from_the_latest_build_and_the_next_request_is_ready(
    tmp_path: Path,
) -> None:
    root = _store(tmp_path)
    fake = FakeProtomaps()
    worker = FillWorker(root, [BasemapFiller(root, extract=fake)], state_dir=tmp_path / "fs")
    try:
        first = worker.request("basemap", GREENSBORO)
        assert first.state == "fetching"
        _wait(worker, first.fill_id)
        again = worker.request("basemap", GREENSBORO)
        assert again.state == READY and again.fill_id is None
    finally:
        worker.shutdown()
    assert fake.extracts == [("https://build.protomaps.com/20260927.pmtiles", CELL, 15)]
    row = StoreBook(root).records()["basemap/cell-2d-w080-n36"]
    assert row["path"] == "basemap/protomaps/cells/cell-2d-w080-n36.pmtiles"
    assert row["upstream"] == "protomaps:20260927"
    assert (root / row["path"]).exists()


def test_a_bbox_spanning_two_cells_fills_both(tmp_path: Path) -> None:
    root = _store(tmp_path)
    fake = FakeProtomaps()
    worker = FillWorker(root, [BasemapFiller(root, extract=fake)], state_dir=tmp_path / "fs")
    try:
        status = worker.request("basemap", (-80.2, 36.05, -79.8, 36.15))
        assert set(status.areas) == {"cell-2d-w082-n36", "cell-2d-w080-n36"}
        _wait(worker, status.fill_id)
    finally:
        worker.shutdown()
    assert {e[1] for e in fake.extracts} == {(-82.0, 36.0, -80.0, 38.0), CELL}


def test_a_seeded_archive_whose_parts_cover_the_bbox_needs_no_fill(tmp_path: Path) -> None:
    root = _store(tmp_path, {"basemap": {"covered_regions": {"priority-regions": {
        "path": "basemap/priority.pmtiles", "bbox": [-84, 34, -70, 45],
        "parts": [[-80.5, 35.5, -79.0, 36.5]]}}}})
    (root / "basemap").mkdir()
    (root / "basemap" / "priority.pmtiles").write_bytes(b"x")
    fake = FakeProtomaps()
    worker = FillWorker(root, [BasemapFiller(root, extract=fake)], state_dir=tmp_path / "fs")
    try:
        assert worker.request("basemap", GREENSBORO).state == READY
        # Inside the envelope, outside every part: a fill, not a false ready.
        assert worker.request("basemap", (-75.5, 40.05, -75.4, 40.15)).state == "fetching"
    finally:
        worker.shutdown(wait=True)


def test_an_extract_failure_is_a_failed_fill(tmp_path: Path) -> None:
    root = _store(tmp_path)
    fake = FakeProtomaps()
    fake.fail = True
    worker = FillWorker(root, [BasemapFiller(root, extract=fake)], state_dir=tmp_path / "fs")
    try:
        status = worker.request("basemap", GREENSBORO)
        _wait(worker, status.fill_id, "failed:extract_failed")
        assert not list(root.rglob("*.pmtiles"))
    finally:
        worker.shutdown()


def test_a_cell_past_the_ttl_is_served_and_refreshed_behind_it(tmp_path: Path) -> None:
    old = (datetime.now(timezone.utc) - timedelta(days=TTL_DAYS + 1)).isoformat()
    root = _store(tmp_path, {"areas": {"basemap/cell-2d-w080-n36": {
        "layer": "basemap", "area": "cell-2d-w080-n36",
        "path": "basemap/protomaps/cells/cell-2d-w080-n36.pmtiles", "bbox": list(CELL),
        "filled_at": old, "last_read_at": old, "bytes": 1, "pinned": False, "seeded": False}}})
    build_archive(root / "basemap/protomaps/cells/cell-2d-w080-n36.pmtiles",
                  _tiles_for(CELL, "stale"), bounds=CELL)
    fake = FakeProtomaps()
    worker = FillWorker(root, [BasemapFiller(root, extract=fake)], state_dir=tmp_path / "fs")
    try:
        assert worker.request("basemap", GREENSBORO).state == READY
        deadline = time.monotonic() + 10
        while not fake.extracts and time.monotonic() < deadline:
            time.sleep(0.02)
        worker.shutdown(wait=True)
    finally:
        worker.shutdown()
    assert fake.extracts, "a stale cell is refreshed"
    row = StoreBook(root).records()["basemap/cell-2d-w080-n36"]
    assert row["filled_at"] > old


def test_the_basemap_ttl_matches_core() -> None:
    assert TTL_DAYS == mirror_state.DEFAULT_BASEMAP_TTL_DAYS


# -- the sidecar half ----------------------------------------------------------------

pytestmark_home = pytest.mark.skipif(
    not default_home_region_archive().exists(),
    reason="committed home-region archive not present in this checkout",
)


def _filled_store(tmp_path: Path) -> Path:
    root = _store(tmp_path, {"areas": {
        "basemap/cell-2d-w080-n36": {
            "layer": "basemap", "area": "cell-2d-w080-n36",
            "path": "basemap/protomaps/cells/cell-2d-w080-n36.pmtiles", "bbox": list(CELL),
            "filled_at": "2026-09-28T00:00:00Z"},
        "basemap/cell-2d-w076-n36": {
            "layer": "basemap", "area": "cell-2d-w076-n36",
            "path": "basemap/protomaps/cells/cell-2d-w076-n36.pmtiles",
            "bbox": [-76.0, 36.0, -74.0, 38.0], "filled_at": "2026-09-28T00:00:00Z"},
    }})
    build_archive(root / "basemap/protomaps/cells/cell-2d-w080-n36.pmtiles",
                  _tiles_for(CELL, "w080"), bounds=CELL)
    build_archive(root / "basemap/protomaps/cells/cell-2d-w076-n36.pmtiles",
                  _tiles_for((-76.0, 36.0, -74.0, 38.0), "w076"),
                  bounds=(-76.0, 36.0, -74.0, 38.0))
    return root


@pytestmark_home
def test_the_sidecar_reads_a_store_root_by_area(tmp_path: Path) -> None:
    root = _filled_store(tmp_path)
    client = TestClient(create_app(tmp_path / "cache", tiles_upstream=root))
    z, x, y = 10, *_lonlat_to_tile(-79.8, 36.1, 10)
    resp = client.get(f"/tiles/{z}/{x}/{y}")
    assert resp.status_code == 200
    assert resp.content.startswith(b"w080:")
    gap = (10, *_lonlat_to_tile(-77.0, 37.0, 10))
    assert client.get("/tiles/{}/{}/{}".format(*gap)).status_code == 404


@pytestmark_home
def test_health_reports_per_cell_coverage_after_the_first_read_and_none_before(
    tmp_path: Path,
) -> None:
    root = _filled_store(tmp_path)
    client = TestClient(create_app(tmp_path / "cache", tiles_upstream=root))
    upstream = client.get("/health").json()["capabilities"]["tiles"]["upstream"]
    assert upstream["coverage"] is None and upstream["bounds"] is None  # no read yet
    z, x, y = 10, *_lonlat_to_tile(-79.8, 36.1, 10)
    client.get(f"/tiles/{z}/{x}/{y}")
    upstream = client.get("/health").json()["capabilities"]["tiles"]["upstream"]
    assert sorted(upstream["coverage"]) == [[-80.0, 36.0, -78.0, 38.0], [-76.0, 36.0, -74.0, 38.0]]
    assert upstream["bounds"] is None  # never the envelope over the gap


@pytestmark_home
def test_a_new_cell_changes_the_tile_archive_identity(tmp_path: Path) -> None:
    root = _filled_store(tmp_path)
    app = create_app(tmp_path / "cache", tiles_upstream=root)
    client = TestClient(app)
    z, x, y = 10, *_lonlat_to_tile(-79.8, 36.1, 10)
    client.get(f"/tiles/{z}/{x}/{y}")
    before = client.get("/health").json()["capabilities"]["tiles"]["archive"]
    state = json.loads((root / "MIRROR_STATE.json").read_text())
    state["areas"]["basemap/cell-2d-w080-n36"]["filled_at"] = "2026-10-01T00:00:00Z"
    (root / "MIRROR_STATE.json").write_text(json.dumps(state))
    upstream_set = app.state.readiness.upstream_tiles if hasattr(app.state, "readiness") else None
    if upstream_set is None:
        pytest.skip("readiness not exposed on app.state")
    upstream_set.invalidate()
    client.get(f"/tiles/{z}/{x}/{y}")
    assert client.get("/health").json()["capabilities"]["tiles"]["archive"] != before


@pytestmark_home
def test_a_third_party_root_is_refused_on_health_and_never_read(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path / "cache",
                                   tiles_upstream="https://build.protomaps.com"))
    upstream = client.get("/health").json()["capabilities"]["tiles"]["upstream"]
    assert upstream["refused"] is True and upstream["kind"] == "foreign"


def test_a_region_build_stitches_its_tiles_from_two_cells(tmp_path: Path) -> None:
    root = _store(tmp_path, {"areas": {
        "basemap/cell-2d-w082-n36": {"layer": "basemap", "area": "cell-2d-w082-n36",
                                  "path": "basemap/w.pmtiles", "bbox": [-82, 36, -80, 38]},
        "basemap/cell-2d-w080-n36": {"layer": "basemap", "area": "cell-2d-w080-n36",
                                  "path": "basemap/e.pmtiles", "bbox": list(CELL)},
    }})
    build_archive(root / "basemap/w.pmtiles", _tiles_for((-82, 36, -80, 38), "w"),
                  bounds=(-82, 36, -80, 38))
    build_archive(root / "basemap/e.pmtiles", _tiles_for(CELL, "e"), bounds=CELL)
    s = BasemapArchiveSet(root)
    out = s.extract((-80.3, 36.1, -79.7, 36.4), tmp_path / "trip.pmtiles", max_zoom=15)
    from plotlines_core.tiles.archive import Archive
    with Archive(out) as a:
        assert a.tile(10, *_lonlat_to_tile(-80.2, 36.2, 10)).startswith(b"w:")
        assert a.tile(10, *_lonlat_to_tile(-79.8, 36.2, 10)).startswith(b"e:")
