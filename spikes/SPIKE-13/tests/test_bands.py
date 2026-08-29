"""The pre-registered bands must not drift silently — this file pins them."""

import pytest

from bands import (
    FALLBACK_CRITERIA,
    MAJOR_CONSUMER_HOSTS,
    STAKE_CRITERIA,
    Band,
    HostResult,
    Rollup,
    classify,
    unmet_reasons,
)


def _rollup(inbox=1.0, spam=0.0, missing=0.0, p50=5.0, p95=15.0, per_host=None):
    if per_host is None:
        per_host = (
            HostResult("gmail", inbox, spam, missing),
            HostResult("yahoo", inbox, spam, missing),
        )
    return Rollup(inbox, spam, missing, p50, p95, tuple(per_host))


def test_clean_run_is_stake():
    assert classify(_rollup()) is Band.STAKE


def test_ragged_tail_drops_stake_to_fallback():
    # median still fast, p95 past the STAKE ceiling but inside FALLBACK's
    r = _rollup(inbox=0.98, spam=0.01, missing=0.01, p50=9.0, p95=60.0)
    assert classify(r) is Band.FALLBACK


def test_low_overall_inbox_is_block():
    assert classify(_rollup(inbox=0.90, spam=0.05, missing=0.05)) is Band.BLOCK


def test_one_bad_major_host_cannot_be_laundered_by_the_rollup():
    per_host = (
        HostResult("gmail", 1.0, 0.0, 0.0),
        HostResult("microsoft", 1.0, 0.0, 0.0),
        HostResult("yahoo", 0.80, 0.20, 0.0),  # Yahoo users simply cannot log in
    )
    # rollup looks healthy...
    r = Rollup(0.985, 0.011, 0.004, 5.0, 20.0, per_host)
    # ...but the verdict is still BLOCK
    assert classify(r) is Band.BLOCK


def test_non_major_host_does_not_gate():
    # a corporate tenant behaving badly is not a launch blocker
    per_host = (
        HostResult("gmail", 1.0, 0.0, 0.0),
        HostResult("yahoo", 1.0, 0.0, 0.0),
        HostResult("acme-corp", 0.5, 0.5, 0.0),
    )
    r = Rollup(0.99, 0.006, 0.004, 6.0, 18.0, per_host)
    assert classify(r) is Band.STAKE


def test_stake_is_strictly_tighter_than_fallback():
    assert STAKE_CRITERIA.min_inbox_rate >= FALLBACK_CRITERIA.min_inbox_rate
    assert STAKE_CRITERIA.max_spam_rate <= FALLBACK_CRITERIA.max_spam_rate
    assert STAKE_CRITERIA.max_p95_seconds <= FALLBACK_CRITERIA.max_p95_seconds
    assert STAKE_CRITERIA.max_missing_rate <= FALLBACK_CRITERIA.max_missing_rate


def test_major_hosts_cover_the_consumer_market():
    for h in ("gmail", "microsoft", "yahoo", "icloud"):
        assert h in MAJOR_CONSUMER_HOSTS


def test_unmet_reasons_are_specific():
    r = _rollup(inbox=0.90, spam=0.10, missing=0.0, p50=40.0, p95=200.0)
    reasons = unmet_reasons(STAKE_CRITERIA, r)
    joined = " ".join(reasons)
    assert "inbox rate" in joined
    assert "spam rate" in joined
    assert "p50" in joined and "p95" in joined


@pytest.mark.parametrize("p95", [29.9, 30.0])
def test_stake_p95_boundary_inclusive(p95):
    assert classify(_rollup(p95=p95)) is Band.STAKE


def test_stake_p95_just_over_boundary_is_fallback():
    assert classify(_rollup(inbox=0.995, spam=0.003, missing=0.002, p95=30.1)) is Band.FALLBACK
