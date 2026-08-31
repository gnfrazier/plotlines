"""Hazard and technical-crux assembly — Story C11 (PRD FR27, FR115).

C11 places hazard/crux warnings on any route, transit leg, day, or anchor, with a
severity, a safety note, and required-gear callouts. Two of its acceptance criteria
are model responsibilities that outlive any one screen, so they live here rather
than in a presentation layer:

  1. **One traversal of every hazard on the trip, with where each one sits.**
     `collect_hazards` walks days, their segments (a route *or* a transit leg is a
     `Segment`), and anchor references, and returns each hazard tagged with its
     `scope`, `day_index`, and the ids needed to place it on a map, an elevation
     profile, an itinerary, or a cue sheet. Every hazard surface reads the same
     list, so they cannot disagree about what exists.

  2. **A distinct Character alert on sync for high-severity markers.**
     `sync_alerts` is `collect_hazards` filtered to `ALERTING_SEVERITIES`
     (`high`, `mandatory_reroute`) and ordered worst-first — the payload the
     client raises as an interrupt when a Character syncs or opens the trip,
     *before* they are standing on the hazard.

Nothing here is reveal-aware, by construction: a `Hazard` carries no reveal field
(`trips.payload.Hazard`), so there is no policy to consult and no way for an Author
to hide one (FR115). This module never imports `RevealResolver` and never will.

Pure data — no graph, no I/O, no service types (P1). Every input already sits on
the payload, so this needs no solve to answer.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from plotlines_core.trips.payload import (
    ALERTING_SEVERITIES,
    HAZARD_SEVERITIES,
    Hazard,
    Trip,
    f,
)

#: Where a hazard is pinned. `anchor` wins whenever `Hazard.anchor_id` is set
#: (it can be carried in either a day's or a segment's hazard list); otherwise a
#: hazard in a segment's list is `passage` and one in a day's list is `day`.
HAZARD_SCOPES = ("day", "passage", "anchor")

#: Sort key for severity, worst last in `HAZARD_SEVERITIES` — negated at use so
#: the worst hazard sorts first.
_SEVERITY_RANK = {name: i for i, name in enumerate(HAZARD_SEVERITIES)}


@dataclass
class LocatedHazard:
    """One hazard on the trip, plus enough context to render or route to it.

    `scope` is one of `HAZARD_SCOPES`. `day_index` is the 1-based day the hazard
    sits on. `segment_id` is set for a `passage`-scope hazard (and for an
    `anchor`-scope hazard that was carried in a segment's list). `anchor_id` /
    `anchor_title` are set for an `anchor`-scope hazard, the title resolved
    against `Trip.anchors` when that anchor is present.
    """

    hazard: Hazard
    scope: str
    day_index: int
    day_id: str
    segment_id: str | None = None
    anchor_id: str | None = None
    anchor_title: str | None = None

    @property
    def is_alerting(self) -> bool:
        """FR27 — this hazard raises a distinct Character alert on sync."""
        return self.hazard.is_alerting

    def to_dict(self) -> dict:
        return {
            "hazard": self.hazard.to_dict(),
            "scope": self.scope,
            "day_index": self.day_index,
            "day_id": self.day_id,
            "segment_id": self.segment_id,
            "anchor_id": self.anchor_id,
            "anchor_title": self.anchor_title,
        }


@dataclass
class SyncAlert:
    """A high-severity hazard, flattened into the shape the client raises as a
    distinct Character alert on sync (FR27). Ordered worst-first by
    `sync_alerts`; nothing in it is reveal-gated (FR115)."""

    hazard_id: str
    severity: str
    day_index: int
    scope: str
    title: str | None = None
    safety_note: str | None = None
    required_gear: list[str] = field(default_factory=list)
    segment_id: str | None = None
    anchor_id: str | None = None
    anchor_title: str | None = None
    distance_along_m: float | None = None
    coord: list[float] | None = None

    def to_dict(self) -> dict:
        return {
            "hazard_id": self.hazard_id,
            "severity": self.severity,
            "day_index": self.day_index,
            "scope": self.scope,
            "title": self.title,
            "safety_note": self.safety_note,
            "required_gear": list(self.required_gear) or None,
            "segment_id": self.segment_id,
            "anchor_id": self.anchor_id,
            "anchor_title": self.anchor_title,
            "distance_along_m": (None if self.distance_along_m is None
                                 else round(f(self.distance_along_m), 1)),
            "coord": list(self.coord) if self.coord is not None else None,
        }


def _located(hazard: Hazard, *, day_index: int, day_id: str,
             segment_id: str | None, anchor_titles: dict[str, str]) -> LocatedHazard:
    if hazard.anchor_id is not None:
        return LocatedHazard(
            hazard=hazard, scope="anchor", day_index=day_index, day_id=day_id,
            segment_id=segment_id, anchor_id=hazard.anchor_id,
            anchor_title=anchor_titles.get(hazard.anchor_id),
        )
    scope = "passage" if segment_id is not None else "day"
    return LocatedHazard(
        hazard=hazard, scope=scope, day_index=day_index, day_id=day_id,
        segment_id=segment_id,
    )


def collect_hazards(trip: Trip) -> list[LocatedHazard]:
    """Every hazard on `trip`, in reading order: day by day, and within a day
    the day-level hazards first, then each segment's, in segment order.

    This is the one traversal every hazard surface — map, elevation profile,
    itinerary, cue sheet, sync alert — is meant to read, so they can never
    disagree about which hazards a trip carries or where they sit.
    """
    anchor_titles = {a.id: a.title for a in trip.anchors if a.title is not None}
    out: list[LocatedHazard] = []
    for day in trip.days:
        for hazard in day.hazards:
            out.append(_located(hazard, day_index=day.index, day_id=day.id,
                                segment_id=None, anchor_titles=anchor_titles))
        for segment in day.segments:
            for hazard in segment.hazards:
                out.append(_located(hazard, day_index=day.index, day_id=day.id,
                                    segment_id=segment.id, anchor_titles=anchor_titles))
    return out


def _order_key(located: LocatedHazard) -> tuple:
    hazard = located.hazard
    return (
        -_SEVERITY_RANK.get(hazard.severity, -1),   # worst severity first
        located.day_index,                          # then earliest day
        hazard.distance_along_m is None,            # placed hazards before unplaced
        hazard.distance_along_m or 0.0,             # then by distance along
        (hazard.title or "").lower(),               # then stable by title
        hazard.id,                                  # then fully deterministic
    )


def sync_alerts(trip: Trip) -> list[SyncAlert]:
    """FR27 — the high-severity hazards on `trip`, flattened and ordered
    worst-first, as the distinct Character alert raised on sync.

    "High-severity" is `ALERTING_SEVERITIES` (`high` and `mandatory_reroute`).
    A `caution` hazard still appears everywhere a hazard appears; it just does
    not interrupt on sync. Order is: severity (worst first), then day, then
    distance along the route, then title — deterministic, because a Character
    who syncs the same trip twice must see the same alert list (no gamification,
    Brand Value 9).
    """
    alerting = [lh for lh in collect_hazards(trip)
                if lh.hazard.severity in ALERTING_SEVERITIES]
    alerting.sort(key=_order_key)
    return [
        SyncAlert(
            hazard_id=lh.hazard.id,
            severity=lh.hazard.severity,
            day_index=lh.day_index,
            scope=lh.scope,
            title=lh.hazard.title,
            safety_note=lh.hazard.safety_note,
            required_gear=list(lh.hazard.required_gear),
            segment_id=lh.segment_id,
            anchor_id=lh.anchor_id,
            anchor_title=lh.anchor_title,
            distance_along_m=lh.hazard.distance_along_m,
            coord=lh.hazard.coord,
        )
        for lh in alerting
    ]


def has_sync_alerts(trip: Trip) -> bool:
    """Whether `trip` carries any hazard that interrupts on sync — the cheap
    check a client makes before building the full `sync_alerts` payload."""
    return any(
        h.severity in ALERTING_SEVERITIES
        for day in trip.days
        for h in (*day.hazards, *(hz for s in day.segments for hz in s.hazards))
    )
