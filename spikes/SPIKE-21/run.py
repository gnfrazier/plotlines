"""SPIKE-21 — cue derivation from a routed polyline.

    PYTHONPATH=core .venv/bin/python spikes/SPIKE-21/run.py [--regions boulder,davis,viroqua]

The spike question is a subtraction problem: a solved route is a sequence of junctions
with a bending polyline and flickering surface tags, and a cue sheet is what is left
after the noise is removed. So this measures the removal, not just the result — every
scenario reports the naive baselines (one cue per polyline vertex, one per junction,
one per bend over threshold) beside the derived sheet, because "12 cues" means nothing
without "and it started from 1,600 candidates".

What it runs, per region:

  * three route shapes on the shared SPIKE-01/02/03 graphs — a cross-town
    point-to-point, a plain 20 km loop, and a 20 km loop through two via-nodes (the
    retrace case SPIKE-01 found)
  * a parameter sweep over the two thresholds that do the real filtering, so the
    defaults are a measured plateau rather than a guess
  * Author-placed nodes, hazards, a portage and an alternate — including one node
    deliberately off-route, to exercise the corridor rule
  * schema conformance against SPIKE-20's `trip_payload.schema.json`, and the same
    payload pushed through SPIKE-20's Dart round-trip harness

Exits non-zero if any self-check fails, so this works as a CI gate.
"""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

SPIKE = Path(__file__).resolve().parent
SPIKES = SPIKE.parent
ROOT = SPIKES.parent
sys.path.insert(0, str(SPIKES / "shared"))

import jsonschema  # noqa: E402

from plotlines_core.routing.loops import generate_loop, offset, solve_circuit  # noqa: E402
from plotlines_core.scoring.metrics import edge_walk, measure  # noqa: E402
from plotlines_core.scoring.profile import THEMES  # noqa: E402
from plotlines_core.trips.compose import compose_day, split_trip  # noqa: E402
from plotlines_core.trips.cues import (  # noqa: E402
    CueSettings, cues_per_window, derive_cue_sheet, route_polyline, signed_turn,
    surface_class,
)
from plotlines_core.trips.payload import (  # noqa: E402
    Alternate, Attribution, Hazard, LineString, Node, Portage, Provenance,
    RouteMetrics, Segment, SolveProvenance, TargetDistance, WeightProfile,
    coord_from_latlon, dumps, now_stamp,
)

SCHEMA_PATH = ROOT / "docs" / "schemas" / "trip_payload.schema.json"
RESULTS = SPIKE / "results"
SAMPLES = RESULTS / "samples"
DART_DIR = SPIKES / "SPIKE-20" / "dart"
DART_OUT = RESULTS / "dart"

#: The ceiling this spike judges legibility against. A cue every 250 m is readable on a
#: handlebar; one every 60 m is a wall of text. Stated up front so the measurement can
#: fail rather than be graded afterwards.
LEGIBLE_CUES_PER_KM = 4.0
PEAK_CUES_PER_KM = 8.0


# ------------------------------------------------------------------- scenarios

def _solve_p2p(bench, key):
    loaded = bench.regions[key]
    graph = loaded.graph
    lat, lon = loaded.region.centre
    start, end = (lat, lon), offset(lat, lon, 95.0, 4200.0)
    profile = THEMES["quiet_scenic"]
    circuit = solve_circuit(graph, [bench.snap(key, start), bench.snap(key, end)],
                            profile, close=False)
    walk = edge_walk(graph, circuit.path, profile)
    return {"shape": "point_to_point", "walk": walk, "profile": profile,
            "metrics": measure(graph, walk), "start": start, "end": end, "via": []}


def _solve_loop(bench, key, via_count: int, target_m: float = 20_000.0):
    loaded = bench.regions[key]
    graph = loaded.graph
    lat, lon = loaded.region.centre
    via = bench.via_points(key, via_count) if via_count else []
    loop = generate_loop(graph, (lat, lon), target_m, THEMES["gravel"], via=via)
    return {"shape": "loop", "walk": loop.walk, "profile": THEMES["gravel"],
            "metrics": loop.metrics, "start": (lat, lon), "end": None, "via": via,
            "loop": loop}


def _off_route_point(route, near: list[float], minimum_m: float = 500.0) -> list[float]:
    """A point far enough from the route that no corridor rule could claim it."""
    for metres in (minimum_m, 1_000.0, 2_000.0, 4_000.0, 8_000.0):
        for bearing in (0.0, 90.0, 180.0, 270.0):
            lat, lon = offset(near[1], near[0], bearing, metres)
            candidate = coord_from_latlon(lat, lon)
            _, away = route.project(candidate)
            if away > minimum_m:
                return candidate
    return coord_from_latlon(*offset(near[1], near[0], 0.0, 20_000.0))


def _author_content(route, region_name: str):
    """Author-placed content on (and beside) the route — the F1 inputs that are not
    derived from geometry: nodes, hazards, a portage, an alternate."""
    length = route.length_m

    def at(fraction: float):
        return route.point_at(length * fraction)

    nodes = [
        Node(kind="regroup", coord=at(0.18), title="Regroup at the bridge",
             note="Wait here — the next stretch has no shoulder."),
        Node(kind="rest_stop", coord=at(0.42), title="Corner store",
             amenities=["water", "food"]),
        Node(kind="poi", coord=at(0.43), title="Old mill race", poi_type="viewpoint",
             note="Two minutes off the road, worth it."),
        Node(kind="transition", coord=at(0.66), title="Boat stash",
             instructions="Boats are 40 m upstream of the gauge post."),
        Node(kind="poi", coord=at(0.88), title=f"{region_name} overlook",
             poi_type="viewpoint"),
        # Deliberately off-route, to prove the corridor rule fires and is counted
        # rather than silently dropping an Author's node. Placed by pushing away from
        # the route until it is unambiguously outside — a fixed offset is not enough,
        # because a loop can fold back and pass close to wherever you put it.
        Node(kind="poi", coord=_off_route_point(route, at(0.5)),
             title="Off-route diner", poi_type="restaurant"),
    ]
    hazards = [
        Hazard(severity="high", title="Cattle guard on the descent",
               safety_note="Cross square — slick when wet.", coord=at(0.30)),
        Hazard(severity="mandatory_reroute", title="Low-head dam",
               safety_note="Do not run. Take out river left.", coord=at(0.67)),
    ]
    portages = [Portage(
        geometry=LineString(coordinates=[at(0.67), at(0.68)], source="authored"),
        exit_bank="river_left", distance_m=180.0, mandatory=True, surface="gravel")]
    alternates = [Alternate(
        kind="bypass", label="Valley road bypass",
        geometry=LineString(coordinates=[at(0.55), at(0.62)], source="authored"),
        diverges_at_m=length * 0.55, rejoins_at_m=length * 0.62)]
    return nodes, hazards, portages, alternates


# -------------------------------------------------------------------- baselines

def _baselines(graph, route, settings: CueSettings) -> dict:
    """What the naive algorithms would have emitted, on the same geometry.

    Three of them, each a plausible first implementation:
      * one cue per polyline vertex — the strawman the spike names
      * one cue per junction the route passes through
      * one cue per bend over threshold, with no junction test — the version that
        looks careful and still cues every switchback
    """
    length_km = (route.length_m / 1000.0) or 1.0
    bends = 0
    for index in range(len(route.edges) - 1):
        incoming, outgoing = route.edges[index], route.edges[index + 1]
        before = route.bearing_before(incoming.end_index, settings.smoothing_m)
        after = route.bearing_after(outgoing.start_index, settings.smoothing_m)
        if before is None or after is None:
            continue
        if abs(signed_turn(before, after)) >= settings.straight_deg:
            bends += 1

    # The unsmoothed variant: bearings from adjacent vertices, as a first cut would.
    raw_bends = 0
    coords = route.coords
    for index in range(1, len(coords) - 1):
        from plotlines_core.trips.cues import bearing_deg
        before = bearing_deg(tuple(coords[index - 1]), tuple(coords[index]))
        after = bearing_deg(tuple(coords[index]), tuple(coords[index + 1]))
        if abs(signed_turn(before, after)) >= settings.straight_deg:
            raw_bends += 1

    return {
        "per_vertex": len(route.coords),
        "per_vertex_per_km": round(len(route.coords) / length_km, 1),
        "per_junction": len(route.edges) - 1,
        "per_junction_per_km": round((len(route.edges) - 1) / length_km, 1),
        "bend_over_threshold_no_junction_test": bends,
        "bend_over_threshold_per_km": round(bends / length_km, 1),
        "unsmoothed_bend_over_threshold": raw_bends,
        "unsmoothed_bend_per_km": round(raw_bends / length_km, 1),
    }


# --------------------------------------------------------------------- sweeps

def _sweep(graph, walk, nodes, hazards, portages, alternates) -> list[dict]:
    """The two thresholds that do the filtering, swept over the same route."""
    rows = []
    for smoothing in (10.0, 25.0, 50.0):
        for straight in (20.0, 30.0, 45.0):
            settings = CueSettings(smoothing_m=smoothing, straight_deg=straight)
            _, stats = derive_cue_sheet(
                graph, walk, nodes=nodes, hazards=hazards, portages=portages,
                alternates=alternates, settings=settings)
            rows.append({
                "smoothing_m": smoothing, "straight_deg": straight,
                "turns": stats["turns"]["emitted"],
                "cues": stats["cues"], "cues_per_km": stats["cues_per_km"],
            })
    return rows


# --------------------------------------------------------------------- sheets

_KIND_GLYPH = {"start": "▶", "finish": "■", "turn": "↰", "surface": "▚",
               "node": "◆", "hazard": "⚠", "portage": "⛰", "transition": "⇄",
               "event": "◷", "alternate": "⤳"}


def render_sheet(sheet, title: str, route_m: float) -> str:
    """The cue sheet as a rider would read it. This is the legibility evidence — a
    density number can look fine while the document is unreadable."""
    lines = [f"# {title}", "",
             f"_{route_m / 1000:.1f} km · {len(sheet.cues)} cues · "
             f"{len(sheet.cues) / (route_m / 1000):.1f} per km_", "",
             "| At | | Cue |", "|---:|:--:|---|"]
    for cue in sheet.cues:
        glyph = _KIND_GLYPH.get(cue.kind, "·")
        text = cue.instruction or cue.kind
        if cue.retrace:
            text = f"{text}  _(retrace)_"
        lines.append(f"| {cue.distance_along_m / 1000:.2f} km | {glyph} | {text} |")
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------ validation

def _payload_for(region_name: str, scenarios: list[dict]) -> dict:
    """Wrap the derived sheets in a real trip payload, so schema conformance is
    tested on the shape a client would actually store."""
    days = []
    for index, scenario in enumerate(scenarios, start=1):
        route = scenario["route"]
        metrics = scenario["metrics"]
        segment = Segment(
            mode="cycling", shape=scenario["shape"], title=scenario["name"],
            start=coord_from_latlon(*scenario["start"]),
            end=coord_from_latlon(*scenario["end"]) if scenario["end"] else None,
            via=[coord_from_latlon(*point) for point in scenario["via"]],
            target_distance=(TargetDistance(value_m=20_000.0, min_m=17_000.0,
                                            max_m=23_000.0)
                             if scenario["shape"] == "loop" else None),
            geometry=LineString(coordinates=route.coords, source="solved"),
            metrics=RouteMetrics(distance_m=metrics.distance_m, climb_m=metrics.climb_m,
                                 descent_m=metrics.descent_m, traffic=metrics.traffic,
                                 unpaved_frac=metrics.unpaved_frac,
                                 edge_count=metrics.edge_count),
            weights=WeightProfile(name="gravel", climbing=4.0, traffic=0.5,
                                  surface={"paved": 1.0, "gravel": 5.0}),
            nodes=scenario["nodes"], hazards=scenario["hazards"],
            portages=scenario["portages"], alternates=scenario["alternates"],
            solve=SolveProvenance(engine_version="plotlines-core 0.0.1",
                                  graph_region=region_name, solved_at=now_stamp()),
        )
        day = compose_day([segment], [], index=index, title=scenario["name"])
        day.cue_sheet = scenario["sheet"]
        day.cue_sheet.segment_ids = [segment.id]
        for position, cue in enumerate(day.cue_sheet.cues):
            day.cue_sheet.cues[position].segment_id = segment.id
        days.append(day)

    trip = split_trip(days, {}, title=f"{region_name} — SPIKE-21 cue sheets",
                      provenance=Provenance(
                          produced_by="plotlines-core 0.0.1",
                          attribution=[Attribution(
                              source="OpenStreetMap", licence="ODbL",
                              credit="© OpenStreetMap")]))
    return trip.to_dict()


def _validate(validator, payload: dict) -> list[str]:
    return [f"{'/'.join(str(p) for p in e.absolute_path) or '/'}: {e.message}"
            for e in validator.iter_errors(payload)]


def _dart_roundtrip(payload_path: Path) -> dict:
    """Push the cue-sheet payload through SPIKE-20's Dart harness.

    SPIKE-20 proved the payload survives the client; this proves the *derived* half
    does too, including the `retrace` field this spike added to the schema. If the
    harness is not set up, that is recorded rather than treated as a failure — the
    Dart toolchain is not required to derive a cue.
    """
    DART_OUT.mkdir(parents=True, exist_ok=True)
    try:
        proc = subprocess.run(
            ["dart", "run", "bin/roundtrip.dart", "--input", str(payload_path),
             "--outdir", str(DART_OUT)],
            cwd=DART_DIR, capture_output=True, text=True, timeout=600)
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        return {"ran": False, "reason": str(exc)}
    report = DART_OUT / f"{payload_path.stem}.dart_report.json"
    if proc.returncode != 0 or not report.exists():
        return {"ran": True, "ok": False, "stderr": proc.stderr[-1500:]}
    data = json.loads(report.read_text())
    original = json.loads(payload_path.read_text())
    returned = json.loads(Path(data["reserialized_path"]).read_text())

    def sheets(payload):
        return [day.get("cue_sheet") for day in payload["days"] if day.get("cue_sheet")]

    before, after = sheets(original), sheets(returned)
    return {
        "ran": True, "ok": True,
        "byte_identical": data.get("byte_identical_to_producer"),
        "drift_bytes_identical": data.get("drift_bytes_identical"),
        "cue_sheets": len(before),
        "cues_before": sum(len(s["cues"]) for s in before),
        "cues_after": sum(len(s["cues"]) for s in after),
        "retrace_flags_before": sum(1 for s in before for c in s["cues"] if c.get("retrace")),
        "retrace_flags_after": sum(1 for s in after for c in s["cues"] if c.get("retrace")),
        "cues_identical": before == after,
    }


# ------------------------------------------------------------------------ run

def run(bench, regions: list[str]) -> dict:
    schema = json.loads(SCHEMA_PATH.read_text())
    jsonschema.validators.validator_for(schema).check_schema(schema)
    validator = jsonschema.validators.validator_for(schema)(schema)
    settings = CueSettings(legible_cues_per_km=LEGIBLE_CUES_PER_KM)

    out: dict = {
        "spike": "SPIKE-21",
        "question": "Turn/surface/node cue derivation from a solved polyline, at a "
                    "density a rider can read.",
        "legibility_ceiling": {"mean_cues_per_km": LEGIBLE_CUES_PER_KM,
                               "peak_cues_per_km": PEAK_CUES_PER_KM},
        "settings": settings.__dict__,
        "environment": bench.environment(),
        "regions": [],
        "failures": [],
    }
    SAMPLES.mkdir(parents=True, exist_ok=True)

    for key in regions:
        loaded = bench.regions[key]
        graph = loaded.graph
        region_out: dict = {"region": key, "name": loaded.region.name,
                            "surface_tagged_pct": loaded.stats["surface_tagged_pct"],
                            "scenarios": []}
        scenarios = []

        specs = [("cross-town point-to-point", lambda: _solve_p2p(bench, key)),
                 ("20 km loop", lambda: _solve_loop(bench, key, 0)),
                 ("20 km loop through two via-nodes", lambda: _solve_loop(bench, key, 2))]

        for name, solve in specs:
            started = time.perf_counter()
            solved = solve()
            solve_ms = (time.perf_counter() - started) * 1000.0
            walk = solved["walk"]
            route = route_polyline(graph, walk)
            nodes, hazards, portages, alternates = _author_content(
                route, loaded.region.name.split(",")[0])

            derive_started = time.perf_counter()
            sheet, stats = derive_cue_sheet(
                graph, walk, nodes=nodes, hazards=hazards, portages=portages,
                alternates=alternates, settings=settings,
                start_label=f"Depart {loaded.region.name.split(',')[0]}",
                finish_label="Arrive")
            derive_ms = (time.perf_counter() - derive_started) * 1000.0

            buckets = cues_per_window(sheet.cues, 1000.0, route.length_m)
            scenario = {
                "name": name, "shape": solved["shape"], "solve_ms": round(solve_ms, 1),
                "derive_ms": round(derive_ms, 2),
                "baselines": _baselines(graph, route, settings),
                "stats": stats,
                "peak_cues_per_km": max(buckets) if buckets else 0,
                "median_cues_per_km": (round(statistics.median(buckets), 1)
                                       if buckets else 0),
                # Judged on the derived half — see the note in `derive_cue_sheet`.
                "legible": (stats["derived_cues_per_km"] <= LEGIBLE_CUES_PER_KM
                            and (max(buckets) if buckets else 0) <= PEAK_CUES_PER_KM),
            }
            region_out["scenarios"].append(scenario)

            scenarios.append({
                "name": name, "shape": solved["shape"], "route": route,
                "metrics": solved["metrics"], "sheet": sheet, "nodes": nodes,
                "hazards": hazards, "portages": portages, "alternates": alternates,
                "start": solved["start"], "end": solved["end"], "via": solved["via"],
            })

            sample = SAMPLES / f"{key}_{solved['shape']}{'_via' if solved['via'] else ''}.md"
            sample.write_text(render_sheet(
                sheet, f"{loaded.region.name} — {name}", route.length_m))

        # Threshold sweep on the via-loop, the busiest of the three.
        busiest = scenarios[-1]
        region_out["sweep"] = _sweep(graph, specs and _solve_loop(bench, key, 2)["walk"],
                                     busiest["nodes"], busiest["hazards"],
                                     busiest["portages"], busiest["alternates"])

        payload = _payload_for(loaded.region.name, scenarios)
        errors = _validate(validator, payload)
        region_out["schema_errors"] = errors
        payload_path = RESULTS / "payloads" / f"{key}_cues.json"
        payload_path.parent.mkdir(parents=True, exist_ok=True)
        payload_path.write_text(dumps(payload) + "\n")
        region_out["payload_bytes"] = len(payload_path.read_bytes())

        out["regions"].append(region_out)

    # One Dart round trip, on the largest payload — the derived half of the payload
    # crossing the same boundary SPIKE-20 measured.
    biggest = max(out["regions"], key=lambda r: r["payload_bytes"])
    out["dart"] = _dart_roundtrip(RESULTS / "payloads" / f"{biggest['region']}_cues.json")
    out["dart_region"] = biggest["region"]

    # ---- self-checks -----------------------------------------------------
    failures = out["failures"]
    for region in out["regions"]:
        if region["schema_errors"]:
            failures.append(f"{region['region']}: cue payload failed the schema")
        for scenario in region["scenarios"]:
            stats = scenario["stats"]
            if not scenario["legible"]:
                failures.append(
                    f"{region['region']}/{scenario['shape']}: "
                    f"{stats['derived_cues_per_km']} derived cues/km "
                    f"(peak {scenario['peak_cues_per_km']}/km all kinds) "
                    f"exceeds the ceiling")
            if stats["nodes"]["off_route"] != 1:
                failures.append(
                    f"{region['region']}/{scenario['shape']}: corridor rule caught "
                    f"{stats['nodes']['off_route']} off-route nodes, expected 1")
            if stats["by_kind"].get("hazard", 0) != 2:
                failures.append(
                    f"{region['region']}/{scenario['shape']}: "
                    f"{stats['by_kind'].get('hazard', 0)} hazard cues, expected 2 "
                    f"(safety cues must never merge away)")
        via = [s for s in region["scenarios"] if "via" in s["name"]]
        if via and via[0]["stats"]["retrace"]["retraced_span_m"] > 0 \
                and via[0]["stats"]["retrace"]["cues_marked"] == 0:
            failures.append(f"{region['region']}: retraced road produced no marked cues")
    dart = out["dart"]
    if dart.get("ran") and dart.get("ok") is False:
        failures.append("dart round-trip of the cue payload failed")
    if dart.get("ok") and not dart.get("cues_identical"):
        failures.append("cue sheets changed crossing the client boundary")
    if dart.get("ok") and not dart.get("retrace_flags_after"):
        failures.append("the retrace flag did not survive the client boundary")

    out["passed"] = not failures
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--regions", default="boulder,davis,viroqua")
    args = parser.parse_args()
    regions = [r.strip() for r in args.regions.split(",") if r.strip()]

    from harness import Bench  # noqa: PLC0415 — pulls osmnx and the graph fixtures

    with Bench.setup(regions) as bench:
        results = run(bench, regions)

    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "results.json").write_text(json.dumps(results, indent=2) + "\n")

    for region in results["regions"]:
        for scenario in region["scenarios"]:
            stats = scenario["stats"]
            print(f"{region['region']:<8} {scenario['shape']:<15} "
                  f"{stats['route_m'] / 1000:5.1f} km  "
                  f"{stats['cues']:>3} cues  {stats['cues_per_km']:>5.2f}/km "
                  f"({stats['derived_cues_per_km']:>4.2f} derived)  "
                  f"peak {scenario['peak_cues_per_km']:>2}  "
                  f"(vertices {scenario['baselines']['per_vertex_per_km']:>6.1f}/km, "
                  f"junctions {scenario['baselines']['per_junction_per_km']:>5.1f}/km)")
    if results["failures"]:
        print("\nFAILURES:")
        for failure in results["failures"]:
            print(f"  - {failure}")
        return 1
    print("\nAll self-checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
