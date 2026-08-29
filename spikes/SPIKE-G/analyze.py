"""SPIKE-G orchestrator — sweep every region x strategy x zoom x platform,
price each with the cost model, classify against the pre-registered bands, and
write `results/render_budget.json`.

Entirely offline: reads SPIKE-A's committed extracts, computes, writes JSON.
Re-running never re-fetches anything.

    python spikes/SPIKE-G/analyze.py [out.json]
"""

from __future__ import annotations

import json
import os
import sys

import regions as R
from bands import (
    OVERVIEW_ZOOM,
    PLACEMENT_ZOOMS,
    AxisResult,
    a16_budget_mb,
    classify,
)
from costmodel import frame_cost, memory_cost, selection_cost
from extract import load_candidates
from geo import centroid, in_bbox, viewport_bbox
from strategies import STRATEGIES

HERE = os.path.dirname(os.path.abspath(__file__))


def _viewport_candidates(cands, zoom):
    clat, clon = centroid([(c.lat, c.lon) for c in cands])
    vb = viewport_bbox(clat, clon, zoom, *R.VIEWPORT_PX)
    return [c for c in cands if in_bbox(c.lat, c.lon, vb)]


def analyze_region(region: str) -> dict:
    cands = load_candidates(region)
    facts = R.REGIONS[region]
    all_in_bbox = len(cands)

    out_strategies: dict[str, dict] = {}
    for sname, sfn in STRATEGIES.items():
        per_zoom = {}
        for zoom in R.ZOOM_LEVELS:
            vp = _viewport_candidates(cands, zoom)
            zoom_platforms = {}
            for platform in R.PLATFORMS:
                k = R.PINNED_CUT_K[platform]
                plan = sfn(vp, zoom, k, all_in_bbox)
                fc = frame_cost(plan, platform, warm=True)
                mc = memory_cost(plan, platform)
                sc = selection_cost(plan, platform)
                zoom_platforms[platform] = {
                    "plan": {
                        "widget_markers": plan.widget_markers,
                        "canvas_dots": plan.canvas_dots,
                        "cluster_glyphs": plan.cluster_glyphs,
                        "polygon_vertices": plan.polygon_vertices,
                        "in_viewport": plan.in_viewport,
                        "notes": plan.notes,
                    },
                    "frame": {
                        "basemap_p95_ms": fc.basemap_frame_ms,
                        "candidate_add_ms": round(
                            fc.marker_add_ms + fc.dot_add_ms + fc.polygon_add_ms, 2
                        ),
                        "total_p95_ms": fc.total_p95_ms,
                        "over_budget": fc.over_budget,
                    },
                    "memory": {
                        "spike14_client_mb": mc.spike14_client_mb,
                        "candidate_add_mb": round(
                            mc.marker_add_mb + mc.dot_add_mb + mc.polygon_add_mb
                            + mc.cluster_index_add_mb, 2
                        ),
                        "total_mb": mc.total_mb,
                        "over_1gb": mc.over_1gb,
                    },
                    "selection": {
                        "list_to_map_ms": sc.list_to_map_ms,
                        "map_to_list_ms": sc.map_to_list_ms,
                        "rebuild_on_select_ms": sc.rebuild_on_select_ms,
                        "worst_ms": sc.worst_ms,
                        "usable": sc.usable,
                    },
                }
            # interaction properties are platform-independent; take from a plan
            probe_plan = sfn(_viewport_candidates(cands, zoom), zoom,
                             R.PINNED_CUT_K["windows-gpu"], all_in_bbox)
            zoom_platforms["intent"] = {
                "salience_visible": probe_plan.salience_visible,
                "overview_usable": probe_plan.overview_usable,
                "map_to_list_exact": probe_plan.map_to_list_exact,
                "promote_from_map_direct": probe_plan.promote_from_map_direct,
            }
            per_zoom[str(zoom)] = zoom_platforms

        # ---- classify this strategy for this region --------------------- #
        gpu = "windows-gpu"
        swr = "linux-swraster"
        frame_ok_gpu = all(
            not per_zoom[str(z)][gpu]["frame"]["over_budget"] for z in R.ZOOM_LEVELS
        )
        frame_ok_swr_overview = not per_zoom[str(OVERVIEW_ZOOM)][swr]["frame"]["over_budget"]
        select_ok_gpu = all(
            per_zoom[str(z)][gpu]["selection"]["usable"] for z in R.ZOOM_LEVELS
        )
        hard_reasons: list[str] = []
        soft_reasons: list[str] = []
        it_over = per_zoom[str(OVERVIEW_ZOOM)]["intent"]
        if not it_over["overview_usable"]:
            hard_reasons.append(f"overview (z{OVERVIEW_ZOOM}) renders nothing")
        if not it_over["salience_visible"]:
            soft_reasons.append(f"salience aggregated away at z{OVERVIEW_ZOOM} (FR99)")
        for z in PLACEMENT_ZOOMS:
            it = per_zoom[str(z)]["intent"]
            if not it["map_to_list_exact"]:
                soft_reasons.append(f"tap->card ambiguous at z{z} (N4a)")
            if not it["promote_from_map_direct"]:
                soft_reasons.append(f"cannot promote directly from map at z{z} (FR99)")
        intent_reasons = hard_reasons + soft_reasons

        axis = AxisResult(
            frame_ok_gpu=frame_ok_gpu,
            frame_ok_swraster_overview=frame_ok_swr_overview,
            select_ok_gpu=select_ok_gpu,
            intent_hard_fail=bool(hard_reasons),
            intent_soft_fail=bool(soft_reasons),
            reasons=tuple(intent_reasons),
        )
        band = classify(axis)

        # worst candidate-layer memory add across the sweep, GPU
        worst_add = max(
            per_zoom[str(z)][gpu]["memory"]["candidate_add_mb"] for z in R.ZOOM_LEVELS
        )

        out_strategies[sname] = {
            "band": band.value,
            "axes": {
                "frame_ok_gpu": frame_ok_gpu,
                "frame_ok_swraster_overview": frame_ok_swr_overview,
                "select_ok_gpu": select_ok_gpu,
                "intent_hard_fail": bool(hard_reasons),
                "intent_soft_fail": bool(soft_reasons),
                "intent_reasons": intent_reasons,
            },
            "worst_candidate_layer_add_mb_gpu": worst_add,
            "by_zoom": per_zoom,
        }

    return {
        "region": region,
        "place": facts.place,
        "km2": facts.km2,
        "candidates_v1_2_0": facts.candidates_v1_2_0,
        "candidates_v1_1_0_flood": facts.candidates_v1_1_0,
        "area_anchor_count": sum(1 for c in cands if c.is_area),
        "density_per_100km2": round(all_in_bbox / facts.km2 * 100, 1),
        "strategies": out_strategies,
    }


def summarize(regions_out: list[dict]) -> dict:
    # the recommended strategy is the one that is never RED and is GREEN or
    # AMBER in the densest region.
    strat_names = list(STRATEGIES)
    verdict = {}
    for s in strat_names:
        bands = {r["region"]: r["strategies"][s]["band"] for r in regions_out}
        worst = "green"
        for b in bands.values():
            if b == "red":
                worst = "red"
            elif b == "amber" and worst != "red":
                worst = "amber"
        verdict[s] = {"per_region": bands, "worst": worst}

    recommended = None
    for s in ("salience_gated", "cluster_grid", "zoom_threshold", "naive"):
        if verdict[s]["worst"] != "red":
            recommended = s
            break

    # Display-density ceiling: with K widget markers fixed and a ~2 ms polygon
    # allowance, how many total candidates can share one GPU viewport before the
    # p95 interaction frame tips over 16.7 ms? Everything past K is a canvas dot.
    gpu = "windows-gpu"
    k = R.PINNED_CUT_K[gpu]
    base_p95 = R.BASEMAP_WARM_FRAME_MS[gpu]["p95"]
    marker_ms = R.WIDGET_MARKER_FRAME_US[gpu].value / 1000.0
    dot_ms = R.CANVAS_DOT_FRAME_US[gpu].value / 1000.0
    poly_allowance_ms = 2.0
    dot_budget_ms = R.FRAME_BUDGET_MS - base_p95 - k * marker_ms - poly_allowance_ms
    density_ceiling = k + max(0, int(dot_budget_ms / dot_ms))

    # A16 restatement from the recommended strategy's worst memory add
    gpu_base = R.MEM_SPIKE14_CLIENT_BUDGET_MB["windows-gpu"]
    worst_add = 0.0
    if recommended:
        worst_add = max(
            r["strategies"][recommended]["worst_candidate_layer_add_mb_gpu"]
            for r in regions_out
        )
    a16 = a16_budget_mb(gpu_base, worst_add)

    return {
        "recommended_strategy": recommended,
        "pinned_cut_k": R.PINNED_CUT_K,
        "gpu_display_density_ceiling": density_ceiling,
        "per_strategy_bands": verdict,
        "a16_restated": {
            "spike14_client_budget_mb_gpu": gpu_base,
            "recommended_strategy": recommended,
            "worst_candidate_layer_add_mb": round(worst_add, 1),
            "headroom_mb": 150,
            "budget_mb": a16,
            "statement": (
                f"Budget the curation workspace at ~{int(a16)} MB working set on "
                f"a Windows GPU client: SPIKE-14's ~{int(gpu_base)} MB basemap "
                f"client, + ~{round(worst_add,1)} MB for the "
                f"{recommended} candidate layer at its density ceiling, + "
                f"~150 MB tile-cache / transient headroom. Re-measure on a "
                f"release build (HARNESS.md)."
            ),
        },
    }


def main(argv: list[str]) -> int:
    out_path = argv[1] if len(argv) > 1 else os.path.join(HERE, "results", "render_budget.json")
    regions_out = [analyze_region(r) for r in R.REGIONS]
    doc = {
        "spike": "SPIKE-G",
        "question": "ARCH Q15 — candidate/proposal rendering at bbox scale; re-measure A16",
        "method": "analytical model calibrated to SPIKE-14 anchors + SPIKE-A densities; live harness in HARNESS.md",
        "regions": regions_out,
        "summary": summarize(regions_out),
    }
    with open(out_path, "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")

    s = doc["summary"]
    print(f"wrote {out_path}")
    print(f"recommended strategy: {s['recommended_strategy']}")
    for strat, v in s["per_strategy_bands"].items():
        print(f"  {strat:16s} worst={v['worst']:6s}  {v['per_region']}")
    print(s["a16_restated"]["statement"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
