"""The basemap as a set of archives found by area — issue #519 (epic #516,
ARCH D67).

Before this, `--tiles-upstream` named exactly one `.pmtiles` file, so every
area the mirror covered had to live in that one file: #515 merged every
pre-warmed area into `priority.pmtiles`, whose header bounds are its whole
continental envelope, which hid the #318 notice over the gaps between its
regions. With fills (D67) the mirror grows cell by cell, and a file per
cell is the only shape that can grow without rewriting the others.

So `--tiles-upstream` may now name the **mirror root** (anything not ending
in `.pmtiles`: `https://tiles.plotlines.app`, or a local store directory).
The set learns which archives exist, and what each covers, from the
store's own record — `MIRROR_STATE.json`'s `areas` rows (#517), or
`basemap.covered_regions` on a mirror that predates them — and holds one
`UpstreamTileReader` per archive.

Three rules this keeps:

- **No request before it is needed** (D41/D57). Constructing a set makes
  no request, and neither do `coverage()` or `identity()` (what `/health`
  reads). The record is read the first time a tile or an extract needs it.
- **The record is read on the caller's pool, never a request thread.**
  `tile()` runs on the sidecar's dedicated upstream-tile pool behind its
  deadline (`_upstream_tile`, #154), and `extract()` runs in a region
  build phase; both may read the record there. It is cached for
  `RECORD_TTL_S`, the same idea as #367's `MirrorStateCache`, and
  `invalidate()` drops it when the sidecar knows a fill just landed (#521).
- **`HotlinkRefused` applies to the root exactly as to a file URL**
  (FR92/FR95): the root is resolved once at construction, and every archive
  URL is built under it.
"""

from __future__ import annotations

import hashlib
import json
import math
import threading
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from ..osm_identity import osm_user_agent
from .extract import ExtractStats, NoTilesInBbox, extract_bbox_from_parts
from .mirror import resolve_upstream
from .upstream import UpstreamTileReader

BBox = tuple[float, float, float, float]

#: How long a read of the store record is trusted. Short enough that a cell
#: filled by someone else shows up within minutes; long enough that a pan
#: does not re-read it per tile.
RECORD_TTL_S = 300.0

#: Socket timeout on the record read — it runs on a pool behind the
#: caller's own deadline, so this only has to be finite.
RECORD_FETCH_TIMEOUT_S = 10.0

STATE_FILE = "MIRROR_STATE.json"


def is_archive_root(source: str | Path) -> bool:
    """A `--tiles-upstream` that names a store root rather than one
    archive: anything that is not a `.pmtiles` path or URL."""
    return not str(source).rstrip("/").endswith(".pmtiles")


@dataclass(frozen=True)
class BasemapArchive:
    """One archive in the store: its store-relative `path`, the area key it
    was filled or seeded as, and what it covers — `parts` when the record
    names them (#515's multi-area archive), else its one `bbox`."""

    area: str
    path: str
    bbox: BBox
    parts: tuple[BBox, ...]
    filled_at: str | None = None


def archives_from_state(state: dict) -> list[BasemapArchive]:
    """The basemap archives a store record names. `areas` rows (#517) win;
    `basemap.covered_regions` is read on a mirror that has no rows yet."""
    rows = [r for r in (state.get("areas") or {}).values()
            if isinstance(r, dict) and r.get("layer") == "basemap"]
    if not rows:
        covered = (state.get("basemap") or {}).get("covered_regions")
        if isinstance(covered, dict):
            rows = [{"area": name, **(entry or {})} for name, entry in covered.items()]
    out = []
    for row in rows:
        bbox, path = row.get("bbox"), row.get("path")
        if not bbox or not path:
            continue
        parts = tuple(tuple(p) for p in (row.get("parts") or [])) or (tuple(bbox),)
        out.append(BasemapArchive(
            area=str(row.get("area") or row.get("name") or path), path=str(path),
            bbox=tuple(bbox), parts=parts,
            filled_at=row.get("filled_at") or row.get("extracted_at")))
    return sorted(out, key=lambda a: a.path)


def _tile_bbox(z: int, x: int, y: int) -> BBox:
    n = 2.0 ** z

    def lat(yy: float) -> float:
        return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * yy / n))))

    return (x / n * 360.0 - 180.0, lat(y + 1), (x + 1) / n * 360.0 - 180.0, lat(y))


def _overlap(a: BBox, b: BBox) -> float:
    w, s = max(a[0], b[0]), max(a[1], b[1])
    e, n = min(a[2], b[2]), min(a[3], b[3])
    return max(0.0, e - w) * max(0.0, n - s)


class RecordUnavailable(Exception):
    """The store record could not be read. Transient (D66) — `/tiles`
    answers 503, a build phase fails its tiles honestly, nothing latches."""


class BasemapArchiveSet:
    """The archives under one store root. `fetch_record` is injectable for
    tests; the default reads `<root>/MIRROR_STATE.json`."""

    def __init__(self, root: str | Path, *, allow_unmirrored: bool = False,
                 fetch_record: Callable[[], dict] | None = None,
                 reader_factory: Callable[[str], UpstreamTileReader] | None = None,
                 clock: Callable[[], float] = time.monotonic,
                 ttl_s: float = RECORD_TTL_S) -> None:
        self.source = str(root)
        resolve_upstream(root, allow_unmirrored=allow_unmirrored)  # FR92/95, raises now
        self._remote = self.source.startswith(("http://", "https://"))
        self._root = self.source.rstrip("/")
        self._allow_unmirrored = allow_unmirrored
        self._fetch_record = fetch_record or self._default_fetch
        self._reader_factory = reader_factory or (
            lambda url: UpstreamTileReader(url, allow_unmirrored=allow_unmirrored))
        self._clock = clock
        self._ttl_s = ttl_s
        self._lock = threading.Lock()
        self._archives: list[BasemapArchive] | None = None
        self._loaded_at: float | None = None
        self._readers: dict[str, UpstreamTileReader] = {}

    # -- the record --------------------------------------------------------

    def archive_url(self, path: str) -> str:
        return f"{self._root}/{path}" if self._remote else str(Path(self._root) / path)

    def _default_fetch(self) -> dict:
        if not self._remote:
            return json.loads((Path(self._root) / STATE_FILE).read_text())
        req = urllib.request.Request(f"{self._root}/{STATE_FILE}",
                                     headers={"User-Agent": osm_user_agent()})
        with urllib.request.urlopen(req, timeout=RECORD_FETCH_TIMEOUT_S) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def archives(self) -> list[BasemapArchive]:
        """The current archive list, re-read once `ttl_s` has passed. Makes
        a request — call it only off the request thread."""
        with self._lock:
            fresh = (self._archives is not None and self._loaded_at is not None
                     and self._clock() - self._loaded_at < self._ttl_s)
            if fresh:
                return self._archives
        try:
            state = self._fetch_record()
        except Exception as exc:  # noqa: BLE001 — any read failure is transient
            with self._lock:
                if self._archives is not None:
                    return self._archives  # keep serving the last good list
            raise RecordUnavailable(f"couldn't read the mirror's store record: {exc}") from exc
        archives = archives_from_state(state if isinstance(state, dict) else {})
        with self._lock:
            self._archives = archives
            self._loaded_at = self._clock()
            live = {a.path for a in archives}
            for path in [p for p in self._readers if p not in live]:
                self._readers.pop(path).close()
        return archives

    def invalidate(self) -> None:
        """Forget the cached record — the next read fetches it again. For a
        caller that knows a fill just landed (#521)."""
        with self._lock:
            self._loaded_at = None

    # -- what /health reads: no request -------------------------------------

    def coverage(self) -> list[list[float]] | None:
        """Every covered rectangle, `[[w, s, e, n], …]` — per part, so the
        gaps between cells (or between #515's regions) stay uncovered.
        `None` until the record has been read once."""
        with self._lock:
            if self._archives is None:
                return None
            return [list(p) for a in self._archives for p in a.parts]

    def identity(self) -> str:
        """A fingerprint of the archive list as last read, for #455's tile
        cache identity: a newly filled cell must not be masked by the
        client's cache of the misses it replaced."""
        with self._lock:
            listing = [] if self._archives is None else [
                f"{a.path}@{a.filled_at}" for a in self._archives]
        return hashlib.sha256("|".join([self.source, *listing]).encode()).hexdigest()[:16]

    def info(self):
        """Nothing single-archive to report — `coverage()` replaces the
        one `bounds` envelope."""
        return None

    # -- reads (off the request thread) --------------------------------------

    def archive_for(self, z: int, x: int, y: int) -> BasemapArchive | None:
        """The archive to read a tile from: among the archives with a part
        overlapping the tile, the one overlapping it most (so the cell a
        tile sits in wins over a neighbour it only grazes), smallest first
        on a tie (the cell over a wide seeded archive)."""
        tb = _tile_bbox(z, x, y)
        best = None
        for archive in self.archives():
            overlap = max((_overlap(tb, p) for p in archive.parts), default=0.0)
            if overlap <= 0:
                continue
            size = sum((p[2] - p[0]) * (p[3] - p[1]) for p in archive.parts)
            key = (overlap, -size)
            if best is None or key > best[0]:
                best = (key, archive)
        return best[1] if best else None

    def _reader(self, archive: BasemapArchive) -> UpstreamTileReader:
        with self._lock:
            reader = self._readers.get(archive.path)
            if reader is None:
                reader = self._reader_factory(self.archive_url(archive.path))
                self._readers[archive.path] = reader
            return reader

    def read_tile(self, z: int, x: int, y: int):
        """One tile from whichever archive covers it, with that archive's
        header info, or `(None, None)` when none does — the honest "no tile
        here" (#521 turns a missing cell into a fill). Raises
        `RecordUnavailable` or the transport's error; the caller reports
        both as a retryable 503 (D66)."""
        archive = self.archive_for(z, x, y)
        if archive is None:
            return None, None
        return self._reader(archive).read_tile(z, x, y)

    def tile(self, z: int, x: int, y: int) -> bytes | None:
        return self.read_tile(z, x, y)[0]

    def extract(self, bbox: BBox, out_path: Path, *, max_zoom: int | None = None,
                stats: ExtractStats | None = None) -> Path:
        """A region's on-demand archive (FR94), stitched from every archive
        with a part inside `bbox` (`extract_bbox_from_parts`). Raises
        `NoTilesInBbox` when none has."""
        parts = []
        for archive in self.archives():
            for part in archive.parts:
                if _overlap(part, bbox) > 0:
                    parts.append((self.archive_url(archive.path), part))
        if not parts:
            raise NoTilesInBbox(f"no basemap archive on the mirror covers bbox={bbox}")
        return extract_bbox_from_parts(parts, bbox, out_path, max_zoom=max_zoom,
                                       allow_unmirrored=self._allow_unmirrored, stats=stats)

    def missing_cells(self, bbox: BBox, cell_degrees: float = 2.0) -> list[BBox]:
        """The grid squares `bbox` reaches that no archive part contains —
        what a caller asks the mirror to fill (#521)."""
        out = []
        west, south, east, north = bbox
        archives = self.archives()
        for i in range(math.floor(west / cell_degrees), math.ceil(east / cell_degrees)):
            for j in range(math.floor(south / cell_degrees), math.ceil(north / cell_degrees)):
                square = (i * cell_degrees, j * cell_degrees,
                          (i + 1) * cell_degrees, (j + 1) * cell_degrees)
                piece = (max(west, square[0]), max(south, square[1]),
                         min(east, square[2]), min(north, square[3]))
                if piece[0] >= piece[2] or piece[1] >= piece[3]:
                    continue
                if not any(p[0] <= piece[0] and p[1] <= piece[1] and p[2] >= piece[2]
                           and p[3] >= piece[3] for a in archives for p in a.parts):
                    out.append(piece)
        return out

    def close(self) -> None:
        with self._lock:
            for reader in self._readers.values():
                reader.close()
            self._readers.clear()
