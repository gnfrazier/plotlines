"""The reconciled ARCH §14.2 `LayerProvider` contract — stories N2/N5,
FR100/FR101, SPIKE-D #159 / SPIKE-H #160.

Exercises the shape `core/plotlines_core/curation/providers.py` now ships:
`licence -> LayerLicence`, `taxonomy -> TypeTaxonomy`,
`fetch_candidates(bbox) -> list[Candidate]`, `load_state() -> LayerLoadState`.
No live Overpass call — the built-in provider is driven by a fake batch
engine that returns committed-style `RawFeature`s.
"""

from __future__ import annotations

from plotlines_core.curation.notability import Candidate, RawFeature
from plotlines_core.curation.providers import (
    FAILED,
    READY,
    BBox,
    BuiltinOsmLayerProvider,
    LayerLicence,
    LayerLoadState,
    OSM_LICENCE,
    SharedOsmFetch,
    builtin_osm_providers,
)
from plotlines_core.curation.taxonomy import LAYERS, TAXONOMY

_BBOX = BBox(-82.10, 35.90, -81.78, 36.12)


class _FakeOsmEngine:
    """Stands in for `OsmLayerProvider` — returns fixed features, records
    every `fetch` call so the shared-fetch sharing can be asserted."""

    licence = "ODbL"

    def __init__(self, features: list[RawFeature]) -> None:
        self._features = features
        self.calls: list[frozenset[str]] = []

    def fetch(self, bbox: BBox, layers: set[str]) -> list[RawFeature]:
        self.calls.append(frozenset(layers))
        return list(self._features)


def _features() -> list[RawFeature]:
    return [
        RawFeature(id="n/1", coord=(-81.95, 36.00), tags={"historic": "castle", "name": "Keep"}),
        RawFeature(id="n/2", coord=(-81.92, 36.02), tags={"natural": "peak", "name": "Knob"}),
        RawFeature(id="n/3", coord=(-81.90, 36.01), tags={"amenity": "drinking_water"}),
    ]


def test_layer_licence_satisfiable_needs_id_and_attribution():
    assert LayerLicence(id="ODbL-1.0", attribution="© OSM").satisfiable is True
    assert LayerLicence(id="ODbL-1.0").satisfiable is False
    assert LayerLicence(attribution="© OSM").satisfiable is False
    assert LayerLicence().satisfiable is False
    assert LayerLicence(id="  ", attribution="  ").satisfiable is False


def test_layer_load_state_as_dict_omits_empty_fields():
    assert LayerLoadState(READY).as_dict() == {"state": "ready"}
    d = LayerLoadState(state="loading", reason="fetching", progress=0.4123).as_dict()
    assert d == {"state": "loading", "reason": "fetching", "progress": 0.41}


def test_builtin_osm_licence_is_a_satisfiable_layerlicence():
    assert isinstance(OSM_LICENCE, LayerLicence)
    assert OSM_LICENCE.satisfiable is True


def test_builtin_provider_exposes_the_four_contract_members():
    engine = _FakeOsmEngine(_features())
    provider = BuiltinOsmLayerProvider("historic", SharedOsmFetch(engine))

    assert isinstance(provider.licence, LayerLicence)
    assert provider.taxonomy  # a non-empty TypeTaxonomy slice
    assert all(rule.layer == "historic" for rule in provider.taxonomy)
    assert provider.load_state() == LayerLoadState(READY)

    candidates = provider.fetch_candidates(_BBOX)
    assert candidates and all(isinstance(c, Candidate) for c in candidates)
    # Only this layer's candidates come back, already scored + ranked.
    assert {c.layer for c in candidates} == {"historic"}


def test_builtin_provider_taxonomy_is_a_slice_not_the_whole_table():
    engine = _FakeOsmEngine(_features())
    providers = builtin_osm_providers(engine)
    covered = set()
    for layer, provider in providers.items():
        assert all(rule.layer == layer for rule in provider.taxonomy)
        covered.add(layer)
    assert covered == set(LAYERS)


def test_six_builtin_providers_share_one_fetch():
    engine = _FakeOsmEngine(_features())
    providers = builtin_osm_providers(engine)
    for provider in providers.values():
        provider.fetch_candidates(_BBOX)
    # One bbox -> one underlying Overpass call, shared across all six.
    assert len(engine.calls) == 1
    assert engine.calls[0] == frozenset(LAYERS)


def test_builtin_provider_rejects_a_non_builtin_layer_name():
    engine = _FakeOsmEngine(_features())
    try:
        BuiltinOsmLayerProvider("revwar_battlefields", SharedOsmFetch(engine))
    except ValueError as exc:
        assert "built-in" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("expected ValueError for a non-built-in layer")


def test_area_geometry_survives_scoring_to_the_candidate():
    """FR100 / SPIKE-H §3 — a polygon feature's area and exterior ring reach
    the Candidate; a point's stay None."""
    from plotlines_core.curation.notability import score_with_taxonomy
    from plotlines_core.curation.taxonomy import TypeRule

    ring = ((-81.9, 36.0), (-81.89, 36.0), (-81.89, 36.01), (-81.9, 36.01), (-81.9, 36.0))
    feats = [
        RawFeature(id="area/1", coord=(-81.895, 36.005),
                   tags={"leisure": "nature_reserve", "name": "Big Reserve"},
                   area_m2=250_000.0, geometry=ring),
        RawFeature(id="pt/1", coord=(-81.9, 36.0),
                   tags={"natural": "peak", "name": "Knob"}),
    ]
    got = {c.id: c for c in score_with_taxonomy(
        feats, TAXONOMY, live_layers={"leisure", "natural"})}
    assert got["area/1"].area_m2 == 250_000.0
    assert got["area/1"].geometry == ring
    assert got["pt/1"].area_m2 is None
    assert got["pt/1"].geometry is None


def test_feature_from_geometry_captures_a_polygon_exterior_ring():
    from shapely.geometry import Point, Polygon

    from plotlines_core.curation.providers import feature_from_geometry

    d = 0.002
    poly = Polygon([(0, 0), (d, 0), (d, d), (0, d)])
    feat = feature_from_geometry("w1", poly, {"leisure": "park"})
    assert feat is not None and feat.geometry is not None
    assert feat.geometry[0] == (0.0, 0.0)
    assert len(feat.geometry) == 5  # closed ring

    pt = feature_from_geometry("n1", Point(1, 2), {"natural": "peak"})
    assert pt is not None and pt.geometry is None


def test_plugin_shaped_provider_scores_against_its_own_taxonomy():
    """A plugin's own type, in its own taxonomy, produces a Candidate with
    no core-table edit — the FR105 / ARCH §14.4 property."""
    from plotlines_core.curation.notability import score_with_taxonomy
    from plotlines_core.curation.taxonomy import TypeRule

    taxonomy = (
        TypeRule(layer="battlefields", key="site_type", value="battlefield",
                 base_weight=0.8, role_affinity="narrative"),
    )
    feats = [RawFeature(id="p/1", coord=(-81.9, 36.0),
                        tags={"site_type": "battlefield", "name": "Test Ridge"})]
    got = score_with_taxonomy(feats, taxonomy, live_layers={"battlefields"})
    assert [c.id for c in got] == ["p/1"]
    assert got[0].role_affinity == "narrative"
    assert got[0].layer == "battlefields"
