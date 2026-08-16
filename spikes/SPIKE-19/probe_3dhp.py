"""SPIKE-19 step 1 — the regression check: does 3DHP still carry what SPIKE-04 measured?

SPIKE-04 chose USGS NHDPlus High Resolution over OSM for the paddling network on the
strength of four declared attributes (`spikes/SPIKE-04/results/RESULTS.md` §3.2):

    fromnode / tonode   topology stated, not inferred from shared vertices
    flowdir             which way the water goes
    streamorde          Strahler order, an objective "big enough to float a boat"
    reachcode           the identifier space USGS gauges are indexed in

USGS retired the NHD on 1 October 2023 and stopped maintaining NHDPlus HR. 3DHP is the
replacement, so those four attributes are not guaranteed to exist any more — under those
names or any names. This probe answers that by reading the service's own schema rather
than by trying a query and interpreting the silence, then pulls the geometry SPIKE-04
explicitly skipped (§10: "building the provider will need the geometry pull this spike
skipped").

Two things this probe records that are findings rather than plumbing:

  * **`workunitid`**, which says whether a region's flowlines are new elevation-derived
    hydrography or the converted NHD snapshot. "3DHP" and "still NHD underneath" are very
    different answers to "has the data improved", and the field distinguishes them.
  * **whether the Z ordinate carries anything.** The layer advertises `hasZ: true`, which
    is what makes taking stream slope from flowline geometry look free. Advertised and
    populated are different claims, and only one of them is checkable.

Licensing: USGS, public domain (17 U.S.C. §105). No key, no quota.

Usage:
    python spikes/SPIKE-19/probe_3dhp.py [--refresh]
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
from pathlib import Path

import common
from common import (FLOWLINE_LAYER, RAW, REACHCODE_LAYER, REGIONS, RESULTS, SERVICE,
                    cache, count_layer, get_json, query_layer)

# The four attributes SPIKE-04's verdict rests on, and what a replacement has to provide.
#
# Checking the *names* alone would score all four as lost, which is true and useless: the
# question is whether the capability survived, and three of them survived a rename. So each
# entry carries the candidate successor fields, and the check reports which one it found.
# A field named differently is a migration; a capability that is gone is a regression, and
# a probe that cannot tell them apart would report this dataset as a catastrophe.
SPIKE04_ATTRIBUTES = {
    "fromnode/tonode": {
        "purpose": "declared topology (connectivity stated, not inferred)",
        "candidates": ("fromnode", "tonode", "hydrosequence", "dnhydrosequence"),
    },
    "flowdir": {
        "purpose": "direction of flow",
        "candidates": ("flowdir", "flowdirection"),
    },
    "streamorde": {
        "purpose": "Strahler stream order",
        "candidates": ("streamorde", "streamorder"),
    },
    # Deliberately NOT listing `mainstemid` as a candidate here. It is not a renamed
    # reachcode — a mainstem is a whole river, a reachcode is a segment of one, and they
    # are different identifier spaces with different cardinality. Treating it as a rename
    # would report this attribute as a clean migration when what actually happened is that
    # the reach code left the flowline table (see the MOVED branch below) and a new,
    # coarser key appeared beside it. `probe_join.py` measures which one carries the gauge
    # join; that is a measurement, not something to assume in a field-name check.
    "reachcode": {
        "purpose": "the identifier space USGS gauges are indexed in",
        "candidates": ("reachcode",),
    },
}

FLOWLINE_FIELDS = ("id3dhp,mainstemid,gnisidlabel,featuretypelabel,lengthkm,"
                   "flowdirection,streamorder,hydrosequence,dnhydrosequence,"
                   "uphydrosequence,levelpath,divergence,workunitid,featuredate")

# Same threshold pair as SPIKE-04, for the same reason: order 4 is the working definition
# of "paddleable-scale" and order 3 is measured beside it so the sensitivity of every
# downstream number stays visible. The threshold is a product decision, not a truth.
ORDERS = (3, 4)

# Geometry is fetched only where something consumes it. Order 3 exists in this spike to
# answer "how much does the threshold move the network", and every part of that — length,
# connectivity, topology — comes from attributes. Pulling its geometry as well tripled the
# committed cache to buy a number nothing reads.
GEOMETRY_ORDERS = (4,)


def probe_schema(refresh: bool) -> dict:
    """Read both layers' field lists straight from the service."""
    path = RAW / "schema.json"
    if cache.exists(path) and not refresh:
        return cache.load(path)

    out = {"service": SERVICE, "layers": {}}
    svc = get_json(SERVICE, {"f": "json"})
    out["service_layers"] = [{"id": l["id"], "name": l["name"],
                              "geometryType": l.get("geometryType")}
                             for l in svc.get("layers", [])]
    for layer in (FLOWLINE_LAYER, REACHCODE_LAYER):
        meta = get_json(f"{SERVICE}/{layer}", {"f": "json"})
        out["layers"][str(layer)] = {
            "name": meta.get("name"),
            "geometryType": meta.get("geometryType"),
            "hasZ": meta.get("hasZ"),
            "maxRecordCount": meta.get("maxRecordCount"),
            "fields": [{"name": f["name"],
                        "type": f["type"].replace("esriFieldType", "")}
                       for f in meta.get("fields", [])],
        }
    cache.save(path, out)
    return out


def fetch_flowlines(region, order: int, refresh: bool) -> list[dict]:
    path = RAW / f"{region.key}-3dhp-order{order}.json"
    if cache.exists(path) and not refresh:
        return cache.load(path)
    want_geom = order in GEOMETRY_ORDERS
    print(f"  order>={order} {'geometry' if want_geom else 'attributes'}")
    rows = query_layer(region, FLOWLINE_LAYER, f"streamorder>={order}",
                       FLOWLINE_FIELDS, geometry=want_geom)
    cache.save(path, rows)
    return rows


def fetch_reachcodes(region, refresh: bool) -> list[dict]:
    """Reach codes are not a flowline attribute in 3DHP — they are point features on
    layer 40. Pulled with geometry because attaching one to an edge is now a spatial
    operation, which is itself the finding."""
    path = RAW / f"{region.key}-3dhp-reachcodes.json"
    if cache.exists(path) and not refresh:
        return cache.load(path)
    print("  reachcode hydrolocations")
    rows = query_layer(region, REACHCODE_LAYER, "1=1",
                       "id3dhp,mainstemid,universalreferenceid,featuretypelabel,"
                       "gnisidlabel", geometry=True)
    cache.save(path, rows)
    return rows


def _z_audit(region, refresh: bool) -> dict:
    """Does the advertised Z ordinate carry anything?

    Fetched separately, with returnZ=true, because the main geometry pull deliberately
    drops the third ordinate. If Z is populated this audit is what says so; if it is not,
    this is the evidence that the elevation question answers itself.
    """
    path = RAW / f"{region.key}-3dhp-zaudit.json"
    if cache.exists(path) and not refresh:
        return cache.load(path)
    params = common.envelope(region) | {
        "where": "streamorder>=4", "outFields": "id3dhp", "returnGeometry": "true",
        "returnZ": "true", "outSR": 4326, "resultRecordCount": 500,
    }
    data = get_json(f"{SERVICE}/{FLOWLINE_LAYER}/query", params)
    zs = [p[2] for f in data.get("features", [])
          for path_ in f.get("geometry", {}).get("paths", [])
          for p in path_ if len(p) > 2]
    out = {
        "features_sampled": len(data.get("features", [])),
        "vertices_sampled": len(zs),
        "z_nonzero": sum(1 for z in zs if z not in (0, 0.0, None)),
        "z_min": min(zs) if zs else None,
        "z_max": max(zs) if zs else None,
    }
    cache.save(path, out)
    return out


def summarise(region, rows: list[dict], order: int) -> dict:
    n = len(rows)
    if not n:
        return {"flowlines": 0}
    km = sum(r.get("lengthkm") or 0 for r in rows)
    dates = [dt.datetime.fromtimestamp(r["featuredate"] / 1000, dt.UTC).date().isoformat()
             for r in rows if r.get("featuredate")]
    return {
        "flowlines": n,
        "km": round(km, 1),
        "km_per_1000km2": region.per_1000km2(int(km)),
        "flowdirection_set_pct": round(
            100 * sum(1 for r in rows if r.get("flowdirection")) / n, 1),
        "dnhydrosequence_set_pct": round(
            100 * sum(1 for r in rows if r.get("dnhydrosequence")) / n, 1),
        "mainstemid_set_pct": round(
            100 * sum(1 for r in rows if r.get("mainstemid")) / n, 1),
        "named_pct": round(100 * sum(1 for r in rows if r.get("gnisidlabel")) / n, 1),
        "distinct_mainstems": len({r["mainstemid"] for r in rows if r.get("mainstemid")}),
        "mainstem_namespaces": dict(collections.Counter(
            r["mainstemid"].rsplit("/mainstems/", 1)[0].rsplit("/", 1)[-1]
            for r in rows if r.get("mainstemid"))),
        "featuretypes": dict(collections.Counter(
            r.get("featuretypelabel") for r in rows).most_common()),
        "workunitid": dict(collections.Counter(r.get("workunitid") for r in rows)),
        "featuredate_range": [min(dates), max(dates)] if dates else None,
        "vertices": (sum(len(p) for r in rows for p in r.get("_paths", []))
                     if order in GEOMETRY_ORDERS else None),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    args = ap.parse_args()

    schema = probe_schema(args.refresh)
    fl = schema["layers"][str(FLOWLINE_LAYER)]
    rc_names = {f["name"].lower()
                for f in schema["layers"][str(REACHCODE_LAYER)]["fields"]}
    names = {f["name"].lower() for f in fl["fields"]}
    print(f"\n=== schema: layer {FLOWLINE_LAYER} '{fl['name']}' "
          f"({len(fl['fields'])} fields, hasZ={fl['hasZ']}) ===")
    regression = {}
    for old, spec in SPIKE04_ATTRIBUTES.items():
        same = [n for n in old.split("/") if n in names]
        found = [n for n in spec["candidates"] if n in names]
        if same:
            verdict, how = "KEPT", "+".join(same)
        elif found:
            verdict, how = "RENAMED", "+".join(found)
        elif old == "reachcode" and "universalreferenceid" in rc_names:
            verdict, how = "MOVED", f"layer {REACHCODE_LAYER}.universalreferenceid"
        else:
            verdict, how = "LOST", "-"
        regression[old] = {"verdict": verdict, "carried_by": how,
                           "purpose": spec["purpose"]}
        print(f"  {old:<16} {verdict:<8} as {how:<42} {spec['purpose']}")

    out = {"schema": schema, "attribute_regression": regression, "regions": {}}
    for region in REGIONS:
        print(f"\n=== {region.name} ({region.area_km2:,.0f} km2) ===")
        entry = {"area_km2": round(region.area_km2, 1), "orders": {}}
        entry["total_flowlines_any_order"] = count_layer(region, FLOWLINE_LAYER, "1=1")
        for order in ORDERS:
            rows = fetch_flowlines(region, order, args.refresh)
            s = summarise(region, rows, order)
            entry["orders"][str(order)] = s
            print(f"  order>={order}: {s['flowlines']:>7,} flowlines "
                  f"{s['km']:>9,.0f} km  flowdir {s['flowdirection_set_pct']}%  "
                  f"dnhydroseq {s['dnhydrosequence_set_pct']}%  "
                  f"mainstem {s['mainstemid_set_pct']}%")
            print(f"           workunit {s['workunitid']}  "
                  f"namespaces {s['mainstem_namespaces']}")
        rc = fetch_reachcodes(region, args.refresh)
        entry["reachcode_points"] = {
            "count": len(rc),
            "with_universalreferenceid": sum(
                1 for r in rc if r.get("universalreferenceid")),
            "distinct_reachcodes": len({r["universalreferenceid"] for r in rc
                                        if r.get("universalreferenceid")}),
            "featuretypes": dict(collections.Counter(
                r.get("featuretypelabel") for r in rc).most_common()),
        }
        print(f"  reachcode points: {len(rc):,} "
              f"({entry['reachcode_points']['distinct_reachcodes']:,} distinct codes)")
        entry["z_audit"] = _z_audit(region, args.refresh)
        za = entry["z_audit"]
        print(f"  Z audit: {za['z_nonzero']:,}/{za['vertices_sampled']:,} vertices "
              f"non-zero (range {za['z_min']}..{za['z_max']})")
        out["regions"][region.key] = entry

    RESULTS.mkdir(parents=True, exist_ok=True)
    Path(RESULTS / "schema_and_network.json").write_text(
        __import__("json").dumps(out, indent=2), encoding="utf-8")
    print(f"\nwrote {RESULTS / 'schema_and_network.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
