"""The trip payload — `plotlines-core`'s plain-data return type (ARCH §6.1, §10.1).

Written by SPIKE-20. This module is the Python half of one shape that has to serve
three consumers without an adapter at any of them:

  * `plotlines-core`'s return type from `compose_day` / `split_trip` (ARCH §6.1)
  * drift's local `trip.payload` column (ARCH §10.3) and, later, the hosted
    `trip.payload JSONB` column (ARCH §10.1)
  * the Flutter domain layer's `Trip` / `Day` / `Segment` / `WeightProfile` (ARCH §9.1)

The authority for the shape is `docs/schemas/trip_payload.schema.json`; this file is
one implementation of it and is validated against it in CI-able form by the spike's
`run.py`. Where the two ever disagree, the schema wins — it is what the Dart side
reads too, and a schema only two of three consumers obey is prose again.

Four serialization rules are load-bearing rather than stylistic, and each is here
because SPIKE-20 measured the failure it prevents:

  1. **Absent means unset; `null` is never written.** `None` fields and empty
     collections are dropped on the way out. A `null` means "absent" in Python, "set
     to null" in Dart, and "JSON null" in Postgres — three readings of one byte.
  2. **Anything fractional is written as a float.** `round(x)` returns an `int` and
     `round(x, 1)` returns a `float`; the first silently retypes a distance, and a
     Dart `as double` cast on it throws at the boundary rather than at the mistake.
  3. **Coordinates are rounded to 7 decimals on write** (~1 cm, well past OSM's own
     precision). Full float repr costs ~40% of a real payload's bytes and buys
     nothing; rounding once at the producer means every later re-serialization is
     idempotent instead of drifting in the last digits.
  4. **Non-finite floats are refused.** `json.dumps` writes `NaN`/`Infinity` by
     default, which is not JSON, and Dart's `jsonDecode` rejects it — so a NaN that
     leaks out of an elevation void (FR88) would produce a file this codebase can
     write and the client cannot read.
"""

from __future__ import annotations

import json
import math
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone

from plotlines_core.content.anchor import Anchor

#: Bumped to 1.1.0 by SPIKE-21, which added `cue.retrace` — additive and
#: backward compatible, exactly the "schema patch" SPIKE-20 predicted a new
#: cue field would cost. Bumped to 1.2.0 by FR106/FR110 (Story O1), which
#: added `anchor`/`role` and the trip-level `anchors` array — additive in
#: the same sense: an absent `anchors` list still parses. Bumped to 1.3.0 by
#: FR107 (Story O2), which added `role.coord` — additive again: a role with
#: no `coord` still parses, and behaves exactly as a single point (O2's AC).
#: Bumped to 1.4.0 by FR108/FR126 (Story O3), which added `anchor.area` and
#: `role.area` — additive once more: an absent `area` still parses, and an
#: anchor/role with none behaves exactly as a point (O3 extends O2's AC to
#: polygons). Bumped to 1.5.0 by FR38 (Story O6), which added `role.arc` and
#: `segment.arc_stage` — arc now attaches to anchors (via their roles) and to
#: passages, not just to point `node`s (v1.0's reading). Additive again: an
#: absent `arc`/`arc_stage` still parses, and a role/segment with neither
#: carries no arc beat, same as today.
SCHEMA_VERSION = "1.5.0"

#: Decimal places kept on stored coordinates. 7 dp ≈ 1.1 cm at the equator.
COORD_PRECISION = 7

#: B2's adjacency warning threshold (story AC says "e.g. 500 m").
DEFAULT_GAP_WARN_M = 500.0

Coord = list[float]


# --------------------------------------------------------------------- helpers

def new_id() -> str:
    return str(uuid.uuid4())


def now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def f(value) -> float:
    """Coerce to a finite float, or raise. Rule 2 and rule 4, in one place."""
    out = float(value)
    if not math.isfinite(out):
        raise ValueError(f"non-finite number in payload: {value!r}")
    return out


def coord(lon: float, lat: float, elevation: float | None = None) -> Coord:
    """A stored [lon, lat(, elev)] in RFC 7946 order, rounded to `COORD_PRECISION`."""
    out = [round(f(lon), COORD_PRECISION), round(f(lat), COORD_PRECISION)]
    if elevation is not None:
        out.append(round(f(elevation), 2))
    return out


def coord_from_latlon(lat: float, lon: float) -> Coord:
    """The one adapter for core's internal (lat, lon) convention.

    osmnx, the graph loader and every solver signature in this package take
    (lat, lon); RFC 7946 — and therefore the payload — is [lon, lat]. Swapping them
    is the single most common geospatial defect there is, so it happens here and
    nowhere else.
    """
    return coord(lon, lat)


def prune(obj):
    """Drop `None` and empty collections, recursively. Rule 1.

    Booleans and zeros are kept: `False` and `0.0` are values an Author chose.
    """
    if isinstance(obj, dict):
        out = {}
        for key, value in obj.items():
            cleaned = prune(value)
            if cleaned is None:
                continue
            if isinstance(cleaned, (list, dict)) and not cleaned:
                continue
            out[key] = cleaned
        return out
    if isinstance(obj, list):
        return [prune(v) for v in obj]
    if isinstance(obj, float) and not math.isfinite(obj):
        raise ValueError("non-finite number in payload")
    return obj


def dumps(payload: dict, *, indent: int | None = None) -> str:
    """Serialize a payload in its canonical form.

    Canonical means three things, and each earns its place:

      * `sort_keys=True` — key order carries no meaning (rule 4), so fixing it makes
        two producers' bytes comparable. SPIKE-20 measured Python and Dart emitting
        byte-identical payloads once both sort; without it, `cue_sheet
        .derived_from.geometry_digest` could never be computed on one side and
        checked on the other.
      * compact separators — worth ~7% of a real payload's bytes, for nothing.
      * `allow_nan=False` — makes rule 4 a hard failure rather than invalid JSON
        nobody notices until a Dart client refuses the file.
    """
    separators = None if indent else (",", ":")
    return json.dumps(payload, indent=indent, allow_nan=False,
                      ensure_ascii=False, sort_keys=True, separators=separators)


# ---------------------------------------------------------------- value objects

@dataclass
class WeightProfile:
    """ARCH §6.3's profile in its Author-facing form (FR2–FR5, 0.0–5.0).

    Deliberately NOT `scoring.profile.WeightProfile`, which is the solver's internal
    0..1 form. The payload stores what the Author set; the solver derives what it
    needs (`w = ui / 5.0`, and `(ui - 2.5) / 2.5` for the bipolar climbing term).
    Storing both would be two representations of one preference, and they would
    disagree the first time one is edited without the other.
    """

    name: str = "balanced"
    climbing: float | None = None
    traffic: float | None = None
    surface: dict[str, float] = field(default_factory=dict)
    # FR5 (Story A4) / ARCH §7.3, D46: a single salience bias, no POI-type
    # parameter (layer selection already says what matters) and no separate
    # `detour_budget` (a second dial for the one intent this weight expresses).
    # Explore-mode only — compose simply never sends it.
    interest: float | None = None
    terrain_technicality: float | None = None

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "climbing": None if self.climbing is None else f(self.climbing),
            "traffic": None if self.traffic is None else f(self.traffic),
            "surface": {k: f(v) for k, v in self.surface.items()} or None,
            "interest": None if self.interest is None else f(self.interest),
            "terrain_technicality": (None if self.terrain_technicality is None
                                     else f(self.terrain_technicality)),
        }


@dataclass
class Band:
    """FR6 / A5 — an acceptance range on a realised attribute, not on a weight."""

    attribute: str
    minimum: float | None = None
    maximum: float | None = None
    source: str = "author"

    def to_dict(self) -> dict:
        return {
            "attribute": self.attribute,
            "min": None if self.minimum is None else f(self.minimum),
            "max": None if self.maximum is None else f(self.maximum),
            "source": self.source,
        }


@dataclass
class Violation:
    attribute: str
    realised: float
    shortfall: float

    def to_dict(self) -> dict:
        return {"attribute": self.attribute, "realised": f(self.realised),
                "shortfall": f(self.shortfall)}


@dataclass
class TargetDistance:
    value_m: float
    min_m: float | None = None
    max_m: float | None = None
    advisory: bool = False

    def to_dict(self) -> dict:
        return {
            "value_m": f(self.value_m),
            "min_m": None if self.min_m is None else f(self.min_m),
            "max_m": None if self.max_m is None else f(self.max_m),
            "advisory": self.advisory,
        }


@dataclass
class RouteMetrics:
    """The realised attributes. Mirrors `scoring.metrics.RouteMetrics` plus B7's
    time model, which is a trip-level concern the scorer has no opinion about."""

    distance_m: float = 0.0
    climb_m: float = 0.0
    descent_m: float = 0.0
    traffic: float | None = None
    unpaved_frac: float | None = None
    scenic_frac: float | None = None
    # FR5/FR6 (Story A5) — length-weighted mean realized salience, the
    # attribute A5's AC adds to what a band may bound.
    salience: float | None = None
    max_grade: float | None = None
    overlap_frac: float | None = None
    overlap_near_frac: float | None = None
    overlap_far_frac: float | None = None
    edge_count: int | None = None
    moving_time_s: float | None = None
    elapsed_time_s: float | None = None
    pace_source: str | None = None

    def to_dict(self) -> dict:
        out = {
            "distance_m": round(f(self.distance_m), 1),
            "climb_m": round(f(self.climb_m), 1),
            "descent_m": round(f(self.descent_m), 1),
        }
        for key in ("traffic", "unpaved_frac", "scenic_frac", "salience", "max_grade",
                    "overlap_frac", "overlap_near_frac", "overlap_far_frac"):
            value = getattr(self, key)
            out[key] = None if value is None else round(f(value), 4)
        out["edge_count"] = self.edge_count
        for key in ("moving_time_s", "elapsed_time_s"):
            value = getattr(self, key)
            out[key] = None if value is None else round(f(value), 1)
        out["pace_source"] = self.pace_source
        return out

    def merged(self, other: RouteMetrics) -> RouteMetrics:
        """Sum two metric sets, length-weighting the fractional terms.

        Averaging fractions unweighted is the classic roll-up bug: a 2 km connector
        at 90% traffic and a 60 km day at 5% do not average to 47.5%.
        """
        total = self.distance_m + other.distance_m

        def blend(name: str) -> float | None:
            a, b = getattr(self, name), getattr(other, name)
            if a is None and b is None:
                return None
            av, bv = (a or 0.0), (b or 0.0)
            return ((av * self.distance_m + bv * other.distance_m) / total
                    if total else 0.0)

        def add(name: str):
            a, b = getattr(self, name), getattr(other, name)
            if a is None and b is None:
                return None
            return (a or 0) + (b or 0)

        return RouteMetrics(
            distance_m=total,
            climb_m=self.climb_m + other.climb_m,
            descent_m=self.descent_m + other.descent_m,
            traffic=blend("traffic"),
            unpaved_frac=blend("unpaved_frac"),
            scenic_frac=blend("scenic_frac"),
            salience=blend("salience"),
            max_grade=(None if self.max_grade is None and other.max_grade is None
                       else max(self.max_grade or 0.0, other.max_grade or 0.0)),
            overlap_frac=blend("overlap_frac"),
            overlap_near_frac=blend("overlap_near_frac"),
            overlap_far_frac=blend("overlap_far_frac"),
            edge_count=add("edge_count"),
            moving_time_s=add("moving_time_s"),
            elapsed_time_s=add("elapsed_time_s"),
            pace_source=self.pace_source or other.pace_source,
        )


@dataclass
class Elevation:
    ascent_m: float = 0.0
    descent_m: float = 0.0
    min_m: float | None = None
    max_m: float | None = None
    samples: list[float] = field(default_factory=list)
    void_samples: int = 0
    source: str | None = None

    def to_dict(self) -> dict:
        return {
            "ascent_m": round(f(self.ascent_m), 1),
            "descent_m": round(f(self.descent_m), 1),
            "min_m": None if self.min_m is None else round(f(self.min_m), 1),
            "max_m": None if self.max_m is None else round(f(self.max_m), 1),
            "samples": [round(f(v), 1) for v in self.samples] or None,
            "void_samples": self.void_samples or None,
            "source": self.source,
        }


@dataclass
class MediaRef:
    kind: str
    path: str
    id: str = field(default_factory=new_id)
    caption: str | None = None
    bytes: int | None = None
    duration_s: float | None = None

    def to_dict(self) -> dict:
        return {
            "id": self.id, "kind": self.kind, "path": self.path,
            "caption": self.caption, "bytes": self.bytes,
            "duration_s": None if self.duration_s is None else f(self.duration_s),
        }


@dataclass
class Narration:
    """FR40/FR41 — authoring half only; playback is field execution (H2)."""

    trigger_distance_m: float
    media_id: str | None = None
    text: str | None = None

    def to_dict(self) -> dict:
        return {"trigger_distance_m": f(self.trigger_distance_m),
                "media_id": self.media_id, "text": self.text}


@dataclass
class ScheduledWindow:
    opens_at: str
    closes_at: str | None = None
    timezone: str | None = None
    detail: str | None = None

    def to_dict(self) -> dict:
        return {"opens_at": self.opens_at, "closes_at": self.closes_at,
                "timezone": self.timezone, "detail": self.detail}


@dataclass
class Node:
    kind: str
    coord: Coord
    id: str = field(default_factory=new_id)
    distance_along_m: float | None = None
    title: str | None = None
    note: str | None = None
    media: list[MediaRef] = field(default_factory=list)
    amenities: list[str] = field(default_factory=list)
    poi_type: str | None = None
    arc_stage: str | None = None
    narration: Narration | None = None
    instructions: str | None = None
    scheduled: ScheduledWindow | None = None

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "kind": self.kind,
            "coord": self.coord,
            "distance_along_m": (None if self.distance_along_m is None
                                 else round(f(self.distance_along_m), 1)),
            "title": self.title,
            "note": self.note,
            "media": [m.to_dict() for m in self.media] or None,
            "amenities": list(self.amenities) or None,
            "poi_type": self.poi_type,
            "arc_stage": self.arc_stage,
            "narration": self.narration.to_dict() if self.narration else None,
            "instructions": self.instructions,
            "scheduled": self.scheduled.to_dict() if self.scheduled else None,
        }


@dataclass
class Hazard:
    severity: str
    id: str = field(default_factory=new_id)
    title: str | None = None
    safety_note: str | None = None
    required_gear: list[str] = field(default_factory=list)
    coord: Coord | None = None
    distance_along_m: float | None = None
    node_id: str | None = None

    def to_dict(self) -> dict:
        return {
            "id": self.id, "severity": self.severity, "title": self.title,
            "safety_note": self.safety_note,
            "required_gear": list(self.required_gear) or None,
            "coord": self.coord,
            "distance_along_m": (None if self.distance_along_m is None
                                 else round(f(self.distance_along_m), 1)),
            "node_id": self.node_id,
        }


@dataclass
class LineString:
    coordinates: list[Coord]
    source: str = "solved"

    def to_dict(self) -> dict:
        return {"type": "LineString", "coordinates": self.coordinates,
                "source": self.source}


@dataclass
class Portage:
    geometry: LineString
    id: str = field(default_factory=new_id)
    exit_bank: str | None = None
    distance_m: float | None = None
    surface: str | None = None
    elevation_change_m: float | None = None
    mandatory: bool = False
    note: str | None = None

    def to_dict(self) -> dict:
        return {
            "id": self.id, "geometry": self.geometry.to_dict(),
            "exit_bank": self.exit_bank,
            "distance_m": None if self.distance_m is None else round(f(self.distance_m), 1),
            "surface": self.surface,
            "elevation_change_m": (None if self.elevation_change_m is None
                                   else round(f(self.elevation_change_m), 1)),
            "mandatory": self.mandatory,
            "note": self.note,
        }


@dataclass
class Alternate:
    kind: str
    geometry: LineString
    id: str = field(default_factory=new_id)
    label: str | None = None
    metrics: RouteMetrics | None = None
    elevation: Elevation | None = None
    diverges_at_m: float | None = None
    rejoins_at_m: float | None = None

    def to_dict(self) -> dict:
        return {
            "id": self.id, "kind": self.kind, "label": self.label,
            "geometry": self.geometry.to_dict(),
            "metrics": self.metrics.to_dict() if self.metrics else None,
            "elevation": self.elevation.to_dict() if self.elevation else None,
            "diverges_at_m": (None if self.diverges_at_m is None
                              else round(f(self.diverges_at_m), 1)),
            "rejoins_at_m": (None if self.rejoins_at_m is None
                             else round(f(self.rejoins_at_m), 1)),
        }


@dataclass
class SolveProvenance:
    engine_version: str | None = None
    graph_region: str | None = None
    solve_ms: float | None = None
    solver_calls: int | None = None
    solved_at: str | None = None
    closed: bool | None = None
    hit_via: bool | None = None
    #: Set by the client when an Author edits an input this geometry was solved from.
    #: SPIKE-20 added it: without a staleness flag the derived half of the payload
    #: (geometry, metrics, elevation) silently describes the previous route.
    stale: bool | None = None

    def to_dict(self) -> dict:
        return {
            "engine_version": self.engine_version,
            "graph_region": self.graph_region,
            "solve_ms": None if self.solve_ms is None else round(f(self.solve_ms), 1),
            "solver_calls": self.solver_calls,
            "solved_at": self.solved_at,
            "closed": self.closed,
            "hit_via": self.hit_via,
            "stale": self.stale,
        }


@dataclass
class Cue:
    """PLACEHOLDER — SPIKE-21 owns cue derivation. This is where its output lands."""

    sequence: int
    distance_along_m: float
    kind: str
    id: str = field(default_factory=new_id)
    instruction: str | None = None
    modifier: str | None = None
    bearing_deg: float | None = None
    ref_id: str | None = None
    segment_id: str | None = None
    #: SPIKE-21 — this cue stands on road the route has already ridden (the return leg
    #: of a via-node spur). Absent means fresh road.
    retrace: bool | None = None

    def to_dict(self) -> dict:
        return {
            "id": self.id, "sequence": self.sequence,
            "distance_along_m": round(f(self.distance_along_m), 1),
            "kind": self.kind, "instruction": self.instruction,
            "modifier": self.modifier,
            "bearing_deg": None if self.bearing_deg is None else round(f(self.bearing_deg), 1),
            "ref_id": self.ref_id, "segment_id": self.segment_id,
            "retrace": self.retrace,
        }


@dataclass
class CueSheet:
    generated_at: str
    cues: list[Cue] = field(default_factory=list)
    generator: str | None = None
    segment_ids: list[str] = field(default_factory=list)
    geometry_digest: str | None = None

    def to_dict(self) -> dict:
        derived = {"segment_ids": list(self.segment_ids) or None,
                   "geometry_digest": self.geometry_digest}
        return {
            "generated_at": self.generated_at,
            "generator": self.generator,
            "derived_from": derived,
            "cues": [c.to_dict() for c in self.cues],
        }


@dataclass
class LimitBreach:
    mode: str
    bound: str
    limit_m: float
    realised_m: float
    day_id: str | None = None

    def to_dict(self) -> dict:
        return {"mode": self.mode, "bound": self.bound,
                "limit_m": f(self.limit_m), "realised_m": round(f(self.realised_m), 1),
                "day_id": self.day_id}


@dataclass
class RollUp:
    total: RouteMetrics | None = None
    by_mode: dict[str, RouteMetrics] = field(default_factory=dict)
    limit_breaches: list[LimitBreach] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "total": self.total.to_dict() if self.total else None,
            "by_mode": {k: v.to_dict() for k, v in self.by_mode.items()} or None,
            "limit_breaches": [b.to_dict() for b in self.limit_breaches] or None,
        }


# ------------------------------------------------------------------ aggregates

@dataclass
class Segment:
    """FR10 / B1. One routed or Author-drawn leg — the "passage" FR38/O6 names.

    `arc_stage` (FR38 / O6) is this passage's own stage in the day's story,
    distinct from any arc stage on a `Node` along it: the long grind between
    two anchors can itself be the rising action, not just the places at
    either end. One of `content.anchor.ARC_STAGES`, or `None` for a segment
    that carries no arc beat of its own (the common case).
    """

    mode: str
    shape: str
    id: str = field(default_factory=new_id)
    title: str | None = None
    start: Coord | None = None
    end: Coord | None = None
    via: list[Coord] = field(default_factory=list)
    target_distance: TargetDistance | None = None
    bands: list[Band] = field(default_factory=list)
    violations: list[Violation] = field(default_factory=list)
    weights: WeightProfile | None = None
    geometry: LineString | None = None
    metrics: RouteMetrics | None = None
    elevation: Elevation | None = None
    nodes: list[Node] = field(default_factory=list)
    alternates: list[Alternate] = field(default_factory=list)
    hazards: list[Hazard] = field(default_factory=list)
    portages: list[Portage] = field(default_factory=list)
    solve: SolveProvenance | None = None
    arc_stage: str | None = None

    def to_dict(self) -> dict:
        return {
            "id": self.id, "title": self.title, "mode": self.mode,
            "shape": self.shape, "start": self.start, "end": self.end,
            "via": list(self.via) or None,
            "target_distance": (self.target_distance.to_dict()
                                if self.target_distance else None),
            "bands": [b.to_dict() for b in self.bands] or None,
            "violations": [v.to_dict() for v in self.violations] or None,
            "weights": self.weights.to_dict() if self.weights else None,
            "geometry": self.geometry.to_dict() if self.geometry else None,
            "metrics": self.metrics.to_dict() if self.metrics else None,
            "elevation": self.elevation.to_dict() if self.elevation else None,
            "nodes": [n.to_dict() for n in self.nodes] or None,
            "alternates": [a.to_dict() for a in self.alternates] or None,
            "hazards": [h.to_dict() for h in self.hazards] or None,
            "portages": [p.to_dict() for p in self.portages] or None,
            "solve": self.solve.to_dict() if self.solve else None,
            "arc_stage": self.arc_stage,
        }


@dataclass
class Transition:
    """FR12 / B3 — belongs to the day, not to either segment it joins."""

    from_segment_id: str
    to_segment_id: str
    id: str = field(default_factory=new_id)
    from_mode: str | None = None
    to_mode: str | None = None
    node: Node | None = None
    gap_m: float | None = None
    gap_warning: bool = False

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "from_segment_id": self.from_segment_id,
            "to_segment_id": self.to_segment_id,
            "from_mode": self.from_mode, "to_mode": self.to_mode,
            "node": self.node.to_dict() if self.node else None,
            "gap_m": None if self.gap_m is None else round(f(self.gap_m), 1),
            "gap_warning": self.gap_warning,
        }


@dataclass
class Day:
    """FR18 / C2. A rest day is a day with no segments, not a different type."""

    index: int
    kind: str = "route"
    id: str = field(default_factory=new_id)
    roles: list[str] = field(default_factory=list)
    date: str | None = None
    title: str | None = None
    note: str | None = None
    location: Coord | None = None
    segments: list[Segment] = field(default_factory=list)
    transitions: list[Transition] = field(default_factory=list)
    nodes: list[Node] = field(default_factory=list)
    hazards: list[Hazard] = field(default_factory=list)
    limits: dict[str, dict[str, float]] = field(default_factory=dict)
    weights: WeightProfile | None = None
    metrics: RollUp | None = None
    cue_sheet: CueSheet | None = None

    def to_dict(self) -> dict:
        return {
            "id": self.id, "index": self.index, "kind": self.kind,
            "roles": list(self.roles) or None, "date": self.date,
            "title": self.title, "note": self.note, "location": self.location,
            "segments": [s.to_dict() for s in self.segments] or None,
            "transitions": [t.to_dict() for t in self.transitions] or None,
            "nodes": [n.to_dict() for n in self.nodes] or None,
            "hazards": [h.to_dict() for h in self.hazards] or None,
            "limits": {m: {k: f(v) for k, v in b.items()}
                       for m, b in self.limits.items()} or None,
            "weights": self.weights.to_dict() if self.weights else None,
            "metrics": self.metrics.to_dict() if self.metrics else None,
            "cue_sheet": self.cue_sheet.to_dict() if self.cue_sheet else None,
        }


@dataclass
class Attribution:
    source: str
    licence: str
    credit: str
    url: str | None = None

    def to_dict(self) -> dict:
        return {"source": self.source, "licence": self.licence,
                "credit": self.credit, "url": self.url}


@dataclass
class Provenance:
    produced_by: str | None = None
    app_version: str | None = None
    sidecar_version: str | None = None
    attribution: list[Attribution] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "produced_by": self.produced_by,
            "app_version": self.app_version,
            "sidecar_version": self.sidecar_version,
            "attribution": [a.to_dict() for a in self.attribution] or None,
        }


@dataclass
class Trip:
    """The canonical plotline (P8). What `trip.payload` holds, in full."""

    title: str
    id: str = field(default_factory=new_id)
    created_at: str = field(default_factory=now_stamp)
    updated_at: str = field(default_factory=now_stamp)
    duration: dict | None = None
    default_weights: WeightProfile | None = None
    day_limits: dict[str, dict[str, float]] = field(default_factory=dict)
    days: list[Day] = field(default_factory=list)
    anchors: list[Anchor] = field(default_factory=list)
    metrics: RollUp | None = None
    provenance: Provenance | None = None
    schema_version: str = SCHEMA_VERSION

    def to_dict(self) -> dict:
        defaults = {
            "weights": self.default_weights.to_dict() if self.default_weights else None,
            "day_limits": {m: {k: f(v) for k, v in b.items()}
                           for m, b in self.day_limits.items()} or None,
        }
        return prune({
            "schema_version": self.schema_version,
            "id": self.id,
            "title": self.title,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "duration": self.duration,
            "defaults": defaults,
            "days": [d.to_dict() for d in self.days],
            "anchors": [a.to_dict() for a in self.anchors] or None,
            "metrics": self.metrics.to_dict() if self.metrics else None,
            "provenance": self.provenance.to_dict() if self.provenance else None,
        })

    def to_json(self, *, indent: int | None = None) -> str:
        return dumps(self.to_dict(), indent=indent)
