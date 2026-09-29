"""The basemap as a set of archives found by area — issue #519.

Synthetic cell archives on local disk under a store root with a
`MIRROR_STATE.json` record, the way the mirror lays them out. Each tile's
payload names the archive it came from, so "which archive answered" is a
plain equality check.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from plotlines_core.tiles.archive import Archive
from plotlines_core.tiles.basemap_set import (
    BasemapArchiveSet,
    RecordUnavailable,
    archives_from_state,
    is_archive_root,
)
from plotlines_core.tiles.extract import NoTilesInBbox, _lonlat_to_tile
from plotlines_core.tiles.mirror import HotlinkRefused
from tiles_helpers import build_archive

WEST_CELL = (-82.0, 34.0, -80.0, 36.0)
EAST_CELL = (-80.0, 34.0, -78.0, 36.0)
FAR_CELL = (-76.0, 34.0, -74.0, 36.0)
ZOOMS = range(6, 9)


def _tiles_for(bbox, tag: str) -> dict:
    west, south, east, north = bbox
    tiles = {}
    for z in ZOOMS:
        x0, y0 = _lonlat_to_tile(west, north, z)
        x1, y1 = _lonlat_to_tile(east, south, z)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                tiles[(z, x, y)] = f"{tag}:{z}/{x}/{y}".encode()
    return tiles


def _row(area, path, bbox, **extra):
    return {"layer": "basemap", "area": area, "path": path, "bbox": list(bbox),
            "filled_at": "2026-09-28T00:00:00Z", **extra}


@pytest.fixture
def store(tmp_path: Path) -> Path:
    root = tmp_path / "store"
    for name, bbox in (("cell-w082-n34", WEST_CELL), ("cell-w080-n34", EAST_CELL),
                       ("cell-w076-n34", FAR_CELL)):
        path = root / "basemap" / "protomaps" / "cells" / f"{name}.pmtiles"
        path.parent.mkdir(parents=True, exist_ok=True)
        build_archive(path, _tiles_for(bbox, name), bounds=bbox)
    (root / "MIRROR_STATE.json").write_text(json.dumps({"areas": {
        f"basemap/{name}": _row(name, f"basemap/protomaps/cells/{name}.pmtiles", bbox)
        for name, bbox in (("cell-w082-n34", WEST_CELL), ("cell-w080-n34", EAST_CELL),
                           ("cell-w076-n34", FAR_CELL))
    }}))
    return root


def _tile_at(lon, lat, z=8):
    return (z, *_lonlat_to_tile(lon, lat, z))


def test_a_root_is_anything_but_a_pmtiles_file() -> None:
    assert is_archive_root("https://tiles.plotlines.app")
    assert is_archive_root("/srv/plotlines-mirror")
    assert not is_archive_root("https://tiles.plotlines.app/basemap/x/corridor.pmtiles")


def test_constructing_the_set_and_reading_health_facts_make_no_request(store) -> None:
    calls = []

    def fetch():
        calls.append(1)
        return json.loads((store / "MIRROR_STATE.json").read_text())

    s = BasemapArchiveSet(store, fetch_record=fetch)
    assert s.coverage() is None
    s.identity()
    assert calls == []  # D41/D57: /health reads these and must not reach out


def test_each_tile_comes_from_the_cell_it_sits_in(store) -> None:
    s = BasemapArchiveSet(store)
    assert s.tile(*_tile_at(-81.0, 35.0)).startswith(b"cell-w082-n34:")
    assert s.tile(*_tile_at(-79.0, 35.0)).startswith(b"cell-w080-n34:")


def test_a_tile_in_the_gap_between_cells_is_an_honest_miss(store) -> None:
    s = BasemapArchiveSet(store)
    # z10 tiles are ~0.35° wide, so this one sits wholly inside the 2° gap.
    assert s.tile(*_tile_at(-77.0, 35.0, z=10)) is None
    data, info = s.read_tile(*_tile_at(-77.0, 35.0, z=10))
    assert data is None and info is None


def test_coverage_is_one_rectangle_per_part_once_read(store) -> None:
    s = BasemapArchiveSet(store)
    s.archives()
    assert sorted(s.coverage()) == sorted([list(WEST_CELL), list(EAST_CELL), list(FAR_CELL)])


def test_a_multi_area_archive_covers_its_parts_not_its_envelope(tmp_path: Path) -> None:
    """#515's priority archive: the envelope spans the gap, the parts don't."""
    root = tmp_path / "store"
    path = root / "basemap" / "priority.pmtiles"
    path.parent.mkdir(parents=True)
    build_archive(path, {**_tiles_for(WEST_CELL, "p"), **_tiles_for(FAR_CELL, "p")},
                  bounds=(-82.0, 34.0, -74.0, 36.0))
    (root / "MIRROR_STATE.json").write_text(json.dumps({"basemap": {"covered_regions": {
        "priority-regions": {"path": "basemap/priority.pmtiles", "bbox": [-82, 34, -74, 36],
                             "parts": [list(WEST_CELL), list(FAR_CELL)]}}}}))
    s = BasemapArchiveSet(root)
    assert s.archive_for(*_tile_at(-81.0, 35.0)) is not None
    assert s.archive_for(*_tile_at(-78.0, 35.0)) is None
    assert s.coverage() == [list(WEST_CELL), list(FAR_CELL)]


def test_a_record_without_areas_rows_is_read_from_covered_regions(store) -> None:
    state = {"basemap": {"covered_regions": {"wnc": {
        "path": "basemap/wnc.pmtiles", "bbox": [-83.6, 35.2, -81.0, 36.4],
        "extracted_at": "2026-09-21T00:00:00Z"}}}}
    [archive] = archives_from_state(state)
    assert archive.path == "basemap/wnc.pmtiles"
    assert archive.parts == ((-83.6, 35.2, -81.0, 36.4),)


def test_a_bbox_spanning_two_cells_extracts_from_both_without_a_seam(store, tmp_path) -> None:
    s = BasemapArchiveSet(store)
    bbox = (-80.5, 34.5, -79.5, 35.5)  # straddles -80.0
    out = s.extract(bbox, tmp_path / "trip.pmtiles")
    with Archive(out) as archive:
        west = archive.tile(*_tile_at(-80.3, 35.0))
        east = archive.tile(*_tile_at(-79.7, 35.0))
        assert west is not None and west.startswith(b"cell-w082-n34:")
        assert east is not None and east.startswith(b"cell-w080-n34:")
        # Every address the bbox touches is present — a tile on the cell
        # line came from one side or the other, never neither.
        for z in ZOOMS:
            x0, y0 = _lonlat_to_tile(bbox[0], bbox[3], z)
            x1, y1 = _lonlat_to_tile(bbox[2], bbox[1], z)
            for x in range(x0, x1 + 1):
                for y in range(y0, y1 + 1):
                    assert archive.tile(z, x, y) is not None, (z, x, y)


def test_a_bbox_no_archive_reaches_raises_no_tiles(store, tmp_path) -> None:
    with pytest.raises(NoTilesInBbox):
        BasemapArchiveSet(store).extract((-77.5, 34.5, -76.5, 35.5), tmp_path / "x.pmtiles")


def test_missing_cells_names_the_squares_to_fill(store) -> None:
    s = BasemapArchiveSet(store)
    assert s.missing_cells((-79.5, 34.5, -77.0, 35.5)) == [(-78.0, 34.0, -76.0, 36.0)]
    assert s.missing_cells((-81.5, 34.5, -79.5, 35.5)) == []


def test_a_third_party_root_is_refused_before_any_byte(tmp_path) -> None:
    with pytest.raises(HotlinkRefused):
        BasemapArchiveSet("https://build.protomaps.com/")


def test_a_failed_record_read_is_transient_and_keeps_the_last_good_list(store) -> None:
    good = json.loads((store / "MIRROR_STATE.json").read_text())
    answers = [good, OSError("mirror down")]
    clock = {"t": 0.0}

    def fetch():
        answer = answers.pop(0) if answers else OSError("still down")
        if isinstance(answer, Exception):
            raise answer
        return answer

    s = BasemapArchiveSet(store, fetch_record=fetch, clock=lambda: clock["t"], ttl_s=10)
    assert len(s.archives()) == 3
    clock["t"] = 11
    assert len(s.archives()) == 3  # the read failed; the last good list serves

    fresh = BasemapArchiveSet(store, fetch_record=lambda: (_ for _ in ()).throw(OSError("x")))
    with pytest.raises(RecordUnavailable):
        fresh.archives()


def test_the_identity_moves_when_a_cell_is_filled(store) -> None:
    s = BasemapArchiveSet(store)
    s.archives()
    before = s.identity()
    state = json.loads((store / "MIRROR_STATE.json").read_text())
    state["areas"]["basemap/cell-w080-n34"]["filled_at"] = "2026-10-01T00:00:00Z"
    (store / "MIRROR_STATE.json").write_text(json.dumps(state))
    s.invalidate()
    s.archives()
    assert s.identity() != before
