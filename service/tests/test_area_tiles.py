"""Basemap tiles from a covering held area's archive — epic #641 (ARCH
D73), story #646. The second trip inside a held area extracts nothing, its
`/tiles` answer from the area's archive (a little past its own bbox too),
and both trips share one `tiles.archive` fingerprint."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core import cache_areas
from plotlines_core.cache_layout import CacheLayout
from plotlines_core.tiles.extract import _lonlat_to_tile
from plotlines_service import app as app_mod
from plotlines_service.app import create_app
from tiles_helpers import build_archive

_TRIP_1 = (-105.30, 39.99, -105.25, 40.03)
_TRIP_2 = (-105.304, 39.987, -105.254, 40.027)
_Z = 18


def _tiles_over(bbox) -> dict[tuple[int, int, int], bytes]:
    w, s, e, n = bbox
    x0, y0 = _lonlat_to_tile(w, n, _Z)
    x1, y1 = _lonlat_to_tile(e, s, _Z)
    return {(_Z, x, y): f"{x}/{y}".encode()
            for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)}


@pytest.fixture
def extracts(monkeypatch, tmp_path):
    """`extract_bbox` writing a real archive over the asked bbox; records
    every call."""
    calls: list[tuple] = []

    def fake_extract(upstream, box, out_path, *, allow_unmirrored=False,
                     max_zoom=None, stats=None):
        calls.append(tuple(box))
        out_path.parent.mkdir(parents=True, exist_ok=True)
        build_archive(out_path, _tiles_over(box), bounds=tuple(box))
        return out_path

    monkeypatch.setattr(app_mod, "extract_bbox", fake_extract)
    monkeypatch.setattr(app_mod.region_lib, "ensure_graph",
                        lambda region, cache_dir: region.graph_path(cache_dir))
    monkeypatch.setattr(app_mod, "load_graphml", lambda path: object())
    monkeypatch.setattr(app_mod.region_lib, "trip_graph_extent", lambda trip, area: None)
    return calls


def _settle(client: TestClient) -> None:
    readiness = client.app.state.readiness
    readiness._build_pool.shutdown(wait=True)
    readiness._build_pool = ThreadPoolExecutor(max_workers=1)


def _fingerprint(client) -> str:
    return client.get("/health").json()["capabilities"]["tiles"]["archive"]


def test_a_second_trip_inside_a_held_area_extracts_nothing(tmp_path, extracts):
    client = TestClient(create_app(tmp_path, tiles_upstream=tmp_path / "upstream.pmtiles",
                                   allow_unmirrored_tiles=True))
    k1 = client.post("/regions", json={"bbox": list(_TRIP_1)}).json()["region"]
    _settle(client)
    area = cache_areas.pad_bbox(_TRIP_1)
    assert extracts == [area]
    first_fingerprint = _fingerprint(client)

    k2 = client.post("/regions", json={"bbox": list(_TRIP_2)}).json()["region"]
    _settle(client)

    assert extracts == [area]
    readiness = client.app.state.readiness
    archive = CacheLayout(tmp_path).tile_archive(area)
    assert readiness.region(k1).tiles_archive.path == archive
    assert readiness.region(k2).tiles_archive.path == archive
    # One area, one archive: the fingerprint did not move.
    assert _fingerprint(client) == first_fingerprint
    assert list((tmp_path / "tiles").glob("*.pmtiles")) == [archive]


def test_tiles_just_past_the_trip_bbox_but_inside_the_area_still_answer(tmp_path, extracts):
    client = TestClient(create_app(tmp_path, tiles_upstream=tmp_path / "upstream.pmtiles",
                                   allow_unmirrored_tiles=True))
    client.post("/regions", json={"bbox": list(_TRIP_1)})
    _settle(client)
    client.post("/regions", json={"bbox": list(_TRIP_2)})
    _settle(client)
    area = cache_areas.pad_bbox(_TRIP_1)
    # A point in the area's west margin, west of trip 2's own bbox.
    x, y = _lonlat_to_tile(area[0] + 0.0002, 40.0, _Z)
    assert x < _lonlat_to_tile(_TRIP_2[0], 40.0, _Z)[0]
    resp = client.get(f"/tiles/{_Z}/{x}/{y}")
    assert resp.status_code == 200
    assert resp.content == f"{x}/{y}".encode()
