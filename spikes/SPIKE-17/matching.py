"""Event geometry → graph edges. The part `annotate_edges` actually has to do,
and the part ARCH §14.2's signature makes invisible.

A WZDx event is a `LineString` drawn by a DOT along a road, with a road *name*
and no OSM identity of any kind — no way id, no node ids, no reach code. To
influence `edge_cost` it has to become a set of `(u, v, k)` edge keys in a
graph built from a different data source with a different geometry. That is
map-matching, and every plugin edge source needs it.

**The method, and why it is this one.** Sample the event line, take every edge
within a metre tolerance, and keep the ones whose heading agrees. Bearing is
what separates "the work zone on the eastbound carriageway" from "the frontage
road 15 m away", and a distance-only match takes both. Road-name agreement is
computed but deliberately **not** required — it is reported as a coverage
number, because a name filter would hide how often the two sources disagree
about what a road is called, which is one of the things the spike is here to
measure.

Distance is metric via a local equirectangular scale rather than a projection
library — the same "good enough at MVP scale, cheap, no extra dependency"
call `curation/providers.py::_approx_area_m2` makes, and over a 30 km bbox the
error is well under the tolerance being tested.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from shapely.geometry import LineString, Point, Polygon
from shapely.strtree import STRtree

_EARTH_R_M = 6_371_000.0
#: Metres either side of a DOT line that still counts as the same road.
DEFAULT_TOLERANCE_M = 30.0
#: Degrees of heading disagreement tolerated, modulo direction of travel.
DEFAULT_BEARING_TOLERANCE_DEG = 40.0


def _scale(lat: float) -> tuple[float, float]:
    m_per_deg_lat = math.pi * _EARTH_R_M / 180.0
    return m_per_deg_lat * math.cos(math.radians(lat)), m_per_deg_lat


@dataclass(frozen=True)
class MatchStats:
    """What one annotate pass actually managed, so a silent zero is visible."""

    events_in: int = 0
    events_locatable: int = 0
    events_in_bbox: int = 0
    events_matched: int = 0
    edges_annotated: int = 0
    name_agreements: int = 0
    name_comparisons: int = 0
    #: Matched events and the edges they claimed, split by how the source
    #: published their geometry. A point-published event cannot be
    #: bearing-checked, so its edges-per-event is the precision cost of
    #: publishing a linear event as a location.
    by_kind: dict = field(default_factory=dict)

    @property
    def match_rate(self) -> float:
        return self.events_matched / self.events_in_bbox if self.events_in_bbox else 0.0

    @property
    def name_agreement_rate(self) -> float:
        return self.name_agreements / self.name_comparisons if self.name_comparisons else 0.0

    def as_dict(self) -> dict:
        return {
            "events_in": self.events_in,
            "events_locatable": self.events_locatable,
            "events_in_bbox": self.events_in_bbox,
            "events_matched": self.events_matched,
            "edges_annotated": self.edges_annotated,
            "match_rate": round(self.match_rate, 4),
            "name_agreement_rate": round(self.name_agreement_rate, 4),
            "name_comparisons": self.name_comparisons,
            "by_geometry_kind": self.by_kind,
        }


class EdgeIndex:
    """An R-tree over a graph's edges in local metres, built once per graph."""

    def __init__(self, graph) -> None:
        lats = [float(d["y"]) for _, d in graph.nodes(data=True)]
        lons = [float(d["x"]) for _, d in graph.nodes(data=True)]
        self.mid_lat = (min(lats) + max(lats)) / 2.0 if lats else 0.0
        self.bbox = (min(lons), min(lats), max(lons), max(lats)) if lats else (0, 0, 0, 0)
        self._mx, self._my = _scale(self.mid_lat)

        self.keys: list[tuple] = []
        lines: list[LineString] = []
        for u, v, k, data in graph.edges(keys=True, data=True):
            coords = _edge_coords(graph, u, v, data)
            if len(coords) < 2:
                continue
            self.keys.append((u, v, k))
            lines.append(LineString([self.to_m(x, y) for x, y in coords]))
        self.lines = lines
        self.tree = STRtree(lines) if lines else None
        self.names = _edge_names(graph, self.keys)

    def to_m(self, lon: float, lat: float) -> tuple[float, float]:
        return lon * self._mx, lat * self._my

    def to_m_line(self, coords) -> LineString | None:
        pts = [self.to_m(x, y) for x, y in coords]
        return LineString(pts) if len(pts) >= 2 else None

    def within_bbox(self, coords) -> bool:
        """Does this event's extent overlap the graph's? The feeds are
        statewide and have **no bbox parameter on the wire**, so this filter is
        the client's job, not the server's.

        Deliberately an *extent* overlap and not "any vertex inside": a county
        weather polygon contains the whole graph without putting a single
        vertex in it, and a highway work zone can cross a small bbox with its
        vertices on either side. Vertex containment drops both, silently.
        """
        w, s, e, n = self.bbox
        xs = [x for x, _ in coords]
        ys = [y for _, y in coords]
        return not (max(xs) < w or min(xs) > e or max(ys) < s or min(ys) > n)

    def near(self, line: LineString, tolerance_m: float) -> list[int]:
        if self.tree is None:
            return []
        idx = self.tree.query(line.buffer(tolerance_m))
        return [int(i) for i in idx]


def _edge_coords(graph, u, v, data) -> list[tuple[float, float]]:
    geom = data.get("geometry")
    if geom is not None and hasattr(geom, "coords"):
        return [(float(x), float(y)) for x, y in geom.coords]
    try:
        return [
            (float(graph.nodes[u]["x"]), float(graph.nodes[u]["y"])),
            (float(graph.nodes[v]["x"]), float(graph.nodes[v]["y"])),
        ]
    except KeyError:
        return []


def _edge_names(graph, keys) -> list[str]:
    out: list[str] = []
    for u, v, k in keys:
        data = graph.edges[u, v, k]
        parts = []
        for attr in ("name", "ref"):
            value = data.get(attr)
            if isinstance(value, list):
                parts.extend(str(x) for x in value)
            elif value:
                parts.append(str(value))
        out.append(" ".join(parts).lower())
    return out


def bearing(line: LineString) -> float:
    """Overall heading of a line in degrees, 0–180 (direction-agnostic: a road
    is the same road whichever way the DOT drew it)."""
    (x0, y0), (x1, y1) = line.coords[0], line.coords[-1]
    deg = math.degrees(math.atan2(y1 - y0, x1 - x0)) % 180.0
    return deg


def bearing_delta(a: float, b: float) -> float:
    d = abs(a - b) % 180.0
    return min(d, 180.0 - d)


_NAME_NOISE = str.maketrans({"-": " ", "/": " ", ".": " ", ",": " "})


def names_agree(event_names: tuple[str, ...], edge_name: str) -> bool:
    """Loose token overlap. `"WIS 142 WB"` against OSM's `"State Highway 142"`
    agrees on `142`; `"CTH B"` against `"County Road B"` agrees on `b`. Strict
    equality would report near-zero agreement and say nothing useful."""
    if not event_names or not edge_name:
        return False
    edge_tokens = {t for t in edge_name.translate(_NAME_NOISE).split() if t}
    for raw in event_names:
        tokens = {t for t in raw.lower().translate(_NAME_NOISE).split() if t}
        # Direction words are not identity.
        tokens -= {"nb", "sb", "eb", "wb", "northbound", "southbound",
                   "eastbound", "westbound", "ramp", "at"}
        if tokens & edge_tokens:
            return True
    return False


def match_events(graph, index: EdgeIndex, events, *,
                 tolerance_m: float = DEFAULT_TOLERANCE_M,
                 bearing_tolerance_deg: float = DEFAULT_BEARING_TOLERANCE_DEG,
                 ) -> tuple[dict[tuple, list], MatchStats]:
    """`{(u, v, k): [RoadEvent, ...]}` plus what happened on the way.

    A polygon event (`geometry_kind="polygon"`) matches by containment
    instead of by bearing — a weather advisory has no heading, and requiring
    one would silently drop every alert that does carry geometry.
    """
    hits: dict[tuple, list] = {}
    stats = {"in": 0, "locatable": 0, "in_bbox": 0, "matched": 0,
             "name_ok": 0, "name_cmp": 0}
    by_kind: dict[str, dict[str, int]] = {}

    for event in events:
        stats["in"] += 1
        if not event.locatable:
            continue
        stats["locatable"] += 1
        if not index.within_bbox(event.geometry):
            continue
        stats["in_bbox"] += 1

        if event.geometry_kind == "polygon":
            matched = _match_polygon(index, event, tolerance_m)
        elif event.geometry_kind == "point" or len(event.geometry) < 2:
            matched = _match_point(index, event, tolerance_m)
        else:
            matched = _match_line(index, event, tolerance_m, bearing_tolerance_deg)
        bucket = by_kind.setdefault(event.geometry_kind,
                                    {"events_in_bbox": 0, "matched": 0, "edges": 0})
        bucket["events_in_bbox"] += 1
        if not matched:
            continue
        stats["matched"] += 1
        bucket["matched"] += 1
        bucket["edges"] += len(matched)
        for i in matched:
            key = index.keys[i]
            hits.setdefault(key, []).append(event)
            if event.road_names and index.names[i]:
                stats["name_cmp"] += 1
                if names_agree(event.road_names, index.names[i]):
                    stats["name_ok"] += 1

    return hits, MatchStats(
        events_in=stats["in"], events_locatable=stats["locatable"],
        events_in_bbox=stats["in_bbox"], events_matched=stats["matched"],
        edges_annotated=len(hits), name_agreements=stats["name_ok"],
        name_comparisons=stats["name_cmp"], by_kind=by_kind,
    )


def _match_point(index: EdgeIndex, event, tolerance_m: float) -> list[int]:
    """A single-point event. **No bearing check is possible**, so this takes
    every edge within tolerance — cross streets included. That imprecision is
    not a defect of this matcher; it is what a point-only publication of a
    linear event can support, and it is measured rather than hidden
    (`point_events` in the stats)."""
    if index.tree is None or not event.geometry:
        return []
    point = Point(index.to_m(*event.geometry[0]))
    return [i for i in index.near(point, tolerance_m)
            if index.lines[i].distance(point) <= tolerance_m]


def _match_line(index: EdgeIndex, event, tolerance_m: float,
                bearing_tolerance_deg: float) -> list[int]:
    line = index.to_m_line(event.geometry)
    if line is None:
        return []
    want = bearing(line)
    out = []
    for i in index.near(line, tolerance_m):
        edge_line = index.lines[i]
        if edge_line.distance(line) > tolerance_m:
            continue
        if bearing_delta(want, bearing(edge_line)) > bearing_tolerance_deg:
            continue
        out.append(i)
    return out


def _match_polygon(index: EdgeIndex, event, tolerance_m: float) -> list[int]:
    ring = [index.to_m(x, y) for x, y in event.geometry]
    if len(ring) < 4:
        return []
    poly = Polygon(ring)
    if not poly.is_valid:
        poly = poly.buffer(0)
    if index.tree is None or poly.is_empty:
        return []
    return [int(i) for i in index.tree.query(poly)
            if index.lines[int(i)].intersects(poly)]
