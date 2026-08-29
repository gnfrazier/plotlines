import json
import os

import pytest

from analyze import percentile, rollup, summarize
from bands import Band, classify

SAMPLE = os.path.join(os.path.dirname(__file__), "..", "results", "sample_run.json")


# --- percentile ---------------------------------------------------------------

def test_percentile_empty_is_infinite():
    # a run that put nothing in the inbox has infinitely bad latency, not zero
    assert percentile([], 50) == float("inf")


def test_percentile_singleton():
    assert percentile([7.3], 95) == 7.3


def test_percentile_nearest_rank():
    xs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    assert percentile(xs, 50) == 5
    assert percentile(xs, 95) == 10
    assert percentile(xs, 100) == 10


def test_percentile_is_order_independent():
    assert percentile([9, 1, 5, 3, 7], 50) == 5


# --- rollup -----------------------------------------------------------------

def _run(observations):
    return {"provider": "postmark", "from_address": "login@x", "observations": observations}


def test_rollup_counts_placements():
    r = rollup(_run([
        {"host": "gmail", "placement": "inbox", "time_to_inbox_seconds": 4.0},
        {"host": "gmail", "placement": "inbox", "time_to_inbox_seconds": 6.0},
        {"host": "yahoo", "placement": "spam", "time_to_inbox_seconds": None},
        {"host": "yahoo", "placement": "missing", "time_to_inbox_seconds": None},
    ]))
    assert r.inbox_rate == 0.5
    assert r.spam_rate == 0.25
    assert r.missing_rate == 0.25
    assert r.p50_seconds == 4.0  # nearest-rank over [4.0, 6.0]


def test_rollup_latency_ignores_non_inbox():
    r = rollup(_run([
        {"host": "gmail", "placement": "inbox", "time_to_inbox_seconds": 5.0},
        {"host": "gmail", "placement": "spam", "time_to_inbox_seconds": None},
    ]))
    assert r.p50_seconds == 5.0


def test_rollup_per_host_breakdown():
    r = rollup(_run([
        {"host": "gmail", "placement": "inbox", "time_to_inbox_seconds": 5.0},
        {"host": "gmail", "placement": "inbox", "time_to_inbox_seconds": 5.0},
        {"host": "microsoft", "placement": "spam", "time_to_inbox_seconds": None},
        {"host": "microsoft", "placement": "inbox", "time_to_inbox_seconds": 8.0},
    ]))
    by_host = {h.host: h for h in r.per_host}
    assert by_host["gmail"].inbox_rate == 1.0
    assert by_host["microsoft"].inbox_rate == 0.5
    assert by_host["microsoft"].spam_rate == 0.5


def test_rollup_rejects_empty_run():
    with pytest.raises(ValueError):
        rollup(_run([]))


# --- the committed sample --------------------------------------------------

def test_sample_run_is_labelled_synthetic():
    with open(SAMPLE) as fh:
        run = json.load(fh)
    assert run.get("synthetic") is True, "the fixture must not be mistaken for a measured run"


def test_sample_run_lands_in_the_fallback_band():
    with open(SAMPLE) as fh:
        run = json.load(fh)
    result = summarize(run)
    assert result["verdict"] == "fallback"
    # and specifically: it clears FALLBACK outright...
    assert result["why_not_fallback"] == []
    # ...while carrying concrete reasons it is not STAKE
    assert result["why_not_stake"]


def test_sample_run_classify_matches_summarize():
    with open(SAMPLE) as fh:
        run = json.load(fh)
    assert classify(rollup(run)) is Band.FALLBACK


def test_summarize_shape():
    with open(SAMPLE) as fh:
        run = json.load(fh)
    result = summarize(run)
    assert set(result) >= {
        "provider", "from_address", "sample_size", "verdict",
        "overall", "per_host", "why_not_stake", "why_not_fallback",
    }
    assert result["sample_size"] == len(run["observations"])
    assert {"inbox_rate", "spam_rate", "missing_rate", "p50_seconds", "p95_seconds"} == set(
        result["overall"]
    )
