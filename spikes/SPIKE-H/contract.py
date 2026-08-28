"""The reconciled ARCH §14.2 `LayerProvider` contract — issue #160 (SPIKE-H).

SPIKE-D (#159) found the contract was never implemented as written:
`core/plotlines_core/curation/providers.py` ships

    class LayerProvider(Protocol):
        licence: str
        def fetch(self, bbox: BBox, layers: set[str]) -> list[RawFeature]: ...

against ARCH §14.2's

    class LayerProvider(Protocol):
        @property
        def licence(self) -> LayerLicence: ...
        @property
        def taxonomy(self) -> TypeTaxonomy: ...
        def fetch_candidates(self, bbox: BBox) -> list[Candidate]: ...
        def load_state(self) -> LayerLoadState: ...

This module is the second shape, built once so every provider in this spike
(built-in OSM and three real external sources) can be written *against* it —
the same discipline `spikes/SPIKE-D/plugin_layers.py` used for the per-layer
registry. **Nothing here is a patch to `core/`.** It imports and reuses
core's real `Candidate`, `RawFeature`, `BBox` and `TypeRule` — the shapes the
protocol's own signatures name — rather than inventing spike-local
substitutes, so what this spike measures is whether core's *existing* pieces
can be assembled behind the real interface, not whether a parallel
implementation can be made to work.

**`TypeTaxonomy` needed no new shape.** ARCH's own line — "each type
declares a primary role affinity and a salience weight" — is `TypeRule`
verbatim (`core/plotlines_core/curation/taxonomy.py`). This spike does not
invent a rival record type; a `TypeTaxonomy` here is `tuple[TypeRule, ...]`.

**Notability scoring must move from the caller to the provider.** Core's
`score_notability(features, live_layers)` matches every feature against the
one module-level `taxonomy.TAXONOMY` tuple. That is fine for a single
built-in source, but it is exactly the seam ARCH §14.4 forbids a plugin from
needing: for a plugin's own types to be scored, either its rows must be
merged into `TAXONOMY` (a core-code edit, one per plugin) or the scoring
function must be told which taxonomy to use. `fetch_candidates(bbox) ->
list[Candidate]` on the protocol says the latter: a provider scores against
*its own* declared taxonomy and returns finished `Candidate`s, never raw
features for someone else to match. `score_with_taxonomy` below is
`notability.score_notability`'s matching logic, parameterised on a taxonomy
instead of closed over the global one — see `results/RESULTS.md` §1 for why
this, not a shared registry-side merge, is the reading that keeps §14.4
intact.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Protocol

import _paths  # noqa: F401 — sys.path side effect

from plotlines_core.curation.notability import Candidate, RawFeature
from plotlines_core.curation.providers import BBox
from plotlines_core.curation.taxonomy import TypeRule

__all__ = [
    "BBox", "Candidate", "RawFeature", "TypeRule",
    "LayerLicence", "TypeTaxonomy", "LayerLoadState",
    "PENDING", "LOADING", "READY", "FAILED",
    "LayerProvider", "score_with_taxonomy", "match_in",
]

TypeTaxonomy = tuple[TypeRule, ...]


@dataclass(frozen=True)
class LayerLicence:
    """FR101 — what a layer must declare before it is loadable (D45: enforced
    at registration, not here). `id` and `attribution` are both required for
    `satisfiable` to be true; a source that supplies neither (§ RESULTS §5's
    NC Highway Historical Markers, verified live) is honestly unsatisfiable
    rather than guessed at. `note` records where the value came from — the
    service's own metadata, or asserted by the plugin author, which is the
    realistic case for most government REST sources (none of the three
    tested here publish a machine-readable licence field at all)."""

    id: str = ""
    attribution: str = ""
    terms_url: str = ""
    note: str = ""

    @property
    def satisfiable(self) -> bool:
        return bool(self.id) and bool(self.attribution)


PENDING, LOADING, READY, FAILED = "pending", "loading", "ready", "failed"


@dataclass
class LayerLoadState:
    """ARCH §8.3 / D48's per-layer readiness, returned by the provider
    itself. A provider's own `load_state()` says whether *it* is usable; the
    licence gate is a separate, registry-side refusal to ever call it (D45)
    — a provider can honestly report `ready` and still never be queried."""

    state: str
    reason: str = ""
    progress: float | None = None

    def as_dict(self) -> dict:
        out: dict = {"state": self.state}
        if self.reason:
            out["reason"] = self.reason
        if self.progress is not None:
            out["progress"] = round(self.progress, 2)
        return out


class LayerProvider(Protocol):
    """ARCH §14.2, unamended — the shape this spike tests, not the reduced
    one `core/plotlines_core/curation/providers.py` ships today."""

    @property
    def licence(self) -> LayerLicence: ...

    @property
    def taxonomy(self) -> TypeTaxonomy: ...

    def fetch_candidates(self, bbox: BBox) -> list[Candidate]: ...

    def load_state(self) -> LayerLoadState: ...


# --------------------------------------------------------------------------- #
# `notability.match` / `weight_for`, parameterised on a taxonomy instead of
# closed over the module-global `TAXONOMY` — see the module docstring.
# --------------------------------------------------------------------------- #

def match_in(taxonomy: TypeTaxonomy, tags) -> TypeRule | None:
    """`taxonomy.match`, verbatim, against a caller-supplied taxonomy rather
    than the global `TAXONOMY` tuple. An exact key=value rule wins over a
    wildcard on the same key, exactly as core's version does."""
    exact = None
    wildcard = None
    for rule in taxonomy:
        if rule.key not in tags:
            continue
        if not rule.is_wildcard and tags[rule.key] == rule.value:
            exact = rule
        elif rule.is_wildcard and wildcard is None:
            wildcard = rule
    return exact or wildcard


def score_with_taxonomy(
    features: Iterable[RawFeature],
    taxonomy: TypeTaxonomy,
    live_layers: Iterable[str],
) -> list[Candidate]:
    """`notability.score_notability`'s body, unmodified except for reading
    `taxonomy` instead of the global. This is the function each provider's
    `fetch_candidates` calls against its *own* taxonomy — the mechanism that
    keeps a plugin's scoring out of core's global table (see module
    docstring). Ranking, the qualification gate, and the uncatalogued-
    wildcard floor are identical to core's."""
    from plotlines_core.curation.taxonomy import weight_for as _weight_for

    live = set(live_layers)
    out: list[Candidate] = []
    for feature in features:
        rule = match_in(taxonomy, feature.tags)
        if rule is None or rule.layer not in live:
            continue
        if not rule.qualification.satisfied_by(feature.tags, feature.area_m2):
            continue
        out.append(Candidate(
            id=feature.id,
            coord=feature.coord,
            layer=rule.layer,
            salience=_weight_for(rule, feature.tags),
            role_affinity=rule.role_affinity,
            tags=dict(feature.tags),
            title=feature.tags.get("name"),
        ))
    out.sort(key=lambda c: c.salience, reverse=True)
    return out
