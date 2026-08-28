"""SPIKE-D step 4 — the verdicts, computed offline from `results/*.json`.

Nothing here queries anything. Every number comes from `probe.json`,
`concurrency.json` and `health.json`, so the four claims below can be
re-derived from the committed artifacts without touching the Overpass commons.

  §1  D34 — "ordering is a reordering of existing startup work, not new work"
      Extraction-to-authoring against enrichment, per extent. D34 is confirmed
      only if extraction is small relative to enrichment; if extraction is
      itself minutes long, FR121 moves the spinner rather than removing it.
  §2  A23 — what a candidate pull costs public Overpass, whole-bbox versus
      tiled, and against a graph build over the same extent.
  §3  Area scaling — the curve, so a bbox size can be reasoned about rather
      than guessed at.
  §4  FR120/N1 — added-area-only re-extraction: time saved, and whether the
      union is the same candidate set as a full re-extract.

Usage:
    .venv/bin/python spikes/SPIKE-D/analyze.py [--json]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import common  # noqa: E402
from common import RESULTS  # noqa: E402

#: The bar §1 judges D34 against, declared here rather than chosen after the
#: numbers were seen. FR121's own words are "terrain data loading — routing
#: available in about 3 minutes", so enrichment is expected to be minutes.
#: Extraction has to be short enough that an Author experiences it as opening
#: a document rather than waiting for one: 20 s is roughly the boundary at
#: which a progress indicator stops being decoration (Nielsen's 10 s attention
#: limit, doubled for a one-off at trip creation). Anything past that and the
#: reorder has not removed the wait, it has renamed it.
AUTHORABLE_CEILING_S = 20.0


def _load(name: str) -> dict:
    path = RESULTS / name
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def _extract_phases(probe: dict) -> list[tuple[str, dict]]:
    """Every `extract*` key, in insertion order — `probe.py --suffix` keeps a
    second sample rather than overwriting the first, because the run-to-run
    spread on public Overpass turned out to be the headline (§2)."""
    return [(k, v) for k, v in probe.items() if k.startswith("extract")]


def _samples_by_label(probe: dict) -> dict[str, list[dict]]:
    """label -> every sample of that run across all extract phases."""
    out: dict[str, list[dict]] = {}
    for phase, payload in _extract_phases(probe):
        for row in payload.get("runs", []):
            out.setdefault(row["label"], []).append({**row, "phase": phase})
    return out


def _runs_by_label(probe: dict) -> dict[str, dict]:
    """One representative row per label — the **fastest successful** sample.

    Fastest, not mean: every slow sample here is slow because of server-side
    queueing (§2 measures 2.7 s and 178.5 s for the identical query), and the
    fastest observation is the closest available estimate of the work itself.
    Where the spread matters, §1 and §2 print every sample rather than this one.
    """
    best: dict[str, dict] = {}
    for label, samples in _samples_by_label(probe).items():
        ok = [s for s in samples if not s.get("error")]
        pool = ok or samples
        best[label] = min(pool, key=lambda s: s["total_s"])
    return best


# ---------------------------------------------------------------------- §1 D34


def section_d34(probe: dict, conc: dict) -> dict:
    runs = _runs_by_label(probe)
    elev = probe.get("elevation", {})
    rows = []

    for label in ("trip / default 3 layers", "trip / all 6 layers",
                  "trip / all (warm cache)", "enlarged / all 6 layers",
                  "tour / default 3 layers", "tour / all 6 layers"):
        run = runs.get(label)
        if not run:
            continue
        rows.append({
            "extent": label,
            "area_km2": run["area_km2"],
            "fetch_s": run["fetch_s"],
            "index_s": run["index_s"],
            "authorable_s": run["total_s"],
            "candidates": run["candidates"],
            "error": run.get("error"),
            "within_ceiling": run.get("error") is None
                              and run["total_s"] <= AUTHORABLE_CEILING_S,
        })

    enrich_s = elev.get("total_s")
    trip = runs.get("trip / all 6 layers", {})
    trip_s = trip.get("total_s")
    samples = _samples_by_label(probe).get("trip / all 6 layers", [])
    trip_worst = max((s["total_s"] for s in samples), default=None)
    graph_s = next((b.get("build_s") for b in probe.get("graph", {}).get("builds", [])
                    if b.get("box") == "trip"), None)

    verdict = {
        "ceiling_s": AUTHORABLE_CEILING_S,
        "trip_authorable_best_s": trip_s,
        "trip_authorable_worst_s": trip_worst,
        "trip_enrichment_s": enrich_s,
        "trip_graph_build_s": graph_s,
        "ratio_enrichment_over_extraction": (round(enrich_s / trip_s, 2)
                                             if enrich_s and trip_s else None),
        "rows": rows,
    }
    if trip_s is not None and enrich_s is not None:
        # D34 says the reorder is cheap *because extraction is the short half*.
        # It holds only if extraction reliably beats the ceiling AND enrichment
        # is genuinely the longer operation. Judged on the worst sample, not
        # the best: the Author gets whichever one the server feels like giving.
        verdict["extraction_within_ceiling_best"] = trip_s <= AUTHORABLE_CEILING_S
        verdict["extraction_within_ceiling_worst"] = (
            trip_worst is not None and trip_worst <= AUTHORABLE_CEILING_S)
        verdict["enrichment_is_the_longer_half"] = enrich_s > trip_s
        verdict["d34_confirmed"] = bool(
            verdict["extraction_within_ceiling_worst"]
            and verdict["enrichment_is_the_longer_half"])
    # The concurrency half: an ordering claim is only worth confirming if the
    # Author can actually work during the second operation.
    under = conc.get("under_enrichment", {})
    verdict["authoring_slowdown_under_enrichment"] = under.get("score_notability_slowdown")
    verdict["health_p95_ms_under_enrichment"] = under.get("health", {}).get("p95_ms")
    verdict["health_p95_ms_idle"] = conc.get("solo", {}).get("health", {}).get("p95_ms")
    return verdict


# ---------------------------------------------------------------------- §2 A23


def section_a23(probe: dict) -> dict:
    extract = probe.get("extract", {})
    runs = _runs_by_label(probe)
    graph_builds = {g["box"]: g for g in probe.get("graph", {}).get("builds", [])}

    rows = []
    for label, run in runs.items():
        op = run.get("overpass", {})
        rows.append({
            "label": label,
            "area_km2": run["area_km2"],
            "requests": op.get("requests"),
            "retries": op.get("retries"),
            "slot_pause_s": op.get("slot_pause_s"),
            "server_s": op.get("server_s"),
            "mb": round(op.get("bytes", 0) / 1e6, 2),
            "elements": op.get("elements"),
            "failed": bool(run.get("error")) or bool(op.get("failures")),
        })

    # The spread, run to run, for the *same query against the same endpoint*.
    # This is the number A23 is actually about: not "how big is the bbox" but
    # "what will the commons give me today".
    spread = []
    for label, samples in _samples_by_label(probe).items():
        times = [s["total_s"] for s in samples]
        retries = [s.get("overpass", {}).get("retries", 0) for s in samples]
        if len(times) < 2:
            continue
        spread.append({
            "label": label,
            "samples": len(times),
            "min_s": round(min(times), 2),
            "max_s": round(max(times), 2),
            "ratio": round(max(times) / min(times), 1) if min(times) else None,
            "retries": retries,
        })
    spread.sort(key=lambda r: -(r["ratio"] or 0))

    trip_whole = runs.get("trip / all 6 layers", {})
    whole_vs_tiled = {
        "whole_total_s": trip_whole.get("total_s"),
        "whole_requests": trip_whole.get("overpass", {}).get("requests"),
        "whole_failed": bool(trip_whole.get("error")),
        "tiled_total_s": extract.get("trip_tiled_total_s"),
        "tiled_requests": sum(t.get("overpass", {}).get("requests", 0)
                              for t in extract.get("trip_tiles", [])),
        "tiled_failures": sum(1 for t in extract.get("trip_tiles", []) if t.get("error")),
        "tiled_features": extract.get("trip_tiled_features"),
        "whole_features": trip_whole.get("features"),
    }

    # A23's actual claim, finally comparable: candidate pull vs graph build.
    comparison = []
    for box, extract_label in (("trip", "trip / all 6 layers"),
                               ("enlarged", "enlarged / all 6 layers")):
        build = graph_builds.get(box)
        run = runs.get(extract_label)
        if not build or not run:
            continue
        gop = build.get("overpass", {})
        cop = run.get("overpass", {})
        comparison.append({
            "box": box,
            "area_km2": run["area_km2"],
            "graph_build_s": build.get("build_s"),
            "graph_requests": gop.get("requests"),
            "graph_mb": round(gop.get("bytes", 0) / 1e6, 2),
            "candidate_fetch_s": run.get("fetch_s"),
            "candidate_requests": cop.get("requests"),
            "candidate_mb": round(cop.get("bytes", 0) / 1e6, 2),
            "candidate_is_heavier_by_time": (
                None if not build.get("build_s") or not run.get("fetch_s")
                else round(run["fetch_s"] / build["build_s"], 2)),
            "candidate_is_heavier_by_bytes": (
                None if not gop.get("bytes") else round(cop.get("bytes", 0)
                                                        / gop["bytes"], 2)),
        })

    return {
        "per_run": rows,
        "run_to_run_spread": spread,
        "whole_vs_tiled_trip": whole_vs_tiled,
        "candidate_vs_graph": comparison,
        "overpass_cache_bytes": extract.get("overpass_cache_bytes"),
        "tour_tiles": extract.get("tour_tiles", []),
    }


# ------------------------------------------------------------------- §3 scaling


def section_scaling(probe: dict) -> dict:
    runs = _runs_by_label(probe)
    points = []
    for label, run in runs.items():
        if run.get("error") or not run.get("cold", True):
            continue
        if "all 6 layers" not in label and not label.startswith("sweep"):
            continue
        points.append({
            "label": label,
            "area_km2": run["area_km2"],
            "total_s": run["total_s"],
            "fetch_s": run["fetch_s"],
            "index_s": run["index_s"],
            "candidates": run["candidates"],
            "s_per_1000km2": round(run["total_s"] / run["area_km2"] * 1000, 2),
            "candidates_per_1000km2": round(run["candidates"] / run["area_km2"] * 1000, 1),
        })
    points.sort(key=lambda p: p["area_km2"])
    return {"points": points}


# ------------------------------------------------------------------ §4 enlarge


def section_enlarge(probe: dict) -> dict:
    enl = probe.get("enlarge", {})
    runs = _runs_by_label(probe)
    full = runs.get("enlarged / all 6 layers", {})
    inc_s = enl.get("incremental_total_s")
    full_s = full.get("total_s")
    return {
        "incremental_runs": enl.get("incremental_runs", []),
        "offline_partition_check": enl.get("offline_partition_check"),
        "added_area_km2": enl.get("added_area_km2"),
        "added_frac_of_new_extent": enl.get("added_frac_of_new_extent"),
        "incremental_s": inc_s,
        "full_reextract_s": full_s,
        "saving": (None if not inc_s or not full_s
                   else round(1 - inc_s / full_s, 3)),
        "union_candidates": enl.get("union_candidates"),
        "full_reextract_candidates": enl.get("full_reextract_candidates"),
        "n_missing": enl.get("n_missing"),
        "n_extra": enl.get("n_extra"),
        "correct": enl.get("n_missing") == 0,
    }


# ---------------------------------------------------------------------- report


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    probe = _load("probe.json")
    conc = _load("concurrency.json")
    health = _load("health.json")
    if not probe:
        raise SystemExit("no results/probe.json — run probe.py first")

    d34 = section_d34(probe, conc)
    a23 = section_a23(probe)
    scaling = section_scaling(probe)
    enlarge = section_enlarge(probe)

    print("=== §1  D34 — is the reorder cheap? ===")
    print(f"  ceiling for 'authorable': {d34['ceiling_s']:.0f}s (declared before the run)\n")
    print(f"  {'extent':28} {'km2':>8} {'fetch':>8} {'index':>8} {'total':>8} "
          f"{'cand':>7}  ok")
    for row in d34["rows"]:
        mark = "—" if row["error"] else ("yes" if row["within_ceiling"] else "NO")
        print(f"  {row['extent']:28} {row['area_km2']:8,.0f} {row['fetch_s']:8.2f} "
              f"{row['index_s']:8.3f} {row['authorable_s']:8.2f} "
              f"{row['candidates']:7,}  {mark}")
    if d34.get("trip_enrichment_s"):
        print(f"\n  trip authorable in {d34['trip_authorable_best_s']:.1f}s "
              f"(best of {len(_samples_by_label(probe).get('trip / all 6 layers', []))} "
              f"samples; worst {d34['trip_authorable_worst_s']:.1f}s)")
        print(f"  elevation enrichment  {d34['trip_enrichment_s']:.1f}s   "
              f"= {d34['ratio_enrichment_over_extraction']}x extraction")
        if d34.get("trip_graph_build_s"):
            print(f"  graph build (routing) {d34['trip_graph_build_s']:.1f}s")
    print(f"  extraction within ceiling — best sample: "
          f"{d34.get('extraction_within_ceiling_best')}, "
          f"worst sample: {d34.get('extraction_within_ceiling_worst')}")
    print(f"  enrichment is the longer half: {d34.get('enrichment_is_the_longer_half')}")
    print(f"  D34 confirmed: {d34.get('d34_confirmed')}")
    if d34.get("authoring_slowdown_under_enrichment"):
        print(f"  authoring slowdown while enrichment runs: "
              f"x{d34['authoring_slowdown_under_enrichment']}   "
              f"/health p95 {d34['health_p95_ms_idle']} -> "
              f"{d34['health_p95_ms_under_enrichment']} ms")

    print("\n=== §2  A23 — what a candidate pull costs public Overpass ===")
    print(f"  {'run':28} {'km2':>8} {'req':>4} {'retry':>6} {'pause':>7} "
          f"{'server':>8} {'MB':>7}  failed")
    for row in a23["per_run"]:
        print(f"  {row['label']:28} {row['area_km2']:8,.0f} {row['requests'] or 0:4} "
              f"{row['retries'] or 0:6} {row['slot_pause_s'] or 0:7.1f} "
              f"{row['server_s'] or 0:8.1f} {row['mb']:7.2f}  {row['failed']}")
    if a23["run_to_run_spread"]:
        print(f"\n  run-to-run spread, same query, same endpoint:")
        print(f"  {'run':28} {'n':>2} {'min_s':>8} {'max_s':>8} {'x':>6}  retries")
        for row in a23["run_to_run_spread"]:
            print(f"  {row['label']:28} {row['samples']:2} {row['min_s']:8.2f} "
                  f"{row['max_s']:8.2f} {row['ratio'] or 0:6.1f}  {row['retries']}")

    wt = a23["whole_vs_tiled_trip"]
    print(f"\n  TRIP whole: {wt['whole_total_s']}s / {wt['whole_requests']} req / "
          f"{wt['whole_features']:,} feat   failed={wt['whole_failed']}")
    print(f"  TRIP tiled: {wt['tiled_total_s']}s / {wt['tiled_requests']} req / "
          f"{wt['tiled_features']:,} feat   {wt['tiled_failures']} tile failures")
    for row in a23["candidate_vs_graph"]:
        print(f"\n  {row['box']}: graph build {row['graph_build_s']}s "
              f"({row['graph_mb']} MB) vs candidate pull {row['candidate_fetch_s']}s "
              f"({row['candidate_mb']} MB)")
        print(f"        candidate/graph = x{row['candidate_is_heavier_by_time']} time, "
              f"x{row['candidate_is_heavier_by_bytes']} bytes")

    print("\n=== §3  extraction time vs bbox area ===")
    print(f"  {'label':28} {'km2':>8} {'total_s':>8} {'s/1000km2':>10} "
          f"{'cand/1000km2':>13}")
    for p in scaling["points"]:
        print(f"  {p['label']:28} {p['area_km2']:8,.0f} {p['total_s']:8.2f} "
              f"{p['s_per_1000km2']:10.2f} {p['candidates_per_1000km2']:13.1f}")

    print("\n=== §4  FR120/N1 — enlarging re-extracts only the added area ===")
    e = enlarge
    if e.get("incremental_s") is not None:
        print(f"  added {e['added_area_km2']:,.0f} km2 "
              f"({e['added_frac_of_new_extent']:.0%} of the new extent)")
        if e.get("saving") is not None:
            verb = "faster" if e["saving"] > 0 else "SLOWER"
            n_queries = len(e.get("incremental_runs") or [])
            print(f"  incremental {e['incremental_s']:.1f}s over {n_queries} queries "
                  f"vs full re-extract {e['full_reextract_s']:.1f}s over 1 — "
                  f"{abs(e['saving']):.0%} {verb}")
        print(f"  union {e['union_candidates']:,} candidates vs full re-extract "
              f"{e['full_reextract_candidates']:,}  "
              f"(missing {e['n_missing']}, extra {e['n_extra']})")
        print(f"  correct: {e['correct']}")

    if health:
        print("\n=== §5  /health contract (from health.py) ===")
        for app, s in health.get("summary", {}).items():
            print(f"  {app:10} {s['passed']}/{s['total']} clauses")

    out = {"d34": d34, "a23": a23, "scaling": scaling, "enlarge": enlarge,
           "health_summary": health.get("summary", {})}
    if args.json:
        print(f"\nwrote {common.write_results('analysis.json', out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
