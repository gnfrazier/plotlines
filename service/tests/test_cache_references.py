"""Live-trip references and retention — epic #641 (ARCH D73), stories
#647 and #648. The client sends the full set of live trips' bboxes; the
sidecar marks held areas referenced or not, and prunes only what no live
trip needs once it is past its TTL."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core import cache_areas
from plotlines_core.cache_layout import CacheLayout
from plotlines_service.app import Readiness, create_app
from tiles_helpers import build_archive

DAY = 86_400.0
_AREA = (-82.60, 35.55, -82.50, 35.63)
_TRIP_A = (-82.58, 35.56, -82.52, 35.61)   # inside the area
_TRIP_B = (-82.57, 35.57, -82.53, 35.60)   # also inside
_ELSEWHERE = (-80.00, 36.00, -79.90, 36.10)


class Clock:
    def __init__(self) -> None:
        self.t = 1_800_000_000.0

    def __call__(self) -> float:
        return self.t


def _seed_area(root: Path, index: cache_areas.AreaIndex) -> Path:
    path = CacheLayout(root).tile_archive(_AREA)
    path.parent.mkdir(parents=True, exist_ok=True)
    build_archive(path, {(0, 0, 0): b"t"}, bounds=_AREA)
    index.register(_AREA, cache_areas.PAYLOAD_BASEMAP, path)
    return path


def _drain(state: Readiness) -> None:
    state._area_cache_pool.submit(lambda: None).result(timeout=10)


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def state(tmp_path, clock):
    index = cache_areas.AreaIndex(tmp_path, clock=clock)
    readiness = Readiness(tmp_path, tmp_path / "home.pmtiles", area_index=index)
    yield readiness
    readiness.shutdown()


def test_before_the_first_set_no_area_is_unreferenced(state, tmp_path):
    _seed_area(tmp_path, state.areas)
    assert state.areas.is_referenced(_AREA)


def test_deleting_the_only_trip_in_an_area_unreferences_it(state, tmp_path):
    _seed_area(tmp_path, state.areas)
    state.set_cache_references([_TRIP_A, _ELSEWHERE])
    assert state.areas.is_referenced(_AREA)
    state.set_cache_references([_ELSEWHERE])
    assert not state.areas.is_referenced(_AREA)


def test_deleting_one_of_two_trips_in_an_area_leaves_it_referenced(state, tmp_path):
    _seed_area(tmp_path, state.areas)
    state.set_cache_references([_TRIP_A, _TRIP_B])
    state.set_cache_references([_TRIP_B])
    assert state.areas.is_referenced(_AREA)


def test_moving_a_bbox_out_and_back(state, tmp_path):
    _seed_area(tmp_path, state.areas)
    state.set_cache_references([_TRIP_A])
    state.set_cache_references([_ELSEWHERE])
    assert not state.areas.is_referenced(_AREA)
    state.set_cache_references([_TRIP_A])
    assert state.areas.is_referenced(_AREA)


def test_a_restarted_sidecar_gets_a_missed_delete_right_from_the_next_set(tmp_path, clock):
    first = Readiness(tmp_path, tmp_path / "home.pmtiles",
                      area_index=cache_areas.AreaIndex(tmp_path, clock=clock))
    _seed_area(tmp_path, first.areas)
    first.set_cache_references([_TRIP_A])
    _drain(first)
    first.shutdown()
    # The trip is deleted while the sidecar is down; the next start's first
    # set is the truth.
    second = Readiness(tmp_path, tmp_path / "home.pmtiles",
                       area_index=cache_areas.AreaIndex(tmp_path, clock=clock))
    assert second.areas.is_referenced(_AREA)  # nothing known yet
    second.set_cache_references([])
    assert not second.areas.is_referenced(_AREA)
    second.shutdown()


def test_the_request_and_the_index_carry_no_trip_id_or_name(tmp_path):
    client = TestClient(create_app(tmp_path))
    body = {"bboxes": [list(_TRIP_A)]}
    resp = client.put("/cache/references", json=body)
    assert resp.status_code == 200
    assert set(body) == {"bboxes"}
    state = client.app.state.readiness
    _seed_area(tmp_path, state.areas)
    _drain(state)
    state.areas.persist()
    raw = state.areas.index_path.read_bytes()
    for forbidden in (b"trip", b"title", b"name", b"author", b"id\""):
        assert forbidden not in raw.lower()


def test_a_malformed_bbox_is_a_422(tmp_path):
    client = TestClient(create_app(tmp_path))
    assert client.put("/cache/references", json={"bboxes": [[1, 2, 3]]}).status_code == 422
    assert client.put("/cache/references",
                      json={"bboxes": [[3, 0, 1, 1]]}).status_code == 422


# -- retention (#648) -------------------------------------------------------- #


def test_the_first_set_prunes_an_unreferenced_past_ttl_area(state, tmp_path, clock):
    path = _seed_area(tmp_path, state.areas)
    clock.t += 31 * DAY
    state.set_cache_references([_ELSEWHERE])
    _drain(state)
    assert not path.exists()
    assert state.areas.resolve(_TRIP_A, cache_areas.PAYLOAD_BASEMAP) is None


def test_a_referenced_area_far_past_ttl_is_kept(state, tmp_path, clock):
    path = _seed_area(tmp_path, state.areas)
    clock.t += 300 * DAY
    state.set_cache_references([_TRIP_A])
    _drain(state)
    assert path.exists()


def test_an_archive_an_open_region_is_reading_survives_the_pass(state, tmp_path, clock):
    path = _seed_area(tmp_path, state.areas)
    key = state.ensure_region(_TRIP_A, "bike")
    region = state.region(key)
    assert region.tiles_archive is not None and region.tiles_archive.path == path
    state.areas.set_references([_ELSEWHERE])
    clock.t += 31 * DAY
    state.prune_cache()
    assert path.exists()
