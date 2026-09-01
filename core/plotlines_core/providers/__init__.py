"""The data-input half of FR84's two-way interface — one page for a plugin
author to read (ARCH §14.1, §14.2).

FR84 splits across two legs. **Data input** runs in `plotlines-core` and is
no longer open: `LayerProvider` was specified and delivered at Leg 2.5 (FR100,
breaking change B4), because the layer picker and co-location analysis read
it. **Output** — pushing a finished trip to Garmin / Coros / Wahoo /
RideWithGPS — is Dart-side and keeps its deliberately open contract shape at
Leg 7; its seam is `client/lib/data/plugins/` and it runs on the device
because it holds the user's OAuth token (§14.1: routing that through the
server would make the service a credential custodian for every user).

Two families live behind this one import site:

- **`LayerProvider`** — candidates for the curation pipeline. Specified,
  shipped, and validated against real external sources (SPIKE-H, #160). It
  lives in `curation/providers.py` next to the notability and taxonomy code
  that consumes it, and is re-exported here so a plugin author finds both
  directions of the contract in one place rather than two.
- **`EdgeDataProvider` / `NodeDataProvider` / `ShapeDataProvider` /
  `WaterwayDataProvider`** — annotation for the routing graph and the
  waterway network. Leg 7, `SPIKE-17` unrun: the call shapes are declared,
  nothing is implemented behind them, and the questions the spike owns
  (registration, cost, TTL, what a stale annotation surfaces) are left open
  rather than guessed. See `graph_data.py`.

**Core ships zero implementations of the four graph-data Protocols.** The
built-in OSM layers do implement `LayerProvider` — that is ARCH §14.2's
proof-of-realness test, and it passed — but nothing in core registers itself
as an edge, node, shape, or waterway provider. A plugin may not require a
change to core code; if it does, the extension point is wrong (§14.4, P6).
"""

from ..curation.providers import (
    FAILED,
    LOADING,
    PENDING,
    READY,
    BBox,
    LayerLicence,
    LayerLoadState,
    LayerProvider,
)
from .graph_data import (
    EdgeDataProvider,
    NodeDataProvider,
    ShapeDataProvider,
    WaterwayDataProvider,
    WaterwayGraph,
    WaterwayReach,
)

__all__ = [
    # shared
    "BBox",
    # data input — curation layers (Leg 2.5, FR100)
    "LayerProvider",
    "LayerLicence",
    "LayerLoadState",
    "PENDING",
    "LOADING",
    "READY",
    "FAILED",
    # data input — routing-graph annotation (Leg 7, SPIKE-17 unrun)
    "EdgeDataProvider",
    "NodeDataProvider",
    "ShapeDataProvider",
    "WaterwayDataProvider",
    "WaterwayGraph",
    "WaterwayReach",
]
