"""Issue #276 (Phase 3.4) — re-validate SPIKE-A's golden candidate sets
against the #275 local-clip candidate path.

SPIKE-I (#265) measured graph parity only ("path T" for `ensure_graph`) and
said so explicitly: "#276 should still run against the candidate path, which
this spike did not touch" (`spikes/SPIKE-I/results/RESULTS.md` §1.3). This
script is that run, for `curation/providers.py::OsmLayerProvider`'s own
`_fetch_from_local_clip` (added by #275), not the routing graph.

**Design: isolate the transport from data/ruleset drift.** SPIKE-A's frozen
`results/golden/*.json` were captured at `RULESET_VERSION 1.2.0`; the
taxonomy is at `1.3.0` today (`sight` replacing bare `tourism` among other
changes) and live OSM data has moved in the two named regions since. A raw
diff against golden would conflate three causes — transport, ruleset version,
and OSM churn — which is exactly the "close enough" failure G5 named. So this
script fetches each region's Overpass response **once** and builds candidates
two ways from the identical bytes:

  path O — `OsmLayerProvider._features_from_gdf` over the gdf
           `osmnx.features.features_from_bbox` itself would have produced
           (`_create_gdf(response_jsons, polygon, tags)`) — the pre-#275 live
           branch, today's taxonomy.
  path T — the same elements written to a synthetic `.osm.pbf`
           (`osmium.osm.mutable.Node/Way/Relation` + `SimpleWriter`, the
           exact technique `core/tests/test_graph_pbf_source.py` uses for its
           fixtures) and read back through
           `OsmLayerProvider._fetch_from_local_clip` — the #275 branch,
           unmodified production code, not a reimplementation.

O vs T isolates the transport. A separate, clearly-labelled diff against
`results/golden/` is also reported, for the record, but it is not this
issue's finding — see `results/REVALIDATION_276.md`.

Usage:
    cd core && uv run --frozen python3 ../spikes/SPIKE-A/revalidate_clip_candidates.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import osmium
from osmium.osm import mutable

CORE = Path(__file__).resolve().parents[2] / "core"
sys.path.insert(0, str(CORE))
sys.path.insert(0, str(Path(__file__).parent))

from regions import REGIONS, REGIONS_BY_KEY  # noqa: E402

import osmnx as ox  # noqa: E402
from osmnx import features as ox_features  # noqa: E402
from osmnx import utils_geo  # noqa: E402

from plotlines_core.curation.notability import RULESET_VERSION, score_notability  # noqa: E402
from plotlines_core.curation.providers import (  # noqa: E402
    OsmLayerProvider,
    osm_tags_for,
)
from plotlines_core.curation.taxonomy import LAYERS  # noqa: E402
from plotlines_core.osm_identity import apply_osm_http_identity  # noqa: E402

apply_osm_http_identity()

HERE = Path(__file__).parent
RESULTS = HERE / "results"
SCRATCH = HERE / "scratch_clip_revalidation"

TAGS = osm_tags_for(set(LAYERS))

_MEMBER_TYPE = {"node": "n", "way": "w", "relation": "r"}


def _merged_elements(response_jsons: list[dict]) -> list[dict]:
    """Dedupe (type, id) across however many sub-polygon responses osmnx's
    own `_make_overpass_polygon_coord_strs` split the query into, merging
    tags on a repeat the same way `SPIKE-A/analyze.py::load_features` does
    for its own (differently-sourced) raw pulls.

    Copies each element (and its `tags` dict) rather than holding the same
    reference `response_jsons` does — `osmnx.features._create_gdf` mutates
    its input elements in place (`_process_features` pops keys off them),
    and `revalidate_region` below builds path O and path T from the *same*
    `response_jsons`, so a shared reference here would have path O's own gdf
    construction silently corrupt what path T then reads."""
    seen: dict[tuple[str, int], dict] = {}
    order: list[tuple[str, int]] = []
    for rj in response_jsons:
        for el in rj.get("elements", []):
            if el.get("type") not in ("node", "way", "relation"):
                continue
            key = (el["type"], el["id"])
            if key in seen:
                seen[key]["tags"] = {**seen[key].get("tags", {}), **el.get("tags", {})}
                continue
            copy = dict(el)
            copy["tags"] = dict(el.get("tags", {}))
            if "nodes" in copy:
                copy["nodes"] = list(copy["nodes"])
            if "members" in copy:
                copy["members"] = [dict(m) for m in copy["members"]]
            seen[key] = copy
            order.append(key)
    return [seen[k] for k in order]


def _write_pbf(path: Path, elements: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    with osmium.SimpleWriter(str(path)) as writer:
        for el in elements:
            if el["type"] == "node":
                writer.add_node(mutable.Node(
                    id=el["id"], location=(el["lon"], el["lat"]), tags=el.get("tags") or {}))
        for el in elements:
            if el["type"] == "way":
                writer.add_way(mutable.Way(
                    id=el["id"], nodes=el.get("nodes", []), tags=el.get("tags") or {}))
        for el in elements:
            if el["type"] == "relation":
                members = [
                    (_MEMBER_TYPE[m["type"]], m["ref"], m.get("role", ""))
                    for m in el.get("members", [])
                ]
                writer.add_relation(mutable.Relation(
                    id=el["id"], members=members, tags=el.get("tags") or {}))


def _candidate_view(cands) -> dict[str, dict]:
    return {
        c.id: {
            "salience": round(c.salience, 4),
            "layer": c.layer,
            "role_affinity": c.role_affinity,
        }
        for c in cands
    }


def _diff(a: dict[str, dict], b: dict[str, dict], *, salience_tol: float = 1e-6) -> dict:
    a_ids, b_ids = set(a), set(b)
    added = sorted(b_ids - a_ids)
    dropped = sorted(a_ids - b_ids)
    changed = []
    for cid in sorted(a_ids & b_ids):
        if abs(a[cid]["salience"] - b[cid]["salience"]) > salience_tol or \
                a[cid]["layer"] != b[cid]["layer"] or \
                a[cid]["role_affinity"] != b[cid]["role_affinity"]:
            changed.append({"id": cid, "a": a[cid], "b": b[cid]})
    return {
        "a_count": len(a_ids), "b_count": len(b_ids),
        "added": added, "dropped": dropped, "changed": changed,
        "exact": not added and not dropped and not changed,
    }


def revalidate_region(region_key: str) -> dict:
    region = REGIONS_BY_KEY[region_key]
    bbox_lonlat = region.bbox_lonlat  # (west, south, east, north)
    polygon = utils_geo.bbox_to_poly(bbox_lonlat)

    response_jsons = list(ox._overpass._download_overpass_features(polygon, TAGS))
    elements = _merged_elements(response_jsons)

    # path O: the pre-#275 live branch's own gdf construction, over the
    # elements just fetched (no second network round trip).
    gdf_o = ox_features._create_gdf(response_jsons, polygon, TAGS)
    raw_o = [f for f in OsmLayerProvider._features_from_gdf(gdf_o) if f is not None]
    cands_o = score_notability(raw_o, live_layers=LAYERS)

    # path T: the same bytes, through #275's shipped local-clip branch.
    pbf_path = SCRATCH / f"{region_key}.osm.pbf"
    _write_pbf(pbf_path, elements)
    provider = OsmLayerProvider()
    raw_t = provider._fetch_from_local_clip(pbf_path, bbox_lonlat, TAGS)
    cands_t = score_notability(raw_t, live_layers=LAYERS)

    view_o, view_t = _candidate_view(cands_o), _candidate_view(cands_t)
    ot_diff = _diff(view_o, view_t)

    golden_path = RESULTS / "golden" / f"{region_key}.json"
    golden = json.loads(golden_path.read_text())
    view_golden = {
        c["id"]: {"salience": c["salience"], "layer": c["layer"], "role_affinity": c["role_affinity"]}
        for c in golden["candidates"]
    }
    golden_diff = _diff(view_golden, view_o)

    return {
        "region": region_key,
        "name": region.name,
        "raw_elements_fetched": len(elements),
        "current_ruleset_version": RULESET_VERSION,
        "golden_ruleset_version": golden["ruleset_version"],
        "path_o_candidates": len(cands_o),
        "path_t_candidates": len(cands_t),
        "golden_candidates": golden["candidate_count"],
        "transport_delta_O_vs_T": ot_diff,
        "drift_golden_vs_O": {
            "a_count": golden_diff["a_count"], "b_count": golden_diff["b_count"],
            "added": len(golden_diff["added"]), "dropped": len(golden_diff["dropped"]),
            "changed": len(golden_diff["changed"]), "exact": golden_diff["exact"],
        },
    }


def main() -> int:
    SCRATCH.mkdir(exist_ok=True)
    reports = [revalidate_region(r.key) for r in REGIONS]
    out = RESULTS / "revalidation_276.json"
    out.write_text(json.dumps(reports, indent=2), encoding="utf-8")

    for rep in reports:
        print(f"\n=== {rep['name']} ({rep['region']}) ===")
        print(f"  raw elements fetched      {rep['raw_elements_fetched']:,}")
        print(f"  path O (live) candidates  {rep['path_o_candidates']:,}")
        print(f"  path T (clip) candidates  {rep['path_t_candidates']:,}")
        d = rep["transport_delta_O_vs_T"]
        print(f"  O vs T: {'EXACT' if d['exact'] else 'DIFFERS'} "
              f"(+{len(d['added'])} / -{len(d['dropped'])} / ~{len(d['changed'])})")
        g = rep["drift_golden_vs_O"]
        print(f"  golden({rep['golden_ruleset_version']}) vs O({rep['current_ruleset_version']}): "
              f"{'EXACT' if g['exact'] else 'DIFFERS'} "
              f"(+{g['added']} / -{g['dropped']} / ~{g['changed']})")

    print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
