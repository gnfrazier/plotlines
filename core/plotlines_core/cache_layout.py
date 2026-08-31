"""The one bbox-scoped, on-demand cache pattern (PRD FR94, ARCH §8.1 / §4.2).

FR94: *"Tiles are generated and cached **bbox-scoped and on demand**; the same
pipeline is the origin for live map requests and offline packages. The
elevation cache follows the identical pattern under a separate cache. **Both
are scoped by the trip bbox (FR120).**"*

ARCH §8.1 restates it for the third payload: *"Tile, elevation, **and
candidate** caches follow an identical bbox-scoped, on-demand pattern (P7,
FR94) — same policy, three payloads, not three designs."*

This module is that one design. It does not fetch, extract, or sample
anything — it only says **where** a payload for a given trip bbox lives and
**how that location is named**, so the tile pipeline
(:mod:`plotlines_core.tiles.extract`), the elevation cache
(:mod:`plotlines_core.elevation.interface`) and a future candidate cache all
key the same way instead of each inventing one.

Two rules, and they are the whole contract:

* **Scoped by the trip bbox.** The cache key is a pure function of the bbox
  (:func:`trip_bbox_key`) — not of network type, zoom, layer selection or
  anything else. Two requests for "the same" trip area, differing only in
  float noise from a re-drawn but visually identical box, round to one key
  and share one cache entry. FR120's revisable bbox is the *only* extent;
  there is never a second one for analysis.
* **A separate cache per payload.** Tiles, elevation and candidates each get
  their **own** sub-directory under the cache root
  (:attr:`CacheLayout.tiles_dir` / :attr:`~CacheLayout.elevation_dir` /
  :attr:`~CacheLayout.candidates_dir`). "Separate cache" (FR94) is a
  directory boundary, so wiping one payload's cache never touches another's,
  and the shipped home-region elevation raster (FR90) and an on-demand
  fetched DEM land in the same place by construction.

"On demand" is a property of the *callers*, not of this module: nothing here
is written until a cache miss makes a pipeline produce it. This module just
guarantees the miss and the later hit compute the same path.
"""

from __future__ import annotations

import hashlib
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
#: hard-codes the string and the tile/elevation/candidate paths cannot drift
#: apart.
TILES_DIRNAME = "tiles"
ELEVATION_DIRNAME = "elevation"
CANDIDATES_DIRNAME = "candidates"


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
    directory) or, in hosted mode, the shared cache volume. The three payload
    caches are siblings under it::

        <root>/tiles/<trip_bbox_key>.pmtiles
        <root>/elevation/<trip_bbox_key>.tif
        <root>/candidates/<trip_bbox_key>.json
    """

    root: Path

    def __post_init__(self) -> None:
        object.__setattr__(self, "root", Path(self.root))

    # -- the three separate caches -------------------------------------- #

    @property
    def tiles_dir(self) -> Path:
        return self.root / TILES_DIRNAME

    @property
    def elevation_dir(self) -> Path:
        return self.root / ELEVATION_DIRNAME

    @property
    def candidates_dir(self) -> Path:
        return self.root / CANDIDATES_DIRNAME

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

    # -- helpers --------------------------------------------------------- #

    def ensure_dirs(self) -> "CacheLayout":
        """Create the three payload sub-directories if absent. Returns self."""
        for d in (self.tiles_dir, self.elevation_dir, self.candidates_dir):
            d.mkdir(parents=True, exist_ok=True)
        return self
