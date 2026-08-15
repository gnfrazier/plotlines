"""SPIKE-04 step 1 — what does OSM actually carry for paddling in each region?

Two passes per region:

  * a **census**: one Overpass query per region containing ~25 `out count` statements,
    one per tag family the paddling feature would depend on. Counts are cheap, so this
    is the cheapest possible honest answer to "does the data exist at all".
  * a **geometry pull** for the four families the routing analysis needs to inspect
    rather than merely count (network, access points, class ratings, portages/hazards).

The census carries **control probes** for cycling and hiking in the same bboxes. That is
the whole point of the design: "OSM has 41 put-ins in Western North Carolina" means
nothing on its own. "OSM has 41 put-ins where it has 2,700 km of cycleway" is a
comparison against the mode the PRD already calls proven, in the same place, from the
same source. Every count in the results is read against its control.

Responses are cached under `raw/`, keyed by region and probe, so re-running the analysis
never re-hits the Overpass commons (ARCH §14 P7). Delete a cache file to refetch it.

Usage:
    python spikes/SPIKE-04/probe_osm.py              # all regions, cached
    python spikes/SPIKE-04/probe_osm.py --refresh    # ignore cache
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

# The main instance returns 504/429 under load often enough that a single-endpoint script
# reads its own rate-limiting as "no data". Fall through mirrors, and make an exhausted
# list a hard error rather than an empty result — a silent zero here would be read as
# "OSM has no put-ins in this region", which is exactly the wrong conclusion to reach by
# accident in a spike whose whole job is to count them.
#
# (connect, read) per endpoint: the mirrors were unreachable from this network during the
# run, and a long read timeout against a host that never answers turns a retry into a
# five-minute stall. Fail fast on the mirrors, be patient with the one that works — but
# never more patient than QUERY_TIMEOUT_S below, or the client waits on a query the server
# has already given up on.
ENDPOINTS = (
    ("https://overpass-api.de/api/interpreter", (10, 120)),
    ("https://overpass.kumi.systems/api/interpreter", (10, 60)),
    ("https://overpass.private.coffee/api/interpreter", (10, 60)),
)
ATTEMPTS = 5
PACE_S = 20         # gap after a successful query, to stay welcome on a shared server
SLOT_WAIT_S = 30    # wait after a 429 — the client's own slot has to free up first

# The `[timeout:N]` in the query header is the *server-side* budget, and it is the root
# cause of the 429 storm this probe spent an hour fighting. When the gateway returns 504,
# the query keeps running on the Overpass instance until its own budget expires — still
# holding one of the client's two slots. At `timeout:300` a handful of abandoned queries
# starve the script of slots for five minutes, so every retry gets 429 and the retry loop
# feeds the problem it is trying to escape. Every query here completes in well under ten
# seconds when the server is healthy, so a 90 s budget loses nothing and releases an
# abandoned slot six times faster.
QUERY_TIMEOUT_S = 90
HEADER = f"[out:json][timeout:{QUERY_TIMEOUT_S}];"

# ---------------------------------------------------------------------------
# Census probes: (group, label, Overpass selector). {bbox} is substituted.
# ---------------------------------------------------------------------------
CENSUS: tuple[tuple[str, str, str], ...] = (
    # --- the network itself -------------------------------------------------
    ("network", "waterway=river",            'way["waterway"="river"]({bbox})'),
    ("network", "waterway=stream",           'way["waterway"="stream"]({bbox})'),
    ("network", "waterway=canal",            'way["waterway"="canal"]({bbox})'),
    ("network", "waterway=tidal_channel",    'way["waterway"="tidal_channel"]({bbox})'),
    # canoe=* on a waterway is paddling's equivalent of bicycle=* on a highway: the
    # access/legality tag a router must have to know an edge is traversable.
    ("network", "waterway + canoe=*",        'way["waterway"]["canoe"]({bbox})'),
    ("network", "canoe=* (anything)",        'nwr["canoe"]({bbox})'),
    ("network", "route=canoe relations",     'relation["route"="canoe"]({bbox})'),

    # --- access points ------------------------------------------------------
    ("access", "canoe=put_in",               'nwr["canoe"="put_in"]({bbox})'),
    ("access", "waterway=access_point",      'nwr["waterway"="access_point"]({bbox})'),
    ("access", "whitewater=put_in/egress",
     'nwr["whitewater"~"^(put_in|egress|put_in;egress|egress;put_in)$"]({bbox})'),
    # slipways are boat ramps generally (motorboats included) — a superset, counted to
    # show how much of the "access" story is really generic launch infrastructure.
    ("access", "leisure=slipway",            'nwr["leisure"="slipway"]({bbox})'),

    # --- difficulty / class -------------------------------------------------
    ("class", "whitewater:section_grade",    'nwr["whitewater:section_grade"]({bbox})'),
    ("class", "whitewater:rapid_grade",      'nwr["whitewater:rapid_grade"]({bbox})'),
    ("class", "rapids=*",                    'nwr["rapids"]({bbox})'),
    ("class", "whitewater=rapid",            'nwr["whitewater"="rapid"]({bbox})'),

    # --- portages -----------------------------------------------------------
    ("portage", "canoe=portage",             'nwr["canoe"="portage"]({bbox})'),
    ("portage", "whitewater=portage_way",    'nwr["whitewater"="portage_way"]({bbox})'),
    ("portage", "portage=*",                 'nwr["portage"]({bbox})'),

    # --- hazards ------------------------------------------------------------
    # Written as a union of exact-value statements rather than one `~"^(a|b|c)$"` regex.
    # Overpass indexes exact tag values and does not index regex matches, so the regex
    # form makes the server scan every `waterway=*` object in the bbox — which is tens of
    # thousands of streams — and it timed out on all three endpoints. Same result,
    # different cost.
    ("hazard", "waterfall/weir/dam/lock",
     '(nwr["waterway"="waterfall"]({bbox});nwr["waterway"="weir"]({bbox});'
     'nwr["waterway"="dam"]({bbox});nwr["waterway"="lock_gate"]({bbox});)'),
    ("hazard", "waterway=canoe_pass",        'nwr["waterway"="canoe_pass"]({bbox})'),

    # --- gauge --------------------------------------------------------------
    # If OSM carried the gauge station *and* a ref linking it to a reach, gauge data
    # would enter through the same provider as everything else. Worth measuring before
    # assuming a second provider is required.
    ("gauge", "man_made=monitoring_station", 'nwr["man_made"="monitoring_station"]({bbox})'),

    # --- controls: the modes the PRD already calls proven --------------------
    ("control", "highway=cycleway",          'way["highway"="cycleway"]({bbox})'),
    ("control", "highway + bicycle=*",       'way["highway"]["bicycle"]({bbox})'),
    ("control", "route=bicycle relations",   'relation["route"="bicycle"]({bbox})'),
    ("control", "route=hiking relations",    'relation["route"="hiking"]({bbox})'),
    ("control", "highway=path/footway",
     '(way["highway"="path"]({bbox});way["highway"="footway"]({bbox});'
     'way["highway"="bridleway"]({bbox});)'),
)

# ---------------------------------------------------------------------------
# Geometry pulls: things the analysis must inspect, not just count.
# ---------------------------------------------------------------------------
GEOM: dict[str, str] = {
    # waterway=stream is excluded on purpose: a stream is generally too small to paddle,
    # and including it would inflate the network into something that looks routable but
    # is mostly unpaddleable. That exclusion is itself a finding — see RESULTS.md.
    # Exact-value union rather than a regex, for the indexing reason noted above.
    "network": ('(way["waterway"="river"]({bbox});way["waterway"="canal"]({bbox});'
                'way["waterway"="tidal_channel"]({bbox}););out geom;'),
    "access": (
        '('
        'nwr["canoe"="put_in"]({bbox});'
        'nwr["waterway"="access_point"]({bbox});'
        'nwr["whitewater"~"^(put_in|egress|put_in;egress|egress;put_in)$"]({bbox});'
        'nwr["leisure"="slipway"]({bbox});'
        ');out center tags;'
    ),
    "class": (
        '('
        'nwr["whitewater:section_grade"]({bbox});'
        'nwr["whitewater:rapid_grade"]({bbox});'
        'nwr["rapids"]({bbox});'
        'nwr["whitewater"="rapid"]({bbox});'
        ');out center tags;'
    ),
    "portage_hazard": (
        '('
        'nwr["canoe"="portage"]({bbox});'
        'nwr["whitewater"="portage_way"]({bbox});'
        'nwr["portage"]({bbox});'
        'nwr["waterway"="waterfall"]({bbox});'
        'nwr["waterway"="weir"]({bbox});'
        'nwr["waterway"="dam"]({bbox});'
        'nwr["waterway"="lock_gate"]({bbox});'
        'nwr["waterway"="canoe_pass"]({bbox});'
        ');out center tags;'
    ),
}


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
                    # A 200 carrying an HTML error page is Overpass's way of reporting a
                    # runtime error. Treat it as a failure, never as an empty result.
                    last = f"{host}: 200 but non-JSON body"
                    print(f"    {host} -> 200 non-JSON", file=sys.stderr)
                    continue
                # Pace successive queries. The public instance allows two concurrent
                # slots per client and starts answering 429/504 when a script walks
                # straight out of one query into the next; a gap between *successful*
                # calls was the difference between this probe completing and grinding
                # through retries for an hour.
                time.sleep(PACE_S)
                return data
            last = f"{host}: HTTP {resp.status_code}"
            print(f"    {host} -> HTTP {resp.status_code}", file=sys.stderr)
            if resp.status_code == 429:
                # 429 means *this client* has no free slot, so trying the next endpoint
                # immediately is pointless and moving straight to the next attempt just
                # burns one. The instance frees a slot within roughly a query budget;
                # wait for that rather than hammering.
                time.sleep(SLOT_WAIT_S)
        if attempt < ATTEMPTS:
            backoff = 15 * attempt
            print(f"    all endpoints failed (attempt {attempt}/{ATTEMPTS}); "
                  f"waiting {backoff}s", file=sys.stderr)
            time.sleep(backoff)
    raise RuntimeError(f"all Overpass endpoints failed {ATTEMPTS}x; last: {last}")


def tiles(region, n: int = 2) -> list[str]:
    """Split a region bbox into an n x n grid of Overpass bboxes.

    The full-region `out geom` pull for the waterway network returned 504 from every
    endpoint while the *status* endpoint reported free slots — so this is the gateway
    cutting off a long-running response, not rate limiting. Quartering the bbox brings
    each response back inside the limit. Elements are de-duplicated by id on merge, which
    matters because a river way crossing a tile boundary is returned by both tiles."""
    dlat = (region.north - region.south) / n
    dlon = (region.east - region.west) / n
    return [
        f"{region.south + i * dlat},{region.west + j * dlon},"
        f"{region.south + (i + 1) * dlat},{region.west + (j + 1) * dlon}"
        for i in range(n) for j in range(n)
    ]


def fetch_tiled(region, name: str, template: str, n: int = 2) -> dict:
    """Tiles are cached individually, not just the merged result.

    Overpass was throwing intermittent 504s throughout this run, and with only a
    whole-region cache a failure on the last tile discarded three successful pulls and
    made the next attempt re-request all four. Per-tile caching makes a retry cost only
    the tile that actually failed."""
    merged: dict[tuple[str, int], dict] = {}
    grid = tiles(region, n)
    for k, bbox in enumerate(grid, 1):
        tile_path = RAW / "tiles" / f"{region.key}-{name}-{n}x{n}-{k}.json"
        data = cached(tile_path,
                      lambda b=bbox: overpass(HEADER
                                              + template.format(bbox=b)))
        for element in data.get("elements", []):
            merged[(element["type"], element["id"])] = element
        print(f"      tile {k}/{len(grid)}: {len(data.get('elements', [])):,} elements "
              f"({len(merged):,} unique so far)")
    return {"elements": list(merged.values())}


def cached(path: Path, build, refresh: bool = False) -> dict:
    if cache.exists(path) and not refresh:
        return cache.load(path)
    data = build()
    cache.save(path, data)
    return data


def census_groups() -> dict[str, list[tuple[str, str, str]]]:
    """Census probes bucketed by group. One Overpass query per group rather than one
    per region: a 25-statement query is heavy enough to draw a 504 from a loaded
    instance, and a per-probe query would be 75 round trips against a shared commons.
    Seven small queries per region is the middle that actually completes."""
    groups: dict[str, list[tuple[str, str, str]]] = {}
    for probe in CENSUS:
        groups.setdefault(probe[0], []).append(probe)
    return groups


def parse_census(probes: list[tuple[str, str, str]], payload: dict) -> list[dict]:
    counts = [e for e in payload.get("elements", []) if e.get("type") == "count"]
    if len(counts) != len(probes):
        raise RuntimeError(
            f"census returned {len(counts)} counts for {len(probes)} probes — the "
            "probe list and the response are out of step, so every label would be "
            "attached to the wrong number"
        )
    out = []
    for (group, label, sel), element in zip(probes, counts):
        tags = element.get("tags", {})
        out.append({
            "group": group,
            "label": label,
            "selector": sel,
            "total": int(tags.get("total", 0)),
            "nodes": int(tags.get("nodes", 0)),
            "ways": int(tags.get("ways", 0)),
            "relations": int(tags.get("relations", 0)),
        })
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true", help="ignore the raw/ cache")
    ap.add_argument("--regions", nargs="*", help="region keys; default all")
    args = ap.parse_args()

    wanted = [r for r in REGIONS if not args.regions or r.key in args.regions]
    groups = census_groups()
    census: list[dict] = []

    for region in wanted:
        print(f"\n=== {region.name} ({region.key}) "
              f"{region.area_km2:,.0f} km2 ===")

        rows: list[dict] = []
        for group, probes in groups.items():
            query = HEADER + "".join(
                f"{sel.format(bbox=region.bbox)};out count;" for _, _, sel in probes)
            raw = cached(RAW / f"{region.key}-census-{group}.json",
                         lambda q=query: overpass(q), args.refresh)
            rows.extend(parse_census(probes, raw))

        for row in rows:
            row["per_1000km2"] = region.per_1000km2(row["total"])
            print(f"  {row['group']:8} {row['label']:28} {row['total']:>7,}"
                  f"   {row['per_1000km2']:>8}/1000km2")

        census.append({
            "region": region.key,
            "region_name": region.name,
            "area_km2": round(region.area_km2, 1),
            "bbox": region.bbox,
            "probes": rows,
        })

        for name, template in GEOM.items():
            path = RAW / f"{region.key}-{name}.json"
            # Only the network pull carries full geometry and needs tiling; the others
            # are `out center` and return in seconds.
            grid = 2 if name == "network" else 1
            data = cached(path, lambda r=region, nm=name, t=template, g=grid:
                          fetch_tiled(r, nm, t, g), args.refresh)
            print(f"  geom {name:16} {len(data.get('elements', [])):>7,} elements"
                  f"   ({cache.cache_path(path).stat().st_size / 1e6:.1f} MB gz)")

    out = HERE / "results" / "census.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(census, indent=2), encoding="utf-8")
    print(f"\nwrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
