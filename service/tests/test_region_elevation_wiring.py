"""Issue #148 — region builds acquire elevation (FR85/FR87, ARCH §12.1 Phase 1)
and enrich their graph with it (FR89), absent rather than flat when no source
resolves (FR88 as amended by #473, D68).

The direct provider is driven end to end through a real `OpenTopographyClient`
— its call ledger, its URL shaping, the resolver's write-back into the local
cache — with only the HTTP opener stubbed to serve a real GeoTIFF, so nothing
here reaches the network and the free-tier ledger is a `tmp_path` file.
"""

from __future__ import annotations

import io
from contextlib import contextmanager
from pathlib import Path

import networkx as nx
import numpy as np
import pytest
import rasterio
from fastapi.testclient import TestClient
from rasterio.transform import from_origin

from plotlines_core.cache_layout import CacheLayout
from plotlines_core.elevation.keys import (
    FREE_TIER_DAILY_CALL_CEILING,
    LEDGER_FILENAME,
    CallLedger,
    EnterpriseKeyRequired,
    KeyTier,
    OpenTopographyClient,
    OpenTopographyKey,
)
from plotlines_core.graph.loader import LoadedGraph
from plotlines_service import app as app_module
from plotlines_service.app import (
    ELEVATION_NOT_CONFIGURED,
    ELEVATION_OPENTOPOGRAPHY_CONFIGURED,
    ELEVATION_QA_PROXY_CONFIGURED,
    ElevationWiring,
    Readiness,
    RegionState,
    create_app,
    resolve_elevation_wiring,
)

# A small bbox and a 2x2-pixel DEM that covers it: west half 1000 m, east
# half 1100 m, so an eastbound edge climbs and a westbound one descends.
_BBOX = (-105.0, 40.0, -104.98, 40.02)
_KEY_ENV = {"PLOTLINES_OPENTOPOGRAPHY_API_KEY": "secret-token"}


def _dem_bytes() -> bytes:
    data = np.array([[1000.0, 1100.0], [1000.0, 1100.0]], dtype="float32")
    buf = io.BytesIO()
    with rasterio.MemoryFile() as mem:
        with mem.open(driver="GTiff", height=2, width=2, count=1, dtype="float32",
                      crs="EPSG:4326", transform=from_origin(-105.0, 40.02, 0.01, 0.01),
                      nodata=-9999.0) as ds:
            ds.write(data, 1)
        buf.write(mem.read())
    return buf.getvalue()


class _DemOpener:
    """`urllib.request.build_opener()` stand-in serving one GeoTIFF body."""

    def __init__(self, body: bytes | None = None, error: Exception | None = None):
        self.body = _dem_bytes() if body is None else body
        self.error = error
        self.urls: list[str] = []

    @contextmanager
    def open(self, url, timeout=None):  # noqa: A003 — mirrors urllib's name
        self.urls.append(url)
        if self.error is not None:
            raise self.error
        yield io.BytesIO(self.body)


def _client(tmp_path: Path, opener: _DemOpener) -> OpenTopographyClient:
    key = OpenTopographyKey(token="secret-token", tier=KeyTier.FREE_NON_ACADEMIC)
    ledger = CallLedger(tmp_path / LEDGER_FILENAME,
                        ceiling=key.effective_terms.daily_call_ceiling)
    return OpenTopographyClient(key, ledger, opener=opener)


def _wiring(client: OpenTopographyClient) -> ElevationWiring:
    return ElevationWiring("opentopography", client.as_fetcher(),
                           ELEVATION_OPENTOPOGRAPHY_CONFIGURED, client=client)


def _graph() -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.add_node(1, y=40.01, x=-104.995)   # west pixel, 1000 m
    g.add_node(2, y=40.01, x=-104.985)   # east pixel, 1100 m
    g.add_edge(1, 2, length=850.0, highway="residential")
    g.add_edge(2, 1, length=850.0, highway="residential")
    return g


def _patch_graph(monkeypatch) -> list[LoadedGraph]:
    """Settle the graph phase instantly on `_graph()`, keeping each loaded
    graph so a test can check the one routing saw was never mutated."""
    loaded: list[LoadedGraph] = []
    monkeypatch.setattr(app_module.region_lib, "ensure_graph",
                        lambda region, cache_dir: region.graph_path(cache_dir))

    def load(path):
        lg = LoadedGraph(graph=_graph(), source=Path(path), load_seconds=0.0)
        loaded.append(lg)
        return lg

    monkeypatch.setattr(app_module, "load_graphml", load)
    return loaded


def _build(region: RegionState, tmp_path: Path, wiring: ElevationWiring | None) -> None:
    region.build(tmp_path, tmp_path / "home.pmtiles", elevation_wiring=wiring)


# ── the process-wide choice ────────────────────────────────────────────────


def test_no_key_is_cache_only_and_says_so(tmp_path):
    wiring = resolve_elevation_wiring(tmp_path, None, env={})
    assert wiring.source == "local_cache"
    assert wiring.fetch is None
    assert wiring.capability == ELEVATION_NOT_CONFIGURED
    assert "OpenTopography key" in wiring.capability["reason"]


def test_a_key_wires_the_direct_provider_with_its_ledger_at_the_cache_root(tmp_path):
    wiring = resolve_elevation_wiring(tmp_path, None, env=_KEY_ENV)
    assert wiring.source == "opentopography"
    assert wiring.fetch is not None
    assert wiring.capability == ELEVATION_OPENTOPOGRAPHY_CONFIGURED
    assert wiring.client.ledger.path == tmp_path / LEDGER_FILENAME
    assert wiring.client.remaining_calls == FREE_TIER_DAILY_CALL_CEILING


def test_the_qa_proxy_flag_wins_over_a_key(tmp_path):
    wiring = resolve_elevation_wiring(tmp_path, "http://pi.invalid/dem", env=_KEY_ENV)
    assert wiring.source == "qa_proxy"
    assert wiring.fetch is None
    assert wiring.capability == ELEVATION_QA_PROXY_CONFIGURED


def test_an_unrecognised_tier_is_refused_not_defaulted_to_free(tmp_path, caplog):
    env = {**_KEY_ENV, "PLOTLINES_OPENTOPOGRAPHY_KEY_TIER": "platinum"}
    wiring = resolve_elevation_wiring(tmp_path, None, env=env)
    assert wiring.source == "local_cache"
    assert wiring.fetch is None
    assert wiring.capability["ready"] is False
    assert "isn't valid" in wiring.capability["reason"]
    assert "secret-token" not in caplog.text


def test_a_commercial_refusal_turns_downloads_off_without_raising(tmp_path, monkeypatch):
    def refuse(*_a, **_kw):
        raise EnterpriseKeyRequired("free key, commercial posture")

    monkeypatch.setattr(app_module, "client_from_env", refuse)
    wiring = resolve_elevation_wiring(tmp_path, None, env=_KEY_ENV)
    assert wiring.source == "local_cache"
    assert "tier doesn't permit" in wiring.capability["reason"]


def test_health_reports_the_source_and_an_empty_regions_map(tmp_path):
    client = TestClient(create_app(tmp_path, elevation_env=_KEY_ENV))
    caps = client.get("/health").json()["capabilities"]
    assert caps["elevation"] == {**ELEVATION_OPENTOPOGRAPHY_CONFIGURED, "regions": {}}


def test_create_app_reads_the_key_from_the_process_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("PLOTLINES_OPENTOPOGRAPHY_API_KEY", "secret-token")
    client = TestClient(create_app(tmp_path))
    assert client.get("/health").json()["capabilities"]["elevation"]["ready"] is True


# ── one region build ───────────────────────────────────────────────────────


def test_a_region_fetches_once_enriches_its_graph_and_reports_ready(tmp_path, monkeypatch):
    loaded = _patch_graph(monkeypatch)
    opener = _DemOpener()
    client = _client(tmp_path, opener)
    region = RegionState("k", _BBOX, "bike")

    _build(region, tmp_path, _wiring(client))

    assert region.graph_state.ready
    assert region.elevation_capability() == {"ready": True}
    assert len(opener.urls) == 1
    assert "demtype=GEDTM30" in opener.urls[0]
    assert client.remaining_calls == FREE_TIER_DAILY_CALL_CEILING - 1
    # the resolver wrote the DEM back into the bbox-scoped cache (FR94)
    assert CacheLayout(tmp_path).elevation_dir.joinpath(
        next(p.name for p in CacheLayout(tmp_path).elevation_dir.glob("*.tif"))).is_file()

    g = region.graph.graph
    assert g.nodes[1]["elevation"] == pytest.approx(1000.0)
    assert g.nodes[2]["elevation"] == pytest.approx(1100.0)
    assert g.edges[1, 2, 0]["elev_gain"] == pytest.approx(100.0)
    assert g.edges[2, 1, 0]["elev_gain"] == 0.0
    # FR2's peaks weight reads grade_abs — present now on a runtime graph
    assert g.edges[1, 2, 0]["grade_abs"] == pytest.approx(round(100.0 / 850.0, 3))
    assert region.sampler is not None

    # enriched on a copy and swapped in — the graph routing opened on first
    # was never annotated under a concurrent solve
    assert region.graph is not loaded[0]
    assert "elevation" not in loaded[0].graph.nodes[1]


def test_a_rebuild_of_the_same_bbox_is_a_cache_hit_with_no_second_call(tmp_path, monkeypatch):
    _patch_graph(monkeypatch)
    opener = _DemOpener()
    client = _client(tmp_path, opener)
    wiring = _wiring(client)

    _build(RegionState("k", _BBOX, "bike"), tmp_path, wiring)
    again = RegionState("k", _BBOX, "bike")
    _build(again, tmp_path, wiring)

    assert len(opener.urls) == 1  # 50 new *bboxes* a day, not 50 builds
    assert again.elevation_capability() == {"ready": True}


def test_with_no_key_and_nothing_cached_elevation_is_absent_not_flat(tmp_path, monkeypatch):
    _patch_graph(monkeypatch)
    region = RegionState("k", _BBOX, "bike")

    _build(region, tmp_path, None)  # a bare caller: cache-only

    assert region.graph_state.ready  # never blocks routing (FR121)
    cap = region.elevation_capability()
    assert cap["ready"] is False
    assert "progress" not in cap  # settled: the client stops waiting
    assert "isn't set up to download" in cap["reason"]
    assert region.sampler is None
    assert "elevation" not in region.graph.graph.nodes[1]
    assert "grade_abs" not in region.graph.graph.edges[1, 2, 0]


def test_with_no_key_a_cached_bbox_still_gets_elevation(tmp_path, monkeypatch):
    """Offline, or with no key: a DEM already in the cache (fetched earlier,
    or the shipped FR90 home-region raster) is read with no network."""
    _patch_graph(monkeypatch)
    _build(RegionState("warm", _BBOX, "bike"), tmp_path, _wiring(_client(tmp_path, _DemOpener())))

    region = RegionState("k", _BBOX, "bike")
    _build(region, tmp_path, resolve_elevation_wiring(tmp_path, None, env={}))
    assert region.elevation_capability() == {"ready": True}
    assert region.graph.graph.nodes[2]["elevation"] == pytest.approx(1100.0)


def test_a_failed_download_is_absent_with_a_connection_sentence(tmp_path, monkeypatch):
    _patch_graph(monkeypatch)
    opener = _DemOpener(error=OSError("connection refused"))
    region = RegionState("k", _BBOX, "bike")

    _build(region, tmp_path, _wiring(_client(tmp_path, opener)))

    cap = region.elevation_capability()
    assert cap["ready"] is False
    assert "Couldn't download terrain data" in cap["reason"]
    assert "refused" not in cap["reason"]  # the raw error stays in the log
    assert region.sampler is None


def test_a_spent_free_tier_names_the_allowance_and_makes_no_call(tmp_path, monkeypatch):
    _patch_graph(monkeypatch)
    opener = _DemOpener()
    client = _client(tmp_path, opener)
    for _ in range(FREE_TIER_DAILY_CALL_CEILING):
        client.ledger.record()
    region = RegionState("k", _BBOX, "bike")

    _build(region, tmp_path, _wiring(client))

    assert opener.urls == []  # refused before the wire (FR87 clause 1)
    reason = region.elevation_capability()["reason"]
    assert f"({FREE_TIER_DAILY_CALL_CEILING} new areas per 24 hours)" in reason
    assert region.graph_state.ready


def test_an_unreadable_download_is_absent_and_not_left_in_the_cache(tmp_path, monkeypatch):
    """A 200 carrying an error body is saved as `.tif` by the fetch. It must
    not stay behind as a permanent local-cache 'hit' no rebuild can get past."""
    _patch_graph(monkeypatch)
    bad = _DemOpener(body=b"Error: invalid bbox")
    region = RegionState("k", _BBOX, "bike")
    _build(region, tmp_path, _wiring(_client(tmp_path, bad)))
    assert "couldn't be read" in region.elevation_capability()["reason"]
    assert region.sampler is None
    assert "elevation" not in region.graph.graph.nodes[1]
    assert list(CacheLayout(tmp_path).elevation_dir.glob("*.tif")) == []

    good = _DemOpener()
    again = RegionState("k", _BBOX, "bike")
    _build(again, tmp_path, _wiring(_client(tmp_path, good)))
    assert len(good.urls) == 1
    assert again.elevation_capability() == {"ready": True}


def test_a_failed_graph_build_says_elevation_waits_on_it(tmp_path, monkeypatch):
    def boom(region, cache_dir):
        raise RuntimeError("no graph")

    monkeypatch.setattr(app_module.region_lib, "ensure_graph", boom)
    region = RegionState("k", _BBOX, "bike")
    opener = _DemOpener()
    _build(region, tmp_path, _wiring(_client(tmp_path, opener)))

    assert "routing data first" in region.elevation_capability()["reason"]
    assert opener.urls == []  # no graph, no point spending a call


def test_waiting_and_loading_carry_progress_so_the_client_keeps_waiting(tmp_path):
    region = RegionState("k", _BBOX, "bike")
    pending = region.elevation_capability()
    assert pending["ready"] is False and "progress" in pending
    region.elevation_state.start("fetching terrain data for this area")
    loading = region.elevation_capability()
    assert loading["progress"] == 0.0
    assert "eta_s" not in loading  # no honest estimate exists (#397)


def test_readiness_reports_each_region_under_elevation_regions(tmp_path, monkeypatch):
    _patch_graph(monkeypatch)
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    region = RegionState("k", _BBOX, "bike")
    _build(region, tmp_path, None)
    state.regions["k"] = region

    caps = state.elevation_capabilities()
    assert caps["ready"] is False  # bare Readiness: cache-only, no key
    assert caps["regions"]["k"]["ready"] is False
