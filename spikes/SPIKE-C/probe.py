"""SPIKE-C step 1 — pull every eligible way in every region, once — issue #170.

One tiled `out geom` union per region covers all three modes at once:

    highway = path | footway | track | bridleway | steps | cycleway,  plus  piste:type=*

That single set is the denominator for all six schemas in `schemas.py` and for the
same-place control tags, which is the point: **every number this spike publishes comes
out of one pull per region**, so a schema's coverage and its control's coverage are
measured over literally the same ways. A design with one query per schema could not
promise that, and the comparison is what makes a low number readable.

Geometry is fetched and immediately thrown away. It is here only to turn each way into
a length, so that coverage can be reported by kilometre as well as by way count — a
schema tagged on the 400 m of trail nobody walks and missing from the 40 km spine is
not 50% covered in any sense an Author cares about. See `cache.py` for why the distilled
records are what gets committed.

A second, tiny query per region counts route relations (`route=hiking`/`mtb`/`ski`).
Relations do not appear in a way pull, and they are the cheapest available proxy for
"is there an organised mapping community for this mode here" — which is the variable the
issue says coverage is really a function of.

Usage:
    python spikes/SPIKE-C/probe.py                    # all regions, cached
    python spikes/SPIKE-C/probe.py --regions tyrol    # one region
    python spikes/SPIKE-C/probe.py --refresh          # ignore the cache
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import requests
from pyproj import Geod

sys.path.insert(0, str(Path(__file__).parent))
import cache  # noqa: E402
from regions import REGIONS, TILES  # noqa: E402

HERE = Path(__file__).parent
RAW = HERE / "raw"
_GEOD = Geod(ellps="WGS84")

UA = "plotlines-spikeC/0.1 (research spike; gnfrazier@gmail.com)"

# Same endpoint discipline as SPIKE-04, and for the reason SPIKE-D turned into a
# finding: there is no single Overpass instance that can be relied on, and an
# exhausted endpoint list must be a hard error rather than an empty result. A silent
# zero in a spike whose entire job is to count tags would be read as "the schema is
# absent" — the exact wrong conclusion, reached by accident.
#
# Fail fast on the mirrors, be patient with the one that answers, and never wait
# longer than the server's own budget.
ENDPOINTS = (
    ("https://overpass-api.de/api/interpreter", (10, 240)),
    ("https://overpass.kumi.systems/api/interpreter", (10, 120)),
    ("https://overpass.private.coffee/api/interpreter", (10, 120)),
    ("https://maps.mail.ru/osm/tools/overpass/api/interpreter", (10, 120)),
)
ATTEMPTS = 5
PACE_S = 15         # gap after a *successful* query — stay welcome on a shared commons
SLOT_WAIT_S = 30    # after a 429 the client's own slot has to free up; mirrors won't help
QUERY_TIMEOUT_S = 180
HEADER = f"[out:json][timeout:{QUERY_TIMEOUT_S}]"

#: The one union that carries every denominator in `schemas.py`. Written as exact-value
#: statements rather than one `highway~"^(a|b|c)$"` regex: Overpass indexes exact tag
#: values and does not index regex matches, so the regex form scans every `highway=*`
#: object in the bbox. Same result, different cost — SPIKE-04 learned this the slow way.
WAYS_QUERY = (
    '('
    'way["highway"="path"]({bbox});'
    'way["highway"="footway"]({bbox});'
    'way["highway"="track"]({bbox});'
    'way["highway"="bridleway"]({bbox});'
    'way["highway"="steps"]({bbox});'
    'way["highway"="cycleway"]({bbox});'
    'way["piste:type"]({bbox});'
    ');out geom;'
)

#: Community-activity proxies. `route=ski` is the nordic/downhill route relation;
#: `piste:type` on a relation catches the networks mapped as relations rather than ways.
RELATION_PROBES = (
    ("hiking", 'relation["route"="hiking"]({bbox})'),
    ("foot", 'relation["route"="foot"]({bbox})'),
    ("mtb", 'relation["route"="mtb"]({bbox})'),
    ("bicycle", 'relation["route"="bicycle"]({bbox})'),
    ("ski", 'relation["route"="ski"]({bbox})'),
    ("piste", 'relation["piste:type"]({bbox})'),
)


#: The *curated* denominator, and the strongest possible case for FR14b.
#:
#: A way that belongs to a `route=hiking` or `route=mtb` relation is one somebody has
#: already deliberately assembled into a signed, named itinerary — the exact population
#: the issue says coverage is really a function of ("a function of local mapper community
#: more than of terrain"). If a schema is thin *here*, on the ways a mapping community has
#: personally curated, there is no denominator left to retreat to.
#:
#: `out ids` only: membership is all that is wanted, and the geometry already arrived in
#: the way pull.
MEMBER_PROBES = (
    ("hiking", 'relation["route"="hiking"]({bbox});way(r)'),
    ("mtb", 'relation["route"="mtb"]({bbox});way(r)'),
)


def overpass(query: str) -> dict:
    last = None
    for attempt in range(1, ATTEMPTS + 1):
        for endpoint, timeout in ENDPOINTS:
            host = endpoint.split("/")[2]
            try:
                resp = requests.post(endpoint, data={"data": query},
                                     headers={"User-Agent": UA}, timeout=timeout)
            except requests.RequestException as exc:
                last = f"{host}: {type(exc).__name__}"
                print(f"      {host} -> {type(exc).__name__}", file=sys.stderr)
                continue
            if resp.status_code == 200:
                try:
                    data = resp.json()
                except ValueError:
                    # A 200 carrying an HTML error page is how Overpass reports a
                    # runtime error. A failure, never an empty result.
                    last = f"{host}: 200 but non-JSON body"
                    print(f"      {host} -> 200 non-JSON", file=sys.stderr)
                    continue
                time.sleep(PACE_S)
                return data
            last = f"{host}: HTTP {resp.status_code}"
            print(f"      {host} -> HTTP {resp.status_code}", file=sys.stderr)
            if resp.status_code == 429:
                time.sleep(SLOT_WAIT_S)
        if attempt < ATTEMPTS:
            backoff = 20 * attempt
            print(f"      all endpoints failed (attempt {attempt}/{ATTEMPTS}); "
                  f"waiting {backoff}s", file=sys.stderr)
            time.sleep(backoff)
    raise RuntimeError(f"all Overpass endpoints failed {ATTEMPTS}x; last: {last}")


def cached(path: Path, build, refresh: bool = False):
    if cache.exists(path) and not refresh:
        return cache.load(path)
    data = build()
    cache.save(path, data)
    return data


def distil(payload: dict) -> list[dict]:
    """Way -> `{id, length_m, tags}`. Geometry is consumed here and never stored."""
    out = []
    for element in payload.get("elements", []):
        if element.get("type") != "way":
            continue
        geom = element.get("geometry") or []
        if len(geom) >= 2:
            lons = [p["lon"] for p in geom]
            lats = [p["lat"] for p in geom]
            length_m = sum(
                _GEOD.inv(lons[i], lats[i], lons[i + 1], lats[i + 1])[2]
                for i in range(len(geom) - 1)
            )
        else:
            length_m = 0.0
        out.append({"id": element["id"], "length_m": round(length_m, 1),
                    "tags": element.get("tags", {})})
    return out


def merge_ways(batches: list[list[dict]]) -> list[dict]:
    """De-duplicate by way id across tiles.

    `out geom` returns a way's *complete* geometry whenever any of its nodes falls in
    the bbox, so a trail crossing a tile boundary comes back twice, identical. Keeping
    the longer record is therefore a no-op in the normal case and the right answer in
    the one case it is not (a server that clipped). What it must never do is add the
    two together — that would inflate exactly the long spine trails whose length this
    spike weights coverage by.
    """
    merged: dict[int, dict] = {}
    for batch in batches:
        for way in batch:
            prev = merged.get(way["id"])
            if prev is None or way["length_m"] > prev["length_m"]:
                merged[way["id"]] = way
    return list(merged.values())


def fetch_region(region, refresh: bool = False) -> list[dict]:
    # The merged per-region file is the committed artifact; the per-tile files under
    # `raw/tiles/` are a resume buffer for the fetch itself and are not kept (they are
    # byte-for-byte duplicates of what the merge produces). So: if the merged file is
    # already here, this region is done, and a fresh clone never re-hits Overpass.
    merged = RAW / f"{region.key}-ways.json"
    if cache.exists(merged) and not refresh:
        ways = cache.load(merged)
        print(f"      cached: {len(ways):,} ways")
        return ways

    n = TILES.get(region.key, 1)
    grid = region.tiles(n)
    batches = []
    for k, bbox in enumerate(grid, 1):
        # Per-tile caching, not just per-region: a 504 on the last tile of a 3x3 must
        # not discard eight successful pulls (SPIKE-04 §fetch_tiled).
        path = RAW / "tiles" / f"{region.key}-ways-{n}x{n}-{k}.json"
        ways = cached(path, lambda b=bbox: distil(
            overpass(f"{HEADER};" + WAYS_QUERY.format(bbox=b))), refresh)
        batches.append(ways)
        print(f"      tile {k}/{len(grid)}: {len(ways):,} ways")
    return merge_ways(batches)


def fetch_relations(region, refresh: bool = False) -> dict[str, int]:
    query = f"{HEADER};" + "".join(
        f"{sel.format(bbox=region.bbox)};out count;" for _, sel in RELATION_PROBES)
    payload = cached(RAW / f"{region.key}-relations.json",
                     lambda: overpass(query), refresh)
    counts = [e for e in payload.get("elements", []) if e.get("type") == "count"]
    if len(counts) != len(RELATION_PROBES):
        raise RuntimeError(
            f"{region.key}: {len(counts)} counts for {len(RELATION_PROBES)} probes — "
            "the probe list and the response are out of step, so every label would be "
            "attached to the wrong number")
    return {label: int(c.get("tags", {}).get("total", 0))
            for (label, _), c in zip(RELATION_PROBES, counts)}


def fetch_members(region, refresh: bool = False) -> dict[str, list[int]]:
    out: dict[str, list[int]] = {}
    for label, sel in MEMBER_PROBES:
        query = f"{HEADER};" + sel.format(bbox=region.bbox) + ";out ids;"
        payload = cached(RAW / f"{region.key}-members-{label}.json",
                         lambda q=query: overpass(q), refresh)
        out[label] = sorted({e["id"] for e in payload.get("elements", [])
                             if e.get("type") == "way"})
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true", help="ignore the raw/ cache")
    ap.add_argument("--regions", nargs="*", help="region keys; default all")
    args = ap.parse_args()

    wanted = [r for r in REGIONS if not args.regions or r.key in args.regions]
    for region in wanted:
        print(f"\n=== {region.name} ({region.key}) {region.area_km2:,.0f} km2 ===")
        ways = fetch_region(region, args.refresh)
        km = sum(w["length_m"] for w in ways) / 1000.0
        cache.save(RAW / f"{region.key}-ways.json", ways)
        rels = fetch_relations(region, args.refresh)
        cache.save(RAW / f"{region.key}-relations-counts.json", rels)
        members = fetch_members(region, args.refresh)
        cache.save(RAW / f"{region.key}-members.json", members)
        size = cache.cache_path(RAW / f"{region.key}-ways.json").stat().st_size
        print(f"  {len(ways):,} unique ways   {km:,.0f} km   "
              f"({size / 1e6:.1f} MB gz)")
        print(f"  relations: " + "  ".join(f"{k}={v}" for k, v in rels.items()))
        print(f"  curated member ways: "
              + "  ".join(f"{k}={len(v):,}" for k, v in members.items()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
