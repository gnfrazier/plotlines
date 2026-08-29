"""M3 (issue #131, FR62 seam) — elevation requested for a bbox through one
interface, so inserting a shared cache later is a config change, not a rewrite.

`plotlines_core.elevation.interface`: `ElevationResolver` walks an ordered list
of sources. Phase 1 is [local-cache, direct-provider]; Phase 2 inserts a
shared-cache link ahead of the direct call. Going between the two changes only
the source list's order and a base URL — the resolver, the sources, the local
cache, and the sampler are untouched.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import rasterio
from rasterio.transform import from_origin

from plotlines_core.elevation.interface import (
    OPENTOPO_BASE_URL,
    DirectProviderSource,
    ElevationResolver,
    ElevationUnavailable,
    HttpElevationSource,
    LocalCacheSource,
    bbox_key,
    phase1_resolver,
    phase2_resolver,
)
from plotlines_core.elevation.sampler import ElevationSampler

_BBOX = (10.0, 46.0, 14.0, 50.0)
_TRANSFORM = from_origin(10.0, 50.0, 1.0, 1.0)


def _write_dem(path: Path, base: float) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (np.arange(16, dtype="float32").reshape(4, 4) + base)
    with rasterio.open(
        path, "w", driver="GTiff", height=4, width=4, count=1, dtype="float32",
        crs="EPSG:4326", transform=_TRANSFORM, nodata=-9999.0,
    ) as ds:
        ds.write(data, 1)
    return path


def _seed_cache(cache_dir: Path, bbox, base: float) -> Path:
    return _write_dem(Path(cache_dir) / f"{bbox_key(bbox)}.tif", base)


def _fake_fetch(marker: float, calls: list[str]):
    """A fetcher that writes a DEM whose first value is `marker`."""
    def fetch(base_url: str, bbox, dest: Path) -> Path:
        calls.append(base_url)
        return _write_dem(Path(dest), marker)
    return fetch


# --------------------------------------------------------------------------- #
# Phase 1: local-cache-then-direct-provider                                   #
# --------------------------------------------------------------------------- #

def test_phase1_source_order(tmp_path):
    r = phase1_resolver(tmp_path)
    assert r.source_names == ["local-cache", "direct-provider"]


def test_phase1_local_cache_hit(tmp_path):
    _seed_cache(tmp_path, _BBOX, base=500.0)
    r = phase1_resolver(tmp_path)
    raster = r.resolve(_BBOX)
    assert raster.source == "local-cache"
    assert raster.path == Path(tmp_path) / f"{bbox_key(_BBOX)}.tif"


def test_phase1_miss_falls_through_to_direct_provider_and_writes_back(tmp_path):
    calls: list[str] = []
    r = phase1_resolver(tmp_path, fetch=_fake_fetch(777.0, calls))

    first = r.resolve(_BBOX)
    assert first.source == "direct-provider"
    assert calls == [OPENTOPO_BASE_URL]

    # write-back: the fetched DEM landed in the local cache, so the next
    # resolve for the same bbox is a local hit with no further fetch.
    second = r.resolve(_BBOX)
    assert second.source == "local-cache"
    assert calls == [OPENTOPO_BASE_URL]


def test_phase1_unresolvable_raises_but_sampler_for_degrades(tmp_path):
    r = phase1_resolver(tmp_path)  # empty cache, no fetch wired
    try:
        r.resolve(_BBOX)
    except ElevationUnavailable:
        pass
    else:
        raise AssertionError("expected ElevationUnavailable")

    sampler = r.sampler_for(_BBOX)
    assert isinstance(sampler, ElevationSampler)
    assert sampler.degraded
    assert sampler.sample([(48.0, 12.0)]).tolist() == [0.0]


# --------------------------------------------------------------------------- #
# Phase 2: shared cache inserted ahead of the direct call                     #
# --------------------------------------------------------------------------- #

def test_phase2_inserts_one_link_and_a_base_url_only(tmp_path):
    p1 = phase1_resolver(tmp_path)
    p2 = phase2_resolver(tmp_path, "https://elevation.plotlines.example/dem")

    # same interface class, same method surface
    assert type(p1) is type(p2) is ElevationResolver
    assert hasattr(p2, "resolve") and hasattr(p2, "sampler_for")

    # the only structural difference is one inserted source
    assert p1.source_names == ["local-cache", "direct-provider"]
    assert p2.source_names == ["local-cache", "shared-cache", "direct-provider"]

    # the direct provider still points at the same unchanged base URL
    direct1 = p1.sources[-1]
    direct2 = p2.sources[-1]
    assert isinstance(direct1, DirectProviderSource)
    assert isinstance(direct2, DirectProviderSource)
    assert direct1.base_url == direct2.base_url == OPENTOPO_BASE_URL

    # the new link is the shared cache, distinguished only by its base URL
    shared = p2.sources[1]
    assert isinstance(shared, HttpElevationSource)
    assert shared.base_url == "https://elevation.plotlines.example/dem"


def test_local_cache_hit_resolves_identically_in_both_phases(tmp_path):
    _seed_cache(tmp_path, _BBOX, base=500.0)
    p1 = phase1_resolver(tmp_path)
    p2 = phase2_resolver(tmp_path, "https://elevation.plotlines.example/dem")

    r1 = p1.resolve(_BBOX)
    r2 = p2.resolve(_BBOX)
    assert r1 == r2
    assert r1.source == "local-cache"
    assert p1.sampler_for(_BBOX).sample([(48.0, 12.0)]).tolist() == \
           p2.sampler_for(_BBOX).sample([(48.0, 12.0)]).tolist()


def test_phase2_shared_cache_hit_short_circuits_the_direct_provider(tmp_path):
    shared_calls: list[str] = []
    direct_calls: list[str] = []

    cache = LocalCacheSource(tmp_path)
    resolver = ElevationResolver([
        cache,
        HttpElevationSource(
            "https://shared.example/dem", name="shared-cache",
            fetch=_fake_fetch(111.0, shared_calls), write_back=cache,
        ),
        DirectProviderSource(
            fetch=_fake_fetch(222.0, direct_calls), write_back=cache
        ),
    ])

    raster = resolver.resolve(_BBOX)
    assert raster.source == "shared-cache"
    assert shared_calls == ["https://shared.example/dem"]
    assert direct_calls == []  # direct provider never consulted


def test_phase2_shared_miss_falls_through_to_direct(tmp_path):
    direct_calls: list[str] = []
    cache = LocalCacheSource(tmp_path)
    resolver = ElevationResolver([
        cache,
        HttpElevationSource("https://shared.example/dem", name="shared-cache",
                            fetch=None, write_back=cache),  # miss: no fetch
        DirectProviderSource(fetch=_fake_fetch(222.0, direct_calls),
                             write_back=cache),
    ])
    raster = resolver.resolve(_BBOX)
    assert raster.source == "direct-provider"
    assert direct_calls == [OPENTOPO_BASE_URL]


def test_sampler_for_returns_a_working_sampler_over_the_resolved_dem(tmp_path):
    _seed_cache(tmp_path, _BBOX, base=200.0)
    r = phase1_resolver(tmp_path)
    sampler = r.sampler_for(_BBOX)
    assert not sampler.degraded
    # pixel (0,0) centre is lat 49.5, lon 10.5; value == base (200.0)
    assert sampler.sample([(49.5, 10.5)])[0] == 200.0
