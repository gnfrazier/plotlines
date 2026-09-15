"""F1 / FR133 — `/segments/cues` end to end: a node's `amenities` (C5) reach
`derive_cue_sheet` through `NodeInput` and come back woven into the cue's
own instruction text as a `provision` cue, not a separate field. Routes
against `conftest.py`'s `boulder_region` (the committed SPIKE-00 Boulder
fixture graph) so this never touches the network.
"""

from __future__ import annotations

_START = {"lat": 40.0175, "lon": -105.2797}
_END = {"lat": 40.02, "lon": -105.275}


def test_a_node_amenity_reaches_the_cue_sheet_as_a_woven_provision_line(boulder_region) -> None:
    client, key = boulder_region
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
