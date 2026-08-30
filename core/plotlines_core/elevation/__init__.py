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
"""

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
from plotlines_core.elevation.sampler import ElevationSampler
from plotlines_core.elevation.void import VOID_FILL, VoidLog, resolve_voids

__all__ = [
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
    "EnterpriseKeyRequired",
    "FREE_TIER_DAILY_CALL_CEILING",
    "FreeTierExhausted",
    "HttpElevationSource",
    "KeyTier",
    "LocalCacheSource",
    "MissingApiKey",
    "OPENTOPO_BASE_URL",
    "OPENTOPO_TERMS_URL",
    "OpenTopographyClient",
    "OpenTopographyKey",
    "PHASE1_POSTURE",
    "RATE_WINDOW",
    "TIER_TERMS",
    "TierTerms",
    "VOID_FILL",
    "VoidLog",
    "check_posture",
    "client_from_env",
    "phase1_resolver",
    "phase2_resolver",
    "resolve_voids",
]
