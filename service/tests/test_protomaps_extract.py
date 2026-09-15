"""`deploy/mirror/protomaps_extract.py` — issue #394 (gap found auditing
#257's closing comment: the real Protomaps planet build `MIRROR_ARCHIVE_URL`
names was never acquired). Companion to `test_mirror_deploy_config.py`'s
`TestCopyBasemapStandin`, which this script's `publish_basemap_extract`
deliberately writes the same `MIRROR_STATE.json` shape as.

Loaded by file path like `test_geofabrik_pull.py` loads `geofabrik_pull.py`
— `deploy/mirror/` is deployed standalone, not imported as part of
`plotlines_core`.

No test here touches the real `build.protomaps.com` — a fake HTTP server
stands in for build-date discovery, and a fake `pmtiles` executable (a small
Python script) stands in for the real Go CLI, so these tests are hermetic
and fast. The real endpoint and the real CLI were exercised by hand while
writing this script (see its module docstring for the measured numbers);
that one-time acquisition is not something CI can depend on repeating.
"""

from __future__ import annotations

import http.server
import importlib.util
import json
import stat
import sys
import threading
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

_SCRIPT_PATH = (
    Path(__file__).resolve().parents[2] / "deploy" / "mirror" / "protomaps_extract.py"
)


def _load_protomaps_extract():
    spec = importlib.util.spec_from_file_location("protomaps_extract", _SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["protomaps_extract"] = module
    spec.loader.exec_module(module)
    return module


pe = _load_protomaps_extract()

_BBOX = (-83.6, 35.2, -81.0, 36.4)


class _DateProbeHandler(http.server.BaseHTTPRequestHandler):
    live_dates: set[str] = set()
    request_log: list[str] = []

    def do_HEAD(self):  # noqa: N802 — stdlib handler method name
        self.request_log.append(self.path)
        date = self.path.lstrip("/").removesuffix(".pmtiles")
        if date in self.live_dates:
            self.send_response(200)
            self.end_headers()
        else:
            self.send_error(404)

    def log_message(self, *_args):
        pass


@pytest.fixture
def date_probe_server():
    live_dates: set[str] = set()
    request_log: list[str] = []
    handler = type("Handler", (_DateProbeHandler,),
                    {"live_dates": live_dates, "request_log": request_log})
    server = http.server.HTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield SimpleNamespace(
            base_url=f"http://127.0.0.1:{server.server_port}",
            live_dates=live_dates,
            request_log=request_log,
        )
    finally:
        server.shutdown()
        thread.join(timeout=5)


# --- find_latest_build_date -------------------------------------------------

def test_finds_the_most_recent_live_date(date_probe_server) -> None:
    date_probe_server.live_dates.update({"20260912", "20260913", "20260914"})
    start = datetime(2026, 9, 14, tzinfo=timezone.utc)

    found = pe.find_latest_build_date(
        base_url=date_probe_server.base_url, start=start, max_lookback_days=14,
    )

    assert found == "20260914"


def test_probes_backward_past_a_gap_in_retention(date_probe_server) -> None:
    # Mirrors what was actually observed against the real upstream: a short
    # rolling retention window with no index to consult, so the newest date
    # can 404 while an older one still lives.
    date_probe_server.live_dates.add("20260909")
    start = datetime(2026, 9, 14, tzinfo=timezone.utc)

    found = pe.find_latest_build_date(
        base_url=date_probe_server.base_url, start=start, max_lookback_days=14,
    )

    assert found == "20260909"
    # Probed every day back to the live one, oldest requests last.
    assert date_probe_server.request_log == [
        f"/{d}.pmtiles" for d in
        ("20260914", "20260913", "20260912", "20260911", "20260910", "20260909")
    ]


def test_raises_when_nothing_is_found_within_the_lookback_window(date_probe_server) -> None:
    start = datetime(2026, 9, 14, tzinfo=timezone.utc)

    with pytest.raises(pe.BuildNotFound):
        pe.find_latest_build_date(
            base_url=date_probe_server.base_url, start=start, max_lookback_days=3,
        )
    assert len(date_probe_server.request_log) == 3


# --- run_pmtiles_extract / publish_basemap_extract --------------------------

_FAKE_PMTILES_SCRIPT = """#!/usr/bin/env python3
import sys

args = sys.argv[1:]
assert args[0] == "extract"
source_url, out_path = args[1], args[2]
opts = {a.split("=", 1)[0]: a.split("=", 1)[1] for a in args[3:] if "=" in a}

if "FAIL" in source_url:
    print("simulated extract failure", file=sys.stderr)
    sys.exit(1)

with open(out_path, "wb") as f:
    f.write(f"fake pmtiles archive from {source_url} bbox={opts.get('--bbox')}"
            .encode())
print("Extract required 95 total requests.")
"""


@pytest.fixture
def fake_pmtiles_bin(tmp_path) -> Path:
    script = tmp_path / "fake-pmtiles"
    script.write_text(_FAKE_PMTILES_SCRIPT)
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return script


@pytest.fixture
def mirror_root(tmp_path) -> Path:
    root = tmp_path / "mirror"
    root.mkdir()
    (root / "MIRROR_STATE.json").write_text(json.dumps(
        {"schema_version": 1, "basemap": {"build_id": None, "covered_regions": []},
         "geofabrik": {"pinned_date": "2026-09-01", "regions": {"nc": {"checked_at": "x"}}}}
    ))
    return root


def test_acquire_extracts_and_publishes_end_to_end(
    fake_pmtiles_bin, mirror_root, date_probe_server,
) -> None:
    date_probe_server.live_dates.add("20260913")
    now = datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc)

    dest = pe.acquire(
        root=mirror_root, bbox=_BBOX, region_name="wnc-corridor",
        build_id="20260913-wnc", upstream_base_url=date_probe_server.base_url,
        pmtiles_bin=str(fake_pmtiles_bin), now=now,
    )

    assert dest == mirror_root / "basemap" / "protomaps" / "20260913-wnc" / "corridor.pmtiles"
    assert dest.is_file()
    body = dest.read_text()
    assert f"{date_probe_server.base_url}/20260913.pmtiles" in body
    assert "-83.6,35.2,-81.0,36.4" in body

    state = json.loads((mirror_root / "MIRROR_STATE.json").read_text())
    assert state["basemap"]["build_id"] == "20260913-wnc"
    assert state["basemap"]["covered_regions"] == [
        {"name": "wnc-corridor", "bbox": list(_BBOX)},
    ]
    assert state["basemap"]["source"]["provider"] == "protomaps"
    assert state["basemap"]["source"]["planet_build_date"] == "20260913"
    assert state["basemap"]["source"]["source_url"] == f"{date_probe_server.base_url}/20260913.pmtiles"
    assert state["basemap"]["extracted_at"] == "2026-09-14T12:00:00Z"

    # geofabrik key is untouched — same non-clobbering contract every other
    # script writing into MIRROR_STATE.json holds to.
    assert state["geofabrik"] == {"pinned_date": "2026-09-01", "regions": {"nc": {"checked_at": "x"}}}


def test_explicit_build_date_skips_probing(fake_pmtiles_bin, mirror_root, date_probe_server) -> None:
    # No dates registered as live at all — an explicit --build-date must
    # never trigger a probe.
    pe.acquire(
        root=mirror_root, bbox=_BBOX, region_name="wnc-corridor",
        build_id="20260901-wnc", upstream_base_url=date_probe_server.base_url,
        build_date="20260901", pmtiles_bin=str(fake_pmtiles_bin),
        now=datetime(2026, 9, 14, tzinfo=timezone.utc),
    )
    assert date_probe_server.request_log == []


def test_a_failed_extract_leaves_the_previously_published_archive_untouched(
    fake_pmtiles_bin, mirror_root, date_probe_server,
) -> None:
    date_probe_server.live_dates.add("20260913")
    now = datetime(2026, 9, 14, tzinfo=timezone.utc)

    dest = pe.acquire(
        root=mirror_root, bbox=_BBOX, region_name="wnc-corridor",
        build_id="20260913-wnc", upstream_base_url=date_probe_server.base_url,
        pmtiles_bin=str(fake_pmtiles_bin), now=now,
    )
    original_bytes = dest.read_bytes()
    original_state = (mirror_root / "MIRROR_STATE.json").read_text()

    # A source URL containing "FAIL" trips the fake binary's simulated
    # failure path (see _FAKE_PMTILES_SCRIPT) — stand-in for a real
    # extract-time error (network blip, upstream 5xx, bad bbox).
    with pytest.raises(pe.ExtractFailed):
        pe.acquire(
            root=mirror_root, bbox=_BBOX, region_name="wnc-corridor",
            build_id="20260913-wnc", upstream_base_url=date_probe_server.base_url,
            build_date="FAIL", pmtiles_bin=str(fake_pmtiles_bin), now=now,
        )

    assert dest.read_bytes() == original_bytes
    assert (mirror_root / "MIRROR_STATE.json").read_text() == original_state
    # No stray temp files left behind under the destination directory.
    assert sorted(p.name for p in dest.parent.iterdir()) == ["corridor.pmtiles"]


def test_fails_clearly_when_mirror_state_is_missing(fake_pmtiles_bin, tmp_path, date_probe_server) -> None:
    root = tmp_path / "mirror"
    root.mkdir()  # no MIRROR_STATE.json — build_tree.sh never ran
    date_probe_server.live_dates.add("20260913")

    with pytest.raises(SystemExit, match="MIRROR_STATE.json does not exist"):
        pe.acquire(
            root=root, bbox=_BBOX, region_name="wnc-corridor",
            build_id="20260913-wnc", upstream_base_url=date_probe_server.base_url,
            pmtiles_bin=str(fake_pmtiles_bin),
            now=datetime(2026, 9, 14, tzinfo=timezone.utc),
        )


def test_resolve_pmtiles_bin_prefers_explicit_over_path(fake_pmtiles_bin) -> None:
    assert pe._resolve_pmtiles_bin(str(fake_pmtiles_bin)) == str(fake_pmtiles_bin)


def test_resolve_pmtiles_bin_raises_clearly_when_nothing_is_found(monkeypatch) -> None:
    monkeypatch.setattr(pe.shutil, "which", lambda _name: None)
    monkeypatch.setattr(pe.Path, "is_file", lambda _self: False)

    with pytest.raises(pe.ExtractFailed, match="no `pmtiles` binary found"):
        pe._resolve_pmtiles_bin(None)
