"""Pre-registered verdict bands for a (region, strategy) pair, and the re-stated
A16 memory budget. Declared before any result is read.

A strategy is judged on three axes, at every zoom in the sweep, on both
platforms:

    FRAME      p95 interaction frame stays under the 16.7 ms 60 Hz budget
    SELECT     list<->map selection and cluster-extent highlight stay <= 250 ms
               (the issue's own line: "a map that takes 300 ms to answer a tap
               is still unusable")
    INTENT     the strategy actually satisfies FR99 (salience visible, promote
               from the map) and N4a (two-way selection, cluster extent) at the
               zoom the Author needs them — not just "renders fast"

INTENT has two severities:

    hard   the overview zoom renders *nothing* — the Author cannot see the
           field they are meant to curate. Disqualifying.
    soft   the field is visible but degraded — salience aggregated into a count
           glyph, or a map tap that cannot resolve to one card. A real cost,
           not a disqualification.

Bands:

    GREEN   FRAME + SELECT hold on GPU at every zoom, FRAME also holds on the
            software-raster floor at the trip-overview zoom, and INTENT is clean
    AMBER   holds on GPU but needs a display-density ceiling, fails the
            software-raster floor, or has a soft INTENT cost
    RED     fails FRAME or SELECT on GPU at a zoom the workspace needs, or has a
            hard INTENT failure
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Band(str, Enum):
    GREEN = "green"
    AMBER = "amber"
    RED = "red"


# zooms the curation workspace genuinely depends on (ARCH Q15 / PRD §5.4a):
# z10 is the trip overview ("find the good spots" runs over the whole bbox),
# z14-16 is anchor placement. z12 is in between.
OVERVIEW_ZOOM = 10
PLACEMENT_ZOOMS = (14, 16)


@dataclass(frozen=True)
class AxisResult:
    frame_ok_gpu: bool
    frame_ok_swraster_overview: bool
    select_ok_gpu: bool
    intent_hard_fail: bool          # overview renders nothing
    intent_soft_fail: bool          # visible but degraded
    reasons: tuple[str, ...]


def classify(axis: AxisResult) -> Band:
    if not axis.frame_ok_gpu or not axis.select_ok_gpu or axis.intent_hard_fail:
        return Band.RED
    if not axis.frame_ok_swraster_overview or axis.intent_soft_fail:
        return Band.AMBER
    return Band.GREEN


# --------------------------------------------------------------------------- #
# A16, re-stated. SPIKE-14 said "budget ~1 GB on Windows with a basemap".
# A16 asks for that number re-taken with candidates on screen. The re-statement
# is: base client budget + the worst candidate-layer memory add the recommended
# strategy incurs at its display-density ceiling, + headroom.
# --------------------------------------------------------------------------- #

A16_HEADROOM_MB = 150  # tile-cache bounds + selection/animation transients


def a16_budget_mb(base_client_mb: float, worst_candidate_layer_add_mb: float) -> float:
    return round(base_client_mb + worst_candidate_layer_add_mb + A16_HEADROOM_MB, 0)
