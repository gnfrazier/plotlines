"""SPIKE-A step 2 - calibrate FR98 against the real extracts.

Reads the `raw/` pulls, runs `plotlines_core.curation` over them exactly as the
product would, and reports the two things the issue asks for:

  (a) `historic=*` sub-weighting by value - the actual value-frequency table in
      three regions, so the seed weights in `taxonomy.py` can be set from what is
      out there rather than guessed.
  (b) density-triggered qualification - which matched types contribute so many
      candidates to a trip bbox that they need a qualifying attribute, and where
      the measured break between "notable" and "noise" actually falls.

Also writes golden candidate sets to `results/golden/` (ARCH §15.1) and a
proposed versioned ruleset to `results/notability_ruleset.v2.json`.

Usage:
    python spikes/SPIKE-A/analyze.py            # needs probe.py first
    python spikes/SPIKE-A/analyze.py --write-golden
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

from pyproj import Geod

CORE = Path(__file__).resolve().parents[2] / "core"
sys.path.insert(0, str(CORE))
sys.path.insert(0, str(Path(__file__).parent))

import cache  # noqa: E402
from regions import REGIONS, REGIONS_BY_KEY  # noqa: E402

from plotlines_core.curation.notability import RawFeature, score_notability, RULESET_VERSION  # noqa: E402
from plotlines_core.curation.taxonomy import LAYERS, TAXONOMY, match, weight_for  # noqa: E402

HERE = Path(__file__).parent
RAW = HERE / "raw"
RESULTS = HERE / "results"
KEYS = ("historic", "tourism", "amenity", "natural", "leisure", "man_made")
_GEOD = Geod(ellps="WGS84")

# A trip bbox this size that surfaces more than this many candidates of a single
# type is not giving the Author something reviewable - it is giving them that
# type's basemap. Set from the measured break (see RESULTS.md); this constant is
# the spike's proposed value for FR98(b).
REVIEWABLE_PER_TYPE = 40


def _poly_area_m2(geom: list[dict]) -> float | None:
    if not geom or len(geom) < 4:
        return None
    lons = [p["lon"] for p in geom]
    lats = [p["lat"] for p in geom]
    area, _ = _GEOD.polygon_area_perimeter(lons, lats)
    return abs(area)


def _coord(el: dict) -> tuple[float, float] | None:
    if el["type"] == "node":
        return (el.get("lon"), el.get("lat"))
    c = el.get("center")
    if c:
        return (c.get("lon"), c.get("lat"))
    geom = el.get("geometry")
    if geom:
        return (sum(p["lon"] for p in geom) / len(geom),
                sum(p["lat"] for p in geom) / len(geom))
    return None


def load_features(region_key: str) -> list[RawFeature]:
    """Every raw element for a region, as `RawFeature`s, deduped by (type,id).

    Areas come from the `leisure-geom` pull where available (that is the only
    family with an area-gated type today); everything else has `area_m2=None`,
    which is what a point feature carries anyway.
    """
    areas: dict[str, float] = {}
    geom_path = RAW / f"{region_key}-leisure-geom.json"
    if cache.exists(geom_path):
        for el in cache.load(geom_path).get("elements", []):
            if el.get("type") == "way" and el.get("geometry"):
                a = _poly_area_m2(el["geometry"])
                if a is not None:
                    areas[f"way/{el['id']}"] = a

    seen: dict[tuple[str, int], RawFeature] = {}
    for key in KEYS:
        path = RAW / f"{region_key}-{key}.json"
        if not cache.exists(path):
            continue
        for el in cache.load(path).get("elements", []):
            if el.get("type") not in ("node", "way", "relation"):
                continue
            ident = (el["type"], el["id"])
            if ident in seen:
                # a feature tagged in two families (historic + tourism, say);
                # merge tags so `match()` sees the whole picture.
                seen[ident].tags.update(el.get("tags", {}))
                continue
            coord = _coord(el)
            if coord is None or coord[0] is None:
                continue
            fid = f"{el['type']}/{el['id']}"
            seen[ident] = RawFeature(
                id=fid, coord=coord, tags=dict(el.get("tags", {})),
                area_m2=areas.get(fid),
            )
    return list(seen.values())


def _rule_key(tags: dict) -> str:
    r = match(tags)
    if r is None:
        return "<no rule>"
    if r.is_wildcard:
        return f"{r.key}={tags.get(r.key, '?')}  (wildcard {r.key}=*)"
    return f"{r.key}={r.value}"


def analyse_region(region_key: str) -> dict:
    region = REGIONS_BY_KEY[region_key]
    feats = load_features(region_key)
    cands = score_notability(feats, live_layers=LAYERS)

    matched = [f for f in feats if match(f.tags) is not None]
    unmatched = [f for f in feats if match(f.tags) is None]
    filtered_by_gate = len(matched) - len(cands)

    # candidate density by resolved type
    by_type = Counter(_rule_key(c.tags) for c in cands)
    # historic=* value frequency (raw, pre-filter - a wildcard type has no gate)
    hist_values = Counter(
        f.tags.get("historic") for f in feats if f.tags.get("historic")
    )
    # what the unmatched tail looks like - the "should we add a rule?" question
    unmatched_kinds: Counter = Counter()
    for f in unmatched:
        for k in KEYS:
            if k in f.tags:
                unmatched_kinds[f"{k}={f.tags[k]}"] += 1
                break

    return {
        "region": region_key,
        "name": region.name,
        "area_km2": round(region.area_km2, 1),
        "raw_features": len(feats),
        "matched": len(matched),
        "unmatched": len(unmatched),
        "candidates": len(cands),
        "filtered_by_qualification": filtered_by_gate,
        "candidates_per_100km2": region.per_100km2(len(cands)),
        "salience_buckets": _buckets([c.salience for c in cands]),
        "affinity_split": dict(Counter(c.role_affinity for c in cands)),
        "candidates_by_type": by_type.most_common(),
        "over_reviewable_types": [
            (t, n) for t, n in by_type.most_common() if n > REVIEWABLE_PER_TYPE
        ],
        "historic_value_frequency": hist_values.most_common(),
        "unmatched_top": unmatched_kinds.most_common(25),
    }


def _buckets(vals: list[float]) -> dict:
    b = {"0.0-0.2": 0, "0.2-0.4": 0, "0.4-0.6": 0, "0.6-0.8": 0, "0.8-1.0": 0}
    for v in vals:
        if v < 0.2:
            b["0.0-0.2"] += 1
        elif v < 0.4:
            b["0.2-0.4"] += 1
        elif v < 0.6:
            b["0.4-0.6"] += 1
        elif v < 0.8:
            b["0.6-0.8"] += 1
        else:
            b["0.8-1.0"] += 1
    return b


def write_golden(region_key: str) -> Path:
    """A golden candidate set (ARCH §15.1): bbox + ruleset version + the sorted
    candidate list. A later ruleset change that moves any of these is either a
    bug or a reviewed decision - never silent."""
    region = REGIONS_BY_KEY[region_key]
    cands = score_notability(load_features(region_key), live_layers=LAYERS)
    payload = {
        "region": region_key,
        "bbox_south_west_north_east": [region.south, region.west, region.north, region.east],
        "layers": sorted(LAYERS),
        "ruleset_version": RULESET_VERSION,
        "candidate_count": len(cands),
        "candidates": [
            {
                "id": c.id,
                "salience": round(c.salience, 4),
                "layer": c.layer,
                "role_affinity": c.role_affinity,
                "type": _rule_key(c.tags),
                "title": c.title,
            }
            for c in sorted(cands, key=lambda c: (-c.salience, c.id))
        ],
    }
    out = RESULTS / "golden" / f"{region_key}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write-golden", action="store_true")
    ap.add_argument("--json", action="store_true", help="dump the full analysis as JSON")
    args = ap.parse_args()

    reports = [analyse_region(r.key) for r in REGIONS]

    if args.json:
        print(json.dumps(reports, indent=2))
    else:
        for rep in reports:
            print(f"\n{'=' * 70}\n{rep['name']} ({rep['region']}) - {rep['area_km2']:,} km2")
            print(f"{'=' * 70}")
            print(f"  raw features          {rep['raw_features']:>6,}")
            print(f"  matched a rule        {rep['matched']:>6,}")
            print(f"  -> candidates         {rep['candidates']:>6,}   "
                  f"({rep['candidates_per_100km2']}/100km2)")
            print(f"  filtered by gate      {rep['filtered_by_qualification']:>6,}")
            print(f"  unmatched (no rule)   {rep['unmatched']:>6,}")
            print(f"  affinity split        {rep['affinity_split']}")
            print(f"  salience buckets      {rep['salience_buckets']}")
            print(f"\n  candidates by type (top 20):")
            for t, n in rep["candidates_by_type"][:20]:
                flag = "  <-- over reviewable" if n > REVIEWABLE_PER_TYPE else ""
                print(f"    {n:>5,}  {t}{flag}")
            print(f"\n  historic=* value frequency:")
            for v, n in rep["historic_value_frequency"]:
                r = match({"historic": v})
                w = weight_for(r, {"historic": v}) if r else None
                print(f"    {n:>4,}  historic={v:<22} current weight {w}")
            print(f"\n  unmatched tail (top 15) - rule candidates:")
            for t, n in rep["unmatched_top"][:15]:
                print(f"    {n:>4,}  {t}")

    if args.write_golden:
        for r in REGIONS:
            p = write_golden(r.key)
            if not args.json:
                print(f"wrote {p}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
