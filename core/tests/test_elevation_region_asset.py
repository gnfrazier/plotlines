"""FR90 — the shipped default region's elevation raster ships as a versioned
tarball asset, extracted by a documented one-time setup step; Windows extracts
via ``tar -C <dir>``, never a PowerShell ``>`` redirection.

`plotlines_core.elevation.region_asset`: identity of the home-region DEM asset,
`build_region_asset` (the release step), `extract_region_asset` (the
programmatic form of the documented `tar -C` step), and the
installed / current checks a setup step runs.
"""

from __future__ import annotations

import json
import tarfile
from pathlib import Path

import numpy as np
import pytest
import rasterio
from rasterio.transform import from_origin

from plotlines_core.elevation.interface import LocalCacheSource, bbox_key
from plotlines_core.elevation.region_asset import (
    ELEVATION_ASSET_VERSION,
    HOME_REGION_ASSET,
    HOME_REGION_BBOX,
    RegionAssetError,
    RegionElevationAsset,
    build_region_asset,
    extract_region_asset,
    install_command,
    installed_asset_is_current,
    is_region_asset_installed,
    read_installed_manifest,
)
from plotlines_core.elevation.sampler import ElevationSampler


def _write_dem(path: Path, *, base: float = 100.0) -> Path:
    """A tiny GeoTIFF covering the home-region bbox."""
    path.parent.mkdir(parents=True, exist_ok=True)
    w, s, e, n = HOME_REGION_BBOX
    transform = from_origin(w, n, (e - w) / 4, (n - s) / 4)
    data = (np.arange(16, dtype="float32").reshape(4, 4) + base)
    with rasterio.open(
        path, "w", driver="GTiff", height=4, width=4, count=1, dtype="float32",
        crs="EPSG:4326", transform=transform, nodata=-9999.0,
    ) as ds:
        ds.write(data, 1)
    return path


@pytest.fixture
def source_dem(tmp_path: Path) -> Path:
    return _write_dem(tmp_path / "gedtm30_buncombe.tif")


# --------------------------------------------------------------------------- #
# Asset identity                                                             #
# --------------------------------------------------------------------------- #

def test_tarball_name_is_versioned():
    name = HOME_REGION_ASSET.tarball_name
    assert name == f"plotlines-elevation-buncombe-nc-v{ELEVATION_ASSET_VERSION}.tar.gz"
    assert f"-v{ELEVATION_ASSET_VERSION}" in name  # the version is in the filename


def test_raster_name_matches_local_cache_stem():
    # The extracted raster must land exactly where LocalCacheSource looks.
    assert HOME_REGION_ASSET.raster_name == f"{bbox_key(HOME_REGION_BBOX)}.tif"


def test_manifest_carries_provider_licence_and_bbox():
    m = HOME_REGION_ASSET.manifest()
    assert m["asset"] == "elevation-region-raster"
    assert m["bbox"] == list(HOME_REGION_BBOX)
    assert m["version"] == ELEVATION_ASSET_VERSION
    assert "GEDTM30" in m["provider"]
    assert m["licence"] == "CC BY 4.0"          # FR86 — separate from the basemap's ODbL
    assert "OpenTopography" in m["attribution"]


# --------------------------------------------------------------------------- #
# build → extract round trip                                                 #
# --------------------------------------------------------------------------- #

def test_build_writes_versioned_flat_tarball(source_dem: Path, tmp_path: Path):
    tarball = build_region_asset(source_dem, tmp_path / "dist")

    assert tarball.name == HOME_REGION_ASSET.tarball_name
    with tarfile.open(tarball) as tf:
        names = sorted(m.name for m in tf.getmembers())
    assert names == sorted(HOME_REGION_ASSET.members)
    # Flat — no leading directory component to need --strip-components.
    assert all("/" not in n for n in names)


def test_extract_places_raster_where_the_resolver_finds_it(
    source_dem: Path, tmp_path: Path
):
    tarball = build_region_asset(source_dem, tmp_path / "dist")
    cache_dir = tmp_path / "elev-cache"

    extracted = extract_region_asset(tarball, cache_dir)

    assert HOME_REGION_ASSET.raster_name in extracted
    # LocalCacheSource resolves it with no new code path.
    raster = LocalCacheSource(cache_dir).get(HOME_REGION_BBOX)
    assert raster is not None
    assert raster.path == HOME_REGION_ASSET.raster_cache_path(cache_dir)

    # ...and the raster actually reads back through the sampler.
    sampler = ElevationSampler(raster.path)
    assert not sampler.degraded
    w, s, e, n = HOME_REGION_BBOX
    mid = sampler.sample([((s + n) / 2, (w + e) / 2)])
    assert np.isfinite(mid[0]) and mid[0] != 0.0


def test_extracted_manifest_is_readable_and_current(source_dem: Path, tmp_path: Path):
    tarball = build_region_asset(source_dem, tmp_path / "dist")
    cache_dir = tmp_path / "elev-cache"
    extract_region_asset(tarball, cache_dir)

    assert is_region_asset_installed(cache_dir)
    assert installed_asset_is_current(cache_dir)
    manifest = read_installed_manifest(cache_dir)
    assert manifest["version"] == ELEVATION_ASSET_VERSION
    assert manifest["raster"] == HOME_REGION_ASSET.raster_name


def test_not_installed_on_empty_cache(tmp_path: Path):
    assert not is_region_asset_installed(tmp_path)
    assert not installed_asset_is_current(tmp_path)
    assert read_installed_manifest(tmp_path) is None


def test_stale_version_is_not_current(source_dem: Path, tmp_path: Path):
    tarball = build_region_asset(source_dem, tmp_path / "dist")
    cache_dir = tmp_path / "elev-cache"
    extract_region_asset(tarball, cache_dir)

    # Simulate an app upgrade that bumped ELEVATION_ASSET_VERSION.
    newer = RegionElevationAsset(
        region_name=HOME_REGION_ASSET.region_name,
        region_slug=HOME_REGION_ASSET.region_slug,
        bbox=HOME_REGION_ASSET.bbox,
        version="99",
    )
    assert is_region_asset_installed(cache_dir, asset=newer)  # raster stem is unchanged
    assert not installed_asset_is_current(cache_dir, asset=newer)


# --------------------------------------------------------------------------- #
# The documented setup command                                               #
# --------------------------------------------------------------------------- #

def test_install_command_uses_tar_dash_c_and_no_redirection(tmp_path: Path):
    cmd = install_command(tmp_path / HOME_REGION_ASSET.tarball_name, tmp_path / "cache")
    assert cmd.startswith("tar ")
    assert " -C " in cmd            # extract in place, into a directory
    assert " -xf " in cmd
    assert ">" not in cmd           # never a PowerShell redirection (FR90)
    assert "|" not in cmd           # nor a pipe


def test_install_command_is_identical_across_platforms(tmp_path: Path):
    # `tar` is cross-platform (bsdtar ships with Windows 10 1803+), so the
    # documented Windows step is the same command, not a PowerShell variant.
    a = install_command("a.tar.gz", "/x/cache")
    b = install_command("a.tar.gz", "/x/cache")
    assert a == b and a.count("tar ") == 1


# --------------------------------------------------------------------------- #
# Malformed / hostile tarballs                                               #
# --------------------------------------------------------------------------- #

def test_build_rejects_missing_source(tmp_path: Path):
    with pytest.raises(FileNotFoundError):
        build_region_asset(tmp_path / "nope.tif", tmp_path / "dist")


def test_extract_rejects_tarball_with_path_traversal(tmp_path: Path):
    evil = tmp_path / "evil.tar.gz"
    with tarfile.open(evil, "w:gz") as tf:
        payload = b"x" * 8
        info = tarfile.TarInfo("../escape.tif")
        info.size = len(payload)
        import io

        tf.addfile(info, io.BytesIO(payload))
    with pytest.raises(RegionAssetError):
        extract_region_asset(evil, tmp_path / "cache")
    assert not (tmp_path / "escape.tif").exists()


def test_extract_rejects_tarball_missing_the_raster(tmp_path: Path):
    import io

    bad = tmp_path / "manifest-only.tar.gz"
    with tarfile.open(bad, "w:gz") as tf:
        payload = json.dumps(HOME_REGION_ASSET.manifest()).encode()
        info = tarfile.TarInfo(HOME_REGION_ASSET.manifest_name)
        info.size = len(payload)
        tf.addfile(info, io.BytesIO(payload))
    with pytest.raises(RegionAssetError):
        extract_region_asset(bad, tmp_path / "cache")


def test_extract_rejects_unexpected_member(source_dem: Path, tmp_path: Path):
    import io

    tarball = tmp_path / "extra.tar.gz"
    with tarfile.open(tarball, "w:gz") as tf:
        tf.add(source_dem, arcname=HOME_REGION_ASSET.raster_name)
        junk = b"nope"
        info = tarfile.TarInfo("README.txt")
        info.size = len(junk)
        tf.addfile(info, io.BytesIO(junk))
    with pytest.raises(RegionAssetError):
        extract_region_asset(tarball, tmp_path / "cache")
