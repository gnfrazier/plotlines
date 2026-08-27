"""SPIKE-A step 1 - pull the six OSM layer families for each trip bbox.

One `out center tags` pull per (region, top-level key) in the FR97 catalog:
`historic`, `tourism`, `amenity`, `natural`, `leisure`, `man_made`. `leisure` is
additionally pulled with `out geom` so `analyze.py` can compute polygon areas for
FR98(b)'s `leisure=park` area gate.

Everything is cached under `raw/` (gzipped, committed). Delete a file to refetch.

Usage:
    python spikes/SPIKE-A/probe.py            # all regions, cached
    python spikes/SPIKE-A/probe.py --refresh  # ignore cache
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).parent))
import cache  # noqa: E402
from regions import REGIONS  # noqa: E402

HERE = Path(__file__).parent
RAW = HERE / "raw"

UA = "plotlines-spikeA/0.1 (notability calibration spike; gnfrazier@gmail.com)"

ENDPOINTS = (
    ("https://overpass-api.de/api/interpreter", (10, 180)),
    ("https://overpass.kumi.systems/api/interpreter", (10, 90)),
    ("https://overpass.private.coffee/api/interpreter", (10, 90)),
)
ATTEMPTS = 5
PACE_S = 12
SLOT_WAIT_S = 30
QUERY_TIMEOUT_S = 180
HEADER = f"[out:json][timeout:{QUERY_TIMEOUT_S}]"

# FR97's six layer families, keyed by the top-level OSM key the taxonomy matches on.
KEYS = ("historic", "tourism", "amenity", "natural", "leisure", "man_made")


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
                print(f"    {host} -> {type(exc).__name__}", file=sys.stderr)
                continue
            if resp.status_code == 200:
                try:
                    data = resp.json()
                except ValueError:
                    last = f"{host}: 200 non-JSON (Overpass runtime error)"
                    print(f"    {host} -> 200 non-JSON", file=sys.stderr)
                    continue
                time.sleep(PACE_S)
                return data
            last = f"{host}: HTTP {resp.status_code}"
            print(f"    {host} -> HTTP {resp.status_code}", file=sys.stderr)
            if resp.status_code == 429:
                time.sleep(SLOT_WAIT_S)
        if attempt < ATTEMPTS:
            backoff = 15 * attempt
            print(f"    all endpoints failed ({attempt}/{ATTEMPTS}); waiting {backoff}s",
                  file=sys.stderr)
            time.sleep(backoff)
    raise RuntimeError(f"all Overpass endpoints failed {ATTEMPTS}x; last: {last}")


def cached(path: Path, build, refresh: bool = False) -> dict:
    if cache.exists(path) and not refresh:
        return cache.load(path)
    return _save_through(path, build())


def _save_through(path: Path, data: dict) -> dict:
    cache.save(path, data)
    return data


def _elements(payload: dict) -> list[dict]:
    return [e for e in payload.get("elements", []) if e.get("type") in ("node", "way", "relation")]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--regions", nargs="*")
    args = ap.parse_args()

    wanted = [r for r in REGIONS if not args.regions or r.key in args.regions]

    for region in wanted:
        print(f"\n=== {region.name} ({region.key}) {region.area_km2:,.0f} km2 ===")
        for key in KEYS:
            q = f"{HEADER};nwr[\"{key}\"]({region.bbox});out center tags;"
            data = cached(RAW / f"{region.key}-{key}.json", lambda q=q: overpass(q), args.refresh)
            print(f"  {key:10} {len(_elements(data)):>6,} features")
        # leisure again, with geometry, for the park area gate.
        q = f"{HEADER};way[\"leisure\"]({region.bbox});out geom;"
        data = cached(RAW / f"{region.key}-leisure-geom.json", lambda q=q: overpass(q), args.refresh)
        print(f"  {'leisure/geom':10} {len(_elements(data)):>6,} ways")

    print("\nprobe complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
