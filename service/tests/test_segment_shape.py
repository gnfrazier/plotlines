"""Story A7 (issue #24) — route shape is selectable independently of
weights, loop is the default, and only point_to_point requires a
destination.

Routes against `conftest.py`'s `boulder_region` — the committed SPIKE-00
Boulder fixture graph, pre-seeded so these tests never touch the network.
"""

from __future__ import annotations

_START = {"lat": 40.0175, "lon": -105.2797}
_END = {"lat": 40.02, "lon": -105.275}
_TARGET_M = 2500.0  # short, so loop/out_and_back solves stay fast in tests


# --- AC: "loop default" -----------------------------------------------

def test_shape_omitted_defaults_to_loop(boulder_region) -> None:
    """Omitting `shape` entirely and also omitting `target_m` must fail with
    loop's own complaint ("requires target_m"), not point_to_point's
    ("requires end") — the only way to tell which shape the server actually
    defaulted to without a route solve."""
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key,
        "start": _START,
        "mode": "cycling",
        "theme": "balanced",
    })
    assert resp.status_code == 422
    assert "loop shape requires target_m" in resp.json()["detail"]


def test_shape_omitted_with_target_m_solves_a_loop(boulder_region) -> None:
    """The same omission, this time with a `target_m` supplied, must
    actually solve — and report back `shape: loop`."""
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key,
        "start": _START,
        "target_m": _TARGET_M,
        "mode": "cycling",
        "theme": "balanced",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["shape"] == "loop"
    assert body["closed"] is True


def test_cues_shape_also_defaults_to_loop(boulder_region) -> None:
    """`/segments/cues` re-solves the same request shape `/segments/generate`
    would (CuesRequest carries its own `shape` default) — same default,
    same evidence."""
    client, key = boulder_region
    resp = client.post("/segments/cues", json={
        "region": key,
        "start": _START,
        "mode": "cycling",
        "theme": "balanced",
    })
    assert resp.status_code == 422
    assert "loop shape requires target_m" in resp.json()["detail"]


# --- AC: "three shapes per passage" -------------------------------------

def test_all_three_shapes_solve(boulder_region) -> None:
    client, key = boulder_region

    loop_resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "loop",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    assert loop_resp.status_code == 200
    assert loop_resp.json()["shape"] == "loop"

    oab_resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "out_and_back",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    assert oab_resp.status_code == 200
    assert oab_resp.json()["shape"] == "out_and_back"

    p2p_resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "end": _END, "shape": "point_to_point",
        "mode": "cycling", "theme": "balanced",
    })
    assert p2p_resp.status_code == 200
    assert p2p_resp.json()["shape"] == "point_to_point"


# --- AC: "point-to-point requires a destination, loop/out-and-back
# require only a start" ---------------------------------------------------

def test_point_to_point_without_end_is_422(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "point_to_point",
        "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 422
    assert "point_to_point shape requires end" in resp.json()["detail"]


def test_loop_without_end_solves(boulder_region) -> None:
    """Loop needs no destination at all — only a start and a target
    distance."""
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "loop",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    assert "end" not in resp.json() or resp.json().get("end") is None


def test_out_and_back_without_end_solves(boulder_region) -> None:
    """Out-and-back needs no destination either — a target distance alone
    is enough to pick its own turnaround."""
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "out_and_back",
        "target_m": _TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    assert resp.json()["shape"] == "out_and_back"


def test_loop_without_target_m_is_422(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "loop",
        "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 422
    assert "loop shape requires target_m" in resp.json()["detail"]


# --- AC: "independent of weight profile" ---------------------------------

def test_shape_is_independent_of_weight_profile(boulder_region) -> None:
    """The same shape, with two very different weight profiles, must both
    solve and both still report the shape the Author asked for — weights
    flavor the route the shape doesn't gate, and a shape's requirements
    (here, loop's target_m) don't vary with which weights are sent."""
    client, key = boulder_region

    quiet_resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "loop", "target_m": _TARGET_M,
        "mode": "cycling", "weights": {"quiet": 1.0, "scenic": 0.5, "directness": 0.2},
    })
    direct_resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "loop", "target_m": _TARGET_M,
        "mode": "cycling", "weights": {"quiet": 0.1, "scenic": 0.0, "directness": 0.95},
    })

    assert quiet_resp.status_code == 200
    assert direct_resp.status_code == 200
    assert quiet_resp.json()["shape"] == "loop"
    assert direct_resp.json()["shape"] == "loop"


def test_theme_default_is_unaffected_by_shape_default_change(boulder_region) -> None:
    """The shape default flipping to loop must not disturb the independent
    `theme`/weights default resolution — a request naming only `theme`
    (no weights, no shape) still resolves via `THEMES`, not the (now
    loop-shaped) request rejecting it for an unrelated reason."""
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "target_m": _TARGET_M, "theme": "balanced",
    })
    assert resp.status_code == 200
    assert resp.json()["theme"] == "balanced"
