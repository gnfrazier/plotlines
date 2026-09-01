"""FR84's data-input half, as an importable contract — ARCH §14.1, §14.2.

The claim under test is ARCH §14.4's: **a plugin may not require a change to
core code.** Every provider below is defined in this file, implements a core
Protocol structurally (no base class imported, no registration), and is
accepted — which is the only way "the interface is clean" is falsifiable
before SPIKE-17 runs against a real source.
"""

from __future__ import annotations

import plotlines_core.providers as providers
from plotlines_core.curation.notability import RawFeature
from plotlines_core.curation.providers import BBox
from plotlines_core.providers import (
    EdgeDataProvider,
    LayerProvider,
    NodeDataProvider,
    ShapeDataProvider,
    WaterwayDataProvider,
    WaterwayGraph,
    WaterwayReach,
)

_BBOX = BBox(-82.10, 35.90, -81.78, 36.12)


# ---------------------------------------------------------------- plugins --
# Written the way a third-party package would write them: local types, no
# core import beyond the value types the call signatures name.


class _TrafficPlugin:
    """An `EdgeDataProvider` that annotates and never restructures."""

    def annotate_edges(self, graph, bbox: BBox):
        for _, _, data in graph.edges(data=True):
            data["plugin_traffic"] = "heavy"
        return graph


class _GatePlugin:
    def fetch_nodes(self, bbox: BBox, categories: list[str]) -> list[RawFeature]:
        # `categories` is a seed set, not the vocabulary: this source answers
        # with a kind nobody asked for rather than dropping it (PRD D-L).
        return [
            RawFeature(id="gate/1", coord=(-81.95, 36.00), tags={"barrier": "gate"}),
            RawFeature(id="ford/1", coord=(-81.93, 36.01), tags={"ford": "yes"}),
        ]


class _ClosurePlugin:
    def fetch_shapes(self, bbox: BBox, kinds: list[str]) -> list[RawFeature]:
        ring = ((-81.96, 36.00), (-81.94, 36.00), (-81.94, 36.02), (-81.96, 36.00))
        return [RawFeature(id="closure/1", coord=(-81.95, 36.01),
                           tags={"access": "no"}, area_m2=51_000.0, geometry=ring)]


class _NhdPlugin:
    def fetch_waterways(self, bbox: BBox) -> WaterwayGraph:
        return WaterwayGraph(reaches=(
            WaterwayReach(id="r1", mainstem_id="https://geoconnex.us/ref/mainstems/1",
                          reach_code="03050101000001", downstream_ids=("r2", "r3")),
            WaterwayReach(id="r2", reach_code="03050101000002"),
            WaterwayReach(id="r3"),
        ))


# ---------------------------------------------------------- the two halves --


def test_both_halves_of_the_two_way_interface_import_from_one_place():
    """FR84 — a plugin author reads one page. The curation half is re-exported
    from `plotlines_core.providers` rather than living in a second import
    path only."""
    for name in ("LayerProvider", "LayerLicence", "LayerLoadState", "BBox",
                 "EdgeDataProvider", "NodeDataProvider", "ShapeDataProvider",
                 "WaterwayDataProvider"):
        assert hasattr(providers, name), name
        assert name in providers.__all__

    from plotlines_core.curation.providers import LayerProvider as CurationLayerProvider

    assert LayerProvider is CurationLayerProvider


def test_plugins_satisfy_the_protocols_with_no_core_change():
    """ARCH §14.4 — structural conformance, no base class, no registration."""
    assert isinstance(_TrafficPlugin(), EdgeDataProvider)
    assert isinstance(_GatePlugin(), NodeDataProvider)
    assert isinstance(_ClosurePlugin(), ShapeDataProvider)
    assert isinstance(_NhdPlugin(), WaterwayDataProvider)


def test_a_provider_of_the_wrong_family_is_not_accepted():
    assert not isinstance(_GatePlugin(), EdgeDataProvider)
    assert not isinstance(_TrafficPlugin(), WaterwayDataProvider)


def test_core_ships_no_implementation_of_the_graph_data_protocols():
    """The package is interfaces only (Leg 7, SPIKE-17 unrun). A concrete
    implementer appearing here would mean core had grown a privileged
    internal path of exactly the kind §14.2's realness test exists to
    prevent."""
    protocols = (EdgeDataProvider, NodeDataProvider, ShapeDataProvider,
                 WaterwayDataProvider)
    for name in providers.__all__:
        obj = getattr(providers, name)
        if obj in protocols or isinstance(obj, str):
            continue
        assert not any(isinstance(obj, p) for p in protocols), name


# ------------------------------------------------------- the one measurement --


def test_a_reach_needs_only_one_join_key_to_bind_and_both_are_kept():
    """D27 / SPIKE-19: `mainstem_id` binds 77.8%, `reach_code` 80.6%, they
    fail on different sites, together 94.4%. Both are carried; either alone
    is enough to bind."""
    both = WaterwayReach(id="r1", mainstem_id="https://geoconnex.us/ref/mainstems/1",
                         reach_code="03050101000001")
    assert both.bindable
    assert WaterwayReach(id="r2", reach_code="03050101000002").bindable
    assert WaterwayReach(id="r3", mainstem_id="https://geoconnex.us/ref/mainstems/9").bindable
    assert not WaterwayReach(id="r4").bindable
    assert not WaterwayReach(id="r5", mainstem_id="  ", reach_code=" ").bindable


def test_mainstem_id_is_the_full_uri_never_a_normalised_prefix():
    """Two disjoint geoconnex registries, 0 of 933 ids overlapping — the
    stored value is the URI the source gave, verbatim."""
    uri = "https://geoconnex.us/ref/mainstems/1234"
    assert WaterwayReach(id="r1", mainstem_id=uri).mainstem_id == uri


def test_unbindable_reaches_are_reported_rather_than_silently_dropped():
    """The ~5.6% residual yields *no signal*, which an advisory surface must
    never render as a clear reading (FR14)."""
    graph = _NhdPlugin().fetch_waterways(_BBOX)
    assert [r.id for r in graph.unbindable] == ["r3"]
    assert len(graph.reaches) == 3


def test_edge_annotation_extends_the_graph_it_is_given():
    """P6 — a plugin extends, never restructures. The annotated graph is the
    same graph, with attributes added."""
    import networkx as nx

    graph = nx.MultiDiGraph()
    graph.add_edge(1, 2, length=100.0)
    annotated = _TrafficPlugin().annotate_edges(graph, _BBOX)

    assert annotated is graph
    assert annotated.number_of_edges() == 1
    assert annotated[1][2][0]["plugin_traffic"] == "heavy"
    assert annotated[1][2][0]["length"] == 100.0


def test_node_and_shape_providers_return_the_one_raw_feature_shape():
    """Both halves of the input direction speak `RawFeature` — an area
    feature keeps its ring *and* offers a centroid, so a point-only consumer
    still has something to read."""
    nodes = _GatePlugin().fetch_nodes(_BBOX, ["gate"])
    assert all(isinstance(n, RawFeature) for n in nodes)
    assert [n.tags.get("ford") for n in nodes if n.id == "ford/1"] == ["yes"]

    shapes = _ClosurePlugin().fetch_shapes(_BBOX, ["closure"])
    assert all(isinstance(s, RawFeature) for s in shapes)
    assert shapes[0].geometry is not None
    assert shapes[0].coord == (-81.95, 36.01)
