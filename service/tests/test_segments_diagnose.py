"""FR9 (Story A6), ARCH D25 — `/segments/diagnose` + `/segments/diagnose/{id}`:
the 202-and-poll house style this endpoint promises because diagnosis itself
is slow (SPIKE-02: 1.3-15.0s) while a solve is fast (27-218ms) and cannot
share a request with it.

`diagnose.py`'s own control flow (naming a conflict, the deletion filter,
via-node implication) is unit-tested directly in `core/tests/`
(`test_conflict_diagnosis.py`, `test_band_search.py`); this file only proves
the HTTP surface around it — the part those tests cannot reach: that the POST
returns immediately with a job id rather than blocking, that polling an
in-flight job reports "pending" rather than erroring, that a finished job's
response actually deserializes into `Diagnosis` shape (mirrored on the client
by `client/lib/domain/diagnosis.dart`), and that a malformed band is a 422,
never a 500 or a hang.
"""

from __future__ import annotations

import time

from fastapi.testclient import TestClient


_START = {"lat": 40.0175, "lon": -105.2797}


def _poll_until_done(client: TestClient, job_id: str, timeout: float = 20.0) -> dict:
    deadline = time.perf_counter() + timeout
    while True:
        resp = client.get(f"/segments/diagnose/{job_id}")
        assert resp.status_code == 200
        body = resp.json()
        if body["status"] == "done":
            return body
        assert body["status"] == "pending"
        if time.perf_counter() > deadline:
            raise AssertionError(f"diagnose job {job_id} never finished")
        time.sleep(0.02)


def test_post_returns_202_and_a_job_id_immediately(boulder_region) -> None:
    client, key = boulder_region
    t0 = time.perf_counter()
    resp = client.post("/segments/diagnose", json={
        "region": key,
        "start": _START,
        "target_m": 3000,
        # comfortably satisfiable — any route at all has traffic <= 1.0 —
        # so the endpoint's own responsiveness is what's under test here,
        # not `diagnose()`'s search behaviour (covered in core/tests).
        "bands": [{"metric": "traffic", "maximum": 1.0}],
    })
    elapsed_s = time.perf_counter() - t0

    assert resp.status_code == 202
    assert elapsed_s < 1.0, "the AC this endpoint exists for: diagnosis must not block the request"
    body = resp.json()
    assert isinstance(body["id"], str) and body["id"]


def test_poll_reports_pending_then_a_feasible_diagnosis(boulder_region) -> None:
    client, key = boulder_region
    job_id = client.post("/segments/diagnose", json={
        "region": key,
        "start": _START,
        "target_m": 3000,
        "bands": [{"metric": "traffic", "maximum": 1.0}],
    }).json()["id"]

    result = _poll_until_done(client, job_id)
    diagnosis = result["diagnosis"]
    assert diagnosis["feasible"] is True
    assert diagnosis["kind"] == "none"
    # Shape `Diagnosis.fromJson` (client/lib/domain/diagnosis.dart) depends on:
    for field in ("conflict", "explanation", "relaxations", "envelope", "solves", "elapsed_ms"):
        assert field in diagnosis


def test_unknown_job_id_is_404_not_a_hang_or_silent_drop(boulder_region) -> None:
    client, _key = boulder_region
    resp = client.get("/segments/diagnose/not-a-real-job-id")
    assert resp.status_code == 404


def test_a_malformed_band_is_a_422_not_a_500(boulder_region) -> None:
    client, key = boulder_region
    resp = client.post("/segments/diagnose", json={
        "region": key,
        "start": _START,
        "target_m": 3000,
        # neither minimum nor maximum set — `Band.__post_init__` rejects
        # this ("bounds nothing"); A6's AC is "never a raw error," which
        # includes never a 500 for an Author's own malformed input.
        "bands": [{"metric": "traffic"}],
    })
    assert resp.status_code == 422
