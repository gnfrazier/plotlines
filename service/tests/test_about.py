"""`GET /about` and the elevation line on `GET /attribution` — stories K10
and K11 (issues #116/#117; FR86, FR95, FR101, FR138).

The About surface lists every licensed source's attribution (elevation CC BY
and basemap ODbL together, plus a line per loaded plugin layer), the app and
sidecar versions, and the plain-language privacy statement.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.curation.providers import BBox, LayerLicence, LayerLoadState, READY
from plotlines_core.curation.registry import LayerRegistry
from plotlines_service.app import create_app
from plotlines_service.version import VERSION


class _FakeOsmEngine:
    licence = "ODbL"

    def fetch(self, bbox, layers):
        return []


class _Plugin:
    taxonomy = ()

    def __init__(self, licence: LayerLicence):
        self._licence = licence

    @property
    def licence(self):
        return self._licence

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
    tc._registry = reg
    return tc


def test_about_lists_elevation_cc_by_and_basemap_odbl_together(client: TestClient):
    body = client.get("/about").json()
    by_layer = {a["layer"]: a for a in body["attributions"]}

    assert by_layer["elevation"]["licence"] == "CC-BY-4.0"
    assert "OpenTopography" in by_layer["elevation"]["attribution"]
    assert by_layer["basemap"]["licence"] == "ODbL-1.0"
    assert by_layer["basemap"]["attribution"] == "© OpenStreetMap contributors"


def test_about_lists_the_routing_graphs_own_odbl_credit(client: TestClient):
    # Issue #269: the graph is a separate obligation from the basemap, not a
    # free ride under its line, and gets distinct credit text.
    body = client.get("/about").json()
    by_layer = {a["layer"]: a for a in body["attributions"]}

    assert by_layer["graph"]["licence"] == "ODbL-1.0"
    assert by_layer["graph"]["attribution"] != by_layer["basemap"]["attribution"]
    assert "OpenStreetMap" in by_layer["graph"]["attribution"]


def test_about_carries_matched_app_and_sidecar_versions(client: TestClient):
    body = client.get("/about").json()
    assert body["app_version"] == VERSION
    assert body["sidecar_version"] == VERSION
    assert body["sidecar_version"] == client.get("/health").json()["sidecar_version"]


def test_about_propagates_a_loaded_plugin_layers_attribution(client: TestClient):
    client._registry.register_plugin("revwar_battlefields", _Plugin(
        LayerLicence(id="CC-BY-4.0", attribution="Revwar GIS Project")))
    body = client.get("/about").json()
    by_layer = {a["layer"]: a for a in body["attributions"]}
    assert by_layer["revwar_battlefields"]["attribution"] == "Revwar GIS Project"
    assert body["attribution_complete"] is True


def test_about_flags_a_missing_plugin_attribution_as_incomplete(client: TestClient):
    plugin = _Plugin(LayerLicence(id="X", attribution="present at gate"))
    client._registry.register_plugin("sneaky", plugin)
    plugin._licence = LayerLicence(id="X", attribution="   ")

    body = client.get("/about").json()
    assert body["attribution_complete"] is False
    assert "sneaky" in body["missing_attribution"]


def test_about_carries_the_privacy_statement_with_every_fr138_clause(client: TestClient):
    body = client.get("/about").json()
    ids = {p["id"] for p in body["privacy"]}
    assert ids == {
        "on_device", "to_server", "planning_requests", "reveal",
        "arrival_sharing", "author_notes", "guest_sessions",
    }
    reveal = next(p for p in body["privacy"] if p["id"] == "reveal")
    assert "not a security boundary" in reveal["body"]


def test_attribution_endpoint_now_also_carries_the_elevation_cc_by_line(client: TestClient):
    body = client.get("/attribution").json()
    by_layer = {a["layer"]: a for a in body["attributions"]}
    assert by_layer["elevation"]["licence"] == "CC-BY-4.0"
    assert by_layer["basemap"]["licence"] == "ODbL-1.0"
    assert by_layer["graph"]["licence"] == "ODbL-1.0"
    assert body["complete"] is True


def test_about_answers_before_any_region_is_ensured(client: TestClient):
    # The lightest surfaces (Web guest, share-token reading view) reach About
    # with nothing else loaded — it must not depend on routing readiness.
    assert client.get("/health").json()["capabilities"]["routing"] == {"regions": {}}
    assert client.get("/about").status_code == 200
