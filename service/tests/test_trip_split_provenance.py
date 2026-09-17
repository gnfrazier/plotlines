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

import osmnx as ox
from fastapi.testclient import TestClient

from plotlines_core.cache_layout import CacheLayout
from plotlines_core.graph import extract_fetch
from plotlines_service.app import create_app
from plotlines_service.version import VERSION

from mirror_clip_fixtures import node, way, write_pbf


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


def test_split_response_osm_source_names_the_mirror_pin_once_a_region_used_it(
    tmp_path: Path, monkeypatch,
) -> None:
    """Issue #277 — once a region in this session actually built its graph
    from a local mirror clip, a trip assembled afterwards records that pin,
    not the Overpass placeholder, even though `/trips/split` itself carries
    no bbox of its own (`Readiness.osm_source_pin`'s "most recently
    finished region" reading)."""
    bbox = [-105.30, 39.99, -105.25, 40.03]
    pin = "2026-09-01"

    def _refuse_overpass(*_a, **_k):
        raise AssertionError("must not touch Overpass with a clip cached")
    monkeypatch.setattr(ox, "graph_from_bbox", _refuse_overpass)

    def _fake_ensure_extract(bbox, *, mirror_url, cache_dir, client_key=None,
                             progress=None, **_kwargs):
        path = write_pbf(
            CacheLayout(cache_dir).osm_extract(tuple(bbox), pin),
            nodes=[node(1, -105.29, 40.00), node(2, -105.28, 40.01)],
            ways=[way(10, [1, 2], {"highway": "residential"})],
        )
        if progress is not None:
            size = path.stat().st_size
            progress.status = "ready"
            progress.bytes_downloaded = size
            progress.total_bytes = size
        return path

    monkeypatch.setattr(extract_fetch, "ensure_extract", _fake_ensure_extract)
    client = TestClient(create_app(tmp_path, mirror_clip_url="http://mirror.example"))

    key = client.post("/regions", json={"bbox": bbox}).json()["region"]
    client.app.state.readiness._build_pool.shutdown(wait=True)
    assert client.get("/health").json()["capabilities"]["routing"]["regions"][key] == {
        "ready": True
    }

    resp = client.post("/trips/split", json={
        "title": "Mirror-pinned trip", "days": [_day(1)],
    })
    assert resp.json()["provenance"]["osm_source"] == f"geofabrik:{pin}"


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
