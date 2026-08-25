"""Shared PMTiles archive-building helper for `test_tiles_archive.py` and
`test_tiles_extract.py` — a tiny, fully synthetic archive so tile tests never
depend on a real Protomaps download or a committed spike asset."""

from __future__ import annotations

from pathlib import Path

from pmtiles.tile import Compression, TileType, zxy_to_tileid
from pmtiles.writer import write as pmtiles_write


def build_archive(path: Path, tiles: dict[tuple[int, int, int], bytes], *,
                  bounds: tuple[float, float, float, float] = (-180.0, -85.0, 180.0, 85.0),
                  compression: Compression = Compression.NONE,
                  tile_type: TileType = TileType.MVT) -> Path:
    """Write a minimal valid PMTiles archive at `path` containing exactly
    `tiles` (keyed by (z, x, y), fake payload bytes — need not be real MVT
    for these structural tests)."""
    west, south, east, north = bounds
    ordered = sorted(tiles.items(), key=lambda kv: zxy_to_tileid(*kv[0]))
    with pmtiles_write(str(path)) as w:
        for (z, x, y), data in ordered:
            w.write_tile(zxy_to_tileid(z, x, y), data)
        w.finalize({
            "tile_type": tile_type,
            "tile_compression": compression,
            "min_lon_e7": int(round(west * 1e7)),
            "min_lat_e7": int(round(south * 1e7)),
            "max_lon_e7": int(round(east * 1e7)),
            "max_lat_e7": int(round(north * 1e7)),
        }, {"name": "test archive"})
    return path
