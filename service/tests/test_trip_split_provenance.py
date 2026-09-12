"""L7 / issue #270 — `/trips/split` writes a populated `provenance`.

Before this, `plotlines-core` declared `Provenance`/`Attribution`
(`trips/payload.py`) and the schema carried them, but nothing constructed
one — the client already read `trip.provenance` (`reveal_view.dart`'s
`attributionForTrip()`) with nothing on the other end. `/trips/split` is the
one production call site of `split_trip`, so this is where the producer
half of the contract has to show up.
"""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from plotlines_service.app import create_app
from plotlines_service.version import VERSION


def _client(tmp_path: Path) -> TestClient:
    return TestClient(create_app(tmp_path))


def _day(index: int) -> dict:
    return {
        "index": index,
        "kind": "route",
        "segments": [{
            "id": f"s{index}",
            "mode": "cycling",
            "shape": "point_to_point",
            "start": [0.0, 0.0],
            "end": [0.1, 0.1],
            "metrics": {"distance_m": 5_000.0},
        }],
    }


def test_split_response_carries_a_populated_provenance(tmp_path: Path) -> None:
    client = _client(tmp_path)
    resp = client.post("/trips/split", json={
        "title": "Provenance trip", "days": [_day(1)],
    })
    assert resp.status_code == 200
    provenance = resp.json()["provenance"]

    assert provenance["produced_by"] == f"plotlines-core {VERSION}"
    assert provenance["app_version"] == VERSION
    assert provenance["sidecar_version"] == VERSION
    assert provenance["attribution"]


def test_split_response_osm_source_names_overpass_and_a_fetch_timestamp(
    tmp_path: Path,
) -> None:
    client = _client(tmp_path)
    resp = client.post("/trips/split", json={
        "title": "Pin trip", "days": [_day(1)],
    })
    body = resp.json()
    osm_source = body["provenance"]["osm_source"]

    assert osm_source.startswith("overpass:")
    # Agrees with the trip's own `created_at` — Phase 1 has no per-fetch
    # record of its own, so the payload's own write time is the honest stamp.
    assert osm_source == f"overpass:{body['created_at']}"


def test_split_response_attribution_includes_the_graph_and_static_credits(
    tmp_path: Path,
) -> None:
    """Addendum L7's concrete payoff: the routing graph's own ODbL credit
    (issue #269) now travels with the trip, not only the About screen."""
    client = _client(tmp_path)
    resp = client.post("/trips/split", json={
        "title": "Attribution trip", "days": [_day(1)],
    })
    lines = resp.json()["provenance"]["attribution"]
    by_source = {line["source"]: line for line in lines}

    assert "graph" in by_source
    assert by_source["graph"]["licence"] == "ODbL-1.0"
    assert "elevation" in by_source
    assert "basemap" in by_source
