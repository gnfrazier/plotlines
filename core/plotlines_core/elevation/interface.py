"""The one elevation interface (PRD M3 / FR62 seam, ARCH §12.1).

Callers ask for elevation covering a bounding box through a single object,
:class:`ElevationResolver`, and never learn where the raster came from. The
resolver walks an **ordered list of sources** and returns the first hit:

    Phase 1 (MVP)   [ LocalCacheSource, DirectProviderSource(base_url=OPENTOPO) ]
    Phase 2 (later) [ LocalCacheSource, HttpElevationSource(base_url=SHARED),
                                        DirectProviderSource(base_url=OPENTOPO) ]

Going from Phase 1 to Phase 2 inserts one link ahead of the direct provider and
supplies its base URL. Nothing else moves: the resolver, the source classes, the
local cache, the sampler, and every call site are byte-identical between phases
(ARCH §12.1 — "Phase 2 changes a base URL and a cache-lookup step, not the
client"). That invariant is what :mod:`core.tests.test_elevation_interface`
pins.

A cache miss is the only thing that can touch the network, and that only happens
outside a route solve — `ElevationResolver.resolve()` is a planning-time call.
FR88's "no network fetch inside route computation" holds because the solver is
handed an already-resolved :class:`~plotlines_core.elevation.sampler.ElevationSampler`.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol, runtime_checkable

from plotlines_core.cache_layout import CacheLayout
from plotlines_core.cache_layout import trip_bbox_key as _trip_bbox_key
from plotlines_core.elevation.sampler import ElevationSampler

BBox = tuple[float, float, float, float]  # (min_lon, min_lat, max_lon, max_lat)

#: GEDTM30 (30 m global ensemble DTM) via OpenTopography — the single source,
#: no fallback service (FR85, ARCH D20). Phase 2's shared cache sits *in front*
#: of this, never beside it.
OPENTOPO_BASE_URL = "https://portal.opentopography.org/API/globaldem?demtype=GEDTM30"


class ElevationUnavailable(RuntimeError):
    """Every source missed and no fetch is configured. Callers that hit this at
    planning time carry on with elevation absent (``sampler_for`` returns
    ``None``, #473); a solve never sees it because a solve never resolves."""


def bbox_key(bbox: BBox) -> str:
    """Stable filename stem for a bbox-scoped DEM.

    A thin alias for :func:`plotlines_core.cache_layout.trip_bbox_key` — the
    tile, elevation and candidate caches share **one** key function (FR94,
    ARCH §8.1), and this name is kept only so existing call sites and the
    FR90 region asset need no edit. Byte-identical output to the previous
    local implementation, so nothing on disk migrates.
    """
    return _trip_bbox_key(bbox)


@dataclass(frozen=True)
class ElevationRaster:
    """A resolved DEM: a local file plus the name of the source that produced it."""

    path: Path
    bbox: BBox
    source: str


# A fetcher downloads the DEM for `bbox` from `base_url` and writes it to
# `dest`, returning `dest`. Injected so the network layer is swappable and so
# tests never hit OpenTopography. `None` (the default) means "no fetch wired" —
# the local cache is then the only source. The shipped fetcher is
# `plotlines_core.elevation.keys.OpenTopographyClient.as_fetcher()`, which
# carries FR87's key tiering and free-tier ceiling (issue #148); its refusals
# arrive here as a fetch failure, which `HttpElevationSource` reads as a miss.
Fetcher = Callable[[str, BBox, Path], Path]


@runtime_checkable
class ElevationSource(Protocol):
    name: str

    def get(self, bbox: BBox) -> ElevationRaster | None:
        """Return a raster covering `bbox`, or ``None`` for a miss."""


class LocalCacheSource:
    """On-disk bbox-scoped DEM cache. First link in every phase; also the
    write-back target when a downstream network source produces a raster.

    With `areas` (a `cache_areas.AreaIndex`, epic #641 / ARCH D73), a bbox
    with no DEM of its own is served from a held area's DEM that covers it:
    the area's raster itself, not a crop, because a sampler reads only the
    points it is asked for and a crop file per trip would grow the disk
    again. A network source writing back through this cache then fetches
    the *padded* area (:meth:`fetch_bbox`), so the next trip nearby hits.
    Without `areas` (the Pi's elevation proxy) the behaviour is the
    exact-bbox one it always was."""

    name = "local-cache"

    def __init__(self, cache_dir: str | Path, *, areas=None):
        self.cache_dir = Path(cache_dir)
        self.areas = areas

    def _path_for(self, bbox: BBox) -> Path:
        return self.cache_dir / f"{bbox_key(bbox)}.tif"

    def get(self, bbox: BBox) -> ElevationRaster | None:
        p = self._path_for(bbox)
        if p.is_file():
            return ElevationRaster(path=p, bbox=bbox, source=self.name)
        if self.areas is None:
            return None
        from plotlines_core.cache_areas import PAYLOAD_ELEVATION

        hit = self.areas.resolve(bbox, PAYLOAD_ELEVATION)
        if hit is None:
            return None
        if not hit.path.is_file() or not _raster_covers(hit.path, bbox):
            # A record whose file is gone, or a DEM that does not actually
            # reach this bbox, is a miss — never a flat profile (D68).
            return None
        return ElevationRaster(path=hit.path, bbox=hit.area_bbox, source=self.name)

    def fetch_bbox(self, bbox: BBox) -> BBox:
        """The bbox a downstream source should fetch for `bbox`: the padded
        area (D73) when areas are wired, else `bbox` itself."""
        return self.areas.reserve(bbox) if self.areas is not None else bbox

    def reserve(self, bbox: BBox) -> Path:
        """Where a downstream source should write the DEM it fetched."""
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        return self._path_for(bbox)

    def written(self, bbox: BBox, path: Path) -> None:
        """Record a DEM a downstream source just wrote for `bbox`."""
        if self.areas is not None:
            from plotlines_core.cache_areas import PAYLOAD_ELEVATION

            self.areas.register(bbox, PAYLOAD_ELEVATION, Path(path))

    def discard(self, raster: "ElevationRaster") -> None:
        """Forget a DEM that turned out unreadable, and delete it."""
        if self.areas is not None:
            from plotlines_core.cache_areas import PAYLOAD_ELEVATION

            self.areas.forget(raster.bbox, PAYLOAD_ELEVATION)
        raster.path.unlink(missing_ok=True)


def _raster_covers(path: Path, bbox: BBox) -> bool:
    """Whether the DEM at `path` spans `bbox` (to half a 30 m pixel)."""
    import rasterio

    try:
        with rasterio.open(path) as ds:
            b = ds.bounds
            tol = max(abs(ds.res[0]), abs(ds.res[1])) / 2
    except Exception:  # noqa: BLE001 — an unreadable file covers nothing
        return False
    west, south, east, north = bbox
    return (b.left <= west + tol and b.bottom <= south + tol
            and b.right >= east - tol and b.top >= north - tol)


class HttpElevationSource:
    """A DEM source addressed by a base URL.

    The Phase-2 shared cache and the Phase-1 direct provider are *the same
    class* with a different `base_url` — the whole point of M3. On a hit the
    fetched raster is written into `write_back` (the local cache) so the next
    resolve for the same bbox is a local hit.
    """

    def __init__(
        self,
        base_url: str,
        *,
        name: str = "http",
        fetch: Fetcher | None = None,
        write_back: LocalCacheSource | None = None,
    ):
        self.base_url = base_url
        self.name = name
        self._fetch = fetch
        self._write_back = write_back

    def get(self, bbox: BBox) -> ElevationRaster | None:
        if self._fetch is None:
            return None
        # Epic #641 — fetch the padded area, so the next trip nearby hits.
        fetch_bbox = (self._write_back.fetch_bbox(bbox)
                      if self._write_back is not None else bbox)
        dest = (
            self._write_back.reserve(fetch_bbox)
            if self._write_back is not None
            else Path(f"{bbox_key(fetch_bbox)}.tif")
        )
        try:
            written = self._fetch(self.base_url, fetch_bbox, dest)
        except Exception:  # noqa: BLE001 — a fetch failure is a miss, not a raise
            return None
        if written is None or not Path(written).is_file():
            return None
        if self._write_back is not None:
            self._write_back.written(fetch_bbox, Path(written))
        return ElevationRaster(path=Path(written), bbox=fetch_bbox, source=self.name)


class DirectProviderSource(HttpElevationSource):
    """GEDTM30 via OpenTopography, called directly (FR62: Web and Guest have no
    server-side cache in this phase). Just :class:`HttpElevationSource` pinned to
    the one provider's base URL."""

    def __init__(
        self,
        base_url: str = OPENTOPO_BASE_URL,
        *,
        fetch: Fetcher | None = None,
        write_back: LocalCacheSource | None = None,
    ):
        super().__init__(
            base_url, name="direct-provider", fetch=fetch, write_back=write_back
        )


class ElevationResolver:
    """The one interface. Walks its ordered `sources`; first hit wins."""

    def __init__(self, sources: list[ElevationSource]):
        if not sources:
            raise ValueError("ElevationResolver needs at least one source")
        self.sources = list(sources)

    @property
    def source_names(self) -> list[str]:
        return [s.name for s in self.sources]

    def resolve(self, bbox: BBox) -> ElevationRaster:
        """Return a DEM covering `bbox` from the first source that has one."""
        for src in self.sources:
            raster = src.get(bbox)
            if raster is not None:
                return raster
        raise ElevationUnavailable(
            f"no elevation source resolved bbox {bbox} "
            f"(tried: {', '.join(self.source_names)})"
        )

    def sampler_for(self, bbox: BBox) -> ElevationSampler | None:
        """Resolve `bbox` and hand back a sampler over the result, or ``None``
        when no source resolved it.

        ``None`` is FR88's *absent* case (#473, ARCH D68): elevation is never
        the reason planning stops, and it is never fabricated either — before
        #473 this returned a degraded sampler that read ``0.0`` everywhere, so
        a region with no DEM reported a flat profile as if it were measured.
        A returned sampler does no network I/O, so it is safe to pass into a
        solve.
        """
        try:
            raster = self.resolve(bbox)
        except ElevationUnavailable:
            return None
        return ElevationSampler(raster.path)


def phase1_resolver(cache_dir: str | Path, *, fetch: Fetcher | None = None,
                    areas=None) -> ElevationResolver:
    """MVP wiring: local cache, then the direct provider (FR62). `areas`
    (epic #641) lets the cache serve a covering held area's DEM."""
    cache = LocalCacheSource(cache_dir, areas=areas)
    return ElevationResolver(
        [cache, DirectProviderSource(fetch=fetch, write_back=cache)]
    )


def phase1_resolver_for_layout(
    layout: CacheLayout, *, fetch: Fetcher | None = None, areas=None,
) -> ElevationResolver:
    """:func:`phase1_resolver` rooted at ``layout.elevation_dir`` — the
    separate, bbox-scoped elevation cache FR94 calls for, a sibling of the
    tile cache under one cache root. The shipped FR90 home-region raster and
    an on-demand OpenTopography fetch both land here."""
    return phase1_resolver(layout.elevation_dir, fetch=fetch, areas=areas)


def phase2_resolver(
    cache_dir: str | Path,
    shared_cache_url: str,
    *,
    fetch: Fetcher | None = None,
) -> ElevationResolver:
    """Later wiring: local cache, then the shared server-side cache, then the
    same direct provider. Differs from :func:`phase1_resolver` by exactly one
    inserted link and its base URL — nothing else."""
    cache = LocalCacheSource(cache_dir)
    return ElevationResolver(
        [
            cache,
            HttpElevationSource(
                shared_cache_url, name="shared-cache", fetch=fetch, write_back=cache
            ),
            DirectProviderSource(fetch=fetch, write_back=cache),
        ]
    )
