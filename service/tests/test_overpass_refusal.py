"""Issue #284 (Phase 5.1, ARCH D63 phase 3): the sidecar refuses a public
Overpass fallback by default, and its dev escape hatch is off by default and
named like `--allow-unmirrored-tiles`."""

from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient

from plotlines_core.graph import regions as region_lib
from plotlines_service.__main__ import parse_args
from plotlines_service.app import create_app


def test_the_escape_hatch_is_off_by_default(tmp_path: Path):
    base = ["--cache-dir", str(tmp_path)]
    assert parse_args(base).allow_unmirrored_osm is False
    assert parse_args(base + ["--allow-unmirrored-osm"]).allow_unmirrored_osm is True
    assert parse_args(base).allow_unmirrored_tiles is False


def test_a_region_with_no_clip_settles_to_the_refusal_sentence(tmp_path: Path, monkeypatch):
    monkeypatch.delenv("PLOTLINES_OVERPASS_ENDPOINTS", raising=False)
    tried = []
    monkeypatch.setattr(region_lib, "_download_region_graph",
                        lambda region: tried.append(region) or None)

    client = TestClient(create_app(tmp_path))
    try:
        key = client.post("/regions", json={"bbox": [-105.3, 40.0, -105.2, 40.1]}).json()["region"]
        import time
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            region = client.get("/health").json()["capabilities"]["routing"]["regions"].get(key, {})
            if region.get("reason", "").startswith("failed:"):
                break
            time.sleep(0.05)
    finally:
        client.app.state.readiness.shutdown()

    assert tried == [], "no public Overpass query may be made"
    assert region["reason"] == "failed:" + region_lib.OVERPASS_REFUSED_MESSAGE
