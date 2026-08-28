"""SPIKE-H orchestration — issue #160. Runs every point the issue asks for
against real code and real (or realistically cached) external data, and
writes `results/*.json` for `results/RESULTS.md` to cite.

    core/.venv/bin/python spikes/SPIKE-H/run_spike.py

Everything network-touching is cached to `raw/*.json.gz` after the first
run (see `arcgis_common.py`); a committed cache means a second run, or CI,
never re-hits `gis2.ncdcr.gov` / `mapservices.nps.gov` / `geo.dot.gov`.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import _paths  # noqa: F401

from contract import BBox
from nc_markers_provider import NCHighwayMarkersProvider
from nps_pois_provider import NPSPublicPOIsProvider
from osm_layer_provider import SharedOsmFetch, builtin_providers, cached_trip_loader
from registry import LayerRegistry
from scenic_byways_provider import USScenicBywaysProvider

from plotlines_core.curation.colocate import analyze_colocation

HERE = Path(__file__).resolve().parent
RESULTS = HERE / "results"

# TOUR bbox (Asheville-Boone corridor) — only for the scenic-byways query,
# which needs more than TRIP's small box to catch a real designated route.
TOUR_BBOX = BBox(west=-82.75, south=35.50, east=-81.65, north=36.30)


def section(title: str) -> None:
    print(f"\n=== {title} ===")


def main() -> None:
    RESULTS.mkdir(parents=True, exist_ok=True)
    out: dict = {}

    # ---------------------------------------------------------------- §1/§4
    # Built-in OSM, expressed as real LayerProviders, reading SPIKE-D's
    # committed TRIP extraction (see osm_layer_provider.py's docstring for
    # why this run does not hit Overpass again).
    section("1. Built-in OSM layers as LayerProvider (TRIP bbox)")
    trip_bbox, trip_loader = cached_trip_loader()
    shared = SharedOsmFetch(trip_loader)
    osm = builtin_providers(shared)
    osm_candidates = []
    for layer, provider in osm.items():
        cands = provider.fetch_candidates(trip_bbox)
        osm_candidates.extend(cands)
        print(f"  {layer:9} taxonomy={len(provider.taxonomy):3} rows  "
              f"candidates={len(cands):4}  licence={provider.licence.id}")
    print(f"  total OSM candidates: {len(osm_candidates)}  "
          f"(one Overpass-shaped fetch shared across all six instances)")
    out["osm"] = {
        "bbox": "TRIP", "total_candidates": len(osm_candidates),
        "by_layer": {layer: len(provider.fetch_candidates(trip_bbox))
                    for layer, provider in osm.items()},
    }

    # -------------------------------------------------------------------- §2
    # Three real external sources, live ArcGIS REST (cached after first run).
    section("2. Real external sources — live ArcGIS REST")

    nc = NCHighwayMarkersProvider()
    t0 = time.perf_counter()
    nc_candidates_direct = nc.fetch_candidates(trip_bbox)  # bypasses the gate — see §5
    nc_fetch_s = time.perf_counter() - t0
    print(f"  NC Highway Historical Markers: {len(nc_candidates_direct)} candidates "
          f"in {nc_fetch_s:.2f}s (fetched directly, gate tested separately in §5)")

    nps = NPSPublicPOIsProvider()
    t0 = time.perf_counter()
    nps_candidates = nps.fetch_candidates(trip_bbox)
    nps_fetch_s = time.perf_counter() - t0
    print(f"  NPS Public POIs: {len(nps_candidates)} candidates in {nps_fetch_s:.2f}s")
    poi_type_counts: dict[str, int] = {}
    for c in nps_candidates:
        poi_type_counts[c.tags.get("poi_type", "?")] = poi_type_counts.get(c.tags.get("poi_type", "?"), 0) + 1

    byways = USScenicBywaysProvider()
    t0 = time.perf_counter()
    byway_candidates = byways.fetch_candidates(TOUR_BBOX)
    byway_fetch_s = time.perf_counter() - t0
    print(f"  US Scenic Byways (NC): {len(byway_candidates)} candidates in {byway_fetch_s:.2f}s")
    byway_detail = [
        {"name": c.tags.get("name"), "length_km": c.tags.get("length_km"),
         "n_paths": c.tags.get("n_paths"), "n_vertices": c.tags.get("n_vertices"),
         "centroid": list(c.coord)}
        for c in byway_candidates
    ]

    out["external"] = {
        "nc_markers": {"count": len(nc_candidates_direct), "fetch_s": round(nc_fetch_s, 2),
                        "licence_satisfiable": nc.licence.satisfiable},
        "nps_pois": {"count": len(nps_candidates), "fetch_s": round(nps_fetch_s, 2),
                     "licence_satisfiable": nps.licence.satisfiable,
                     "by_poi_type": poi_type_counts},
        "scenic_byways": {"count": len(byway_candidates), "fetch_s": round(byway_fetch_s, 2),
                          "licence_satisfiable": byways.licence.satisfiable,
                          "routes": byway_detail},
    }

    # -------------------------------------------------------------------- §3
    section("3. Area/route geometry — what survives to a Candidate")
    total_verts = sum(int(c.tags.get("n_vertices", 0)) for c in byway_candidates)
    total_km = sum(float(c.tags.get("length_km", 0)) for c in byway_candidates)
    print(f"  {len(byway_candidates)} byways, {total_verts} real vertices, "
          f"{total_km:.0f} km of route -> {len(byway_candidates)} points "
          f"(one centroid each). Vertex/length data survives only in `tags`, "
          f"which nothing downstream reads.")
    raw_osm = shared.features_for(trip_bbox)
    polygon_features = [f for f in raw_osm if f.area_m2 is not None]
    print(f"  {len(polygon_features)} of {len(raw_osm)} raw OSM features carry an "
          f"`area_m2` scalar (e.g. `leisure=park`'s FR98(b) gate) — and even that "
          f"scalar does not survive into `Candidate`, which has no area/geometry "
          f"field at all: only `coord`.")
    out["geometry"] = {
        "byway_routes": len(byway_candidates), "byway_vertices_discarded": total_verts,
        "byway_km_discarded": round(total_km, 1),
        "raw_features_with_area_m2": len(polygon_features),
        "raw_features_total": len(raw_osm),
        "candidate_has_area_field": False,
    }

    # -------------------------------------------------------------------- §4
    # Affinity-driven co-location, merging OSM (core's real taxonomy) with a
    # real, loadable, unlike plugin source (NPS) — no core code touched.
    section("4. Co-location across OSM + a real, loadable plugin source")
    merged = osm_candidates + nps_candidates
    proposals = analyze_colocation(merged, trip_bbox)
    mixed = [p for p in proposals
            if any(m.candidate_id.startswith("nps-poi/") for m in p.members)
            and any(not m.candidate_id.startswith("nps-poi/") for m in p.members)]
    station_props = [p for p in proposals if "station" in p.role_affinities]
    print(f"  {len(merged)} merged candidates -> {len(proposals)} cluster proposals")
    print(f"  proposals mixing an NPS candidate with a non-NPS one: {len(mixed)}")
    print(f"  proposals carrying the 'station' affinity (Mile Marker): {len(station_props)}")
    out["colocation"] = {
        "merged_candidates": len(merged), "proposals": len(proposals),
        "mixed_source_proposals": len(mixed),
        "station_affinity_proposals": len(station_props),
        "examples": [
            {"name": p.name, "kind": p.kind, "role_affinities": list(p.role_affinities),
             "members": [{"id": m.candidate_id, "layer": m.layer, "type": m.type,
                          "affinity": m.role_affinity} for m in p.members]}
            for p in (mixed[:3] + station_props[:3])
        ],
    }

    # -------------------------------------------------------------------- §5
    # Licence gate — a real blocked source vs. a real loaded one.
    section("5. Licence gate — real sources")
    registry = LayerRegistry()
    for layer, provider in osm.items():
        registry.register_builtin(layer, provider)
    registry.register_plugin("plugin_nc_markers", nc)
    registry.register_plugin("plugin_nps_pois", NPSPublicPOIsProvider(cache_key="nps_pois_trip"))
    per_layer = registry.per_layer()
    for layer, state in per_layer.items():
        print(f"  {layer:24} {state}")
    out["licence_gate"] = per_layer

    # -------------------------------------------------------------------- §6
    # Per-layer load state — a real slow fetch and a real broken layer id.
    section("6. Per-layer load state — real slow + real broken")
    from arcgis_common import RAW

    slow_cache = RAW / "nps_pois_slow_demo.json.gz"
    was_cached = slow_cache.exists()
    slow_provider = NPSPublicPOIsProvider(cache_key="nps_pois_slow_demo", delay_s=3.0)
    t0 = time.perf_counter()
    slow_candidates = slow_provider.fetch_candidates(trip_bbox)
    slow_elapsed = time.perf_counter() - t0
    print(f"  slow provider (delay_s=3.0, {'cache hit' if was_cached else 'live fetch'}): "
          f"{slow_elapsed:.2f}s wall, {len(slow_candidates)} candidates")

    class BrokenNPSProvider(NPSPublicPOIsProvider):
        """Same real service, a layer id (99) that does not exist — a real
        upstream 'Layer not found' rather than a fabricated exception."""

        def fetch_candidates(self, bbox):
            from arcgis_common import query_envelope
            from nps_pois_provider import BASE_URL
            query_envelope(self._cache_key, BASE_URL, 99, bbox)
            return []  # unreachable — query_envelope raises on ArcGIS's error body

    broken = BrokenNPSProvider(cache_key="nps_broken_layer_demo")
    registry.register_plugin("plugin_nps_broken", broken)
    print(f"  registered (load_state ready — the provider itself is fine; "
          f"the failure only shows up on fetch): {registry.per_layer()['plugin_nps_broken']}")
    _, fetch_errors = registry.fetch_candidates_all(trip_bbox, {"plugin_nps_broken"})
    broken_state = registry.per_layer()["plugin_nps_broken"]
    print(f"  after fetch_candidates_all: {broken_state}  "
          f"(N2's AC: which layer and why, and the other layers are unaffected)")
    out["load_state"] = {
        "slow_fetch_s": round(slow_elapsed, 2), "slow_candidates": len(slow_candidates),
        "broken_state": broken_state,
    }

    # ------------------------------------------------------------------ write
    results_path = RESULTS / "run_spike.json"
    results_path.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"\nwrote {results_path}")


if __name__ == "__main__":
    main()
