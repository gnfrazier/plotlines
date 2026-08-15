"""SPIKE-04 step 2 — is there real-time gauge data, and does it answer FR14?

FR14 lets an Author set a min/max **river gauge height** on a paddling segment. That
requires four separate things to be true, and the spike question only names the first:

  1. gauges exist in the region;
  2. they report *now*, not just historically, because a gauge band is a go/no-go check
     a Character makes on the morning of the trip;
  3. they report the *quantity the Author set the band in* — and paddlers overwhelmingly
     talk in cubic feet per second, not stage height, so a "gauge height" field that most
     gauges do not publish is a field most trips cannot use;
  4. a gauge can be **attached to a specific reach**. A gauge reading is meaningless
     without knowing which stretch of river it governs, and that association is not in
     the gauge feed. Step 4 is measured in `analyze.py`, not here.

This probe answers 1–3 and hands step 4 the gauge coordinates.

USGS Water Services is public-domain US Government data with no key and no quota
negotiation, which is the best licensing position of any source in this spike.

Usage:
    python spikes/SPIKE-04/probe_gauges.py [--refresh]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).parent))
import cache  # noqa: E402
from regions import REGIONS  # noqa: E402

HERE = Path(__file__).parent
RAW = HERE / "raw"

UA = "plotlines-spike04/0.1 (research spike; gnfrazier@gmail.com)"
SITE_URL = "https://waterservices.usgs.gov/nwis/site/"
IV_URL = "https://waterservices.usgs.gov/nwis/iv/"

# WaterServices — the API the two URLs above belong to — is being decommissioned in Q1
# 2027, with intentional degradation possible from the second half of 2026 onward. A
# spike that green-lit paddling on the strength of an endpoint with a published end date
# would be handing the build a migration it didn't know about, so the successor is
# probed alongside it and the results record both. The successor is OGC API - Features
# and needs no key.
OGC_URL = "https://api.waterdata.usgs.gov/ogcapi/v0/collections"

# 00060 = discharge (cubic feet per second) — what paddlers and river guides quote.
# 00065 = gauge height (feet)               — what FR14's wording asks the Author for.
PARAMS = {"00060": "discharge_cfs", "00065": "gauge_height_ft"}


def get(url: str, params: dict) -> requests.Response:
    resp = requests.get(url, params=params, headers={"User-Agent": UA}, timeout=120)
    # The site service answers 404 for "no sites matched", which is a legitimate empty
    # result rather than an error. Anything else is a real failure and must not be
    # silently folded into a zero.
    if resp.status_code not in (200, 404):
        raise RuntimeError(f"{url} -> HTTP {resp.status_code}: {resp.text[:200]}")
    return resp


def parse_rdb(text: str) -> list[dict]:
    """USGS RDB: '#' comments, a header row, a column-width row, then tab-separated data.
    The width row looks exactly like data to a naive tab-split, so it must be dropped by
    position — silently keeping it adds one phantom gauge to every count."""
    lines = [ln for ln in text.splitlines() if ln and not ln.startswith("#")]
    if len(lines) < 2:
        return []
    header = lines[0].split("\t")
    return [dict(zip(header, ln.split("\t"))) for ln in lines[2:]]


def sites(region, param: str, refresh: bool) -> list[dict]:
    path = RAW / f"{region.key}-usgs-sites-{param}.json"
    if cache.exists(path) and not refresh:
        return cache.load(path)
    resp = get(SITE_URL, {
        "format": "rdb",
        "bBox": region.bbox_lonlat,
        "siteType": "ST",             # stream, not well/spring/lake
        "hasDataTypeCd": "iv",        # has instantaneous (real-time) values
        "parameterCd": param,
        "siteStatus": "active",
    })
    rows = parse_rdb(resp.text) if resp.status_code == 200 else []
    cache.save(path, rows)
    return rows


def liveness(region, site_nos: list[str], refresh: bool) -> dict:
    """Existence in the site catalogue is not the same as reporting today. Pull current
    values for a sample and report how many actually came back with a reading."""
    path = RAW / f"{region.key}-usgs-iv.json"
    if cache.exists(path) and not refresh:
        return cache.load(path)
    sample = site_nos[:100]           # the IV service caps the site list
    if not sample:
        data = {"elements": []}
    else:
        resp = get(IV_URL, {
            "format": "json",
            "sites": ",".join(sample),
            "parameterCd": ",".join(PARAMS),
            "siteStatus": "active",
        })
        data = resp.json() if resp.status_code == 200 else {"value": {"timeSeries": []}}
    cache.save(path, data)
    return data


def successor(region, refresh: bool) -> dict:
    """Same two questions against the replacement API: how many stream monitoring
    locations does it know in this bbox, and how many are publishing a current discharge.

    The recency filter is not decoration. `latest-continuous` returns the last value a
    time series ever produced, including series that stopped in 2004 — so counting rows
    would report long-dead gauges as live coverage."""
    path = RAW / f"{region.key}-usgs-ogc.json"
    if cache.exists(path) and not refresh:
        return cache.load(path)

    loc = get(OGC_URL + "/monitoring-locations/items",
              {"bbox": region.bbox_lonlat, "site_type_code": "ST",
               "limit": 5000, "f": "json"})
    latest = get(OGC_URL + "/latest-continuous/items",
                 {"bbox": region.bbox_lonlat, "parameter_code": "00060",
                  "limit": 5000, "f": "json"})
    loc_features = loc.json().get("features", []) if loc.status_code == 200 else []
    val_features = latest.json().get("features", []) if latest.status_code == 200 else []

    cutoff = "2026-01-01"
    fresh = [f for f in val_features
             if (f["properties"].get("time") or "") >= cutoff]
    data = {
        "monitoring_locations": len(loc_features),
        "latest_continuous_series": len(val_features),
        "reported_since_" + cutoff: len(fresh),
    }
    cache.save(path, data)
    return data


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    args = ap.parse_args()

    summary = []
    for region in REGIONS:
        print(f"\n=== {region.name} ({region.area_km2:,.0f} km2) ===")
        by_param = {}
        for param, name in PARAMS.items():
            rows = sites(region, param, args.refresh)
            by_param[name] = rows
            print(f"  {name:16} {len(rows):>4} active real-time sites"
                  f"   {region.per_1000km2(len(rows)):>6}/1000km2")

        # Union of site numbers across both parameters, for the liveness check.
        all_sites = {r["site_no"]: r for rows in by_param.values() for r in rows}
        iv = liveness(region, sorted(all_sites), args.refresh)
        series = iv.get("value", {}).get("timeSeries", [])
        reporting, values_seen = set(), 0
        for ts in series:
            site_no = ts["sourceInfo"]["siteCode"][0]["value"]
            for v in ts.get("values", []):
                for point in v.get("value", []):
                    # -999999 is USGS's in-band "no value" sentinel; counting it as a
                    # reading would report a dead gauge as live.
                    if point.get("value") not in (None, "", "-999999"):
                        reporting.add(site_no)
                        values_seen += 1
        print(f"  live now:        {len(reporting)}/{min(len(all_sites), 100)} sampled "
              f"sites returned a current reading ({values_seen} values)")

        ogc = successor(region, args.refresh)
        print(f"  successor API:   {ogc['monitoring_locations']} stream monitoring "
              f"locations; {ogc['latest_continuous_series']} discharge series, "
              f"{ogc['reported_since_2026-01-01']} of them reporting since 2026-01-01")

        summary.append({
            "region": region.key,
            "region_name": region.name,
            "area_km2": round(region.area_km2, 1),
            "sites": {name: len(rows) for name, rows in by_param.items()},
            "sites_per_1000km2": {name: region.per_1000km2(len(rows))
                                  for name, rows in by_param.items()},
            "sites_union": len(all_sites),
            "sampled": min(len(all_sites), 100),
            "reporting_now": len(reporting),
            "successor_api": ogc,
            # Coordinates go to analyze.py, which measures whether a gauge can be
            # attached to a paddleable reach at all.
            "gauges": [
                {"site_no": s["site_no"], "name": s["station_nm"],
                 "lat": float(s["dec_lat_va"]), "lon": float(s["dec_long_va"]),
                 "huc": s.get("huc_cd", "")}
                for s in all_sites.values()
                if s.get("dec_lat_va") and s.get("dec_long_va")
            ],
        })

    out = HERE / "results" / "gauges.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(f"\nwrote {out.relative_to(HERE.parent.parent)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
