"""Plugin layer discovery via entry points — story N5, FR100, SPIKE-H §7."""

from __future__ import annotations

from plotlines_core.curation import plugins
from plotlines_core.curation.providers import BBox, LayerLicence, LayerLoadState, READY


class _FakeEntryPoint:
    def __init__(self, name, value, *, dist_version="1.2.3", raises=None):
        self.name = name
        self._value = value
        self._raises = raises
        self.dist = type("D", (), {"version": dist_version})()

    def load(self):
        if self._raises is not None:
            raise self._raises
        return self._value


class GoodPlugin:
    licence = LayerLicence(id="CC-BY-4.0", attribution="Community Data Co-op")
    taxonomy = ()

    def fetch_candidates(self, bbox: BBox) -> list:
        return []

    def load_state(self) -> LayerLoadState:
        return LayerLoadState(READY)


def test_discovers_installed_layer_providers(monkeypatch):
    monkeypatch.setattr(
        plugins, "_load_entry_points",
        lambda group: [_FakeEntryPoint("revwar_battlefields", GoodPlugin())],
    )
    found = plugins.discover_layer_providers()
    assert [name for name, _, _ in found] == ["revwar_battlefields"]
    _, provider, version = found[0]
    assert isinstance(provider, GoodPlugin)
    assert version == "1.2.3"


def test_a_class_entry_point_is_instantiated(monkeypatch):
    monkeypatch.setattr(
        plugins, "_load_entry_points",
        lambda group: [_FakeEntryPoint("revwar", GoodPlugin)],  # the class, not an instance
    )
    _, provider, _ = plugins.discover_layer_providers()[0]
    assert isinstance(provider, GoodPlugin)


def test_a_plugin_that_fails_to_load_becomes_a_failed_layer(monkeypatch):
    monkeypatch.setattr(
        plugins, "_load_entry_points",
        lambda group: [_FakeEntryPoint("broken", None, raises=ImportError("no module 'x'"))],
    )
    name, provider, _ = plugins.discover_layer_providers()[0]
    assert name == "broken"
    state = provider.load_state()
    assert state.state == "failed"
    assert "ImportError" in state.reason
    # a broken plugin's licence is unsatisfiable, so the registry never queries it
    assert provider.licence.satisfiable is False


def test_a_plugin_whose_constructor_raises_becomes_a_failed_layer(monkeypatch):
    class Boom:
        def __init__(self):
            raise RuntimeError("bad config")

    monkeypatch.setattr(
        plugins, "_load_entry_points",
        lambda group: [_FakeEntryPoint("boom", Boom)],
    )
    _, provider, _ = plugins.discover_layer_providers()[0]
    assert provider.load_state().state == "failed"
    assert "RuntimeError" in provider.load_state().reason


def test_no_plugins_installed_is_an_empty_list(monkeypatch):
    monkeypatch.setattr(plugins, "_load_entry_points", lambda group: [])
    assert plugins.discover_layer_providers() == []


def test_registry_registers_discovered_plugins(monkeypatch):
    from plotlines_core.curation.registry import build_default_registry

    class FakeOsmEngine:
        licence = "ODbL"

        def fetch(self, bbox, layers):
            return []

    monkeypatch.setattr(
        plugins, "_load_entry_points",
        lambda group: [_FakeEntryPoint("community_markers", GoodPlugin())],
    )
    reg = build_default_registry(osm_engine=FakeOsmEngine(), discover_plugins=True)
    assert "community_markers" in reg.known_layers()
    assert reg.per_layer_detail()["community_markers"]["version"] == "1.2.3"
