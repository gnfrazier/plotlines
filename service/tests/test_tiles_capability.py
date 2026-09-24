"""Unit tests for `capabilities.tiles.upstream` (issue #454) and the
composite `capabilities.tiles.archive` identity (issue #455). Landed
together per epic #458's run order: "#455's recommended design (a composite
identity) is a field in the block #454 adds. Two PRs would mean two shape
changes to one `/health` block and two client parses of it; one PR means
one." — so one shape change to `tiles`, tested in one file.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from plotlines_core.tiles.archive import Archive
from plotlines_core.cache_layout import CacheLayout
from plotlines_service import app as app_mod
from plotlines_service.app import create_app
from plotlines_service.tiles_paths import default_home_region_archive
from tiles_helpers import build_archive

pytestmark = pytest.mark.skipif(
    not default_home_region_archive().exists(),
    reason="committed home-region archive not present in this checkout",
)


# ── #454: capabilities.tiles.upstream ────────────────────────────────────


def test_upstream_unset_reports_local_home_archive(tmp_path: Path) -> None:
    client = TestClient(create_app(tmp_path))
    upstream = client.get("/health").json()["capabilities"]["tiles"]["upstream"]
    assert upstream == {
        "kind": "local",
        "source": str(default_home_region_archive()),
        "refused": False,
        "reason": None,
        "bounds": None,
    }


def test_upstream_mirror_host_reported_not_refused(tmp_path: Path) -> None:
    url = "http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles"
    client = TestClient(create_app(tmp_path, tiles_upstream=url))
    upstream = client.get("/health").json()["capabilities"]["tiles"]["upstream"]
    assert upstream == {"kind": "mirror", "source": url, "refused": False, "reason": None,
                        "bounds": None}


def test_foreign_upstream_is_refused_before_any_region_is_built(
    tmp_path: Path, monkeypatch,
) -> None:
    # FR92/FR95 (HotlinkRefused) fires here purely from string classification
    # — no `/regions` call, no network — so a misconfigured upstream is
    # visible on `/health` from the very first poll (#454's acceptance, and
    # #453's bullet 5 this closes out). The monkeypatches pin the "no
    # network" half: `classify_upstream`/`resolve_upstream` are string
    # inspection (D41/D57), and this fails loudly if a caller ever grows a
    # socket or urlopen underneath them.
    def _no_network(*_args, **_kwargs):
        raise AssertionError("classifying a tile upstream must not touch the network")
    monkeypatch.setattr("urllib.request.urlopen", _no_network)
    monkeypatch.setattr("socket.create_connection", _no_network)

    url = "https://tile.openstreetmap.org/x.pmtiles"
    client = TestClient(create_app(tmp_path, tiles_upstream=url))
    tiles = client.get("/health").json()["capabilities"]["tiles"]
    # #155's byte-identical guarantee holds even for a refused upstream.
    assert tiles["ready"] is True
    assert isinstance(tiles["archive"], str) and tiles["archive"]
    upstream = tiles["upstream"]
    assert upstream["kind"] == "foreign"
    assert upstream["refused"] is True
    assert "mirror" in upstream["reason"]
    assert "FR92" in upstream["reason"] and "FR95" in upstream["reason"]


def test_allow_unmirrored_tiles_suppresses_the_refusal(tmp_path: Path) -> None:
    url = "https://example.invalid/x.pmtiles"
    client = TestClient(
        create_app(tmp_path, tiles_upstream=url, allow_unmirrored_tiles=True))
    upstream = client.get("/health").json()["capabilities"]["tiles"]["upstream"]
    assert upstream == {"kind": "foreign", "source": url, "refused": False, "reason": None,
                        "bounds": None}


def test_tiles_ready_and_upstream_never_change_shape_when_a_region_fails(
    tmp_path: Path, monkeypatch,
) -> None:
    """`tiles.ready`/`tiles.upstream` are process-wide and decided at
    startup — a region build failing (of any kind) must never touch them."""
    monkeypatch.setattr(app_mod.region_lib, "ensure_graph",
                        lambda region, cache_dir: (_ for _ in ()).throw(RuntimeError("boom")))
    client = TestClient(create_app(tmp_path))
    client.post("/regions", json={"bbox": [-105.0, 40.0, -104.9, 40.1]})
    client.app.state.readiness._build_pool.shutdown(wait=True)
    tiles = client.get("/health").json()["capabilities"]["tiles"]
    assert tiles["ready"] is True
    assert tiles["upstream"]["kind"] == "local"


# ── #455: capabilities.tiles.archive is a composite identity ────────────


def test_archive_equals_home_identity_when_nothing_has_moved_off_the_default(
    tmp_path: Path,
) -> None:
    client = TestClient(create_app(tmp_path))
    home_identity = Archive(default_home_region_archive()).info().identity
    archive = client.get("/health").json()["capabilities"]["tiles"]["archive"]
    assert archive == home_identity


def test_two_upstreams_produce_different_archive_identities_same_value_identical(
    tmp_path: Path,
) -> None:
    url_a = "http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles"
    url_b = "http://tiles.plotlines.app/basemap/protomaps/20250201-wnc/corridor.pmtiles"
    a1 = TestClient(create_app(tmp_path / "a1", tiles_upstream=url_a))
    a2 = TestClient(create_app(tmp_path / "a2", tiles_upstream=url_a))
    b = TestClient(create_app(tmp_path / "b", tiles_upstream=url_b))
    id_a1 = a1.get("/health").json()["capabilities"]["tiles"]["archive"]
    id_a2 = a2.get("/health").json()["capabilities"]["tiles"]["archive"]
    id_b = b.get("/health").json()["capabilities"]["tiles"]["archive"]
    assert id_a1 == id_a2
    assert id_a1 != id_b


def test_a_regions_own_tile_archive_folds_into_and_moves_the_composite_identity(
    tmp_path: Path, monkeypatch,
) -> None:
    """The #155 poisoning shape, one archive removed (#455's summary):
    ensuring a region that gets its own on-demand tile archive must move
    `capabilities.tiles.archive`, and re-extracting that archive with
    different content (a fresh Protomaps pull, same path) must move it
    again — never silently serving the prior render from the same folder."""
    monkeypatch.setattr(app_mod.region_lib, "ensure_graph",
                        lambda region, cache_dir: tmp_path / "graph.graphml")
    monkeypatch.setattr(app_mod, "load_graphml", lambda path: object())

    client = TestClient(create_app(tmp_path))
    before = client.get("/health").json()["capabilities"]["tiles"]["archive"]

    bbox = (-105.30, 39.99, -105.25, 40.03)
    tiles_path = CacheLayout(tmp_path).tile_archive(bbox)
    tiles_path.parent.mkdir(parents=True, exist_ok=True)
    build_archive(tiles_path, {(3, 4, 4): b"region-tile-v1"})

    key = client.post("/regions", json={"bbox": list(bbox)}).json()["region"]
    client.app.state.readiness._build_pool.shutdown(wait=True)
    region = client.app.state.readiness.region(key)
    assert region is not None and region.tiles_archive is not None

    after_first = client.get("/health").json()["capabilities"]["tiles"]["archive"]
    assert after_first != before

    # Re-extract with different content, the same corridor.pmtiles path a
    # fresh `protomaps_extract.py` run would overwrite.
    tiles_path.unlink()
    build_archive(tiles_path, {(3, 4, 4): b"region-tile-v2-different-payload"})
    region.tiles_archive = None
    region.build(tmp_path, default_home_region_archive())

    after_reextract = client.get("/health").json()["capabilities"]["tiles"]["archive"]
    assert after_reextract not in (before, after_first)


def test_computing_the_identity_makes_no_ranged_get_against_the_upstream(
    tmp_path: Path, monkeypatch,
) -> None:
    """D41/D57: the upstream's contribution to the composite is its source
    *string*, never its content — computing `/health` must never range into
    a remote (or even local, unopened) upstream archive to answer it."""
    import urllib.request

    def refuse(*_args, **_kwargs):
        raise AssertionError("must not make a network request to compute /health")

    monkeypatch.setattr(urllib.request, "urlopen", refuse)
    url = "http://tiles.plotlines.app/basemap/protomaps/20250101-wnc/corridor.pmtiles"
    client = TestClient(create_app(tmp_path, tiles_upstream=url))
    body = client.get("/health").json()
    assert body["capabilities"]["tiles"]["archive"]
