"""The anchor/role object model (ARCH §7.8, `[NEW v2.0]`). PRD FR106, FR110, Story O1.

An Author **promotes** a candidate, a cluster proposal, or a hand-placed location into
an **anchor** — one object per place, carrying a **role set** (narrative, provision,
station) rather than a single type. The national-monument case is the reason the set
exists: one anchor holds a narrative role (the statue) and a provision role
(restrooms, water), with one arrival and one pin, because a type field cannot express
both at once.

This module is deliberately self-contained (no import from `plotlines_core.trips
.payload`, and none the other way) even though its shapes mirror that module's
conventions closely: `trips.payload.Trip` will hold a `list[Anchor]` once wired in, so
a `payload -> content` import there must not close a `content -> payload` cycle back.
The handful of helpers duplicated below (`new_id`, `_finite`, coordinate rounding) are
kept in lockstep with `trips.payload`'s versions by convention, not by import.

Authority for the wire shape is `docs/schemas/trip_payload.schema.json`'s `anchor`,
`role`, `role_kind`, `reveal_policy`, and `anchor_provenance` $defs — where this module
and the schema disagree, the schema wins (ARCH D28).

Deliberately absent from `Role` and reserved for later stories, per ARCH §7.8's own
note that the four properties shown there are "the whole point," not the full set:
station activity (FR109 / O4) and arc stage (FR38 / O6). Each adds its own field to
this module, the schema, and the Dart mirror together when it is built — not guessed
ahead of time here.

`Role.coord` (FR107 / O2) is a role's optional point offset from its anchor, so the
overlook 400 m up the spur can trigger at the overlook rather than the parking lot at
the anchor's own coord. `Anchor.area` / `Role.area` (FR108, FR126 / O3) are this
module's polygon geometry: a historic district, an arboretum, or a main-street block
is first-class rather than approximated as a point with a radius. `Anchor.area` also
serves as a cluster boundary (in place of point-plus-radius) via
`Anchor.contains_point`, and entry into it is the trigger event FR126 specifies for
the (not-yet-built) field runtime — the debounce for that event lives client-side
(`client/lib/domain/area_trigger.dart`), since only the client tracks live position.
"""

from __future__ import annotations

import math
import uuid
from dataclasses import dataclass, field

#: [lon, lat] (RFC 7946), optionally [lon, lat, elevation_m].
Coord = list[float]

#: A closed linear ring: >= 4 positions, first == last (RFC 7946).
Ring = list[Coord]

#: FR108 / O3 — where a polygon area came from: drawn by the Author, or adopted
#: from a source feature's own area geometry at promotion. Never "solved" — no
#: engine produces an anchor's area the way one produces a route.
AREA_SOURCES = ("authored", "imported")

#: FR106 / O1 — a role set, not a type field.
ROLE_KINDS = ("narrative", "provision", "station")

#: FR114 / O5. `reveal` may be left unset at promotion (O1's AC: "set here or
#: later"); when an Author does set it, it must be one of these.
REVEAL_POLICIES = ("always_visible", "on_arrival")

#: FR106 / O1 — where a promoted anchor came from. Copied at promotion, never a
#: live reference (ARCH §4.2, P10).
PROVENANCE_KINDS = ("candidate", "cluster", "hand_placed")


def new_id() -> str:
    return str(uuid.uuid4())


def _finite(value: float, what: str) -> float:
    out = float(value)
    if not math.isfinite(out):
        raise ValueError(f"non-finite number in {what}: {value!r}")
    return out


def _coord(value: Coord, what: str) -> Coord:
    if not 2 <= len(value) <= 3:
        raise ValueError(f"{what} has {len(value)} elements; coord needs 2 or 3")
    return [round(_finite(v, f"{what}[{i}]"), 7) for i, v in enumerate(value)]


def _signed_area(ring: Ring) -> float:
    """Twice the signed area (shoelace formula); sign gives winding —
    positive is counter-clockwise. Only lon/lat are used (elevation, if
    present, plays no part in winding)."""
    total = 0.0
    for i in range(len(ring) - 1):
        x1, y1 = ring[i][0], ring[i][1]
        x2, y2 = ring[i + 1][0], ring[i + 1][1]
        total += x1 * y2 - x2 * y1
    return total


def _ring(value: Ring, what: str, *, exterior: bool) -> Ring:
    if len(value) < 4:
        raise ValueError(f"{what} has {len(value)} positions; a ring needs at least 4")
    checked = [_coord(c, f"{what}[{i}]") for i, c in enumerate(value)]
    if checked[0][:2] != checked[-1][:2]:
        raise ValueError(f"{what} is not closed: first position must equal last")
    # ARCH §11.6 / D37 — fixed winding so the content digest stays stable
    # across producers: exterior rings counter-clockwise, holes clockwise
    # (RFC 7946 §3.1.6's right-hand rule), normalised rather than rejected
    # so an Author's drawing order never matters.
    area = _signed_area(checked)
    wrong_winding = (area < 0) if exterior else (area > 0)
    if wrong_winding:
        checked = list(reversed(checked))
    return checked


@dataclass
class Polygon:
    """FR108, FR126 / O3 — RFC 7946 Polygon. `coordinates` is one or more
    closed rings (first exterior, any further ones holes). `source` mirrors
    `line_string`'s vocabulary minus `solved`: `authored` (Author-drawn) or
    `imported` (adopted from a source feature's own area geometry)."""

    coordinates: list[Ring]
    source: str = "authored"

    def __post_init__(self) -> None:
        if self.source not in AREA_SOURCES:
            raise ValueError(f"polygon source {self.source!r} not in {AREA_SOURCES}")
        if not self.coordinates:
            raise ValueError("polygon.coordinates needs at least one ring")

    def to_dict(self) -> dict:
        rings = [_ring(r, f"polygon.coordinates[{i}]", exterior=i == 0)
                 for i, r in enumerate(self.coordinates)]
        return {"type": "Polygon", "coordinates": rings, "source": self.source}

    def contains_point(self, point: Coord) -> bool:
        """Ray-casting point-in-polygon: inside the exterior ring and outside
        every hole. This is the mechanism FR108's "area can serve as a
        cluster boundary instead of point-plus-radius" and FR126's "entry
        into the polygon is a trigger event" both resolve down to."""
        rings = self.to_dict()["coordinates"]
        exterior, holes = rings[0], rings[1:]
        if not _ring_contains_point(exterior, point):
            return False
        return not any(_ring_contains_point(hole, point) for hole in holes)


def _ring_contains_point(ring: Ring, point: Coord) -> bool:
    x, y = point[0], point[1]
    inside = False
    n = len(ring) - 1  # last position repeats the first; walk n edges
    for i in range(n):
        x1, y1 = ring[i][0], ring[i][1]
        x2, y2 = ring[i + 1][0], ring[i + 1][1]
        if (y1 > y) != (y2 > y):
            x_at_y = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x < x_at_y:
                inside = not inside
    return inside


@dataclass
class MediaRef:
    """Mirrors `trips.payload.MediaRef` — duplicated, not imported; see module doc."""

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
            "duration_s": None if self.duration_s is None else _finite(
                self.duration_s, "media_ref.duration_s"),
        }


@dataclass
class Role:
    """FR106, FR107, FR110 / O1, O2 — one entry in an anchor's role set.

    `reveal` and content (`title`/`note`/`media`) may be left unset at promotion and
    decided later (O1's AC) — nothing here defaults `reveal` on the Author's behalf;
    that judgment (provision defaults always-visible, hazard/crux is never gated) is
    O5's (FR114, FR115), applied by the client's `RevealResolver` at read time, not
    stamped into this object.

    `coord` (FR107 / O2) is the role's own optional point offset from its anchor.
    `None` is the common case an anchor with no offsets must cost nothing for (O2's
    AC) — trigger and rendering code reads `Anchor.role_geometry(role)`, never this
    field directly, so that fallback lives in exactly one place.

    `area` (FR108 / O3) is the same fallback shape as `coord`, one level up: a
    role's own polygon offset from its anchor's area — `Anchor.role_area(role)`
    is the one place that fallback lives, mirroring `role_geometry`.

    `hazard` (FR115 / O5) marks this role a hazard or technical-crux warning,
    orthogonal to `kind` — a station, a narrative beat, or a provision can all be
    the thing an Author needs to flag as safety-critical. FR115 is a hard
    constraint ("cannot be set otherwise by any Author"), so `hazard=True` paired
    with `reveal="on_arrival"` is rejected here rather than merely discouraged;
    the resolver-side half of the exemption (forcing the *effective* policy to
    always-visible even when `reveal` is left unset) is the client's, since only
    the client has a resolver yet.
    """

    kind: str
    id: str = field(default_factory=new_id)
    coord: Coord | None = None
    area: Polygon | None = None
    reveal: str | None = None
    title: str | None = None
    note: str | None = None
    media: list[MediaRef] = field(default_factory=list)
    hazard: bool = False

    def __post_init__(self) -> None:
        if self.kind not in ROLE_KINDS:
            raise ValueError(f"role kind {self.kind!r} not in {ROLE_KINDS}")
        if self.reveal is not None and self.reveal not in REVEAL_POLICIES:
            raise ValueError(f"reveal policy {self.reveal!r} not in {REVEAL_POLICIES}")
        if self.hazard and self.reveal == "on_arrival":
            raise ValueError(
                f"role {self.id}: FR115 forbids a hazard/technical-crux role from "
                "being set on_arrival — hazards are always visible, enforced in the model"
            )

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "kind": self.kind,
            "coord": None if self.coord is None else _coord(self.coord, "role.coord"),
            "area": None if self.area is None else self.area.to_dict(),
            "reveal": self.reveal,
            "title": self.title,
            "note": self.note,
            "media": [m.to_dict() for m in self.media] or None,
            # FR115 / O5 — always written (never pruned at False), the same
            # treatment `Polygon.source` gets: a flag this consequential should
            # never be ambiguous between "false" and "absent."
            "hazard": self.hazard,
        }


@dataclass
class AnchorProvenance:
    """§4.2 / P10 — copied at promotion, never a live reference back into the
    candidate cache. `source_id` is carried only so a second promotion of the same
    candidate can be recognised in the current session; it is never dereferenced."""

    kind: str
    source_id: str | None = None
    layer: str | None = None
    tags: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.kind not in PROVENANCE_KINDS:
            raise ValueError(f"provenance kind {self.kind!r} not in {PROVENANCE_KINDS}")

    def to_dict(self) -> dict:
        return {
            "kind": self.kind,
            "source_id": self.source_id,
            "layer": self.layer,
            "tags": dict(self.tags) or None,
        }


@dataclass
class Anchor:
    """FR106, FR110, FR108 / O1, O3 — a promoted place: one object per place,
    carrying a role set (ARCH decision D-A). Raises on an empty role set rather
    than letting a roleless anchor — the exact "type field" bug the role-set
    design exists to rule out — reach the payload.

    `coord` is always required — a representative point (§4.2's promotion still
    stamps one even for an area anchor) — and `area` (FR108 / O3) is additionally
    set when the place is a district, block, or reserve rather than a pin.
    """

    coord: Coord
    id: str = field(default_factory=new_id)
    title: str | None = None
    area: Polygon | None = None
    roles: list[Role] = field(default_factory=list)
    provenance: AnchorProvenance | None = None

    def role_geometry(self, role: Role) -> Coord:
        """FR107 / O2 — the coord a trigger, marker, or export feature for
        `role` must use: the role's own offset if it carries one, otherwise
        this anchor's coord. This is the one place that fallback lives (ARCH
        §6.2: "the index is built over roles, not anchors" — a one-word
        change with a real consequence if it's read from the wrong spot)."""
        return role.coord if role.coord is not None else self.coord

    def role_area(self, role: Role) -> Polygon | None:
        """FR108 / O3 — the polygon a trigger, marker, or export feature for
        `role` must use, when one exists: the role's own area offset if it
        carries one, otherwise this anchor's own area, otherwise `None` (the
        role/anchor is a point, not an area). Mirrors `role_geometry`."""
        return role.area if role.area is not None else self.area

    def contains_point(self, point: Coord) -> bool:
        """FR108's "an area can serve as a cluster boundary instead of
        point-plus-radius": true when this anchor has an area and it contains
        `point`. An anchor with no area (the common, point-anchor case) never
        contains anything — it has no boundary to test against."""
        return self.area is not None and self.area.contains_point(point)

    def to_dict(self) -> dict:
        if not self.roles:
            raise ValueError(f"anchor {self.id}: FR106 requires at least one role")
        return {
            "id": self.id,
            "coord": _coord(self.coord, "anchor.coord"),
            "area": None if self.area is None else self.area.to_dict(),
            "title": self.title,
            "roles": [r.to_dict() for r in self.roles],
            "provenance": self.provenance.to_dict() if self.provenance else None,
        }
