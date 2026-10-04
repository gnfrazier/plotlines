"""Issue #627 — a solved passage carries the per-point elevation its profile
chart draws.

`ElevationSampler.profile` reported only ascent/descent/min/max, so every
passage's ELEVATION block read "No elevation profile for this passage yet."
These pin `elevation.samples` on both response families — point_to_point
(`routing/solve.py`) and the loop shapes (`app.py`'s loop response) — as
index-aligned with `coordinates`, which is the contract the client's
`Elevation.samples` documents.

Routes against `conftest.py`'s `boulder_region` with a synthetic DEM over the
Boulder bbox injected as the region's sampler, so nothing touches the network.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest
import rasterio
from rasterio.transform import from_origin

from plotlines_core.elevation.sampler import ElevationSampler

#: `conftest.BOULDER_BBOX` — the extent the `boulder_region` fixture builds.
_BOULDER_BBOX = (-105.30, 39.99, -105.25, 40.03)
_START = {"lat": 40.0175, "lon": -105.2797}
_END = {"lat": 40.02, "lon": -105.275}


def _boulder_dem(path: Path) -> Path:
    """A west-to-east ramp over the Boulder bbox, so every route has relief."""
    west, south, east, north = _BOULDER_BBOX
    width, height = 50, 40
    data = np.tile(np.linspace(1600.0, 1800.0, width, dtype="float32"), (height, 1))
    with rasterio.open(path, "w", driver="GTiff", height=height, width=width, count=1,
                       dtype="float32", crs="EPSG:4326",
                       transform=from_origin(west, north, (east - west) / width,
                                             (north - south) / height),
                       nodata=-9999.0) as ds:
        ds.write(data, 1)
    return path


@pytest.fixture
def boulder_with_elevation(boulder_region, tmp_path):
    client, key = boulder_region
    # `boulder_region` returns at the ready flip, before the build's own
    # elevation phase runs and sets `sampler` (to None here, with no source
    # configured) — join it first, or it overwrites this one (#466's race).
    client.app.state.readiness._build_pool.shutdown(wait=True)
    region = client.app.state.readiness.region(key)
    region.sampler = ElevationSampler(_boulder_dem(tmp_path / "boulder_dem.tif"))
    return client, key


def _assert_samples_align(body: dict) -> None:
    elevation = body["elevation"]
    samples = elevation["samples"]
    assert len(samples) == len(body["coordinates"])
    assert all(np.isfinite(samples))
    assert min(samples) == pytest.approx(elevation["min_m"])
    assert max(samples) == pytest.approx(elevation["max_m"])
    assert elevation["void_samples"] == 0


def test_point_to_point_carries_index_aligned_samples(boulder_with_elevation) -> None:
    client, key = boulder_with_elevation
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END,
        "shape": "point_to_point", "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    _assert_samples_align(resp.json())


def test_loop_carries_index_aligned_samples(boulder_with_elevation) -> None:
    client, key = boulder_with_elevation
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "target_m": 2500.0,
        "shape": "loop", "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    _assert_samples_align(resp.json())


def test_no_sampler_still_reports_elevation_absent(boulder_region) -> None:
    # #473/#533 unchanged: no source is `{}`, never an empty samples list.
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END,
        "shape": "point_to_point", "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    assert resp.json()["elevation"] == {}
