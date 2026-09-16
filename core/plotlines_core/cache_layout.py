"""The one bbox-scoped, on-demand cache pattern (PRD FR94, ARCH §8.1 / §4.2).

FR94: *"Tiles are generated and cached **bbox-scoped and on demand**; the same
pipeline is the origin for live map requests and offline packages. The
elevation cache follows the identical pattern under a separate cache. **Both
are scoped by the trip bbox (FR120).**"*

ARCH §8.1 restates it for the fourth payload: *"Tile, elevation, candidate,
**and OSM extract** caches follow an identical bbox-scoped, on-demand
pattern (P7, FR94) — same policy, four payloads, not four designs."*

This module is that one design. It does not fetch, extract, or sample
anything — it only says **where** a payload for a given trip bbox lives and
**how that location is named**, so the tile pipeline
(:mod:`plotlines_core.tiles.extract`), the elevation cache
(:mod:`plotlines_core.elevation.interface`), the candidate cache
(:mod:`plotlines_core.curation.providers`) and the OSM extract Phase 3
(#272) fetches (issue #273) all key the same way instead of each inventing
one.

Two rules, and they are the whole contract:

* **Scoped by the trip bbox.** The cache key is a pure function of the bbox
  (:func:`trip_bbox_key`) — not of network type, zoom, layer selection, the
  extract's pin, or anything else. Two requests for "the same" trip area,
  differing only in float noise from a re-drawn but visually identical box,
  round to one key and share one cache entry. FR120's revisable bbox is the
  *only* extent; there is never a second one for analysis.
* **A separate cache per payload.** Tiles, elevation, candidates and OSM
  extracts each get their **own** sub-directory under the cache root
  (:attr:`CacheLayout.tiles_dir` / :attr:`~CacheLayout.elevation_dir` /
  :attr:`~CacheLayout.candidates_dir` / :attr:`~CacheLayout.extracts_dir`).
  "Separate cache" (FR94) is a directory boundary, so wiping one payload's
  cache never touches another's, and the shipped home-region elevation
  raster (FR90) and an on-demand fetched DEM land in the same place by
  construction.

The OSM extract carries a second axis the other three payloads don't: the
Geofabrik pin it was clipped under (the same value
`deploy/mirror/geofabrik_pull.py` stamps into
``osm/geofabrik/<pinned_date>/...``). The pin is a **path level above** the
key, never inside it — :func:`trip_bbox_key` stays a pure function of the
bbox alone, and :meth:`CacheLayout.osm_extract` takes the pin as a second
argument instead of folding it into the hash. That makes a stale pin a
visible sibling directory rather than an invisible overwrite, and turns a
pin bump into a directory removal (:meth:`CacheLayout.sweep_stale_extracts`)
rather than a file-by-file diff. Retention is **not** left unbounded and
accepted: one extract per bbox per pin is the largest payload in this cache
and grows without bound across trips and monthly pin bumps, so whoever owns
the Phase 3 pin bump calls :meth:`CacheLayout.sweep_stale_extracts` with the
new pin once its extracts are in place.

"On demand" is a property of the *callers*, not of this module: nothing here
is written until a cache miss makes a pipeline produce it. This module just
guarantees the miss and the later hit compute the same path.
"""

from __future__ import annotations

import hashlib
import shutil
from dataclasses import dataclass
from pathlib import Path

#: (west, south, east, north) in degrees — osmnx 2.x order, the order every
#: bbox in the codebase already uses.
BBox = tuple[float, float, float, float]

#: Coordinate rounding applied before hashing. ~1 m at the equator (5 dp):
#: enough that a re-drawn but visually identical trip bbox hits the same
#: cache entry, tight enough that two deliberately different extents never
#: collide.
_KEY_PRECISION = 5

#: Sub-directory names under the cache root — one separate cache per payload
#: (FR94 "under a separate cache"). Kept as named constants so a caller never
#: hard-codes the string and the tile/elevation/candidate/extract paths
#: cannot drift apart.
TILES_DIRNAME = "tiles"
ELEVATION_DIRNAME = "elevation"
CANDIDATES_DIRNAME = "candidates"
EXTRACTS_DIRNAME = "extracts"


def trip_bbox_key(bbox: BBox) -> str:
    """The cache key for a trip bbox — a short, stable, deterministic hex
    string (FR94 "scoped by the trip bbox (FR120)").

    A pure function of the four coordinates, rounded to :data:`_KEY_PRECISION`
    decimal places first. Identical in shape to the key the elevation cache
    and the FR90 region-asset tarball already use, so adopting it migrates
    nothing.
    """
    rounded = ",".join(f"{coord:.{_KEY_PRECISION}f}" for coord in bbox)
    return hashlib.sha1(rounded.encode()).hexdigest()[:16]


@dataclass(frozen=True)
class CacheLayout:
    """Where every bbox-scoped, on-demand payload for a cache root lives.

    `root` is normally the sidecar's ``--cache-dir`` (an OS app-support
    directory) or, in hosted mode, the shared cache volume. The four payload
    caches are siblings under it::

        <root>/tiles/<trip_bbox_key>.pmtiles
        <root>/elevation/<trip_bbox_key>.tif
        <root>/candidates/<trip_bbox_key>.json
        <root>/extracts/<pin>/<trip_bbox_key>.osm.pbf

    The extract path carries one more level than the other three: the
    Geofabrik pin sits *above* the key, not inside it (:meth:`osm_extract`).
    """

    root: Path

    def __post_init__(self) -> None:
        object.__setattr__(self, "root", Path(self.root))

    # -- the four separate caches ---------------------------------------- #

    @property
    def tiles_dir(self) -> Path:
        return self.root / TILES_DIRNAME

    @property
    def elevation_dir(self) -> Path:
        return self.root / ELEVATION_DIRNAME

    @property
    def candidates_dir(self) -> Path:
        return self.root / CANDIDATES_DIRNAME

    @property
    def extracts_dir(self) -> Path:
        return self.root / EXTRACTS_DIRNAME

    # -- per-trip-bbox payload paths ---------------------------------------- #

    def tile_archive(self, bbox: BBox) -> Path:
        """The PMTiles archive covering exactly `bbox` — the on-demand subset
        :func:`plotlines_core.tiles.extract.extract_bbox` writes and
        ``GET /tiles/{z}/{x}/{y}`` reads back."""
        return self.tiles_dir / f"{trip_bbox_key(bbox)}.pmtiles"

    def elevation_raster(self, bbox: BBox) -> Path:
        """The DEM covering exactly `bbox` — the path
        :class:`plotlines_core.elevation.interface.LocalCacheSource` resolves,
        whether the raster got there by an on-demand OpenTopography fetch or
        by extracting the shipped FR90 region tarball."""
        return self.elevation_dir / f"{trip_bbox_key(bbox)}.tif"

    def candidate_set(self, bbox: BBox) -> Path:
        """The candidate cache entry for `bbox`. The candidate cache also
        keys on layer-set and ruleset versions (ARCH §4.2); those belong in
        the file's *contents* / a sidecar index, not in this bbox-scoped
        path."""
        return self.candidates_dir / f"{trip_bbox_key(bbox)}.json"

    def osm_extract(self, bbox: BBox, pin: str) -> Path:
        """The clipped ``.osm.pbf`` extract for `bbox` — the payload the
        region graph and the candidate features are both built from once
        Phase 3 (#272) wires a fetcher onto this slot (issue #273).

        `pin` is the Geofabrik pull date — the same value
        `deploy/mirror/geofabrik_pull.py` stamps into
        ``osm/geofabrik/<pinned_date>/...`` — and sits **above** the bbox
        key as a directory level, not inside it: :func:`trip_bbox_key` stays
        a pure function of the bbox alone, so two pins for the same bbox
        land in sibling directories instead of one overwriting the other.
        See :meth:`sweep_stale_extracts` to clean up a superseded pin.
        """
        return self.extracts_dir / pin / f"{trip_bbox_key(bbox)}.osm.pbf"

    # -- helpers --------------------------------------------------------- #

    def ensure_dirs(self) -> "CacheLayout":
        """Create the four payload sub-directories if absent. Returns self.

        The per-pin sub-directory :meth:`osm_extract` writes under is *not*
        created here — like the tile and elevation payload files, it is
        created on first write (``path.parent.mkdir(parents=True,
        exist_ok=True)``), because the pin isn't known until a caller
        supplies one.
        """
        for d in (self.tiles_dir, self.elevation_dir, self.candidates_dir, self.extracts_dir):
            d.mkdir(parents=True, exist_ok=True)
        return self

    def sweep_stale_extracts(self, current_pin: str) -> list[Path]:
        """Remove every extract pin directory other than `current_pin`.

        One clipped extract per bbox per pin is the largest payload this
        cache holds, and grows without bound across trips and monthly pin
        bumps unless something sweeps it (see this module's docstring). A
        pin bump is a directory removal because the pin is a path level
        above the key (:meth:`osm_extract`), never inside it. The Phase 3
        pin-bump job — mirroring `deploy/mirror/geofabrik_pull.py`'s own
        monthly cadence — calls this with the *new* pin once its extracts
        are in place.

        Returns the removed pin directories, sorted by name. A missing
        `extracts_dir` is not an error — there is nothing to sweep yet.
        """
        if not self.extracts_dir.is_dir():
            return []
        removed = []
        for child in sorted(self.extracts_dir.iterdir()):
            if child.is_dir() and child.name != current_pin:
                shutil.rmtree(child)
                removed.append(child)
        return removed
