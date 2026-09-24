"""Bbox-scoped on-demand tile extraction (FR94; issue #154, mirror policy
from story M11 / issue #139).

FR94: "Tiles are generated and cached bbox-scoped and on demand; the same
pipeline is the origin for live map requests and offline packages." This
derives a small PMTiles archive covering exactly one trip bbox from a larger
source archive — the committed home-region archive for MVP, or a remote
Protomaps-format archive served over HTTP range requests.

**Hotlinking is not the shipped answer** (FR92/FR95). The default upstream a
region is built against is the committed local archive; nothing here reaches
the network unless a caller explicitly configures an `http(s)://` upstream.
When it does, `mirror.resolve_upstream` refuses any host that is not the
Plotlines-controlled mirror (`mirror.MIRROR_HOST`) unless the caller passes
`allow_unmirrored=True` — the dev-only escape hatch behind
`--allow-unmirrored-tiles`.
"""

from __future__ import annotations

import http.client
import logging
import math
import mmap
import time
from dataclasses import dataclass
from http.client import HTTPConnection, HTTPSConnection
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

from pmtiles.reader import Reader
from pmtiles.tile import Entry, deserialize_directory, find_tile, zxy_to_tileid
from pmtiles.writer import write as pmtiles_write

from .mirror import resolve_upstream

log = logging.getLogger(__name__)

GetBytes = Callable[[int, int], bytes]


@dataclass
class ExtractStats:
    """What one `extract_bbox` call cost (issue #456) — addresses walked,
    tiles actually present, `get_bytes` calls made (the real request count:
    `pmtiles.reader.Reader.get` re-reads the header and walks the directory
    tree fresh for *every* tile, so this is well above the tile count, not
    equal to it), bytes moved, and wall time. Pass an instance in via
    `extract_bbox(..., stats=...)` to read it back; always logged at INFO
    regardless, so a live run is visible in `mirror.log`/the sidecar log
    with no caller wiring at all."""

    source: str = ""
    addresses: int = 0
    hits: int = 0
    requests: int = 0
    bytes: int = 0
    wall_time_s: float = 0.0

    def as_dict(self) -> dict:
        return {
            "source": self.source,
            "addresses": self.addresses,
            "hits": self.hits,
            "requests": self.requests,
            "bytes": self.bytes,
            "wall_time_s": round(self.wall_time_s, 3),
        }


def _counting_source(get_bytes: GetBytes, stats: ExtractStats) -> GetBytes:
    """Wrap a `get_bytes` source to tally requests/bytes into `stats` — the
    same source either way, so counting adds no behaviour, just a count."""

    def counted(offset: int, length: int) -> bytes:
        data = get_bytes(offset, length)
        stats.requests += 1
        stats.bytes += len(data)
        return data

    return counted


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
    (ARCH Q9). Dev/opt-in only; see this module's docstring.

    Issue #456: one `http.client` connection is opened and kept alive for
    the life of this source rather than a fresh `urlopen` (and, over HTTPS,
    a fresh TLS handshake) per ranged GET — a coalesced extract still makes
    several dozen requests, and paying connection setup on each one was
    itself a measurable share of the pre-coalescing 136 s/2,995-address
    result recorded on #456. If the server (or a LAN middlebox) closes the
    kept-alive connection between requests, one reconnect-and-retry absorbs
    it rather than failing the whole extract for a transient keep-alive
    drop."""
    parsed = urlsplit(url)
    conn_cls = HTTPSConnection if parsed.scheme == "https" else HTTPConnection
    path = parsed.path or "/"
    if parsed.query:
        path = f"{path}?{parsed.query}"
    conn = conn_cls(parsed.hostname, parsed.port, timeout=timeout)
    headers = {"User-Agent": "plotlines-sidecar/1"}

    def _request(offset: int, length: int) -> bytes:
        conn.request("GET", path, headers={
            **headers, "Range": f"bytes={offset}-{offset + length - 1}",
        })
        resp = conn.getresponse()
        data = resp.read()
        if resp.status not in (200, 206):
            raise http.client.HTTPException(
                f"{resp.status} {resp.reason} ranging {url!r} bytes={offset}-{offset + length - 1}"
            )
        return data

    def get_bytes(offset: int, length: int) -> bytes:
        try:
            return _request(offset, length)
        except (http.client.HTTPException, OSError):
            conn.close()
            conn.connect()
            return _request(offset, length)

    def close() -> None:
        conn.close()

    return get_bytes, close


def _open_source(source: str | Path, *,
                 allow_unmirrored: bool = False) -> tuple[GetBytes, Callable[[], None]]:
    # FR92/FR95: a remote upstream must be the Plotlines mirror, never a
    # third-party tile host — refused here before a single byte is fetched.
    source = resolve_upstream(source, allow_unmirrored=allow_unmirrored)
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


#: How close two tile-data byte ranges must be (in bytes) to fetch in one
#: ranged GET rather than two — issue #456's coalescing scheme. `pmtiles
#: extract` gets away with 95 requests for a 43k-tile clustered archive by
#: doing the same merge; 128 KiB is generous enough to bridge the small gaps
#: a clustered-but-not-perfectly-contiguous bbox selection leaves (tiles
#: from other zoom levels, or outside the bbox, interleaved on the Hilbert
#: curve) without pulling in whole unrelated regions of the archive.
_COALESCE_GAP_BYTES = 128 * 1024


def _resolve_directory_entries(get_bytes: GetBytes, header: dict,
                               tile_ids: list[int], *,
                               dir_cache: dict | None = None) -> dict[int, Entry]:
    """Resolve `tile_ids` to their tile-data `Entry` (offset/length in the
    tile-data section), fetching each distinct directory blob — the root,
    and any leaf directory the lookups reach — exactly once rather than the
    fresh root-to-leaf walk `pmtiles.reader.Reader.get` does per call.
    Missing tile_ids are simply absent from the returned dict (the same
    "no data at this address" case `Reader.get` reports as `None`).

    `dir_cache`, when given, outlives this call — `upstream.UpstreamTileReader`
    passes its own bounded one so a run of single-tile reads pays for each
    directory blob once across calls, not once per tile."""
    if dir_cache is None:
        dir_cache = {}

    def load_dir(offset: int, length: int) -> list[Entry]:
        key = (offset, length)
        directory = dir_cache.get(key)
        if directory is None:
            directory = deserialize_directory(get_bytes(offset, length))
            dir_cache[key] = directory
        return directory

    resolved: dict[int, Entry] = {}
    for tile_id in tile_ids:
        dir_offset, dir_length = header["root_offset"], header["root_length"]
        for _depth in range(4):  # matches Reader.get's own max directory depth
            entry = find_tile(load_dir(dir_offset, dir_length), tile_id)
            if entry is None:
                break
            if entry.run_length == 0:
                dir_offset = header["leaf_directory_offset"] + entry.offset
                dir_length = entry.length
                continue
            resolved[tile_id] = entry
            break
    return resolved


def _fetch_tile_data_coalesced(get_bytes: GetBytes, header: dict,
                               resolved: dict[int, Entry]) -> dict[int, bytes]:
    """Fetch the tile bytes for every entry in `resolved`, merging entries
    whose tile-data ranges are within `_COALESCE_GAP_BYTES` of each other
    into one ranged GET — the tile-data half of #456's coalescing scheme.
    On a clustered archive (PMTiles header `clustered: true`, true of every
    build this project produces) tile-data offsets track tile id order, so
    a bbox's sorted addresses land in a small number of runs rather than
    one scattered offset per tile."""
    pairs = sorted(resolved.items(), key=lambda kv: kv[1].offset)
    # (range_start, range_end, [(tile_id, entry), ...]) per merged run.
    groups: list[tuple[int, int, list[tuple[int, Entry]]]] = []
    for tile_id, entry in pairs:
        entry_end = entry.offset + entry.length
        if groups and entry.offset <= groups[-1][1] + _COALESCE_GAP_BYTES:
            start, end, members = groups[-1]
            groups[-1] = (start, max(end, entry_end), members)
            members.append((tile_id, entry))
        else:
            groups.append((entry.offset, entry_end, [(tile_id, entry)]))

    tile_data: dict[int, bytes] = {}
    for start, end, members in groups:
        blob = get_bytes(header["tile_data_offset"] + start, end - start)
        for tile_id, entry in members:
            rel = entry.offset - start
            tile_data[tile_id] = blob[rel:rel + entry.length]
    return tile_data


def extract_bbox(source: str | Path, bbox: tuple[float, float, float, float],
                 out_path: Path, *, min_zoom: int | None = None,
                 max_zoom: int | None = None, allow_unmirrored: bool = False,
                 stats: ExtractStats | None = None) -> Path:
    """Write a new PMTiles archive at `out_path` covering only `bbox` (west,
    south, east, north) within `[min_zoom, max_zoom]`, read from `source` (a
    local path, the Plotlines mirror, or — with `allow_unmirrored` — any
    other `http(s)://` URL read via ranged GETs). Zoom bounds default to the
    source archive's own min/max.

    Raises `mirror.HotlinkRefused` if `source` is a third-party tile host and
    `allow_unmirrored` is false (FR92/FR95).

    Raises `NoTilesInBbox` if the source has no matching tile data — this
    happens when a trip bbox falls entirely outside the committed home
    region and no live mirror is configured (ARCH constraint: hotlinking is
    not the shipped default).

    Issue #456: every call is measured — address/hit/request/byte counts and
    wall time are always logged at INFO, and filled into `stats` (an
    `ExtractStats`, mutated in place) when the caller passes one, the same
    "pass a mutable telemetry object" shape `extract_fetch.DownloadProgress`
    uses. `requests` counts `get_bytes` calls, not tiles or addresses: the
    directory tree is resolved once per distinct directory blob touched
    (`_resolve_directory_entries`, a handful of requests, not the naive
    `pmtiles.reader.Reader.get` shape of one full root-to-leaf walk per
    tile) and the tile bytes are then fetched with runs of near-contiguous
    tile-data offsets merged into one ranged GET each
    (`_fetch_tile_data_coalesced`) — the same scheme `pmtiles extract`
    itself uses to pull a 43k-tile clustered archive in 95 requests. Before
    this, a Buncombe-County-sized bbox (2,995 addresses) measured 11,983
    requests and 136.6 s wall time against the live Pi mirror.
    """
    own_stats = stats if stats is not None else ExtractStats()
    own_stats.source = str(source)
    # The *effective* zoom range (after the clamp below) — what the log
    # line reports, since the caller's own bound is exactly the number that
    # can be misleading. `None` only if the header never loaded.
    lo_z: int | None = None
    hi_z: int | None = None
    t0 = time.monotonic()
    get_bytes, close = _open_source(source, allow_unmirrored=allow_unmirrored)
    get_bytes = _counting_source(get_bytes, own_stats)
    try:
        reader = Reader(get_bytes)
        header = reader.header()
        metadata = reader.metadata()
        # A caller-supplied bound is a further restriction, never a licence
        # to enumerate past what this archive actually contains — issue
        # #456's own `BASEMAP_MAX_ZOOM` is a *ceiling* (it "caps explicitly
        # ... rather than inheriting whatever max_zoom the source archive
        # happens to carry"), and today's real archives happen to agree
        # with it, but nothing enforced that. Without this clamp, a source
        # shallower than the requested max_zoom (a partial extract, a
        # small/synthetic archive, any future thinner archive) still
        # enumerates every address up to the caller's bound — for a
        # trip-sized bbox that's merely wasted work, but for a large bbox
        # against a shallow archive it is an unbounded address list built
        # in memory before a single byte is fetched.
        lo_z = header["min_zoom"] if min_zoom is None else max(min_zoom, header["min_zoom"])
        hi_z = header["max_zoom"] if max_zoom is None else min(max_zoom, header["max_zoom"])
        west, south, east, north = bbox

        addresses: list[tuple[int, int, int]] = []
        for z in range(lo_z, hi_z + 1):
            x0, y0 = _lonlat_to_tile(west, north, z)   # top-left
            x1, y1 = _lonlat_to_tile(east, south, z)   # bottom-right
            for x in range(min(x0, x1), max(x0, x1) + 1):
                for y in range(min(y0, y1), max(y0, y1) + 1):
                    addresses.append((z, x, y))
        addresses.sort(key=lambda zxy: zxy_to_tileid(*zxy))
        own_stats.addresses = len(addresses)
        tile_ids = [zxy_to_tileid(z, x, y) for z, x, y in addresses]

        # Collect before opening the writer: an empty result must never
        # create a partial/unreadable archive file on disk.
        resolved = _resolve_directory_entries(get_bytes, header, tile_ids)
        tile_bytes = _fetch_tile_data_coalesced(get_bytes, header, resolved)
        tiles = [(tid, tile_bytes[tid]) for tid in tile_ids if tid in tile_bytes]
        own_stats.hits = len(tiles)
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
        own_stats.wall_time_s = time.monotonic() - t0
        log.info(
            "tile extract bbox=%s zoom=[%s,%s] addresses=%d hits=%d "
            "requests=%d bytes=%d wall_s=%.3f source=%r",
            bbox, lo_z, hi_z, own_stats.addresses, own_stats.hits,
            own_stats.requests, own_stats.bytes, own_stats.wall_time_s, source,
        )
    return out_path
