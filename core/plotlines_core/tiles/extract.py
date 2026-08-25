"""Bbox-scoped on-demand tile extraction (FR94; issue #154).

FR94: "Tiles are generated and cached bbox-scoped and on demand; the same
pipeline is the origin for live map requests and offline packages." This
derives a small PMTiles archive covering exactly one trip bbox from a larger
source archive — the committed home-region archive for MVP, or (per ARCH
Q9/D-line "configurable upstream", not shipped wired to a live mirror by this
issue — see #139) a remote Protomaps-format archive served over HTTP range
requests.

**Hotlinking is not the shipped answer.** The default upstream a region is
built against is the committed local archive; nothing here reaches the
network unless a caller explicitly configures an `http(s)://` upstream
(dev-only until #139 stands up a Plotlines-controlled mirror).
"""

from __future__ import annotations

import math
import mmap
from pathlib import Path
from typing import Callable
from urllib.request import Request, urlopen

from pmtiles.reader import Reader
from pmtiles.tile import zxy_to_tileid
from pmtiles.writer import write as pmtiles_write

GetBytes = Callable[[int, int], bytes]


def local_source(path: Path) -> tuple[GetBytes, Callable[[], None]]:
    """A `get_bytes` source reading a PMTiles archive off local disk."""
    f = open(path, "rb")
    mapping = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

    def get_bytes(offset: int, length: int) -> bytes:
        return mapping[offset:offset + length]

    def close() -> None:
        mapping.close()
        f.close()

    return get_bytes, close


def http_range_source(url: str, *, timeout: float = 30.0) -> tuple[GetBytes, Callable[[], None]]:
    """A `get_bytes` source reading a PMTiles archive over HTTP range
    requests — what `pmtiles extract` itself does against a remote archive
    (ARCH Q9). Dev/opt-in only; see this module's docstring."""

    def get_bytes(offset: int, length: int) -> bytes:
        req = Request(url, headers={
            "Range": f"bytes={offset}-{offset + length - 1}",
            "User-Agent": "plotlines-sidecar/1",
        })
        with urlopen(req, timeout=timeout) as resp:  # noqa: S310 — explicit http(s) upstream only
            return resp.read()

    def close() -> None:
        pass

    return get_bytes, close


def _open_source(source: str | Path) -> tuple[GetBytes, Callable[[], None]]:
    if isinstance(source, str) and source.startswith(("http://", "https://")):
        return http_range_source(source)
    return local_source(Path(source))


def _lonlat_to_tile(lon: float, lat: float, z: int) -> tuple[int, int]:
    """Standard slippy-map (x, y) for (lon, lat) at zoom z."""
    lat = max(min(lat, 85.0511287798), -85.0511287798)
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    lat_rad = math.radians(lat)
    y = int((1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) / 2.0 * n)
    return max(0, min(x, n - 1)), max(0, min(y, n - 1))


class NoTilesInBbox(ValueError):
    """The source archive has no tile data for this bbox/zoom range —
    surfaced honestly rather than writing an unreadable empty archive."""


def extract_bbox(source: str | Path, bbox: tuple[float, float, float, float],
                 out_path: Path, *, min_zoom: int | None = None,
                 max_zoom: int | None = None) -> Path:
    """Write a new PMTiles archive at `out_path` covering only `bbox` (west,
    south, east, north) within `[min_zoom, max_zoom]`, read from `source` (a
    local path, or an `http(s)://` URL read via ranged GETs). Zoom bounds
    default to the source archive's own min/max.

    Raises `NoTilesInBbox` if the source has no matching tile data — this
    happens when a trip bbox falls entirely outside the committed home
    region and no live mirror is configured (ARCH constraint: hotlinking is
    not the shipped default).
    """
    get_bytes, close = _open_source(source)
    try:
        reader = Reader(get_bytes)
        header = reader.header()
        metadata = reader.metadata()
        lo_z = header["min_zoom"] if min_zoom is None else min_zoom
        hi_z = header["max_zoom"] if max_zoom is None else max_zoom
        west, south, east, north = bbox

        addresses: list[tuple[int, int, int]] = []
        for z in range(lo_z, hi_z + 1):
            x0, y0 = _lonlat_to_tile(west, north, z)   # top-left
            x1, y1 = _lonlat_to_tile(east, south, z)   # bottom-right
            for x in range(min(x0, x1), max(x0, x1) + 1):
                for y in range(min(y0, y1), max(y0, y1) + 1):
                    addresses.append((z, x, y))
        addresses.sort(key=lambda zxy: zxy_to_tileid(*zxy))

        # Collect before opening the writer: an empty result must never
        # create a partial/unreadable archive file on disk.
        tiles = [
            (zxy_to_tileid(z, x, y), data)
            for z, x, y in addresses
            if (data := reader.get(z, x, y)) is not None
        ]
        if not tiles:
            raise NoTilesInBbox(
                f"no tile data for bbox={bbox} in zoom range [{lo_z}, {hi_z}] "
                f"from {source!r}"
            )

        out_path.parent.mkdir(parents=True, exist_ok=True)
        with pmtiles_write(str(out_path)) as w:
            for tile_id, data in tiles:
                w.write_tile(tile_id, data)
            w.finalize({
                "tile_type": header["tile_type"],
                "tile_compression": header["tile_compression"],
                "min_lon_e7": int(round(west * 1e7)),
                "min_lat_e7": int(round(south * 1e7)),
                "max_lon_e7": int(round(east * 1e7)),
                "max_lat_e7": int(round(north * 1e7)),
            }, metadata)
    finally:
        close()
    return out_path
