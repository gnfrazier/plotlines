"""FR90 — the shipped default region's elevation raster as a versioned tarball.

The **home region** (Buncombe County, NC — FR96 / ARCH D41, the same constant
extent the basemap ships under) needs a DEM on disk before any
elevation-dependent metric can be computed for a trip drawn inside it. Unlike a
trip bbox — whose DEM is fetched on demand from OpenTopography and is gated on
FR87 / issue #148 — the home region's raster is **shipped**: distributed out of
band as a *versioned tarball asset* and dropped into the local elevation cache
by a **one-time setup step**, documented in ``packaging/README.md``.

This module owns:

* the identity of that asset — region, bbox, version, provider, licence — and
  its canonical tarball / raster / manifest filenames
  (:class:`RegionElevationAsset`, :data:`HOME_REGION_ASSET`);
* :func:`build_region_asset`, which packs a source GeoTIFF into the versioned
  tarball — the release step ``packaging/build_elevation_asset.sh`` wraps;
* :func:`extract_region_asset`, the programmatic equivalent of the documented
  ``tar -C <cache-dir> -xf`` setup step, and :func:`install_command` which
  returns the exact shell command the docs show. The command is built around
  ``tar -C <dir>`` on **every** platform — Windows included — and never a
  PowerShell ``>`` redirection, which would corrupt the binary raster (FR90);
* :func:`is_region_asset_installed` / :func:`read_installed_manifest` /
  :func:`installed_asset_is_current`, so a caller can tell whether the shipped
  raster is in place — and current — without going near the network.

The extracted raster lands at exactly the path
:class:`~plotlines_core.elevation.interface.LocalCacheSource` already looks for
(``<cache-dir>/<bbox_key>.tif``), so nothing in ``interface.py`` changes: the
resolver finds the home-region DEM as an ordinary local-cache hit.
"""

from __future__ import annotations

import io
import json
import tarfile
from dataclasses import dataclass
from pathlib import Path

from plotlines_core.elevation.interface import BBox, bbox_key

#: Buncombe County, NC — the shipped home region (FR96, ARCH D41). A constant,
#: not a default: no override, no first-run prompt, no eager download. Same
#: rectangle the geocode/tile fixtures carry.
HOME_REGION_NAME = "Buncombe County, NC"
HOME_REGION_SLUG = "buncombe-nc"
HOME_REGION_BBOX: BBox = (-82.83, 35.36, -82.14, 35.79)

#: Bumped whenever the shipped raster's *contents* change — a new GEDTM30
#: build, a widened home-region rect. It is part of the tarball filename and is
#: recorded in the manifest, so a stale extract is detectable
#: (:func:`installed_asset_is_current`) rather than silently mixed in.
ELEVATION_ASSET_VERSION = "1"

#: The single elevation source (FR85, ARCH D20) — no secondary/fallback service.
ELEVATION_PROVIDER = (
    "GEDTM30 (Global Ensemble Digital Terrain Model, 30 m), distributed by OpenTopography"
)

#: CC BY — a separate obligation from the basemap's ODbL (FR86 vs FR95). Carried
#: in the manifest so an extracted raster keeps its licensing trail.
ELEVATION_LICENCE = "CC BY 4.0"
ELEVATION_LICENCE_ID = "CC-BY-4.0"
ELEVATION_ATTRIBUTION = (
    "Elevation: GEDTM30 (Global Ensemble Digital Terrain Model, 30 m) "
    "© OpenTopography and contributors — CC BY 4.0"
)
ELEVATION_TERMS_URL = "https://creativecommons.org/licenses/by/4.0/"


def elevation_attribution() -> dict:
    """The elevation raster's CC BY credit line, shaped like
    :func:`plotlines_core.tiles.mirror.basemap_attribution` and
    :meth:`plotlines_core.curation.attribution.LayerAttribution.as_dict` so the
    About surface (K10), `/attribution`, exports and printed cue sheets can list
    it in one list beside the basemap's ODbL line and the per-layer credits.

    It is always present — the home region ships a DEM (FR90), so an elevation
    obligation is always owed — and is a **separate obligation** from the
    basemap's ODbL (FR86 vs FR95), under a different licence."""
    return {
        "layer": "elevation",
        "licence": ELEVATION_LICENCE_ID,
        "attribution": ELEVATION_ATTRIBUTION,
        "builtin": True,
        "terms_url": ELEVATION_TERMS_URL,
    }

#: What the manifest's ``asset`` field always reads, so a reader can tell this
#: apart from any other tarball that might land in the same directory.
ASSET_KIND = "elevation-region-raster"


@dataclass(frozen=True)
class RegionElevationAsset:
    """Identity of one shipped region DEM: what it covers, which version it is,
    and where its files belong once extracted."""

    region_name: str
    region_slug: str
    bbox: BBox
    version: str = ELEVATION_ASSET_VERSION
    provider: str = ELEVATION_PROVIDER
    licence: str = ELEVATION_LICENCE
    attribution: str = ELEVATION_ATTRIBUTION

    @property
    def raster_name(self) -> str:
        """Filename the raster carries inside the tarball and on disk — the
        exact stem :class:`LocalCacheSource` resolves for this bbox, so an
        extract into the elevation cache dir needs no rename."""
        return f"{bbox_key(self.bbox)}.tif"

    @property
    def manifest_name(self) -> str:
        """Manifest filename, namespaced by bbox so several region assets can
        share one cache directory without colliding."""
        return f"{bbox_key(self.bbox)}.manifest.json"

    @property
    def tarball_name(self) -> str:
        """Versioned asset filename — the ``v<version>`` is what makes a stale
        download visible before it is ever extracted."""
        return f"plotlines-elevation-{self.region_slug}-v{self.version}.tar.gz"

    @property
    def members(self) -> tuple[str, ...]:
        """Exactly the files a well-formed asset tarball contains."""
        return (self.raster_name, self.manifest_name)

    def manifest(self) -> dict:
        return {
            "asset": ASSET_KIND,
            "region": self.region_name,
            "region_slug": self.region_slug,
            "bbox": list(self.bbox),
            "version": self.version,
            "raster": self.raster_name,
            "provider": self.provider,
            "licence": self.licence,
            "attribution": self.attribution,
        }

    def raster_cache_path(self, cache_dir: str | Path) -> Path:
        return Path(cache_dir) / self.raster_name

    def manifest_cache_path(self, cache_dir: str | Path) -> Path:
        return Path(cache_dir) / self.manifest_name


#: The one asset this repo ships.
HOME_REGION_ASSET = RegionElevationAsset(
    region_name=HOME_REGION_NAME,
    region_slug=HOME_REGION_SLUG,
    bbox=HOME_REGION_BBOX,
)


def _manifest_bytes(asset: RegionElevationAsset) -> bytes:
    return (
        json.dumps(asset.manifest(), indent=2, sort_keys=True).encode("utf-8") + b"\n"
    )


def build_region_asset(
    source_raster: str | Path,
    out_dir: str | Path,
    *,
    asset: RegionElevationAsset = HOME_REGION_ASSET,
) -> Path:
    """Pack ``source_raster`` (a GeoTIFF DEM covering ``asset.bbox``) into the
    versioned tarball ``asset.tarball_name`` under ``out_dir``; return its path.

    The release step. ``packaging/build_elevation_asset.sh`` wraps this so a
    maintainer with a freshly-clipped GEDTM30 GeoTIFF runs one command. The
    tarball is flat — ``<key>.tif`` + ``<key>.manifest.json`` at the root — so
    the documented setup step is a plain ``tar -C <cache-dir> -xf`` with no
    ``--strip-components`` to get wrong.
    """
    src = Path(source_raster)
    if not src.is_file():
        raise FileNotFoundError(f"source raster not found: {src}")

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    tarball = out / asset.tarball_name

    manifest = _manifest_bytes(asset)
    mtime = int(src.stat().st_mtime)

    with tarfile.open(tarball, "w:gz") as tf:
        raster_info = tf.gettarinfo(str(src), arcname=asset.raster_name)
        # Normalise ownership/permissions so the artifact is reproducible
        # regardless of who cut the release.
        raster_info.uid = raster_info.gid = 0
        raster_info.uname = raster_info.gname = ""
        raster_info.mode = 0o644
        with src.open("rb") as fh:
            tf.addfile(raster_info, fh)

        m_info = tarfile.TarInfo(asset.manifest_name)
        m_info.size = len(manifest)
        m_info.mtime = mtime
        m_info.mode = 0o644
        tf.addfile(m_info, io.BytesIO(manifest))

    return tarball


class RegionAssetError(RuntimeError):
    """A tarball that is not a well-formed region elevation asset — wrong
    members, a path that escapes the target directory, a missing raster."""


def _safe_members(
    tf: tarfile.TarFile, asset: RegionElevationAsset
) -> list[tarfile.TarInfo]:
    allowed = set(asset.members)
    picked: list[tarfile.TarInfo] = []
    for member in tf.getmembers():
        name = member.name
        if name.startswith("./"):
            name = name[2:]
        if not member.isfile():
            raise RegionAssetError(f"unexpected non-file member {member.name!r}")
        if name != Path(name).name or name in ("", ".", ".."):
            raise RegionAssetError(f"unsafe member path {member.name!r}")
        if name not in allowed:
            raise RegionAssetError(
                f"unexpected member {member.name!r} "
                f"(asset carries {sorted(allowed)})"
            )
        member.name = name
        picked.append(member)
    names = {m.name for m in picked}
    if asset.raster_name not in names:
        raise RegionAssetError(
            f"tarball is missing the raster {asset.raster_name!r}"
        )
    return picked


def extract_region_asset(
    tarball: str | Path,
    cache_dir: str | Path,
    *,
    asset: RegionElevationAsset = HOME_REGION_ASSET,
) -> list[str]:
    """Programmatic form of the documented one-time setup step.

    Extracts the asset tarball's members into ``cache_dir`` (the local
    elevation cache), where
    :class:`~plotlines_core.elevation.interface.LocalCacheSource` then resolves
    the raster as an ordinary local hit. Returns the extracted filenames.

    This mirrors ``tar -C <cache-dir> -xf <tarball>`` — a plain extraction into
    a directory, never a shell redirection (FR90). Members are checked against
    the asset's expected file set and each name is flattened to its basename,
    so a crafted archive cannot write outside ``cache_dir``.
    """
    dest = Path(cache_dir)
    dest.mkdir(parents=True, exist_ok=True)

    with tarfile.open(tarball, "r:*") as tf:
        members = _safe_members(tf, asset)
        extract_kwargs = {}
        if hasattr(tarfile, "data_filter"):  # py3.12+ / backports
            extract_kwargs["filter"] = "data"
        for member in members:
            tf.extract(member, path=dest, **extract_kwargs)

    return [m.name for m in members]


def install_command(
    tarball: str | Path,
    cache_dir: str | Path,
    *,
    asset: RegionElevationAsset = HOME_REGION_ASSET,
) -> str:
    """The exact one-time setup command the docs show — identical on POSIX and
    Windows, because ``tar`` is cross-platform (bsdtar ships with Windows 10
    1803+). ``-C <dir>`` extracts in place; there is no ``>`` redirection to
    corrupt the binary raster (FR90)."""
    return f'tar -C "{Path(cache_dir)}" -xf "{Path(tarball)}"'


def is_region_asset_installed(
    cache_dir: str | Path,
    *,
    asset: RegionElevationAsset = HOME_REGION_ASSET,
) -> bool:
    """True when the shipped raster is present and non-empty in ``cache_dir``."""
    p = asset.raster_cache_path(cache_dir)
    try:
        return p.is_file() and p.stat().st_size > 0
    except OSError:
        return False


def read_installed_manifest(
    cache_dir: str | Path,
    *,
    asset: RegionElevationAsset = HOME_REGION_ASSET,
) -> dict | None:
    """The manifest an earlier extract wrote, or ``None`` if absent/unreadable."""
    try:
        return json.loads(asset.manifest_cache_path(cache_dir).read_text("utf-8"))
    except (OSError, ValueError):
        return None


def installed_asset_is_current(
    cache_dir: str | Path,
    *,
    asset: RegionElevationAsset = HOME_REGION_ASSET,
) -> bool:
    """True when a raster is installed **and** its manifest records the version
    this build expects — the check a setup step runs to decide whether the
    one-time extract still needs doing after an app upgrade."""
    if not is_region_asset_installed(cache_dir, asset=asset):
        return False
    manifest = read_installed_manifest(cache_dir, asset=asset)
    return bool(manifest) and manifest.get("version") == asset.version
