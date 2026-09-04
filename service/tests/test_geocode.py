"""Unit tests for `GET /geocode`'s bbox field (issue #154).

Pre-#154, `/geocode` discarded the bounding geometry `ox.geocode_to_gdf`
already returns, leaving the trip-area draw map nothing to frame itself on
but a point. `osmnx.geocode_to_gdf` makes a live Nominatim call, so every
test here monkeypatches it with a fake GeoDataFrame instead.
"""

from __future__ import annotations

import threading
import time
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


# ── Issue #249 — audit /geocode against the Nominatim usage policy ────────


def test_geocode_serialises_nominatim_calls_under_concurrent_requests(
    tmp_path: Path, monkeypatch,
) -> None:
    """The policy caps this at "an absolute maximum of 1 request per
    second". osmnx's own `pause = 1` (`osmnx/_nominatim.py`) sleeps inside
    whichever thread calls it, with no state shared across threads — so two
    `/geocode` requests FastAPI schedules on threadpool siblings at the same
    instant each independently wait ~1s and then fire together, exceeding
    the policy with no error. `nominatim_rate_limit` (`osm_identity.py`)
    closes that: this drives four concurrent requests at a shrunk interval
    and asserts neither Nominatim call ever overlaps nor starts sooner than
    the interval after the previous one finished.
    """
    from plotlines_core import osm_identity

    monkeypatch.setattr(osm_identity, "NOMINATIM_MIN_INTERVAL_S", 0.2)

    lock = threading.Lock()
    in_flight = 0
    max_in_flight = 0
    starts: list[float] = []

    def _tracking_gdf(*args, **kwargs):
        nonlocal in_flight, max_in_flight
        with lock:
            in_flight += 1
            max_in_flight = max(max_in_flight, in_flight)
            starts.append(time.monotonic())
        time.sleep(0.05)  # stand-in for a real network round trip
        with lock:
            in_flight -= 1
        return _fake_gdf(*args, **kwargs)

    monkeypatch.setattr(ox, "geocode_to_gdf", _tracking_gdf)

    client = TestClient(create_app(tmp_path))
    statuses: list[int] = []
    statuses_lock = threading.Lock()

    def _call() -> None:
        resp = client.get("/geocode", params={"q": "Asheville, NC"})
        with statuses_lock:
            statuses.append(resp.status_code)

    threads = [threading.Thread(target=_call) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=10)

    assert statuses == [200] * 4
    assert len(starts) == 4
    # The lock around `_tracking_gdf` means this is never >1 regardless of
    # timing — it is the direct "no bulk / no overlap" assertion.
    assert max_in_flight == 1

    starts.sort()
    gaps = [b - a for a, b in zip(starts, starts[1:])]
    assert all(gap >= osm_identity.NOMINATIM_MIN_INTERVAL_S - 0.03 for gap in gaps), gaps


def test_geocode_nominatim_responses_land_in_the_plotlines_cache_root(
    tmp_path: Path, monkeypatch,
) -> None:
    """The policy asks that results be cached rather than re-queried.
    `/geocode` never calls `ensure_graph`, so before #242 it inherited
    `ox.settings.cache_folder`'s CWD-relative `./cache` default; `create_app`
    now calls `configure_overpass_cache` before serving anything. This drops
    one layer below this file's usual `ox.geocode_to_gdf` fake to exercise
    osmnx's actual Nominatim cache read/write (`osmnx._nominatim`,
    `osmnx._http`) and confirms a response lands under the Plotlines cache
    root and a repeat query is served from it rather than re-requested.
    """
    import osmnx._nominatim as ox_nominatim

    create_app(tmp_path)
    monkeypatch.setattr(ox_nominatim.time, "sleep", lambda _s: None)

    class _FakeResponse:
        status_code = 200
        ok = True
        reason = "OK"
        url = "https://nominatim.openstreetmap.org/search"
        content = b"[]"

        def json(self) -> list:
            return []

    calls: list[str] = []

    def _fake_get(url, **_kwargs):
        calls.append(url)
        return _FakeResponse()

    monkeypatch.setattr(ox_nominatim.requests, "get", _fake_get)

    ox_nominatim._download_nominatim_element("Asheville, NC")

    cache_dir = Path(ox.settings.cache_folder)
    assert cache_dir == tmp_path / "overpass"
    cache_files = list(cache_dir.glob("*.json"))
    assert len(cache_files) == 1
    assert len(calls) == 1

    # A repeat of the same query is served from the cache, not re-requested.
    ox_nominatim._download_nominatim_element("Asheville, NC")
    assert len(calls) == 1
