"""Elevation: one interface for acquisition, one policy for voids, one gate on
the provider's licence.

See ARCH §6.2, §7.5, §12.1 and PRD M3 / M10 (FR62, FR85, FR87, FR88).

* :mod:`~plotlines_core.elevation.interface` — the single bbox-scoped interface
  (`ElevationResolver`) and its ordered source chain. Phase 1 is
  local-cache-then-direct-provider; Phase 2 inserts a shared cache ahead of the
  direct call, changing only order and base URL.
* :mod:`~plotlines_core.elevation.keys` — OpenTopography key tiering, the free
  tier's 50-calls/24 h ceiling, and the commercial-distribution refusal (FR87).
  Supplies the fetcher the interface's provider source is wired with.
* :mod:`~plotlines_core.elevation.sampler` — `ElevationSampler`, reads an
  already-acquired local GeoTIFF; never raises, never fetches.
* :mod:`~plotlines_core.elevation.void` — the `nodata` / NaN / out-of-bounds /
  unreadable-raster -> `0.0` policy, logged once per raster path.
* :mod:`~plotlines_core.elevation.enrich` — `enrich_elevation`, writes the
  sampled value onto every graph node and `elev_gain = max(0.0, elev[v] -
  elev[u])` onto every edge (FR89).
* :mod:`~plotlines_core.elevation.region_asset` — FR90: the shipped home
  region's DEM as a versioned tarball asset, with the build step, the
  documented `tar -C` one-time extract, and an "is it installed / current"
  check. The extracted raster is an ordinary `LocalCacheSource` hit.
"""

from plotlines_core.elevation.enrich import (
    ELEV_GAIN_KEY,
    ELEVATION_KEY,
    EnrichmentReport,
    enrich_elevation,
    enrich_from_resolver,
)
from plotlines_core.elevation.interface import (
    OPENTOPO_BASE_URL,
    BBox,
    DirectProviderSource,
    ElevationRaster,
    ElevationResolver,
    ElevationSource,
    ElevationUnavailable,
    HttpElevationSource,
    LocalCacheSource,
    phase1_resolver,
    phase1_resolver_for_layout,
    phase2_resolver,
)
from plotlines_core.elevation.keys import (
    FREE_TIER_DAILY_CALL_CEILING,
    OPENTOPO_TERMS_URL,
    PHASE1_POSTURE,
    RATE_WINDOW,
    TIER_TERMS,
    CallLedger,
    DistributionPosture,
    ElevationKeyError,
    EnterpriseKeyRequired,
    FreeTierExhausted,
    KeyTier,
    MissingApiKey,
    OpenTopographyClient,
    OpenTopographyKey,
    TierTerms,
    check_posture,
    client_from_env,
)
from plotlines_core.elevation.region_asset import (
    ASSET_KIND,
    ELEVATION_ASSET_VERSION,
    ELEVATION_ATTRIBUTION,
    ELEVATION_LICENCE,
    ELEVATION_PROVIDER,
    HOME_REGION_ASSET,
    HOME_REGION_BBOX,
    HOME_REGION_NAME,
    HOME_REGION_SLUG,
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
from plotlines_core.elevation.void import VOID_FILL, VoidLog, resolve_voids

__all__ = [
    "ASSET_KIND",
    "ELEVATION_ASSET_VERSION",
    "ELEVATION_ATTRIBUTION",
    "ELEVATION_KEY",
    "ELEVATION_LICENCE",
    "ELEVATION_PROVIDER",
    "ELEV_GAIN_KEY",
    "FREE_TIER_DAILY_CALL_CEILING",
    "HOME_REGION_BBOX",
    "HOME_REGION_NAME",
    "HOME_REGION_SLUG",
    "OPENTOPO_BASE_URL",
    "OPENTOPO_TERMS_URL",
    "PHASE1_POSTURE",
    "RATE_WINDOW",
    "TIER_TERMS",
    "VOID_FILL",
    "BBox",
    "CallLedger",
    "DirectProviderSource",
    "DistributionPosture",
    "ElevationKeyError",
    "ElevationRaster",
    "ElevationResolver",
    "ElevationSampler",
    "ElevationSource",
    "ElevationUnavailable",
    "EnrichmentReport",
    "EnterpriseKeyRequired",
    "FreeTierExhausted",
    "HOME_REGION_ASSET",
    "HttpElevationSource",
    "KeyTier",
    "LocalCacheSource",
    "MissingApiKey",
    "OpenTopographyClient",
    "OpenTopographyKey",
    "RegionAssetError",
    "RegionElevationAsset",
    "TierTerms",
    "VoidLog",
    "build_region_asset",
    "check_posture",
    "client_from_env",
    "enrich_elevation",
    "enrich_from_resolver",
    "extract_region_asset",
    "install_command",
    "installed_asset_is_current",
    "is_region_asset_installed",
    "phase1_resolver",
    "phase1_resolver_for_layout",
    "phase2_resolver",
    "read_installed_manifest",
    "resolve_voids",
]
