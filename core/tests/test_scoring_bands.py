"""Unit tests for `plotlines_core.scoring.bands` (FR6, Story A5).

No test previously existed for `Band`/`BandSet` at all, despite the elaborate
SPIKE-02/SPIKE-03 commentary throughout `search.py`/`diagnose.py` that
presumes this module's behavior. Covers the generic mechanism plus its
newest metric, `salience` (FR5's realized-outcome counterpart, added by this
story) — proof that a band works on any realized attribute, salience
included, with no metric-specific code path.
"""

import pytest

from plotlines_core.scoring.bands import (
    DEFAULT_DISTANCE_BAND_FRAC, Band, BandSet, default_distance_band,
    ensure_distance_band, format_value,
)
from plotlines_core.scoring.metrics import METRIC_PRECISION, RouteMetrics


def _metrics(**overrides) -> RouteMetrics:
    base = dict(distance_m=10_000.0, climb_m=200.0, descent_m=200.0, traffic=0.2,
                unpaved_frac=0.1, scenic_frac=0.3, max_grade=0.05, overlap_frac=0.0,
                edge_count=10, salience=0.4)
    base.update(overrides)
    return RouteMetrics(**base)


# ---------------------------------------------------------------------------
# Band construction
# ---------------------------------------------------------------------------


def test_band_with_neither_min_nor_max_is_rejected():
    with pytest.raises(ValueError):
        Band("climb_m")


def test_band_with_min_greater_than_max_is_rejected():
    with pytest.raises(ValueError):
        Band("climb_m", minimum=500.0, maximum=100.0)


def test_band_with_only_a_minimum_is_legal():
    Band("climb_m", minimum=100.0)


def test_band_with_only_a_maximum_is_legal():
    Band("climb_m", maximum=100.0)


# ---------------------------------------------------------------------------
# shortfall / satisfied_by
# ---------------------------------------------------------------------------


def test_shortfall_is_zero_inside_the_band():
    band = Band("climb_m", minimum=100.0, maximum=500.0)
    assert band.shortfall(300.0) == 0.0
    assert band.satisfied_by(300.0) is True


def test_shortfall_is_negative_below_the_minimum():
    band = Band("climb_m", minimum=100.0)
    assert band.shortfall(60.0) == pytest.approx(-40.0)
    assert band.satisfied_by(60.0) is False


def test_shortfall_is_positive_above_the_maximum():
    band = Band("climb_m", maximum=500.0)
    assert band.shortfall(560.0) == pytest.approx(60.0)
    assert band.satisfied_by(560.0) is False


def test_a_value_exactly_on_the_boundary_is_satisfied():
    band = Band("traffic", minimum=0.1, maximum=0.3)
    assert band.satisfied_by(0.1) is True
    assert band.satisfied_by(0.3) is True


# ---------------------------------------------------------------------------
# normalised — cross-metric comparability
# ---------------------------------------------------------------------------


def test_normalised_scales_by_the_metric_scale():
    # METRIC_SCALE["climb_m"] == 100.0, so a 100 m miss is exactly one notch.
    band = Band("climb_m", minimum=500.0)
    assert Band("climb_m", minimum=500.0).normalised(400.0) == pytest.approx(1.0)
    assert band.normalised(400.0) == pytest.approx(1.0)


def test_normalised_is_unsigned():
    over = Band("traffic", maximum=0.2).normalised(0.5)
    under = Band("traffic", minimum=0.5).normalised(0.2)
    assert over == pytest.approx(under)


# ---------------------------------------------------------------------------
# widened_to
# ---------------------------------------------------------------------------


def test_widened_to_only_moves_the_violated_side():
    band = Band("climb_m", minimum=100.0, maximum=500.0)
    assert band.widened_to(560.0) == Band("climb_m", minimum=100.0, maximum=560.0)
    assert band.widened_to(60.0) == Band("climb_m", minimum=60.0, maximum=500.0)


def test_widened_to_a_value_already_inside_is_a_no_op():
    band = Band("climb_m", minimum=100.0, maximum=500.0)
    assert band.widened_to(300.0) == band


# ---------------------------------------------------------------------------
# describe / format_value
# ---------------------------------------------------------------------------


def test_describe_two_sided_band():
    band = Band("climb_m", minimum=100.0, maximum=500.0)
    assert band.describe() == "climbing between 100 m and 500 m"


def test_describe_minimum_only():
    assert Band("traffic", minimum=0.2).describe() == "traffic exposure at least 20%"


def test_describe_maximum_only():
    assert Band("salience", maximum=0.6).describe() == "realized salience at most 60%"


def test_format_value_renders_fractions_as_percent():
    assert format_value("salience", 0.42) == "42%"


def test_format_value_renders_metres_with_commas():
    assert format_value("climb_m", 1234.0) == "1,234 m"


def test_describe_falls_back_to_the_raw_metric_name_when_unlabelled():
    assert Band("extras.custom", minimum=1.0).describe() == "extras.custom at least 1"


# ---------------------------------------------------------------------------
# BandSet — violations / satisfied_by / penalty
# ---------------------------------------------------------------------------


def test_bandset_with_no_violations_is_satisfied():
    bands = BandSet.of(Band("climb_m", minimum=100.0), Band("traffic", maximum=0.5))
    assert bands.satisfied_by(_metrics()) is True
    assert bands.violations(_metrics()) == []
    assert bands.penalty(_metrics()) == 0.0


def test_bandset_reports_every_violated_band():
    bands = BandSet.of(Band("climb_m", minimum=1000.0), Band("traffic", maximum=0.05))
    violations = bands.violations(_metrics())
    assert {b.metric for b, _n in violations} == {"climb_m", "traffic"}
    assert bands.satisfied_by(_metrics()) is False


def test_bandset_violations_are_worst_first():
    # climb_m short by 800 -> 8 notches (scale 100); traffic over by 0.1 -> 1 notch
    # (scale 0.1) — climb_m must sort first.
    bands = BandSet.of(Band("climb_m", minimum=1000.0), Band("traffic", maximum=0.1))
    violations = bands.violations(_metrics(climb_m=200.0, traffic=0.2))
    assert [b.metric for b, _n in violations] == ["climb_m", "traffic"]


def test_bandset_penalty_sums_normalised_shortfall_across_bands():
    bands = BandSet.of(Band("climb_m", minimum=1000.0), Band("traffic", maximum=0.1))
    penalty = bands.penalty(_metrics(climb_m=200.0, traffic=0.2))
    assert penalty == pytest.approx(8.0 + 1.0)


def test_bandset_without_removes_one_band_only():
    a, b = Band("climb_m", minimum=100.0), Band("traffic", maximum=0.5)
    bands = BandSet.of(a, b)
    assert bands.without(a).bands == (b,)


def test_bandset_describe_joins_every_band():
    bands = BandSet.of(Band("climb_m", minimum=100.0), Band("salience", minimum=0.2))
    assert bands.describe() == "climbing at least 100 m; realized salience at least 20%"


# ---------------------------------------------------------------------------
# `salience` specifically — this story's addition to the bandable set
# ---------------------------------------------------------------------------


def test_a_salience_band_is_satisfied_by_a_route_that_meets_it():
    band = Band("salience", minimum=0.3)
    assert band.satisfied_by(_metrics(salience=0.4).value("salience")) is True


def test_a_salience_band_is_violated_by_a_route_that_falls_short():
    band = Band("salience", minimum=0.3)
    assert band.satisfied_by(_metrics(salience=0.1).value("salience")) is False


def test_salience_band_shortfall_and_describe_use_the_realized_salience_label():
    band = Band("salience", minimum=0.5)
    metrics = _metrics(salience=0.2)
    assert band.shortfall(metrics.value("salience")) == pytest.approx(-0.3)
    assert band.label == "realized salience"


# ---------------------------------------------------------------------------
# default_distance_band / ensure_distance_band — FR8/A8's "banded by
# default in explore mode." SPIKE-03 §4 measured up to +14.8% unannounced
# distance drift when nothing bounded it; §3's convergence sweep found
# two-sided bands hold to within ±10% of centre everywhere tested.
# ---------------------------------------------------------------------------


def test_default_distance_band_is_centred_on_the_target():
    band = default_distance_band(20_000.0)
    assert band.metric == "distance_m"
    assert band.minimum == pytest.approx(20_000.0 * (1 - DEFAULT_DISTANCE_BAND_FRAC))
    assert band.maximum == pytest.approx(20_000.0 * (1 + DEFAULT_DISTANCE_BAND_FRAC))


def test_default_distance_band_catches_the_drift_spike_03_measured():
    # +14.8% was the worst unbanded drift SPIKE-03 observed (Boulder, §4) —
    # the default band exists specifically to flag that, not just narrower
    # drifts.
    band = default_distance_band(20_000.0)
    assert band.satisfied_by(20_000.0 * 1.148) is False


def test_default_distance_band_is_satisfied_by_the_exact_target():
    band = default_distance_band(20_000.0)
    assert band.satisfied_by(20_000.0) is True


def test_default_distance_band_respects_a_narrower_fraction_argument():
    band = default_distance_band(20_000.0, frac=0.20)
    assert band.minimum == pytest.approx(16_000.0)
    assert band.maximum == pytest.approx(24_000.0)


def test_default_distance_band_is_never_narrower_than_the_precision_floor():
    # A very small target shouldn't band to a window tighter than the search
    # can honestly promise (`METRIC_PRECISION`, the same floor `search.py`'s
    # `_floor_precision` applies to a probed envelope).
    band = default_distance_band(10.0)
    assert band.maximum - band.minimum >= METRIC_PRECISION["distance_m"]


def test_ensure_distance_band_adds_a_default_band_when_none_is_set():
    bands = BandSet.of(Band("climb_m", minimum=100.0))
    augmented = ensure_distance_band(bands, 20_000.0)
    assert len(augmented) == 2
    distance_band = next(b for b in augmented if b.metric == "distance_m")
    assert distance_band == default_distance_band(20_000.0)


def test_ensure_distance_band_never_overrides_an_author_authored_band():
    # FR8/A8's AC: "the Author can widen the band" — an existing distance_m
    # band, of any width, always wins over the default.
    wide = Band("distance_m", minimum=15_000.0, maximum=30_000.0)
    bands = BandSet.of(wide)
    augmented = ensure_distance_band(bands, 20_000.0)
    assert augmented.bands == (wide,)


def test_ensure_distance_band_is_a_no_op_with_no_target():
    bands = BandSet.of(Band("climb_m", minimum=100.0))
    assert ensure_distance_band(bands, None) is bands


def test_ensure_distance_band_is_a_no_op_when_bands_already_full():
    bands = BandSet.of(Band("distance_m", minimum=18_000.0, maximum=22_000.0))
    assert ensure_distance_band(bands, 20_000.0) is bands
