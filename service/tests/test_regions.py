"""Region-correctness tests for issue #154 — "A route request whose
start/end/via lies outside the loaded graph's extent returns an honest 422,
never a route in another region."

Before this fix, `nearest_node`'s unguarded `argmin` snapped any coordinate
— however far away — to the nearest node in whatever graph happened to be
loaded, and the solver returned a route in the wrong region with no error at
all. `test_asheville_coordinate_against_boulder_graph_is_422` is exactly the
"cross-region regression test" the issue calls out by name: it would have
caught the original bug.
"""

from __future__ import annotations


def test_a_boulder_coordinate_routes_successfully(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key,
        "start": {"lat": 40.0175, "lon": -105.2797},
        "end": {"lat": 40.02, "lon": -105.275},
        "mode": "cycling",
        "shape": "point_to_point",
        "theme": "balanced",
    })
    assert resp.status_code == 200


def test_asheville_coordinate_against_boulder_graph_is_422(boulder_region) -> None:
    # The issue's own example: Asheville, NC is ~2,000 km from the Boulder
    # fixture. Pre-#154 this silently returned a Boulder route.
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key,
        "start": {"lat": 35.5951, "lon": -82.5515},  # Asheville, NC
        "end": {"lat": 35.60, "lon": -82.55},
        "mode": "cycling",
        "shape": "point_to_point",
        "theme": "balanced",
    })
    assert resp.status_code == 422
    assert "outside this graph's region" in resp.json()["detail"]


def test_asheville_via_point_is_also_422(boulder_region) -> None:
    # A valid start/end with an out-of-region via-anchor must not slip
    # through either.
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key,
        "start": {"lat": 40.0175, "lon": -105.2797},
        "end": {"lat": 40.02, "lon": -105.275},
        "via": [{"lat": 35.5951, "lon": -82.5515}],
        "mode": "cycling",
        "shape": "point_to_point",
        "theme": "balanced",
    })
    assert resp.status_code == 422


def test_asheville_coordinate_in_a_loop_request_is_422(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key,
        "start": {"lat": 35.5951, "lon": -82.5515},
        "shape": "loop",
        "target_m": 5000,
        "mode": "cycling",
        "theme": "balanced",
    })
    assert resp.status_code == 422


def test_asheville_coordinate_in_cues_request_is_422(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/cues", json={
        "region": key,
        "start": {"lat": 35.5951, "lon": -82.5515},
        "end": {"lat": 35.60, "lon": -82.55},
        "shape": "point_to_point",
        "theme": "balanced",
    })
    assert resp.status_code == 422


def test_asheville_coordinate_in_envelope_request_is_422(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/envelope", json={
        "region": key,
        "start": {"lat": 35.5951, "lon": -82.5515},
        "target_m": 5000,
    })
    assert resp.status_code == 422
