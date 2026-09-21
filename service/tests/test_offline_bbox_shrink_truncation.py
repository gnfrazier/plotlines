"""Issue #432 / ARCH D62 — offline bbox-shrink graph truncation.

§6.7a of `docs/Plotlines_OSM_Acquisition_Review.md` decided the target
design: when a bbox *shrink* cannot build fresh (the mirror and every
Overpass endpoint are unreachable) but a wider graph for the same
`network_type` already built successfully in this session, truncate that
held graph to the new bbox and serve it as a **provisional** capability —
usable now, honestly labelled, replaced by a real rebuild once reconnected.
A nudge or grow past the held graph's coverage is unaffected: there is
nothing to truncate *from* that covers the newly-uncovered area, so it keeps
today's `failed:<reason>` report.

`core/tests/test_graph_regions.py` covers the pure truncation/shrink-
detection primitives (`bbox_contains`, `bbox_is_shrink`,
`truncate_graph_to_bbox`, `build_provisional_graph_from_shrink`). This file
covers the `Readiness`/`RegionState` wiring: finding the held region,
setting the provisional capability, and the reconnect-rebuilds-for-real
path — end to end through `POST /regions` and `GET /health` where it
matters, and directly against `Readiness` where the HTTP layer would only
add noise.
"""

from __future__ import annotations

import time
from concurrent.futures import ThreadPoolExecutor

import networkx as nx
import osmnx as ox
import pytest
from fastapi.testclient import TestClient

from plotlines_core.graph import regions as region_lib
from plotlines_service.app import Readiness, create_app

_WIDE_BBOX = (-105.30, 39.99, -105.10, 40.01)
_SHRUNK_BBOX = (-105.30, 39.99, -105.27, 40.01)  # west third of _WIDE_BBOX
_GROW_BBOX = (-105.31, 39.98, -105.09, 40.02)  # not a subset of _WIDE_BBOX
_OTHER_NETWORK_BBOX = _SHRUNK_BBOX  # same box, different network_type below


def _line_graph(coords: list[tuple[float, float]]) -> nx.MultiDiGraph:
    g = nx.MultiDiGraph()
    g.graph["crs"] = "epsg:4326"
    for i, (x, y) in enumerate(coords, start=1):
        g.add_node(i, x=x, y=y, street_count=2)
    for i in range(1, len(coords)):
        g.add_edge(i, i + 1, length=100.0, osmid=i)
        g.add_edge(i + 1, i, length=100.0, osmid=i)
    return g


def _held_wide_graph() -> nx.MultiDiGraph:
    """Five nodes spanning the full width of `_WIDE_BBOX`; only the first
    three fall inside `_SHRUNK_BBOX`."""
    return _line_graph([
        (-105.30, 40.00), (-105.29, 40.00), (-105.28, 40.00),
        (-105.20, 40.00), (-105.10, 40.00),
    ])


def _fake_ensure_graph_offline_except_for(*ready_bboxes: tuple[float, float, float, float]):
    """A `region_lib.ensure_graph` stand-in: builds+caches a real graph (as a
    cache-hit `ensure_graph` would report it) for any bbox in `ready_bboxes`,
    and raises `OverpassUnavailable` — "the mirror and every Overpass
    endpoint are unreachable" — for anything else. Mirrors the real
    function's contract (writes `graph.graph_path`, records `source.json`,
    returns the path) without touching the network."""
    def fake(region, cache_dir, **_kwargs):
        if region.bbox in ready_bboxes:
            path = region.graph_path(cache_dir)
            if not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True)
                ox.io.save_graphml(_held_wide_graph(), path)
                region_lib._write_graph_source(region, cache_dir, {"transport": "overpass"})
            return path
        raise region_lib.OverpassUnavailable(
            "Couldn't reach the map-data service to prepare routing for this "
            "area. This is almost always temporary — check your connection "
            "and try again in a few minutes."
        )
    return fake


# ── Readiness.find_held_supergraph — the pure lookup ────────────────────────


def _ready_region(readiness: Readiness, bbox, network_type="bike") -> str:
    key = readiness.ensure_region(bbox, network_type)
    readiness._build_pool.shutdown(wait=True)
    readiness._build_pool = ThreadPoolExecutor(max_workers=1)
    return key


def test_find_held_supergraph_finds_a_ready_wider_region(tmp_path, monkeypatch):
    monkeypatch.setattr(region_lib, "ensure_graph",
                        _fake_ensure_graph_offline_except_for(_WIDE_BBOX))
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    wide_key = _ready_region(state, _WIDE_BBOX)

    held = state.find_held_supergraph(_SHRUNK_BBOX, "bike")

    assert held is not None
    assert held.key == wide_key


def test_find_held_supergraph_ignores_a_different_network_type(tmp_path, monkeypatch):
    monkeypatch.setattr(region_lib, "ensure_graph",
                        _fake_ensure_graph_offline_except_for(_WIDE_BBOX))
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    _ready_region(state, _WIDE_BBOX, "bike")

    assert state.find_held_supergraph(_SHRUNK_BBOX, "walk") is None


def test_find_held_supergraph_ignores_an_identical_bbox(tmp_path, monkeypatch):
    """A rebuild request, not a shrink — never served by truncating a graph
    to itself."""
    monkeypatch.setattr(region_lib, "ensure_graph",
                        _fake_ensure_graph_offline_except_for(_WIDE_BBOX))
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    _ready_region(state, _WIDE_BBOX)

    assert state.find_held_supergraph(_WIDE_BBOX, "bike") is None


def test_find_held_supergraph_returns_none_when_nothing_is_wider(tmp_path, monkeypatch):
    monkeypatch.setattr(region_lib, "ensure_graph",
                        _fake_ensure_graph_offline_except_for(_SHRUNK_BBOX))
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    _ready_region(state, _SHRUNK_BBOX)

    assert state.find_held_supergraph(_WIDE_BBOX, "bike") is None


def test_find_held_supergraph_prefers_the_tightest_superset(tmp_path, monkeypatch):
    medium_bbox = (-105.30, 39.99, -105.20, 40.01)  # between shrunk and wide
    monkeypatch.setattr(
        region_lib, "ensure_graph",
        _fake_ensure_graph_offline_except_for(_WIDE_BBOX, medium_bbox))
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    _ready_region(state, _WIDE_BBOX)
    medium_key = _ready_region(state, medium_bbox)

    held = state.find_held_supergraph(_SHRUNK_BBOX, "bike")

    assert held is not None
    assert held.key == medium_key


def test_find_held_supergraph_ignores_a_region_still_building(tmp_path, monkeypatch):
    def never_returns(*_a, **_k):
        raise region_lib.OverpassUnavailable("still trying")
    monkeypatch.setattr(region_lib, "ensure_graph", never_returns)
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    state.ensure_region(_WIDE_BBOX, "bike")  # settles failed, never ready
    state._build_pool.shutdown(wait=True)

    assert state.find_held_supergraph(_SHRUNK_BBOX, "bike") is None


# ── RegionState.build — the offline shrink fallback itself ─────────────────


def test_a_shrink_offline_is_served_provisionally_from_the_held_graph(tmp_path, monkeypatch):
    monkeypatch.setattr(region_lib, "ensure_graph",
                        _fake_ensure_graph_offline_except_for(_WIDE_BBOX))
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    _ready_region(state, _WIDE_BBOX)

    shrunk_key = state.ensure_region(_SHRUNK_BBOX, "bike")
    state._build_pool.shutdown(wait=True)

    shrunk = state.regions[shrunk_key]
    assert shrunk.graph_state.status == "provisional"
    # Provisional is usable right now — never confused with a failure.
    assert shrunk.routing_ready is True
    assert shrunk.graph is not None
    assert shrunk.graph.node_count == 3
    cap = shrunk.routing_capability()
    assert cap["ready"] is True
    assert cap["provisional"] is True
    assert "reconnected" in cap["reason"]


def test_a_shrink_offline_clears_the_requeue_cooldown_ledger(tmp_path, monkeypatch):
    """Issue #432 — a provisional build is a success, not a failure: the next
    `ensure_region` for this bbox must not be throttled by #247's post-
    *failure* cooldown."""
    monkeypatch.setattr(region_lib, "ensure_graph",
                        _fake_ensure_graph_offline_except_for(_WIDE_BBOX))
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    _ready_region(state, _WIDE_BBOX)
    shrunk_key = state.ensure_region(_SHRUNK_BBOX, "bike")
    state._build_pool.shutdown(wait=True)

    shrunk = state.regions[shrunk_key]
    assert shrunk.failed_at is None
    assert shrunk.automatic_requeues == 0


def test_reconnection_replaces_the_provisional_graph_with_a_real_rebuild(tmp_path, monkeypatch):
    """§6.7a: 'on reconnection, the region-build path already shipped ...
    runs for the new extent ... no special-cased resume.' Simulated here by
    the same bbox becoming buildable again on the *next* `POST /regions`."""
    fake = _fake_ensure_graph_offline_except_for(_WIDE_BBOX)
    monkeypatch.setattr(region_lib, "ensure_graph", fake)
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    _ready_region(state, _WIDE_BBOX)
    shrunk_key = state.ensure_region(_SHRUNK_BBOX, "bike")
    state._build_pool.shutdown(wait=True)
    assert state.regions[shrunk_key].graph_state.status == "provisional"

    # Reconnected: the shrunk bbox can now build for real too.
    monkeypatch.setattr(
        region_lib, "ensure_graph",
        _fake_ensure_graph_offline_except_for(_WIDE_BBOX, _SHRUNK_BBOX))
    state._build_pool = ThreadPoolExecutor(max_workers=1)
    got_key = state.ensure_region(_SHRUNK_BBOX, "bike")
    state._build_pool.shutdown(wait=True)

    assert got_key == shrunk_key
    shrunk = state.regions[shrunk_key]
    assert shrunk.graph_state.status == "ready"
    cap = shrunk.routing_capability()
    assert cap["ready"] is True
    assert "provisional" not in cap  # no lingering flag
    # This fixture's `tiles_upstream` (`tmp_path / "home.pmtiles"`) was
    # never a real archive, so tile extraction has always failed here —
    # issue #456 just made that visible on `routing_capability()` rather
    # than only on `/regions/{key}/diagnostics` (issue #454's own point).
    # This test is about the graph/provisional state, not tiles.
    assert "tiles_error" in cap
    assert shrunk.build_attempts == 2


def test_a_nudge_offline_is_unaffected_and_stays_an_honest_failure(tmp_path, monkeypatch):
    """Review §6.7a: 'no change is owed here' — nothing held covers the
    newly-uncovered area, so this is exactly today's shipped behaviour."""
    monkeypatch.setattr(region_lib, "ensure_graph",
                        _fake_ensure_graph_offline_except_for(_WIDE_BBOX))
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    _ready_region(state, _WIDE_BBOX)

    grow_key = state.ensure_region(_GROW_BBOX, "bike")
    state._build_pool.shutdown(wait=True)

    grow = state.regions[grow_key]
    assert grow.graph_state.status == "failed"
    assert grow.routing_ready is False
    cap = grow.routing_capability()
    assert cap["ready"] is False
    assert "provisional" not in cap
    assert cap["reason"].startswith("failed:")


def test_no_held_graph_at_all_is_an_honest_failure(tmp_path, monkeypatch):
    monkeypatch.setattr(region_lib, "ensure_graph",
                        _fake_ensure_graph_offline_except_for())
    state = Readiness(tmp_path, tmp_path / "home.pmtiles")

    key = state.ensure_region(_SHRUNK_BBOX, "bike")
    state._build_pool.shutdown(wait=True)

    assert state.regions[key].graph_state.status == "failed"


# ── End to end over HTTP — /health reports the provisional flag ────────────


def test_health_reports_provisional_distinctly_from_ready(tmp_path, monkeypatch):
    monkeypatch.setattr(region_lib, "ensure_graph",
                        _fake_ensure_graph_offline_except_for(_WIDE_BBOX))
    client = TestClient(create_app(tmp_path))
    client.post("/regions", json={"bbox": list(_WIDE_BBOX)})

    def _wait_ready(bbox) -> str:
        key = client.post("/regions", json={"bbox": list(bbox)}).json()["region"]
        deadline = time.perf_counter() + 10
        while time.perf_counter() < deadline:
            entry = (client.get("/health").json()["capabilities"]["routing"]
                     ["regions"].get(key, {}))
            if entry.get("ready") or str(entry.get("reason", "")).startswith("failed:"):
                return key
            time.sleep(0.02)
        raise AssertionError("region never settled")

    _wait_ready(_WIDE_BBOX)
    shrunk_key = _wait_ready(_SHRUNK_BBOX)

    entry = client.get("/health").json()["capabilities"]["routing"]["regions"][shrunk_key]
    assert entry == {
        "ready": True,
        "provisional": True,
        "reason": entry["reason"],
    }
    assert "reconnected" in entry["reason"]


def test_routing_still_works_against_a_provisional_region(tmp_path, monkeypatch):
    """A provisional graph is usable right now — FR121's whole point is that
    an honest caveat is never the same thing as a block."""
    monkeypatch.setattr(region_lib, "ensure_graph",
                        _fake_ensure_graph_offline_except_for(_WIDE_BBOX))
    client = TestClient(create_app(tmp_path))
    client.post("/regions", json={"bbox": list(_WIDE_BBOX)})

    def _wait_settled(bbox) -> str:
        key = client.post("/regions", json={"bbox": list(bbox)}).json()["region"]
        deadline = time.perf_counter() + 10
        while time.perf_counter() < deadline:
            entry = (client.get("/health").json()["capabilities"]["routing"]
                     ["regions"].get(key, {}))
            if entry.get("ready") or str(entry.get("reason", "")).startswith("failed:"):
                return key
            time.sleep(0.02)
        raise AssertionError("region never settled")

    _wait_settled(_WIDE_BBOX)
    shrunk_key = _wait_settled(_SHRUNK_BBOX)

    resp = client.post("/segments/generate", json={
        "region": shrunk_key,
        "start": {"lat": 40.0, "lon": -105.29},
        "end": {"lat": 40.0, "lon": -105.28},
        "mode": "cycling",
        "shape": "point_to_point",
        "theme": "balanced",
    })
    assert resp.status_code == 200
