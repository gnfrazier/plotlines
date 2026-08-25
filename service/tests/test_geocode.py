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
