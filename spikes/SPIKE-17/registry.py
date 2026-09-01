"""An edge-provider registry with the licence gate the *input* side already
has — and which ARCH §14.2's annotation Protocols have no way to express.

`LayerProvider` declares `licence -> LayerLicence` and `load_state() ->
LayerLoadState`, and `curation/registry.py` refuses a layer whose licence is
absent or unsatisfiable **at registration, not at render** (D45, §12.2).
`EdgeDataProvider` declares neither. So this registry has to read both members
*structurally*, off objects that the Protocol does not require to have them —
which is the whole finding: a plugin edge source cannot be licence-gated or
readiness-tracked under the contract as written, while its data reaches the
Author's screen exactly like a layer's does.

Written here rather than proposed in prose so the gate can be run against the
real feeds: one of the two WZDx publishers this spike uses declares a licence
and the other does not.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from plotlines_core.curation.providers import LayerLicence


@dataclass
class Registration:
    source_id: str
    loaded: bool
    reason: str = ""
    licence: LayerLicence = field(default_factory=LayerLicence)

    def as_dict(self) -> dict:
        return {
            "source_id": self.source_id,
            "loaded": self.loaded,
            "reason": self.reason,
            "licence_id": self.licence.id,
            "attribution": self.licence.attribution,
            "satisfiable": self.licence.satisfiable,
        }


class EdgeProviderRegistry:
    """Registration-time licence gate over annotation providers."""

    def __init__(self) -> None:
        self.registrations: list[Registration] = []
        self._live: dict[str, object] = {}

    def register(self, provider) -> Registration:
        source_id = getattr(provider, "source_id", "") or repr(provider)

        # The provider must be asked to load before its licence can be read:
        # a feed declares its terms *inside the document*, not in its URL.
        # `LayerProvider.licence` is a property answerable before any fetch;
        # a feed source cannot honour that, and this is bend #3 in RESULTS §2.
        if hasattr(provider, "fetch"):
            provider.fetch()

        state = provider.load_state() if hasattr(provider, "load_state") else {"state": "ready"}
        if state.get("state") == "failed":
            reg = Registration(source_id, False, f"failed: {state.get('reason', '')}")
            self.registrations.append(reg)
            return reg

        licence = getattr(provider, "licence", None)
        if not isinstance(licence, LayerLicence) or not licence.satisfiable:
            note = getattr(licence, "note", "") if licence is not None else ""
            reg = Registration(source_id, False,
                               f"licence unsatisfiable ({note or 'nothing declared'})",
                               licence if isinstance(licence, LayerLicence) else LayerLicence())
            self.registrations.append(reg)
            return reg

        reg = Registration(source_id, True, "", licence)
        self.registrations.append(reg)
        self._live[source_id] = provider
        return reg

    @property
    def loaded(self) -> list:
        return list(self._live.values())

    def attributions(self) -> list[str]:
        """Every credit owed by the sources actually loaded — the same rule
        as `curation/attribution.attributions_for`, which is what a work-zone
        advisory shown on an Author's map surface would also owe."""
        return sorted(r.licence.attribution for r in self.registrations if r.loaded)

    def annotate_all(self, graph, bbox):
        for provider in self.loaded:
            graph = provider.annotate_edges(graph, bbox)
        return graph
