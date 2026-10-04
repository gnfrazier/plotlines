"""Issue #397: the routing capability's ETA came from a fixed
`GRAPH_ESTIMATED_S = 8.0` against SPIKE-D's measured 36.7-116.6 s, so
"available in about a minute" showed for builds that ran two. SPIKE-D's own
finding is that the estimate is "a range or observed progress, never a
constant": the ETA now comes from graph builds this sidecar has actually
timed, and there is none until one has been.
"""

from __future__ import annotations

import time

import pytest

from plotlines_service.app import CapabilityState, GraphBuildHistory


def test_no_observed_build_means_progress_but_no_eta():
    history = GraphBuildHistory()
    state = CapabilityState(history.estimate_s)
    state.start("building graph")

    d = state.to_dict()

    assert d["ready"] is False
    assert "progress" in d, "still loading: the client must not read this as failed"
    assert "eta_s" not in d


def test_the_estimate_is_the_median_of_recent_observed_builds():
    history = GraphBuildHistory()
    for seconds in (40.0, 120.0, 60.0):
        history.record(seconds)
    assert history.estimate_s() == 60.0

    state = CapabilityState(history.estimate_s)
    state.start("building graph")
    eta = state.to_dict()["eta_s"]
    assert 55.0 < eta <= 60.0


def test_a_build_served_from_cache_is_not_an_observation():
    history = GraphBuildHistory()
    history.record(0.2)
    assert history.estimate_s() is None


def test_only_the_most_recent_builds_count():
    history = GraphBuildHistory(window=3)
    for seconds in (500.0, 500.0, 500.0, 30.0, 30.0, 30.0):
        history.record(seconds)
    assert history.estimate_s() == 30.0


def test_a_build_running_past_its_estimate_has_no_eta_rather_than_one_second():
    history = GraphBuildHistory()
    history.record(2.0)
    state = CapabilityState(history.estimate_s)
    state.start("building graph")
    state.started_at = time.perf_counter() - 10.0

    d = state.to_dict()

    assert "eta_s" not in d, "past the estimate the honest answer is unknown"
    assert d["progress"] == 0.95


def test_a_fixed_zero_estimate_still_reports_no_eta():
    state = CapabilityState(0.0)
    state.start("fetching elevation")
    assert "eta_s" not in state.to_dict()


# ── Issue #630: the estimate and deadline scale with the local clip ────────

import threading  # noqa: E402

from plotlines_service import app as app_module  # noqa: E402
from plotlines_service.app import (  # noqa: E402
    LARGE_CLIP_BYTES,
    Readiness,
    _graph_phase_deadline,
    _graph_phase_detail,
)


def test_a_sized_estimate_scales_the_observed_rate_to_this_clip():
    """#630: one 4.7 s build made a 15,700 km² region read 95% within
    seconds. Scaled by clip size, a 47.7 MB clip after a 1 MB / 4.7 s build
    estimates ~224 s, not 4.7 s."""
    history = GraphBuildHistory()
    history.record(4.7, clip_bytes=1_000_000)
    assert history.estimate_s(47_700_000) == pytest.approx(224.19)
    # No size: the plain median still answers.
    assert history.estimate_s() == 4.7


def test_an_overpass_observation_never_feeds_the_rate():
    history = GraphBuildHistory()
    history.record(60.0)  # no clip: the Overpass fallback
    assert history.estimate_s(10_000_000) == 60.0


def test_the_local_deadline_scales_and_never_blames_the_network():
    timeout_s, message = _graph_phase_deadline(47_700_000)
    assert timeout_s == pytest.approx(715.5)
    assert "reach" not in message and "connection" not in message
    assert "this computer" in message and message.endswith(".")

    small_s, _ = _graph_phase_deadline(1_000_000)
    assert small_s == app_module._GRAPH_PHASE_TIMEOUT_S
    net_s, net_message = _graph_phase_deadline(None)
    assert (net_s, net_message) == (
        app_module._GRAPH_PHASE_TIMEOUT_S, app_module._GRAPH_PHASE_TIMEOUT_MESSAGE)


def test_a_large_clip_says_so_in_the_routing_reason():
    assert _graph_phase_detail(None) == "building graph"
    assert _graph_phase_detail(LARGE_CLIP_BYTES - 1) == "building graph"
    assert "large area" in _graph_phase_detail(LARGE_CLIP_BYTES)


def _sparse_clip(cache_dir, size):
    path = cache_dir / "clip.osm.pbf"
    with open(path, "wb") as f:
        f.truncate(size)
    return path


def test_a_region_build_reads_its_clip_size_into_the_estimate_and_reason(
    tmp_path, monkeypatch,
):
    clip = _sparse_clip(tmp_path, 30_000_000)
    monkeypatch.setattr(app_module.extract_fetch, "find_reusable_extract",
                        lambda bbox, cache_dir: clip)
    history = GraphBuildHistory()
    history.record(10.0, clip_bytes=1_000_000)  # 10 s/MB
    monkeypatch.setattr(app_module, "GRAPH_BUILD_HISTORY", history)
    release = threading.Event()

    def held_ensure_graph(region, cache_dir):
        release.wait(10)
        return region.graph_path(cache_dir)
    monkeypatch.setattr(app_module.region_lib, "ensure_graph", held_ensure_graph)
    monkeypatch.setattr(app_module, "load_graphml", lambda path: object())

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    try:
        key = state.ensure_region((-80.76, 36.98, -78.88, 37.83), "bike")
        region = state.regions[key]
        deadline = time.monotonic() + 5
        while region.graph_state.status != "loading" and time.monotonic() < deadline:
            time.sleep(0.01)
        d = region.graph_state.to_dict()
        assert "large area" in d["reason"]
        assert 290.0 < d["eta_s"] <= 300.0  # 30 MB × 10 s/MB, not 10 s
        assert d["progress"] < 0.05
    finally:
        release.set()
        state.shutdown()
