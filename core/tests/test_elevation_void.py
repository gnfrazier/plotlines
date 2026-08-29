"""M10 (issue #138, FR85/FR88) — one licensed elevation source, no fallback, and
an explicit void/nodata/NaN policy.

`plotlines_core.elevation.void` + `ElevationSampler`: `nodata`, NaN `nodata`
(checked via `isnan`), out-of-bounds coordinates, and a missing/unreadable
raster all resolve to `0.0`, each logged at most once per raster path; and a
solve does no network I/O.
"""

from __future__ import annotations

import logging
import socket

import numpy as np
import pytest
import rasterio
from rasterio.transform import from_origin

from plotlines_core.elevation.sampler import ElevationSampler
from plotlines_core.elevation.void import VOID_FILL, VoidLog, resolve_voids


# --------------------------------------------------------------------------- #
# helpers                                                                     #
# --------------------------------------------------------------------------- #

# A 4x4 raster covering lon [10, 14), lat (46, 50], 1-degree pixels.
_ORIGIN_LON, _ORIGIN_LAT = 10.0, 50.0
_PIXEL = 1.0
_TRANSFORM = from_origin(_ORIGIN_LON, _ORIGIN_LAT, _PIXEL, _PIXEL)


def _write_dem(path, data: np.ndarray, nodata):
    with rasterio.open(
        path, "w", driver="GTiff",
        height=data.shape[0], width=data.shape[1], count=1,
        dtype="float32", crs="EPSG:4326", transform=_TRANSFORM,
        nodata=nodata,
    ) as ds:
        ds.write(data.astype("float32"), 1)
    return path


def _ramp(nodata=-9999.0) -> np.ndarray:
    # rows increase northward-to-southward in raster space; values 100..1600
    return (np.arange(16, dtype="float32").reshape(4, 4) + 1) * 100.0


def _centre(row: int, col: int) -> tuple[float, float]:
    """(lat, lon) at the centre of raster pixel (row, col)."""
    return (_ORIGIN_LAT - (row + 0.5) * _PIXEL, _ORIGIN_LON + (col + 0.5) * _PIXEL)


# --------------------------------------------------------------------------- #
# resolve_voids — the pure policy                                             #
# --------------------------------------------------------------------------- #

def test_present_values_pass_through_untouched():
    out = resolve_voids(
        np.array([100.0, 250.5, 1600.0]), nodata=-9999.0, raster_path="r.tif"
    )
    assert out.tolist() == [100.0, 250.5, 1600.0]


def test_nodata_sentinel_fills_zero():
    out = resolve_voids(
        np.array([100.0, -9999.0, 200.0]), nodata=-9999.0, raster_path="r.tif"
    )
    assert out.tolist() == [100.0, VOID_FILL, 200.0]


def test_nan_nodata_fills_zero_via_isnan():
    # nodata is itself NaN: `value == nodata` can never catch it (IEEE 754).
    out = resolve_voids(
        np.array([100.0, np.nan, 200.0]), nodata=float("nan"), raster_path="r.tif"
    )
    assert out.tolist() == [100.0, VOID_FILL, 200.0]


def test_out_of_bounds_mask_fills_zero():
    out = resolve_voids(
        np.array([100.0, 200.0, 300.0]),
        nodata=-9999.0,
        raster_path="r.tif",
        in_bounds=np.array([True, False, True]),
    )
    assert out.tolist() == [100.0, VOID_FILL, 300.0]


def test_inf_fills_zero():
    out = resolve_voids(
        np.array([100.0, np.inf, -np.inf]), nodata=None, raster_path="r.tif"
    )
    assert out.tolist() == [100.0, VOID_FILL, VOID_FILL]


def test_void_log_is_once_per_path_and_reason():
    log = VoidLog()
    assert log.note("a.tif", "nodata") is True
    assert log.note("a.tif", "nodata") is False
    assert log.note("a.tif", "nan") is True          # different reason
    assert log.note("b.tif", "nodata") is True       # different path


# --------------------------------------------------------------------------- #
# ElevationSampler — the policy applied to a real raster                      #
# --------------------------------------------------------------------------- #

def test_sample_returns_real_values_inside_coverage(tmp_path):
    dem = _write_dem(tmp_path / "dem.tif", _ramp(), nodata=-9999.0)
    s = ElevationSampler(dem)
    got = s.sample([_centre(0, 0), _centre(3, 3)])
    assert got[0] == pytest.approx(100.0)
    assert got[1] == pytest.approx(1600.0)
    assert not s.degraded


def test_sample_fills_zero_for_nodata_pixel(tmp_path):
    data = _ramp()
    data[1, 1] = -9999.0
    dem = _write_dem(tmp_path / "dem.tif", data, nodata=-9999.0)
    s = ElevationSampler(dem)
    got = s.sample([_centre(1, 1), _centre(0, 0)])
    assert got[0] == VOID_FILL
    assert got[1] == pytest.approx(100.0)


def test_sample_fills_zero_for_nan_nodata_pixel(tmp_path):
    data = _ramp()
    data[2, 2] = np.nan
    dem = _write_dem(tmp_path / "dem.tif", data, nodata=float("nan"))
    s = ElevationSampler(dem)
    got = s.sample([_centre(2, 2), _centre(3, 3)])
    assert got[0] == VOID_FILL
    assert got[1] == pytest.approx(1600.0)


def test_sample_fills_zero_outside_raster_bounds(tmp_path):
    dem = _write_dem(tmp_path / "dem.tif", _ramp(), nodata=-9999.0)
    s = ElevationSampler(dem)
    # far outside lon[10,14] lat[46,50]
    got = s.sample([(0.0, 0.0), _centre(0, 0)])
    assert got[0] == VOID_FILL
    assert got[1] == pytest.approx(100.0)


def test_missing_raster_degrades_and_never_raises(tmp_path):
    s = ElevationSampler(tmp_path / "nope.tif")
    assert s.degraded
    got = s.sample([_centre(0, 0), _centre(1, 1), (0.0, 0.0)])
    assert got.tolist() == [VOID_FILL, VOID_FILL, VOID_FILL]
    # a route entirely through a void summarises to flat zero, never raises
    assert s.profile([_centre(0, 0), _centre(1, 1)]) == {
        "ascent_m": 0.0, "descent_m": 0.0, "min_m": 0.0, "max_m": 0.0,
    }


def test_unreadable_raster_degrades(tmp_path):
    junk = tmp_path / "broken.tif"
    junk.write_bytes(b"not a geotiff")
    s = ElevationSampler(junk)
    assert s.degraded
    assert s.sample([_centre(0, 0)]).tolist() == [VOID_FILL]


def test_voids_logged_at_most_once_per_raster_path(tmp_path, caplog):
    data = _ramp()
    data[0, 0] = -9999.0
    dem = _write_dem(tmp_path / "dem.tif", data, nodata=-9999.0)
    s = ElevationSampler(dem)
    with caplog.at_level(logging.WARNING, logger="plotlines.elevation"):
        # hit the same nodata pixel and the same OOB region many times, twice
        for _ in range(50):
            s.sample([_centre(0, 0), (0.0, 0.0)])
        s.sample([_centre(0, 0), (0.0, 0.0)])
    msgs = [r.getMessage() for r in caplog.records]
    assert sum("nodata" in m for m in msgs) == 1
    assert sum("out_of_bounds" in m for m in msgs) == 1


def test_profile_over_a_partial_void_still_summarises(tmp_path):
    data = _ramp()
    data[1, 1] = -9999.0
    dem = _write_dem(tmp_path / "dem.tif", data, nodata=-9999.0)
    s = ElevationSampler(dem)
    prof = s.profile([_centre(0, 0), _centre(1, 1), _centre(3, 3)])
    # 100 -> 0 -> 1600 : descent 100, ascent 1600
    assert prof["ascent_m"] == pytest.approx(1600.0)
    assert prof["descent_m"] == pytest.approx(100.0)
    assert prof["min_m"] == pytest.approx(0.0)
    assert prof["max_m"] == pytest.approx(1600.0)


# --------------------------------------------------------------------------- #
# FR88 — no network call inside a route solve                                 #
# --------------------------------------------------------------------------- #

def test_solve_with_sampler_makes_no_network_call(tmp_path, monkeypatch):
    import networkx as nx

    from plotlines_core.routing.solve import generate_segment
    from plotlines_core.scoring.profile import WeightProfile

    dem = _write_dem(tmp_path / "dem.tif", _ramp(), nodata=-9999.0)
    sampler = ElevationSampler(dem)

    # a tiny 3-node line graph inside the raster footprint
    g = nx.MultiDiGraph()
    pts = {1: _centre(3, 0), 2: _centre(3, 1), 3: _centre(3, 2)}
    for n, (lat, lon) in pts.items():
        g.add_node(n, y=lat, x=lon, elevation=0.0)
    for u, v in [(1, 2), (2, 3)]:
        g.add_edge(u, v, length=1000.0, highway="residential")
        g.add_edge(v, u, length=1000.0, highway="residential")

    def _no_network(*a, **k):
        raise AssertionError("route solve attempted a network connection")

    monkeypatch.setattr(socket.socket, "connect", _no_network)
    monkeypatch.setattr(socket, "create_connection", _no_network)

    seg = generate_segment(
        g, pts[1], pts[3], WeightProfile(), mode="cycling", sampler=sampler
    )
    assert seg.elevation  # profile populated, offline
