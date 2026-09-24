"""Single-tile reads from the configured tile upstream (FR92/FR94, FR120;
issue #154).

`/tiles/{z}/{x}/{y}` answered from two sources before this: an ensured
region's on-demand archive, and the committed home-region archive. Neither
exists for the one screen that most needs a basemap — the trip-extent draw
map, *before* the Author has drawn anything, anywhere outside Buncombe
County. FR120: "the map is navigable while the extent is drawn". With the
mirror running and `--tiles-upstream` defaulted to it (#453/#457), that
screen still painted grey, because the upstream was only ever read by
`extract_bbox` once a region had been ensured — and a region needs the
extent the Author could not see to draw.

This reads the individual tile a viewport asks for from that same upstream,
through the same refusal (`mirror.resolve_upstream` — FR92/FR95, never a
third-party host without `--allow-unmirrored-tiles`) and the same directory
resolution `extract_bbox` uses. It is on-demand in the FR94 sense — one tile
per tile the map actually requests — and never eager: constructing a reader
makes no request (D41/D57), the header is read on the first `tile()` call.

Not thread-safe by design beyond its own lock: the one kept-alive connection
under `http_range_source` serves one request at a time, and the service
runs every call on a dedicated single-worker pool behind a deadline (ARCH
§8.6, D66) — this class holds no deadline of its own.
"""

from __future__ import annotations

import threading
from collections import OrderedDict
from pathlib import Path
from typing import Callable

from pmtiles.reader import Reader
from pmtiles.tile import zxy_to_tileid

from .archive import ArchiveInfo, _COMPRESSION_NAMES, _CONTENT_TYPES
from .extract import GetBytes, _open_source, _resolve_directory_entries
from .mirror import resolve_upstream

#: Directory blobs kept between calls. A Protomaps build's leaf directories
#: are tens of KB each; a viewport's tiles share one or two of them, so this
#: covers a long pan session without re-fetching a directory per tile.
DIR_CACHE_ENTRIES = 64

#: Tile bytes (or a known miss) kept between calls — a re-pan or a zoom back
#: out re-requests tiles the map already had, and the client's own raster
#: cache does not cover a tile it has not rendered yet.
TILE_CACHE_ENTRIES = 512


class _Lru(OrderedDict):
    def __init__(self, capacity: int) -> None:
        super().__init__()
        self._capacity = capacity

    def get(self, key, default=None):
        if key in self:
            self.move_to_end(key)
            return self[key]
        return default

    def __setitem__(self, key, value) -> None:
        super().__setitem__(key, value)
        self.move_to_end(key)
        while len(self) > self._capacity:
            self.popitem(last=False)


_MISS = object()


class UpstreamTileReader:
    """Reads one tile at a time from a PMTiles upstream — a local path, the
    Plotlines mirror, or (with `allow_unmirrored`) any other `http(s)://`
    archive. Raises `mirror.HotlinkRefused` at construction for a refused
    third-party host, before any byte is fetched."""

    def __init__(self, source: str | Path, *, allow_unmirrored: bool = False,
                 opener: Callable[[str | Path], tuple[GetBytes, Callable[[], None]]] | None = None,
                 ) -> None:
        self.source = str(source)
        resolved = resolve_upstream(source, allow_unmirrored=allow_unmirrored)
        self._opener = opener or (lambda s: _open_source(s, allow_unmirrored=allow_unmirrored))
        self._resolved = resolved
        self._lock = threading.Lock()
        self._get_bytes: GetBytes | None = None
        self._close: Callable[[], None] | None = None
        self._header: dict | None = None
        self._dirs = _Lru(DIR_CACHE_ENTRIES)
        self._tiles = _Lru(TILE_CACHE_ENTRIES)

    def info(self) -> ArchiveInfo | None:
        """The upstream's header-derived info, or `None` until a `tile()`
        call has read it — never itself a request (D41/D57: `/health` reads
        this and must not reach the upstream)."""
        h = self._header
        if h is None:
            return None
        return ArchiveInfo(
            min_zoom=h["min_zoom"],
            max_zoom=h["max_zoom"],
            bounds=(h["min_lon_e7"] / 1e7, h["min_lat_e7"] / 1e7,
                    h["max_lon_e7"] / 1e7, h["max_lat_e7"] / 1e7),
            tile_content_type=_CONTENT_TYPES.get(h["tile_type"], "application/octet-stream"),
            content_encoding=_COMPRESSION_NAMES.get(h["tile_compression"]),
            identity=self.source,
        )

    def tile(self, z: int, x: int, y: int) -> bytes | None:
        """Raw tile bytes as stored (see `info().content_encoding`), or
        `None` if the upstream has no tile there. Raises whatever the
        transport raises (`OSError`, `http.client.HTTPException`) — a
        failure is never cached, and the connection is dropped so the next
        call starts clean (D66: transient, never latched). Caller must have
        range-validated (z, x, y) already."""
        with self._lock:
            cached = self._tiles.get((z, x, y), _MISS)
            if cached is not _MISS:
                return cached
            try:
                data = self._read(z, x, y)
            except Exception:
                self._reset()
                raise
            self._tiles[(z, x, y)] = data
            return data

    def _read(self, z: int, x: int, y: int) -> bytes | None:
        if self._get_bytes is None:
            self._get_bytes, self._close = self._opener(self._resolved)
        if self._header is None:
            self._header = Reader(self._get_bytes).header()
        info = self.info()
        # Outside the upstream's own zoom range or bounds: an honest miss
        # with no request, the common case for a pan off the mirror's
        # covered regions.
        if not info.covers(z, x, y):
            return None
        tile_id = zxy_to_tileid(z, x, y)
        entry = _resolve_directory_entries(
            self._get_bytes, self._header, [tile_id], dir_cache=self._dirs).get(tile_id)
        if entry is None:
            return None
        return self._get_bytes(self._header["tile_data_offset"] + entry.offset, entry.length)

    def _reset(self) -> None:
        if self._close is not None:
            try:
                self._close()
            except Exception:  # noqa: BLE001 — closing a broken connection
                pass
        self._get_bytes = None
        self._close = None

    def close(self) -> None:
        with self._lock:
            self._reset()
