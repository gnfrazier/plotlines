"""Elevation void handling (ARCH §7.5, PRD FR85/FR88, SPIKE-18).

One policy, applied to every elevation read: a value where the raster genuinely
has one, and ``0.0`` everywhere it does not —

* the raster's ``nodata`` sentinel,
* a NaN ``nodata`` (checked with :func:`math.isnan` / :func:`numpy.isnan`,
  because ``value == nodata`` misses NaN under IEEE 754 — a real defect found
  and fixed in the cycling-tour-planner POC this policy is lifted from),
* a coordinate outside every open raster's bounds,
* a raster that is missing or unreadable.

"A route through a data void is slightly wrong; a route that hangs or throws is
broken" (ARCH §7.5). Each *distinct* fallback is logged **once per raster path**
— never once per coordinate — so a route that clips the same hole 400 times
produces one log line, not 400.

This module has no fallback *source*: GEDTM30 via OpenTopography is the single
elevation source with no secondary service (FR85, ARCH D20). A void resolves to
``0.0``; it never triggers a second provider.
"""

from __future__ import annotations

import logging
import math

import numpy as np

logger = logging.getLogger("plotlines.elevation")

#: Every void resolves to this. Not configurable — FR88 pins it.
VOID_FILL = 0.0

# The reasons a read can be void, in the order §7.5 lists them. Kept as an
# enumerated tuple with the rule stated here (seed-set discipline, punch-list
# §0): the rule is "any read that is not a finite in-bounds sample is a void
# and fills to VOID_FILL" — this list is the exhaustive set of ways that
# happens for a local single-source raster, not an open-ended lookup.
VOID_REASONS = ("nodata", "nan", "inf", "out_of_bounds", "unreadable_raster")


class VoidLog:
    """Deduplicates void log lines to one per ``(raster path, reason)`` pair.

    One instance per sampler (a sampler holds one raster path for the process
    lifetime), so in practice this collapses to one line per reason per raster.
    """

    def __init__(self) -> None:
        self._seen: set[tuple[str, str]] = set()

    def note(self, raster_path: str, reason: str, detail: str = "") -> bool:
        """Log this void once. Returns ``True`` the first time, ``False`` after."""
        key = (str(raster_path), reason)
        if key in self._seen:
            return False
        self._seen.add(key)
        suffix = f" ({detail})" if detail else ""
        logger.warning(
            "elevation void: %s for raster %s%s -> filling %.1f (logged once per path)",
            reason, raster_path, suffix, VOID_FILL,
        )
        return True

    def reset(self) -> None:
        self._seen.clear()


def is_nan_nodata(nodata: object) -> bool:
    """True when a dataset's ``nodata`` is itself NaN — the IEEE 754 trap."""
    return isinstance(nodata, float) and math.isnan(nodata)


def resolve_voids(
    values: np.ndarray,
    *,
    nodata: object,
    raster_path: str,
    in_bounds: np.ndarray | None = None,
    void_log: VoidLog | None = None,
) -> np.ndarray:
    """Apply the §7.5 void policy to a 1-D array of raw samples.

    ``values``      raw samples straight off the raster (metres).
    ``nodata``      the dataset's ``nodata`` (may be ``None`` or NaN).
    ``in_bounds``   optional boolean mask, ``False`` where the coordinate fell
                    outside the raster; those positions fill to ``0.0``.
    ``void_log``    dedup sink; a fresh one is used if not supplied.

    Returns a new ``float64`` array with every non-finite / sentinel / OOB
    position replaced by :data:`VOID_FILL`. Never raises.
    """
    out = np.asarray(values, dtype="float64").copy()
    log = void_log or VoidLog()

    # 1. explicit nodata sentinel (skip if it is NaN — the isnan pass below
    #    catches that, and `out == nan` is always False anyway).
    if nodata is not None and not is_nan_nodata(nodata):
        mask = out == nodata
        if mask.any():
            log.note(raster_path, "nodata")
            out[mask] = VOID_FILL

    # 2. NaN — covers a NaN nodata and any NaN the driver returned for a
    #    partially-read window. `math.isnan` semantics, vectorised.
    nan_mask = np.isnan(out)
    if nan_mask.any():
        log.note(raster_path, "nan")
        out[nan_mask] = VOID_FILL

    # 3. +/- inf, defensively — not expected from a DTM, still not a number.
    inf_mask = np.isinf(out)
    if inf_mask.any():
        log.note(raster_path, "inf")
        out[inf_mask] = VOID_FILL

    # 4. coordinate outside the raster.
    if in_bounds is not None:
        oob = ~np.asarray(in_bounds, dtype=bool)
        if oob.any():
            log.note(raster_path, "out_of_bounds")
            out[oob] = VOID_FILL

    return out
