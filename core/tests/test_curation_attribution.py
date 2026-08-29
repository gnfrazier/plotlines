"""Attribution derived from the loaded layer set — story N5, FR101,
ARCH §12.2. A missing attribution on a loaded layer is a build failure.
"""

from __future__ import annotations

import pytest

from plotlines_core.curation.attribution import (
    MissingAttributionError,
    assert_attribution_complete,
    attributions_for,
)
from plotlines_core.curation.providers import BBox, LayerLicence, LayerLoadState, READY
from plotlines_core.curation.registry import LayerRegistry
from plotlines_core.curation.taxonomy import LAYERS


class FakeOsmEngine:
    licence = "ODbL"

    def fetch(self, bbox, layers):
        return []


class Plugin:
    def __init__(self, licence: LayerLicence):
        self._licence = licence

    @property
    def licence(self):
        return self._licence

    taxonomy = ()

    def fetch_candidates(self, bbox: BBox):
        return []

    def load_state(self):
        return LayerLoadState(READY)


def _registry() -> LayerRegistry:
    from plotlines_core.curation.providers import builtin_osm_providers

    reg = LayerRegistry()
    reg.register_builtins(builtin_osm_providers(FakeOsmEngine()))
    return reg


def test_builtin_osm_attribution_is_derived_not_hardcoded():
    lines = attributions_for(_registry())
    osm = [a for a in lines if a.layer == "historic"][0]
    assert osm.attribution == "© OpenStreetMap contributors"
    assert osm.licence_id == "ODbL-1.0"
    assert osm.builtin is True


def test_a_plugin_layers_attribution_propagates():
    reg = _registry()
    reg.register_plugin("battlefields", Plugin(
        LayerLicence(id="CC-BY-4.0", attribution="Revolutionary War GIS Project",
                     terms_url="https://example.org/licence")))
    lines = {a.layer: a for a in attributions_for(reg)}
    assert lines["battlefields"].attribution == "Revolutionary War GIS Project"
    assert lines["battlefields"].terms_url == "https://example.org/licence"
    assert lines["battlefields"].builtin is False


def test_attribution_lists_builtins_first_then_plugins():
    reg = _registry()
    reg.register_plugin("aaa_markers", Plugin(
        LayerLicence(id="CC-BY-4.0", attribution="A")))
    ordered = [a.layer for a in attributions_for(reg)]
    assert ordered.index("historic") < ordered.index("aaa_markers")


def test_attribution_only_covers_ready_layers():
    reg = _registry()
    reg.register_plugin("markers", Plugin(LayerLicence()))  # unsatisfiable -> failed
    layers = {a.layer for a in attributions_for(reg)}
    assert "markers" not in layers


def test_assert_complete_passes_when_every_loaded_layer_has_attribution():
    reg = _registry()
    reg.register_plugin("battlefields", Plugin(
        LayerLicence(id="CC-BY-4.0", attribution="Revwar GIS")))
    lines = assert_attribution_complete(reg)
    assert {a.layer for a in lines} >= set(LAYERS) | {"battlefields"}


def test_assert_complete_is_a_build_failure_when_attribution_missing():
    reg = _registry()

    # A provider that passes the registration licence gate, then yields a
    # blank attribution string at render time (id still present, attribution
    # accidentally emptied) — the drift the dynamic build check exists for.
    plugin = Plugin(LayerLicence(id="X", attribution="present at gate"))
    reg.register_plugin("sneaky", plugin)
    assert "sneaky" in reg.ready_layers()
    plugin._licence = LayerLicence(id="X", attribution="   ")

    with pytest.raises(MissingAttributionError) as excinfo:
        assert_attribution_complete(reg)
    assert "sneaky" in str(excinfo.value)


def test_assert_complete_scoped_to_a_layer_subset():
    reg = _registry()
    lines = assert_attribution_complete(reg, {"historic", "natural"})
    assert {a.layer for a in lines} == {"historic", "natural"}
