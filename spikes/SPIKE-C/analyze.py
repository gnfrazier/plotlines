"""SPIKE-C step 4 — turn the pulls into the per-schema, per-region coverage table.

Everything here runs offline against the committed records in `raw/`. Nothing re-queries
Overpass, so every published figure is reproducible without touching the commons
(ARCH §14 P7) and without the numbers moving under the next reader.

**Four denominators, not one.** The single most manipulable number in a coverage spike
is what the percentage is *of*, so each schema is reported against every denominator
that could reasonably be argued for, widest to narrowest:

    broad       what a routed leg is actually made of — path/track/bridleway/steps and
                non-sidewalk footway. The denominator the *product* would face.
    strict      the way type the schema's wiki page is written about (`highway=path`).
    curated     the way belongs to a `route=hiking` / `route=mtb` relation: somebody
                assembled it into a signed itinerary on purpose.
    signposted  (MTB only) the way already carries an `mtb=`/`mtb:*` tag — a mountain-bike
                mapper has personally edited this way.

The last two are the best case FR14b can possibly have. A schema that is thin on ways a
community has hand-curated is not thin for want of time.

Output:

  results/coverage.json   the table, the same-place control tags, the relation census,
                          and real `CoverageNote` payloads showing what B9 would render.
  stdout                  the tables as they appear in RESULTS.md.

Usage:
    python spikes/SPIKE-C/analyze.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import cache  # noqa: E402
import coverage as cov  # noqa: E402
from regions import REGIONS  # noqa: E402
from schemas import (  # noqa: E402
    BANDS, MAX_UNDERSTATEMENT_PCT, MIN_ELIGIBLE, SCHEMAS, eligible_mtb_signposted,
)

HERE = Path(__file__).parent
RAW = HERE / "raw"
RESULTS = HERE / "results"

#: Widest first in the table, because the narrowing is the argument: each step is a
#: concession to FR14b, and the reader should be able to watch the number fail to
#: improve as the concessions are made.
SCOPE_ORDER = ("broad", "strict", "curated", "signposted")


def denominators(schema, members: dict[str, list[int]]):
    """`[(scope, way-level predicate, human label)]` for one schema in one region."""
    out = [("broad", cov.by_tags(schema.broad), schema.broad_label),
           ("strict", cov.by_tags(schema.strict), schema.strict_label)]

    if schema.mode in ("hiking", "mtb"):
        ids = set(members.get(schema.mode, ()))
        broad = schema.broad
        out.append(("curated",
                    lambda w, ids=ids, b=broad: w["id"] in ids and b(w["tags"]),
                    f"route={schema.mode} member"))
    if schema.mode == "mtb":
        broad = schema.broad
        out.append(("signposted",
                    lambda w, b=broad: b(w["tags"]) and eligible_mtb_signposted(w["tags"]),
                    "carries any mtb=/mtb:* tag"))
    return out


def sample_notes(ways: list[dict], schema, limit: int = 3) -> list[dict]:
    """Real legs, rendered through the honesty payload.

    Picked to span the three states rather than to flatter: for each of `graded`,
    `partial` and `silent`, the longest real named trail that lands in it. A state with
    no instance in this region is simply absent from the list — which is itself readable.
    """
    by_name: dict[str, list[dict]] = {}
    for way in ways:
        if not schema.broad(way["tags"]):
            continue
        name = way["tags"].get("name")
        if name:
            by_name.setdefault(name, []).append(way)

    buckets: dict[str, tuple[float, dict]] = {}
    for name, group in by_name.items():
        if len(group) < 2:
            continue
        note = cov.note_for_leg(group, schema)
        best = buckets.get(note.state)
        if best is None or note.total_km > best[0]:
            buckets[note.state] = (note.total_km, {"leg": name, **note.__dict__})
    return [v[1] for _, v in sorted(buckets.items())][:limit]


def main() -> int:
    rows: list[dict] = []
    controls: list[dict] = []
    relations: dict[str, dict] = {}
    notes: dict[str, list[dict]] = {}
    inventory: list[dict] = []

    for region in REGIONS:
        if not cache.exists(RAW / f"{region.key}-ways.json"):
            print(f"!! {region.key}: not fetched, skipping", file=sys.stderr)
            continue
        ways = load = cache.load(RAW / f"{region.key}-ways.json")
        relations[region.key] = cache.load(RAW / f"{region.key}-relations-counts.json")
        members = (cache.load(RAW / f"{region.key}-members.json")
                   if cache.exists(RAW / f"{region.key}-members.json") else {})

        inventory.append({
            "region": region.key, "name": region.name, "kind": region.kind,
            "area_km2": round(region.area_km2, 1),
            "ways": len(ways),
            "km": round(sum(w["length_m"] for w in ways) / 1000.0, 1),
            "ways_per_1000km2": region.per_1000km2(len(ways)),
            "curated_member_ways": {k: len(v) for k, v in members.items()},
        })

        for schema in SCHEMAS:
            for scope, pred, label in denominators(schema, members):
                c = cov.measure(ways, schema, pred, label)
                rows.append({"region": region.key, "region_kind": region.kind,
                             "scope": scope, **c.to_dict(),
                             "eligible_per_1000km2": region.per_1000km2(c.eligible_ways),
                             "tagged_per_1000km2": region.per_1000km2(c.tagged_ways)})
                if scope == "broad":
                    controls.append({"region": region.key, "schema": schema.key,
                                     "denominator": label,
                                     "eligible_ways": c.eligible_ways,
                                     **cov.controls(ways, schema, pred)})
            notes.setdefault(region.key, []).extend(
                {"schema": schema.key, **n} for n in sample_notes(ways, schema))

    out = {
        "spike": "SPIKE-C",
        "issue": 170,
        "question": ("Per region, per published difficulty schema: what percentage of "
                     "eligible ways carry it? Is that enough to read rather than ask, "
                     "and where it is thin does thin coverage produce silence or wrong "
                     "answers?"),
        "bands": [{"key": b.key, "floor_pct": b.floor_pct, "meaning": b.meaning}
                  for b in BANDS],
        "max_understatement_pct": MAX_UNDERSTATEMENT_PCT,
        "min_eligible_for_a_band": MIN_ELIGIBLE,
        "scopes": list(SCOPE_ORDER),
        "inventory": inventory,
        "relations": relations,
        "coverage": rows,
        "controls": controls,
        "notes": notes,
    }
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / "coverage.json").write_text(json.dumps(out, indent=2) + "\n")

    # ------------------------------------------------------------------ tables
    print("\nINVENTORY")
    print(f"{'region':13} {'kind':13} {'km2':>8} {'ways':>8} {'km':>9} "
          f"{'hike-rel':>9} {'mtb-rel':>8}")
    for r in inventory:
        m = r["curated_member_ways"]
        print(f"{r['region']:13} {r['kind']:13} {r['area_km2']:8,.0f} {r['ways']:8,} "
              f"{r['km']:9,.0f} {m.get('hiking', 0):9,} {m.get('mtb', 0):8,}")

    def find(region_key, schema_key, scope):
        return next((r for r in rows if r["region"] == region_key
                     and r["schema"] == schema_key and r["scope"] == scope), None)

    for schema in SCHEMAS:
        print(f"\n{schema.tag.upper()}   ({schema.mode})   "
              f"— % of eligible ways tagged, by denominator")
        head = f"{'region':13}"
        for scope in SCOPE_ORDER:
            head += f" {scope[:9]+' n':>11} {scope[:9]+' %':>11}"
        print(head + f" {'%km(broad)':>11} {'band':>14}")
        for region in REGIONS:
            line = f"{region.key:13}"
            for scope in SCOPE_ORDER:
                r = find(region.key, schema.key, scope)
                if r is None:
                    line += f" {'-':>11} {'-':>11}"
                elif r["band"] == "n/a":
                    # Too few eligible ways for the percentage to mean anything. The
                    # count still prints — the reader should see *why* it is n/a.
                    line += f" {r['eligible_ways']:11,} {'n/a':>11}"
                else:
                    line += f" {r['eligible_ways']:11,} {r['pct_ways']:11.2f}"
            b = find(region.key, schema.key, "broad")
            if b is None:
                continue
            print(line + f" {b['pct_km']:11.2f} {b['band']:>14}")
        # Value distribution, once per schema, from the broadest denominator.
        for region in REGIONS:
            b = find(region.key, schema.key, "broad")
            if b and b["values"]:
                vals = ", ".join(f"{k}={v}" for k, v in list(b["values"].items())[:6])
                print(f"    {region.key:11} values: {vals}"
                      + (f"   [unparsed {b['unparsed_ways']}]"
                         if b["unparsed_ways"] else ""))

    print("\nCONTROLS — same ways, broad denominator, % carrying an ordinary tag")
    print(f"{'region':13} {'schema':17} {'elig':>7} {'surface':>8} {'smooth':>8} "
          f"{'name':>8} {'incline':>8} {'width':>8}")
    for c in controls:
        if c["schema"] not in ("sac_scale", "mtb:scale", "piste:difficulty"):
            continue
        print(f"{c['region']:13} {c['schema']:17} {c['eligible_ways']:7,} "
              f"{c['surface']:8.1f} {c['smoothness']:8.1f} {c['name']:8.1f} "
              f"{c['incline']:8.1f} {c['width']:8.1f}")

    print("\nROUTE RELATIONS — community-activity proxy")
    keys = list(next(iter(relations.values())).keys())
    print(f"{'region':13} " + " ".join(f"{k:>9}" for k in keys))
    for key, counts in relations.items():
        print(f"{key:13} " + " ".join(f"{counts[k]:9,}" for k in keys))

    print(f"\nwrote {RESULTS / 'coverage.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
