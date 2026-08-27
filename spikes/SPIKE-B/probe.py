"""SPIKE-B step 1 — pull the six OSM layer families for the Blue Ridge corridor.

One `out center tags` pull per top-level key in the FR97 catalog (`historic`,
`tourism`, `amenity`, `natural`, `leisure`, `man_made`) over `regions.BRP`,
plus a `leisure` geometry pull for FR98(b)'s `leisure=park` area gate. Cached
gzipped under `raw/`, committed, so `analyze.py` / `ranking.py` reproduce every
number offline (ARCH §14 P7). Delete a file to refetch.

Overpass fallback + pacing copied from SPIKE-A's probe.

Usage:
    python spikes/SPIKE-B/probe.py            # cached
    python spikes/SPIKE-B/probe.py --refresh  # ignore cache
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).parent))
import cache  # noqa: E402
from regions import BRP  # noqa: E402

HERE = Path(__file__).parent
RAW = HERE / "raw"

UA = "plotlines-spikeB/0.1 (co-location cost + ranking spike; gnfrazier@gmail.com)"

ENDPOINTS = (
    ("https://overpass-api.de/api/interpreter", (10, 240)),
    ("https://overpass.kumi.systems/api/interpreter", (10, 120)),
    ("https://overpass.private.coffee/api/interpreter", (10, 120)),
)
ATTEMPTS = 5
PACE_S = 12
SLOT_WAIT_S = 30
QUERY_TIMEOUT_S = 300
HEADER = f"[out:json][timeout:{QUERY_TIMEOUT_S}]"

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
    data = build()
    cache.save(path, data)
    return data


def _elements(payload: dict) -> list[dict]:
    return [e for e in payload.get("elements", []) if e.get("type") in ("node", "way", "relation")]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    args = ap.parse_args()

    ew, ns = BRP.span_km
    print(f"=== {BRP.name} ===")
    print(f"    {ew:.0f} x {ns:.0f} km, {BRP.area_km2:,.0f} km2\n")

    for key in KEYS:
        q = f'{HEADER};nwr["{key}"]({BRP.bbox});out center tags;'
        data = cached(RAW / f"{BRP.key}-{key}.json", lambda q=q: overpass(q), args.refresh)
        n = len(_elements(data))
        size = cache.cache_path(RAW / f"{BRP.key}-{key}.json").stat().st_size
        print(f"  {key:10} {n:>7,} features   ({size/1024:,.0f} KB gz)")

    q = f'{HEADER};way["leisure"]({BRP.bbox});out geom;'
    data = cached(RAW / f"{BRP.key}-leisure-geom.json", lambda q=q: overpass(q), args.refresh)
    print(f"  {'leisure/geom':10} {len(_elements(data)):>7,} ways")

    print("\nprobe complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
