"""The four routing-graph data-input Protocols — ARCH §14.2, PRD FR84.

These are the *other* half of the data-input direction. `LayerProvider`
(`curation/providers.py`) supplies **candidates for curation** and was
specified and delivered at Leg 2.5 because the layer picker and co-location
analysis read it (FR100, B4). These four supply **annotation for the routing
graph and the waterway network** — traffic, closures, realtime conditions,
gauges — and stay Leg 7, where `SPIKE-17` has not run
(`docs/Plotlines_Research_Spikes.md`).

**Interfaces only, and deliberately so.** Core ships zero implementations of
them: the OSM defaults reach the graph through `graph/loader.py`, not through
a registered provider. FR84's claim is that the interface is *clean* — that a
third-party dataset can be added without touching core (ARCH §14.4, P6) — and
the honest way to hold that claim open until SPIKE-17 measures it is to
declare the shape and ship nothing behind it.

**What is deliberately not decided here.** SPIKE-17's questions are the
registration/packaging story, the fetch-and-annotate cost against a real graph
build, the TTL a source's actual volatility justifies (P7), and what a *stale*
annotation surfaces to the Author. None of those is answered by a Protocol,
and none is guessed at below. What is fixed is the shape of a call.

**`WaterwayGraph` is the one member here with a measurement behind it**
(D27, SPIKE-19) — see `WaterwayReach`.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Protocol, runtime_checkable

from ..curation.notability import RawFeature
from ..curation.providers import BBox

if TYPE_CHECKING:  # networkx is a core dependency but this module needs it
    import networkx as nx  # only as a type, so the import stays type-only.

__all__ = [
    "EdgeDataProvider",
    "NodeDataProvider",
    "ShapeDataProvider",
    "WaterwayDataProvider",
    "WaterwayGraph",
    "WaterwayReach",
]


@runtime_checkable
class EdgeDataProvider(Protocol):
    """Annotates an already-built routing graph with a source's own edge
    attributes — traffic, closures, surface reports, realtime conditions.

    **Annotation, never construction.** The graph arrives built
    (`graph/loader.py`); a provider adds attributes to edges it recognises and
    returns it. A provider that needs to add or remove edges is asking for a
    different seam, and the answer is to fix the seam rather than special-case
    the plugin (ARCH §14.4).

    **Whatever it adds is advisory unless a requirement says otherwise.** A
    closure or a traffic reading surfaces and warns; it does not exclude an
    edge. Mode-legality (FR128) is the constraint category and it is decided
    in `routing/access.py`, not here — an advisory promoted to a constraint
    takes a judgement away from the Author.
    """

    def annotate_edges(self, graph: "nx.MultiDiGraph", bbox: BBox) -> "nx.MultiDiGraph": ...


@runtime_checkable
class NodeDataProvider(Protocol):
    """Point features for the routing graph's own use — gates, fords, water
    points, closures at a location.

    Returns `RawFeature`s, the same type `LayerProvider` extraction produces,
    rather than a second raw-feature shape: `id`, `coord`, `tags`, and an
    optional exterior ring are what a source can honestly supply, and the two
    halves of the input direction having one raw shape is most of what makes
    the interface "clean" (FR84).

    `categories` is a **seed set the caller asks for, not the vocabulary a
    provider may answer in** — a provider that knows a category nobody has
    enumerated yet returns it and tags it, rather than dropping it silently
    (PRD D-L). This is the same discipline as the notability ruleset: the rule
    is written beside the list.
    """

    def fetch_nodes(self, bbox: BBox, categories: list[str]) -> list[RawFeature]: ...


@runtime_checkable
class ShapeDataProvider(Protocol):
    """Area features — closures, restricted zones, land-manager boundaries.

    This one predates v2.0 and is the reason area support was an extension
    rather than a rewrite (ARCH §14.2): the provider layer carried polygons
    while v1.0's PRD scoped them out. A returned `RawFeature` carries its
    exterior ring in `geometry` and its centroid in `coord`, so a consumer
    that only understands points still has one.
    """

    def fetch_shapes(self, bbox: BBox, kinds: list[str]) -> list[RawFeature]: ...


@dataclass(frozen=True)
class WaterwayReach:
    """One reach of the waterway network, carrying **both** join keys.

    D27 / SPIKE-19, measured over 112 real-time gauges in three regions:
    `mainstem_id` binds 77.8% of gauges and `reach_code` 80.6%, they fail on
    *different* sites, and together they reach 94.4%. Carrying one key is not
    a simplification of this type — it is a ~17-point coverage loss, which is
    why both are fields rather than one being derived from the other.

    `mainstem_id` is a geoconnex.us URI drawn from **two disjoint registries**
    (0 of 933 ids overlap). Match the full URI; never normalise the prefix.
    `downstream_ids` is the topology, built by **inverting** the source's
    `dnhydrosequence` — one-to-many at confluences. `uphydrosequence` names
    only the main path and would silently drop every tributary.
    """

    id: str
    mainstem_id: str = ""
    reach_code: str = ""
    geometry: tuple[tuple[float, float], ...] = ()
    downstream_ids: tuple[str, ...] = ()

    @property
    def bindable(self) -> bool:
        """Whether this reach can be joined to a gauge at all. A reach with
        neither key is the measured ~5.6% residual: it yields **no signal**,
        which is never the same as a confirmed-passable reading (FR14's gauge
        bands are advisory — an unflagged advisory means "no contrary signal
        found")."""
        return bool(self.mainstem_id.strip()) or bool(self.reach_code.strip())


@dataclass(frozen=True)
class WaterwayGraph:
    """The reach network for a bbox. Plain data, like everything else that
    crosses this boundary (D28) — topology lives in `WaterwayReach`."""

    reaches: tuple[WaterwayReach, ...] = field(default_factory=tuple)

    @property
    def unbindable(self) -> tuple[WaterwayReach, ...]:
        """Reaches no gauge can be joined to, so a caller can report the gap
        rather than render silence as an all-clear."""
        return tuple(r for r in self.reaches if not r.bindable)


@runtime_checkable
class WaterwayDataProvider(Protocol):
    """The paddling network and its gauge linkage.

    Implement against USGS 3DHP (network) and USGS Water Data + NLDI (gauge,
    reach linkage), not OSM (D27, SPIKE-19). Gauge readings that come back
    through this seam are **advisory**: they surface and warn, they never
    reroute or exclude (FR14).
    """

    def fetch_waterways(self, bbox: BBox) -> WaterwayGraph: ...
