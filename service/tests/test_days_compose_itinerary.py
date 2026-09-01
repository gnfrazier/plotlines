"""E3 / FR39 / FR117 / FR118 — `/days/compose` carries the compose-mode
places-first views (issue #214).

`plotlines_core.trips.spine` is the model half of Story E3: `compose_itinerary`
(ordered `ItineraryStop`s with the `ItineraryLeg`s between them, plus A0a's
`DistanceOutcome`), `recap_spine`, and `spine_cues`. Before this no service
endpoint returned any of it — `/days/compose` returned only `compose_day`'s
`Day` — and the client had no way to reach the itinerary its compose UI needs.

`/days/compose` now bundles those three alongside the `Day` (the same place
`/trips/split` rides `hazard_rollup` / `dashboard`), computed once server-side
from the request's ordered `anchors` spine, so a sidecar and a future hosted
assembly hand the client identical structure. Pure assembly — `compose_day`
touches no graph — so this needs no region fixture.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_service.app import create_app


def _client(tmp_path: Path) -> TestClient:
    return TestClient(create_app(tmp_path))


# A straight three-point spine along the 40th parallel. At lat 40, 0.05 deg of
# longitude is ~4.26 km, so each leg is ~4.26 km and the day ~8.52 km.
_A = [-105.30, 40.00]
_B = [-105.25, 40.00]
_C = [-105.20, 40.00]


def _anchor(coord: list[float], title: str, roles: list[dict]) -> dict:
    return {"id": f"anc-{title}", "coord": coord, "title": title, "roles": roles}


def _spine_anchors() -> list[dict]:
    return [
        _anchor(_A, "trailhead", [{"kind": "provision"}]),
        _anchor(_B, "old-mine", [{"kind": "narrative", "arc": "rising"}]),
        _anchor(_C, "summit", [{"kind": "narrative", "arc": "climax"}]),
    ]


def _compose_segment(*, with_geometry: bool = True) -> dict:
    seg: dict = {
        "id": "seg-1",
        "mode": "hiking",
        "shape": "point_to_point",
        "start": _A,
        "end": _C,
        "via": [_B],
        "metrics": {"distance_m": 8_520.0},
    }
    if with_geometry:
        seg["geometry"] = {"type": "LineString", "coordinates": [_A, _B, _C]}
    return seg


def _body(**over: object) -> dict:
    body = {"segments": [_compose_segment()], "anchors": _spine_anchors(), "index": 1}
    body.update(over)
    return body


def test_compose_response_still_carries_the_day(tmp_path: Path) -> None:
    resp = _client(tmp_path).post("/days/compose", json=_body())
    assert resp.status_code == 200
    body = resp.json()
    assert body["index"] == 1
    assert [s["id"] for s in body["segments"]] == ["seg-1"]


def test_itinerary_is_places_first_with_a_leg_between_each_pair(tmp_path: Path) -> None:
    body = resp = _client(tmp_path).post("/days/compose", json=_body()).json()
    itin = body["itinerary"]

    assert itin["planning_mode"] == "compose"
    assert itin["spine"] == ["anc-trailhead", "anc-old-mine", "anc-summit"]
    assert [s["order"] for s in itin["stops"]] == [0, 1, 2]
    assert [leg["order"] for leg in itin["legs"]] == [0, 1]
    # the single solved passage is split back into one leg per anchor pair
    assert itin["legs"][0]["distance_m"] == pytest.approx(4_260, abs=40)
    assert itin["legs"][1]["distance_m"] == pytest.approx(4_260, abs=40)
    # cumulative distance along the spine reaches each stop
    assert itin["stops"][0]["distance_along_m"] == 0.0
    assert itin["stops"][2]["distance_along_m"] == pytest.approx(8_520, abs=80)


def test_distance_outcome_keeps_the_real_solved_length_and_the_target(tmp_path: Path) -> None:
    body = _client(tmp_path).post("/days/compose", json=_body(target_m=10_000.0)).json()
    outcome = body["itinerary"]["distance"]

    assert outcome["planning_mode"] == "compose"
    # the reported length is the passage's own solved metric, not the sum of
    # the projected split (which rounds differently)
    assert outcome["realised_m"] == 8_520.0
    assert outcome["target_m"] == 10_000.0
    assert outcome["deviation_m"] == -1_480.0
    # A0a: a compose deviation is never a conflict or an error, whatever the miss
    assert outcome["is_conflict"] is False
    assert outcome["is_error"] is False


def test_recap_is_only_the_plot_points(tmp_path: Path) -> None:
    body = _client(tmp_path).post("/days/compose", json=_body()).json()
    recap = body["recap"]
    # the trailhead is provision-only — logistics, not story — so it stays off
    assert [e["anchor_id"] for e in recap] == ["anc-old-mine", "anc-summit"]
    assert recap[0]["arc_stages"] == ["rising"]
    assert recap[1]["arc_stages"] == ["climax"]


def test_cues_are_one_per_place_along_the_spine(tmp_path: Path) -> None:
    body = _client(tmp_path).post("/days/compose", json=_body()).json()
    cues = body["cues"]
    assert [c["kind"] for c in cues] == ["start", "node", "finish"]
    assert [c["ref_id"] for c in cues] == ["anc-trailhead", "anc-old-mine", "anc-summit"]
    assert cues[0]["distance_along_m"] == 0.0


def test_no_itinerary_block_without_a_spine_of_two(tmp_path: Path) -> None:
    body = _client(tmp_path).post(
        "/days/compose", json={"segments": [_compose_segment()], "anchors": [_spine_anchors()[0]]}
    ).json()
    assert "itinerary" not in body
    assert "recap" not in body
    assert "cues" not in body


def test_unrouted_spine_degrades_to_unmeasured_never_zero(tmp_path: Path) -> None:
    body = _client(tmp_path).post(
        "/days/compose",
        json=_body(segments=[_compose_segment(with_geometry=False)]),
    ).json()
    itin = body["itinerary"]
    assert itin["stops"][0]["distance_along_m"] == 0.0
    assert itin["stops"][1]["distance_along_m"] is None
    assert itin["stops"][2]["distance_along_m"] is None
    assert itin["legs"][0]["distance_m"] is None
    # cues can only place the stops it can measure
    assert [c["ref_id"] for c in body["cues"]] == ["anc-trailhead"]


def test_a_role_less_anchor_in_the_spine_is_a_422(tmp_path: Path) -> None:
    bad = _spine_anchors()
    bad[1]["roles"] = []
    resp = _client(tmp_path).post("/days/compose", json=_body(anchors=bad))
    assert resp.status_code == 422


def test_pre_split_multi_segment_day_is_used_as_is(tmp_path: Path) -> None:
    # A day already in the one-passage-per-pair shape (2 segments for 3
    # anchors) is passed straight through to compose_itinerary.
    seg_a = {
        "id": "leg-a", "mode": "hiking", "shape": "point_to_point",
        "start": _A, "end": _B, "metrics": {"distance_m": 4_000.0},
    }
    seg_b = {
        "id": "leg-b", "mode": "hiking", "shape": "point_to_point",
        "start": _B, "end": _C, "metrics": {"distance_m": 6_000.0},
    }
    body = _client(tmp_path).post(
        "/days/compose", json=_body(segments=[seg_a, seg_b])
    ).json()
    itin = body["itinerary"]
    assert [leg["segment_id"] for leg in itin["legs"]] == ["leg-a", "leg-b"]
    assert itin["distance"]["realised_m"] == 10_000.0
