"""Build the fixture trip SPIKE-20 round-trips.

Real routes, not synthetic geometry: everything here is solved on the SPIKE-01/02/03
shared graphs (`spikes/shared/fixtures/`) with the same solver the product uses. A
schema that only ever sees a hand-written 5-point LineString proves nothing about the
6,000-vertex payloads the client will actually hold.

The trip is deliberately the awkward case rather than the tidy one — four days
covering every structural feature the 31 desktop-MVP stories touch:

  Day 1  start · cycling point-to-point, with an alternate (C4), waypoints and a
         regroup point (C5), a hazard (C11), realised-attribute bands and a
         deliberate violation (A5/A6)
  Day 2  cycling loop through two via-nodes (A9) at a banded target distance (A8),
         with curated nodes: notes, media, arc stages, narration trigger metadata
         (E1/E2/E4)
  Day 3  rest day — no route, a location, POIs and a scheduled event (C2/C12)
  Day 4  end · multimodal — hiking, a transition (B3), then an Author-drawn paddling
         segment with a portage (B6) and a mandatory-re-route hazard

Paddling geometry is Author-drawn on purpose: its router is Leg 3 (MVP §1.3), and
`geometry.source` is what keeps a hand-drawn line from being read with a solved
line's authority.
"""

from __future__ import annotations

import sys
from pathlib import Path

SPIKES = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SPIKES / "shared"))

from plotlines_core.elevation.sampler import ElevationSampler  # noqa: E402
from plotlines_core.routing.loops import generate_loop, offset, solve_circuit  # noqa: E402
from plotlines_core.scoring.metrics import edge_walk, measure  # noqa: E402
from plotlines_core.scoring.profile import THEMES  # noqa: E402
from plotlines_core.trips.compose import compose_day, split_trip  # noqa: E402
from plotlines_core.trips.payload import (  # noqa: E402
    Alternate, Attribution, Band, Cue, CueSheet, Elevation, Hazard, LineString,
    MediaRef, Narration, Node, Portage, Provenance, RouteMetrics, ScheduledWindow,
    Segment, SolveProvenance, TargetDistance, Transition, Violation, WeightProfile,
    coord_from_latlon, new_id, now_stamp,
)

from harness import Bench  # noqa: E402

ENGINE = "plotlines-core 0.0.1"

#: System-default paces, m/s. SPIKE-05 measured the cycling default at 31.4% error
#: (7.5% with an uploaded activity file) and hiking's at 9.6% — which is why
#: `pace_source` is stored beside the number rather than assumed.
_PACE_MS = {"cycling": 4.7, "hiking": 1.25, "paddling": 1.4, "transit": 15.0}

#: Fraction of moving time added for stops, per mode — B7's elapsed-vs-moving split.
_STOP_RATIO = {"cycling": 0.18, "hiking": 0.25, "paddling": 0.20, "transit": 0.0}


# ---------------------------------------------------------------- core adapters

def _geometry(graph, path: list[int], walk=None, source: str = "solved") -> LineString:
    """The line a client actually draws, not the graph path.

    An OSMnx graph is simplified: a path's *nodes* are decision points, and the shape
    between them lives on the edge's `geometry`. Building a payload from node
    coordinates alone produces a route that is correct in topology and visibly wrong
    on a map — and understates the payload's real size by an order of magnitude, which
    is the number SPIKE-15 needs from here. SPIKE-14's 6,864-vertex route was measured
    this way; so is this one.

    Edge geometry is stored in the way's own direction, which is not necessarily the
    direction of travel, so each is oriented against the node it starts from.
    """
    if walk is None:
        return LineString(
            coordinates=[coord_from_latlon(graph.nodes[n]["y"], graph.nodes[n]["x"])
                         for n in path],
            source=source,
        )

    coords: list[list[float]] = []
    for u, v, data in walk:
        start = (graph.nodes[u]["x"], graph.nodes[u]["y"])
        end = (graph.nodes[v]["x"], graph.nodes[v]["y"])
        line = data.get("geometry")
        if line is not None:
            points = list(line.coords)
            head, tail = points[0], points[-1]
            if _sq_dist(head, start) > _sq_dist(tail, start):
                points.reverse()
        else:
            points = [start, end]
        for lon, lat in points:
            point = coord_from_latlon(lat, lon)
            if not coords or coords[-1] != point:
                coords.append(point)
    return LineString(coordinates=coords, source=source)


def _sq_dist(a, b) -> float:
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2


def _metrics(core_metrics, mode: str) -> RouteMetrics:
    """core's `scoring.metrics.RouteMetrics` → the payload's, plus B7's time model."""
    moving = core_metrics.distance_m / _PACE_MS[mode]
    return RouteMetrics(
        distance_m=core_metrics.distance_m,
        climb_m=core_metrics.climb_m,
        descent_m=core_metrics.descent_m,
        traffic=core_metrics.traffic,
        unpaved_frac=core_metrics.unpaved_frac,
        scenic_frac=core_metrics.scenic_frac,
        max_grade=core_metrics.max_grade,
        overlap_frac=core_metrics.overlap_frac,
        overlap_near_frac=core_metrics.overlap_near_frac,
        overlap_far_frac=core_metrics.overlap_far_frac,
        edge_count=core_metrics.edge_count,
        moving_time_s=moving,
        elapsed_time_s=moving * (1.0 + _STOP_RATIO[mode]),
        pace_source="system_default",
    )


def _elevation(sampler: ElevationSampler | None, graph, path: list[int]) -> Elevation:
    if sampler is None:
        return Elevation(source="GEDTM30")
    coords = [(graph.nodes[n]["y"], graph.nodes[n]["x"]) for n in path]
    profile = sampler.profile(coords)
    raw = sampler.sample(coords)
    voids = int(sum(1 for v in raw if v != v))  # NaN != NaN — FR88's explicit check
    return Elevation(
        ascent_m=profile["ascent_m"], descent_m=profile["descent_m"],
        min_m=profile["min_m"], max_m=profile["max_m"],
        void_samples=voids, source="GEDTM30",
    )


def _along(graph, path: list[int], fraction: float) -> tuple[int, float]:
    """The node nearest `fraction` of the way along a path, and its distance-along."""
    lengths = [0.0]
    for u, v in zip(path, path[1:]):
        step = min(float(d.get("length", 0.0)) for d in graph[u][v].values())
        lengths.append(lengths[-1] + step)
    target = lengths[-1] * fraction
    index = min(range(len(lengths)), key=lambda i: abs(lengths[i] - target))
    return path[index], lengths[index]


def _default_weights() -> WeightProfile:
    """FR2–FR5 in Author-facing units. FR4's per-class surface axes are bipolar
    (0 avoid / 2.5 indifferent / 5 seek) — SPIKE-03's finding, carried in the data."""
    return WeightProfile(
        name="quiet_scenic", climbing=3.5, traffic=1.0,
        surface={"paved": 3.0, "gravel": 3.5, "singletrack": 1.5},
        interest=2.5,
    )


# -------------------------------------------------------------------- day parts

def _day_one(bench: Bench, key: str, sampler) -> tuple[list[Segment], list[Transition]]:
    """Cycling point-to-point with an alternate, nodes, a hazard, bands."""
    loaded = bench.regions[key]
    graph = loaded.graph
    lat, lon = loaded.region.centre
    start = (lat, lon)
    end = offset(lat, lon, 95.0, 4200.0)

    primary_profile = THEMES["quiet_scenic"]
    a, b = bench.snap(key, start), bench.snap(key, end)
    circuit = solve_circuit(graph, [a, b], primary_profile, close=False)
    walk = edge_walk(graph, circuit.path, primary_profile)
    core_metrics = measure(graph, walk)

    alt_profile = THEMES["fastest"]
    alt_circuit = solve_circuit(graph, [a, b], alt_profile, close=False)
    alt_walk = edge_walk(graph, alt_circuit.path, alt_profile)
    alt_metrics = measure(graph, alt_walk)

    mid_node, mid_along = _along(graph, circuit.path, 0.45)
    late_node, late_along = _along(graph, circuit.path, 0.8)

    # A5/A6: a band the route misses, so the violation path is exercised by real
    # numbers rather than by a hand-typed one. SPIKE-02's asynchronous-diagnosis
    # finding is why the payload carries violations but not the diagnosis.
    climb_band = Band(attribute="climb_m", minimum=250.0, source="envelope")
    traffic_band = Band(attribute="traffic", maximum=0.35, source="envelope")
    violations = []
    if core_metrics.climb_m < 250.0:
        violations.append(Violation("climb_m", core_metrics.climb_m,
                                    core_metrics.climb_m - 250.0))
    if core_metrics.traffic > 0.35:
        violations.append(Violation("traffic", core_metrics.traffic,
                                    core_metrics.traffic - 0.35))

    segment = Segment(
        mode="cycling", shape="point_to_point", title="Out of town",
        start=coord_from_latlon(*start), end=coord_from_latlon(*end),
        bands=[climb_band, traffic_band], violations=violations,
        geometry=_geometry(graph, circuit.path, walk),
        metrics=_metrics(core_metrics, "cycling"),
        elevation=_elevation(sampler, graph, circuit.path),
        nodes=[
            Node(kind="start", coord=coord_from_latlon(*start), title="Trailhead lot",
                 distance_along_m=0.0, arc_stage="exposition"),
            Node(kind="regroup", coord=coord_from_latlon(graph.nodes[mid_node]["y"],
                                                         graph.nodes[mid_node]["x"]),
                 distance_along_m=mid_along, title="Regroup at the bridge",
                 note="Wait here — the next stretch has no shoulder.",
                 amenities=["water", "shade"]),
            Node(kind="rest_stop", coord=coord_from_latlon(graph.nodes[late_node]["y"],
                                                           graph.nodes[late_node]["x"]),
                 distance_along_m=late_along, title="Corner store",
                 amenities=["food", "water", "toilets"], poi_type="shop"),
        ],
        alternates=[Alternate(
            kind="bypass", label="Direct road bypass",
            geometry=_geometry(graph, alt_circuit.path, alt_walk),
            metrics=_metrics(alt_metrics, "cycling"),
            elevation=_elevation(sampler, graph, alt_circuit.path),
            diverges_at_m=0.0, rejoins_at_m=core_metrics.distance_m,
        )],
        hazards=[Hazard(
            severity="caution", title="Cattle guard on the descent",
            safety_note="Cross square — it is slick when wet.",
            distance_along_m=late_along * 0.6,
            coord=coord_from_latlon(graph.nodes[mid_node]["y"],
                                     graph.nodes[mid_node]["x"]),
        )],
        solve=SolveProvenance(engine_version=ENGINE, graph_region=key,
                              solver_calls=circuit.calls, solved_at=now_stamp(),
                              closed=False),
    )
    return [segment], []


def _day_two(bench: Bench, key: str, sampler) -> tuple[list[Segment], list[Transition]]:
    """A9's loop through two via-nodes, banded target distance, curated nodes."""
    loaded = bench.regions[key]
    graph = loaded.graph
    lat, lon = loaded.region.centre
    vias = bench.via_points(key, 2)
    target_m = 20_000.0

    loop = generate_loop(graph, (lat, lon), target_m, THEMES["gravel"], via=vias)
    core_metrics = loop.metrics
    assert core_metrics is not None

    via_nodes = []
    for position, (vlat, vlon) in enumerate(vias, start=1):
        node = Node(
            kind="via", coord=coord_from_latlon(vlat, vlon),
            title=f"Via {position}",
            note=("The gravel starts here. Regroup before the descent."
                  if position == 1 else "Water pump behind the church."),
            arc_stage="crux" if position == 1 else "climax",
            poi_type="viewpoint",
            media=[MediaRef(kind="image", path=f"media/via-{position}.jpg",
                            caption="Looking back down the coulee", bytes=184_320)],
            narration=Narration(trigger_distance_m=400.0 if position == 1 else 150.0,
                                media_id=None,
                                text="Two hundred metres of loose gravel — stay off the brakes."),
        )
        via_nodes.append(node)

    segment = Segment(
        mode="cycling", shape="loop", title="The gravel loop",
        start=coord_from_latlon(lat, lon),
        via=[coord_from_latlon(vlat, vlon) for vlat, vlon in vias],
        target_distance=TargetDistance(value_m=target_m, min_m=target_m * 0.85,
                                       max_m=target_m * 1.15, advisory=False),
        bands=[Band(attribute="distance_m", minimum=target_m * 0.85,
                    maximum=target_m * 1.15, source="author"),
               Band(attribute="unpaved_frac", minimum=0.15, source="envelope")],
        weights=WeightProfile(name="gravel", climbing=4.0, traffic=0.5,
                              surface={"paved": 1.0, "gravel": 5.0,
                                       "singletrack": 3.0},
                              interest=1.0),
        geometry=_geometry(graph, loop.path, loop.walk),
        metrics=_metrics(core_metrics, "cycling"),
        elevation=_elevation(sampler, graph, loop.path),
        nodes=via_nodes,
        solve=SolveProvenance(engine_version=ENGINE, graph_region=key,
                              solve_ms=loop.solve_ms, solver_calls=loop.solver_calls,
                              solved_at=now_stamp(), closed=loop.closed,
                              hit_via=loop.hit_via),
    )
    return [segment], []


def _day_four(bench: Bench, key: str, sampler) -> tuple[list[Segment], list[Transition]]:
    """Multimodal: hiking → transition → Author-drawn paddling with a portage."""
    loaded = bench.regions[key]
    graph = loaded.graph
    lat, lon = loaded.region.centre
    hike_start = offset(lat, lon, 200.0, 1500.0)
    hike_end = offset(lat, lon, 250.0, 3600.0)

    profile = THEMES["quiet_scenic"]
    a, b = bench.snap(key, hike_start), bench.snap(key, hike_end)
    circuit = solve_circuit(graph, [a, b], profile, close=False)
    walk = edge_walk(graph, circuit.path, profile)
    core_metrics = measure(graph, walk)

    hiking = Segment(
        mode="hiking", shape="point_to_point", title="Ridge approach",
        start=coord_from_latlon(*hike_start), end=coord_from_latlon(*hike_end),
        geometry=_geometry(graph, circuit.path, walk),
        metrics=_metrics(core_metrics, "hiking"),
        elevation=_elevation(sampler, graph, circuit.path),
        nodes=[Node(kind="waypoint", coord=coord_from_latlon(*hike_end),
                    title="Put-in", arc_stage="resolution")],
        solve=SolveProvenance(engine_version=ENGINE, graph_region=key,
                              solver_calls=circuit.calls, solved_at=now_stamp()),
    )

    # Author-drawn: the paddling graph provider is Leg 3 work (MVP §1.3), so there is
    # no solved water geometry to carry and the payload must not imply one.
    paddle_points = [offset(*hike_end, 300.0 + step * 12.0, 400.0 * step)
                     for step in range(1, 7)]
    paddle_geometry = LineString(
        coordinates=[coord_from_latlon(plat, plon) for plat, plon in paddle_points],
        source="authored",
    )
    paddle_distance = 2_350.0
    paddling = Segment(
        mode="paddling", shape="point_to_point", title="Down to the take-out",
        start=coord_from_latlon(*hike_end),
        end=coord_from_latlon(*paddle_points[-1]),
        geometry=paddle_geometry,
        metrics=RouteMetrics(
            distance_m=paddle_distance, climb_m=0.0, descent_m=0.0,
            moving_time_s=paddle_distance / _PACE_MS["paddling"],
            elapsed_time_s=paddle_distance / _PACE_MS["paddling"] * 1.2,
            pace_source="system_default",
        ),
        elevation=Elevation(source="GEDTM30"),
        nodes=[Node(kind="finish", coord=coord_from_latlon(*paddle_points[-1]),
                    title="Take-out at the county landing",
                    amenities=["parking", "toilets"])],
        portages=[Portage(
            geometry=LineString(
                coordinates=[coord_from_latlon(*paddle_points[2]),
                             coord_from_latlon(*offset(*paddle_points[2], 15.0, 180.0))],
                source="authored"),
            exit_bank="river_left", distance_m=180.0, surface="gravel",
            elevation_change_m=-4.5, mandatory=True,
            note="Dam — mandatory portage, river left, 180 m on a gravel track.",
        )],
        hazards=[Hazard(severity="mandatory_reroute", title="Low-head dam",
                        safety_note="Do not run. Take out river left above the buoys.",
                        required_gear=["throw bag"],
                        coord=coord_from_latlon(*paddle_points[2]),
                        distance_along_m=900.0)],
        solve=SolveProvenance(engine_version=ENGINE, graph_region=key,
                              solved_at=now_stamp()),
    )

    transition = Transition(
        from_segment_id=hiking.id, to_segment_id=paddling.id,
        node=Node(kind="transition", coord=coord_from_latlon(*hike_end),
                  title="Boat stash",
                  instructions="Boats are stashed 40 m upstream of the gauge post. "
                               "Change here — no privacy at the landing."),
    )
    return [hiking, paddling], [transition]


# ------------------------------------------------------------------------ build

def build_trip(bench: Bench, key: str, *, with_cue_placeholder: bool = True):
    """The whole fixture trip for one region."""
    loaded = bench.regions[key]
    sampler = None
    if loaded.region.dem_path.exists():
        sampler = ElevationSampler(loaded.region.dem_path)

    try:
        day1_segments, day1_transitions = _day_one(bench, key, sampler)
        day2_segments, day2_transitions = _day_two(bench, key, sampler)
        day4_segments, day4_transitions = _day_four(bench, key, sampler)
    finally:
        if sampler:
            sampler.close()

    lat, lon = loaded.region.centre
    days = [
        compose_day(day1_segments, day1_transitions, index=1, roles=["start"],
                    date="2026-09-12", title="Day 1 — out of town"),
        compose_day(day2_segments, day2_transitions, index=2, date="2026-09-13",
                    title="Day 2 — the gravel loop"),
        compose_day([], [], index=3, kind="rest", date="2026-09-14",
                    title="Day 3 — rest", location=coord_from_latlon(lat, lon),
                    note="Zero day. Laundry, then the museum at four.",
                    nodes=[
                        Node(kind="poi", coord=coord_from_latlon(lat, lon),
                             title="County museum", poi_type="museum",
                             note="Open 10–5. The mill exhibit is the reason we came.",
                             arc_stage="rising"),
                        Node(kind="event", coord=coord_from_latlon(lat, lon),
                             title="Ferry booking",
                             scheduled=ScheduledWindow(
                                 opens_at="2026-09-14T16:00:00Z",
                                 closes_at="2026-09-14T16:30:00Z",
                                 timezone="America/Denver",
                                 detail="Tickets collected at the kiosk, not on board.")),
                    ]),
        compose_day(day4_segments, day4_transitions, index=4, roles=["end"],
                    date="2026-09-15", title="Day 4 — ridge and river"),
    ]

    if with_cue_placeholder:
        # SPIKE-21 owns derivation. What SPIKE-20 must prove is that its output has
        # somewhere to land that survives the round trip.
        first = days[0].segments[0]
        days[0].cue_sheet = CueSheet(
            generated_at=now_stamp(), generator="SPIKE-20 placeholder",
            segment_ids=[first.id], geometry_digest="placeholder",
            cues=[
                Cue(sequence=0, distance_along_m=0.0, kind="start",
                    instruction="Depart the trailhead lot", segment_id=first.id),
                Cue(sequence=1, distance_along_m=1200.0, kind="turn",
                    instruction="Left onto the creek path", modifier="left",
                    bearing_deg=274.0, segment_id=first.id),
                Cue(sequence=2, distance_along_m=1200.0, kind="surface",
                    instruction="Pavement ends — gravel", segment_id=first.id),
            ],
        )

    limits = {
        "cycling": {"min_m": 15_000.0, "max_m": 90_000.0},
        "hiking": {"min_m": 2_000.0, "max_m": 18_000.0},
        "paddling": {"max_m": 25_000.0},
    }
    trip = split_trip(
        days, limits,
        title=f"{loaded.region.name} — four days",
        default_weights=_default_weights(),
        duration={"start_date": "2026-09-12", "end_date": "2026-09-15", "day_count": 4},
        provenance=Provenance(
            produced_by=ENGINE, app_version="0.0.1", sidecar_version="0.0.1",
            attribution=[
                Attribution(source="GEDTM30 (OpenTopography)", licence="CC BY 4.0",
                            credit="Elevation: GEDTM30, CC BY 4.0",
                            url="https://opentopography.org/"),
                Attribution(source="Protomaps Basemap (OpenStreetMap)", licence="ODbL",
                            credit="© OpenStreetMap",
                            url="https://www.openstreetmap.org/copyright"),
            ],
        ),
    )
    return trip


__all__ = ["build_trip", "new_id"]
