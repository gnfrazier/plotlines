"""`GET /health`'s `capabilities.mirror` — issue #260 (Phase 1.6, epic #264;
docs/Plotlines_OSM_Acquisition_Review.md §6.6, addendum Q2). Unconfigured by
default (no sidecar is pointed at a mirror in production yet — that's
#261); when `--mirror-state-url` is given, staleness reads through from
`plotlines_core.tiles.mirror_state`, and a fetch failure degrades to a
stale reading rather than a 500 that would take the rest of `/health` down
with it.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient

from plotlines_service.app import create_app

def _now_iso_minus(days: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat().replace(
        "+00:00", "Z")


def test_mirror_capability_absent_by_default(tmp_path):
    client = TestClient(create_app(tmp_path))
    body = client.get("/health").json()
    assert body["capabilities"]["mirror"] == {"configured": False}


def test_mirror_capability_reads_a_fresh_local_state_file(tmp_path):
    state_path = tmp_path / "MIRROR_STATE.json"
    state_path.write_text(json.dumps({
        "schema_version": 1,
        "basemap": {"build_id": datetime.now(timezone.utc).strftime("%Y%m%d") + "-wnc"},
        "geofabrik": {
            "pinned_date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "regions": {
                "north-america/us/north-carolina": {
                    "checked_at": _now_iso_minus(1),
                    "consecutive_failures": 0, "last_failure": None,
                },
            },
        },
    }))
    client = TestClient(create_app(tmp_path, mirror_state_url=str(state_path)))
    mirror = client.get("/health").json()["capabilities"]["mirror"]
    assert mirror["configured"] is True
    assert mirror["stale"] is False
    assert mirror["basemap"]["stale"] is False
    assert mirror["geofabrik"]["stale"] is False


def test_mirror_capability_reports_stale_for_a_deliberately_stalled_pull(tmp_path):
    """The acceptance criterion, exercised end to end: a mirror whose cron
    silently stopped months ago must be visibly stale on `/health`, not
    indistinguishable from a working one."""
    state_path = tmp_path / "MIRROR_STATE.json"
    state_path.write_text(json.dumps({
        "schema_version": 1,
        "basemap": {"build_id": "20250101-wnc"},
        "geofabrik": {
            "pinned_date": "2025-01-01",
            "regions": {
                "north-america/us/north-carolina": {
                    "checked_at": "2025-01-02T00:00:00Z",
                    "consecutive_failures": 0, "last_failure": None,
                },
            },
        },
    }))
    client = TestClient(create_app(tmp_path, mirror_state_url=str(state_path)))
    mirror = client.get("/health").json()["capabilities"]["mirror"]
    assert mirror["stale"] is True
    assert mirror["basemap"]["stale"] is True
    assert mirror["geofabrik"]["stale"] is True


def test_mirror_capability_missing_file_degrades_to_stale_not_a_500(tmp_path):
    client = TestClient(create_app(
        tmp_path, mirror_state_url=str(tmp_path / "does-not-exist.json")))
    resp = client.get("/health")
    assert resp.status_code == 200
    mirror = resp.json()["capabilities"]["mirror"]
    assert mirror["configured"] is True
    assert mirror["stale"] is True
    assert "error" in mirror
    # every other capability must still be reported
    assert "layers" in resp.json()["capabilities"]
