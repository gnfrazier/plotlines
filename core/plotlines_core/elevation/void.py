"""Elevation void handling (ARCH §7.5, PRD FR85/FR88, SPIKE-18; amended #473, D68).

Two policies, because a read can be void for two different kinds of reason.

**A gap inside a raster that opened** — real elevation exists nearby, one pixel
or one point just is not covered:

* the raster's ``nodata`` sentinel,
* a NaN ``nodata`` (checked with :func:`math.isnan` / :func:`numpy.isnan`,
  because ``value == nodata`` misses NaN under IEEE 754 — a real defect found
  and fixed in the cycling-tour-planner POC this policy is lifted from),
* ``+/-inf``,
* a coordinate outside the open raster's bounds.

A gap is **interpolated** from the nearest finite samples on either side — along
the ordered sequence a route hands in (:func:`interpolate_voids`), or across the
graph's own adjacency during enrichment — and fills to :data:`VOID_FILL` only
when there is no finite sample anywhere to interpolate from. Before #473 every
gap filled to ``0.0``, so a route with a handful of nodata pixels on otherwise
good coverage plunged to sea level and back at each one, and reported the
plunge as ascent and descent.

**No source at all** — the raster is missing or unreadable, or the resolver
found nothing for the bbox. That is not a gap in data but the absence of it, and
it is reported as **absent** (NaN from a sampler, ``{}`` from a profile, no
attribute on a graph) — never a fabricated flat ``0.0``.

"A route through a data void is slightly wrong; a route that hangs or throws is
broken" (ARCH §7.5). Neither policy raises. Each *distinct* void is logged
**once per raster path** — never once per coordinate — so a route that clips
the same hole 400 times produces one log line, not 400.

This module has no fallback *source*: GEDTM30 via OpenTopography is the single
elevation source with no secondary service (FR85, ARCH D20). A void never
triggers a second provider.
"""

from __future__ import annotations

import logging
import math

import numpy as np

logger = logging.getLogger("plotlines.elevation")

#: The last-resort fill for a gap with no finite sample anywhere to interpolate
#: from (a route lying wholly outside the open raster, a graph component with no
#: covered node). Never used for a source that did not resolve — that is absent,
#: not ``0.0`` (#473).
VOID_FILL = 0.0

# The reasons a read can be void, in the order §7.5 lists them. Kept as an
# enumerated tuple with the rule stated here (seed-set discipline, punch-list
# §0): the rule is "any read that is not a finite in-bounds sample is a void" —
# this list is the exhaustive set of ways that happens for a local single-source
# raster, not an open-ended lookup. The first four are gaps (interpolated); the
# last is the absence of a source (absent).
VOID_REASONS = ("nodata", "nan", "inf", "out_of_bounds", "unreadable_raster")

#: The subset of :data:`VOID_REASONS` that is a gap inside an open raster.
GAP_REASONS = VOID_REASONS[:4]

_EARTH_RADIUS_M = 6_371_000.0


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
        outcome = (
            "interpolating from the nearest finite samples"
            if reason in GAP_REASONS
            else "elevation absent"
        )
        logger.warning(
            "elevation void: %s for raster %s%s -> %s (logged once per path)",
            reason, raster_path, suffix, outcome,
        )
        return True

    def reset(self) -> None:
        self._seen.clear()


def is_nan_nodata(nodata: object) -> bool:
    """True when a dataset's ``nodata`` is itself NaN — the IEEE 754 trap."""
    return isinstance(nodata, float) and math.isnan(nodata)


def mark_voids(
    values: np.ndarray,
    *,
    nodata: object,
    raster_path: str,
    in_bounds: np.ndarray | None = None,
    void_log: VoidLog | None = None,
) -> np.ndarray:
    """Find every gap in a 1-D array of raw samples and mark it NaN.

    ``values``      raw samples straight off the raster (metres).
    ``nodata``      the dataset's ``nodata`` (may be ``None`` or NaN).
    ``in_bounds``   optional boolean mask, ``False`` where the coordinate fell
                    outside the raster.
    ``void_log``    dedup sink; a fresh one is used if not supplied.

    Returns a new ``float64`` array that is finite exactly where the raster had
    a real value. Never raises. How the NaNs are filled is the caller's call —
    along a sequence (:func:`interpolate_voids`) or across a graph
    (:func:`plotlines_core.elevation.enrich.enrich_elevation`) — because only
    the caller knows which samples are neighbours.
    """
    raw = np.asarray(values, dtype="float64")
    out = raw.copy()
    log = void_log or VoidLog()

    # 1. explicit nodata sentinel (skip if it is NaN — the isnan pass below
    #    catches that, and `out == nan` is always False anyway).
    if nodata is not None and not is_nan_nodata(nodata):
        mask = raw == nodata
        if mask.any():
            log.note(raster_path, "nodata")
            out[mask] = np.nan

    # 2. NaN — covers a NaN nodata and any NaN the driver returned for a
    #    partially-read window. `math.isnan` semantics, vectorised; read off
    #    the raw samples so pass 1's own NaNs are not logged a second time.
    if np.isnan(raw).any():
        log.note(raster_path, "nan")

    # 3. +/- inf, defensively — not expected from a DTM, still not a number.
    inf_mask = np.isinf(raw)
    if inf_mask.any():
        log.note(raster_path, "inf")
        out[inf_mask] = np.nan

    # 4. coordinate outside the raster.
    if in_bounds is not None:
        oob = ~np.asarray(in_bounds, dtype=bool)
        if oob.any():
            log.note(raster_path, "out_of_bounds")
            out[oob] = np.nan

    return out


def _along_track_m(coords: list[tuple[float, float]]) -> np.ndarray:
    """Cumulative distance (metres) along ordered ``(lat, lon)`` pairs.

    Equirectangular per step — exact enough at the spacing of a routed
    polyline, and all interpolation needs is a monotone position.
    """
    lat = np.radians(np.array([c[0] for c in coords], dtype="float64"))
    lon = np.radians(np.array([c[1] for c in coords], dtype="float64"))
    dx = np.diff(lon) * np.cos((lat[1:] + lat[:-1]) / 2.0)
    dy = np.diff(lat)
    return np.concatenate(([0.0], np.cumsum(_EARTH_RADIUS_M * np.hypot(dx, dy))))


def interpolate_voids(
    values: np.ndarray, coords: list[tuple[float, float]] | None = None
) -> np.ndarray:
    """Fill the NaN gaps in an *ordered* sample sequence.

    Each gap is linearly interpolated between the nearest finite samples on
    either side — by distance along ``coords`` when given (a routed polyline's
    vertices are unevenly spaced), by position in the array otherwise. A gap at
    either end, with a finite sample on one side only, holds that sample's
    value. With no finite sample at all, every position is :data:`VOID_FILL`.
    Never raises.
    """
    out = np.asarray(values, dtype="float64").copy()
    gap = ~np.isfinite(out)
    if not gap.any():
        return out
    if gap.all():
        out[:] = VOID_FILL
        return out
    if coords is not None and len(coords) == len(out):
        x = _along_track_m(coords)
    else:
        x = np.arange(len(out), dtype="float64")
    out[gap] = np.interp(x[gap], x[~gap], out[~gap])
    return out


def resolve_voids(
    values: np.ndarray,
    *,
    nodata: object,
    raster_path: str,
    in_bounds: np.ndarray | None = None,
    void_log: VoidLog | None = None,
    coords: list[tuple[float, float]] | None = None,
) -> np.ndarray:
    """Apply the §7.5 gap policy to an *ordered* 1-D array of raw samples —
    :func:`mark_voids`, then :func:`interpolate_voids`. Returns a finite
    ``float64`` array. Never raises."""
    marked = mark_voids(
        values,
        nodata=nodata,
        raster_path=raster_path,
        in_bounds=in_bounds,
        void_log=void_log,
    )
    return interpolate_voids(marked, coords)
