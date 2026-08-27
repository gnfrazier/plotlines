"""F1 / FR133 — `/segments/cues` end to end: a node's `amenities` (C5) reach
`derive_cue_sheet` through `NodeInput` and come back woven into the cue's
own instruction text as a `provision` cue, not a separate field. Reuses
`test_segment_shape.py`'s committed SPIKE-00 Boulder fixture graph so this
never touches the network.
"""

from __future__ import annotations

import shutil
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.graph import regions as region_lib
from plotlines_service.app import create_app

_FIXTURE_GRAPH = (Path(__file__).resolve().parents[2] / "spikes" / "SPIKE-00" / "cache"
                  / "boulder_bike.graphml")
_BOULDER_BBOX = [-105.30, 39.99, -105.25, 40.03]
_START = {"lat": 40.0175, "lon": -105.2797}
_END = {"lat": 40.02, "lon": -105.275}

pytestmark = pytest.mark.skipif(
    not _FIXTURE_GRAPH.exists(),
    reason="SPIKE-00 fixture graph not present in this checkout",
)


def _client_with_boulder_region(tmp_path: Path) -> tuple[TestClient, str]:
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


def test_a_node_amenity_reaches_the_cue_sheet_as_a_woven_provision_line(tmp_path: Path) -> None:
    client, key = _client_with_boulder_region(tmp_path)
    resp = client.post("/segments/cues", json={
        "region": key,
        "start": _START,
        "end": _END,
        "shape": "point_to_point",
        "theme": "balanced",
        "nodes": [{
            "id": "n1", "kind": "poi", "distance_along_m": 100.0,
            "title": "Overlook Camp", "amenities": ["water", "toilets"],
        }],
    })
    assert resp.status_code == 200
    cues = resp.json()["cue_sheet"]["cues"]
    provision = next(c for c in cues if c["kind"] == "provision")
    assert provision["instruction"] == "Point of interest: Overlook Camp — water, toilets"
