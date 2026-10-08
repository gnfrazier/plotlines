"""Elevation reuses a covering held area's DEM — epic #641 (ARCH D73),
story #645. No fetch and no FR87 call for a trip inside a held area."""

from __future__ import annotations

import io
from pathlib import Path

import numpy as np
import pytest
import rasterio
from rasterio.transform import from_bounds

from plotlines_core import cache_areas
from plotlines_core.cache_layout import CacheLayout
from plotlines_core.elevation.interface import phase1_resolver_for_layout
from plotlines_core.elevation.keys import (
    LEDGER_FILENAME,
    CallLedger,
    KeyTier,
    OpenTopographyClient,
    OpenTopographyKey,
)
from plotlines_core.elevation.sampler import ElevationSampler

_TRIP_1 = (-82.58, 35.56, -82.52, 35.61)
_TRIP_2 = (-82.583, 35.557, -82.523, 35.607)  # a block south-west


def _dem_bytes(bbox) -> bytes:
    """A real GeoTIFF over `bbox` whose height varies across it."""
    w, s, e, n = bbox
    width, height = 60, 50
    data = (np.arange(width * height, dtype="float32").reshape(1, height, width) + 300.0)
    buf = io.BytesIO()
    with rasterio.MemoryFile() as mem:
        with mem.open(driver="GTiff", width=width, height=height, count=1, dtype="float32",
                      crs="EPSG:4326", transform=from_bounds(w, s, e, n, width, height)) as ds:
            ds.write(data)
        buf.write(mem.read())
    return buf.getvalue()


class _Opener:
    """OpenTopography over no network: answers with a DEM for the bbox in
    the request, and records every request."""

    def __init__(self) -> None:
        self.urls: list[str] = []

    def open(self, url, timeout=None):
        from urllib.parse import parse_qs, urlparse

        self.urls.append(url)
        q = parse_qs(urlparse(url).query)
        bbox = (float(q["west"][0]), float(q["south"][0]),
                float(q["east"][0]), float(q["north"][0]))
        return io.BytesIO(_dem_bytes(bbox))


@pytest.fixture
def wiring(tmp_path):
    key = OpenTopographyKey(token="t", tier=KeyTier.FREE_NON_ACADEMIC)
    ledger = CallLedger(tmp_path / LEDGER_FILENAME,
                        ceiling=key.effective_terms.daily_call_ceiling)
    opener = _Opener()
    client = OpenTopographyClient(key, ledger, opener=opener)
    areas = cache_areas.AreaIndex(tmp_path)
    resolver = phase1_resolver_for_layout(CacheLayout(tmp_path), fetch=client.as_fetcher(),
                                          areas=areas)
    return resolver, ledger, opener, areas


def test_a_first_fetch_asks_for_the_padded_area(wiring):
    resolver, _ledger, opener, areas = wiring
    raster = resolver.resolve(_TRIP_1)
    assert len(opener.urls) == 1
    assert raster.bbox == cache_areas.pad_bbox(_TRIP_1)
    assert areas.resolve(_TRIP_2, cache_areas.PAYLOAD_ELEVATION).path == raster.path


def test_a_second_trip_inside_the_area_makes_no_request_and_no_fr87_call(wiring):
    resolver, ledger, opener, _areas = wiring
    first = resolver.resolve(_TRIP_1)
    calls_after_first = ledger.calls_in_window()

    second = resolver.resolve(_TRIP_2)

    assert len(opener.urls) == 1
    assert ledger.calls_in_window() == calls_after_first == 1
    assert second.source == "local-cache"
    assert second.path == first.path


def test_samples_for_the_second_trip_equal_the_area_dems(wiring):
    resolver, *_ = wiring
    area = resolver.resolve(_TRIP_1)
    trip2 = resolver.sampler_for(_TRIP_2)
    route = [(35.56, -82.58), (35.58, -82.55), (35.60, -82.53)]
    assert np.array_equal(trip2.sample(route), ElevationSampler(area.path).sample(route))


def test_a_held_dem_that_does_not_reach_the_bbox_is_a_miss_not_flat(tmp_path):
    areas = cache_areas.AreaIndex(tmp_path)
    layout = CacheLayout(tmp_path)
    # Recorded as covering the trip, but the raster itself only spans half.
    path = layout.elevation_raster(_TRIP_1)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_dem_bytes((-82.58, 35.56, -82.55, 35.61)))
    areas.register(cache_areas.pad_bbox(_TRIP_1), cache_areas.PAYLOAD_ELEVATION, path)
    resolver = phase1_resolver_for_layout(layout, areas=areas)
    assert resolver.sampler_for(_TRIP_2) is None
