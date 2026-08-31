"""Compose mode — the curated places *are* the route (PRD FR39, FR117, FR118;
Story E3 / A0, A0a; ARCH §7.7).

FR117 gives every day one of two planning postures:

  * **explore** — the Author supplies a distance, a shape, weights and bands; the
    engine returns a route that matches them and the Author discovers what is on it.
  * **compose** — the Author supplies a set of promoted anchors; the engine returns a
    route that *reaches* them and the Author learns its length.

FR39 [AMENDED v2.0] is the thesis of Epic E: compose is **not a variant feature**. It
is a primary path, and the curated places are "the organizing spine of the route".
This module is the pure-data half of that — no graph, no I/O, no service types
(P1) — sitting on top of `routing/` (which already reaches via-anchors and already
treats `target_distance is None` as a first-class input, ARCH §7.7 / `scoring.bands`).
It owns three things E3's AC names:

  1. `spine_waypoints` / `spine_solver_profile` — split an ordered anchor spine into
     the `(start, [via…], end)` the solver's `generate_segment` / `search_bands` take,
     and carry the Author's stored weights through `solver_profile_from_author` into
     that same call, so the engine both *reaches* the places (waypoints) and
     *flavours* the connections between them by the Author's dials (issue #202,
     ARCH §7.3 glossary). Distance stays an output (FR118) — no band is added.
  2. `compose_itinerary` — assemble the day as **places first**: an ordered list of
     `ItineraryStop`s (the anchors) with the `ItineraryLeg`s (the passages) *between*
     them, plus the compose-mode `DistanceOutcome`. This is the structure the
     itinerary, the cue sheet (`spine_cues`) and the recap (`recap_spine`) all read.
  3. `DistanceOutcome` — A0a / FR118. In compose mode distance is a **reported
     outcome, never a constraint and never a conflict**. `is_conflict` / `is_error`
     are `False` by construction: this must not route through `/segments/diagnose`
     (§8.2) or the shared error surface (M13), because presenting curation as a
     failure mode re-teaches the Author the wrong thing (ARCH §7.7).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from plotlines_core.content.anchor import ARC_STAGES, ROLE_KINDS, Anchor
from plotlines_core.scoring.profile import WeightProfile as SolverWeightProfile
from plotlines_core.trips.compose import solver_profile_for_day
from plotlines_core.trips.payload import (
    Cue, Segment, WeightProfile as AuthorWeightProfile, f,
)

#: FR117 — the two planning postures, one per day, switchable either way with no
#: work lost (FR119).
EXPLORE = "explore"
COMPOSE = "compose"
PLANNING_MODES = (EXPLORE, COMPOSE)

#: A0a / FR118, Flow 4's "drop, defer, split, accept" — the moves an Author has
#: when a composed route's length is not what they had in mind. Order is the
#: flow's. None of them is an error handler: they are ordinary editing.
DISPOSITIONS = ("drop", "defer", "split", "accept")


def assert_planning_mode(mode: str) -> str:
    if mode not in PLANNING_MODES:
        raise ValueError(f"planning mode {mode!r} not in {PLANNING_MODES}")
    return mode


def planning_mode_of(segment: Segment) -> str:
    """Which posture produced (or should produce) this passage. ARCH §7.7: a
    compose passage carries no `target_distance` (distance is its *output*); an
    explore passage carries a banded target (distance is its *input*)."""
    return EXPLORE if segment.target_distance is not None else COMPOSE


# --------------------------------------------------------------------- distance

@dataclass
class DistanceOutcome:
    """A0a / FR118 — the compose-mode distance conversation, as data.

    `target_m` is what the Author had in mind, if anything; in pure compose it is
    `None` and the route's length is simply reported. When a target is present the
    `deviation_*` fields quantify the miss and `dispositions` names the moves — but
    `is_conflict` and `is_error` stay `False` whatever the deviation, because this
    object must never reach `/segments/diagnose` or M13's typed error enum.
    """

    realised_m: float
    target_m: float | None = None
    #: Not `init=` fields an instance can flip — class-level facts the tests pin.
    is_conflict: bool = field(default=False, init=False)
    is_error: bool = field(default=False, init=False)

    @property
    def deviation_m(self) -> float | None:
        """Realised minus target — positive means the places made a longer day
        than intended. `None` when there is no target to miss."""
        if self.target_m is None:
            return None
        return round(self.realised_m - self.target_m, 1)

    @property
    def deviation_frac(self) -> float | None:
        if not self.target_m:  # None or 0.0 — nothing to take a fraction of
            return None
        return round((self.realised_m - self.target_m) / self.target_m, 4)

    @property
    def dispositions(self) -> tuple[str, ...]:
        """The Author's moves. With no target there is nothing to reconcile —
        the only move is to accept the length the places produced."""
        return DISPOSITIONS if self.target_m is not None else ("accept",)

    def to_dict(self) -> dict:
        return {
            "planning_mode": COMPOSE,
            "realised_m": round(f(self.realised_m), 1),
            "target_m": None if self.target_m is None else round(f(self.target_m), 1),
            "deviation_m": self.deviation_m,
            "deviation_frac": self.deviation_frac,
            "dispositions": list(self.dispositions),
            "is_conflict": self.is_conflict,
            "is_error": self.is_error,
        }


def _sum_distance(segments: list[Segment]) -> float:
    return sum(s.metrics.distance_m for s in segments if s.metrics is not None)


def distance_outcome(
    segments: list[Segment], *, target_m: float | None = None
) -> DistanceOutcome:
    """Roll a spine's passages up into their reported length (FR118)."""
    return DistanceOutcome(realised_m=round(_sum_distance(segments), 1), target_m=target_m)


# -------------------------------------------------------------------- itinerary

def _role_kinds_of(anchor: Anchor) -> list[str]:
    """The anchor's role kinds, in `ROLE_KINDS` order (a set, not a type — O1)."""
    present = {r.kind for r in anchor.roles}
    return [k for k in ROLE_KINDS if k in present]


def _arc_stages_of(anchor: Anchor) -> list[str]:
    """The arc beats this anchor's roles carry, in `ARC_STAGES` (story) order."""
    present = {r.arc for r in anchor.roles if r.arc}
    return [s for s in ARC_STAGES if s in present]


@dataclass
class ItineraryStop:
    """One place on the spine — an anchor, rendered as an itinerary entry."""

    anchor_id: str
    order: int
    title: str | None
    coord: list[float]
    roles: list[str]
    arc_stages: list[str]
    hazard: bool
    #: Cumulative distance along the spine to this stop. `None` — never a guessed
    #: `0.0` — once an earlier passage has no solved metrics (mirrors
    #: `trips.compose`'s "unmeasured, never zero" rule for adjacency gaps).
    distance_along_m: float | None
    #: FR116 — a narrative role held until arrival. Print and web read this to
    #: render the stop's shape without spilling its content.
    has_unrevealed_narrative: bool

    def to_dict(self) -> dict:
        return {
            "anchor_id": self.anchor_id,
            "order": self.order,
            "title": self.title,
            "coord": list(self.coord),
            "roles": list(self.roles),
            "arc_stages": list(self.arc_stages),
            "hazard": self.hazard,
            "distance_along_m": self.distance_along_m,
            "has_unrevealed_narrative": self.has_unrevealed_narrative,
        }


@dataclass
class ItineraryLeg:
    """The passage *between* two stops — subordinate to the places it joins.

    `hazards` (FR27 / C11) are this passage's own hazard/technical-crux markers,
    carried through so the itinerary highlights them alongside the map, the
    elevation profile and the cue sheet. They are never reveal-gated (FR115).
    """

    order: int  # sits between stop `order` and stop `order + 1`
    segment_id: str
    mode: str
    distance_m: float | None
    arc_stage: str | None
    planning_mode: str
    hazards: list[dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "order": self.order,
            "segment_id": self.segment_id,
            "mode": self.mode,
            "distance_m": self.distance_m,
            "arc_stage": self.arc_stage,
            "planning_mode": self.planning_mode,
            "hazards": list(self.hazards) or None,
        }


@dataclass
class Itinerary:
    """A day organised around its places (FR39). `stops` is the spine; `legs`
    are the connective tissue, one fewer than the stops."""

    planning_mode: str
    stops: list[ItineraryStop]
    legs: list[ItineraryLeg]
    distance: DistanceOutcome

    @property
    def spine(self) -> list[str]:
        """The anchor ids, in spine order — the day's organizing structure."""
        return [s.anchor_id for s in self.stops]

    def to_dict(self) -> dict:
        return {
            "planning_mode": self.planning_mode,
            "spine": self.spine,
            "stops": [s.to_dict() for s in self.stops],
            "legs": [leg.to_dict() for leg in self.legs],
            "distance": self.distance.to_dict(),
        }


def compose_itinerary(
    anchors: list[Anchor],
    segments: list[Segment],
    *,
    target_m: float | None = None,
    planning_mode: str = COMPOSE,
) -> Itinerary:
    """Assemble the day as places-first (E3's AC).

    `anchors` is the spine in the Author's chosen order — it is never reordered
    here. `segments` connects consecutive anchors, so there must be exactly one
    fewer of them. Each stop's `distance_along_m` is the running sum of the
    passages before it; the first stop sits at `0.0`, and any stop past an
    unrouted passage is left unmeasured rather than placed at a guess.
    """
    assert_planning_mode(planning_mode)
    if len(anchors) < 2:
        raise ValueError("a spine needs at least two places (FR39)")
    if len(segments) != len(anchors) - 1:
        raise ValueError(
            f"{len(anchors)} places need {len(anchors) - 1} connecting passages, "
            f"got {len(segments)}"
        )
    for anchor in anchors:
        if not anchor.roles:
            raise ValueError(f"anchor {anchor.id}: FR106 requires at least one role")

    stops: list[ItineraryStop] = []
    running = 0.0
    unmeasured = False
    for i, anchor in enumerate(anchors):
        if i == 0:
            along: float | None = 0.0
        elif unmeasured:
            along = None
        else:
            metrics = segments[i - 1].metrics
            if metrics is None:
                unmeasured = True
                along = None
            else:
                running += metrics.distance_m
                along = round(running, 1)
        stops.append(ItineraryStop(
            anchor_id=anchor.id,
            order=i,
            title=anchor.title,
            coord=list(anchor.coord),
            roles=_role_kinds_of(anchor),
            arc_stages=_arc_stages_of(anchor),
            hazard=any(r.hazard for r in anchor.roles),
            distance_along_m=along,
            has_unrevealed_narrative=any(
                r.kind == "narrative" and r.reveal == "on_arrival" for r in anchor.roles
            ),
        ))

    legs = [
        ItineraryLeg(
            order=i,
            segment_id=segment.id,
            mode=segment.mode,
            distance_m=(round(segment.metrics.distance_m, 1)
                        if segment.metrics is not None else None),
            arc_stage=segment.arc_stage,
            planning_mode=planning_mode_of(segment),
            hazards=[h.to_dict() for h in segment.hazards],
        )
        for i, segment in enumerate(segments)
    ]

    return Itinerary(
        planning_mode=planning_mode,
        stops=stops,
        legs=legs,
        distance=distance_outcome(segments, target_m=target_m),
    )


# ------------------------------------------------------------------- consumers

def spine_waypoints(
    anchors: list[Anchor],
) -> tuple[tuple[float, float], list[tuple[float, float]], tuple[float, float]]:
    """Split an anchor spine into the `(start, [via…], end)` the solver takes.

    Anchor coords are `[lon, lat]` (RFC 7946); every solver signature in
    `routing/` — `generate_segment`, `search_bands`, `generate_loop` — takes
    `(lat, lon)`. This is the one place that swap happens for compose mode.
    """
    if len(anchors) < 2:
        raise ValueError("a spine needs at least two places (FR39)")
    points = [(a.coord[1], a.coord[0]) for a in anchors]
    return points[0], points[1:-1], points[-1]


def spine_solver_profile(
    *,
    segment_weights: AuthorWeightProfile | None = None,
    day_weights: AuthorWeightProfile | None = None,
    trip_default_weights: AuthorWeightProfile | None = None,
) -> SolverWeightProfile:
    """The solver `WeightProfile` a composed passage is *flavoured* by — the
    companion to `spine_waypoints` (issue #202).

    A caller wires compose mode end to end with the pair::

        start, via, end = spine_waypoints(anchors)
        profile = spine_solver_profile(
            day_weights=day.weights, trip_default_weights=trip.default_weights
        )
        generate_segment(graph, start, end, profile, via=via, mode=mode)

    Precedence (segment → day → trip) and the Author→solver conversion both live in
    `trips.compose.solver_profile_for_day`, so explore and compose share exactly one
    conversion site (`scoring.profile.solver_profile_from_author`).

    Compose keeps distance an *output* (FR118): this adds no band, no
    `target_distance`, and never routes a deviation through `/segments/diagnose` or
    M13 (§7.7). It only changes *how* the fixed anchors are connected — traffic
    tolerance, surface, climbing. The salience bias stays inactive in compose
    whatever is stored (§7.7): a scalar competing with an explicit editorial choice
    is incoherent, so `interest` is forced back to its neutral default here.
    """
    profile = solver_profile_for_day(
        segment=segment_weights, day=day_weights, trip_default=trip_default_weights
    )
    if profile.interest:
        profile = profile.replace(interest=0.0)
    return profile


@dataclass
class RecapEntry:
    """One beat on FR73's narrative axis — a plot point the spine reached."""

    order: int
    anchor_id: str
    title: str | None
    arc_stages: list[str]
    distance_along_m: float | None

    def to_dict(self) -> dict:
        return {
            "order": self.order,
            "anchor_id": self.anchor_id,
            "title": self.title,
            "arc_stages": list(self.arc_stages),
            "distance_along_m": self.distance_along_m,
        }


def recap_spine(itinerary: Itinerary) -> list[RecapEntry]:
    """FR73 [AMENDED v2.0] narrative axis, planned half: which plot points the
    spine reaches and in what order.

    A stop counts as a plot point when it carries a narrative role or any arc
    beat. A stop that is *only* provision (water, toilets, a bail-out) is
    logistics, not story, and stays off this axis — it still appears in the
    itinerary and on the cue sheet, per FR133's shared register.
    """
    out: list[RecapEntry] = []
    for stop in itinerary.stops:
        if "narrative" in stop.roles or stop.arc_stages:
            out.append(RecapEntry(
                order=len(out),
                anchor_id=stop.anchor_id,
                title=stop.title,
                arc_stages=list(stop.arc_stages),
                distance_along_m=stop.distance_along_m,
            ))
    return out


def spine_cues(itinerary: Itinerary, *, start_sequence: int = 0) -> list[Cue]:
    """The curated places as cue-sheet entries (FR46/FR39).

    Turn-by-turn derivation from geometry is `trips.cues`' job; these are the
    POI layer that rides on top of it — one cue per place, at its distance along
    the spine. A stop whose distance could not be measured (an unrouted passage
    earlier in the spine) is skipped rather than pinned to a guessed zero.
    """
    last = len(itinerary.stops) - 1
    cues: list[Cue] = []
    sequence = start_sequence
    for stop in itinerary.stops:
        if stop.distance_along_m is None:
            continue
        kind = "start" if stop.order == 0 else "finish" if stop.order == last else "node"
        cues.append(Cue(
            sequence=sequence,
            distance_along_m=stop.distance_along_m,
            kind=kind,
            instruction=stop.title,
            ref_id=stop.anchor_id,
        ))
        sequence += 1
    return cues
