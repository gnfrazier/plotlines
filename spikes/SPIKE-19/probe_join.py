"""SPIKE-19 step 2 — the identifier join: can a live gauge still be bound to a reach?

This is the question the spike exists to answer second and worries about most. SPIKE-04's
strongest result was that gauge-to-reach association is a **lookup, not a spatial guess**:
58 of 59 sampled NWIS sites resolved to an NHD reach through NLDI, and because NHDPlus HR
carried `reachcode` on every flowline, the gauge layer joined the network layer without a
spatial match at all. That matters precisely where a spatial guess is worst — a gauge
below a confluence reads two rivers, a gauge above a dam reads a pool rather than a
release.

3DHP flowlines do not carry `reachcode`. They carry `mainstemid`, a geoconnex.us URI, and
reach codes have moved to a separate point layer. NLDI returns *both* a `reachcode` and a
`mainstem` URI for a site, so on paper either could carry the join. This probe measures
which one actually does, across every real-time gauge SPIKE-04 found in each region —
not a sample, because a join that works for 80% of gauges is a different product than one
that works for all of them, and the difference only shows up in the tail.

The specific trap being measured: 3DHP's `mainstemid` values appear in **two namespaces**,
`geoconnex.us/usgs/mainstems/N` and `geoconnex.us/ref/mainstems/N`. NLDI answers with one
of them. If the namespaces are disjoint identifier spaces rather than aliases, a naive
string match silently loses every flowline on the other side of the split — and it would
look like sparse gauge coverage rather than a broken join.

Usage:
    python spikes/SPIKE-19/probe_join.py [--refresh]
"""

from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path

from common import NLDI, RAW, REGIONS, RESULTS, cache, get_json

SPIKE04_RAW = Path(__file__).parent.parent / "SPIKE-04" / "raw"


def spike04_sites(region) -> list[dict]:
    """Every real-time site SPIKE-04 found in this region, both parameter codes.

    Reusing that list rather than re-querying keeps the denominator identical to the one
    RESULTS.md will be compared against. A gauge that has since gone offline should still
    be counted as a gauge this join has to serve.
    """
    seen: dict[str, dict] = {}
    for pcode in ("00060", "00065"):
        path = SPIKE04_RAW / f"{region.key}-usgs-sites-{pcode}.json"
        if not cache.exists(path):
            continue
        for site in cache.load(path):
            seen.setdefault(site["site_no"], site)
    return list(seen.values())


def nldi_site(site_no: str) -> dict | None:
    """Resolve one NWIS site through NLDI to its network identifiers."""
    try:
        data = get_json(f"{NLDI}/nwissite/USGS-{site_no}", attempts=2, timeout=60)
    except RuntimeError:
        return None
    feats = data.get("features") or []
    if not feats:
        return None
    p = feats[0].get("properties", {})
    return {
        "site_no": site_no,
        "name": p.get("name"),
        "comid": p.get("comid"),
        "reachcode": p.get("reachcode"),
        "measure": p.get("measure"),
        "mainstem": p.get("mainstem"),
    }


def resolve_region(region, refresh: bool) -> list[dict]:
    path = RAW / f"{region.key}-nldi-sites.json"
    if cache.exists(path) and not refresh:
        return cache.load(path)
    sites = spike04_sites(region)
    print(f"  resolving {len(sites)} sites through NLDI")
    out = []
    for i, s in enumerate(sites, 1):
        r = nldi_site(s["site_no"])
        out.append(r or {"site_no": s["site_no"], "name": s.get("station_nm"),
                         "comid": None, "reachcode": None, "mainstem": None})
        if i % 20 == 0:
            print(f"    {i}/{len(sites)}")
    cache.save(path, out)
    return out


def load_network(region_key: str, order: int = 4) -> list[dict]:
    return cache.load(RAW / f"{region_key}-3dhp-order{order}.json")


def load_reachcodes(region_key: str) -> list[dict]:
    return cache.load(RAW / f"{region_key}-3dhp-reachcodes.json")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true")
    args = ap.parse_args()

    report = {"regions": {}, "namespace_note": None}
    ns_overlap = collections.Counter()

    for region in REGIONS:
        print(f"\n=== {region.name} ===")
        sites = resolve_region(region, args.refresh)
        net3 = load_network(region.key, 3)
        net4 = load_network(region.key, 4)
        rcs = load_reachcodes(region.key)

        ms4 = {r["mainstemid"] for r in net4 if r.get("mainstemid")}
        ms3 = {r["mainstemid"] for r in net3 if r.get("mainstemid")}
        rc_codes = {r["universalreferenceid"] for r in rcs
                    if r.get("universalreferenceid")}
        # Reach codes are 14 digits; NHD's flowline-level code is the first 14 too, so an
        # exact set membership test is the right comparison, not a prefix match.

        resolved = [s for s in sites if s.get("comid")]
        with_ms = [s for s in resolved if s.get("mainstem")]
        with_rc = [s for s in resolved if s.get("reachcode")]

        ms_hit4 = [s for s in with_ms if s["mainstem"] in ms4]
        ms_hit3 = [s for s in with_ms if s["mainstem"] in ms3]
        rc_hit = [s for s in with_rc if s["reachcode"] in rc_codes]

        # Namespace accounting: which side of the usgs//ref split each source sits on.
        def ns(u: str | None) -> str:
            return u.rsplit("/mainstems/", 1)[0].rsplit("/", 1)[-1] if u else "none"

        site_ns = collections.Counter(ns(s.get("mainstem")) for s in resolved)
        net_ns = collections.Counter(ns(m) for m in ms4)
        ns_overlap.update(site_ns)

        entry = {
            "sites_total": len(sites),
            "nldi_resolved": len(resolved),
            "nldi_with_mainstem": len(with_ms),
            "nldi_with_reachcode": len(with_rc),
            "mainstem_matches_order4": len(ms_hit4),
            "mainstem_matches_order3": len(ms_hit3),
            "reachcode_matches_layer40": len(rc_hit),
            "site_mainstem_namespaces": dict(site_ns),
            "network_mainstem_namespaces": dict(net_ns),
            "network_distinct_mainstems_order4": len(ms4),
            "reachcode_points_distinct": len(rc_codes),
        }
        report["regions"][region.key] = entry
        print(f"  sites {entry['sites_total']}  NLDI resolved {entry['nldi_resolved']}"
              f"  with mainstem {entry['nldi_with_mainstem']}"
              f"  with reachcode {entry['nldi_with_reachcode']}")
        print(f"  mainstem URI hits 3DHP order>=4: {len(ms_hit4)}"
              f"  (order>=3: {len(ms_hit3)})")
        print(f"  reachcode hits layer-40 points : {len(rc_hit)}")
        print(f"  site namespaces {dict(site_ns)} | network namespaces {dict(net_ns)}")

    # Are the two namespaces disjoint identifier spaces or aliases? Compare the numeric
    # tails: if the same integer appears under both prefixes for the same river, they are
    # aliases and a normalising join is safe. If not, they are separate registries and a
    # string match is the only honest join.
    wnc4 = load_network("wnc", 4)
    tails = collections.defaultdict(set)
    for r in wnc4:
        u = r.get("mainstemid")
        if u:
            pre, _, num = u.rpartition("/mainstems/")
            tails[num].add(pre.rsplit("/", 1)[-1])
    shared = [n for n, p in tails.items() if len(p) > 1]
    report["namespace_note"] = {
        "distinct_numeric_ids_wnc_order4": len(tails),
        "ids_appearing_under_both_prefixes": len(shared),
    }
    print(f"\nnamespace check (WNC order>=4): {len(tails):,} distinct numeric ids, "
          f"{len(shared)} appear under both prefixes")

    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "join.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"wrote {RESULTS / 'join.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
