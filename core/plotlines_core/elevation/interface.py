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

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Protocol, runtime_checkable

from plotlines_core.elevation.sampler import ElevationSampler

BBox = tuple[float, float, float, float]  # (min_lon, min_lat, max_lon, max_lat)

#: GEDTM30 (30 m global ensemble DTM) via OpenTopography — the single source,
#: no fallback service (FR85, ARCH D20). Phase 2's shared cache sits *in front*
#: of this, never beside it.
OPENTOPO_BASE_URL = "https://portal.opentopography.org/API/globaldem?demtype=GEDTM30"


class ElevationUnavailable(RuntimeError):
    """Every source missed and no fetch is configured. Callers that hit this at
    planning time fall back to a degraded (all-`0.0`) sampler; a solve never
    sees it because a solve never resolves."""


def bbox_key(bbox: BBox) -> str:
    """Stable filename stem for a bbox-scoped DEM (same shape as the tile and
    candidate caches, ARCH §4.2)."""
    rounded = ",".join(f"{c:.5f}" for c in bbox)
    return hashlib.sha1(rounded.encode()).hexdigest()[:16]


@dataclass(frozen=True)
class ElevationRaster:
    """A resolved DEM: a local file plus the name of the source that produced it."""

    path: Path
    bbox: BBox
    source: str


# A fetcher downloads the DEM for `bbox` from `base_url` and writes it to
# `dest`, returning `dest`. Injected so the network layer is swappable and so
# tests never hit OpenTopography. `None` (the default) means "no fetch wired" —
# acquisition is gated on FR87 / issue #148.
Fetcher = Callable[[str, BBox, Path], Path]


@runtime_checkable
class ElevationSource(Protocol):
    name: str

    def get(self, bbox: BBox) -> ElevationRaster | None:
        """Return a raster covering `bbox`, or ``None`` for a miss."""


class LocalCacheSource:
    """On-disk bbox-scoped DEM cache. First link in every phase; also the
    write-back target when a downstream network source produces a raster."""

    name = "local-cache"

    def __init__(self, cache_dir: str | Path):
        self.cache_dir = Path(cache_dir)

    def _path_for(self, bbox: BBox) -> Path:
        return self.cache_dir / f"{bbox_key(bbox)}.tif"

    def get(self, bbox: BBox) -> ElevationRaster | None:
        p = self._path_for(bbox)
        if p.is_file():
            return ElevationRaster(path=p, bbox=bbox, source=self.name)
        return None

    def reserve(self, bbox: BBox) -> Path:
        """Where a downstream source should write the DEM it fetched."""
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        return self._path_for(bbox)


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
        dest = (
            self._write_back.reserve(bbox)
            if self._write_back is not None
            else Path(f"{bbox_key(bbox)}.tif")
        )
        try:
            written = self._fetch(self.base_url, bbox, dest)
        except Exception:  # noqa: BLE001 — a fetch failure is a miss, not a raise
            return None
        if written is None or not Path(written).is_file():
            return None
        return ElevationRaster(path=Path(written), bbox=bbox, source=self.name)


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

    def sampler_for(self, bbox: BBox) -> ElevationSampler:
        """Resolve `bbox` and hand back a sampler over the result.

        On :class:`ElevationUnavailable` returns a degraded (all-`0.0`) sampler
        rather than raising — elevation is never the reason planning stops
        (FR88). The returned sampler does no network I/O, so it is safe to pass
        into a solve.
        """
        try:
            raster = self.resolve(bbox)
        except ElevationUnavailable:
            return ElevationSampler(Path(f"__unresolved__/{bbox_key(bbox)}.tif"))
        return ElevationSampler(raster.path)


def phase1_resolver(cache_dir: str | Path, *, fetch: Fetcher | None = None) -> ElevationResolver:
    """MVP wiring: local cache, then the direct provider (FR62)."""
    cache = LocalCacheSource(cache_dir)
    return ElevationResolver(
        [cache, DirectProviderSource(fetch=fetch, write_back=cache)]
    )


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
