"""One normalised record, and one adapter per source shape.

This module *is* the spike's second question. Issue #176 asks whether
normalisation needs a server tier — a "serverless edge proxy" that flattens
bespoke feeds into light JSON — which would be a **P3 design event**, since P3
enumerates exactly five things the hosted service does and normalisation is
not among them. The way to answer that with evidence rather than taste is to
write the adapters, then count what they cost and what they need.

`RoadEvent` is deliberately thin. It carries only what an annotation needs to
reach an edge and to be honest about its age: an identity, what kind of thing
it is, how much it impacts travel, where it is, when it applies, and when it
was observed. Everything richer stays in `raw` for the provider to carry
through if it wants — normalising *more* than the annotation needs is how a
normaliser becomes a schema of its own and then needs a server to run.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone

# ── The normalised record ────────────────────────────────────────────────

#: What an event does to travel, most to least restrictive. A **seed set with
#: its rule stated** (PRD D-L): the rule is "an impact this adapter does not
#: recognise normalises to `unknown`, never to `clear`" — an unrecognised
#: impact must never read as a confirmed-passable road (FR14's advisory rule).
IMPACT_ORDER = ("all-lanes-closed", "some-lanes-closed", "alternating-one-way",
                "flagging", "temporary-traffic-signal", "unknown", "none")


@dataclass(frozen=True)
class RoadEvent:
    """A condition affecting travel on some stretch of road, from any source."""

    id: str
    source_id: str
    kind: str                       # work-zone / detour / weather-advisory / ...
    impact: str                     # one of IMPACT_ORDER
    road_names: tuple[str, ...] = ()
    geometry: tuple[tuple[float, float], ...] = ()   # (lon, lat)
    geometry_kind: str = "none"     # line / polygon / none
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    observed_at: datetime | None = None
    description: str = ""
    raw: dict = field(default_factory=dict, repr=False)

    @property
    def locatable(self) -> bool:
        """Whether this event can be put on a map at all. An event that cannot
        is not a failure to report — it is a real fraction of every feed, and
        it must be counted rather than dropped silently."""
        return bool(self.geometry)

    def active_at(self, when: datetime) -> bool:
        if self.starts_at and when < self.starts_at:
            return False
        if self.ends_at and when > self.ends_at:
            return False
        return True


def _iso(value: str | None) -> datetime | None:
    if not value:
        return None
    text = str(value).strip().replace("Z", "+00:00")
    # WZDx publishers emit sub-second precision beyond `fromisoformat`'s
    # tolerance on 3.11 and below (".2911663+00:00" — seven digits).
    if "." in text:
        head, _, tail = text.partition(".")
        digits = "".join(c for c in tail if c.isdigit())[:6]
        rest = tail[len(digits):] if tail[len(digits):].startswith(("+", "-")) else ""
        if not rest:
            for i, c in enumerate(tail):
                if c in "+-":
                    rest = tail[i:]
                    break
        text = f"{head}.{digits or '0'}{rest}"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


# ── Adapter 1: WZDx (a standard, many publishers) ────────────────────────
#
# WZDx is FHWA's Work Zone Data Exchange specification. The whole adapter is
# below; there is no per-publisher branch in it, which is the point being
# measured.

_WZDX_IMPACT = {
    "all-lanes-closed": "all-lanes-closed",
    "some-lanes-closed": "some-lanes-closed",
    "alternating-one-way": "alternating-one-way",
    "flagging": "flagging",
    "temporary-traffic-signal": "temporary-traffic-signal",
    "all-lanes-open": "none",
    "unknown": "unknown",
}


def wzdx_licence_id(doc: dict) -> str:
    """The feed's own declared licence, or `""`. WZDx 4.x puts an optional
    `license` on `feed_info`; a publisher that omits it has declared nothing,
    and under D45 that is a refusal at registration rather than a guess."""
    return str((doc.get("feed_info") or {}).get("license") or "").strip()


def wzdx_events(doc: dict, source_id: str) -> list[RoadEvent]:
    """Every road event in a WZDx `RoadEventFeed`, normalised."""
    feed_updated = _iso((doc.get("feed_info") or {}).get("update_date"))
    out: list[RoadEvent] = []
    for feature in doc.get("features") or []:
        props = feature.get("properties") or {}
        core = props.get("core_details") or {}
        geom = feature.get("geometry") or {}
        coords, kind = _geojson_coords(geom)
        out.append(RoadEvent(
            id=str(feature.get("id") or props.get("road_event_id") or ""),
            source_id=source_id,
            kind=str(core.get("event_type") or "unknown"),
            impact=_WZDX_IMPACT.get(str(props.get("vehicle_impact") or ""), "unknown"),
            road_names=tuple(str(n) for n in (core.get("road_names") or []) if n),
            geometry=coords,
            geometry_kind=kind,
            starts_at=_iso(props.get("start_date")),
            ends_at=_iso(props.get("end_date")),
            observed_at=_iso(core.get("update_date")) or feed_updated,
            description=str(core.get("description") or core.get("name") or ""),
            raw=feature,
        ))
    return out


# ── Adapter 2: NWS active alerts (bespoke, and shaped nothing like WZDx) ──
#
# Same concept — "a condition that affects travel on these roads" — arriving
# with no road identity at all, geometry that is frequently `null`, and a
# severity vocabulary instead of a lane-impact one.

_NWS_IMPACT = {
    "Extreme": "all-lanes-closed",
    "Severe": "some-lanes-closed",
    "Moderate": "unknown",
    "Minor": "unknown",
    "Unknown": "unknown",
}


def nws_events(doc: dict, source_id: str) -> list[RoadEvent]:
    """Active NWS alerts, normalised to the same record.

    **Every alert here is `geometry: null` or a polygon, and never a road.**
    The mapping from severity to a travel impact is this adapter's own
    invention, which is exactly the kind of judgement a shared normalisation
    proxy would have to make on a contributor's behalf — see RESULTS §5.
    """
    out: list[RoadEvent] = []
    for feature in doc.get("features") or []:
        props = feature.get("properties") or {}
        coords, kind = _geojson_coords(feature.get("geometry") or {})
        out.append(RoadEvent(
            id=str(props.get("id") or feature.get("id") or ""),
            source_id=source_id,
            kind="weather-advisory",
            impact=_NWS_IMPACT.get(str(props.get("severity") or ""), "unknown"),
            road_names=(),
            geometry=coords,
            geometry_kind=kind,
            starts_at=_iso(props.get("onset") or props.get("effective")),
            ends_at=_iso(props.get("ends") or props.get("expires")),
            observed_at=_iso(props.get("sent")),
            description=str(props.get("event") or ""),
            raw=feature,
        ))
    return out


def nws_zone_refs(doc: dict) -> list[str]:
    """The `affectedZones` URLs an alert with no geometry of its own points
    at. Each is a **separate fetch** — the N+1 that makes this source the
    interesting one for the proxy question."""
    refs: list[str] = []
    for feature in doc.get("features") or []:
        if (feature.get("geometry") or None) is not None:
            continue
        refs.extend(str(z) for z in ((feature.get("properties") or {}).get("affectedZones") or []))
    return refs


# ── shared ───────────────────────────────────────────────────────────────


def _geojson_coords(geom: dict) -> tuple[tuple[tuple[float, float], ...], str]:
    """Flatten a GeoJSON geometry to a coordinate sequence and a kind. Only
    what the matcher needs: a line to run along, or a ring to fall inside."""
    gtype = str(geom.get("type") or "")
    coords = geom.get("coordinates")
    if not coords:
        return (), "none"
    if gtype == "LineString":
        return tuple((float(x), float(y)) for x, y, *_ in coords), "line"
    if gtype == "MultiLineString":
        flat = [p for part in coords for p in part]
        return tuple((float(x), float(y)) for x, y, *_ in flat), "line"
    if gtype == "MultiPoint":
        # WZDx permits a road event to be published as its endpoints rather
        # than as a shape. Two or more points still describe a stretch; a
        # single point does not describe anything but a location, and the
        # matcher has to treat the two differently (RESULTS §3).
        pts = tuple((float(x), float(y)) for x, y, *_ in coords)
        return pts, ("line" if len(pts) >= 2 else "point")
    if gtype == "Polygon":
        return tuple((float(x), float(y)) for x, y, *_ in coords[0]), "polygon"
    if gtype == "MultiPolygon":
        biggest = max(coords, key=lambda poly: len(poly[0]))
        return tuple((float(x), float(y)) for x, y, *_ in biggest[0]), "polygon"
    if gtype == "Point":
        x, y, *_ = coords
        return ((float(x), float(y)),), "point"
    return (), "none"
