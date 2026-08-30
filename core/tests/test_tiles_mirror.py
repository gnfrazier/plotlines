"""Unit tests for `plotlines_core.tiles.mirror` (FR92/FR95; story M11, issue
#139) — the Plotlines-controlled Protomaps mirror and the "mirror, not
hotlink" upstream policy the bbox extractor enforces.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from plotlines_core.tiles.extract import extract_bbox
from plotlines_core.tiles.mirror import (
    MIRROR_ARCHIVE_URL,
    MIRROR_HOST,
    HotlinkRefused,
    UpstreamKind,
    basemap_attribution,
    classify_upstream,
    resolve_upstream,
)
from tiles_helpers import build_archive


def test_a_local_path_classifies_as_local():
    assert classify_upstream(Path("/tmp/home_region.pmtiles")) is UpstreamKind.LOCAL


def test_a_bare_string_path_classifies_as_local():
    assert classify_upstream("./data/home_region.pmtiles") is UpstreamKind.LOCAL


def test_the_plotlines_mirror_classifies_as_mirror():
    assert classify_upstream(MIRROR_ARCHIVE_URL) is UpstreamKind.MIRROR
    assert MIRROR_HOST in MIRROR_ARCHIVE_URL


def test_the_mirror_host_is_matched_case_insensitively():
    assert classify_upstream(f"https://{MIRROR_HOST.upper()}/x.pmtiles") is UpstreamKind.MIRROR


def test_a_third_party_tile_host_classifies_as_foreign():
    assert classify_upstream("https://build.protomaps.com/planet.pmtiles") is UpstreamKind.FOREIGN


def test_resolve_passes_a_local_path_through_unchanged():
    p = Path("/tmp/x.pmtiles")
    assert resolve_upstream(p) == p


def test_resolve_passes_the_mirror_through_unchanged():
    assert resolve_upstream(MIRROR_ARCHIVE_URL) == MIRROR_ARCHIVE_URL


def test_resolve_refuses_a_foreign_host():
    with pytest.raises(HotlinkRefused):
        resolve_upstream("https://tile.openstreetmap.org/planet.pmtiles")


def test_resolve_allows_a_foreign_host_only_with_the_dev_opt_in():
    url = "https://tile.openstreetmap.org/planet.pmtiles"
    assert resolve_upstream(url, allow_unmirrored=True) == url


def test_extract_bbox_refuses_a_foreign_upstream_before_any_fetch(tmp_path):
    with pytest.raises(HotlinkRefused):
        extract_bbox("https://build.protomaps.com/planet.pmtiles",
                     (-1.0, -1.0, 1.0, 1.0), tmp_path / "out.pmtiles")


def test_extract_bbox_still_reads_a_local_archive(tmp_path):
    src = build_archive(tmp_path / "world.pmtiles", {(0, 0, 0): b"0/0/0"})
    out = extract_bbox(src, (-180.0, -85.0, 180.0, 85.0), tmp_path / "out.pmtiles",
                       min_zoom=0, max_zoom=0)
    assert out.exists()


def test_basemap_attribution_is_the_odbl_openstreetmap_line():
    line = basemap_attribution()
    assert line["licence"] == "ODbL-1.0"
    assert line["attribution"] == "© OpenStreetMap contributors"
    assert line["terms_url"].startswith("https://www.openstreetmap.org/")
