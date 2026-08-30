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

import shutil
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.graph import regions as region_lib
from plotlines_service.app import create_app

_FIXTURE_GRAPH = (Path(__file__).resolve().parents[2] / "spikes" / "SPIKE-00" / "fixtures"
                  / "boulder_bike.graphml")
_BOULDER_BBOX = [-105.30, 39.99, -105.25, 40.03]  # SPIKE-00's own fixture bbox
_START = {"lat": 40.0175, "lon": -105.2797}

pytestmark = pytest.mark.skipif(
    not _FIXTURE_GRAPH.exists(),
    reason="SPIKE-00 fixture graph not present in this checkout",
)


def _client_with_boulder_region(tmp_path: Path) -> tuple[TestClient, str]:
    """Same pre-seeded-cache trick as `test_regions.py` — the region is
    already "built" before the app ever starts, so nothing here touches the
    network or waits on a real graph build."""
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


def test_post_returns_202_and_a_job_id_immediately(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
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


def test_poll_reports_pending_then_a_feasible_diagnosis(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
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


def test_unknown_job_id_is_404_not_a_hang_or_silent_drop(tmp_path: Path) -> None:
    client, _key = _client_with_boulder_region(tmp_path)
    resp = client.get("/segments/diagnose/not-a-real-job-id")
    assert resp.status_code == 404


def test_a_malformed_band_is_a_422_not_a_500(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
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
