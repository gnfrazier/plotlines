"""Min/max bands over realised route attributes (FR6, Story A5).

A `Band` is the Author's acceptance range for one attribute. `BandSet` is the whole
constraint set for a request. Neither knows how to route — they only judge a finished
`RouteMetrics`. Keeping judgement separate from search is what lets SPIKE-02 reuse the
same objects to explain *why* nothing satisfied them.
"""

from __future__ import annotations

from dataclasses import dataclass

from plotlines_core.scoring.metrics import METRIC_LABEL, METRIC_PRECISION, METRIC_SCALE, RouteMetrics


@dataclass(frozen=True)
class Band:
    """An inclusive acceptance range on one metric. `None` means unbounded."""

    metric: str
    minimum: float | None = None
    maximum: float | None = None

    def __post_init__(self) -> None:
        if self.minimum is None and self.maximum is None:
            raise ValueError(f"band on {self.metric!r} bounds nothing")
        if (self.minimum is not None and self.maximum is not None
                and self.minimum > self.maximum):
            raise ValueError(
                f"band on {self.metric!r} is inverted: {self.minimum} > {self.maximum}"
            )

    @property
    def label(self) -> str:
        return METRIC_LABEL.get(self.metric, self.metric)

    def shortfall(self, value: float) -> float:
        """How far outside the band `value` sits, in the metric's own units.

        Signed: negative when the value is under `minimum`, positive when over
        `maximum`, 0.0 when satisfied. The sign carries which way to relax.
        """
        if self.minimum is not None and value < self.minimum:
            return value - self.minimum
        if self.maximum is not None and value > self.maximum:
            return value - self.maximum
        return 0.0

    def satisfied_by(self, value: float) -> bool:
        return self.shortfall(value) == 0.0

    def normalised(self, value: float) -> float:
        """Shortfall in "notches an Author would notice", for cross-metric ranking."""
        return abs(self.shortfall(value)) / METRIC_SCALE.get(self.metric, 1.0)

    def describe(self) -> str:
        if self.minimum is not None and self.maximum is not None:
            return f"{self.label} between {format_value(self.metric, self.minimum)} and {format_value(self.metric, self.maximum)}"
        if self.minimum is not None:
            return f"{self.label} at least {format_value(self.metric, self.minimum)}"
        return f"{self.label} at most {format_value(self.metric, self.maximum)}"

    def widened_to(self, value: float) -> Band:
        """The narrowest version of this band that would admit `value`."""
        low, high = self.minimum, self.maximum
        if low is not None and value < low:
            low = value
        if high is not None and value > high:
            high = value
        return Band(self.metric, low, high)


def format_value(metric: str, value: float) -> str:
    # `traffic`/`salience` are the two 0..1 continuous metrics without a `_frac`
    # suffix (length-weighted means, not boolean-threshold shares) — FR6.
    if metric.endswith("_frac") or metric in ("traffic", "salience"):
        return f"{value * 100:.0f}%"
    if metric.endswith("_m"):
        return f"{value:,.0f} m"
    return f"{value:g}"


@dataclass(frozen=True)
class BandSet:
    bands: tuple[Band, ...]

    @classmethod
    def of(cls, *bands: Band) -> BandSet:
        return cls(tuple(bands))

    def __iter__(self):
        return iter(self.bands)

    def __len__(self) -> int:
        return len(self.bands)

    def without(self, band: Band) -> BandSet:
        return BandSet(tuple(b for b in self.bands if b is not band))

    def subset(self, keep) -> BandSet:
        return BandSet(tuple(b for b in self.bands if b in keep))

    def violations(self, metrics: RouteMetrics) -> list[tuple[Band, float]]:
        """Every band this route misses, worst first, in normalised notches."""
        out = [(b, b.normalised(metrics.value(b.metric)))
               for b in self.bands if not b.satisfied_by(metrics.value(b.metric))]
        return sorted(out, key=lambda pair: -pair[1])

    def satisfied_by(self, metrics: RouteMetrics) -> bool:
        return not self.violations(metrics)

    def penalty(self, metrics: RouteMetrics) -> float:
        """Total normalised miss — the objective the band search descends."""
        return sum(b.normalised(metrics.value(b.metric)) for b in self.bands)

    def describe(self) -> str:
        return "; ".join(b.describe() for b in self.bands)


#: FR8/A8, SPIKE-03 §4 (`spikes/SPIKE-03/results/RESULTS.md`): left unbanded, the
#: search silently spent up to +14.8% extra mileage satisfying other bands —
#: "distance must be a band like any other, not a soft target. It is already
#: supported; it simply has to be included by default." §3's convergence sweep
#: found two-sided bands hold to within ±10% of centre in every region tested
#: (±5% failed in one of three) — narrow enough to actually catch the drift
#: SPIKE-03 measured, which is the half-width used whenever the Author (or the
#: caller) hasn't set their own `distance_m` band.
DEFAULT_DISTANCE_BAND_FRAC = 0.10


def default_distance_band(target_m: float, frac: float = DEFAULT_DISTANCE_BAND_FRAC) -> Band:
    """A `distance_m` band centred on `target_m`, floored to the metric's own
    precision (`METRIC_PRECISION`) so a very small target never bands to a
    window narrower than the search can honestly promise."""
    half = max(frac * target_m, METRIC_PRECISION["distance_m"] / 2.0)
    return Band("distance_m", target_m - half, target_m + half)


#: A9a / SPIKE-01 — three or more via-anchors pin a loop's length. SPIKE-01
#: measured distance error jumping from under ±14% at two via-nodes to +30.7%
#: (Boulder) / +81.9% (Viroqua) at three, with every via hit and every loop
#: closed: the solver was never the problem, the places simply determine the
#: length. At or past this count an explore request's target distance stops
#: being a constraint the search will chase and becomes advisory — reported,
#: with any deviation surfaced through A6's relaxation path
#: (`routing.diagnose`). Compose mode (`target_m is None`) already reports
#: distance as an outcome (FR118), so this threshold is an explore-mode
#: concept only.
ADVISORY_VIA_THRESHOLD = 3


def distance_is_advisory(target_m: float | None, via_count: int) -> bool:
    """A9a — True when an explore request's target distance can only be
    reported, not honoured, because `via_count` via-anchors already fix the
    loop's length (see `ADVISORY_VIA_THRESHOLD`).

    `target_m is None` is compose mode, where distance is a reported outcome
    regardless of how many anchors there are (FR118): there is no target to
    downgrade, so this is False.
    """
    return target_m is not None and via_count >= ADVISORY_VIA_THRESHOLD


def ensure_distance_band(bands: BandSet, target_m: float | None,
                         *, via_count: int = 0) -> BandSet:
    """FR8/A8's AC: distance is never dropped from the explore search's
    constraint set. An Author-authored `distance_m` band — any width,
    including one wider than the default — always wins; this only adds one
    when the caller supplied none at all, and only when there is a target to
    centre it on.

    A9a: when `via_count` via-anchors make the target advisory
    (`distance_is_advisory`), no default band is synthesised — the explore
    search stops chasing a distance the vias have already fixed, and the
    deviation is surfaced by `routing.diagnose` instead. An Author-authored
    `distance_m` band still wins even then: downgrading a band the Author set
    by hand is their decision to make, not this function's.
    """
    if target_m is None or any(b.metric == "distance_m" for b in bands):
        return bands
    if distance_is_advisory(target_m, via_count):
        return bands
    return BandSet((*bands.bands, default_distance_band(target_m, DEFAULT_DISTANCE_BAND_FRAC)))
