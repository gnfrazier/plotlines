"""Unit tests for `GET /tiles/{z}/{x}/{y}` (ARCH §8.2, FR92-94; issue #154).

Before this, the client read basemap tiles as loose files straight off local
disk and the sidecar had no tile endpoint at all — FR92 ("the client talks
only to Plotlines' own tile service") was unimplemented. These exercise the
endpoint against the real committed home-region archive plus a synthetic
per-region cache, without touching the network.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_service.app import create_app
from plotlines_service.tiles_paths import default_home_region_archive
from tiles_helpers import build_archive

pytestmark = pytest.mark.skipif(
    not default_home_region_archive().exists(),
    reason="committed home-region archive not present in this checkout",
)


def test_invalid_zxy_is_422_before_any_archive_is_touched(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    resp = client.get("/tiles/-1/0/0")
    assert resp.status_code == 422


def test_zxy_outside_the_zoom_levels_span_is_422(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    # At z=2 the valid x/y span is 0..3.
    resp = client.get("/tiles/2/4/0")
    assert resp.status_code == 422


def test_a_tile_covered_by_the_home_archive_is_served(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    resp = client.get("/tiles/0/0/0")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/vnd.mapbox-vector-tile"
    assert resp.headers.get("content-encoding") == "gzip"
    assert len(resp.content) > 0


def test_a_buncombe_county_tile_is_served(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    # Buncombe County's centre at z=10 — a real tile in the committed archive.
    resp = client.get("/tiles/10/277/403")
    assert resp.status_code == 200
    assert len(resp.content) > 0


def test_an_uncovered_tile_is_an_honest_404_not_a_substitution(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    # Zoom 14 tile (0, 0) is the null island corner, nowhere near Buncombe
    # County — must not silently return *some* tile.
    resp = client.get("/tiles/14/0/0")
    assert resp.status_code == 404


def test_a_region_specific_cache_is_served_before_falling_back(tmp_path: Path, monkeypatch) -> None:
    """A tile only the region's own on-demand cache has (not the committed
    home archive) must come from that region, never 404 just because the
    home archive doesn't have it — and never from an unrelated region."""
    import osmnx as ox

    # Pre-seed a graph so the region settles to ready quickly without
    # network, and monkeypatch tile extraction to fail (isolating this test
    # to the *serving* path, not the extraction pipeline covered elsewhere).
    def _refuse_graph(*_a, **_k):
        raise RuntimeError("no network in this test")
    monkeypatch.setattr(ox, "graph_from_bbox", _refuse_graph)

    client = TestClient(create_app(tmp_path))
    bbox = [-1.0, -1.0, 1.0, 1.0]
    key = client.post("/regions", json={"bbox": bbox}).json()["region"]

    # Build the region's tile cache directly, bypassing the (network-bound,
    # graph-coupled) build thread — this test is about the /tiles lookup
    # order, not about region-build orchestration.
    from plotlines_service.app import RegionState
    from plotlines_core.tiles.archive import Archive

    region: RegionState = client.app.state.readiness.region(key)
    synthetic = build_archive(tmp_path / "synthetic.pmtiles", {(3, 4, 4): b"only-this-region-has-me"})
    region.tiles_archive = Archive(synthetic)

    resp = client.get("/tiles/3/4/4")
    assert resp.status_code == 200
    assert resp.content == b"only-this-region-has-me"


def test_region_tile_cache_lives_in_the_bbox_scoped_cache_layout(tmp_path: Path, monkeypatch) -> None:
    """FR94 (issue #152): a region's on-demand tile cache is written to and
    read back from `CacheLayout(cache_dir).tile_archive(bbox)` — the separate,
    trip-bbox-scoped tile cache, not `regions/<key>/`. Two regions that drew
    the same box (differing only by network type) share the one archive."""
    from plotlines_service import app as app_mod
    from plotlines_service.app import RegionState
    from plotlines_core.cache_layout import CacheLayout

    bbox = (-1.0, -1.0, 1.0, 1.0)
    expected = CacheLayout(tmp_path).tile_archive(bbox)

    # Stub the graph half (network-bound) so build() reaches the tile half.
    monkeypatch.setattr(app_mod.region_lib, "ensure_graph",
                        lambda region, cache_dir: tmp_path / "graph.graphml")
    monkeypatch.setattr(app_mod, "load_graphml", lambda path: object())

    seen: list[Path] = []

    def fake_extract(upstream, box, out_path, *, allow_unmirrored=False):
        seen.append(out_path)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        build_archive(out_path, {(3, 4, 4): b"region-tile"})
        return out_path

    monkeypatch.setattr(app_mod, "extract_bbox", fake_extract)

    region = RegionState("k-bike", bbox, "bike")
    region.build(tmp_path, tiles_upstream="unused", allow_unmirrored=False)

    assert seen == [expected]
    assert expected.is_file()
    assert expected.parent == CacheLayout(tmp_path).tiles_dir
    assert region.tiles_archive is not None
    assert region.tiles_archive.tile(3, 4, 4) == b"region-tile"

    # A second region for the same bbox, different network type: the archive
    # already exists, so no re-extraction — one tile cache per trip bbox.
    seen.clear()
    region2 = RegionState("k-foot", bbox, "walk")
    region2.build(tmp_path, tiles_upstream="unused", allow_unmirrored=False)
    assert seen == []
    assert region2.tiles_archive is not None
