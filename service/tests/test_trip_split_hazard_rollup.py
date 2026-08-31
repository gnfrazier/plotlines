"""C11 / FR27 / FR115 — `/trips/split` carries the trip-wide hazard roll-up.

`trips.hazards.collect_hazards` / `sync_alerts` are the model half of C11, but
before this no service endpoint returned them: the client had a per-segment
`segment.hazards` list and no trip-scoped surface, and no sync-open interrupt
payload at all (issue #210). `/trips/split` now bundles `hazard_rollup(trip)`
alongside the payload, so a sidecar and a hosted server hand the client the
identical worst-first list.

Pure assembly — `split_trip` touches no graph — so this needs no region fixture.
"""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from plotlines_service.app import create_app


def _client(tmp_path: Path) -> TestClient:
    return TestClient(create_app(tmp_path))


def _day(index: int, *, day_hazards=(), seg_hazards=()) -> dict:
    return {
        "index": index,
        "kind": "route",
        "hazards": list(day_hazards),
        "segments": [{
            "id": f"s{index}",
            "mode": "cycling",
            "shape": "point_to_point",
            "start": [0.0, 0.0],
            "end": [0.1, 0.1],
            "metrics": {"distance_m": 5_000.0},
            "hazards": list(seg_hazards),
        }],
    }


def test_split_response_carries_the_hazard_rollup(tmp_path: Path) -> None:
    client = _client(tmp_path)
    resp = client.post("/trips/split", json={
        "title": "Hazard trip",
        "days": [
            _day(1,
                 day_hazards=[{"id": "h-grit", "severity": "caution",
                              "title": "Loose gravel"}],
                 seg_hazards=[{"id": "h-guard", "severity": "high",
                              "title": "Cattle guard"}]),
            _day(2, seg_hazards=[{"id": "h-bridge", "severity": "mandatory_reroute",
                                 "title": "Bridge out"}]),
        ],
    })
    assert resp.status_code == 200
    body = resp.json()

    rollup = body["hazard_rollup"]
    assert rollup["has_sync_alerts"] is True
    # the whole traversal, reading order (day hazard, then its segment's, then day 2)
    assert [h["hazard"]["title"] for h in rollup["hazards"]] == [
        "Loose gravel", "Cattle guard", "Bridge out",
    ]
    # the alerting subset, worst-first — `caution` never interrupts on sync
    assert [a["title"] for a in rollup["sync_alerts"]] == ["Bridge out", "Cattle guard"]
    assert rollup["sync_alerts"][0]["day_index"] == 2
    assert rollup["sync_alerts"][0]["severity"] == "mandatory_reroute"


def test_split_response_rollup_is_empty_lists_for_a_trip_with_no_hazards(tmp_path: Path) -> None:
    client = _client(tmp_path)
    resp = client.post("/trips/split", json={"title": "Calm trip", "days": [_day(1)]})
    assert resp.status_code == 200
    rollup = resp.json()["hazard_rollup"]
    assert rollup == {"has_sync_alerts": False, "sync_alerts": [], "hazards": []}


def test_split_response_rollup_ignores_a_caution_only_trip_for_alerts(tmp_path: Path) -> None:
    client = _client(tmp_path)
    resp = client.post("/trips/split", json={
        "title": "Cautions only",
        "days": [_day(1, seg_hazards=[{"id": "h1", "severity": "caution",
                                      "title": "Puddle"}])],
    })
    assert resp.status_code == 200
    rollup = resp.json()["hazard_rollup"]
    assert rollup["has_sync_alerts"] is False
    assert rollup["sync_alerts"] == []
    assert [h["hazard"]["title"] for h in rollup["hazards"]] == ["Puddle"]
