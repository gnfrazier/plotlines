"""Held-area index (ARCH D73, epic #641 stories #643 and #648).

Asserts on resolved paths and on what is left on disk, never on the index's
internals. Every clock is injected; nothing sleeps.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import numpy as np
import osmium
import pytest
import rasterio
from rasterio.transform import from_bounds

from plotlines_core import cache_areas as A
from plotlines_core.cache_layout import CacheLayout
from plotlines_core.graph import regions as region_lib

from tiles_helpers import build_archive

DAY = 86_400.0

# A ~10 km area near Asheville, and boxes relative to it.
AREA = (-82.60, 35.55, -82.50, 35.63)
INSIDE = (-82.58, 35.56, -82.52, 35.61)   # a block or so in from every edge
CROSSING = (-82.55, 35.56, -82.45, 35.61)  # runs past the east edge
SMALL_AREA = (-82.59, 35.555, -82.51, 35.62)


class Clock:
    def __init__(self, t: float = 1_800_000_000.0) -> None:
        self.t = t

    def __call__(self) -> float:
        return self.t

    def advance_days(self, days: float) -> None:
        self.t += days * DAY


def _touch(path: Path, body: bytes = b"x") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body)
    return path


def _set_mtime(path: Path, t: float) -> None:
    os.utime(path, (t, t))


def _write_tif(path: Path, bbox) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    w, s, e, n = bbox
    data = np.full((1, 10, 10), 500.0, dtype="float32")
    with rasterio.open(path, "w", driver="GTiff", width=10, height=10, count=1,
                       dtype="float32", crs="EPSG:4326",
                       transform=from_bounds(w, s, e, n, 10, 10)) as ds:
        ds.write(data)
    return path


def _write_pbf(path: Path, bbox) -> Path:
    header = osmium.io.Header()
    header.add_box(osmium.osm.Box(*bbox))
    path.parent.mkdir(parents=True, exist_ok=True)
    with osmium.SimpleWriter(str(path), header=header) as writer:
        writer.add_node(osmium.osm.mutable.Node(id=1, location=(bbox[0], bbox[1])))
    return path


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def index(tmp_path, clock):
    return A.AreaIndex(tmp_path, clock=clock)


# -- padding (D73) ---------------------------------------------------------- #


def test_pad_bbox_contains_the_trip_and_grows_each_side_within_the_clamp():
    padded = A.pad_bbox(INSIDE)
    assert A.bbox_contains(padded, INSIDE)
    w, h = A._side_m(INSIDE)
    pw, ph = A._side_m(padded)
    grow_x, grow_y = (pw - w) / 2, (ph - h) / 2
    assert A.PAD_MIN_M - 5 <= grow_x <= A.PAD_MAX_M + 5
    assert A.PAD_MIN_M - 5 <= grow_y <= A.PAD_MAX_M + 5


def test_pad_bbox_never_pads_past_the_area_cap():
    # ~29 km square: padding at 10% would push it well past 900 km².
    near_cap = (-82.80, 35.40, -82.48, 35.66)
    w, h = A._side_m(near_cap)
    assert w * h / 1e6 < A.PAD_AREA_CAP_KM2
    padded = A.pad_bbox(near_cap)
    pw, ph = A._side_m(padded)
    assert A.bbox_contains(padded, near_cap)
    assert pw * ph / 1e6 <= A.PAD_AREA_CAP_KM2 * 1.001


def test_pad_bbox_leaves_a_trip_already_over_the_cap_unpadded():
    big = (-83.0, 35.0, -82.0, 36.0)
    assert A.pad_bbox(big) == big


# -- resolve ---------------------------------------------------------------- #


def test_a_bbox_inside_an_area_resolves_to_its_file(index, tmp_path):
    path = _touch(CacheLayout(tmp_path).tile_archive(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, path)
    hit = index.resolve(INSIDE, A.PAYLOAD_BASEMAP)
    assert hit is not None and hit.path == path and not hit.stale
    assert not hit.covers_exactly(INSIDE)
    assert index.resolve(AREA, A.PAYLOAD_BASEMAP).covers_exactly(AREA)


def test_a_bbox_crossing_the_edge_misses(index, tmp_path):
    index.register(AREA, A.PAYLOAD_BASEMAP, _touch(CacheLayout(tmp_path).tile_archive(AREA)))
    assert index.resolve(CROSSING, A.PAYLOAD_BASEMAP) is None


def test_a_payload_the_area_does_not_hold_misses(index, tmp_path):
    index.register(AREA, A.PAYLOAD_BASEMAP, _touch(CacheLayout(tmp_path).tile_archive(AREA)))
    assert index.resolve(INSIDE, A.PAYLOAD_ELEVATION) is None
    assert index.resolve(INSIDE, A.graph_payload("bike")) is None


def test_the_smallest_containing_area_wins(index, tmp_path):
    layout = CacheLayout(tmp_path)
    big, small = _touch(layout.tile_archive(AREA)), _touch(layout.tile_archive(SMALL_AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, big)
    index.register(SMALL_AREA, A.PAYLOAD_BASEMAP, small)
    assert index.resolve(INSIDE, A.PAYLOAD_BASEMAP).path == small


def test_a_fresh_area_beats_a_smaller_stale_one(index, tmp_path, clock):
    layout = CacheLayout(tmp_path)
    small = _touch(layout.tile_archive(SMALL_AREA))
    index.register(SMALL_AREA, A.PAYLOAD_BASEMAP, small)
    clock.advance_days(A.TTL_DAYS[A.PAYLOAD_BASEMAP] + 1)
    big = _touch(layout.tile_archive(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, big)
    assert index.resolve(INSIDE, A.PAYLOAD_BASEMAP).path == big


def test_a_past_ttl_payload_resolves_stale_not_hidden(index, tmp_path, clock):
    path = _touch(CacheLayout(tmp_path).tile_archive(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, path)
    clock.advance_days(A.TTL_DAYS[A.PAYLOAD_BASEMAP] + 0.5)
    hit = index.resolve(INSIDE, A.PAYLOAD_BASEMAP)
    assert hit is not None and hit.stale and hit.path == path
    assert index.resolve(INSIDE, A.PAYLOAD_BASEMAP, allow_stale=False) is None


def test_each_payload_ages_on_its_own_ttl(index, tmp_path, clock):
    layout = CacheLayout(tmp_path)
    index.register(AREA, A.PAYLOAD_BASEMAP, _touch(layout.tile_archive(AREA)))
    index.register(AREA, A.PAYLOAD_ELEVATION, _touch(layout.elevation_raster(AREA)))
    clock.advance_days(40)
    assert index.resolve(INSIDE, A.PAYLOAD_BASEMAP).stale
    assert not index.resolve(INSIDE, A.PAYLOAD_ELEVATION).stale


# -- intersecting (#675) ---------------------------------------------------- #


def test_an_area_crossed_by_a_bbox_intersects_though_it_does_not_resolve(index, tmp_path):
    path = _touch(CacheLayout(tmp_path).tile_archive(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, path)
    assert index.resolve(CROSSING, A.PAYLOAD_BASEMAP) is None
    assert [h.path for h in index.intersecting(CROSSING, A.PAYLOAD_BASEMAP)] == [path]


def test_an_area_only_touching_a_bbox_edge_does_not_intersect(index, tmp_path):
    index.register(AREA, A.PAYLOAD_BASEMAP, _touch(CacheLayout(tmp_path).tile_archive(AREA)))
    east_neighbour = (AREA[2], AREA[1], AREA[2] + 0.1, AREA[3])
    assert index.intersecting(east_neighbour, A.PAYLOAD_BASEMAP) == []
    assert index.intersecting(INSIDE, A.PAYLOAD_ELEVATION) == []


def test_intersecting_ranks_fresh_before_stale_then_smallest(index, tmp_path, clock):
    layout = CacheLayout(tmp_path)
    stale_small = _touch(layout.tile_archive(SMALL_AREA))
    index.register(SMALL_AREA, A.PAYLOAD_BASEMAP, stale_small)
    clock.advance_days(A.TTL_DAYS[A.PAYLOAD_BASEMAP] + 1)
    fresh_big = _touch(layout.tile_archive(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, fresh_big)
    hits = index.intersecting(INSIDE, A.PAYLOAD_BASEMAP)
    assert [h.path for h in hits] == [fresh_big, stale_small]
    assert [h.stale for h in hits] == [False, True]


def test_a_candidate_set_at_another_version_never_resolves(index, tmp_path):
    path = _touch(CacheLayout(tmp_path).candidate_set(AREA))
    index.register(AREA, A.PAYLOAD_CANDIDATES, path, version="old/1.0")
    assert index.resolve(INSIDE, A.PAYLOAD_CANDIDATES, version="new/1.0") is None
    assert index.resolve(INSIDE, A.PAYLOAD_CANDIDATES, version="old/1.0").path == path


# -- persistence and rebuild ------------------------------------------------- #


def test_the_index_survives_a_restart(tmp_path, clock):
    path = _touch(CacheLayout(tmp_path).tile_archive(AREA))
    A.AreaIndex(tmp_path, clock=clock).register(AREA, A.PAYLOAD_BASEMAP, path)
    assert A.AreaIndex(tmp_path, clock=clock).resolve(INSIDE, A.PAYLOAD_BASEMAP).path == path


def _seed_every_payload(root: Path) -> dict[str, Path]:
    layout = CacheLayout(root)
    tiles = build_archive(_touch(layout.tile_archive(AREA)), {(0, 0, 0): b"t"}, bounds=AREA)
    tif = _write_tif(layout.elevation_raster(AREA), AREA)
    pbf = _write_pbf(layout.osm_extract(AREA, "2026-09-01"), AREA)
    cands = _touch(layout.candidate_set(AREA), json.dumps(
        {"layer_set_version": "ls", "ruleset_version": "1.3.0", "bbox": list(AREA),
         "features": []}).encode())
    region = region_lib.region_for(AREA, "bike")
    graph = _touch(region.graph_path(root), b"<graphml/>")
    region.graph_source_path(root).write_text(json.dumps(
        {"transport": "geofabrik", "pin": "2026-09-01", "bbox": list(AREA),
         "network_type": "bike"}))
    return {A.PAYLOAD_BASEMAP: tiles, A.PAYLOAD_ELEVATION: tif, A.PAYLOAD_EXTRACT: pbf,
            A.PAYLOAD_CANDIDATES: cands, A.graph_payload("bike"): graph}


def _resolve_all(index) -> dict[str, Path | None]:
    out = {}
    for name in (A.PAYLOAD_BASEMAP, A.PAYLOAD_ELEVATION, A.PAYLOAD_EXTRACT,
                 A.PAYLOAD_CANDIDATES, A.graph_payload("bike")):
        hit = index.resolve(INSIDE, name)
        out[name] = hit.path if hit else None
    return out


def test_deleting_the_index_rebuilds_it_from_disk_with_nothing_lost(tmp_path, clock):
    files = _seed_every_payload(tmp_path)
    index = A.AreaIndex(tmp_path, clock=clock)
    assert _resolve_all(index) == files
    index.index_path.unlink()
    rebuilt = A.AreaIndex(tmp_path, clock=clock)
    assert _resolve_all(rebuilt) == files
    assert rebuilt.resolve(INSIDE, A.PAYLOAD_EXTRACT).pin == "2026-09-01"
    assert rebuilt.resolve(INSIDE, A.PAYLOAD_CANDIDATES).version == "ls/1.3.0"


@pytest.mark.parametrize("body", [b"{not json", json.dumps({"version": 999, "areas": []}).encode()])
def test_a_corrupt_or_unknown_version_index_is_rebuilt_not_trusted(tmp_path, clock, body):
    files = _seed_every_payload(tmp_path)
    (tmp_path / A.INDEX_FILENAME).write_bytes(body)
    assert _resolve_all(A.AreaIndex(tmp_path, clock=clock)) == files


def test_rebuild_takes_the_file_mtime_as_fetch_time(tmp_path, clock):
    files = _seed_every_payload(tmp_path)
    _set_mtime(files[A.PAYLOAD_BASEMAP], clock() - 31 * DAY)
    index = A.AreaIndex(tmp_path, clock=clock)
    assert index.resolve(INSIDE, A.PAYLOAD_BASEMAP).stale
    assert not index.resolve(INSIDE, A.PAYLOAD_ELEVATION).stale


def test_the_index_holds_no_trip_identity(tmp_path, clock):
    _seed_every_payload(tmp_path)
    index = A.AreaIndex(tmp_path, clock=clock)
    index.set_references([INSIDE])
    index.persist()
    doc = json.loads(index.index_path.read_text())
    assert set(doc) == {"version", "areas"}
    for area in doc["areas"]:
        assert set(area) == {"bbox", "payloads", "last_referenced_at"}
        for payload in area["payloads"].values():
            assert set(payload) <= {"path", "fetched_at", "pin", "version"}


# -- references (#647) ------------------------------------------------------- #


def test_before_the_first_reference_set_every_area_is_referenced(index):
    assert not index.references_known
    assert index.is_referenced(AREA)


def test_references_follow_the_live_trip_bboxes(index, tmp_path):
    index.register(AREA, A.PAYLOAD_BASEMAP, _touch(CacheLayout(tmp_path).tile_archive(AREA)))
    index.set_references([INSIDE, CROSSING])
    assert index.is_referenced(AREA)
    index.set_references([CROSSING])          # the trip inside was deleted
    assert not index.is_referenced(AREA)
    index.set_references([CROSSING, INSIDE])  # …or moved back
    assert index.is_referenced(AREA)


# -- pruning (#648) ---------------------------------------------------------- #


def test_nothing_is_pruned_before_references_are_known(index, tmp_path, clock):
    path = _touch(CacheLayout(tmp_path).tile_archive(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, path)
    clock.advance_days(400)
    assert index.prune() == []
    assert path.exists()


def test_an_unreferenced_area_inside_ttl_is_kept_and_resolvable(index, tmp_path, clock):
    path = _touch(CacheLayout(tmp_path).tile_archive(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, path)
    index.set_references([])
    clock.advance_days(10)
    index.prune()
    assert path.exists() and index.resolve(INSIDE, A.PAYLOAD_BASEMAP).path == path


def test_an_unreferenced_area_past_ttl_is_pruned(index, tmp_path, clock):
    path = _touch(CacheLayout(tmp_path).tile_archive(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, path)
    index.set_references([])
    clock.advance_days(31)
    pruned = index.prune()
    assert [p.path for p in pruned] == [path]
    assert not path.exists() and index.resolve(INSIDE, A.PAYLOAD_BASEMAP) is None


def test_a_referenced_area_ten_times_past_ttl_is_kept(index, tmp_path, clock):
    path = _touch(CacheLayout(tmp_path).tile_archive(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, path)
    index.set_references([INSIDE])
    clock.advance_days(300)
    assert index.prune() == []
    assert index.resolve(INSIDE, A.PAYLOAD_BASEMAP).stale


def test_elevation_outlives_the_basemap_in_the_same_area(index, tmp_path, clock):
    layout = CacheLayout(tmp_path)
    tiles = _touch(layout.tile_archive(AREA))
    tif = _touch(layout.elevation_raster(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, tiles)
    index.register(AREA, A.PAYLOAD_ELEVATION, tif)
    index.set_references([])
    clock.advance_days(60)
    index.prune()
    assert not tiles.exists() and tif.exists()


def test_a_graph_payload_prunes_its_whole_directory(index, tmp_path, clock):
    region = region_lib.region_for(AREA, "bike")
    graph = _touch(region.graph_path(tmp_path))
    region.graph_source_path(tmp_path).write_text("{}")
    index.register(AREA, A.graph_payload("bike"), graph)
    index.set_references([])
    clock.advance_days(46)
    index.prune()
    assert not graph.parent.exists()


def test_a_file_held_open_survives_and_goes_on_a_later_pass(index, tmp_path, clock):
    path = _touch(CacheLayout(tmp_path).tile_archive(AREA))
    index.register(AREA, A.PAYLOAD_BASEMAP, path)
    index.set_references([])
    clock.advance_days(31)
    assert index.prune(in_use=[path]) == []
    assert path.exists()
    assert [p.path for p in index.prune()] == [path]


def test_a_version_mismatched_candidate_set_is_pruned_whatever_its_references(
        index, tmp_path):
    path = _touch(CacheLayout(tmp_path).candidate_set(AREA))
    index.register(AREA, A.PAYLOAD_CANDIDATES, path, version="old/1")
    index.set_references([INSIDE])
    index.prune(current_versions={A.PAYLOAD_CANDIDATES: "new/1"})
    assert not path.exists()


def test_an_unindexed_file_past_ttl_by_mtime_is_pruned(index, tmp_path, clock):
    stray = _touch(tmp_path / "tiles" / "deadbeefdeadbeef.pmtiles", b"not an archive")
    _set_mtime(stray, clock() - 31 * DAY)
    young = _touch(tmp_path / "tiles" / "0123456789abcdef.pmtiles", b"not an archive")
    _set_mtime(young, clock() - 1 * DAY)
    part = _touch(tmp_path / "tiles" / ".x.pmtiles.part")
    _set_mtime(part, clock() - 99 * DAY)
    index.set_references([])
    index.prune()
    assert not stray.exists() and young.exists() and part.exists()


def test_an_old_pin_directory_goes_once_its_last_extract_is_replaced(index, tmp_path, clock):
    layout = CacheLayout(tmp_path)
    old = _write_pbf(layout.osm_extract(AREA, "2026-08-01"), AREA)
    index.register(AREA, A.PAYLOAD_EXTRACT, old, pin="2026-08-01")
    index.set_references([INSIDE])
    index.prune()
    assert old.exists()  # still the extract this area's graph came from
    new = _write_pbf(layout.osm_extract(AREA, "2026-09-01"), AREA)
    old.unlink()          # a refresh replaces the file…
    index.register(AREA, A.PAYLOAD_EXTRACT, new, pin="2026-09-01")
    index.prune()
    assert not old.parent.exists() and new.exists()


# -- migration (#648) -------------------------------------------------------- #


def test_upgrading_a_pre_epic_cache_loses_nothing_a_live_trip_uses(tmp_path, clock):
    # Pre-epic: one trip's files keyed on its own bbox, graph with no extent
    # in its source.json, and no index at all.
    layout = CacheLayout(tmp_path)
    tiles = build_archive(_touch(layout.tile_archive(INSIDE)), {(0, 0, 0): b"t"}, bounds=INSIDE)
    tif = _write_tif(layout.elevation_raster(INSIDE), INSIDE)
    region = region_lib.region_for(INSIDE, "walk")
    graph = _touch(region.graph_path(tmp_path), b"<graphml/>")
    region.graph_source_path(tmp_path).write_text(json.dumps({"transport": "geofabrik", "pin": "p1"}))
    for p in (tiles, tif, graph, graph.parent):
        _set_mtime(p, clock() - 200 * DAY)

    index = A.AreaIndex(tmp_path, clock=clock)
    index.set_references([INSIDE])
    index.adopt_exact(INSIDE)
    index.prune()
    assert index.resolve(INSIDE, A.graph_payload("walk")).path == graph
    assert index.resolve(INSIDE, A.PAYLOAD_BASEMAP).path == tiles
    assert index.resolve(INSIDE, A.PAYLOAD_ELEVATION).path == tif
    on_disk = {p.resolve() for p in tmp_path.rglob("*")
               if p.is_file() and p.name not in (A.INDEX_FILENAME, "source.json")}
    assert on_disk <= index.indexed_paths()
