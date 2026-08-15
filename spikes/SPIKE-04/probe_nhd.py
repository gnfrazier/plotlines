"""SPIKE-04 step 4 — the alternative network: USGS NHDPlus High Resolution.

The spike question names OSM for the waterway graph. It is worth checking whether OSM is
even the right source, because there is a purpose-built one: NHDPlus HR is the national
hydrography dataset, and unlike OSM's cartographic centrelines it ships the things a
router needs as first-class attributes —

  * `fromnode` / `tonode`: explicit network topology. Connectivity is *stated*, not
    inferred from whether two ways happen to share a node.
  * `flowdir`: which way the water goes. A paddling router that ignores this will
    cheerfully send a Character up a class III rapid.
  * `streamorde`: Strahler stream order, which is an objective, uniform proxy for "big
    enough to float a boat". OSM's river/stream split is a mapper's judgement call and
    varies by who mapped the county.
  * `reachcode`: the identifier USGS gauges are themselves indexed by (see NLDI in
    `probe_nldi.py`), which is what makes gauge-to-reach association a lookup rather than
    a spatial guess.

It carries no class ratings, no put-ins, and no portages — so this is not a replacement
for the OSM probe, it is a candidate for a different layer of the same answer.

Licensing: USGS, public domain (17 U.S.C. §105), no key, no quota negotiation.

Usage:
    python spikes/SPIKE-04/probe_nhd.py [--refresh]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).parent))
import cache  # noqa: E402
from regions import REGIONS  # noqa: E402

HERE = Path(__file__).parent
RAW = HERE / "raw"

UA = "plotlines-spike04/0.1 (research spike; gnfrazier@gmail.com)"
FLOWLINE = ("https://hydro.nationalmap.gov/arcgis/rest/services/"
            "NHDPlus_HR/MapServer/3/query")

# Strahler stream order 4 is the working definition of "paddleable-scale" used
# throughout this spike. It is a threshold, not a truth: order 3 holds runnable creeks at
# high water and order 4 holds some channels too shallow to float in August. It is used
# because it is *uniform* — the same rule everywhere, unlike OSM's river/stream split.
# Both 3 and 4 are measured so the sensitivity of every downstream number is visible.
ORDERS = (3, 4)


def arcgis(params: dict, attempts: int = 4) -> dict:
    """The service times out under load on large envelopes. Retry rather than let a
    timeout be recorded as an empty region."""
    last = None
    for attempt in range(1, attempts + 1):
        try:
            resp = requests.get(FLOWLINE, params=params,
                                headers={"User-Agent": UA}, timeout=180)
        except requests.RequestException as exc:
            last = type(exc).__name__
            print(f"    {last} (attempt {attempt}/{attempts})", file=sys.stderr)
            time.sleep(10 * attempt)
            continue
        if resp.status_code != 200:
            last = f"HTTP {resp.status_code}"
            print(f"    {last} (attempt {attempt}/{attempts})", file=sys.stderr)
            time.sleep(10 * attempt)
            continue
        data = resp.json()
        if "error" in data:
            raise RuntimeError(f"ArcGIS error: {data['error']}")
        return data
    raise RuntimeError(f"NHD query failed {attempts}x; last: {last}")


def envelope(region) -> dict:
    return {
        "geometry": f"{region.west},{region.south},{region.east},{region.north}",
        "geometryType": "esriGeometryEnvelope",
        "inSR": 4326,
        "spatialRel": "esriSpatialRelIntersects",
        "f": "json",
    }


def fetch_flowlines(region, order: int, refresh: bool) -> list[dict]:
    """Paginated attribute pull. Geometry is not requested: the topology questions are
    answered by fromnode/tonode, and skipping geometry keeps a nationwide service from
    having to serialise several hundred megabytes for a spike."""
    path = RAW / f"{region.key}-nhd-order{order}.json"
    if cache.exists(path) and not refresh:
        return cache.load(path)

    fields = ("nhdplusid,lengthkm,streamorde,fromnode,tonode,flowdir,"
              "gnis_name,reachcode,ftype")
    rows, offset = [], 0
    while True:
        params = envelope(region) | {
            "where": f"streamorde>={order} AND innetwork=1",
            "outFields": fields,
            "returnGeometry": "false",
            "resultOffset": offset,
            "resultRecordCount": 2000,
        }
        data = arcgis(params)
        batch = [f["attributes"] for f in data.get("features", [])]
        rows.extend(batch)
        print(f"    order>={order}: +{len(batch)} (total {len(rows)})")
        if not data.get("exceededTransferLimit") or not batch:
            break
        offset += len(batch)

    cache.save(path, rows)
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    args = ap.parse_args()

    for region in REGIONS:
        print(f"\n=== {region.name} ({region.area_km2:,.0f} km2) ===")
        for order in ORDERS:
            rows = fetch_flowlines(region, order, args.refresh)
            km = sum(r.get("lengthkm") or 0 for r in rows)
            named = sum(1 for r in rows if r.get("gnis_name"))
            directed = sum(1 for r in rows if r.get("flowdir") == 1)
            print(f"  order>={order}: {len(rows):>6,} flowlines  {km:>9,.0f} km"
                  f"  ({region.per_1000km2(int(km)):>6}/1000km2)"
                  f"  named {named / len(rows):.0%}" if rows else
                  f"  order>={order}: none")
            if rows:
                print(f"            flowdir set on {directed / len(rows):.0%}; "
                      f"{len({r['reachcode'] for r in rows if r.get('reachcode')}):,} "
                      f"distinct reachcodes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
