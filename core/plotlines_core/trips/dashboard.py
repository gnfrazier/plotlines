"""The real-time planning dashboard (PRD FR31; Story D1 / MVP). ARCH §7.2
(`trips/` — "speeds/ETA"), §6.3.

FR31 asks for one panel that shows, and keeps showing as the Author works:

  * **distance and elevation** by passage, by day, by trip total, and by mode;
  * **with FR16**, moving time / elapsed time (station durations included) / ETA.

This module is the pure-data half — no graph, no I/O, no service types (P1).
`build_dashboard(trip, …)` is a cheap pure function over `trips.payload`
dataclasses: "updates on every add/edit/reorder" is satisfied by the caller
re-invoking it after each edit, and its output is deterministic in the trip it
is handed (the reorder tests pin this).

Aggregation reuses `trips.compose.roll_up`, so the dashboard's numbers are the
same length-weighted roll-up `compose_day` / `split_trip` write into the payload
— never a second implementation that could drift from it.

The **time model** here is deliberately small. FR16 / Story B7 (P1) owns the real
one — per-terrain speeds, an Author pace derived from an uploaded activity file,
an aggregated participant pace. What D1 needs, and all this provides, is:
`moving_time_s` from distance and a per-mode pace (a caller override, else the
system-default base speed from `multimodal.modes`, SPIKE-05), elapsed time as
moving time plus a caller-supplied station/hold duration (FR16b / O4 — the model
that produces those durations is not built yet, so the dashboard *accepts* them
rather than computing them), and an ETA as a day's or the trip's start time plus
its elapsed time.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone

from plotlines_core.multimodal.modes import base_speed_kmh
from plotlines_core.trips.compose import roll_up
from plotlines_core.trips.payload import (
    RollUp, RouteMetrics, Segment, Trip, f, now_stamp,
)

#: `RouteMetrics.pace_source` values this module sets. FR16's three pace
#: choices collapse, for the dashboard's purposes, to "the Author gave me
#: numbers" vs "I used the system default".
PACE_SYSTEM_DEFAULT = "system_default"
PACE_CUSTOM = "custom"

_SECONDS_PER_HOUR = 3600.0
_STAMP = "%Y-%m-%dT%H:%M:%SZ"


# --------------------------------------------------------------- time model

def moving_time_s(
    distance_m: float, mode: str, speeds: Mapping[str, float] | None = None
) -> float | None:
    """Seconds to cover `distance_m` at `mode`'s pace.

    A caller-supplied `speeds` entry (km/h — FR16's custom Author pace or the
    aggregated participant pace) wins; otherwise `mode`'s system-default base
    speed (`multimodal.modes.base_speed_kmh`). `None` when neither exists — a
    `transit` note leg carries an authored schedule, not a computed pace, and
    must not be handed a fabricated one.
    """
    kmh: float | None = None
    if speeds is not None and mode in speeds:
        kmh = speeds[mode]
    if kmh is None:
        kmh = base_speed_kmh(mode)
    if not kmh or kmh <= 0:
        return None
    metres_per_second = float(kmh) * 1000.0 / _SECONDS_PER_HOUR
    return distance_m / metres_per_second


def _parse_iso(stamp: str) -> datetime:
    text = stamp.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def eta(start_at: str, elapsed_s: float) -> str:
    """`start_at` (ISO 8601) plus `elapsed_s`, as a UTC `…Z` stamp."""
    finish = _parse_iso(start_at) + timedelta(seconds=float(elapsed_s))
    return finish.astimezone(timezone.utc).strftime(_STAMP)


# ------------------------------------------------------- timed roll-ups

def _timed_rollup(
    rollup: RollUp,
    *,
    speeds: Mapping[str, float] | None,
    hold_s: float,
    pace_source: str,
) -> RollUp:
    """A copy of `rollup` with moving/elapsed time filled in from per-mode
    distance and pace. Never mutates the input — `roll_up` can hand back the
    very `RouteMetrics` a segment owns when a mode has one passage, so every
    write here goes through `dataclasses.replace`.

    Per-mode lines carry moving time only; the station/hold duration is an
    at-a-place cost that belongs to no mode, so it lands once, on the scope
    total's elapsed time. If any contributing mode has no pace (a `transit`
    leg), the scope's *total* moving/elapsed time is left `None` rather than
    silently under-reported — the per-mode lines that do have a pace still
    show theirs.
    """
    if rollup.total is None:
        return rollup

    by_mode: dict[str, RouteMetrics] = {}
    total_moving = 0.0
    a_mode_has_no_pace = False
    for mode, metrics in (rollup.by_mode or {}).items():
        secs = moving_time_s(metrics.distance_m, mode, speeds)
        if secs is None:
            a_mode_has_no_pace = True
            by_mode[mode] = replace(metrics)
            continue
        by_mode[mode] = replace(
            metrics, moving_time_s=round(secs, 1), pace_source=pace_source
        )
        total_moving += secs

    if a_mode_has_no_pace:
        total = replace(rollup.total, moving_time_s=None, elapsed_time_s=None,
                        pace_source=None)
    else:
        elapsed = total_moving + max(hold_s, 0.0)
        total = replace(
            rollup.total,
            moving_time_s=round(total_moving, 1),
            elapsed_time_s=round(elapsed, 1),
            pace_source=pace_source,
        )
    return RollUp(total=total, by_mode=by_mode,
                  limit_breaches=list(rollup.limit_breaches))


def _day_rollup(day) -> RollUp:
    """A day's roll-up, recomputed live from its passages so a mid-edit trip
    is never shown a stale number — but keeping any `limit_breaches` a prior
    `split_trip` recorded (FR19 / C3, "reflected in the dashboard")."""
    base = roll_up(day.segments)
    if day.metrics is not None:
        base.limit_breaches = list(day.metrics.limit_breaches)
    return base


# ------------------------------------------------------------- dashboard

@dataclass
class PassageLine:
    """The active passage's own readout (D1's "active-passage" scope)."""

    segment_id: str
    mode: str
    title: str | None
    day_index: int | None
    metrics: RouteMetrics

    def to_dict(self) -> dict:
        return {
            "segment_id": self.segment_id,
            "mode": self.mode,
            "title": self.title,
            "day_index": self.day_index,
            "metrics": self.metrics.to_dict(),
        }


@dataclass
class DayLine:
    """One day's totals and by-mode split (D1's "day-total" scope)."""

    day_id: str
    index: int
    kind: str
    metrics: RollUp
    hold_s: float | None = None
    eta: str | None = None

    def to_dict(self) -> dict:
        return {
            "day_id": self.day_id,
            "index": self.index,
            "kind": self.kind,
            "metrics": self.metrics.to_dict(),
            "hold_s": None if self.hold_s is None else round(f(self.hold_s), 1),
            "eta": self.eta,
        }


@dataclass
class Dashboard:
    """FR31 — the whole panel, as one plain-data document a UI binds to."""

    trip_id: str
    trip_title: str
    active_passage: PassageLine | None
    days: list[DayLine]
    trip_total: RollUp
    pace_source: str
    trip_hold_s: float | None = None
    trip_eta: str | None = None
    generated_at: str = field(default_factory=now_stamp)

    def to_dict(self) -> dict:
        return {
            "trip_id": self.trip_id,
            "trip_title": self.trip_title,
            "generated_at": self.generated_at,
            "pace_source": self.pace_source,
            "active_passage": (self.active_passage.to_dict()
                               if self.active_passage else None),
            "days": [d.to_dict() for d in self.days],
            "trip_total": self.trip_total.to_dict(),
            "trip_hold_s": (None if self.trip_hold_s is None
                            else round(f(self.trip_hold_s), 1)),
            "trip_eta": self.trip_eta,
        }


def _find_segment(trip: Trip, segment_id: str) -> tuple[Segment, int]:
    for day in trip.days:
        for segment in day.segments:
            if segment.id == segment_id:
                return segment, day.index
    raise ValueError(f"segment {segment_id!r} is not in trip {trip.id!r}")


def build_dashboard(
    trip: Trip,
    *,
    active_segment_id: str | None = None,
    speeds: Mapping[str, float] | None = None,
    day_hold_s: Mapping[str, float] | None = None,
    day_start_at: Mapping[str, str] | None = None,
    trip_start_at: str | None = None,
) -> Dashboard:
    """Assemble the live planning dashboard for `trip` (FR31).

    Everything is recomputed from the trip's passages, so calling this again
    after any add / edit / reorder yields the panel's next state.

    `speeds` — per-mode km/h overrides (FR16's custom or aggregated pace); a
      mode not listed falls back to its system-default base speed.
    `day_hold_s` / `trip_start_at` / `day_start_at` — station/hold durations
      (FR16b / O4) keyed by day id, and start times for ETA. All optional:
      with none of them the dashboard is the distance/elevation panel D1's
      first AC line requires, and the time fields stay unset.
    """
    pace_source = PACE_CUSTOM if speeds else PACE_SYSTEM_DEFAULT
    day_hold_s = day_hold_s or {}
    day_start_at = day_start_at or {}

    days: list[DayLine] = []
    for day in trip.days:
        hold = float(day_hold_s.get(day.id, 0.0))
        timed = _timed_rollup(_day_rollup(day), speeds=speeds, hold_s=hold,
                              pace_source=pace_source)
        start = day_start_at.get(day.id)
        day_eta = (eta(start, timed.total.elapsed_time_s)
                   if start and timed.total and timed.total.elapsed_time_s is not None
                   else None)
        days.append(DayLine(
            day_id=day.id, index=day.index, kind=day.kind, metrics=timed,
            hold_s=hold if day.id in day_hold_s else None, eta=day_eta,
        ))

    all_segments = [s for day in trip.days for s in day.segments]
    trip_hold = sum(float(v) for v in day_hold_s.values()) if day_hold_s else 0.0
    trip_total = _timed_rollup(roll_up(all_segments), speeds=speeds,
                               hold_s=trip_hold, pace_source=pace_source)
    trip_eta = (eta(trip_start_at, trip_total.total.elapsed_time_s)
                if trip_start_at and trip_total.total
                and trip_total.total.elapsed_time_s is not None else None)

    active: PassageLine | None = None
    if active_segment_id is not None:
        segment, day_index = _find_segment(trip, active_segment_id)
        own = segment.metrics or RouteMetrics()
        secs = moving_time_s(own.distance_m, segment.mode, speeds)
        metrics = (replace(own, moving_time_s=round(secs, 1),
                           elapsed_time_s=round(secs, 1), pace_source=pace_source)
                   if secs is not None else replace(own))
        active = PassageLine(
            segment_id=segment.id, mode=segment.mode, title=segment.title,
            day_index=day_index, metrics=metrics,
        )

    return Dashboard(
        trip_id=trip.id,
        trip_title=trip.title,
        active_passage=active,
        days=days,
        trip_total=trip_total,
        pace_source=pace_source,
        trip_hold_s=trip_hold if day_hold_s else None,
        trip_eta=trip_eta,
    )
