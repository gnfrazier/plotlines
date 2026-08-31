"""Day composition and trip splitting (ARCH §6.1, §6.2 `trips/`).

The two functions ARCH §6.1 sketches:

    compose_day(segments, transitions) -> Day
    split_trip(days, limits)           -> Trip

Both are pure functions over plain data (P1) — no I/O, no graph, no service types.
Their output is `trips.payload`'s dataclasses, which serialize to the one document
`docs/schemas/trip_payload.schema.json` defines. SPIKE-20's finding that shaped this
module: composition is where the *derived* parts of the payload get written — B2's
adjacency gap, C3's limit breaches, D1's roll-ups — and every one of them is a number
a UI would otherwise recompute at each call site, drifting from the number the
composer measured.
"""

from __future__ import annotations

import math

from plotlines_core.scoring.profile import (
    WeightProfile as SolverWeightProfile,
    solver_profile_from_author,
)
from plotlines_core.trips.payload import (
    Day, DEFAULT_GAP_WARN_M, LimitBreach, RollUp, RouteMetrics, Segment,
    Transition, Trip, WeightProfile,
)

_EARTH_R_M = 6_371_000.0


# ---------------------------------------------------- Author → solver weights (#202)


def resolve_author_weights(
    *,
    segment: WeightProfile | None = None,
    day: WeightProfile | None = None,
    trip_default: WeightProfile | None = None,
) -> WeightProfile | None:
    """The Author-facing `payload.WeightProfile` that governs a passage, resolved
    most-specific-wins (issue #202): a ``Segment.weights`` overrides its
    ``Day.weights``, which overrides the ``Trip.default_weights``. An unset level
    falls through to the next; all three unset yields ``None`` — which the solver
    reads as its own balanced default.

    Resolution is whole-profile, not field-by-field. "Most specific wins" is a
    choice *between* the profiles the Author actually set; a half-merged profile
    is one no Author ever inspected, and the payload has no field-level "unset vs.
    zero" for the composite to lean on.
    """
    for level in (segment, day, trip_default):
        if level is not None:
            return level
    return None


def solver_profile_for_day(
    *,
    segment: WeightProfile | None = None,
    day: WeightProfile | None = None,
    trip_default: WeightProfile | None = None,
) -> SolverWeightProfile:
    """Resolve the effective Author-facing weights (`resolve_author_weights`) and
    convert them to the solver profile in one step — the single Author→solver
    conversion site on the compose path (ARCH §7.3; risk A18 / issue #200; #202).

    `compose.py` stays pure data (P1): this returns the solver `WeightProfile` a
    caller hands to `routing.solve.generate_segment` at the seam where the compose
    flow already crosses into `routing/`. It never imports a graph or solves.
    """
    return solver_profile_from_author(
        resolve_author_weights(segment=segment, day=day, trip_default=trip_default)
    )


def haversine_m(a: list[float], b: list[float]) -> float:
    """Great-circle metres between two [lon, lat] coordinates."""
    lon1, lat1 = math.radians(a[0]), math.radians(a[1])
    lon2, lat2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * _EARTH_R_M * math.asin(min(1.0, math.sqrt(h)))


def _segment_end(segment: Segment) -> list[float] | None:
    if segment.geometry and segment.geometry.coordinates:
        return segment.geometry.coordinates[-1]
    return segment.end or segment.start


def _segment_start(segment: Segment) -> list[float] | None:
    if segment.geometry and segment.geometry.coordinates:
        return segment.geometry.coordinates[0]
    return segment.start


def roll_up(segments: list[Segment]) -> RollUp:
    """FR31 / D1 — totals overall and by mode."""
    total: RouteMetrics | None = None
    by_mode: dict[str, RouteMetrics] = {}
    for segment in segments:
        metrics = segment.metrics
        if metrics is None:
            continue
        total = metrics if total is None else total.merged(metrics)
        existing = by_mode.get(segment.mode)
        by_mode[segment.mode] = metrics if existing is None else existing.merged(metrics)
    return RollUp(total=total, by_mode=by_mode)


def compose_day(
    segments: list[Segment],
    transitions: list[Transition],
    *,
    index: int = 1,
    kind: str = "route",
    gap_warn_m: float = DEFAULT_GAP_WARN_M,
    **day_fields,
) -> Day:
    """Compose one day from ordered segments and the transitions between them.

    Transitions are passed in rather than derived: a mode change is an Author's
    decision with instructions attached (FR12/B3), not something a composer can infer
    from two segments' endpoints. What the composer *does* own is the measurement —
    each transition's `gap_m` and B2's warning flag are written here, against the
    segments actually being composed, so no later surface has to guess which two
    endpoints a transition sat between.
    """
    if kind == "rest" and segments:
        raise ValueError("a rest day holds no active route (FR18/C2)")

    order = {segment.id: position for position, segment in enumerate(segments)}
    by_id = {segment.id: segment for segment in segments}

    for transition in transitions:
        src, dst = by_id.get(transition.from_segment_id), by_id.get(transition.to_segment_id)
        if src is None or dst is None:
            raise ValueError(
                f"transition {transition.id} references a segment not in this day"
            )
        if order[dst.id] != order[src.id] + 1:
            raise ValueError(
                f"transition {transition.id} joins non-adjacent segments "
                f"({order[src.id]} → {order[dst.id]})"
            )
        transition.from_mode = transition.from_mode or src.mode
        transition.to_mode = transition.to_mode or dst.mode
        tail, head = _segment_end(src), _segment_start(dst)
        if tail and head:
            transition.gap_m = haversine_m(tail, head)
            transition.gap_warning = transition.gap_m > gap_warn_m

    day = Day(index=index, kind=kind, segments=list(segments),
              transitions=list(transitions), **day_fields)
    day.metrics = roll_up(segments)
    return day


def _ends_at_resolution(day: Day) -> bool:
    """FR38 / O6 — C3's "a day may close at a resolution-stage anchor rather
    than only at a distance threshold": true when the terminal node of the
    day's last segment carries `arc_stage == "resolution"`. Nodes are ordered
    by `distance_along_m` when it's set (falling back to list order for any
    that leave it unset, which sorts them first — the conservative reading:
    an unpositioned node is never assumed to be the terminal one)."""
    if not day.segments:
        return False
    nodes = day.segments[-1].nodes
    if not nodes:
        return False
    ordered = sorted(nodes, key=lambda n: (n.distance_along_m is None, n.distance_along_m or 0.0))
    return ordered[-1].arc_stage == "resolution"


def _breaches(day: Day, limits: dict[str, dict[str, float]]) -> list[LimitBreach]:
    """C3 — per-mode min/max distance per day, as data rather than a UI
    comparison. FR38 / O6: a day that closes at a resolution-stage anchor is
    exempt from a "min" breach — the day fell short of the band on purpose,
    at a deliberate narrative closing point, not by accident. "max" breaches
    still apply: the arc closing early doesn't excuse a day that ran long."""
    effective = {**limits, **day.limits}
    found: list[LimitBreach] = []
    if not day.metrics:
        return found
    closes_at_resolution = _ends_at_resolution(day)
    for mode, metrics in (day.metrics.by_mode or {}).items():
        band = effective.get(mode)
        if not band:
            continue
        low, high = band.get("min_m"), band.get("max_m")
        if low is not None and metrics.distance_m < low and not closes_at_resolution:
            found.append(LimitBreach(mode=mode, bound="min", limit_m=low,
                                     realised_m=metrics.distance_m, day_id=day.id))
        if high is not None and metrics.distance_m > high:
            found.append(LimitBreach(mode=mode, bound="max", limit_m=high,
                                     realised_m=metrics.distance_m, day_id=day.id))
    return found


def split_trip(
    days: list[Day],
    limits: dict[str, dict[str, float]] | None = None,
    *,
    title: str = "Untitled plotline",
    default_weights: WeightProfile | None = None,
    **trip_fields,
) -> Trip:
    """Assemble days into a trip, applying per-mode day limits (FR19 / C3).

    "Split" is ARCH §6.1's word for the operation and it is the wrong half of it:
    what this does is *assemble* — number the days, apply the limits, and roll the
    metrics up. Automatic day splitting (cutting a long route into days that fit the
    limits) is a separate operation this signature has room for and MVP does not
    require; C3 asks only that a breach be indicated.
    """
    limits = limits or {}
    ordered = sorted(days, key=lambda d: d.index)
    for position, day in enumerate(ordered, start=1):
        day.index = position
        day.metrics = day.metrics or roll_up(day.segments)
        day.metrics.limit_breaches = _breaches(day, limits)

    total: RouteMetrics | None = None
    by_mode: dict[str, RouteMetrics] = {}
    breaches: list[LimitBreach] = []
    for day in ordered:
        if not day.metrics:
            continue
        breaches.extend(day.metrics.limit_breaches)
        if day.metrics.total:
            total = (day.metrics.total if total is None
                     else total.merged(day.metrics.total))
        for mode, metrics in (day.metrics.by_mode or {}).items():
            existing = by_mode.get(mode)
            by_mode[mode] = metrics if existing is None else existing.merged(metrics)

    trip = Trip(title=title, days=ordered, day_limits=limits,
                default_weights=default_weights, **trip_fields)
    trip.metrics = RollUp(total=total, by_mode=by_mode, limit_breaches=breaches)
    trip.duration = trip.duration or {"day_count": len(ordered)}
    return trip
