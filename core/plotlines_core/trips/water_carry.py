"""Water-carry distance assembly — Story C9 (PRD FR25).

FR25's AC: "itineraries show water-carry distance between sources." A water
source is a `provision`-kind `Role` carrying `ProvisionDetail.water`
(`content.anchor`) — a promoted anchor, not a placed `Node` (contrast C5's
`node.amenities`, a lighter-weight waypoint tag with no reveal policy). This
module answers "how far apart are they, along the route the Character
actually rides/hikes/paddles" — a straight-line gap between two anchors would
understate a switchbacking climb and overstate a road that runs parallel to
the corridor.

There is no routing-layer link from an anchor to a position on the route yet
(FR8a's `via_anchors` — "a separate story," unbuilt). So this projects each
water anchor's own coordinate onto the day's already-solved geometry
(`Route.project`, the same nearest-point machinery `trips.cues` uses for
bearing and cue placement) rather than waiting on that story. A source too
far from the route to be "on it" is reported, never silently dropped —
FR46's honesty clause applies here exactly as it does to SPIKE-E's coverage
statements: a gap the Author cannot see is worse than an ugly one they can.

Pure data plus the geometry `trips.cues.Route` already carries — no graph, no
I/O, no service types (P1).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from plotlines_core.trips.cues import Route, haversine_m
from plotlines_core.trips.payload import Day, Trip, f

#: How far a water anchor's own coordinate may sit from the day's solved line
#: and still count as "on this day's route" for carry-distance purposes. No
#: measured basis yet (unlike SPIKE-E's surveyed thresholds) — generous enough
#: to catch a spigot set back from the trailhead, narrow enough that a town's
#: water tower a kilometre off-corridor is correctly reported as off-route
#: rather than folded into a gap that never happened on the ground.
SNAP_TOLERANCE_M = 300.0


@dataclass
class WaterCarrySource:
    """One water-source anchor: FR25's "tagged potable or filter-required,"
    carried alongside the id/title an itinerary or a cue sheet needs to place
    it."""

    anchor_id: str
    role_id: str
    coord: list[float]
    potable: bool
    title: str | None = None

    def to_dict(self) -> dict:
        return {
            "anchor_id": self.anchor_id, "role_id": self.role_id,
            "coord": list(self.coord), "potable": self.potable, "title": self.title,
        }


def collect_water_sources(trip: Trip) -> list[WaterCarrySource]:
    """Every water-source anchor on `trip`, in `Trip.anchors` order. A
    provision role with no `provision.water` set (a resupply-only stop, or a
    provision role with no structured detail yet) contributes nothing here —
    `trips.permits`-style "one traversal" for the water half of FR25."""
    out: list[WaterCarrySource] = []
    for anchor in trip.anchors:
        for role in anchor.roles:
            if role.kind != "provision" or role.provision is None:
                continue
            if role.provision.water is None:
                continue
            out.append(WaterCarrySource(
                anchor_id=anchor.id, role_id=role.id,
                coord=list(anchor.role_geometry(role)),
                potable=role.provision.water.potable,
                title=anchor.title,
            ))
    return out


@dataclass
class WaterCarryLeg:
    """The gap between two consecutive water sources along a day's route."""

    from_anchor_id: str
    to_anchor_id: str
    distance_m: float
    from_title: str | None = None
    to_title: str | None = None

    def to_dict(self) -> dict:
        return {
            "from_anchor_id": self.from_anchor_id, "to_anchor_id": self.to_anchor_id,
            "distance_m": round(f(self.distance_m), 1),
            "from_title": self.from_title, "to_title": self.to_title,
        }


@dataclass
class WaterCarryReport:
    """FR25 — one day's water-carry picture: the ordered legs between
    consecutive on-route sources, plus any water source this day's anchors
    named that could not be placed on the route (`SNAP_TOLERANCE_M`) — stated
    rather than silently excluded from the gaps above."""

    day_id: str
    day_index: int
    legs: list[WaterCarryLeg] = field(default_factory=list)
    off_route: list[WaterCarrySource] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "day_id": self.day_id, "day_index": self.day_index,
            "legs": [leg.to_dict() for leg in self.legs],
            "off_route": [w.to_dict() for w in self.off_route],
        }


def _day_route(day: Day) -> Route | None:
    """The day's segments, concatenated into one polyline in segment order,
    each segment's cumulative distance continuing from the last — the same
    "one day, one line" shape a day's cue sheet already assumes. `None` when
    the day has no solved geometry to project against (an un-solved or
    rest day)."""
    coords: list[list[float]] = []
    cumulative: list[float] = []
    total = 0.0
    for segment in day.segments:
        if segment.geometry is None or len(segment.geometry.coordinates) < 2:
            continue
        pts = segment.geometry.coordinates
        start_index = 1 if coords and pts[0] == coords[-1] else 0
        for i in range(start_index, len(pts)):
            if i > 0:
                total += haversine_m(tuple(pts[i - 1]), tuple(pts[i]))
            coords.append(pts[i])
            cumulative.append(total)
    if len(coords) < 2:
        return None
    return Route(coords=coords, cumulative_m=cumulative, edges=[])


def water_carry_for_day(day: Day, water_sources: list[WaterCarrySource]) -> WaterCarryReport:
    """FR25 — this day's water-carry legs: every `water_sources` anchor
    projected onto the day's route (`Route.project`), kept when within
    `SNAP_TOLERANCE_M`, ordered by distance along, and turned into the gaps
    between consecutive ones. Sources too far from this day's route are
    reported in `.off_route` rather than silently skipped — most days, that
    is every source that belongs to a *different* day."""
    route = _day_route(day)
    if route is None:
        return WaterCarryReport(day_id=day.id, day_index=day.index, off_route=list(water_sources))

    placed: list[tuple[float, WaterCarrySource]] = []
    off_route: list[WaterCarrySource] = []
    for source in water_sources:
        along_m, offset_m = route.project(source.coord)
        if offset_m <= SNAP_TOLERANCE_M:
            placed.append((along_m, source))
        else:
            off_route.append(source)
    placed.sort(key=lambda pair: pair[0])

    legs = [
        WaterCarryLeg(
            from_anchor_id=placed[i][1].anchor_id,
            to_anchor_id=placed[i + 1][1].anchor_id,
            distance_m=placed[i + 1][0] - placed[i][0],
            from_title=placed[i][1].title,
            to_title=placed[i + 1][1].title,
        )
        for i in range(len(placed) - 1)
    ]
    return WaterCarryReport(day_id=day.id, day_index=day.index, legs=legs, off_route=off_route)


def water_carry_rollup(trip: Trip) -> dict:
    """The trip-wide water-carry payload: one `WaterCarryReport` per day,
    built from the single `collect_water_sources` traversal so every day
    reasons about the same anchor set."""
    sources = collect_water_sources(trip)
    return {
        "water_sources": [s.to_dict() for s in sources],
        "by_day": [water_carry_for_day(day, sources).to_dict() for day in trip.days],
    }
