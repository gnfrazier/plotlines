"""Story A9 (issue #26) — routing a loop through one or two designated
via-anchors while returning to start (FR8a), exercised over `/segments/
generate`'s real HTTP surface.

`core/tests/test_via_anchor_loop.py` covers `generate_loop`/`solve_circuit`
directly; what only the service layer can catch is whether the response
`_loop_to_dict` builds actually carries what the AC needs surfaced —
`closed`, `hit_via`, and (until this story) the overlap split reporting
"any road ridden twice" (`overlap_frac`/`overlap_near_frac`/
`overlap_far_frac`), which `Loop.metrics` already computed but the endpoint
never returned.

Reuses `test_segment_shape.py`'s pattern of pre-seeding the committed
SPIKE-00 Boulder fixture graph so these tests never touch the network.
"""

from __future__ import annotations

import shutil
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.graph import regions as region_lib
from plotlines_service.app import create_app

_FIXTURE_GRAPH = (Path(__file__).resolve().parents[2] / "spikes" / "SPIKE-00" / "cache"
                  / "boulder_bike.graphml")
_BOULDER_BBOX = [-105.30, 39.99, -105.25, 40.03]  # SPIKE-00's own fixture bbox
_START = {"lat": 40.0175, "lon": -105.2797}
_VIA_A = {"lat": 40.02, "lon": -105.275}   # test_segment_shape.py's own out_and_back end
_VIA_B = {"lat": 40.01, "lon": -105.29}
_TARGET_M = 3500.0  # enough room to detour through one or two via-anchors

pytestmark = pytest.mark.skipif(
    not _FIXTURE_GRAPH.exists(),
    reason="SPIKE-00 fixture graph not present in this checkout",
)


def _client_with_boulder_region(tmp_path: Path) -> tuple[TestClient, str]:
    key = region_lib.region_key(tuple(_BOULDER_BBOX), "bike")
    dest = tmp_path / "regions" / key / "graph.graphml"
    dest.parent.mkdir(parents=True)
    shutil.copy(_FIXTURE_GRAPH, dest)

    client = TestClient(create_app(tmp_path))
    got_key = client.post("/regions", json={"bbox": _BOULDER_BBOX}).json()["region"]
    assert got_key == key

    deadline = time.perf_counter() + 20.0
    while not client.get("/health").json()["capabilities"]["routing"]["regions"][key]["ready"]:
        if time.perf_counter() > deadline:
            raise AssertionError("Boulder region never became ready")
        time.sleep(0.02)
    return client, key


# --- AC: "One or two via-anchors on a loop; the route passes through each
# and returns to start." -----------------------------------------------


def test_a_loop_with_one_via_anchor_reaches_it_and_closes(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "via": [_VIA_A], "shape": "loop",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["shape"] == "loop"
    assert body["closed"] is True
    assert body["hit_via"] is True


def test_a_loop_with_two_via_anchors_reaches_both_and_closes(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "via": [_VIA_A, _VIA_B], "shape": "loop",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["shape"] == "loop"
    assert body["closed"] is True
    assert body["hit_via"] is True


# --- AC: "weights and target distance still honored around them" --------


def test_a_via_anchor_loop_still_reports_target_and_distance_error(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "via": [_VIA_A], "shape": "loop",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    body = resp.json()
    assert body["target_m"] == _TARGET_M
    assert body["distance_error"] is not None
    assert body["distance_m"] > 0


# --- AC: "a genuine loop rather than an out-and-back, with any road
# ridden twice reported" --------------------------------------------------


def test_a_via_anchor_loop_response_reports_the_overlap_split(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "via": [_VIA_A, _VIA_B], "shape": "loop",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    body = resp.json()
    for key_name in ("overlap_frac", "overlap_near_frac", "overlap_far_frac"):
        assert key_name in body
        assert 0.0 <= body[key_name] <= 1.0


def test_a_plain_loop_with_no_via_anchors_also_reports_the_overlap_split(tmp_path: Path) -> None:
    # Regression guard: the fields must not depend on `via` being non-empty —
    # `_loop_to_dict` serves every loop, and a plain loop can double back on
    # itself just as easily as a via-anchor one.
    client, key = _client_with_boulder_region(tmp_path)
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "loop",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    body = resp.json()
    for key_name in ("overlap_frac", "overlap_near_frac", "overlap_far_frac"):
        assert key_name in body
