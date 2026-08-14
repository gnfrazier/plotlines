"""Min/max bands over realised route attributes (FR6, Story A5).

A `Band` is the Author's acceptance range for one attribute. `BandSet` is the whole
constraint set for a request. Neither knows how to route — they only judge a finished
`RouteMetrics`. Keeping judgement separate from search is what lets SPIKE-02 reuse the
same objects to explain *why* nothing satisfied them.
"""

from __future__ import annotations

from dataclasses import dataclass

from plotlines_core.scoring.metrics import METRIC_LABEL, METRIC_SCALE, RouteMetrics


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
    if metric.endswith("_frac") or metric == "traffic":
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
