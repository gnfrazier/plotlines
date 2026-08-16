"""SPIKE-19 step 4 — bind live gauges to a real routed segment, end to end.

Steps 1–3 established that the network survives the succession and that a route comes out
of it. This is the part FR14/FR14a actually ships: an Author draws a paddle segment, and
Plotlines shows the river's current level against the band the Author set.

The binding is done **by identifier**, which is the whole point. SPIKE-04 measured what
happens when you guess spatially — snapping gauges to a waterway network attached only
27 of 43, 1 of 9 and 19 of 60 — and the failures are not random. A gauge below a
confluence reads two rivers; a gauge above a dam reads a pool rather than the release.
Those are exactly the places a paddler needs the number to be right.

What this probe emits, and what it deliberately does not: the payload carries the reading,
its units, its age, its approval status, and where it sits relative to **the Author's**
band. It carries no verdict. "Runnable" is a difficulty judgement, which is the capability
ARCH D19 removed after SPIKE-04 found no licensable class-rating source, and no discharge
number supports it. The band belongs to the Author; the app reports and warns.

The reading comes from `api.waterdata.usgs.gov`, not `waterservices.usgs.gov` — SPIKE-04
§5 established the latter is decommissioned in Q1 2027, so nothing built here may depend
on it.

Usage:
    python spikes/SPIKE-19/probe_gauge_bind.py [--refresh]
"""

from __future__ import annotations

import argparse
import datetime as dt
import json

import networkx as nx

from analyze import access_points, build_graph, component_report, load_flowlines, \
    route, snap_access
from common import RAW, RESULTS, WATERDATA, cache, get_json

OGC = f"{WATERDATA}/ogcapi/v0/collections"

# An illustrative Author-set band for the French Broad, in the unit paddlers actually
# quote. FR14 lets the Author choose cfs or stage; this is a stand-in for that input, not
# a Plotlines recommendation about the river — the spike has no basis for one and D19 is
# the reason it must not invent one.
EXAMPLE_BAND = {"parameter_code": "00060", "unit": "ft^3/s", "min": 300, "max": 3000,
                "set_by": "author (illustrative — not a Plotlines recommendation)"}


def latest_reading(site_no: str, parameter_code: str) -> dict | None:
    data = get_json(f"{OGC}/latest-continuous/items",
                    {"monitoring_location_id": f"USGS-{site_no}",
                     "parameter_code": parameter_code, "f": "json", "limit": 5},
                    attempts=3, timeout=60)
    feats = data.get("features") or []
    if not feats:
        return None
    # Prefer the instantaneous statistic where several are published for one parameter.
    feats.sort(key=lambda f: f["properties"].get("time") or "", reverse=True)
    p = feats[0]["properties"]
    return {
        "value": p.get("value"),
        "unit": p.get("unit_of_measure"),
        "time": p.get("time"),
        "approval_status": p.get("approval_status"),
        "statistic_id": p.get("statistic_id"),
    }


def band_state(value: float | None, band: dict) -> str:
    """Where the reading sits relative to the Author's band. Three states, no fourth.

    Not a verdict on the water — a statement about a number and an interval the Author
    typed in. `unknown` is a first-class outcome: FR14a requires the app to say plainly
    when a segment has no gauge, and silence would be indistinguishable from "fine".
    """
    if value is None:
        return "unknown"
    if value < band["min"]:
        return "below_author_band"
    if value > band["max"]:
        return "above_author_band"
    return "within_author_band"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--region", default="wnc")
    args = ap.parse_args()

    rows = load_flowlines(args.region, 4)
    g, _ = build_graph(rows)
    comp = component_report(g)
    largest = comp.pop("_largest")
    snapped = [s for s in snap_access(rows, access_points(args.region))
               if s["snap_m"] <= 200]
    r = route(g, snapped, largest)
    leg = r.get("downstream")
    if not leg:
        print("no downstream route in this region; nothing to bind")
        return 1

    # Recover the segment's flowlines so the mainstems along it can be read off.
    src = next(s for s in snapped
               if s.get("name") == leg["from"]["name"] and s["snap_m"] == leg["from"]["snap_m"])
    dst = next(s for s in snapped
               if s.get("name") == leg["to"]["name"] and s["snap_m"] == leg["to"]["snap_m"])
    und_path = nx.shortest_path(g, src["flowline"], dst["flowline"], weight="km")
    mainstems = {g.nodes[n]["mainstem"] for n in und_path if g.nodes[n].get("mainstem")}
    names = sorted({g.nodes[n]["name"] for n in und_path if g.nodes[n].get("name")})
    print(f"route: {leg['km']} km, {len(und_path)} flowlines, "
          f"{len(mainstems)} distinct mainstems")
    print(f"  named waters on the segment: {', '.join(names)}")

    # Gauges whose NLDI mainstem lands on this segment — an identifier match, no geometry.
    sites = cache.load(RAW / f"{args.region}-nldi-sites.json")
    bound = [s for s in sites if s.get("mainstem") in mainstems]
    print(f"  gauges bound by mainstem identifier: {len(bound)}")

    now = dt.datetime.now(dt.UTC)
    payloads = []
    for s in bound:
        discharge = latest_reading(s["site_no"], "00060")
        stage = latest_reading(s["site_no"], "00065")
        primary = discharge or stage
        age_min = None
        if primary and primary.get("time"):
            t = dt.datetime.fromisoformat(primary["time"])
            age_min = round((now - t).total_seconds() / 60, 1)
        value = None
        if discharge and discharge.get("value") not in (None, ""):
            try:
                value = float(discharge["value"])
            except ValueError:
                value = None
        payloads.append({
            "station_id": s["site_no"],
            "station_name": s["name"],
            "bound_by": "mainstem_uri",
            "mainstem": s["mainstem"],
            "reachcode": s["reachcode"],
            "discharge": discharge,
            "stage": stage,
            # FR66's rule, generalised: a reading is presented with its age, never as
            # timeless. `retrieved_at` and the observation `time` are both kept because
            # the difference between them is the staleness the Author has to judge.
            "retrieved_at": now.isoformat(timespec="seconds"),
            "age_minutes": age_min,
            "author_band": EXAMPLE_BAND,
            "band_state": band_state(value, EXAMPLE_BAND),
        })

    for p in payloads:
        d = p["discharge"]
        print(f"    {p['station_id']}  {p['station_name']}")
        print(f"      discharge {d['value'] if d else '—'} "
              f"{d['unit'] if d else ''}  ({d['approval_status'] if d else 'no series'})"
              f"  age {p['age_minutes']} min  -> {p['band_state']}")

    out = {
        "region": args.region,
        "segment": {"km": leg["km"], "flowlines": len(und_path),
                    "from": leg["from"], "to": leg["to"],
                    "named_waters": names,
                    "distinct_mainstems": len(mainstems)},
        "gauges_bound": len(bound),
        "payloads": payloads,
    }
    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "gauge_binding.json").write_text(json.dumps(out, indent=2),
                                                encoding="utf-8")
    print(f"\nwrote {RESULTS / 'gauge_binding.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
