"""Unit tests for `GET /geocode`'s bbox field (issue #154).

Pre-#154, `/geocode` discarded the bounding geometry `ox.geocode_to_gdf`
already returns, leaving the trip-area draw map nothing to frame itself on
but a point. `osmnx.geocode_to_gdf` makes a live Nominatim call, so every
test here monkeypatches it with a fake GeoDataFrame instead.
"""

from __future__ import annotations

from pathlib import Path

import geopandas as gpd
import osmnx as ox
import pytest
from fastapi.testclient import TestClient
from shapely.geometry import Point

from plotlines_service.app import create_app


def _fake_gdf(*_args, **_kwargs) -> gpd.GeoDataFrame:
    return gpd.GeoDataFrame({
        "display_name": ["Asheville, Buncombe County, North Carolina, United States"],
        "lon": [-82.5515],
        "lat": [35.5951],
        "bbox_west": [-82.83],
        "bbox_south": [35.36],
        "bbox_east": [-82.14],
        "bbox_north": [35.79],
        "geometry": [Point(-82.5515, 35.5951)],
    })


@pytest.fixture(autouse=True)
def _fake_nominatim(monkeypatch):
    monkeypatch.setattr(ox, "geocode_to_gdf", _fake_gdf)


def test_geocode_result_carries_bbox_alongside_coord(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    resp = client.get("/geocode", params={"q": "Asheville, NC"})
    assert resp.status_code == 200
    result = resp.json()["results"][0]
    assert result["coord"] == [-82.5515, 35.5951]
    assert result["bbox"] == [-82.83, 35.36, -82.14, 35.79]


def test_geocode_rejects_an_empty_query(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    resp = client.get("/geocode", params={"q": "   "})
    assert resp.status_code == 422


def test_create_app_stamps_a_contactable_nominatim_user_agent(tmp_path: Path) -> None:
    """Issue #241 / addendum P2: `/geocode` hits public Nominatim, whose
    usage policy names a stock library UA as explicitly insufficient.
    `create_app` sets `ox.settings.http_user_agent`/`http_referer` to the
    Plotlines identity — carrying the real build version — before the app
    can serve a request.
    """
    from plotlines_core.osm_identity import osm_user_agent
    from plotlines_service.version import VERSION

    ox.settings.http_user_agent = "OSMnx Python package (https://github.com/gboeing/osmnx)"
    ox.settings.http_referer = "OSMnx Python package (https://github.com/gboeing/osmnx)"

    create_app(tmp_path)

    assert ox.settings.http_user_agent == osm_user_agent(VERSION)
    assert ox.settings.http_referer == osm_user_agent(VERSION)
    assert VERSION in ox.settings.http_user_agent


def test_create_app_points_the_osm_response_cache_inside_the_cache_root(
    tmp_path: Path,
) -> None:
    """Issue #242: `configure_overpass_cache` was only reached inside
    `ensure_graph`, past its warm-cache early return — so `/candidates` and
    `/geocode`, which never call `ensure_graph`, ran with
    `ox.settings.cache_folder` at its CWD-relative `./cache` default and
    littered stray responses there (issue #154). `create_app` now configures
    it at the factory, before any endpoint runs and without `ensure_graph`
    in the process at all.
    """
    ox.settings.cache_folder = "./cache"
    ox.settings.use_cache = False

    create_app(tmp_path)

    assert ox.settings.cache_folder == str(tmp_path / "overpass")
    assert Path(ox.settings.cache_folder).is_absolute()
    assert ox.settings.use_cache is True
