"""M10 (issue #138, FR85/FR88) — one licensed elevation source, no fallback, and
an explicit void/nodata/NaN policy.

`plotlines_core.elevation.void` + `ElevationSampler`, as amended by #473
(ARCH D68): a gap inside an open raster — `nodata`, NaN `nodata` (checked via
`isnan`), `inf`, an out-of-bounds coordinate — is interpolated from the nearest
finite samples, falling back to `0.0` only with none anywhere; a missing or
unreadable raster is absent (NaN / `{}`), never flat `0.0`. Each void is logged
at most once per raster path, and a solve does no network I/O.
"""

from __future__ import annotations

import logging
import socket

import numpy as np
import pytest
import rasterio
from rasterio.transform import from_origin

from plotlines_core.elevation.sampler import ElevationSampler
from plotlines_core.elevation.void import (
    VOID_FILL,
    VoidLog,
    interpolate_voids,
    mark_voids,
    resolve_voids,
)


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


def test_nodata_sentinel_is_interpolated_between_its_neighbours():
    out = resolve_voids(
        np.array([100.0, -9999.0, 200.0]), nodata=-9999.0, raster_path="r.tif"
    )
    assert out.tolist() == [100.0, 150.0, 200.0]


def test_nan_nodata_is_caught_via_isnan_and_interpolated():
    # nodata is itself NaN: `value == nodata` can never catch it (IEEE 754).
    out = resolve_voids(
        np.array([100.0, np.nan, 200.0]), nodata=float("nan"), raster_path="r.tif"
    )
    assert out.tolist() == [100.0, 150.0, 200.0]


def test_out_of_bounds_mask_is_interpolated():
    # whatever the driver returned for an OOB point is not trusted
    out = resolve_voids(
        np.array([100.0, 999.0, 300.0]),
        nodata=-9999.0,
        raster_path="r.tif",
        in_bounds=np.array([True, False, True]),
    )
    assert out.tolist() == [100.0, 200.0, 300.0]


def test_inf_is_a_gap_and_a_trailing_gap_holds_the_last_finite_value():
    out = resolve_voids(
        np.array([100.0, np.inf, -np.inf]), nodata=None, raster_path="r.tif"
    )
    assert out.tolist() == [100.0, 100.0, 100.0]


def test_a_leading_gap_holds_the_first_finite_value():
    out = resolve_voids(
        np.array([-9999.0, -9999.0, 300.0, 400.0]), nodata=-9999.0,
        raster_path="r.tif",
    )
    assert out.tolist() == [300.0, 300.0, 300.0, 400.0]


def test_all_void_with_no_finite_neighbour_falls_back_to_void_fill():
    out = resolve_voids(
        np.array([-9999.0, np.nan]), nodata=-9999.0, raster_path="r.tif"
    )
    assert out.tolist() == [VOID_FILL, VOID_FILL]


def test_interpolation_is_by_distance_along_the_coords_not_by_index():
    # The void sits 1 km along a 4 km run, not halfway by index.
    coords = [(0.0, 0.0), (0.0, 0.008993), (0.0, 0.035972)]  # ~0, 1, 4 km east
    out = interpolate_voids(np.array([100.0, np.nan, 500.0]), coords)
    assert out[1] == pytest.approx(200.0, abs=0.5)
    # without coords it is positional
    assert interpolate_voids(np.array([100.0, np.nan, 500.0]))[1] == 300.0


def test_mark_voids_marks_every_gap_nan_and_leaves_real_values():
    out = mark_voids(
        np.array([100.0, -9999.0, np.nan, np.inf, 500.0]),
        nodata=-9999.0,
        raster_path="r.tif",
        in_bounds=np.array([True, True, True, True, False]),
    )
    assert out[0] == 100.0
    assert np.isnan(out[1:]).all()


def test_mark_voids_does_not_log_a_sentinel_as_nan(caplog):
    with caplog.at_level(logging.WARNING, logger="plotlines.elevation"):
        mark_voids(np.array([100.0, -9999.0]), nodata=-9999.0, raster_path="r.tif")
    msgs = [r.getMessage() for r in caplog.records]
    assert any("nodata" in m for m in msgs)
    assert not any(": nan " in m for m in msgs)


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


def test_sample_interpolates_a_nodata_pixel_along_the_route(tmp_path):
    data = _ramp()
    data[1, 1] = -9999.0
    dem = _write_dem(tmp_path / "dem.tif", data, nodata=-9999.0)
    s = ElevationSampler(dem)
    # row 1 reads 500, (void), 700 at evenly spaced pixel centres
    got = s.sample([_centre(1, 0), _centre(1, 1), _centre(1, 2)])
    assert got.tolist() == pytest.approx([500.0, 600.0, 700.0])


def test_sample_interpolates_a_nan_nodata_pixel(tmp_path):
    data = _ramp()
    data[2, 2] = np.nan
    dem = _write_dem(tmp_path / "dem.tif", data, nodata=float("nan"))
    s = ElevationSampler(dem)
    got = s.sample([_centre(2, 1), _centre(2, 2), _centre(2, 3)])
    assert got.tolist() == pytest.approx([1000.0, 1100.0, 1200.0])


def test_sample_holds_the_nearest_value_outside_raster_bounds(tmp_path):
    dem = _write_dem(tmp_path / "dem.tif", _ramp(), nodata=-9999.0)
    s = ElevationSampler(dem)
    # far outside lon[10,14] lat[46,50]
    got = s.sample([(0.0, 0.0), _centre(0, 0)])
    assert got.tolist() == pytest.approx([100.0, 100.0])


def test_sample_wholly_outside_the_raster_falls_back_to_void_fill(tmp_path):
    dem = _write_dem(tmp_path / "dem.tif", _ramp(), nodata=-9999.0)
    s = ElevationSampler(dem)
    assert s.sample([(0.0, 0.0), (1.0, 1.0)]).tolist() == [VOID_FILL, VOID_FILL]


def test_read_leaves_every_gap_nan_for_the_caller_to_fill(tmp_path):
    data = _ramp()
    data[1, 1] = -9999.0
    dem = _write_dem(tmp_path / "dem.tif", data, nodata=-9999.0)
    got = ElevationSampler(dem).read([_centre(0, 0), _centre(1, 1), (0.0, 0.0)])
    assert got[0] == pytest.approx(100.0)
    assert np.isnan(got[1:]).all()


def test_missing_raster_is_absent_not_flat_and_never_raises(tmp_path):
    s = ElevationSampler(tmp_path / "nope.tif")
    assert s.degraded
    got = s.sample([_centre(0, 0), _centre(1, 1), (0.0, 0.0)])
    assert np.isnan(got).all()
    assert np.isnan(s.read([_centre(0, 0)])).all()
    # a route with no source behind it has no profile — the same `{}` a solve
    # with no sampler reports — never a fabricated flat-zero one (#473)
    assert s.profile([_centre(0, 0), _centre(1, 1)]) == {}


def test_unreadable_raster_is_absent(tmp_path):
    junk = tmp_path / "broken.tif"
    junk.write_bytes(b"not a geotiff")
    s = ElevationSampler(junk)
    assert s.degraded
    assert np.isnan(s.sample([_centre(0, 0)])).all()
    assert s.profile([_centre(0, 0), _centre(1, 1)]) == {}


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


def test_profile_over_a_partial_void_reports_the_real_climb(tmp_path):
    data = _ramp()
    data[1, 1] = -9999.0
    dem = _write_dem(tmp_path / "dem.tif", data, nodata=-9999.0)
    s = ElevationSampler(dem)
    prof = s.profile([_centre(0, 0), _centre(1, 1), _centre(3, 3)])
    # 100 -> (void, interpolated) -> 1600. Before #473 the void read 0.0, so
    # the profile invented a 100 m descent to sea level and a 1600 m climb
    # back out of it; now it is the 1500 m climb the raster actually has.
    assert prof["ascent_m"] == pytest.approx(1500.0)
    assert prof["descent_m"] == pytest.approx(0.0)
    assert prof["min_m"] == pytest.approx(100.0)
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
