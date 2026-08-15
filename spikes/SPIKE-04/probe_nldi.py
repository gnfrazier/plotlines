"""SPIKE-04 step 5 — can a gauge be tied to a river reach?

This is the question that decides whether FR14's gauge band is buildable, and it is the
one the spike brief does not ask. A gauge reading on its own is a number attached to a
point. FR14 needs it attached to *a stretch of river a Character will paddle*: "the
Nantahala is runnable above 500 cfs" is a claim about a reach, not about a coordinate.

Spatially guessing the association — nearest gauge to the segment — is wrong in the two
cases that matter most: a gauge just below a confluence reads both rivers, and a gauge
above a dam reads a pool rather than the release. So the question is whether the
association can be *looked up*.

USGS NLDI answers it. Every NWIS site resolves to an NHD `comid` and `reachcode`, and the
navigation endpoints walk the hydrographic network upstream or downstream from that
point. That turns "which reach does this gauge govern" into a traversal rather than a
heuristic — and it is the same `reachcode` space `probe_nhd.py` pulls the network in, so
the two sources join without a spatial match at all.

Licensing: USGS, public domain, no key.

Usage:
    python spikes/SPIKE-04/probe_nldi.py [--refresh] [--sample 25]
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
RESULTS = HERE / "results"

UA = "plotlines-spike04/0.1 (research spike; gnfrazier@gmail.com)"
NLDI = "https://api.water.usgs.gov/nldi/linked-data/nwissite/USGS-{site}"

# How far downstream to walk from a gauge when asking "what reach does this govern".
# 40 km is roughly a long day on moving water — the scale FR14's band is set at.
DOWNSTREAM_KM = 40


def get(url: str, params: dict | None = None) -> requests.Response:
    return requests.get(url, params=params or {},
                        headers={"User-Agent": UA}, timeout=90)


def resolve(site: str) -> dict | None:
    resp = get(NLDI.format(site=site))
    if resp.status_code != 200:
        return None
    features = resp.json().get("features") or []
    if not features:
        return None
    props = features[0]["properties"]
    return {
        "site_no": site,
        "name": props.get("name"),
        "comid": props.get("comid"),
        "reachcode": props.get("reachcode"),
        "measure": props.get("measure"),
        "mainstem": props.get("mainstem"),
    }


def downstream(site: str) -> dict | None:
    resp = get(NLDI.format(site=site) + "/navigation/DM/flowlines",
               {"distance": str(DOWNSTREAM_KM)})
    if resp.status_code != 200:
        return None
    features = resp.json().get("features") or []
    return {
        "flowlines": len(features),
        "comids": len({f["properties"].get("nhdplus_comid") for f in features}),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--sample", type=int, default=25,
                    help="gauges per region to resolve; the point is the success rate, "
                         "not an exhaustive index")
    args = ap.parse_args()

    gauges_path = RESULTS / "gauges.json"
    if not gauges_path.exists():
        raise SystemExit("run probe_gauges.py first")
    by_region = {e["region"]: e for e in json.loads(gauges_path.read_text(encoding="utf-8"))}

    out = []
    for region in REGIONS:
        entry = by_region.get(region.key)
        if not entry:
            continue
        path = RAW / f"{region.key}-nldi.json"
        if cache.exists(path) and not args.refresh:
            record = cache.load(path)
        else:
            sample = [g["site_no"] for g in entry["gauges"]][:args.sample]
            resolved = [r for r in (resolve(s) for s in sample) if r]
            with_reach = [r for r in resolved if r.get("reachcode")]
            # Walk downstream from the first gauge that resolved, as an existence proof
            # that the association is traversable and not merely an identifier.
            nav = downstream(with_reach[0]["site_no"]) if with_reach else None
            record = {
                "region": region.key,
                "sampled": len(sample),
                "resolved": len(resolved),
                "with_reachcode": len(with_reach),
                "with_mainstem": sum(1 for r in resolved if r.get("mainstem")),
                "downstream_example": (
                    {"site_no": with_reach[0]["site_no"],
                     "name": with_reach[0]["name"],
                     "reachcode": with_reach[0]["reachcode"],
                     "distance_km": DOWNSTREAM_KM, **nav}
                    if nav else None),
                "gauges": resolved,
            }
            cache.save(path, record)

        print(f"\n=== {region.name} ===")
        print(f"  {record['with_reachcode']}/{record['sampled']} sampled gauges "
              f"resolved to an NHD reachcode")
        example = record.get("downstream_example")
        if example:
            print(f"  downstream {example['distance_km']} km from "
                  f"{example['name']}: {example['flowlines']} flowlines, "
                  f"{example['comids']} distinct reaches")
        out.append({k: v for k, v in record.items() if k != "gauges"})

    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "nldi.json").write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(f"\nwrote {RESULTS / 'nldi.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
