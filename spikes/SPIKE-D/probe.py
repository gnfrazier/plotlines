"""SPIKE-D step 1 — the live measurements. Issue #159, points 1, 4 and 5.

Everything that needs the network happens here and is cached; every other
script in this directory reproduces its numbers offline from `raw/` and
`results/probe.json`.

Phases (`--phase`, repeatable; default all):

  extract    bbox -> candidates through the product's own `OsmLayerProvider`
             + `score_notability`, at three extents x two layer sets, whole-
             bbox and tiled, cold and warm. This is the numerator of D34's
             claim: the time between an Author finishing their bbox and the
             Curation Workspace being genuinely usable.
  graph      `ox.graph_from_bbox` over the same extents — A23 says candidate
             extraction is "a heavier query than graph building", which is a
             comparison nobody has made. Also produces the graph the
             elevation phase enriches.
  elevation  DEM acquisition + `add_node_elevations_raster` +
             `add_edge_grades` over the trip extent: the denominator, the
             "blocking, minutes-long operation" of FR91.
  enlarge    FR120/N1 — extract TRIP, enlarge, and re-extract only the added
             area; time it against a full re-extract and check the union is
             the same candidate set.

Usage:
    .venv/bin/python spikes/SPIKE-D/probe.py --phase extract
    .venv/bin/python spikes/SPIKE-D/probe.py            # all four
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import common  # noqa: E402
import overpass_meter  # noqa: E402
from common import (  # noqa: E402
    ALL_LAYERS, DEFAULT_LAYERS, Meter, RESULTS, extract_stage,
    overpass_cache_bytes, save_features,
)
from regions import (  # noqa: E402
    ENLARGED, TOUR, TOUR_SWEEP, TRIP, TRIP_SWEEP, TRIP_TILES, rect_difference,
)

PROBE_JSON = RESULTS / "probe.json"


def _load() -> dict:
    if PROBE_JSON.exists():
        return json.loads(PROBE_JSON.read_text(encoding="utf-8"))
    return {}


def _store(phase: str, payload) -> None:
    """Written after every phase, not once at the end — an Overpass pull that
    dies on the fourth extent must not cost the first three."""
    data = _load()
    data[phase] = payload
    RESULTS.mkdir(parents=True, exist_ok=True)
    PROBE_JSON.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n",
                          encoding="utf-8")


def _report(label: str, result) -> None:
    if result.error:
        print(f"  {label:28} FAILED  {result.error[:70]}")
        return
    op = result.overpass
    print(f"  {label:28} fetch {result.fetch_s:7.2f}s  index {result.index_s:6.3f}s  "
          f"{result.features:6,} feat -> {result.candidates:5,} cand  "
          f"[{op['requests']}req {op['slot_pause_s']:.0f}s pause "
          f"{op['bytes'] / 1e6:.1f}MB]")


# --------------------------------------------------------------------- extract


PHASE_SUFFIX = ""


def phase_extract() -> dict:
    """The D34 numerator, and A23's whole-vs-tiled question in one pass.

    Every measured run is flushed to `probe.json` as it completes, not at the
    end. The multi-day extent is the last and by far the longest pull, and on
    the first attempt it ran past an hour without returning — losing the six
    trip-scale rows to *that* would have meant re-querying the commons for
    numbers already measured, which is the load A23 is a risk about.
    """
    runs: list[dict] = []
    partial: dict = {"runs": runs, "trip_tiles": [], "tour_tiles": [],
                     "incomplete": True}

    def flush() -> None:
        partial["overpass_cache_bytes"] = overpass_cache_bytes()
        _store("extract" + PHASE_SUFFIX, partial)

    def run(label: str, box, layers, *, cold=True, save_as: str | None = None,
            deadline_s: float = common.DEFAULT_DEADLINE_S):
        result, features, _ = extract_stage(box, layers, cold=cold,
                                            deadline_s=deadline_s)
        _report(label, result)
        row = result.to_dict()
        row["label"] = label
        row["cold"] = cold
        runs.append(row)
        if save_as and not result.error:
            save_features(save_as, features)
        flush()
        return result

    print(f"=== TRIP: {TRIP.name} ({TRIP.area_km2:,.0f} km2) ===")
    run("trip / default 3 layers", TRIP, DEFAULT_LAYERS, save_as="trip-default")
    run("trip / all 6 layers", TRIP, ALL_LAYERS, save_as="trip-all")
    # Warm immediately after the cold all-layer pull, same query, cache intact:
    # ARCH §4.2's bbox-scoped on-demand cache, and the number an Author sees
    # when they reopen a trip.
    run("trip / all (warm cache)", TRIP, ALL_LAYERS, cold=False)

    print(f"\n=== TRIP tiled 2x2 (A23's baseline access pattern) ===")
    common.clear_overpass_cache()
    tile_rows, tile_total, tile_feats = [], 0.0, 0
    for tile in TRIP_TILES:
        result, features, _ = extract_stage(tile, ALL_LAYERS, cold=False)
        _report(f"  {tile.key}", result)
        tile_rows.append(result.to_dict())
        tile_total += result.total_s
        tile_feats += result.features
        partial["trip_tiles"] = tile_rows
        partial["trip_tiled_total_s"] = round(tile_total, 2)
        partial["trip_tiled_features"] = tile_feats
        flush()
    print(f"  {'tiled total':28} {tile_total:7.2f}s   {tile_feats:,} feat "
          f"(dupes across tile edges not removed)")

    print(f"\n=== area sweep — extraction time vs bbox area ===")
    for box in TRIP_SWEEP[1:]:  # [0] is TRIP itself, already measured
        run(f"sweep {box.area_km2:,.0f} km2", box, ALL_LAYERS)

    print(f"\n=== ENLARGED ({ENLARGED.area_km2:,.0f} km2) ===")
    run("enlarged / all 6 layers", ENLARGED, ALL_LAYERS, save_as="enlarged-all")

    print(f"\n=== TOUR: multi-day extent ({TOUR.area_km2:,.0f} km2) ===")
    print("    osmnx splits above settings.max_query_area_size (2,500 km2) on its own —")
    print("    the request count below is that split, not a choice this spike made.")
    # Capped, because osmnx's 429/504 handler retries without an attempt limit
    # (see `common.Deadline`). Ten minutes is far past any plausible product
    # budget — FR121's own indicator promises "about 3 minutes" for the whole
    # of enrichment — so a pull that misses it has failed by any standard a
    # trip-initiation flow could hold it to.
    tour_deadline = 600.0
    run("tour / default 3 layers", TOUR, DEFAULT_LAYERS, save_as="tour-default",
        deadline_s=tour_deadline)
    tour_all = run("tour / all 6 layers", TOUR, ALL_LAYERS, save_as="tour-all",
                   deadline_s=tour_deadline)

    tour_tiles: list[dict] = []
    if tour_all.error:
        print("\n    whole-extent pull failed — falling back to explicit 4x4 tiling")
        print("    (A23's prediction, and the reason it says tile-and-retry is the")
        print("     baseline rather than the fallback)")
        from regions import TOUR_TILES

        common.clear_overpass_cache()
        for tile in TOUR_TILES:
            result, _, _ = extract_stage(tile, ALL_LAYERS, cold=False,
                                         deadline_s=180.0)
            _report(f"  {tile.key}", result)
            tour_tiles.append(result.to_dict())
            partial["tour_tiles"] = tour_tiles
            flush()

    partial["incomplete"] = False
    return partial


# ----------------------------------------------------------------------- graph


def phase_graph() -> dict:
    """A23's unmade comparison: is a candidate pull really heavier than a
    graph build over the same bbox? Uses the product's own `ensure_graph`."""
    import osmnx as ox

    from plotlines_core.graph import regions as region_lib

    cache_dir = common.HERE / "cache" / "regions"
    rows = []
    for box in (TRIP, ENLARGED):
        common.clear_overpass_cache()
        region = region_lib.region_for(box.bbox_lonlat, "bike")
        path = region.graph_path(cache_dir)
        if path.exists():
            path.unlink()
        row = {"box": box.key, "area_km2": round(box.area_km2, 1)}
        with overpass_meter.measure() as cost:
            try:
                with Meter() as m:
                    out = region_lib.ensure_graph(region, cache_dir)
                row["build_s"] = round(m.seconds, 2)
                row["peak_mb"] = round(m.peak_mb, 1)
                graph = ox.io.load_graphml(out)
                row["nodes"] = graph.number_of_nodes()
                row["edges"] = graph.number_of_edges()
                row["graphml_bytes"] = out.stat().st_size
            except Exception as exc:  # noqa: BLE001
                row["error"] = f"{type(exc).__name__}: {exc}"
        row["overpass"] = cost.to_dict()
        print(f"  graph {box.key:10} {row.get('build_s', '—'):>8}s  "
              f"{row.get('nodes', 0):,} nodes / {row.get('edges', 0):,} edges  "
              f"[{row['overpass']['requests']}req "
              f"{row['overpass']['bytes'] / 1e6:.1f}MB]")
        rows.append(row)
    return {"builds": rows}


# ------------------------------------------------------------------- elevation


def phase_elevation() -> dict:
    """FR91's "blocking, minutes-long operation", measured.

    **The source is a stand-in and the write-up says so.** D20/FR85 pin
    production elevation to GEDTM30 via OpenTopography, whose acquisition
    pipeline is gated on FR87 (#148) and does not exist to time. AWS Terrain
    Tiles at z12 is ~30 m/px at this latitude — the same ground resolution as
    GEDTM30 — and is keyless, so it measures the *shape* of enrichment cost
    (tile fetch, mosaic, reproject, then a raster sample per graph node)
    without inventing a second production source, which D20 forbids.
    """
    import numpy as np
    import osmnx as ox

    # `spikes/shared/regions.py` and this spike's own `regions.py` share a
    # module name, and this directory is first on `sys.path` — a plain
    # `import regions` returns SPIKE-D's, which has no `Region` and no
    # `build_dem`. Load the shared one by path under a name of its own.
    import importlib.util

    shared_path = common.HERE.parents[0] / "shared" / "regions.py"
    spec = importlib.util.spec_from_file_location("spiked_shared_regions", shared_path)
    shared = importlib.util.module_from_spec(spec)
    # Registered before exec: `@dataclass` resolves a field's type by looking
    # its own module up in `sys.modules`, so a module executed outside it
    # raises on the first frozen dataclass it defines.
    sys.modules[spec.name] = shared
    spec.loader.exec_module(shared)

    from plotlines_core.graph import regions as region_lib

    cache_dir = common.HERE / "cache" / "regions"
    region = region_lib.region_for(TRIP.bbox_lonlat, "bike")
    graph_path = region.graph_path(cache_dir)
    if not graph_path.exists():
        raise SystemExit("run --phase graph first: elevation enriches that graph")

    dem_path = common.HERE / "cache" / "trip_dem.tif"
    dem_path.parent.mkdir(parents=True, exist_ok=True)
    if dem_path.exists():
        dem_path.unlink()

    import shutil

    # `build_dem` writes to `Region.dem_path`, which is fixed under
    # spikes/shared/fixtures/. Build there and move the result into this
    # spike's own cache rather than leaving a SPIKE-D artifact in the shared
    # SPIKE-01/02/03 fixture directory.
    fixture = shared.Region(key="spiked_trip", name=TRIP.name, character="",
                            bbox=TRIP.bbox_lonlat)
    shared.FIXTURES.mkdir(parents=True, exist_ok=True)

    t0 = time.perf_counter()
    built = shared.build_dem(fixture, zoom=12, force=True)
    dem_s = time.perf_counter() - t0
    shutil.move(str(built), str(dem_path))
    built = dem_path
    dem_bytes = built.stat().st_size

    graph = ox.io.load_graphml(graph_path)
    t0 = time.perf_counter()
    graph = ox.elevation.add_node_elevations_raster(graph, built, cpus=1)
    sample_s = time.perf_counter() - t0

    t0 = time.perf_counter()
    graph = ox.elevation.add_edge_grades(graph, add_absolute=True)
    grade_s = time.perf_counter() - t0

    elevs = np.array([d.get("elevation", np.nan) for _, d in graph.nodes(data=True)],
                     dtype="float64")
    finite = elevs[np.isfinite(elevs)]

    out = {
        "source": "AWS Terrain Tiles (Terrarium) z12 — stand-in for GEDTM30 "
                  "(D20/FR85), gated on FR87/#148",
        "box": TRIP.key,
        "area_km2": round(TRIP.area_km2, 1),
        "dem_fetch_mosaic_reproject_s": round(dem_s, 2),
        "dem_bytes": dem_bytes,
        "node_sample_s": round(sample_s, 2),
        "edge_grade_s": round(grade_s, 2),
        "total_s": round(dem_s + sample_s + grade_s, 2),
        "nodes": graph.number_of_nodes(),
        "edges": graph.number_of_edges(),
        "nodes_with_elevation": int(finite.size),
        "elevation_min_m": round(float(finite.min()), 1) if finite.size else None,
        "elevation_max_m": round(float(finite.max()), 1) if finite.size else None,
    }
    print(f"  DEM acquire       {out['dem_fetch_mosaic_reproject_s']:8.2f}s  "
          f"({dem_bytes / 1e6:.1f} MB GeoTIFF)")
    print(f"  node sampling     {out['node_sample_s']:8.2f}s  ({out['nodes']:,} nodes)")
    print(f"  edge grades       {out['edge_grade_s']:8.2f}s  ({out['edges']:,} edges)")
    print(f"  enrichment total  {out['total_s']:8.2f}s")
    return out


# ------------------------------------------------------------------- enlarge


def _crop_check(added) -> dict:
    """The geometry half of N1, checked offline against the cached pulls.

    Splits the cached full-extent feature set by which added rectangle (if
    any) each feature falls in, and asks whether TRIP's features plus the
    added rectangles' features reconstitute the whole. This isolates
    `rect_difference` from Overpass: if the decomposition drops a strip or
    double-counts a corner, it shows up here with no network involved, and
    the live incremental run below then only has to answer "and does the
    fetch agree?".
    """
    from plotlines_core.curation.notability import score_notability

    if not (common.has_features("enlarged-all") and common.has_features("trip-all")):
        return {"skipped": "cached trip-all / enlarged-all not present"}

    full = common.load_features("enlarged-all")
    trip = common.load_features("trip-all")
    live = set(ALL_LAYERS)
    full_ids = {c.id for c in score_notability(full, live_layers=live)}
    trip_ids = {c.id for c in score_notability(trip, live_layers=live)}

    in_added = [f for f in full
                if any(p.contains(f.coord[0], f.coord[1]) for p in added)]
    added_ids = {c.id for c in score_notability(in_added, live_layers=live)}

    union = trip_ids | added_ids
    overlaps = sum(1 for f in full
                   if sum(p.contains(f.coord[0], f.coord[1]) for p in added) > 1)
    return {
        "full_candidates": len(full_ids),
        "trip_candidates": len(trip_ids),
        "added_candidates": len(added_ids),
        "union_candidates": len(union),
        "n_missing": len(full_ids - union),
        "n_extra": len(union - full_ids),
        "features_in_two_added_rects": overlaps,
        "partition_is_exact": len(full_ids - union) == 0 and overlaps == 0,
    }


def phase_enlarge() -> dict:
    """FR120/N1: enlarging re-extracts only the added area. Measured against
    a full re-extract of the new extent, and checked for equality — an
    incremental extraction that is fast and wrong is worse than a slow one."""
    added = rect_difference(ENLARGED, TRIP)
    crop = _crop_check(added)
    print(f"  offline partition check: {crop}")
    print(f"  enlargement adds {sum(p.area_km2 for p in added):,.0f} km2 in "
          f"{len(added)} rectangles ({sum(p.area_km2 for p in added) / ENLARGED.area_km2:.0%} "
          f"of the new extent)")

    rows, inc_total, inc_ids = [], 0.0, set()
    common.clear_overpass_cache()
    for part in added:
        result, features, candidates = extract_stage(part, ALL_LAYERS, cold=False)
        _report(f"  {part.key}", result)
        rows.append(result.to_dict())
        inc_total += result.total_s
        inc_ids |= {c.id for c in candidates}
        if not result.error:
            save_features(part.key, features)

    # The full re-extract to compare against was already pulled by
    # `phase_extract` ("enlarged / all 6 layers"); re-score it here rather
    # than re-fetching, so this comparison costs Overpass nothing.
    from plotlines_core.curation.notability import score_notability

    full_ids: set[str] = set()
    if common.has_features("enlarged-all"):
        full_ids = {c.id for c in
                    score_notability(common.load_features("enlarged-all"),
                                     live_layers=set(ALL_LAYERS))}
    trip_ids: set[str] = set()
    if common.has_features("trip-all"):
        trip_ids = {c.id for c in
                    score_notability(common.load_features("trip-all"),
                                     live_layers=set(ALL_LAYERS))}

    union = trip_ids | inc_ids
    out = {
        "offline_partition_check": crop,
        "added_parts": [{"key": p.key, "area_km2": round(p.area_km2, 1)} for p in added],
        "added_area_km2": round(sum(p.area_km2 for p in added), 1),
        "added_frac_of_new_extent": round(sum(p.area_km2 for p in added)
                                          / ENLARGED.area_km2, 3),
        "incremental_runs": rows,
        "incremental_total_s": round(inc_total, 2),
        "trip_candidates": len(trip_ids),
        "incremental_candidates": len(inc_ids),
        "union_candidates": len(union),
        "full_reextract_candidates": len(full_ids),
        "missing_from_union": sorted(full_ids - union)[:20],
        "extra_in_union": sorted(union - full_ids)[:20],
        "n_missing": len(full_ids - union),
        "n_extra": len(union - full_ids),
    }
    print(f"  incremental total {inc_total:7.2f}s   "
          f"union {len(union):,} vs full re-extract {len(full_ids):,} "
          f"(-{out['n_missing']} / +{out['n_extra']})")
    return out


PHASES = {
    "extract": phase_extract,
    "graph": phase_graph,
    "elevation": phase_elevation,
    "enlarge": phase_enlarge,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", action="append", choices=sorted(PHASES),
                    help="repeatable; default runs all four in order")
    ap.add_argument("--suffix", default="",
                    help="store under `<phase><suffix>` — used to keep a second "
                         "sample of a phase rather than overwrite the first, "
                         "since Overpass timings vary by an order of magnitude "
                         "run to run (RESULTS §2)")
    args = ap.parse_args()
    phases = args.phase or ["extract", "graph", "elevation", "enlarge"]

    global PHASE_SUFFIX
    PHASE_SUFFIX = args.suffix
    endpoint = common.select_overpass_endpoint()
    for name in phases:
        print(f"\n########## phase: {name} ##########")
        payload = PHASES[name]()
        if isinstance(payload, dict):
            payload["overpass_endpoint"] = endpoint
        _store(name + args.suffix, payload)
    print(f"\nwrote {PROBE_JSON}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
