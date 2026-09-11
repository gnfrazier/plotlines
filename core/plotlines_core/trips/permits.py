"""Permit / access-pass assembly — Story C10 (PRD FR26).

C10 attaches permits, land-access rules, and parking passes to a passage or a
promoted anchor, surfaced to Characters as a pre-trip checklist. Mirrors
`trips.hazards`' shape for the same reason that module exists: **one
traversal of every permit on the trip**, so a Logistics-tab list and a
pre-trip checklist can never disagree about what exists or where it stands.

`Trip.permits` is trip-scoped (not nested under a day or segment) — unlike a
hazard, a permit is not a point on a route, and a checklist is inherently a
whole-trip view, so there is nothing to gain from segment/day nesting the way
`Hazard` needs it for cue-sheet placement.

Pure data — no graph, no I/O, no service types (P1). Every input already sits
on the payload, so this needs no solve to answer.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from plotlines_core.trips.payload import Permit, Trip

#: Where a permit is pinned. `anchor` / `passage` when `segment_id` /
#: `anchor_id` is set; `trip` covers an all-trip obligation pinned to
#: neither (a state-park annual pass covering every day).
PERMIT_SCOPES = ("trip", "passage", "anchor")

#: FR26 — the checklist's own read of `PERMIT_STATUSES`: everything short of
#: `confirmed` is "still needs attention" before departure. `denied` is
#: included deliberately — a rejected permit is the opposite of resolved.
NEEDS_ATTENTION_STATUSES = ("required", "applied", "denied")


@dataclass
class LocatedPermit:
    """One permit on the trip, plus enough context to render or route to it.

    `scope` is one of `PERMIT_SCOPES`. `segment_id` / `anchor_id` are carried
    straight from the `Permit` (mutually exclusive there already);
    `anchor_title` is resolved against `Trip.anchors` when that anchor has one.
    """

    permit: Permit
    scope: str
    segment_id: str | None = None
    anchor_id: str | None = None
    anchor_title: str | None = None

    @property
    def needs_attention(self) -> bool:
        return self.permit.status in NEEDS_ATTENTION_STATUSES

    def to_dict(self) -> dict:
        return {
            "permit": self.permit.to_dict(),
            "scope": self.scope,
            "segment_id": self.segment_id,
            "anchor_id": self.anchor_id,
            "anchor_title": self.anchor_title,
            "needs_attention": self.needs_attention,
        }


def collect_permits(trip: Trip) -> list[LocatedPermit]:
    """Every permit on `trip`, in `Trip.permits`' own order — the one
    traversal a Logistics list and a pre-trip checklist both read, so they
    can never disagree about what exists or where it sits."""
    anchor_titles = {a.id: a.title for a in trip.anchors if a.title is not None}
    out: list[LocatedPermit] = []
    for permit in trip.permits:
        if permit.anchor_id is not None:
            scope = "anchor"
        elif permit.segment_id is not None:
            scope = "passage"
        else:
            scope = "trip"
        out.append(LocatedPermit(
            permit=permit, scope=scope,
            segment_id=permit.segment_id, anchor_id=permit.anchor_id,
            anchor_title=anchor_titles.get(permit.anchor_id) if permit.anchor_id else None,
        ))
    return out


def _order_key(located: LocatedPermit) -> tuple:
    permit = located.permit
    # Worst-first: a denied permit is the one thing on the checklist that
    # actually blocks the trip, so it sorts ahead of "still need to apply."
    rank = {"denied": 0, "required": 1, "applied": 2, "confirmed": 3}
    return (rank.get(permit.status, -1), permit.title.lower(), permit.id)


@dataclass
class PermitChecklist:
    """FR26 — the pre-trip checklist: every permit, ordered worst-first
    (denied, then required, then applied, then confirmed), plus the tally a
    Character-facing summary reads before showing the full list."""

    permits: list[LocatedPermit] = field(default_factory=list)

    @property
    def needs_attention_count(self) -> int:
        return sum(1 for lp in self.permits if lp.needs_attention)

    @property
    def is_clear(self) -> bool:
        """True when the trip carries permits and every one is confirmed.
        `True` on an empty trip too — nothing outstanding is nothing
        outstanding — so a caller wanting to know "is there anything to
        show" should check `permits`, not this."""
        return self.needs_attention_count == 0

    def to_dict(self) -> dict:
        return {
            "permits": [lp.to_dict() for lp in self.permits],
            "needs_attention_count": self.needs_attention_count,
            "is_clear": self.is_clear,
        }


def permit_checklist(trip: Trip) -> PermitChecklist:
    """FR26 — "Characters get a pre-trip permit/pass checklist," assembled
    from the one `collect_permits` traversal and ordered so the permits that
    still need attention (denied, then required, then applied) lead."""
    located = collect_permits(trip)
    located.sort(key=_order_key)
    return PermitChecklist(permits=located)
