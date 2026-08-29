"""GeoTIFF elevation reads (ARCH §6.2 `elevation/`, §7.5 void handling).

The single elevation source is GEDTM30 (30 m global ensemble DTM) distributed by
OpenTopography — **one source, no secondary/fallback service** (PRD FR85, ARCH
D20). This module reads an already-acquired local raster; acquisition (the
network half) lives behind :mod:`plotlines_core.elevation.interface` and is never
invoked from a route solve (FR88).

Void handling (`plotlines_core.elevation.void`): `nodata`, NaN `nodata` checked
via `isnan`, out-of-bounds coordinates, and a missing/unreadable raster all
resolve to `0.0`, each logged at most once per raster path. `sample()` and
`profile()` therefore never raise and never block a solve.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import rasterio

from plotlines_core.elevation.void import VOID_FILL, VoidLog, resolve_voids


class ElevationSampler:
    """Samples elevation from a local GeoTIFF. Holds the dataset open.

    A missing or unreadable raster is **not** an error (FR88): the sampler opens
    in a degraded state and every read returns `0.0`, logged once.
    """

    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.void_log = VoidLog()
        self._ds = None
        self._nodata = None
        self._bounds = None
        try:
            self._ds = rasterio.open(self.path)
        except Exception as exc:  # noqa: BLE001 — any open failure degrades, never raises
            self.void_log.note(str(self.path), "unreadable_raster", detail=type(exc).__name__)
        else:
            self._nodata = self._ds.nodata
            self._bounds = self._ds.bounds

    @property
    def degraded(self) -> bool:
        """True when no raster is open — every sample is a `0.0` void fill."""
        return self._ds is None

    def close(self) -> None:
        if self._ds is not None:
            self._ds.close()

    def _in_bounds(self, coords: list[tuple[float, float]]) -> np.ndarray:
        """Boolean mask, True where (lat, lon) sits inside the open raster."""
        b = self._bounds
        lats = np.array([lat for lat, _ in coords], dtype="float64")
        lons = np.array([lon for _, lon in coords], dtype="float64")
        return (
            (lons >= b.left) & (lons <= b.right)
            & (lats >= b.bottom) & (lats <= b.top)
        )

    def sample(self, coords: list[tuple[float, float]]) -> np.ndarray:
        """Sample elevations for (lat, lon) pairs. Metres; `0.0` in every void."""
        if not coords:
            return np.empty(0, dtype="float64")

        if self.degraded:
            self.void_log.note(str(self.path), "unreadable_raster")
            return np.full(len(coords), VOID_FILL, dtype="float64")

        in_bounds = self._in_bounds(coords)
        # rasterio.sample wants (x, y) == (lon, lat). Reading out-of-bounds
        # points is harmless (the driver returns its fill); resolve_voids
        # rewrites them from the mask regardless of what came back.
        xy = [(lon, lat) for lat, lon in coords]
        raw = np.array(
            [v[0] for v in self._ds.sample(xy, indexes=1)], dtype="float64"
        )
        return resolve_voids(
            raw,
            nodata=self._nodata,
            raster_path=str(self.path),
            in_bounds=in_bounds,
            void_log=self.void_log,
        )

    def profile(self, coords: list[tuple[float, float]]) -> dict:
        """Ascent/descent/grade summary over an ordered coordinate list."""
        elev = self.sample(coords)
        finite = elev[np.isfinite(elev)]
        if finite.size < 2:
            return {"ascent_m": 0.0, "descent_m": 0.0, "min_m": None, "max_m": None}
        deltas = np.diff(finite)
        return {
            "ascent_m": round(float(deltas[deltas > 0].sum()), 1),
            "descent_m": round(float(-deltas[deltas < 0].sum()), 1),
            "min_m": round(float(finite.min()), 1),
            "max_m": round(float(finite.max()), 1),
        }
