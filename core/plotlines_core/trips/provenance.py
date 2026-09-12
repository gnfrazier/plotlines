"""L7 (issue #270) — the `Provenance` producer.

`trips/payload.py` declares `Provenance`/`Attribution` and `$defs/provenance`
carries the same shape in the schema (SPIKE-20), but before this module
nothing in `core/plotlines_core/` ever constructed one — zero `Provenance(`
call sites outside test fixtures — even though the client already reads it
(`client/lib/domain/trip.dart`; `reveal_view.dart`'s `attributionForTrip()`
merges `trip.provenance?.attribution` with the static credits). A declared
contract with a live consumer and no producer.

Kept out of `trips/compose.py` on purpose: `compose_day`/`split_trip` are
ARCH §6.1's pure functions over plain data, and assembling a `Provenance`
needs a live `LayerRegistry` (to derive the attribution list) plus the
running app's version strings — neither belongs in that signature. The
caller (the sidecar's `POST /trips/split` handler) builds a `Trip` with
`split_trip` and then calls `build_provenance` here to fill the one slot
that function never touches.
"""

from __future__ import annotations

from plotlines_core.graph.regions import overpass_source_pin
from plotlines_core.web.about import about_attributions

from .payload import Attribution, Provenance


def build_provenance(
    registry,
    *,
    app_version: str,
    fetched_at: str,
    sidecar_version: str | None = None,
    produced_by: str | None = None,
) -> Provenance:
    """Assemble the `Provenance` for a payload being written right now.

    The attribution list reuses `web.about.about_attributions` — the same
    dynamic derivation `GET /about` and `GET /attribution` already return
    (the four static obligations plus every ready loaded layer, never a
    hardcoded list). That includes the routing graph's own ODbL credit
    (issue #269), which is the concrete payoff addendum L7 names: an
    exported cue sheet or FIT course now carries that credit itself
    rather than relying on the About screen alone.

    `osm_source` is Phase 1's honest value
    (`graph.regions.overpass_source_pin`): Overpass has no versioned
    snapshot to pin to, so the closest honest analogue is the transport
    plus `fetched_at` — the caller's own clock read (the service passes
    the trip's own `created_at`), which keeps this a pure mapping over
    its arguments rather than a second clock of its own.
    """
    attribution = [
        Attribution(
            source=line["layer"],
            licence=line["licence"],
            credit=line["attribution"],
            url=line.get("terms_url") or None,
        )
        for line in about_attributions(registry)
    ]
    return Provenance(
        produced_by=produced_by or f"plotlines-core {app_version}",
        app_version=app_version,
        sidecar_version=sidecar_version,
        osm_source=overpass_source_pin(fetched_at),
        attribution=attribution,
    )
