"""FR94 — the elevation cache follows the identical pattern under a separate
cache, scoped by the trip bbox (issue #152).

These pin the elevation half of FR94: `phase1_resolver_for_layout` roots the
bbox-scoped DEM cache at `CacheLayout.elevation_dir` — a sibling of the tile
cache, never comingled — and both an on-demand OpenTopography fetch and the
shipped FR90 home-region tarball resolve there as an ordinary local hit.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import rasterio
from rasterio.transform import from_origin

from plotlines_core.cache_layout import CacheLayout, trip_bbox_key
from plotlines_core.elevation.interface import (
    ElevationResolver,
    LocalCacheSource,
    phase1_resolver,
    phase1_resolver_for_layout,
)
from plotlines_core.elevation.region_asset import (
    HOME_REGION_ASSET,
    HOME_REGION_BBOX,
    build_region_asset,
    extract_region_asset,
)
from plotlines_core.elevation.sampler import ElevationSampler

_BBOX = (10.0, 46.0, 14.0, 50.0)
_TRANSFORM = from_origin(10.0, 50.0, 1.0, 1.0)


def _write_dem(path: Path, base: float = 100.0) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = np.arange(16, dtype="float32").reshape(4, 4) + base
    with rasterio.open(
        path, "w", driver="GTiff", height=4, width=4, count=1, dtype="float32",
        crs="EPSG:4326", transform=_TRANSFORM, nodata=-9999.0,
    ) as ds:
        ds.write(data, 1)
    return path


def _home_region_dem(path: Path, base: float = 100.0) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    w, s, e, n = HOME_REGION_BBOX
    transform = from_origin(w, n, (e - w) / 4, (n - s) / 4)
    data = np.arange(16, dtype="float32").reshape(4, 4) + base
    with rasterio.open(
        path, "w", driver="GTiff", height=4, width=4, count=1, dtype="float32",
        crs="EPSG:4326", transform=transform, nodata=-9999.0,
    ) as ds:
        ds.write(data, 1)
    return path


def test_resolver_for_layout_roots_the_dem_cache_at_elevation_dir(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    resolver = phase1_resolver_for_layout(layout)

    local = resolver.sources[0]
    assert isinstance(local, LocalCacheSource)
    assert local.cache_dir == layout.elevation_dir
    # A sibling of the tile cache, never the same directory.
    assert local.cache_dir != layout.tiles_dir
    assert local.cache_dir.parent == layout.tiles_dir.parent


def test_the_dem_lands_in_the_elevation_cache_keyed_by_the_trip_bbox(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    _write_dem(layout.elevation_raster(_BBOX))

    raster = phase1_resolver_for_layout(layout).resolve(_BBOX)

    assert raster.source == "local-cache"
    assert raster.path == layout.elevation_dir / f"{trip_bbox_key(_BBOX)}.tif"
    assert raster.path.parent == layout.elevation_dir


def test_on_demand_fetch_writes_back_into_the_separate_elevation_cache(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    calls: list[str] = []

    def fake_fetch(base_url: str, bbox, dest: Path) -> Path:
        calls.append(base_url)
        return _write_dem(Path(dest), base=50.0)

    resolver = phase1_resolver_for_layout(layout, fetch=fake_fetch)

    # miss -> provider -> write-back
    first = resolver.resolve(_BBOX)
    assert first.source == "direct-provider"
    assert first.path == layout.elevation_raster(_BBOX)
    assert layout.elevation_raster(_BBOX).is_file()

    # second resolve is a local hit — on-demand, fetched once (P7)
    second = resolver.resolve(_BBOX)
    assert second.source == "local-cache"
    assert calls == [resolver.sources[-1].base_url]


def test_layout_rooted_cache_matches_a_plain_phase1_resolver_on_the_same_dir(tmp_path: Path) -> None:
    """`phase1_resolver_for_layout(layout)` is exactly `phase1_resolver` on
    `layout.elevation_dir` — same order, same sources, same paths."""
    layout = CacheLayout(tmp_path)
    a = phase1_resolver_for_layout(layout)
    b = phase1_resolver(layout.elevation_dir)
    assert a.source_names == b.source_names
    assert a.sources[0].cache_dir == b.sources[0].cache_dir


def test_shipped_fr90_tarball_resolves_from_the_separate_elevation_cache(tmp_path: Path) -> None:
    """The FR90 home-region raster, extracted into `CacheLayout.elevation_dir`
    (per packaging/README.md), is an ordinary local-cache hit for the resolver."""
    src = _home_region_dem(tmp_path / "gedtm30_buncombe.tif")
    tarball = build_region_asset(src, tmp_path / "dist")

    layout = CacheLayout(tmp_path / "app-support").ensure_dirs()
    extracted = extract_region_asset(tarball, layout.elevation_dir)
    assert HOME_REGION_ASSET.raster_name in extracted

    raster = phase1_resolver_for_layout(layout).resolve(HOME_REGION_BBOX)
    assert raster.source == "local-cache"
    assert raster.path == layout.elevation_raster(HOME_REGION_BBOX)

    sampler = ElevationSampler(raster.path)
    assert not sampler.degraded


def test_tile_and_elevation_caches_do_not_share_a_directory(tmp_path: Path) -> None:
    layout = CacheLayout(tmp_path)
    _write_dem(layout.elevation_raster(_BBOX))
    layout.tiles_dir.mkdir(parents=True, exist_ok=True)

    # Wiping the tile cache leaves the elevation cache untouched, and vice versa.
    import shutil

    shutil.rmtree(layout.tiles_dir)
    assert layout.elevation_raster(_BBOX).is_file()
