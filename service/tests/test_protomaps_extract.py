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
    f.write(f"fake pmtiles archive from {source_url} bbox={opts.get('--bbox')} "
            f"region={opts.get('--region')}".encode())
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
    # Primary region (default) — mirrored up to the flat top-level shape
    # mirror_state.basemap_health() and the client already read.
    assert state["basemap"]["build_id"] == "20260913-wnc"
    assert state["basemap"]["source"]["provider"] == "protomaps"
    assert state["basemap"]["source"]["planet_build_date"] == "20260913"
    assert state["basemap"]["source"]["source_url"] == f"{date_probe_server.base_url}/20260913.pmtiles"
    assert state["basemap"]["extracted_at"] == "2026-09-14T12:00:00Z"

    # Issue #457 — covered_regions is a dict keyed by region name, one full
    # entry per region, not a two-field list.
    region = state["basemap"]["covered_regions"]["wnc-corridor"]
    assert region["name"] == "wnc-corridor"
    assert region["bbox"] == list(_BBOX)
    assert region["build_id"] == "20260913-wnc"
    assert region["path"] == "basemap/protomaps/20260913-wnc/corridor.pmtiles"
    assert region["source"]["planet_build_date"] == "20260913"
    assert region["extracted_at"] == "2026-09-14T12:00:00Z"

    # geofabrik key is untouched — same non-clobbering contract every other
    # script writing into MIRROR_STATE.json holds to.
    assert state["geofabrik"] == {"pinned_date": "2026-09-01", "regions": {"nc": {"checked_at": "x"}}}


def test_a_non_primary_region_does_not_touch_the_top_level_fields(
    fake_pmtiles_bin, mirror_root, date_probe_server,
) -> None:
    date_probe_server.live_dates.add("20260913")
    now = datetime(2026, 9, 14, 12, 0, tzinfo=timezone.utc)

    # Publish the primary region first, exactly as a real refresh run would.
    pe.acquire(
        root=mirror_root, bbox=_BBOX, region_name="wnc-corridor",
        build_id="20260913-wnc", upstream_base_url=date_probe_server.base_url,
        pmtiles_bin=str(fake_pmtiles_bin), now=now,
    )
    nc_bbox = (-84.32, 33.75, -75.40, 36.59)
    pe.acquire(
        root=mirror_root, bbox=nc_bbox, region_name="nc", build_id="20260913-nc",
        upstream_base_url=date_probe_server.base_url, pmtiles_bin=str(fake_pmtiles_bin),
        now=now, filename="nc.pmtiles", primary=False,
    )

    state = json.loads((mirror_root / "MIRROR_STATE.json").read_text())
    # Top level still reflects the primary region, unchanged by the NC publish.
    assert state["basemap"]["build_id"] == "20260913-wnc"
    # Both regions are tracked independently.
    assert set(state["basemap"]["covered_regions"]) == {"wnc-corridor", "nc"}
    nc_dest = mirror_root / "basemap" / "protomaps" / "20260913-nc" / "nc.pmtiles"
    assert nc_dest.is_file()
    assert state["basemap"]["covered_regions"]["nc"]["path"] == \
        "basemap/protomaps/20260913-nc/nc.pmtiles"


def test_region_geojson_is_passed_as_region_instead_of_bbox(
    fake_pmtiles_bin, mirror_root, date_probe_server, tmp_path,
) -> None:
    # prewarm_basemap_priority_regions.py — several disjoint areas in one
    # archive go to the CLI as --region; bbox is only the recorded envelope.
    geojson = tmp_path / "areas.geojson"
    geojson.write_text('{"type": "MultiPolygon", "coordinates": []}')
    dest = pe.acquire(
        root=mirror_root, bbox=_BBOX, region_name="priority-regions",
        build_id="20260913-priority", build_date="20260913",
        upstream_base_url=date_probe_server.base_url, pmtiles_bin=str(fake_pmtiles_bin),
        filename="priority.pmtiles", primary=False, region_geojson=geojson,
    )

    body = dest.read_text()
    assert f"region={geojson}" in body
    assert "bbox=None" in body
    state = json.loads((mirror_root / "MIRROR_STATE.json").read_text())
    assert state["basemap"]["covered_regions"]["priority-regions"]["bbox"] == list(_BBOX)


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


# --- region_is_fresh / region_extracted_at (issue #457) ---------------------

def test_region_is_fresh_true_within_ttl() -> None:
    now = datetime(2026, 9, 21, tzinfo=timezone.utc)
    state = {"basemap": {"covered_regions": {
        "wnc-corridor": {"extracted_at": "2026-08-25T00:00:00Z"},  # 27 days old
    }}}
    assert pe.region_is_fresh(state, "wnc-corridor", ttl_days=30.0, now=now) is True


def test_region_is_fresh_false_past_ttl() -> None:
    now = datetime(2026, 9, 21, tzinfo=timezone.utc)
    state = {"basemap": {"covered_regions": {
        "wnc-corridor": {"extracted_at": "2026-08-01T00:00:00Z"},  # 51 days old
    }}}
    assert pe.region_is_fresh(state, "wnc-corridor", ttl_days=30.0, now=now) is False


def test_region_is_fresh_false_when_never_extracted() -> None:
    now = datetime(2026, 9, 21, tzinfo=timezone.utc)
    assert pe.region_is_fresh({"basemap": {}}, "nc", ttl_days=30.0, now=now) is False
    assert pe.region_is_fresh({}, "nc", ttl_days=30.0, now=now) is False


# --- refresh_region / refresh_all (issue #457) ------------------------------

def test_refresh_region_is_a_no_op_when_fresh(
    fake_pmtiles_bin, mirror_root, date_probe_server, monkeypatch,
) -> None:
    date_probe_server.live_dates.add("20260913")
    now = datetime(2026, 9, 14, tzinfo=timezone.utc)
    spec = pe.RegionSpec(
        key="wnc-corridor", label="WNC", bbox=_BBOX, build_id="20260913-wnc",
        filename="corridor.pmtiles", primary=True,
    )
    pe.acquire(
        root=mirror_root, bbox=spec.bbox, region_name=spec.key, build_id=spec.build_id,
        upstream_base_url=date_probe_server.base_url, pmtiles_bin=str(fake_pmtiles_bin), now=now,
    )
    date_probe_server.request_log.clear()

    # No subprocess invoked on a fresh re-run: fail loudly if extraction is
    # attempted anyway.
    def _boom(*_a, **_kw):
        raise AssertionError("pmtiles extract must not run for a fresh region")
    monkeypatch.setattr(pe, "run_pmtiles_extract", _boom)

    later = now + pe.timedelta(days=5)  # still within the default 30-day TTL
    result = pe.refresh_region(root=mirror_root, spec=spec, ttl_days=30.0, now=later)

    assert result.skipped is True
    assert result.reason == "fresh"
    assert date_probe_server.request_log == []  # no build-date re-probe either


def test_refresh_region_re_extracts_when_stale(
    fake_pmtiles_bin, mirror_root, date_probe_server,
) -> None:
    date_probe_server.live_dates.add("20260101")
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    spec = pe.RegionSpec(
        key="wnc-corridor", label="WNC", bbox=_BBOX, build_id="20260913-wnc",
        filename="corridor.pmtiles", primary=True,
    )
    pe.acquire(
        root=mirror_root, bbox=spec.bbox, region_name=spec.key, build_id=spec.build_id,
        upstream_base_url=date_probe_server.base_url, pmtiles_bin=str(fake_pmtiles_bin), now=now,
    )

    date_probe_server.live_dates.add("20260305")
    later = now + pe.timedelta(days=63)  # past the default 30-day TTL
    result = pe.refresh_region(
        root=mirror_root, spec=spec, ttl_days=30.0, now=later,
        upstream_base_url=date_probe_server.base_url, pmtiles_bin=str(fake_pmtiles_bin),
    )

    assert result.skipped is False
    state = json.loads((mirror_root / "MIRROR_STATE.json").read_text())
    assert state["basemap"]["covered_regions"]["wnc-corridor"]["extracted_at"] == \
        later.isoformat().replace("+00:00", "Z")
    assert state["basemap"]["covered_regions"]["wnc-corridor"]["source"]["planet_build_date"] == "20260305"


def test_refresh_region_force_bypasses_freshness(
    fake_pmtiles_bin, mirror_root, date_probe_server,
) -> None:
    date_probe_server.live_dates.add("20260913")
    now = datetime(2026, 9, 14, tzinfo=timezone.utc)
    spec = pe.RegionSpec(
        key="wnc-corridor", label="WNC", bbox=_BBOX, build_id="20260913-wnc",
        filename="corridor.pmtiles", primary=True,
    )
    pe.acquire(
        root=mirror_root, bbox=spec.bbox, region_name=spec.key, build_id=spec.build_id,
        upstream_base_url=date_probe_server.base_url, pmtiles_bin=str(fake_pmtiles_bin), now=now,
    )
    later = now + pe.timedelta(days=1)  # well within TTL

    result = pe.refresh_region(
        root=mirror_root, spec=spec, ttl_days=30.0, now=later, force=True,
        upstream_base_url=date_probe_server.base_url, pmtiles_bin=str(fake_pmtiles_bin),
    )

    assert result.skipped is False


def test_refresh_all_pulls_at_least_two_named_regions(
    fake_pmtiles_bin, mirror_root, date_probe_server,
) -> None:
    date_probe_server.live_dates.add("20260913")
    now = datetime(2026, 9, 14, tzinfo=timezone.utc)
    regions = (
        pe.RegionSpec(key="wnc-corridor", label="WNC", bbox=_BBOX,
                       build_id="20260913-wnc", filename="corridor.pmtiles", primary=True),
        pe.RegionSpec(key="nc", label="NC", bbox=(-84.32, 33.75, -75.40, 36.59),
                       build_id="20260913-nc", filename="nc.pmtiles"),
    )

    results = pe.refresh_all(
        root=mirror_root, regions=regions, ttl_days=30.0, now=now,
        upstream_base_url=date_probe_server.base_url, pmtiles_bin=str(fake_pmtiles_bin),
    )

    assert [r.region.key for r in results] == ["wnc-corridor", "nc"]
    assert all(not r.skipped for r in results)
    state = json.loads((mirror_root / "MIRROR_STATE.json").read_text())
    assert set(state["basemap"]["covered_regions"]) == {"wnc-corridor", "nc"}
    assert (mirror_root / "basemap" / "protomaps" / "20260913-wnc" / "corridor.pmtiles").is_file()
    assert (mirror_root / "basemap" / "protomaps" / "20260913-nc" / "nc.pmtiles").is_file()


# --- CLI: --ttl-days / PLOTLINES_TILES_TTL_DAYS / --regions -----------------

def test_ttl_days_env_var_overrides_the_default(monkeypatch, mirror_root) -> None:
    monkeypatch.setenv(pe.ENV_TTL_DAYS, "7")
    captured = {}

    def _stub(*, ttl_days, **_kwargs):
        captured["ttl_days"] = ttl_days
        return []

    monkeypatch.setattr(pe, "refresh_all", _stub)
    pe.main(["--root", str(mirror_root)])

    assert captured["ttl_days"] == 7.0


def test_ttl_days_flag_overrides_the_env_var(monkeypatch, mirror_root) -> None:
    monkeypatch.setenv(pe.ENV_TTL_DAYS, "7")
    captured = {}

    def _stub(*, ttl_days, **_kwargs):
        captured["ttl_days"] = ttl_days
        return []

    monkeypatch.setattr(pe, "refresh_all", _stub)
    pe.main(["--root", str(mirror_root), "--ttl-days", "3"])

    assert captured["ttl_days"] == 3.0


def test_cli_regions_flag_selects_a_named_subset(
    fake_pmtiles_bin, mirror_root, date_probe_server,
) -> None:
    date_probe_server.live_dates.add("20260913")
    rc = pe.main([
        "--root", str(mirror_root), "--regions", "nc",
        "--upstream-base-url", date_probe_server.base_url,
        "--pmtiles-bin", str(fake_pmtiles_bin),
    ])
    assert rc == 0
    state = json.loads((mirror_root / "MIRROR_STATE.json").read_text())
    assert set(state["basemap"]["covered_regions"]) == {"nc"}
    # nc is not primary, so it never overwrites the top-level build_id —
    # left at the fixture's pre-seeded None, not stamped with nc's pin.
    assert state["basemap"]["build_id"] is None


def test_cli_unknown_region_key_errors(mirror_root) -> None:
    with pytest.raises(SystemExit):
        pe.main(["--root", str(mirror_root), "--regions", "not-a-real-region"])


def test_cli_explicit_bbox_runs_a_single_ad_hoc_region(
    fake_pmtiles_bin, mirror_root, date_probe_server,
) -> None:
    date_probe_server.live_dates.add("20260913")
    rc = pe.main([
        "--root", str(mirror_root), "--bbox=-80.0,35.0,-79.0,36.0",
        "--region-name", "custom", "--build-id", "20260913-custom",
        "--upstream-base-url", date_probe_server.base_url,
        "--pmtiles-bin", str(fake_pmtiles_bin),
    ])
    assert rc == 0
    state = json.loads((mirror_root / "MIRROR_STATE.json").read_text())
    assert "custom" in state["basemap"]["covered_regions"]
    assert state["basemap"]["build_id"] == "20260913-custom"
