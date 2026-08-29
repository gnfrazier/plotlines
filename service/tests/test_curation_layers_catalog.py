"""`/layers` catalog + `/attribution` — stories N5 (FR100/FR101) and the
catalog half of N2. A plugin layer appears alongside OSM layers, carries its
own licence/attribution, and its attribution propagates to `/attribution`.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.curation.providers import BBox, LayerLicence, LayerLoadState, READY
from plotlines_core.curation.registry import LayerRegistry
from plotlines_service.app import create_app


class _FakeOsmEngine:
    licence = "ODbL"

    def fetch(self, bbox, layers):
        return []


class _Plugin:
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


@pytest.fixture()
def client(tmp_path: Path) -> TestClient:
    app = create_app(tmp_path)
    reg = LayerRegistry()
    from plotlines_core.curation.providers import builtin_osm_providers

    reg.register_builtins(builtin_osm_providers(_FakeOsmEngine()))
    app.state.layer_registry = reg
    tc = TestClient(app)
    tc._registry = reg  # test handle
    return tc


def test_catalog_lists_builtin_osm_layers_with_licence_metadata(client: TestClient):
    body = client.get("/layers").json()
    assert set(body["layers"]) == {"sight", "amenity", "natural", "historic",
                                   "leisure", "man_made"}
    by_id = {e["id"]: e for e in body["catalog"]}
    hist = by_id["historic"]
    assert hist["builtin"] is True
    assert hist["state"] == "ready"
    assert hist["licence"]["id"] == "ODbL-1.0"
    assert hist["licence"]["attribution"] == "© OpenStreetMap contributors"


def test_a_plugin_layer_appears_in_the_catalog_alongside_osm(client: TestClient):
    client._registry.register_plugin("revwar_battlefields", _Plugin(
        LayerLicence(id="CC-BY-4.0", attribution="Revolutionary War GIS Project")),
        version="0.3.1")
    body = client.get("/layers").json()
    assert "revwar_battlefields" in body["layers"]
    entry = {e["id"]: e for e in body["catalog"]}["revwar_battlefields"]
    assert entry["builtin"] is False
    assert entry["version"] == "0.3.1"
    assert entry["licence"]["attribution"] == "Revolutionary War GIS Project"


def test_a_plugin_with_unsatisfiable_licence_shows_as_failed_and_has_no_credit(client: TestClient):
    client._registry.register_plugin("markers", _Plugin(LayerLicence()))
    body = client.get("/layers").json()
    entry = {e["id"]: e for e in body["catalog"]}["markers"]
    assert entry["state"] == "failed:licence_unsatisfiable"
    assert entry["licence"] is None


def test_attribution_endpoint_enumerates_the_loaded_layer_set(client: TestClient):
    client._registry.register_plugin("revwar_battlefields", _Plugin(
        LayerLicence(id="CC-BY-4.0", attribution="Revwar GIS")))
    body = client.get("/attribution").json()
    assert body["complete"] is True
    assert body["missing"] == []
    attributions = {a["layer"]: a for a in body["attributions"]}
    assert attributions["historic"]["attribution"] == "© OpenStreetMap contributors"
    assert attributions["revwar_battlefields"]["attribution"] == "Revwar GIS"


def test_attribution_endpoint_flags_a_missing_attribution_as_incomplete(client: TestClient):
    plugin = _Plugin(LayerLicence(id="X", attribution="present at gate"))
    client._registry.register_plugin("sneaky", plugin)
    plugin._licence = LayerLicence(id="X", attribution="   ")
    body = client.get("/attribution").json()
    assert body["complete"] is False
    assert "sneaky" in body["missing"]


def test_layers_still_answers_while_routing_is_not_ready(client: TestClient):
    health = client.get("/health").json()
    assert health["capabilities"]["routing"] == {"regions": {}}
    assert client.get("/layers").status_code == 200
