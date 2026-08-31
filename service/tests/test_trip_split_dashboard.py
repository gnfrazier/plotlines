"""D1 / FR31 / FR16 — `/trips/split` carries the live planning dashboard.

`plotlines_core.trips.dashboard.build_dashboard` is the model half of Story D1
(issue #53): the three roll-up scopes plus the FR16 moving-time / elapsed-time
/ ETA model. Before this no service endpoint returned it and the client had no
way to reach it (issue #213) — the only trip-scoped roll-up it showed was a
distance/climb/descent sum with no time in it at all.

`/trips/split` now bundles `build_dashboard(trip, …)` alongside the payload (the
same place `hazard_rollup` rides), so the FR16 time model is computed once,
server-side, and a sidecar and a hosted server hand the client identical
numbers. Pure assembly — `split_trip` touches no graph — so this needs no
region fixture.
"""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from plotlines_service.app import create_app


def _client(tmp_path: Path) -> TestClient:
    return TestClient(create_app(tmp_path))


def _seg(seg_id: str, mode: str, dist_m: float) -> dict:
    return {
        "id": seg_id,
        "mode": mode,
        "shape": "point_to_point",
        "start": [0.0, 0.0],
        "end": [0.1, 0.1],
        "metrics": {"distance_m": dist_m},
    }


def _two_day_trip() -> dict:
    return {
        "title": "Three ways over the range",
        "days": [
            {"index": 1, "kind": "route", "segments": [
                _seg("s1", "cycling", 20_000.0),
                _seg("s2", "hiking", 5_000.0),
            ]},
            {"index": 2, "kind": "route", "segments": [
                _seg("s3", "cycling", 30_000.0),
            ]},
        ],
    }


def test_split_response_carries_the_dashboard_block(tmp_path: Path) -> None:
    client = _client(tmp_path)
    resp = client.post("/trips/split", json=_two_day_trip())
    assert resp.status_code == 200

    dash = resp.json()["dashboard"]
    assert dash["trip_title"] == "Three ways over the range"
    assert [d["index"] for d in dash["days"]] == [1, 2]
    # the distance roll-up is the same length-weighted sum the payload carries
    assert dash["trip_total"]["total"]["distance_m"] == 55_000.0
    assert dash["trip_total"]["by_mode"]["cycling"]["distance_m"] == 50_000.0
    assert dash["trip_total"]["by_mode"]["hiking"]["distance_m"] == 5_000.0


def test_dashboard_fills_in_the_fr16_time_model_from_system_default_pace(tmp_path: Path) -> None:
    client = _client(tmp_path)
    resp = client.post("/trips/split", json=_two_day_trip())
    assert resp.status_code == 200
    dash = resp.json()["dashboard"]

    assert dash["pace_source"] == "system_default"
    # cycling 15 km/h → 50 km is 12000 s; hiking 5 km/h → 5 km is 3600 s.
    assert dash["trip_total"]["by_mode"]["cycling"]["moving_time_s"] == 12_000.0
    assert dash["trip_total"]["by_mode"]["hiking"]["moving_time_s"] == 3_600.0
    # no hold durations on the request → elapsed == moving on the scope total
    assert dash["trip_total"]["total"]["moving_time_s"] == 15_600.0
    assert dash["trip_total"]["total"]["elapsed_time_s"] == 15_600.0
    # day 1: 20 km cycling (4800 s) + 5 km hiking (3600 s)
    assert dash["days"][0]["metrics"]["total"]["moving_time_s"] == 8_400.0
    # ETA needs a start time, and none was supplied
    assert dash["trip_eta"] is None
    assert dash["days"][0]["eta"] is None


def test_dashboard_custom_pace_and_holds_drive_elapsed_time_and_eta(tmp_path: Path) -> None:
    client = _client(tmp_path)
    body = _two_day_trip()
    # Assemble once with no inputs to learn the day ids split_trip minted.
    day_ids = [d["id"] for d in client.post("/trips/split", json=body).json()["days"]]

    body["speeds"] = {"cycling": 10.0}          # override the 15 km/h default
    body["day_hold_s"] = {day_ids[0]: 1_800.0}  # 30 min of stations on day 1
    body["trip_start_at"] = "2026-09-01T08:00:00Z"
    resp = client.post("/trips/split", json=body)
    assert resp.status_code == 200
    dash = resp.json()["dashboard"]

    assert dash["pace_source"] == "custom"
    # cycling 50 km at 10 km/h = 18000 s; hiking unchanged at 3600 s
    assert dash["trip_total"]["by_mode"]["cycling"]["moving_time_s"] == 18_000.0
    assert dash["trip_total"]["total"]["moving_time_s"] == 21_600.0
    # the hold lands once, on the scope total's elapsed time
    assert dash["trip_total"]["total"]["elapsed_time_s"] == 23_400.0
    assert dash["trip_hold_s"] == 1_800.0
    # 08:00Z + 23400 s (6 h 30 m) = 14:30Z
    assert dash["trip_eta"] == "2026-09-01T14:30:00Z"


def test_dashboard_reports_the_active_passage_when_asked(tmp_path: Path) -> None:
    client = _client(tmp_path)
    body = _two_day_trip()
    body["active_segment_id"] = "s2"
    resp = client.post("/trips/split", json=body)
    assert resp.status_code == 200
    active = resp.json()["dashboard"]["active_passage"]
    assert active["segment_id"] == "s2"
    assert active["mode"] == "hiking"
    assert active["day_index"] == 1
    assert active["metrics"]["moving_time_s"] == 3_600.0


def test_dashboard_422s_when_the_active_segment_is_not_in_the_trip(tmp_path: Path) -> None:
    client = _client(tmp_path)
    body = _two_day_trip()
    body["active_segment_id"] = "does-not-exist"
    resp = client.post("/trips/split", json=body)
    assert resp.status_code == 422


def test_dashboard_present_for_a_trip_with_no_time_model_inputs(tmp_path: Path) -> None:
    client = _client(tmp_path)
    resp = client.post("/trips/split", json={"title": "Bare", "days": [
        {"index": 1, "kind": "route", "segments": [_seg("s1", "cycling", 1_000.0)]},
    ]})
    assert resp.status_code == 200
    dash = resp.json()["dashboard"]
    assert dash["active_passage"] is None
    assert dash["trip_hold_s"] is None
    assert dash["trip_eta"] is None
    # the distance panel is still there
    assert dash["trip_total"]["total"]["distance_m"] == 1_000.0
