"""The built-in OSM sightseeing/amenity/natural/historic/leisure/man_made
layers, expressed as real `LayerProvider`s (ARCH §14.2's "proof of realness"
test, extended past the reduced `core/plotlines_core/curation/providers.py`
shape SPIKE-D found). Wraps core's *real* `OsmLayerProvider.fetch` and the
*real* `taxonomy.TAXONOMY` — no reimplementation.

**Where it had to bend (recorded for RESULTS §1):**

1. **`fetch_candidates(bbox)` takes no `layers` argument**, but Overpass is
   one network call per bbox regardless of how many ARCH-layers are asked
   for, and `OsmLayerProvider.fetch` is written to batch all six into one
   query. Six separate `BuiltinOsmLayerProvider` instances — one per
   ARCH-layer, as §14.2's "the built-in layers ... must be expressed as
   `LayerProvider` implementations" reads literally — would mean six
   Overpass calls for what is one query today. The adapter below shares one
   underlying fetch across sibling instances via `shared_cache`, keyed on
   bbox: each instance still satisfies the protocol (its own `taxonomy`, its
   own `fetch_candidates`), but the six only ever cost one network round
   trip between them. **This is a real tension the protocol's per-instance
   shape does not resolve on its own** — see RESULTS §1.
2. **Scoring moves inside the provider.** `taxonomy` is a slice of the real
   `TAXONOMY` filtered to this instance's ARCH-layer; `fetch_candidates`
   calls `contract.score_with_taxonomy` against that slice rather than the
   central `score_notability(features, live_layers=...)` the shipped
   `/candidates` endpoint calls today.
3. **No live Overpass call in this spike run.** SPIKE-D already measured
   `OsmLayerProvider.fetch` against the TRIP bbox and committed its output
   (`spikes/SPIKE-D/raw/trip-all.json.gz`); re-querying the same public
   commons for the same bbox days later would be the exact A23 risk that
   spike's own results warn against. `CachedOsmLayerProvider` reads that
   committed file. The extraction call itself (network latency, retry
   behaviour) is not this spike's question — it is SPIKE-D's, already
   answered.
"""

from __future__ import annotations

from typing import Optional

import _paths  # noqa: F401

from contract import (
    BBox, Candidate, LayerLicence, LayerLoadState, READY,
    score_with_taxonomy,
)
from plotlines_core.curation.notability import RawFeature
from plotlines_core.curation.taxonomy import LAYERS, TAXONOMY

_OSM_LICENCE = LayerLicence(
    id="ODbL-1.0",
    attribution="© OpenStreetMap contributors",
    terms_url="https://www.openstreetmap.org/copyright",
    note="hardcoded in core/plotlines_core/curation/providers.py:OsmLayerProvider.licence "
         "(currently the bare string 'ODbL', not a LayerLicence) — asserted by the "
         "integrator, same as every plugin's licence in this spike, not derived from "
         "an Overpass response.",
)


class SharedOsmFetch:
    """One bbox -> one `OsmLayerProvider.fetch` call, shared by however many
    per-ARCH-layer `BuiltinOsmLayerProvider` instances are registered — the
    workaround for bend #1 above. `loader` is injected so this spike can read
    SPIKE-D's committed cache instead of hitting Overpass (bend #3)."""

    def __init__(self, loader) -> None:
        self._loader = loader
        self._cache: dict[BBox, list[RawFeature]] = {}

    def features_for(self, bbox: BBox) -> list[RawFeature]:
        if bbox not in self._cache:
            self._cache[bbox] = self._loader(bbox)
        return self._cache[bbox]


class BuiltinOsmLayerProvider:
    """One ARCH-layer's worth of the built-in OSM taxonomy, as a real
    `LayerProvider`. `shared` supplies the (possibly cached) raw features so
    six sibling instances cost one fetch, not six (bend #1)."""

    def __init__(self, layer: str, shared: SharedOsmFetch) -> None:
        if layer not in LAYERS:
            raise ValueError(f"not a built-in ARCH layer: {layer}")
        self._layer = layer
        self._shared = shared

    @property
    def licence(self) -> LayerLicence:
        return _OSM_LICENCE

    @property
    def taxonomy(self):
        return tuple(r for r in TAXONOMY if r.layer == self._layer)

    def fetch_candidates(self, bbox: BBox) -> list[Candidate]:
        features = self._shared.features_for(bbox)
        return score_with_taxonomy(features, self.taxonomy, live_layers={self._layer})

    def load_state(self) -> LayerLoadState:
        # Built-in, synchronous, no warm-up — D48's "built-in OSM layers
        # unlock curation immediately."
        return LayerLoadState(READY)


def cached_trip_loader():
    """Reads `spikes/SPIKE-D/raw/trip-all.json.gz` — the real
    `OsmLayerProvider.fetch(TRIP, all-6-layers)` output SPIKE-D already
    measured and committed. Returns a `(bbox, loader)` pair for
    `SharedOsmFetch`, so this module never re-derives the TRIP box itself."""
    import gzip
    import json
    import sys
    from pathlib import Path

    spike_d = Path(__file__).resolve().parents[1] / "SPIKE-D"
    sys.path.insert(0, str(spike_d))
    from regions import TRIP  # noqa: E402

    raw_path = spike_d / "raw" / "trip-all.json.gz"

    def loader(_bbox: BBox) -> list[RawFeature]:
        # Ignores the bbox argument — this spike run only ever asks for
        # TRIP, and always reads SPIKE-D's committed extraction for it
        # rather than re-deriving or re-fetching (bend #3 above).
        with gzip.open(raw_path, "rt", encoding="utf-8") as fh:
            rows = json.load(fh)
        return [
            RawFeature(id=r["id"], coord=(r["coord"][0], r["coord"][1]),
                       tags=r["tags"], area_m2=r.get("area_m2"))
            for r in rows
        ]

    bbox = BBox(*TRIP.bbox_lonlat)
    return bbox, loader


def builtin_providers(shared: Optional[SharedOsmFetch] = None) -> dict[str, BuiltinOsmLayerProvider]:
    """One `BuiltinOsmLayerProvider` per ARCH-layer, sharing one fetch."""
    if shared is None:
        _, loader = cached_trip_loader()
        shared = SharedOsmFetch(loader)
    return {layer: BuiltinOsmLayerProvider(layer, shared) for layer in sorted(LAYERS)}
