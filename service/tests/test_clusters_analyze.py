"""`POST /clusters/analyze` — story N4 (FR102–FR105a), "find the good spots".

A named Author action over the trip bbox: extract candidates across the live
layers, cluster across heterogeneous layers, return ranked + capped proposals
with contributing members, the affinity-union role set, and (given a route)
distance-to-corridor. Never writes canon.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.curation.notability import RawFeature
from plotlines_core.curation.providers import BBox, LayerLicence, LayerLoadState, READY
from plotlines_core.curation.registry import build_default_registry
from plotlines_service.app import create_app

# A tight cluster of three OSM features (~30 m apart) — a viewpoint + a museum
# (narrative) and drinking water (provision) — plus an isolated boundary stone.
_D = 0.0003  # ~33 m at this latitude
_OSM = [
    RawFeature(id="osm/vp", coord=(-82.00, 36.00),
               tags={"tourism": "viewpoint", "name": "Ridge Overlook"}),
    RawFeature(id="osm/mus", coord=(-82.00 + _D, 36.00),
               tags={"tourism": "museum", "name": "Mill Museum"}),
    RawFeature(id="osm/water", coord=(-82.00, 36.00 + _D),
               tags={"amenity": "drinking_water"}),
    RawFeature(id="osm/far", coord=(-81.90, 36.05),
               tags={"historic": "castle", "name": "Lone Keep"}),
]


class _FakeOsmEngine:
    licence = "ODbL"

    def __init__(self, features):
        self._features = features

    def fetch(self, bbox, layers):
        return list(self._features)


class _CragPlugin:
    """A plugin layer whose `crag` type declares the `station` affinity —
    D47's third affinity from a non-OSM source (FR105)."""

    licence = LayerLicence(id="CC-BY-4.0", attribution="Climbing DB")
    from plotlines_core.curation.taxonomy import TypeRule as _TR
    taxonomy = (_TR(layer="crags", key="sport", value="climbing",
                    base_weight=0.5, role_affinity="station"),)

    def __init__(self, *, raise_on_fetch=False):
        self._raise = raise_on_fetch

    def fetch_candidates(self, bbox: BBox):
        if self._raise:
            raise TimeoutError("crag API down")
        from plotlines_core.curation.notability import score_with_taxonomy
        feats = [RawFeature(id="crag/1", coord=(-82.00 + _D, 36.00 + _D),
                            tags={"sport": "climbing", "name": "The Wall"})]
        return score_with_taxonomy(feats, self.taxonomy, live_layers={"crags"})

    def load_state(self):
        return LayerLoadState(READY)


@pytest.fixture()
def client(tmp_path: Path) -> TestClient:
    app = create_app(tmp_path)
    reg = build_default_registry(osm_engine=_FakeOsmEngine(_OSM), discover_plugins=False)
    app.state.layer_registry = reg
    tc = TestClient(app)
    tc._registry = reg
    return tc


_BBOX = [-82.10, 35.90, -81.80, 36.10]


def _analyze(client, **over):
    body = {"bbox": _BBOX, "layers": ["sight", "amenity", "historic"], **over}
    return client.post("/clusters/analyze", json=body)


def test_returns_one_proposal_for_the_tight_cluster(client):
    resp = _analyze(client)
    assert resp.status_code == 200
    body = resp.json()
    assert body["ruleset_version"]
    assert len(body["proposals"]) == 1
    p = body["proposals"][0]
    assert {m["candidate_id"] for m in p["members"]} == {"osm/vp", "osm/mus", "osm/water"}


def test_proposal_carries_members_with_salience_so_the_author_can_judge(client):
    p = _analyze(client).json()["proposals"][0]
    for m in p["members"]:
        assert set(m) >= {"candidate_id", "layer", "type", "salience", "role_affinity"}
        assert 0.0 <= m["salience"] <= 1.0


def test_role_set_is_the_affinity_union(client):
    p = _analyze(client).json()["proposals"][0]
    assert set(p["role_affinities"]) == {"narrative", "provision"}
    assert p["kind"] == "narrative+provision"


def test_a_plugin_layers_affinity_participates_the_day_it_loads(client):
    client._registry.register_plugin("crags", _CragPlugin())
    body = _analyze(client, layers=["sight", "amenity", "historic", "crags"]).json()
    p = body["proposals"][0]
    assert "station" in p["role_affinities"]
    assert "crag/1" in {m["candidate_id"] for m in p["members"]}


def test_never_ambient_it_is_a_post_over_a_fixed_bbox(client):
    # There is no GET form and no viewport parameter — the request is the bbox.
    assert client.get("/clusters/analyze").status_code in (404, 405)


def test_cap_and_beyond_count_are_reported_never_truncated_silently(client):
    body = _analyze(client, params={"cap_floor": 0}).json()
    assert body["cap"] == 0
    assert body["n_beyond_cap"] == 1  # the one real cluster is beyond a 0 cap
    assert body["proposals"] == []


def test_cap_grows_with_route_km(client):
    route = [[-82.05, 35.95], [-81.85, 36.05]]  # ~25 km
    body = _analyze(client, route=route).json()
    assert body["cap"] > 30  # 30 + 0.5 * route-km


def test_route_adds_distance_to_corridor(client):
    route = [[-82.00, 35.99], [-82.00, 36.01]]
    p = _analyze(client, route=route).json()["proposals"][0]
    assert p["distance_to_route_m"] is not None
    assert p["distance_to_route_m"] >= 0


def test_rejected_membership_is_not_re_proposed(client):
    first = _analyze(client).json()["proposals"][0]
    member_ids = [m["candidate_id"] for m in first["members"]]
    again = _analyze(client, rejected=[member_ids]).json()
    assert again["proposals"] == []


def test_previous_run_marks_which_proposals_are_new(client):
    first = _analyze(client).json()["proposals"][0]
    member_ids = [m["candidate_id"] for m in first["members"]]
    again = _analyze(client, previous=[member_ids]).json()["proposals"]
    assert again and again[0]["is_new"] is False
    fresh = _analyze(client, previous=[["totally", "different"]]).json()["proposals"]
    assert fresh and fresh[0]["is_new"] is True


def test_corridor_sort_is_opt_in(client):
    route = [[-82.00, 35.99], [-82.00, 36.01]]
    body = _analyze(client, route=route, sort="corridor").json()
    assert body["sort"] == "corridor"
    assert client.post("/clusters/analyze", json={
        "bbox": _BBOX, "layers": ["sight"], "sort": "nonsense"}).status_code == 422


def test_one_failing_layer_never_fails_the_run(client):
    client._registry.register_plugin("crags", _CragPlugin(raise_on_fetch=True))
    body = _analyze(client, layers=["sight", "amenity", "historic", "crags"]).json()
    assert body["proposals"]  # the OSM cluster still came back
    assert "crags" in body["layers_unavailable"]
    assert body["layers_served"] == ["amenity", "historic", "sight"]


def test_empty_layer_set_is_422(client):
    assert client.post("/clusters/analyze", json={"bbox": _BBOX, "layers": []}).status_code == 422


def test_never_writes_canon_it_only_returns_proposals(client):
    # No side effect: two identical calls return identical proposal ids and
    # nothing is persisted (the endpoint holds no store).
    a = _analyze(client).json()["proposals"]
    b = _analyze(client).json()["proposals"]
    assert [p["id"] for p in a] == [p["id"] for p in b]
