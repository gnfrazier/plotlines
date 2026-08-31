"""The gate: re-derive every published figure and assert the verdict still holds.

    core/.venv/bin/python spikes/SPIKE-E/run.py --dry-run

Offline and deterministic — the same discipline as SPIKE-F's nine verdict clauses and
SPIKE-G's `--dry-run`. Each clause below is a sentence from `results/RESULTS.md`
turned back into an assertion, so the writeup cannot drift from the data without this
exiting non-zero.
"""

from __future__ import annotations

import sys

import analyze
from advisory import Capability, assess
from filters import SHIPPED
from regions import APPROACHES, FALSE_CLEAR_CEILING_PCT

WIDEST = analyze.WIDEST


def clauses() -> list[tuple[str, bool, str]]:
    routing = analyze.routing_section()
    routing["filter_control"] = analyze.control_section()
    routing["cue_span_defect"] = analyze.span_defect_section()
    coverage = analyze.coverage_section()
    advisory = analyze.advisory_section()

    out: list[tuple[str, bool, str]] = []

    def check(name: str, ok: bool, detail: str) -> None:
        out.append((name, bool(ok), detail))

    # ---- routing ---------------------------------------------------------
    boulder = routing["approaches"]["boulder"]["variants"]
    check(
        "shipped drive filter loses the Gregory Canyon trailhead road",
        boulder[SHIPPED]["arrival_gap_m"] > 200.0
        and boulder["drive_service"]["arrival_gap_m"] < 50.0,
        f"{boulder[SHIPPED]['arrival_gap_m']:.0f} m short on `drive`, "
        f"{boulder['drive_service']['arrival_gap_m']:.0f} m on `drive_service`",
    )
    check(
        "the shortfall is silent — the route solves and reports success",
        boulder[SHIPPED]["ok"] and not boulder[SHIPPED]["dest_outside_guard"],
        "solved, and the 3 km snap guard does not trip at 265 m",
    )
    bigsandy = routing["approaches"]["bigsandy"]
    check(
        "the shipped filter keeps under half the remote approach corridor",
        bigsandy["corridor_kept_by_shipped_pct"] < 50.0,
        f"{bigsandy['corridor_kept_by_shipped_pct']}% of corridor km "
        f"({bigsandy['corridor_km'][SHIPPED]} of {bigsandy['corridor_km'][WIDEST]} km)",
    )
    slowest = max(row["solve_ms"] for block in routing["approaches"].values()
                  for row in block["variants"].values())
    check(
        "solve time is not the problem: every cold solve is under 100 ms",
        slowest < 100.0,
        f"slowest cold solve {slowest} ms",
    )
    inert = [
        key for key, block in routing["approaches"].items()
        if all(row["identical_to_shipped"] for row in block["weight_sweep"]
               if row["case"].startswith("surface_paved"))
    ]
    check(
        "surface_paved changes no route at driving's shipped directness",
        len(inert) >= 3,
        f"identical in {len(inert)} of 4 approaches: {', '.join(inert)}",
    )
    flat = routing["approaches"]["bigsandy"]["variants"][WIDEST]
    check(
        "the flat 60 km/h speed under-reports the canonical approach by over a third",
        (flat["time_surface_aware_min"] - flat["time_flat_min"])
        / flat["time_surface_aware_min"] > 0.33,
        f"{flat['time_flat_min']} min reported vs {flat['time_surface_aware_min']} min "
        f"surface-aware",
    )
    check(
        "the offline filter reconstruction matches a live `drive` pull",
        routing["filter_control"]["agreement_pct"] > 99.0,
        f"{routing['filter_control']['agreement_pct']}% way agreement",
    )
    worst_span = max(row["unattributed_pct"] for row in routing["cue_span_defect"].values())
    check(
        "cues.route_polyline's edge spans do not tile the route",
        worst_span > 10.0,
        f"up to {worst_span}% of route length belongs to no RouteEdge span",
    )

    # ---- coverage --------------------------------------------------------
    scopes = {key: block["scopes"] for key, block in coverage["approaches"].items()}
    total_ways = sum(scope["network"]["ways"] for scope in scopes.values())
    total_km = sum(scope["network"]["km"] for scope in scopes.values())
    check(
        "4wd_only is absent everywhere — not one tagged way in four regions",
        all(scope["network"]["signals"]["4wd_only"]["tagged_ways"] == 0
            for scope in scopes.values()),
        f"0 of {total_ways:,} ways / {total_km:,.0f} km across the four regions",
    )
    gap = coverage["product_tag_gap"]
    check(
        "the product's graph builder cannot read two of FR29a's six signals at all",
        {"4wd_only", "motor_vehicle"} <= set(gap["unrequested"]),
        f"unrequested: {', '.join(gap['unrequested'])} — "
        f"{gap['totals']['motor_vehicle']} ways carry motor_vehicle in these pulls",
    )
    check(
        "and `barrier` is a node tag no product graph carries in any form",
        "barrier" not in gap["product_way_tags"]
        and "barrier" not in gap["product_node_tags"],
        "routing/access.py's _BARRIER_DEFAULTS — including driving's gate row — is "
        "unreachable on a product-built graph",
    )
    check(
        "smoothness is absent at network scale in every region",
        all(scope["network"]["signals"]["smoothness"]["band"] == "absent"
            for scope in scopes.values()),
        ", ".join(f"{k}={s['network']['signals']['smoothness']['pct_ways']}%"
                  for k, s in scopes.items()),
    )
    check(
        "the approach is better surveyed than the network at large where it matters",
        scopes["bigsandy"]["route"]["any_signal"]["pct_km"]
        > scopes["bigsandy"]["network"]["any_signal"]["pct_km"],
        f"bigsandy route {scopes['bigsandy']['route']['any_signal']['pct_km']}% km vs "
        f"network {scopes['bigsandy']['network']['any_signal']['pct_km']}%",
    )
    check(
        "and worse on the one that ends on a service road",
        scopes["middlefork"]["last_mile"]["any_signal"]["pct_km"] < 5.0,
        f"middlefork last mile {scopes['middlefork']['last_mile']['any_signal']['pct_km']}% km",
    )

    # ---- advisory --------------------------------------------------------
    check(
        "assessing a route never changes it",
        all(block["route_unchanged_by_assessment"]
            for block in advisory["approaches"].values()),
        "identical edge walk before and after assessment, all four approaches",
    )
    big = advisory["approaches"]["bigsandy"]["by_declaration"]
    check(
        "a 2WD declaration is flagged on the canonical approach and 4WD is not",
        big["2WD"]["state"] == "flagged" and big["4WD"]["state"] != "flagged",
        f"2WD: {big['2WD']['sections']} section(s), {big['2WD']['flagged_km']} km; "
        f"4WD: {big['4WD']['state']}",
    )
    check(
        "gap merging turns per-edge noise into a leg summary",
        big["2WD"]["raw_sections"] > 20 and big["2WD"]["sections"] <= 3,
        f"{big['2WD']['raw_sections']} raw runs -> {big['2WD']['sections']} section(s)",
    )
    viroqua = advisory["approaches"]["viroqua"]["floor_sensitivity"]
    check(
        "at the opportunistic floor a 35%-surveyed gravel approach reads as clear",
        viroqua["opportunistic_20"]["state"] == "no_contrary_signal"
        and viroqua["read_70"]["state"] == "insufficient_signal",
        f"{viroqua['opportunistic_20']['signal_pct']}% surveyed: "
        f"{viroqua['opportunistic_20']['state']} at 20%, "
        f"{viroqua['read_70']['state']} at 70%",
    )
    mid = advisory["approaches"]["middlefork"]["degrade"]
    check(
        "the harm model breaches the pre-declared ceiling at the opportunistic floor "
        "and clears it at the read floor",
        mid["opportunistic_20"]["worst_false_clear_pct"] > FALSE_CLEAR_CEILING_PCT
        >= mid["read_70"]["worst_false_clear_pct"],
        f"false-clear {mid['opportunistic_20']['worst_false_clear_pct']}% at floor 20 "
        f"vs {mid['read_70']['worst_false_clear_pct']}% at floor 70 "
        f"(ceiling {FALSE_CLEAR_CEILING_PCT}%)",
    )

    # ---- the prototype's own invariants ----------------------------------
    edges = [(0.0, 1000.0, {"highway": "track", "surface": "dirt", "length": 1000.0})]
    ladder = [assess(edges, level).state for level in
              (Capability.TWO_WD, Capability.AWD, Capability.FOUR_WD)]
    check(
        "the ladder is ordered: a rough edge flags for 2WD and not for 4WD",
        ladder == ["flagged", "no_contrary_signal", "no_contrary_signal"],
        " -> ".join(ladder),
    )
    check(
        "no state exposes a passable/ok boolean",
        not any(field in assess(edges, Capability.FOUR_WD).__dict__
                for field in ("passable", "ok", "clear")),
        "Advisory carries three states and no verdict boolean",
    )
    return out


def main(argv: list[str]) -> int:
    if "--dry-run" not in argv:
        print(__doc__)
        return 2
    print(f"SPIKE-E self-check — {len(APPROACHES)} approaches, offline\n")
    failures = 0
    for name, ok, detail in clauses():
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}\n         {detail}")
        failures += not ok
    print(f"\n{'all clauses hold' if not failures else f'{failures} clause(s) FAILED'}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
