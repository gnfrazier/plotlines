"""Reading a PMTiles archive (ARCH §8.2, FR92-94; issue #154).

Before this, the client read basemap tiles as loose `.mvt` files straight off
local disk (`client/lib/presentation/map/vector_tile_provider.dart`) — the
exploded contents of a ~20 km box around Boulder, CO, and nothing else,
committed unbundleable (`client/pubspec.yaml` deliberately excludes
`assets/tiles/`) and never reachable through the sidecar at all (FR92: "the
client talks only to Plotlines' own tile service"). This module is what the
service's `/tiles/{z}/{x}/{y}` endpoint reads through instead.
"""

from __future__ import annotations

import mmap
from dataclasses import dataclass
from pathlib import Path

from pmtiles.reader import Reader
from pmtiles.tile import Compression, TileType

#: Real tile pyramids never exceed this in practice; this is a pure range
#: check (FR93: "validates z/x/y against range before any upstream work"),
#: independent of any one archive's own min/max zoom.
MAX_VALID_ZOOM = 24


def valid_zxy(z: int, x: int, y: int) -> bool:
    """Whether (z, x, y) is a structurally valid tile address — before any
    archive is opened or any upstream/network work happens (FR93)."""
    if not (0 <= z <= MAX_VALID_ZOOM):
        return False
    span = 1 << z
    return 0 <= x < span and 0 <= y < span


_COMPRESSION_NAMES = {
    Compression.NONE: None,
    Compression.GZIP: "gzip",
    Compression.BROTLI: "br",
    Compression.ZSTD: "zstd",
}


@dataclass(frozen=True)
class ArchiveInfo:
    min_zoom: int
    max_zoom: int
    bounds: tuple[float, float, float, float]  # west, south, east, north
    tile_content_type: str
    #: An HTTP `Content-Encoding` value (`"gzip"`, ...), or `None` when tiles
    #: are stored uncompressed. Every tile `Archive.tile()` returns is in
    #: this encoding, verbatim from the archive — callers that hand it
    #: straight to an HTTP response should set this header rather than
    #: decompressing, and only decompress if they need the raw bytes.
    content_encoding: str | None

    def covers(self, z: int, x: int, y: int) -> bool:
        if not (self.min_zoom <= z <= self.max_zoom):
            return False
        west, south, east, north = self.bounds
        tile_west, tile_north = _tile_to_lonlat(x, y, z)
        tile_east, tile_south = _tile_to_lonlat(x + 1, y + 1, z)
        return not (tile_east < west or tile_west > east
                   or tile_south > north or tile_north < south)


def _tile_to_lonlat(x: int, y: int, z: int) -> tuple[float, float]:
    """Top-left (lon, lat) corner of tile (x, y) at zoom z, in the standard
    slippy-map tiling scheme."""
    import math
    n = 2.0 ** z
    lon = x / n * 360.0 - 180.0
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    return lon, lat


class Archive:
    """One open, read-only PMTiles archive on local disk. Cheap to open
    repeatedly (memory-mapped, no eager read of the tile data) — a caller
    serving many requests should still hold one instance rather than
    reopening per request."""

    def __init__(self, path: Path) -> None:
        self._path = Path(path)
        self._file = open(self._path, "rb")
        self._mmap = mmap.mmap(self._file.fileno(), 0, access=mmap.ACCESS_READ)
        self._reader = Reader(lambda offset, length: self._mmap[offset:offset + length])
        self._header = self._reader.header()

    def info(self) -> ArchiveInfo:
        h = self._header
        return ArchiveInfo(
            min_zoom=h["min_zoom"],
            max_zoom=h["max_zoom"],
            bounds=(h["min_lon_e7"] / 1e7, h["min_lat_e7"] / 1e7,
                    h["max_lon_e7"] / 1e7, h["max_lat_e7"] / 1e7),
            tile_content_type=_CONTENT_TYPES.get(h["tile_type"], "application/octet-stream"),
            content_encoding=_COMPRESSION_NAMES.get(h["tile_compression"]),
        )

    def tile(self, z: int, x: int, y: int) -> bytes | None:
        """Raw tile bytes exactly as stored (see `ArchiveInfo.content_encoding`
        for whether that's compressed), or `None` if this archive has no tile
        at that address. Caller must have already range-validated (z, x, y)
        via `valid_zxy` — this does not re-check it."""
        return self._reader.get(z, x, y)

    def close(self) -> None:
        self._mmap.close()
        self._file.close()

    def __enter__(self) -> "Archive":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()


_CONTENT_TYPES = {
    TileType.MVT: "application/vnd.mapbox-vector-tile",
    TileType.PNG: "image/png",
    TileType.JPEG: "image/jpeg",
    TileType.WEBP: "image/webp",
    TileType.AVIF: "image/avif",
}
