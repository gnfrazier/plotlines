"""`deploy/mirror/prewarm_basemap_priority_regions.py` — one mirror basemap
archive over the elevation proxy's priority regions (issue #453). Loaded by
file path like `test_protomaps_extract.py`; a fake `pmtiles` executable
stands in for the Go CLI and `--build-date` skips build discovery, so
nothing here reaches `build.protomaps.com`.
"""

from __future__ import annotations

import importlib.util
import json
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

_SCRIPT_PATH = (
    Path(__file__).resolve().parents[2] / "deploy" / "mirror"
    / "prewarm_basemap_priority_regions.py"
)


def _load():
    spec = importlib.util.spec_from_file_location("prewarm_basemap_priority_regions", _SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["prewarm_basemap_priority_regions"] = module
    spec.loader.exec_module(module)
    return module


pb = _load()

_WNC = (-83.6, 35.2, -81.0, 36.4)

# Records its argv and the --region file's contents, so a test can read back
# exactly what the real CLI would have been handed.
_FAKE_PMTILES_SCRIPT = """#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
opts = {a.split("=", 1)[0]: a.split("=", 1)[1] for a in args[3:] if "=" in a}
region = json.load(open(opts["--region"])) if "--region" in opts else None
with open(args[2], "w") as f:
    json.dump({"source": args[1], "opts": opts, "region": region}, f)
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
    (root / "MIRROR_STATE.json").write_text(json.dumps({
        "schema_version": 1,
        "basemap": {"build_id": "20250101-wnc", "covered_regions": {"wnc-corridor": {
            "name": "wnc-corridor", "extracted_at": "2026-09-21T18:22:55Z"}}},
        "geofabrik": {"pinned_date": "2026-09-18"},
    }))
    return root


def test_candidates_are_the_elevation_priority_list_verbatim() -> None:
    # Compared as plain values: test_priority_regions.py loads its own copy of
    # the module, so the RegionCandidate classes may not be the same object.
    def _rows(candidates):
        return [(c.region_key, c.tile_index, c.bbox) for c in candidates]

    assert _rows(pb.selected_candidates()) == _rows(pb.build_priority_candidates())
    assert {c.region_key for c in pb.selected_candidates()} == {
        "nc", "brp", "skyline", "bwcaw", "yellowstone", "champlain", "pct"}


def test_regions_filter_selects_by_region_key() -> None:
    keys = {c.region_key for c in pb.selected_candidates({"nc", "yellowstone"})}
    assert keys == {"nc", "yellowstone"}


def test_unknown_region_key_is_an_error() -> None:
    with pytest.raises(ValueError, match="nowhere"):
        pb.selected_candidates({"nc", "nowhere"})


def test_wnc_corridor_is_always_covered() -> None:
    # The archive replaces corridor.pmtiles as the client's upstream, so even
    # a run narrowed to the PCT must still cover the corridor.
    bboxes = pb.area_bboxes(pb.selected_candidates({"pct"}))
    assert _WNC in bboxes


def test_region_geojson_is_one_closed_ring_per_bbox() -> None:
    geo = pb.region_geojson([(-1.0, -2.0, 3.0, 4.0), _WNC])
    assert geo["type"] == "MultiPolygon"
    assert len(geo["coordinates"]) == 2
    ring = geo["coordinates"][0][0]
    assert ring == [[-1.0, -2.0], [3.0, -2.0], [3.0, 4.0], [-1.0, 4.0], [-1.0, -2.0]]


def test_envelope_spans_every_bbox() -> None:
    assert pb.envelope([(-1.0, -2.0, 3.0, 4.0), (0.0, -5.0, 1.0, 1.0)]) == (-1.0, -5.0, 3.0, 4.0)


def test_prewarm_publishes_one_non_primary_archive(fake_pmtiles_bin, mirror_root) -> None:
    candidates = pb.selected_candidates({"nc", "yellowstone"})
    now = datetime(2026, 9, 24, 12, 0, tzinfo=timezone.utc)

    dest = pb.prewarm(
        root=mirror_root, candidates=candidates, build_date="20260923",
        upstream_base_url="https://build.example", pmtiles_bin=str(fake_pmtiles_bin), now=now,
    )

    assert dest == mirror_root / "basemap" / "protomaps" / pb.BUILD_ID / "priority.pmtiles"
    ran = json.loads(dest.read_text())
    assert ran["source"] == "https://build.example/20260923.pmtiles"
    assert "--bbox" not in ran["opts"]
    assert ran["region"] == pb.region_geojson(pb.area_bboxes(candidates))

    state = json.loads((mirror_root / "MIRROR_STATE.json").read_text())
    entry = state["basemap"]["covered_regions"]["priority-regions"]
    assert entry["path"] == f"basemap/protomaps/{pb.BUILD_ID}/priority.pmtiles"
    assert entry["bbox"] == list(pb.envelope(pb.area_bboxes(candidates)))
    assert entry["extracted_at"] == "2026-09-24T12:00:00Z"
    # Non-primary: the corridor stays what basemap_health() reports.
    assert state["basemap"]["build_id"] == "20250101-wnc"
    assert "wnc-corridor" in state["basemap"]["covered_regions"]
    assert state["geofabrik"] == {"pinned_date": "2026-09-18"}


def test_prewarm_is_a_no_op_within_ttl(fake_pmtiles_bin, mirror_root) -> None:
    candidates = pb.selected_candidates({"yellowstone"})
    kwargs = dict(build_date="20260923", pmtiles_bin=str(fake_pmtiles_bin))
    first = datetime(2026, 9, 24, tzinfo=timezone.utc)
    pb.prewarm(root=mirror_root, candidates=candidates, now=first, **kwargs)

    again = pb.prewarm(root=mirror_root, candidates=candidates,
                       now=datetime(2026, 9, 25, tzinfo=timezone.utc), **kwargs)
    assert again is None

    forced = pb.prewarm(root=mirror_root, candidates=candidates, force=True,
                        now=datetime(2026, 9, 25, tzinfo=timezone.utc), **kwargs)
    assert forced is not None


def test_dry_run_makes_no_network_call_and_names_the_client_url(capsys, monkeypatch) -> None:
    def _no_network(*_a, **_k):
        raise AssertionError("dry run reached the network")

    monkeypatch.setattr(pb.pe, "acquire", _no_network)
    monkeypatch.setattr(pb.pe, "find_latest_build_date", _no_network)
    assert pb.main(["--dry-run"]) == 0
    out = capsys.readouterr().out
    assert "wnc-corridor" in out and "pct" in out
    assert f"PLOTLINES_TILES_UPSTREAM={pb.published_url()}" in out
