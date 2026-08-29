"""Per-layer `/health` readiness — story N2, ARCH §8.3, SPIKE-D #159's
eight clauses. The shipped app passed 3 of 8 before this; these pin the rest.
"""

from __future__ import annotations

import time
from pathlib import Path

import osmnx as ox
import pytest
from fastapi.testclient import TestClient

from plotlines_core.curation.providers import BBox, LayerLicence, LayerLoadState, LOADING, READY
from plotlines_core.curation.registry import build_default_registry
from plotlines_service.app import create_app

_MISSING_BBOX = [-1.0, -1.0, 1.0, 1.0]


class _FakeOsmEngine:
    licence = "ODbL"

    def fetch(self, bbox, layers):
        return []


class _SlowPlugin:
    """`load_state()` reports `loading` a few times, then `ready`."""

    licence = LayerLicence(id="CC-BY-4.0", attribution="Slow Data Co-op")
    taxonomy = ()

    def __init__(self, loading_polls: int = 3):
        self._left = loading_polls

    def fetch_candidates(self, bbox: BBox):
        return []

    def load_state(self):
        if self._left > 0:
            self._left -= 1
            return LayerLoadState(state=LOADING, reason="fetching dataset", progress=0.4)
        return LayerLoadState(READY)


class _UnlicensedPlugin:
    licence = LayerLicence()  # unsatisfiable
    taxonomy = ()

    def fetch_candidates(self, bbox: BBox):  # pragma: no cover
        raise AssertionError("never queried")

    def load_state(self):  # pragma: no cover
        return LayerLoadState(READY)


@pytest.fixture(autouse=True)
def _no_network(monkeypatch):
    def _refuse(*_a, **_k):
        raise RuntimeError("no network access in this test")
    monkeypatch.setattr(ox, "graph_from_bbox", _refuse)


@pytest.fixture()
def client(tmp_path: Path) -> TestClient:
    app = create_app(tmp_path)
    reg = build_default_registry(osm_engine=_FakeOsmEngine(), discover_plugins=False)
    app.state.layer_registry = reg
    tc = TestClient(app)
    tc._registry = reg
    return tc


def _layers(client) -> dict:
    return client.get("/health").json()["capabilities"]["layers"]


def test_c1_layers_ready_immediately(client):
    assert _layers(client)["ready"] is True


def test_c2_per_layer_state_lives_inside_the_layers_capability(client):
    per = _layers(client)["per_layer"]
    assert set(per) == {"sight", "amenity", "natural", "historic", "leisure", "man_made"}


def test_c3_a_slow_plugin_layer_shows_loading_while_builtins_are_usable(client):
    client._registry.register_plugin("plugin_slow", _SlowPlugin(loading_polls=50))
    per = _layers(client)["per_layer"]
    assert per["plugin_slow"] == "loading"
    assert all(per[l] == "ready" for l in
               ("sight", "amenity", "natural", "historic", "leisure", "man_made"))


def test_c4_a_failure_names_the_layer_and_the_reason(client):
    client._registry.register_plugin("plugin_unlicensed", _UnlicensedPlugin())
    per = _layers(client)["per_layer"]
    assert per["plugin_unlicensed"] == "failed:licence_unsatisfiable"


def test_c5_a_failed_layer_does_not_gate_the_capability(client):
    client._registry.register_plugin("plugin_unlicensed", _UnlicensedPlugin())
    assert _layers(client)["ready"] is True  # any(), not all()


def test_c6_extraction_survives_one_bad_layer(client):
    class _Boom:
        licence = LayerLicence(id="X", attribution="Y")
        taxonomy = ()

        def fetch_candidates(self, bbox):
            raise TimeoutError("down")

        def load_state(self):
            return LayerLoadState(READY)

    client._registry.register_plugin("plugin_boom", _Boom())
    resp = client.get("/candidates", params={
        "west": -82.1, "south": 35.9, "east": -81.8, "north": 36.1,
        "layers": "natural,plugin_boom",
    })
    assert resp.status_code == 200


def test_c7_response_names_the_unavailable_layers(client):
    class _Boom:
        licence = LayerLicence(id="X", attribution="Y")
        taxonomy = ()

        def fetch_candidates(self, bbox):
            raise TimeoutError("down")

        def load_state(self):
            return LayerLoadState(READY)

    client._registry.register_plugin("plugin_boom", _Boom())
    body = client.get("/candidates", params={
        "west": -82.1, "south": 35.9, "east": -81.8, "north": 36.1,
        "layers": "natural,plugin_boom",
    }).json()
    assert "plugin_boom" in body["layers_unavailable"]


def test_c8_a_failing_region_leaves_layers_ready(client):
    key = client.post("/regions", json={"bbox": _MISSING_BBOX}).json()["region"]
    deadline = time.monotonic() + 30.0
    while True:
        caps = client.get("/health").json()["capabilities"]
        region = caps["routing"]["regions"].get(key, {})
        if region.get("reason", "").startswith("failed:"):
            break
        assert time.monotonic() < deadline
        time.sleep(0.05)
    assert caps["layers"]["ready"] is True


def test_c9_a_loading_layer_settles_to_ready_on_its_own(client):
    client._registry.register_plugin("plugin_slow", _SlowPlugin(loading_polls=3))
    assert _layers(client)["per_layer"]["plugin_slow"] == "loading"
    deadline = time.monotonic() + 5.0
    while _layers(client)["per_layer"]["plugin_slow"] != "ready":
        assert time.monotonic() < deadline
        time.sleep(0.05)


def test_loading_detail_carries_observed_progress_not_a_fixed_eta(client):
    client._registry.register_plugin("plugin_slow", _SlowPlugin(loading_polls=50))
    detail = _layers(client)["per_layer_detail"]["plugin_slow"]
    assert detail["state"] == "loading"
    assert detail["progress"] == 0.4
    assert "elapsed_s" in detail
    assert "eta_s" not in detail
