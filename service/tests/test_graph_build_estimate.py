"""Issue #397: the routing capability's ETA came from a fixed
`GRAPH_ESTIMATED_S = 8.0` against SPIKE-D's measured 36.7-116.6 s, so
"available in about a minute" showed for builds that ran two. SPIKE-D's own
finding is that the estimate is "a range or observed progress, never a
constant": the ETA now comes from graph builds this sidecar has actually
timed, and there is none until one has been.
"""

from __future__ import annotations

import time

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
