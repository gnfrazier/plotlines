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

Routes against `conftest.py`'s `boulder_region` — the committed SPIKE-00
Boulder fixture graph, pre-seeded so these tests never touch the network.
"""

from __future__ import annotations

_START = {"lat": 40.0175, "lon": -105.2797}
_VIA_A = {"lat": 40.02, "lon": -105.275}   # test_segment_shape.py's own out_and_back end
_VIA_B = {"lat": 40.01, "lon": -105.29}
_TARGET_M = 3500.0  # enough room to detour through one or two via-anchors


# --- AC: "One or two via-anchors on a loop; the route passes through each
# and returns to start." -----------------------------------------------


def test_a_loop_with_one_via_anchor_reaches_it_and_closes(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "via": [_VIA_A], "shape": "loop",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["shape"] == "loop"
    assert body["closed"] is True
    assert body["hit_via"] is True


def test_a_loop_with_two_via_anchors_reaches_both_and_closes(boulder_region) -> None:
    client, key = boulder_region
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


def test_a_via_anchor_loop_still_reports_target_and_distance_error(boulder_region) -> None:
    client, key = boulder_region
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


def test_a_via_anchor_loop_response_reports_the_overlap_split(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "via": [_VIA_A, _VIA_B], "shape": "loop",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    body = resp.json()
    for key_name in ("overlap_frac", "overlap_near_frac", "overlap_far_frac"):
        assert key_name in body
        assert 0.0 <= body[key_name] <= 1.0


def test_a_plain_loop_with_no_via_anchors_also_reports_the_overlap_split(boulder_region) -> None:
    # Regression guard: the fields must not depend on `via` being non-empty —
    # `_loop_to_dict` serves every loop, and a plain loop can double back on
    # itself just as easily as a via-anchor one.
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "loop",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    body = resp.json()
    for key_name in ("overlap_frac", "overlap_near_frac", "overlap_far_frac"):
        assert key_name in body
