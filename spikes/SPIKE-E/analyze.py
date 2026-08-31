"""Every published figure, re-derived offline from `raw/` — no network, no clock.

    core/.venv/bin/python spikes/SPIKE-E/analyze.py

Writes `results/routing.json`, `results/coverage.json`, `results/advisory.json`, and
prints the tables `results/RESULTS.md` quotes. `run.py --dry-run` re-runs this and
asserts the verdict clauses still hold, so a reader can check the writeup against the
data without trusting either.
"""

from __future__ import annotations

import json
import random
from dataclasses import asdict

import coverage as cov
import graphs
import route as routing
from advisory import (
    DECLARABLE, LABEL, OPPORTUNISTIC_FLOOR, READ_FLOOR, Capability, advisory_cues,
    assess,
)
from filters import SHIPPED, VARIANTS
from plotlines_core.trips.cues import route_polyline
from regions import (
    APPROACHES, CORRIDOR_M, FALSE_CLEAR_CEILING_PCT, LAST_MILE_M, RESULTS,
    UNREQUESTED_BY_PRODUCT, band_for,
)

WIDEST = "drive_track"          # the variant every non-filter measurement runs on
TRIALS = 400                    # thinning trials per retention step
SEED = 20260831                 # fixed: the degrade model must reproduce exactly


# --------------------------------------------------------------------- routing

def routing_section() -> dict:
    out: dict = {"constraints": routing.driving_constraints(), "approaches": {}}
    for key, approach in APPROACHES.items():
        pull = graphs.load(f"{key}-graph")
        widest = graphs.build(pull, WIDEST)

        # The approach corridor, defined once on the widest graph so every variant is
        # measured against the same set of ways rather than against its own.
        corridor = _corridor(approach, pull)
        corridor_km_by_variant = {}

        variants = {}
        for variant in VARIANTS:
            graph = graphs.build(pull, variant)
            solved = routing.solve_one(graph, approach, variant)
            record = asdict(solved)
            record.pop("edge_key_set")
            variants[variant] = record
            corridor_km_by_variant[variant] = round(sum(
                float(data.get("length", 0.0))
                for u, v, data in graph.edges(data=True)
                if u in corridor and v in corridor
            ) / 1000.0, 2)

        shipped_km = corridor_km_by_variant[SHIPPED]
        widest_km = corridor_km_by_variant[WIDEST]
        out["approaches"][key] = {
            "name": approach.name,
            "remote": approach.remote,
            "shared_fixture": approach.shared_fixture,
            "pull": pull.meta,
            "variants": variants,
            "corridor_km": corridor_km_by_variant,
            "corridor_kept_by_shipped_pct": round(
                100.0 * shipped_km / widest_km, 1) if widest_km else 0.0,
            "weight_sweep": routing.weight_sweep(
                graphs.build(pull, WIDEST), approach, WIDEST),
        }
    return out


def _way_ids(graph) -> set:
    """Every OSM way id present, flattened out of the merged `osmid` lists osmnx's
    simplification leaves behind.

    Comparing *way ids* rather than graph edges is what makes the control a test of
    the **filter** rather than of osmnx's simplification: the same road merged into a
    different number of edges is the same set of ways, and two pulls with different
    sets of ways present is exactly the disagreement worth catching.
    """
    ids: set = set()
    for _u, _v, data in graph.edges(data=True):
        osmid = data.get("osmid")
        if isinstance(osmid, list):
            ids.update(osmid)
        elif osmid is not None:
            ids.add(osmid)
    return ids


def control_section() -> dict:
    """The offline `drive` reconstruction against a real `network_type="drive"` pull."""
    control = graphs.load("boulder-drive-control")
    live_ids = _way_ids(graphs.build(control))
    rebuilt_ids = _way_ids(graphs.build(graphs.load("boulder-graph"), "drive"))
    shared = live_ids & rebuilt_ids
    return {
        "live_pull": control.meta,
        "live_ways": len(live_ids),
        "rebuilt_ways": len(rebuilt_ids),
        "agree_ways": len(shared),
        "agreement_pct": round(100.0 * len(shared) / len(live_ids), 2) if live_ids else 0.0,
        "only_live": sorted(live_ids - rebuilt_ids)[:20],
        "only_live_count": len(live_ids - rebuilt_ids),
        "only_rebuilt": sorted(rebuilt_ids - live_ids)[:20],
        "only_rebuilt_count": len(rebuilt_ids - live_ids),
    }


# -------------------------------------------------------------------- coverage

def _corridor(approach, pull) -> set:
    """The approach corridor: every node within `CORRIDOR_M` **driving distance** of
    where the approach actually ends.

    Anchored on the solved route's final node rather than on the nearest node to the
    trailhead coordinate, because the widest pull retains disconnected components
    (`retain_all=True`) and the nearest node to a trailhead is sometimes a stub of
    track severed at the bbox edge — a corridor grown from that is two ways wide and
    says nothing about the approach.
    """
    _legal, walk, _drawn = _route_for(approach, pull)
    end_node = walk[-1][1]
    widest = graphs.build(pull, WIDEST)
    return graphs.corridor_nodes(widest, end_node, CORRIDOR_M)


def _route_for(approach, pull):
    """The solved approach as a `trips.cues.Route`, on the widest variant — the only
    one that reaches every destination, and therefore the only honest denominator for
    "what does the approach actually cross"."""
    graph = graphs.build(pull, WIDEST)
    truncated = graphs.largest_strong_component(graph)
    from plotlines_core.routing.access import mode_legal_graph
    legal = mode_legal_graph(truncated, routing.DRIVING)
    from plotlines_core.multimodal.modes import weights_for
    profile = weights_for(routing.DRIVING)
    walk = routing._walk(legal, approach, profile)
    return legal, walk, route_polyline(legal, walk)


def _last_mile_edges(drawn):
    """The final `LAST_MILE_M` of the drawn route, with each edge's length **clipped
    to the window**.

    Clipping matters on exactly the approaches this spike is about: the last edge of
    the Middle Fork route is a single simplified way tens of kilometres long, and
    counting its whole length inside a 5 km window would make the last mile longer
    than the last mile.
    """
    cut = drawn.length_m - LAST_MILE_M
    for edge in drawn.edges:
        if edge.end_m <= cut:
            continue
        data = dict(edge.data)
        data["length"] = max(0.0, edge.end_m - max(edge.start_m, cut))
        yield edge.u, edge.v, data


def product_tag_gap() -> dict:
    """What the *shipped* graph builder could not read even if FR29a were built today.

    `graph/regions.py` extends osmnx's `useful_tags_way` with `surface`, `tracktype`
    and `smoothness` — and stops there. `4wd_only` and `motor_vehicle` are never
    requested, and a tag not requested at download time is not recoverable later
    without re-downloading (`spikes/shared/README.md`'s "osmnx tag trap", found on the
    cycling side for `surface`). `barrier` is worse than unrequested: OSM tags it on
    the **node**, and osmnx's `useful_tags_node` carries none of it either.

    This is punch-list §5.3's dependency, measured — the mapping gap is not only in
    the markdown, and it reaches past FR29a into FR128's legality model.
    """
    import osmnx as ox
    import plotlines_core.graph.regions  # noqa: F401 — importing applies the product's tag list

    way_tags = set(ox.settings.useful_tags_way)
    node_tags = set(ox.settings.useful_tags_node)
    counts: dict[str, dict] = {}
    for key in APPROACHES:
        graph = graphs.build(graphs.load(f"{key}-graph"), "drive_track_private")
        ways = cov.collect(graph.edges(data=True), "network")
        counts[key] = {
            tag: sum(1 for data, _m in ways.ways.values() if cov.tag(data, tag) is not None)
            for tag in (*UNREQUESTED_BY_PRODUCT, "barrier", "access", "surface")
        }
    return {
        "product_way_tags": sorted(way_tags),
        "product_node_tags": sorted(node_tags),
        "unrequested": [t for t in (*UNREQUESTED_BY_PRODUCT, "barrier")
                        if t not in way_tags],
        "ways_carrying_tag": counts,
        "totals": {
            tag: sum(row[tag] for row in counts.values())
            for tag in (*UNREQUESTED_BY_PRODUCT, "barrier", "access", "surface")
        },
    }


def coverage_section() -> dict:
    out: dict = {"approaches": {}, "product_tag_gap": product_tag_gap()}
    for key, approach in APPROACHES.items():
        pull = graphs.load(f"{key}-graph")
        widest = graphs.build(pull, WIDEST)
        legal, walk, drawn = _route_for(approach, pull)

        corridor = _corridor(approach, pull)

        scopes = {
            "network": cov.collect(widest.edges(data=True), "network"),
            "corridor": cov.collect(
                ((u, v, d) for u, v, d in widest.edges(data=True)
                 if u in corridor and v in corridor), "corridor"),
            "route": cov.collect(walk, "route"),
            "last_mile": cov.collect(_last_mile_edges(drawn), "last_mile"),
        }
        out["approaches"][key] = {
            "name": approach.name,
            "remote": approach.remote,
            "last_mile_is_whole_route": drawn.length_m <= LAST_MILE_M,
            "scopes": {
                name: {
                    "ways": ways.count,
                    "km": round(ways.km, 2),
                    "signals": cov.signal_coverage(ways),
                    "any_signal": cov.any_signal_coverage(ways),
                    "track_prevalence": cov.prevalence(ways),
                }
                for name, ways in scopes.items()
            },
        }
    return out


# -------------------------------------------------------------------- advisory

def _edge_tuples(drawn):
    """The route's edges as `(start_m, end_m, data)` spans that **tile** the polyline.

    `trips.cues.route_polyline` sets `RouteEdge.start_index = len(coords)` *before*
    appending the edge's own points, so for every edge after the first, `start_m` is
    the distance at that edge's **second** geometry point — its first sub-segment
    belongs to no edge at all. The spans therefore do not tile: on the Boulder
    approach they cover 2,240 m of a 3,046 m route (`span_defect_section` measures it
    per approach). Anything that integrates over spans — `surface_cues`' own
    `surface_min_run_m` filter, and this advisory's flagged kilometres — under-counts
    by that much, and every cue placed at a run's start lands one sub-segment late.

    This is a defect in shipped product code, reported in `results/RESULTS.md` rather
    than fixed here (no product change is this spike's rule). The one-line correction
    is `start_index = max(0, len(coords) - 1)`; the spans below are what that fix
    produces, so the advisory is measured against a correct route rather than against
    a bug.
    """
    spans = []
    cursor = 0.0
    for edge in drawn.edges:
        spans.append((cursor, edge.end_m, edge.data))
        cursor = edge.end_m
    return spans


def span_defect_section() -> dict:
    """How much of each route falls outside every `RouteEdge` span — the measurement
    behind the `route_polyline` finding above."""
    out = {}
    for key, approach in APPROACHES.items():
        pull = graphs.load(f"{key}-graph")
        _legal, _walk, drawn = _route_for(approach, pull)
        covered = sum(edge.end_m - edge.start_m for edge in drawn.edges)
        out[key] = {
            "polyline_m": round(drawn.length_m, 1),
            "covered_by_spans_m": round(covered, 1),
            "unattributed_m": round(drawn.length_m - covered, 1),
            "unattributed_pct": round(
                100.0 * (drawn.length_m - covered) / drawn.length_m, 1)
            if drawn.length_m else 0.0,
            "edges": len(drawn.edges),
        }
    return out


def advisory_section() -> dict:
    out: dict = {"approaches": {}, "ceiling_pct": FALSE_CLEAR_CEILING_PCT}
    for key, approach in APPROACHES.items():
        pull = graphs.load(f"{key}-graph")
        legal, walk, drawn = _route_for(approach, pull)
        edges = _edge_tuples(drawn)

        # FR29a's central claim, tested rather than asserted: assessing a route must
        # not change it. Solve, assess at every declared level, solve again, compare.
        before = [(u, v, round(float(d.get("length", 0.0)), 3)) for u, v, d in walk]
        per_declaration = {}
        for declared in DECLARABLE:
            result = assess(edges, declared)
            per_declaration[LABEL[declared]] = {
                "state": result.state,
                "summary": result.summary,
                "flags": [
                    {
                        "km": [round(f.start_m / 1000.0, 2), round(f.end_m / 1000.0, 2)],
                        "length_km": round(f.length_m / 1000.0, 2),
                        "requires": LABEL[f.requires],
                        "signal": f.signal,
                        "note": f.note,
                        "way": f.way,
                    }
                    for f in result.flags
                ],
                "access_notes": [
                    {"km": round(n.start_m / 1000.0, 2), "value": n.value,
                     "note": n.note, "way": n.way}
                    for n in result.access_notes
                ],
                "route_km": result.route_km,
                "signal_pct": result.signal_pct,
                "flagged_km": result.flagged_km,
                "sections": len(result.flags),
                "raw_sections": result.raw_sections,
                "cues": advisory_cues(result),
            }
        _legal2, walk2, _drawn2 = _route_for(approach, pull)
        after = [(u, v, round(float(d.get("length", 0.0)), 3)) for u, v, d in walk2]

        # Which honesty floor should gate `no_contrary_signal`? The pre-registered
        # `opportunistic` band (20%) is where this started; the `read` band (70%) is
        # the alternative, and the degrade model below is the argument between them.
        floors = {}
        for label, floor in (("opportunistic_20", OPPORTUNISTIC_FLOOR),
                             ("read_70", READ_FLOOR)):
            result = assess(edges, Capability.TWO_WD, floor=floor)
            floors[label] = {"state": result.state, "signal_pct": result.signal_pct}

        out["approaches"][key] = {
            "name": approach.name,
            "remote": approach.remote,
            "route_unchanged_by_assessment": before == after,
            "by_declaration": per_declaration,
            "floor_sensitivity": floors,
            "degrade": {
                "opportunistic_20": degrade(edges, OPPORTUNISTIC_FLOOR),
                "read_70": degrade(edges, READ_FLOOR),
            },
        }
    return out


# --------------------------------------------------------------------- degrade

def degrade(edges, floor: float) -> dict:
    """What thin tagging does to this advisory — the harm model.

    SPIKE-C found that a *difficulty* grade fails **low** under thinning, because it
    is a worst-of over a sample. An access advisory is an **any-of**: one tagged rough
    section is enough to raise the flag, so thinning it produces one of two very
    different outcomes, and only the second is dangerous:

      * `insufficient_signal` — coverage falls under the floor and the surface says
        so. A loss of capability, nothing worse.
      * `no_contrary_signal` — enough tags survive to clear the honesty floor, but
        the rough ones are not among them. **The surface prints a clear line about a
        road it can no longer see.**

    The trial keeps each *way's* signals with probability `r` (a way is the unit a
    mapper edits, so dropping per-edge would model a mapper who tagged half a road),
    with a fixed seed per trial so the table reproduces exactly.
    """
    truth = assess(edges, Capability.TWO_WD, floor=floor)
    if truth.state != "flagged":
        return {"applicable": False, "reason": f"baseline state is {truth.state}"}

    keys = ("surface", "smoothness", "tracktype", "4wd_only", "ford")
    steps = [round(0.05 * i, 2) for i in range(1, 21)]
    rows = []
    for retention in steps:
        outcomes = {"flagged": 0, "no_contrary_signal": 0, "insufficient_signal": 0}
        for trial in range(TRIALS):
            rng = random.Random((SEED, retention, trial).__hash__())
            thinned = []
            keep_way: dict = {}
            for start_m, end_m, data in edges:
                way = str(data.get("osmid"))
                if way not in keep_way:
                    keep_way[way] = rng.random() < retention
                if keep_way[way]:
                    thinned.append((start_m, end_m, data))
                else:
                    stripped = {k: v for k, v in data.items() if k not in keys}
                    thinned.append((start_m, end_m, stripped))
            outcomes[assess(thinned, Capability.TWO_WD, floor=floor).state] += 1
        rows.append({
            "retention_pct": round(retention * 100, 1),
            **{k: round(100.0 * v / TRIALS, 1) for k, v in outcomes.items()},
        })

    # The harm-derived floor, read off the way SPIKE-C read its ≈32–38%: the highest
    # retention at which the confidently-wrong outcome still breaches the ceiling
    # declared before the model was written. Above it the feature is thin; at or below
    # it the feature is a lie an Author acts on.
    breaching = [r["retention_pct"] for r in rows
                 if r["no_contrary_signal"] > FALSE_CLEAR_CEILING_PCT]
    floor = max(breaching) if breaching else None
    return {
        "applicable": True,
        "floor_pct": floor,
        "baseline_flags": len(truth.flags),
        "baseline_signal_pct": truth.signal_pct,
        "rows": rows,
        "worst_false_clear_pct": max(r["no_contrary_signal"] for r in rows),
        "false_clear_ceiling_pct": FALSE_CLEAR_CEILING_PCT,
        "highest_retention_breaching_ceiling_pct": floor,
    }


# ----------------------------------------------------------------------- print

def _print_routing(data: dict) -> None:
    print("\n== routing: does the graph contain the last mile? ==")
    header = f"{'approach':12s} {'variant':22s} {'edges':>7s} {'legal':>7s} " \
             f"{'corridor km':>11s} {'km':>7s} {'arrive m':>9s} {'solve ms':>9s} {'paved%':>7s}"
    print(header)
    for key, block in data["approaches"].items():
        for variant, row in block["variants"].items():
            print(f"{key:12s} {variant:22s} {row['edges']:7d} {row['legal_edges']:7d} "
                  f"{block['corridor_km'][variant]:11.2f} "
                  f"{row['distance_m'] / 1000.0:7.2f} {row['arrival_gap_m']:9.0f} "
                  f"{row['solve_ms']:9.1f} {row['composition'].get('paved_pct', 0):7.1f}")

    print("\n== driving weights: does any dial change the route? ==")
    for key, block in data["approaches"].items():
        changed = [r for r in block["weight_sweep"] if not r["identical_to_shipped"]]
        print(f"{key:12s} {len(changed)}/{len(block['weight_sweep']) - 1} cases differ "
              f"from shipped; worst overlap "
              f"{min(r['edge_overlap_pct'] for r in block['weight_sweep'])}%")

    print("\n== reported time: flat 60 km/h vs the tags on the edge ==")
    for key, block in data["approaches"].items():
        row = block["variants"][WIDEST]
        flat, aware = row["time_flat_min"], row["time_surface_aware_min"]
        print(f"{key:12s} {row['distance_m'] / 1000.0:6.2f} km  flat {flat:6.1f} min  "
              f"surface-aware {aware:6.1f} min  error {100.0 * (flat - aware) / aware:+6.1f}%")


def _print_coverage(data: dict) -> None:
    print("\n== FR29a signal coverage, % of ways (% of km) ==")
    signals = list(cov.ELIGIBILITY)
    print(f"{'approach':12s} {'scope':10s} {'ways':>6s} {'km':>8s} "
          + " ".join(f"{s:>16s}" for s in signals) + f" {'any':>16s}")
    for key, block in data["approaches"].items():
        for scope, row in block["scopes"].items():
            cells = []
            for signal in signals:
                cell = row["signals"][signal]
                cells.append(f"{cell['pct_ways']:6.1f}({cell['pct_km']:5.1f})"
                             f"{'*' if cell['band'] == 'n/a' else ' '}"[:16].rjust(16))
            any_cell = row["any_signal"]
            print(f"{key:12s} {scope:10s} {row['ways']:6d} {row['km']:8.1f} "
                  + " ".join(cells)
                  + f" {any_cell['pct_ways']:6.1f}({any_cell['pct_km']:5.1f})".rjust(17))
    print("  * = under 30 eligible ways: n/a, not absent")
    gap = data["product_tag_gap"]
    print(f"\n  tags the shipped graph builder never downloads: "
          f"{', '.join(gap['unrequested'])}")
    print(f"  ways carrying them in these four pulls: "
          + ", ".join(f"{tag}={gap['totals'][tag]}" for tag in gap['unrequested']))


def _print_advisory(data: dict) -> None:
    print("\n== the advisory, flagging without excluding ==")
    for key, block in data["approaches"].items():
        print(f"\n{key} — route unchanged by assessment: "
              f"{block['route_unchanged_by_assessment']}")
        for declared, row in block["by_declaration"].items():
            print(f"  declared {declared:14s} {row['state']:20s} "
                  f"{row['sections']} section(s) from {row['raw_sections']} raw, "
                  f"{row['flagged_km']:.1f} km")
        first = block["by_declaration"]["2WD"]
        print(f"  2WD summary: {first['summary']}")
        for cue in first["cues"][:3]:
            print(f"    cue @{cue['distance_along_m'] / 1000.0:6.2f} km: {cue['instruction']}")
        for label, degraded in block["degrade"].items():
            if degraded.get("applicable"):
                print(f"  degrade @floor {label}: worst false-clear "
                      f"{degraded['worst_false_clear_pct']}% (ceiling "
                      f"{degraded['false_clear_ceiling_pct']}%), breached up to "
                      f"{degraded['highest_retention_breaching_ceiling_pct']}% retention")
            else:
                print(f"  degrade @floor {label}: n/a — {degraded['reason']}")
        print("  floor sensitivity: " + ", ".join(
            f"{label}={row['state']}" for label, row in block["floor_sensitivity"].items()))


def main() -> int:
    RESULTS.mkdir(parents=True, exist_ok=True)

    routing_data = routing_section()
    routing_data["filter_control"] = control_section()
    routing_data["cue_span_defect"] = span_defect_section()
    coverage_data = coverage_section()
    advisory_data = advisory_section()

    (RESULTS / "routing.json").write_text(json.dumps(routing_data, indent=2) + "\n")
    (RESULTS / "coverage.json").write_text(json.dumps(coverage_data, indent=2) + "\n")
    (RESULTS / "advisory.json").write_text(json.dumps(advisory_data, indent=2) + "\n")

    _print_routing(routing_data)
    print(f"\nfilter control (boulder, live network_type='drive'): "
          f"{routing_data['filter_control']['agreement_pct']}% way agreement "
          f"({routing_data['filter_control']['only_live']} live-only, "
          f"{routing_data['filter_control']['only_rebuilt']} rebuilt-only)")
    _print_coverage(coverage_data)
    _print_advisory(advisory_data)
    print(f"\nwrote {RESULTS}/routing.json, coverage.json, advisory.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
