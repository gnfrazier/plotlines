"""Attribution derived from the loaded layer set — PRD FR101 (story N5),
ARCH §12.2 / §13.4.

Three rules from ARCH §12.2, made mechanical:

- **Every layer declares its licence and attribution** in the data-input
  contract (`providers.LayerLicence`). A layer whose licence metadata is
  absent or unsatisfiable does not load — that gate lives in
  `registry.LayerRegistry.register_plugin` (refused at registration, D45),
  not here.
- **Attribution is derived from the loaded layer set at render time**, not
  hardcoded. `attributions_for` enumerates what is actually in use — the
  About surface, exports, and printed itineraries / cue sheets all read it.
- **The build check is dynamic.** `assert_attribution_complete` is the
  release-gate shape: a *loaded* layer that reaches a display surface with
  no attribution string is a **build failure**, not a render-time warning
  (FR101, consistent with FR86/FR95).
"""

from __future__ import annotations

from dataclasses import dataclass

from .providers import LayerLicence


class MissingAttributionError(RuntimeError):
    """Raised by `assert_attribution_complete` when a loaded layer would
    reach a display surface with no attribution. A build failure — the
    release gate fails, the itinerary is not produced."""


@dataclass(frozen=True)
class LayerAttribution:
    """One line of credit for one layer, ready to place on any surface."""

    layer: str
    licence_id: str
    attribution: str
    terms_url: str = ""
    builtin: bool = False

    def as_dict(self) -> dict:
        out = {
            "layer": self.layer,
            "licence": self.licence_id,
            "attribution": self.attribution,
            "builtin": self.builtin,
        }
        if self.terms_url:
            out["terms_url"] = self.terms_url
        return out


def _licence_of(provider) -> LayerLicence | None:
    lic = getattr(provider, "licence", None)
    if isinstance(lic, LayerLicence):
        return lic
    if isinstance(lic, str) and lic.strip():
        # Backward-compat: the built-in `OsmLayerProvider` still carries a
        # bare `"ODbL"` string. Treat it as a satisfiable OSM licence.
        from .providers import OSM_LICENCE

        return OSM_LICENCE if lic.strip() == "ODbL" else LayerLicence(id=lic)
    return None


def attributions_for(registry, layers: set[str] | None = None) -> list[LayerAttribution]:
    """The credit lines for `layers` (default: every ready layer in the
    registry). Ordered built-ins first, then plugins, each alphabetical —
    stable output for the About surface and for the build check."""
    ready = registry.ready_layers()
    wanted = ready if layers is None else (set(layers) & ready)
    detail = registry.per_layer_detail()

    out: list[LayerAttribution] = []
    for layer in sorted(wanted):
        provider = registry.provider(layer)
        if provider is None:
            continue
        lic = _licence_of(provider)
        if lic is None:
            continue
        out.append(LayerAttribution(
            layer=layer,
            licence_id=lic.id,
            attribution=lic.attribution,
            terms_url=lic.terms_url,
            builtin=bool(detail.get(layer, {}).get("builtin")),
        ))
    out.sort(key=lambda a: (not a.builtin, a.layer))
    return out


def assert_attribution_complete(registry, layers: set[str] | None = None) -> list[LayerAttribution]:
    """The release-gate check (FR101). Returns the attribution lines that
    *will* be shown; raises `MissingAttributionError` if any loaded,
    in-use layer has no attribution string to show — a build failure.
    """
    ready = registry.ready_layers()
    wanted = sorted(ready if layers is None else (set(layers) & ready))
    missing: list[str] = []
    lines: list[LayerAttribution] = attributions_for(registry, set(wanted))
    covered = {a.layer for a in lines if a.attribution.strip()}
    for layer in wanted:
        if layer not in covered:
            missing.append(layer)
    if missing:
        raise MissingAttributionError(
            "loaded layers with no attribution for a display surface: "
            + ", ".join(missing)
        )
    return lines
