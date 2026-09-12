"""The `/clip` HTTP layer — issue #262 (Phase 1.8 of epic #264). Exercises
`plotlines_service.mirror_clip.create_clip_app` via `TestClient`, same
pattern `test_elevation_proxy.py` uses for its sibling Pi5 companion
service. `test_mirror_clip.py` covers the pyosmium clip logic itself; this
file covers only the request/response contract: bbox in as GET query params
or a POST body, a clipped `.osm.pbf` with its metadata headers out, and —
acceptance criterion 5 — a finished JSON error body rather than a stack
trace for bad input or a bbox this mirror doesn't cover.
"""

from __future__ import annotations

from pathlib import Path

import osmium
from fastapi.testclient import TestClient

from mirror_clip_fixtures import build_mirror_tree, node, write_pbf

from plotlines_service.mirror_clip import create_clip_app

_BBOX = {"west": -82.6, "south": 34.9, "east": -81.9, "north": 35.6}


def _mirror_with_one_region(tmp_path: Path) -> Path:
    src = write_pbf(
        tmp_path / "src.osm.pbf",
        nodes=[node(1, -82.2, 35.2, {"natural": "peak", "name": "Test Peak"})],
        box=(-83.0, 34.0, -81.0, 36.0),
    )
    return build_mirror_tree(tmp_path / "mirror", regions={"the-region": src})


def test_get_clip_returns_a_valid_pbf_with_metadata_headers(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    resp = tc.get("/clip", params=_BBOX)

    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/octet-stream"
    assert 'filename="clip.osm.pbf"' in resp.headers["content-disposition"]
    assert int(resp.headers["x-plotlines-clip-output-bytes"]) == len(resp.content)
    assert resp.headers["x-plotlines-clip-source-regions"] == "the-region"
    assert float(resp.headers["x-plotlines-clip-wall-time-ms"]) >= 0.0

    out_path = tmp_path / "roundtrip.osm.pbf"
    out_path.write_bytes(resp.content)
    seen = []
    osmium.apply(str(out_path), type("_C", (osmium.SimpleHandler,), {
        "node": lambda self, n: seen.append(n.id)
    })())
    assert seen == [1]


def test_post_clip_accepts_the_same_bbox_as_a_json_body(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    resp = tc.post("/clip", json=_BBOX)

    assert resp.status_code == 200
    assert resp.headers["x-plotlines-clip-source-regions"] == "the-region"


def test_clip_output_file_does_not_survive_the_response(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    scratch = tmp_path / "scratch"
    tc = TestClient(create_clip_app(mirror, tmp_dir=scratch))

    resp = tc.get("/clip", params=_BBOX)

    assert resp.status_code == 200
    leftover_pbfs = list(scratch.glob("*.osm.pbf"))
    assert leftover_pbfs == []  # the background cleanup task ran


def test_out_of_coverage_bbox_is_a_finished_sentence_not_a_stack_trace(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    resp = tc.get(
        "/clip", params={"west": 10.0, "south": 50.0, "east": 11.0, "north": 51.0}
    )

    assert resp.status_code == 404
    body = resp.json()["detail"]
    assert body["error"] == "no_mirror_coverage"
    assert "Traceback" not in resp.text


def test_invalid_bbox_returns_400_with_a_finished_sentence(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    resp = tc.get(
        "/clip", params={"west": -81.0, "south": 34.9, "east": -82.6, "north": 35.6}
    )

    assert resp.status_code == 400
    assert resp.json()["detail"]["error"] == "invalid_bbox"
    assert "Traceback" not in resp.text


def test_health_reports_the_pinned_extracts(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    resp = tc.get("/health")

    assert resp.status_code == 200
    body = resp.json()
    assert body["ready"] is True
    assert body["root"] == str(mirror)
    assert body["pinned_extracts"] == ["the-region"]
    # Still an exact key set, so a field cannot appear or vanish here
    # unnoticed — but the `licence` block's *values* belong to
    # test_mirror_clip_licence_notice.py (#364), not restated here.
    assert set(body) == {"ready", "root", "pinned_extracts", "licence"}


# --------------------------------------------------------------------------
# Reachability — issue #263, review §6.8/1d
# --------------------------------------------------------------------------


def test_clip_stays_open_when_no_client_key_is_configured(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    resp = tc.get("/clip", params=_BBOX)  # no X-Plotlines-Client-Key header at all

    assert resp.status_code == 200


def test_clip_refuses_a_missing_client_key_with_an_honest_401(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(
        create_clip_app(mirror, tmp_dir=tmp_path / "scratch", client_key="s3cret")
    )

    resp = tc.get("/clip", params=_BBOX)

    assert resp.status_code == 401
    assert resp.json()["detail"]["error"] == "unauthorized_client"
    assert "Traceback" not in resp.text


def test_clip_refuses_a_wrong_client_key(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(
        create_clip_app(mirror, tmp_dir=tmp_path / "scratch", client_key="s3cret")
    )

    resp = tc.get(
        "/clip", params=_BBOX, headers={"X-Plotlines-Client-Key": "wrong"}
    )

    assert resp.status_code == 401
    assert resp.json()["detail"]["error"] == "unauthorized_client"


def test_clip_accepts_the_correct_client_key(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(
        create_clip_app(mirror, tmp_dir=tmp_path / "scratch", client_key="s3cret")
    )

    resp = tc.get(
        "/clip", params=_BBOX, headers={"X-Plotlines-Client-Key": "s3cret"}
    )

    assert resp.status_code == 200


def test_health_needs_no_client_key(tmp_path: Path) -> None:
    # Ops monitoring must not have to carry the client key just to poll
    # liveness, and /health costs nothing to serve.
    mirror = _mirror_with_one_region(tmp_path)
    tc = TestClient(
        create_clip_app(mirror, tmp_dir=tmp_path / "scratch", client_key="s3cret")
    )

    resp = tc.get("/health")

    assert resp.status_code == 200


def test_clip_rate_limits_per_caller_regardless_of_client_key(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    clock = [0.0]
    tc = TestClient(
        create_clip_app(
            mirror,
            tmp_dir=tmp_path / "scratch",
            rate_limit_per_minute=1,
            rate_limit_time_fn=lambda: clock[0],
        )
    )

    first = tc.get("/clip", params=_BBOX)
    second = tc.get("/clip", params=_BBOX)

    assert first.status_code == 200
    assert second.status_code == 429
    assert second.json()["detail"]["error"] == "rate_limited"
    assert "Traceback" not in second.text


def test_clip_rate_limit_window_resets(tmp_path: Path) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    clock = [0.0]
    tc = TestClient(
        create_clip_app(
            mirror,
            tmp_dir=tmp_path / "scratch",
            rate_limit_per_minute=1,
            rate_limit_time_fn=lambda: clock[0],
        )
    )

    first = tc.get("/clip", params=_BBOX)
    clock[0] = 61.0  # past the 60s window
    second = tc.get("/clip", params=_BBOX)

    assert first.status_code == 200
    assert second.status_code == 200


def test_clip_rate_limit_tracks_callers_independently_by_forwarded_ip(
    tmp_path: Path,
) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    clock = [0.0]
    tc = TestClient(
        create_clip_app(
            mirror,
            tmp_dir=tmp_path / "scratch",
            rate_limit_per_minute=1,
            rate_limit_time_fn=lambda: clock[0],
        )
    )

    a1 = tc.get("/clip", params=_BBOX, headers={"X-Forwarded-For": "10.0.0.1"})
    b1 = tc.get("/clip", params=_BBOX, headers={"X-Forwarded-For": "10.0.0.2"})
    a2 = tc.get("/clip", params=_BBOX, headers={"X-Forwarded-For": "10.0.0.1"})

    assert a1.status_code == 200
    assert b1.status_code == 200  # a different caller, not throttled by A's usage
    assert a2.status_code == 429  # A's own second request in the same window
