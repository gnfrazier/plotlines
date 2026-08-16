"""Cue derivation from a routed polyline (PRD F1/FR46, ARCH §6.1 `trips/`).

Written by SPIKE-21. This is what *produces* a cue sheet; the Field Runtime's
position-aware engine (ARCH §5.3) is what *consumes* one, and assumes it already
exists on-device. It runs here, in the core, rather than in the client — a cue sheet
is derived from graph attributes (junction degree, `surface`, `name`) that only the
routing side holds, and P1 requires sidecar and hosted deployments to produce the
same sheet for the same route.

The whole problem is subtraction. A solved route through a city grid passes through a
junction every hundred metres or so, its polyline bends constantly, and its `surface`
tag flickers between "asphalt", absent, and "concrete" over a single block. Emitting a
cue per junction, per bend, or per tag change produces a document nobody can read on a
handlebar. Four rules do the subtracting, and each is defended where it is implemented:

  1. **Bearing is measured over a smoothing window, not between adjacent vertices.**
     Adjacent vertices at a junction describe the kerb radius, not the manoeuvre.
  2. **A bend is only a turn where an alternative existed.** Junction degree decides
     that. A road that curves through 60° with nowhere else to go is not a turn, and
     Boulder's switchbacks are exactly that case (SPIKE-03 §4's flagged geometry).
  3. **An unknown `surface` tag is not a surface change.** Coverage runs 24.5%–81.7%
     across the fixture regions (SPIKE-03), so treating absence as a value would spam
     the sheet in Viroqua and mislead everywhere.
  4. **Everything else merges by proximity, but safety never merges away.** Hazards,
     portages and transitions survive crowding rules that thin POIs and surface notes.

Nothing here reroutes, and nothing here reads a live position: a cue sheet is a
function of one solved route and the Author's own nodes.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

from plotlines_core.trips.payload import (
    Cue, CueSheet, coord_from_latlon, now_stamp,
)

_EARTH_R_M = 6_371_000.0

#: `surface` values that count as paved. Anything not listed in either map is
#: **unknown**, never "other" — see `surface_class`.
_PAVED = {
    "asphalt", "paved", "concrete", "concrete:plates", "concrete:lanes",
    "paving_stones", "sett", "cobblestone", "chipseal", "metal", "wood",
    "bricks", "brick",
}

#: `surface` values that count as unpaved for cue purposes. FR4 calls this class
#: "gravel"; it is really "not paved", which is what a rider needs told.
_GRAVEL = {
    "gravel", "fine_gravel", "compacted", "unpaved", "dirt", "ground", "earth",
    "grass", "sand", "mud", "pebblestone", "rock", "woodchips",
}

#: Human labels for the classes a cue can announce.
SURFACE_LABEL = {"paved": "pavement", "gravel": "gravel"}


@dataclass(frozen=True)
class CueSettings:
    """Every threshold the derivation uses, in one place and all overridable.

    They are settings rather than constants because SPIKE-21 measured them on three
    regions, not thirty: a Dutch city or a Scottish estate track may want different
    numbers, and the alternative to naming them here is finding them scattered through
    the code as magic values later.
    """

    #: Metres of polyline averaged either side of a junction to get its bearings.
    #: At 10 m the kerb radius dominates; at 50 m a short block between two turns
    #: bleeds into the next manoeuvre. 25 m is the middle of the plateau SPIKE-21 swept.
    smoothing_m: float = 25.0

    #: Below this bearing change, a junction is "continue" and emits nothing.
    straight_deg: float = 30.0
    slight_deg: float = 45.0        # 30–45° reads as "bear left/right"
    sharp_deg: float = 120.0        # beyond this, "sharp"
    uturn_deg: float = 160.0        # beyond this, a reversal

    #: Undirected degree at which a node counts as offering a choice. Below it, a
    #: bend is the road's own geometry and cueing it is noise.
    junction_min_degree: int = 3

    #: A reversal is always cued regardless of degree — it is how a spur's turnaround
    #: reads, and a dead end has degree 1.
    always_cue_reversal: bool = True

    #: Staying on the same way is not a manoeuvre, however hard it bends — a named
    #: path that swings 90° and continues under its own name is "continue", not
    #: "turn". Above `sharp_deg` the rule lifts, because a reversal on your own road
    #: still has to be announced.
    suppress_same_way: bool = True

    #: Two turns closer than this are one manoeuvre: a staggered crossing, a
    #: path-to-road ramp, a jog between two blocks. They coalesce into a single cue.
    jog_window_m: float = 40.0

    #: Minimum length of a surface run before a change is worth announcing.
    surface_min_run_m: float = 150.0

    #: How far off the route a node may sit and still be cued, and the distance
    #: within which two advisory cues collapse into one.
    node_corridor_m: float = 150.0
    merge_window_m: float = 25.0

    #: Cues per kilometre above which a sheet stops being glanceable. Not enforced —
    #: measured and reported, because the honest failure is "this route is busy",
    #: not "we hid some turns".
    legible_cues_per_km: float = 4.0


#: Merge priority. A cue never absorbs one above it in this list.
_PRIORITY = {
    "hazard": 0, "portage": 1, "transition": 2, "start": 3, "finish": 3,
    "turn": 4, "event": 5, "alternate": 6, "node": 7, "surface": 8,
}

#: Kinds that are never merged into a neighbour and never suppressed.
_SAFETY_CRITICAL = frozenset({"hazard", "portage", "transition", "start", "finish"})


# ------------------------------------------------------------------- geometry

def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Metres between two (lon, lat) points."""
    lon1, lat1 = math.radians(a[0]), math.radians(a[1])
    lon2, lat2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = (math.sin(dlat / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2)
    return 2 * _EARTH_R_M * math.asin(min(1.0, math.sqrt(h)))


def bearing_deg(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Initial great-circle bearing from a to b, degrees clockwise from north."""
    lat1, lat2 = math.radians(a[1]), math.radians(b[1])
    dlon = math.radians(b[0] - a[0])
    y = math.sin(dlon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def signed_turn(from_deg: float, to_deg: float) -> float:
    """Turn angle in (-180, 180]: negative left, positive right."""
    delta = (to_deg - from_deg + 540.0) % 360.0 - 180.0
    return 180.0 if delta == -180.0 else delta


@dataclass
class RouteEdge:
    """One traversed graph edge, placed on the drawn polyline."""

    u: int
    v: int
    data: dict
    start_m: float
    end_m: float
    start_index: int
    end_index: int
    repeat: int = 0          # 0 on first traversal, 1+ on each retrace


@dataclass
class Route:
    """A solved walk as the client draws it: one polyline plus its edge index."""

    coords: list[list[float]]      # [[lon, lat], ...]
    cumulative_m: list[float]
    edges: list[RouteEdge]

    @property
    def length_m(self) -> float:
        return self.cumulative_m[-1] if self.cumulative_m else 0.0

    def point_at(self, distance_m: float) -> list[float]:
        """The coordinate at a distance along the route."""
        if not self.coords:
            return [0.0, 0.0]
        for index in range(1, len(self.cumulative_m)):
            if self.cumulative_m[index] >= distance_m:
                span = self.cumulative_m[index] - self.cumulative_m[index - 1]
                if span <= 0:
                    return list(self.coords[index])
                t = (distance_m - self.cumulative_m[index - 1]) / span
                a, b = self.coords[index - 1], self.coords[index]
                return [round(a[0] + (b[0] - a[0]) * t, 7),
                        round(a[1] + (b[1] - a[1]) * t, 7)]
        return list(self.coords[-1])

    def bearing_before(self, index: int, window_m: float) -> float | None:
        """Bearing of the `window_m` of route arriving at polyline `index`."""
        target = self.cumulative_m[index] - window_m
        start = index
        while start > 0 and self.cumulative_m[start] > target:
            start -= 1
        if start == index:
            start = max(0, index - 1)
        if start == index:
            return None
        return bearing_deg(tuple(self.coords[start]), tuple(self.coords[index]))

    def bearing_after(self, index: int, window_m: float) -> float | None:
        """Bearing of the `window_m` of route leaving polyline `index`."""
        target = self.cumulative_m[index] + window_m
        end = index
        last = len(self.coords) - 1
        while end < last and self.cumulative_m[end] < target:
            end += 1
        if end == index:
            end = min(last, index + 1)
        if end == index:
            return None
        return bearing_deg(tuple(self.coords[index]), tuple(self.coords[end]))

    def project(self, point: list[float]) -> tuple[float, float]:
        """Nearest point on the route to `point`: (distance_along_m, offset_m).

        Equirectangular projection about the query point — the routes here are tens of
        kilometres, where the error is centimetres, and it keeps this dependency-free.
        """
        if len(self.coords) < 2:
            return 0.0, math.inf
        lat0 = math.radians(point[1])
        kx = math.cos(lat0) * math.pi * _EARTH_R_M / 180.0
        ky = math.pi * _EARTH_R_M / 180.0
        px, py = point[0] * kx, point[1] * ky

        best = (0.0, math.inf)
        for index in range(len(self.coords) - 1):
            ax, ay = self.coords[index][0] * kx, self.coords[index][1] * ky
            bx, by = self.coords[index + 1][0] * kx, self.coords[index + 1][1] * ky
            dx, dy = bx - ax, by - ay
            span = dx * dx + dy * dy
            t = 0.0 if span == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / span))
            cx, cy = ax + dx * t, ay + dy * t
            offset = math.hypot(px - cx, py - cy)
            if offset < best[1]:
                along = self.cumulative_m[index] + math.hypot(cx - ax, cy - ay)
                best = (along, offset)
        return best


def route_polyline(graph, walk) -> Route:
    """Build the drawn polyline for a walk, with its edge index and retrace counts.

    The polyline is what a client renders and what a cue sheet measures against — the
    graph path is a sequence of junctions, and the shape between them lives on each
    edge's `geometry`. Cueing against the junction-only path would put every distance
    slightly short and every bearing slightly wrong.
    """
    coords: list[list[float]] = []
    cumulative: list[float] = []
    edges: list[RouteEdge] = []
    seen: dict[frozenset, int] = {}

    for u, v, data in walk:
        start = (graph.nodes[u]["x"], graph.nodes[u]["y"])
        end = (graph.nodes[v]["x"], graph.nodes[v]["y"])
        line = data.get("geometry")
        if line is not None:
            points = list(line.coords)
            if _sq(points[0], start) > _sq(points[-1], start):
                points.reverse()
        else:
            points = [start, end]

        start_index = len(coords)
        if not coords:
            coords.append(coord_from_latlon(points[0][1], points[0][0]))
            cumulative.append(0.0)
            start_index = 0
        for lon, lat in points[1:]:
            point = coord_from_latlon(lat, lon)
            if point == coords[-1]:
                continue
            cumulative.append(cumulative[-1] + haversine_m(tuple(coords[-1]), tuple(point)))
            coords.append(point)

        key = frozenset((u, v))
        repeat = seen.get(key, 0)
        seen[key] = repeat + 1
        edges.append(RouteEdge(
            u=u, v=v, data=data,
            start_m=cumulative[start_index], end_m=cumulative[-1],
            start_index=start_index, end_index=len(coords) - 1,
            repeat=repeat,
        ))

    return Route(coords=coords, cumulative_m=cumulative, edges=edges)


def _sq(a, b) -> float:
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2


# ------------------------------------------------------------------ attributes

def _first(value):
    """OSM tags arrive as str or list[str] depending on way merging."""
    return value[0] if isinstance(value, list) and value else value


def surface_class(data: dict) -> str | None:
    """`paved`, `gravel`, or **None for unknown** — never a third bucket.

    Deliberately reads the `surface` tag and nothing else. Inferring surface from
    `highway` would let a `residential` tag manufacture "pavement" the mapper never
    recorded — the same overreach ARCH A17 records for traffic stress, where highway
    class alone gave rural Viroqua a 35% traffic floor. An unknown surface is a fact
    about the map, and the cue sheet says nothing rather than guessing.

    **FR4's third class, singletrack, has no source here**: no `surface` value means
    it. It needs `highway` + `tracktype`/`mtb:scale`, which is a modelling decision
    this function deliberately leaves to whoever takes it (SPIKE-21 §5.3).
    """
    value = _first(data.get("surface"))
    if not value:
        return None
    value = str(value).lower()
    if value in _PAVED:
        return "paved"
    if value in _GRAVEL:
        return "gravel"
    return None


def way_name(data: dict) -> str | None:
    name = _first(data.get("name"))
    return str(name) if name else None


def _osmids(data: dict) -> frozenset:
    value = data.get("osmid")
    if value is None:
        return frozenset()
    return frozenset(value) if isinstance(value, list) else frozenset({value})


def same_way(a: dict, b: dict) -> bool:
    """Do two consecutive edges belong to the same way the rider is riding?

    Name first, because that is what a rider verifies against a signpost. Where a way
    is unnamed — 54% of Boulder's edges — fall back to shared OSM way ids, which is
    weaker but does not confuse two different "service road"s the way a label would.
    """
    name_a, name_b = way_name(a), way_name(b)
    if name_a and name_b:
        return name_a == name_b
    shared = _osmids(a) & _osmids(b)
    return bool(shared)


def _way_label(data: dict) -> str:
    """What to call a way in an instruction when it has no name.

    A named road is named. An unnamed one is described by its kind, because "Turn
    left" with no object is the cue people misread — the rider needs to know whether
    they are looking for a road or a trail.
    """
    name = way_name(data)
    if name:
        return name
    highway = _first(data.get("highway")) or "road"
    return {
        "cycleway": "the bike path", "path": "the path", "footway": "the footway",
        "track": "the track", "service": "the service road",
        "residential": "the unnamed residential street",
        "living_street": "the unnamed street",
    }.get(str(highway), "the unnamed road")


# ---------------------------------------------------------------------- turns

def _modifier(delta: float, settings: CueSettings) -> str:
    magnitude = abs(delta)
    side = "left" if delta < 0 else "right"
    if magnitude >= settings.uturn_deg:
        return "uturn"
    if magnitude >= settings.sharp_deg:
        return f"sharp_{side}"
    if magnitude < settings.slight_deg:
        return f"slight_{side}"
    return side


_MODIFIER_TEXT = {
    "left": "Turn left", "right": "Turn right",
    "slight_left": "Bear left", "slight_right": "Bear right",
    "sharp_left": "Sharp left", "sharp_right": "Sharp right",
    "uturn": "Turn back",
}


def turn_cues(graph, route: Route, settings: CueSettings) -> tuple[list[Cue], dict]:
    """Turn cues at real decision points, plus the counts that justify the filtering."""
    undirected = graph.to_undirected(as_view=True)
    cues: list[Cue] = []
    stats = {"junctions": 0, "bend_below_threshold": 0, "no_alternative": 0,
             "same_way_continuation": 0, "before_coalescing": 0, "coalesced_away": 0,
             "emitted": 0, "reversals": 0}

    for index in range(len(route.edges) - 1):
        incoming, outgoing = route.edges[index], route.edges[index + 1]
        node = incoming.v
        stats["junctions"] += 1

        before = route.bearing_before(incoming.end_index, settings.smoothing_m)
        after = route.bearing_after(outgoing.start_index, settings.smoothing_m)
        if before is None or after is None:
            continue
        delta = signed_turn(before, after)

        if abs(delta) < settings.straight_deg:
            stats["bend_below_threshold"] += 1
            continue

        reversal = abs(delta) >= settings.uturn_deg
        degree = undirected.degree(node)
        if degree < settings.junction_min_degree and not (
                reversal and settings.always_cue_reversal):
            # The road bends and there was nowhere else to go. Boulder's switchbacks
            # live here: real geometry, no decision.
            stats["no_alternative"] += 1
            continue

        if (settings.suppress_same_way and abs(delta) < settings.sharp_deg
                and same_way(incoming.data, outgoing.data)):
            # You are still on the road you were on. A cue sheet says "continue",
            # which is to say it says nothing — this is the single largest source of
            # noise on a path-heavy urban route, where a greenway bends through 60°
            # at every bridge and keeps its own name throughout.
            stats["same_way_continuation"] += 1
            continue

        modifier = _modifier(delta, settings)
        onto = _way_label(outgoing.data)
        text = _MODIFIER_TEXT[modifier]
        instruction = (f"{text} at the end" if modifier == "uturn" and degree == 1
                       else f"{text} onto {onto}")
        cues.append(Cue(
            sequence=0,
            distance_along_m=incoming.end_m,
            kind="turn",
            instruction=instruction,
            modifier=modifier,
            bearing_deg=round(after, 1),
            retrace=outgoing.repeat > 0 or None,
        ))
        if reversal:
            stats["reversals"] += 1

    stats["before_coalescing"] = len(cues)
    cues = _coalesce_turns(cues, settings)
    stats["coalesced_away"] = stats["before_coalescing"] - len(cues)
    stats["emitted"] = len(cues)
    return cues, stats


_SIDE = {"left": -1, "slight_left": -1, "sharp_left": -1,
         "right": 1, "slight_right": 1, "sharp_right": 1, "uturn": 0}


def _coalesce_turns(cues: list[Cue], settings: CueSettings) -> list[Cue]:
    """Collapse turns that are one manoeuvre into one cue.

    A staggered crossing, a ramp off a path onto the road beside it, or a jog between
    two blocks reads as three or four turns inside 30 m. Measured on the Boulder
    fixture before this pass: four cues in twenty metres at a single path/road
    interchange. A rider executing it makes one decision, so it is one line.

    A U-turn never coalesces — it is the spur turnaround, and it is the one cue on the
    sheet nobody may miss.
    """
    if not cues:
        return cues
    out: list[Cue] = [cues[0]]
    for cue in cues[1:]:
        previous = out[-1]
        gap = cue.distance_along_m - previous.distance_along_m
        both_reversals = previous.modifier == "uturn" and cue.modifier == "uturn"
        if both_reversals and gap <= settings.jog_window_m:
            # Two "turn back"s twenty metres apart is one turnaround seen twice — an
            # artefact of how the circuit re-enters a node, not two manoeuvres. Keep
            # the first; a rider turns around once.
            out[-1] = replace(previous, retrace=previous.retrace or cue.retrace)
            continue
        if (gap <= settings.jog_window_m
                and previous.modifier != "uturn" and cue.modifier != "uturn"):
            side_a = _SIDE.get(previous.modifier or "", 0)
            side_b = _SIDE.get(cue.modifier or "", 0)
            onto = (cue.instruction or "").split(" onto ", 1)
            target = onto[1] if len(onto) == 2 else None
            if side_a and side_b and side_a != side_b:
                first = "left" if side_a < 0 else "right"
                second = "left" if side_b < 0 else "right"
                text = f"Jog {first} then {second}"
                modifier = f"jog_{first}_{second}"
            else:
                text = _MODIFIER_TEXT.get(previous.modifier or "", "Turn")
                modifier = previous.modifier
            out[-1] = replace(
                previous,
                instruction=f"{text} onto {target}" if target else text,
                modifier=modifier,
                bearing_deg=cue.bearing_deg,
                retrace=previous.retrace or cue.retrace,
            )
            continue
        out.append(cue)
    return out


# -------------------------------------------------------------------- surfaces

def surface_cues(route: Route, settings: CueSettings) -> tuple[list[Cue], dict]:
    """Surface-change cues, with unknown treated as unknown.

    Two filters, and the second is the one that matters on thin coverage:

      * a gap in tagging never opens or closes a cue — only a *known* class following
        a different *known* class does;
      * a change must persist for `surface_min_run_m` to be worth announcing, so a
        20 m concrete apron across a driveway is not a surface change.
    """
    runs: list[tuple[str, float, float]] = []      # (class, start_m, end_m)
    for edge in route.edges:
        klass = surface_class(edge.data)
        if klass is None:
            continue
        if runs and runs[-1][0] == klass:
            runs[-1] = (klass, runs[-1][1], edge.end_m)
        else:
            runs.append((klass, edge.start_m, edge.end_m))

    stats = {"known_runs": len(runs),
             "raw_transitions": max(0, len(runs) - 1),
             "suppressed_short": 0, "emitted": 0}

    cues: list[Cue] = []
    for index in range(1, len(runs)):
        klass, start_m, end_m = runs[index]
        previous = runs[index - 1]
        if (end_m - start_m) < settings.surface_min_run_m or \
                (previous[2] - previous[1]) < settings.surface_min_run_m:
            stats["suppressed_short"] += 1
            continue
        label = SURFACE_LABEL.get(klass, klass)
        cues.append(Cue(
            sequence=0, distance_along_m=start_m, kind="surface",
            instruction=f"Surface changes to {label}",
        ))
        stats["emitted"] += 1

    return cues, stats


# ----------------------------------------------------------------- highlights

_NODE_TEXT = {
    "waypoint": "Waypoint", "regroup": "Regroup point", "rest_stop": "Rest stop",
    "poi": "Point of interest", "transition": "Mode change", "via": "Via point",
    "start": "Start", "finish": "Finish", "event": "Scheduled",
    "portage_start": "Portage begins", "portage_end": "Portage ends",
}

#: Which payload node kinds become which cue kind.
_NODE_CUE_KIND = {"transition": "transition", "event": "event"}


def node_cues(route: Route, nodes, settings: CueSettings) -> tuple[list[Cue], dict]:
    """Author-placed nodes, projected onto the route and cued in route order."""
    cues: list[Cue] = []
    stats = {"considered": 0, "off_route": 0, "emitted": 0}

    for node in nodes:
        stats["considered"] += 1
        along, offset = (node.distance_along_m, 0.0) if node.distance_along_m is not None \
            else route.project(node.coord)
        if offset > settings.node_corridor_m:
            # Recorded rather than silently dropped: a node the Author placed and the
            # sheet does not mention is a support question later.
            stats["off_route"] += 1
            continue
        title = node.title or _NODE_TEXT.get(node.kind, "Point")
        prefix = _NODE_TEXT.get(node.kind, "Point")
        instruction = title if title.lower().startswith(prefix.lower()) \
            else f"{prefix}: {title}"
        if node.kind == "transition" and node.instructions:
            instruction = f"{instruction} — {node.instructions.splitlines()[0]}"
        cues.append(Cue(
            sequence=0, distance_along_m=along,
            kind=_NODE_CUE_KIND.get(node.kind, "node"),
            instruction=instruction, ref_id=node.id,
        ))
        stats["emitted"] += 1

    return cues, stats


def hazard_cues(route: Route, hazards, settings: CueSettings) -> list[Cue]:
    """FR27 — always cued, never merged away, and severity leads the text."""
    lead = {"caution": "Caution", "high": "HAZARD", "mandatory_reroute": "STOP"}
    cues: list[Cue] = []
    for hazard in hazards:
        if hazard.distance_along_m is not None:
            along = hazard.distance_along_m
        elif hazard.coord:
            along, _ = route.project(hazard.coord)
        else:
            continue
        title = hazard.title or "Hazard"
        text = f"{lead.get(hazard.severity, 'Caution')}: {title}"
        if hazard.safety_note:
            text = f"{text} — {hazard.safety_note.splitlines()[0]}"
        cues.append(Cue(sequence=0, distance_along_m=along, kind="hazard",
                        instruction=text, ref_id=hazard.id))
    return cues


def portage_cues(route: Route, portages) -> list[Cue]:
    """FR15 — a portage is auto-included, and its distance is stated because it is
    carried, not paddled."""
    cues: list[Cue] = []
    for portage in portages:
        coords = portage.geometry.coordinates if portage.geometry else []
        if not coords:
            continue
        along, _ = route.project(coords[0])
        bank = {"river_left": "river left", "river_right": "river right"}.get(
            portage.exit_bank or "", "")
        parts = ["Portage"]
        if portage.mandatory:
            parts = ["MANDATORY portage"]
        if bank:
            parts.append(f"take out {bank}")
        if portage.distance_m:
            parts.append(f"{round(portage.distance_m)} m carry")
        cues.append(Cue(sequence=0, distance_along_m=along, kind="portage",
                        instruction=" — ".join(parts), ref_id=portage.id))
    return cues


def alternate_cues(route: Route, alternates) -> list[Cue]:
    """FR20 — an alternate is announced where it leaves, not where it is drawn."""
    label = {"bypass": "Bypass", "extension": "Extension"}
    cues: list[Cue] = []
    for alternate in alternates:
        along = alternate.diverges_at_m
        if along is None and alternate.geometry and alternate.geometry.coordinates:
            along, _ = route.project(alternate.geometry.coordinates[0])
        if along is None:
            continue
        name = alternate.label or label.get(alternate.kind, "Alternate")
        cues.append(Cue(sequence=0, distance_along_m=along, kind="alternate",
                        instruction=f"{label.get(alternate.kind, 'Alternate')} available: {name}",
                        ref_id=alternate.id))
    return cues


# --------------------------------------------------------------------- merging

def _merge(cues: list[Cue], settings: CueSettings) -> tuple[list[Cue], dict]:
    """Order by distance, then collapse advisory crowding into single entries.

    The rule is asymmetric on purpose. Two POIs and a surface note within 20 m are one
    line on a cue sheet; a hazard next to a turn is two, because a rider who reads one
    line and looks up must not have missed the other.
    """
    ordered = sorted(cues, key=lambda cue: (cue.distance_along_m,
                                            _PRIORITY.get(cue.kind, 9)))
    merged: list[Cue] = []
    stats = {"before": len(ordered), "merged_away": 0}

    for cue in ordered:
        if merged:
            previous = merged[-1]
            close = cue.distance_along_m - previous.distance_along_m <= settings.merge_window_m
            mergeable = (close
                         and cue.kind not in _SAFETY_CRITICAL
                         and previous.kind not in _SAFETY_CRITICAL
                         and not (cue.kind == "turn" and previous.kind == "turn"))
            if mergeable:
                keep, absorb = (previous, cue) if _PRIORITY.get(previous.kind, 9) <= \
                    _PRIORITY.get(cue.kind, 9) else (cue, previous)
                text = keep.instruction or ""
                extra = absorb.instruction or ""
                merged[-1] = replace(
                    keep,
                    distance_along_m=min(previous.distance_along_m, cue.distance_along_m),
                    instruction=f"{text} ({extra})" if extra else text,
                    retrace=previous.retrace or cue.retrace,
                )
                stats["merged_away"] += 1
                continue
        merged.append(cue)

    for sequence, cue in enumerate(merged):
        merged[sequence] = replace(cue, sequence=sequence,
                                   distance_along_m=round(cue.distance_along_m, 1))
    stats["after"] = len(merged)
    return merged, stats


def _retrace_pass(cues: list[Cue], route: Route) -> dict:
    """Mark every cue standing on road the route has already used.

    SPIKE-01 found that some via-node loops legitimately ride a spur twice — the
    lollipop. Cueing the return leg identically to the outbound is how a rider ends up
    turning off a road they were supposed to stay on: the instruction is right, the
    context is missing. `retrace` carries that context.
    """
    marked = 0
    spans = [(edge.start_m, edge.end_m) for edge in route.edges if edge.repeat > 0]
    for index, cue in enumerate(cues):
        if cue.kind in ("start", "finish"):
            # A loop finishes where it started, so its last cue always sits on road
            # already ridden. Saying so adds nothing: "Arrive (retrace)" is noise.
            continue
        if cue.retrace:
            marked += 1
            continue
        for start_m, end_m in spans:
            if start_m - 1.0 <= cue.distance_along_m <= end_m + 1.0:
                cues[index] = replace(cue, retrace=True)
                marked += 1
                break
    return {"retraced_span_m": round(sum(e - s for s, e in spans), 1),
            "cues_marked": marked}


# ----------------------------------------------------------------------- entry

def derive_cue_sheet(
    graph,
    walk,
    *,
    segment_id: str | None = None,
    nodes=(),
    hazards=(),
    portages=(),
    alternates=(),
    settings: CueSettings | None = None,
    start_label: str = "Start",
    finish_label: str = "Finish",
    generated_at: str | None = None,
) -> tuple[CueSheet, dict]:
    """Derive one segment's cue sheet. Returns the sheet and its derivation stats.

    The stats are returned rather than logged because every one of them is a number a
    UI may need to show honestly: how many Author nodes fell outside the corridor, how
    many surface changes the tagging could not support, how dense the sheet is.
    """
    settings = settings or CueSettings()
    route = route_polyline(graph, walk)

    turns, turn_stats = turn_cues(graph, route, settings)
    surfaces, surface_stats = surface_cues(route, settings)
    highlights, node_stats = node_cues(route, nodes, settings)

    cues = [
        Cue(sequence=0, distance_along_m=0.0, kind="start", instruction=start_label),
        *turns, *surfaces, *highlights,
        *hazard_cues(route, hazards, settings),
        *portage_cues(route, portages),
        *alternate_cues(route, alternates),
        Cue(sequence=0, distance_along_m=route.length_m, kind="finish",
            instruction=finish_label),
    ]

    merged, merge_stats = _merge(cues, settings)
    retrace_stats = _retrace_pass(merged, route)
    for index, cue in enumerate(merged):
        merged[index] = replace(cue, segment_id=segment_id)

    length_km = route.length_m / 1000.0 or 1.0
    # Derived vs authored is the distinction the density ceiling has to be judged
    # against: the algorithm chooses how many turn and surface cues to emit, and has
    # no business thinning the Author's own hazards, stops and transitions. On a short
    # route the authored half dominates the sheet and no filtering may touch it.
    derived = sum(1 for cue in merged if cue.kind in ("turn", "surface"))
    stats = {
        "route_m": round(route.length_m, 1),
        "polyline_vertices": len(route.coords),
        "edges": len(route.edges),
        "turns": turn_stats,
        "surfaces": surface_stats,
        "nodes": node_stats,
        "merge": merge_stats,
        "retrace": retrace_stats,
        "cues": len(merged),
        "cues_per_km": round(len(merged) / length_km, 2),
        "derived_cues": derived,
        "derived_cues_per_km": round(derived / length_km, 2),
        "authored_cues": len(merged) - derived,
        "vertices_per_km": round(len(route.coords) / length_km, 2),
        "within_legibility_ceiling": (derived / length_km)
        <= settings.legible_cues_per_km,
        "by_kind": {kind: sum(1 for cue in merged if cue.kind == kind)
                    for kind in sorted({cue.kind for cue in merged})},
    }

    sheet = CueSheet(
        generated_at=generated_at or now_stamp(),
        generator="plotlines-core cues/1.0",
        cues=merged,
        segment_ids=[segment_id] if segment_id else [],
    )
    return sheet, stats


def cues_per_window(cues, window_m: float = 1000.0, route_m: float = 0.0) -> list[int]:
    """Cue counts per window along the route — the peak matters, not just the mean."""
    if route_m <= 0:
        return []
    buckets = [0] * (int(route_m // window_m) + 1)
    for cue in cues:
        buckets[min(len(buckets) - 1, int(cue.distance_along_m // window_m))] += 1
    return buckets
