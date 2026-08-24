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
area/polygon geometry (FR108 / O3), station activity (FR109 / O4), and arc stage
(FR38 / O6). Each adds its own field to this module, the schema, and the Dart mirror
together when it is built — not guessed ahead of time here.

`Role.coord` (FR107 / O2) is the one exception already present: a role's optional
point offset from its anchor, so the overlook 400 m up the spur can trigger at the
overlook rather than the parking lot at the anchor's own coord.
"""

from __future__ import annotations

import math
import uuid
from dataclasses import dataclass, field

#: [lon, lat] (RFC 7946), optionally [lon, lat, elevation_m]. Point-only for O1;
#: polygon geometry is O3's addition (FR108).
Coord = list[float]

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
    O5's (FR114, FR115), not O1's.

    `coord` (FR107 / O2) is the role's own optional point offset from its anchor.
    `None` is the common case an anchor with no offsets must cost nothing for (O2's
    AC) — trigger and rendering code reads `Anchor.role_geometry(role)`, never this
    field directly, so that fallback lives in exactly one place.
    """

    kind: str
    id: str = field(default_factory=new_id)
    coord: Coord | None = None
    reveal: str | None = None
    title: str | None = None
    note: str | None = None
    media: list[MediaRef] = field(default_factory=list)

    def __post_init__(self) -> None:
        if self.kind not in ROLE_KINDS:
            raise ValueError(f"role kind {self.kind!r} not in {ROLE_KINDS}")
        if self.reveal is not None and self.reveal not in REVEAL_POLICIES:
            raise ValueError(f"reveal policy {self.reveal!r} not in {REVEAL_POLICIES}")

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "kind": self.kind,
            "coord": None if self.coord is None else _coord(self.coord, "role.coord"),
            "reveal": self.reveal,
            "title": self.title,
            "note": self.note,
            "media": [m.to_dict() for m in self.media] or None,
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
    """FR106, FR110 / O1 — a promoted place: one object per place, carrying a role
    set (ARCH decision D-A). Raises on an empty role set rather than letting a
    roleless anchor — the exact "type field" bug the role-set design exists to
    rule out — reach the payload."""

    coord: Coord
    id: str = field(default_factory=new_id)
    title: str | None = None
    roles: list[Role] = field(default_factory=list)
    provenance: AnchorProvenance | None = None

    def role_geometry(self, role: Role) -> Coord:
        """FR107 / O2 — the coord a trigger, marker, or export feature for
        `role` must use: the role's own offset if it carries one, otherwise
        this anchor's coord. This is the one place that fallback lives (ARCH
        §6.2: "the index is built over roles, not anchors" — a one-word
        change with a real consequence if it's read from the wrong spot)."""
        return role.coord if role.coord is not None else self.coord

    def to_dict(self) -> dict:
        if not self.roles:
            raise ValueError(f"anchor {self.id}: FR106 requires at least one role")
        return {
            "id": self.id,
            "coord": _coord(self.coord, "anchor.coord"),
            "title": self.title,
            "roles": [r.to_dict() for r in self.roles],
            "provenance": self.provenance.to_dict() if self.provenance else None,
        }
