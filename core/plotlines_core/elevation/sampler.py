"""GeoTIFF elevation reads (ARCH §6.2 `elevation/`).

SPIKE-00 scope: a real rasterio/GDAL read path. Void handling, tile stitching, and
the provider fallback chain (§13) are out of scope — the point here is that GDAL is
genuinely on the request hot path inside the frozen binary, because a freezer that
silently drops GDAL's data files will pass a naive smoke test and fail here.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import rasterio


class ElevationSampler:
    """Samples elevation from a local GeoTIFF. Holds the dataset open."""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        if not self.path.exists():
            raise FileNotFoundError(f"no DEM at {self.path}")
        self._ds = rasterio.open(self.path)
        self._nodata = self._ds.nodata

    def close(self) -> None:
        self._ds.close()

    def sample(self, coords: list[tuple[float, float]]) -> np.ndarray:
        """Sample elevations for (lat, lon) pairs. Returns metres, NaN outside coverage."""
        if not coords:
            return np.empty(0, dtype="float64")
        # rasterio.sample wants (x, y) == (lon, lat)
        xy = [(lon, lat) for lat, lon in coords]
        vals = np.array(
            [v[0] for v in self._ds.sample(xy, indexes=1)], dtype="float64"
        )
        if self._nodata is not None:
            vals = np.where(vals == self._nodata, np.nan, vals)
        return vals

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
