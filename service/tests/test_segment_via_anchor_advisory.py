"""Story A9a (issue #27) — a loop through *three or more* via-anchors over
`/segments/generate` and `/segments/diagnose`'s real HTTP surface (FR8a).

`core/tests/test_via_anchor_advisory.py` covers the engine behaviour
directly; what only the service layer can catch is whether the wire
responses actually carry what A9a's AC needs the client to see:

  * `/segments/generate` marks a three-via loop `target_advisory` — the
    solve is unchanged, `target_m`/`distance_error` are still reported, but
    the client frames the deviation as an editing decision, not a miss;
  * `/segments/diagnose` returns `distance_advisory` with an
    `advisory_deviation` block and never names distance in the conflict set.

Routes against `conftest.py`'s `boulder_region` (the pre-seeded SPIKE-00
Boulder fixture), so nothing here touches the network.
"""

from __future__ import annotations

import time

from fastapi.testclient import TestClient


_START = {"lat": 40.0175, "lon": -105.2797}
_VIA_A = {"lat": 40.02, "lon": -105.275}
_VIA_B = {"lat": 40.01, "lon": -105.29}
_VIA_C = {"lat": 40.025, "lon": -105.28}
_THREE_VIA = [_VIA_A, _VIA_B, _VIA_C]
#: Small enough that three separated via-anchors cannot fit inside it — the
#: SPIKE-01 condition A9a is the product position for.
_TIGHT_TARGET_M = 2000.0


def _poll_until_done(client: TestClient, job_id: str, timeout: float = 20.0) -> dict:
    deadline = time.perf_counter() + timeout
    while True:
        body = client.get(f"/segments/diagnose/{job_id}").json()
        if body["status"] == "done":
            return body
        assert body["status"] == "pending"
        if time.perf_counter() > deadline:
            raise AssertionError(f"diagnose job {job_id} never finished")
        time.sleep(0.02)


# --- AC: "Three or more via-anchors; the route passes through each and
# returns to start" — over the generate endpoint --------------------------


def test_generate_loop_with_three_via_anchors_reaches_all_and_closes(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/generate", json={
        "region": key, "start": _START, "via": _THREE_VIA, "shape": "loop",
        "target_m": _TIGHT_TARGET_M, "mode": "cycling", "theme": "balanced",
    })
    assert resp.status_code == 200
    body = resp.json()
    assert body["closed"] is True
    assert body["hit_via"] is True


# --- AC: "in explore mode target distance becomes advisory" --------------


def test_generate_loop_with_three_via_anchors_is_marked_target_advisory(boulder_region) -> None:
    client, key = boulder_region
    body = client.post("/segments/generate", json={
        "region": key, "start": _START, "via": _THREE_VIA, "shape": "loop",
        "target_m": _TIGHT_TARGET_M, "mode": "cycling", "theme": "balanced",
    }).json()
    assert body["target_advisory"] is True
    # still reported, just not enforced
    assert body["target_m"] == _TIGHT_TARGET_M
    assert body["distance_error"] is not None


def test_generate_loop_with_two_via_anchors_is_not_target_advisory(boulder_region) -> None:
    # Regression guard: the threshold is three. One or two via-anchors still
    # honour target distance (story A9), so the flag must stay false.
    client, key = boulder_region
    body = client.post("/segments/generate", json={
        "region": key, "start": _START, "via": [_VIA_A, _VIA_B], "shape": "loop",
        "target_m": 3500.0, "mode": "cycling", "theme": "balanced",
    }).json()
    assert body["target_advisory"] is False


def test_generate_plain_loop_is_not_target_advisory(boulder_region) -> None:
    client, key = boulder_region
    body = client.post("/segments/generate", json={
        "region": key, "start": _START, "shape": "loop",
        "target_m": 3500.0, "mode": "cycling", "theme": "balanced",
    }).json()
    assert body["target_advisory"] is False


# --- AC: "the deviation is surfaced with A6's relaxation path" -----------


def test_diagnose_of_a_three_via_loop_reports_distance_advisory(boulder_region) -> None:
    client, key = boulder_region
    job_id = client.post("/segments/diagnose", json={
        "region": key, "start": _START, "via": _THREE_VIA,
        "target_m": _TIGHT_TARGET_M,
        "bands": [{"metric": "traffic", "maximum": 1.0}],
    }).json()["id"]

    diagnosis = _poll_until_done(client, job_id)["diagnosis"]

    assert diagnosis["distance_advisory"] is True
    assert diagnosis["advisory_deviation"] is not None
    # distance is never the named conflict — the via-anchors fixed it
    assert all("distance" not in c.lower() for c in diagnosis["conflict"])
    # the fields the client's Diagnosis.fromJson will read
    for field in ("distance_advisory", "advisory_deviation", "kind", "relaxations"):
        assert field in diagnosis
