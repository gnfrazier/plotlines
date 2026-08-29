"""Unit tests for the curation endpoints — PRD FR97/FR98/FR99 (Story N3)."""

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.curation.notability import RawFeature
from plotlines_service.app import create_app


class _FakeOsmEngine:
    """Stands in for the batched `OsmLayerProvider` engine so `/candidates`
    never makes a live Overpass call in a unit test. The registry's built-in
    per-layer providers share one of these."""

    licence = "ODbL"

    def __init__(self, features: list[RawFeature]) -> None:
        self._features = features
        self.calls: list[tuple] = []

    def fetch(self, bbox, layers) -> list[RawFeature]:
        self.calls.append((bbox, frozenset(layers)))
        return self._features


def _use_fake_engine(client: TestClient, engine) -> None:
    from plotlines_core.curation.registry import build_default_registry

    client.app.state.layer_registry = build_default_registry(
        osm_engine=engine, discover_plugins=False)


@pytest.fixture()
def client(tmp_path: Path) -> TestClient:
    # No cached graph/DEM at tmp_path — readiness stays "loading" for the
    # life of the test, which is the point: /layers and /candidates/score
    # must answer regardless (ARCH B1 — layer/POI capability is independent
    # of elevation readiness).
    return TestClient(create_app(tmp_path))


def test_layers_lists_the_full_catalog(client: TestClient) -> None:
    resp = client.get("/layers")
    assert resp.status_code == 200
    body = resp.json()
    assert set(body["layers"]) == {"sight", "amenity", "natural", "historic", "leisure", "man_made"}
    assert "ruleset_version" in body


def test_layers_default_live_set_varies_by_mode_and_day_type(client: TestClient) -> None:
    route = client.get("/layers", params={"mode": "cycling", "day_type": "route"}).json()
    rest = client.get("/layers", params={"mode": "cycling", "day_type": "rest"}).json()
    assert "amenity" not in route["default_live"]
    assert "amenity" in rest["default_live"]


def test_layers_answers_while_not_ready(client: TestClient) -> None:
    # ARCH B1's regression test, at endpoint scope: routing is gated on
    # per-region readiness (issue #154), layers must not be gated at all.
    health = client.get("/health").json()
    assert health["capabilities"]["routing"] == {"regions": {}}
    assert health["capabilities"]["layers"]["ready"] is True
    resp = client.get("/layers")
    assert resp.status_code == 200


def test_candidates_score_filters_by_live_layers(client: TestClient) -> None:
    body = {
        "live_layers": ["natural"],
        "features": [
            {"id": "1", "coord": [-105.27, 40.02], "tags": {"natural": "peak"}},
            {"id": "2", "coord": [-105.27, 40.02], "tags": {"amenity": "drinking_water"}},
        ],
    }
    resp = client.post("/candidates/score", json=body)
    assert resp.status_code == 200
    candidates = resp.json()["candidates"]
    assert [c["id"] for c in candidates] == ["1"]


def test_candidates_score_ranks_by_salience(client: TestClient) -> None:
    body = {
        "live_layers": ["historic"],
        "features": [
            {"id": "stone", "coord": [0, 0], "tags": {"historic": "boundary_stone"}},
            {"id": "castle", "coord": [0, 0], "tags": {"historic": "castle"}},
        ],
    }
    resp = client.post("/candidates/score", json=body)
    candidates = resp.json()["candidates"]
    assert [c["id"] for c in candidates] == ["castle", "stone"]
    assert candidates[0]["salience"] > candidates[1]["salience"]


def test_candidates_score_omits_unqualified_over_triggering_features(client: TestClient) -> None:
    body = {
        "live_layers": ["natural", "leisure"],
        "features": [
            {"id": "unnamed_tree", "coord": [0, 0], "tags": {"natural": "tree"}},
            {"id": "unnamed_park", "coord": [0, 0], "tags": {"leisure": "park"}, "area_m2": 100.0},
            {"id": "notable_tree", "coord": [0, 0],
             "tags": {"natural": "tree", "denotation": "natural_monument"}},
        ],
    }
    resp = client.post("/candidates/score", json=body)
    ids = {c["id"] for c in resp.json()["candidates"]}
    assert ids == {"notable_tree"}


def test_candidates_extract_scores_features_from_the_layer_provider(client: TestClient) -> None:
    engine = _FakeOsmEngine([
        RawFeature(id="peak1", coord=(-105.3, 40.0), tags={"natural": "peak"}),
        RawFeature(id="water1", coord=(-105.3, 40.0), tags={"amenity": "drinking_water"}),
    ])
    _use_fake_engine(client, engine)

    resp = client.get("/candidates", params={
        "west": -105.4, "south": 39.9, "east": -105.2, "north": 40.1,
        "layers": "natural",
    })
    assert resp.status_code == 200
    body = resp.json()
    ids = {c["id"] for c in body["candidates"]}
    assert ids == {"peak1"}  # amenity wasn't in the live layer set
    assert body["layers_served"] == ["natural"]
    assert body["layers_unavailable"] == {}


def test_candidates_extract_serves_good_layers_when_one_layer_fails(client: TestClient) -> None:
    """SPIKE-D #159 / story N2 — one failing layer no longer 422s the whole
    request; the response names what it could not serve and returns the rest."""
    from plotlines_core.curation.providers import BBox, LayerLicence, LayerLoadState, READY
    from plotlines_core.curation.registry import build_default_registry

    engine = _FakeOsmEngine([
        RawFeature(id="peak1", coord=(-105.3, 40.0), tags={"natural": "peak"}),
    ])
    registry = build_default_registry(osm_engine=engine, discover_plugins=False)

    class _FailingPlugin:
        licence = LayerLicence(id="CC-BY-4.0", attribution="Test Co-op")
        taxonomy = ()

        def fetch_candidates(self, bbox: BBox):
            raise TimeoutError("upstream plugin API timed out")

        def load_state(self):
            return LayerLoadState(READY)

    registry.register_plugin("plugin_crags", _FailingPlugin())
    client.app.state.layer_registry = registry

    resp = client.get("/candidates", params={
        "west": -105.4, "south": 39.9, "east": -105.2, "north": 40.1,
        "layers": "natural,plugin_crags",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert {c["id"] for c in body["candidates"]} == {"peak1"}
    assert body["layers_served"] == ["natural"]
    assert "plugin_crags" in body["layers_unavailable"]
    assert "TimeoutError" in body["layers_unavailable"]["plugin_crags"]


def test_candidates_extract_reports_a_wholly_failed_extraction_as_empty_not_422(
    client: TestClient,
) -> None:
    class _FailingEngine:
        licence = "ODbL"

        def fetch(self, bbox, layers):
            raise RuntimeError("no network")

    _use_fake_engine(client, _FailingEngine())
    resp = client.get("/candidates", params={
        "west": -105.4, "south": 39.9, "east": -105.2, "north": 40.1,
        "layers": "natural",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["candidates"] == []
    assert body["layers_served"] == []
    assert "no network" in body["layers_unavailable"]["natural"]


def test_candidates_extract_422s_only_on_an_empty_layer_set(client: TestClient) -> None:
    resp = client.get("/candidates", params={
        "west": -105.4, "south": 39.9, "east": -105.2, "north": 40.1, "layers": "",
    })
    assert resp.status_code == 422
