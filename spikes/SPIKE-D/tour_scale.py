"""The multi-day extent's POI-indexing cost, from SPIKE-B's committed pull.
Issue #159 point 1, at the top of the range FR120 permits.

`regions.TOUR` is coordinate-for-coordinate `SPIKE-B/regions.py`'s `BRP`, and
SPIKE-B committed the six FR97 layer-family Overpass responses for it
(`spikes/SPIKE-B/raw/brp-*.json.gz`, ~0.75 MB gzipped). Those queries have
already been paid for once, at the cost SPIKE-B's README records — "~3h once,
through a bad Overpass day". Re-issuing them to time `score_notability` would
add load to the public commons for a number that does not depend on how the
bytes arrived.

So this measures the half that can be measured honestly offline — bytes in,
features out, indexing time, candidates — and leaves the fetch half to
`probe.py`, which is where the multi-day pull's real behaviour against public
Overpass is recorded.

The split matters for D34. "Layer extraction and POI indexing" is one phrase
covering two costs with nothing in common: one is a network queue you do not
control, the other is a Python loop that scales with feature count. Only the
second is a *reordering* of work. If the first is the minutes, D34's claim
that FR121 reorders rather than adds is describing the wrong half.

Usage:
    .venv/bin/python spikes/SPIKE-D/tour_scale.py [--json]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import common  # noqa: E402
from common import ALL_LAYERS, DEFAULT_LAYERS, Meter  # noqa: E402
from regions import TOUR  # noqa: E402

from plotlines_core.curation.notability import RawFeature, score_notability  # noqa: E402

SPIKE_B_RAW = Path(__file__).resolve().parent.parent / "SPIKE-B" / "raw"
KEYS = ("historic", "tourism", "amenity", "natural", "leisure", "man_made")

# SPIKE-B pulled by OSM top-level key; the taxonomy names one of them
# differently. Same mapping SPIKE-B/common.py uses.
_KEY_TO_LAYER = {"tourism": "sight"}


def _coord(el: dict):
    if el["type"] == "node":
        return (el.get("lon"), el.get("lat"))
    c = el.get("center")
    if c:
        return (c.get("lon"), c.get("lat"))
    geom = el.get("geometry")
    if geom:
        return (sum(p["lon"] for p in geom) / len(geom),
                sum(p["lat"] for p in geom) / len(geom))
    return None


def load_brp() -> tuple[list[RawFeature], dict]:
    """SPIKE-B's committed pull -> `RawFeature`s, with the wire cost recorded."""
    import gzip
    import json

    from pyproj import Geod

    geod = Geod(ellps="WGS84")
    areas: dict[str, float] = {}
    geom_path = SPIKE_B_RAW / "brp-leisure-geom.json.gz"
    if geom_path.exists():
        with gzip.open(geom_path, "rt", encoding="utf-8") as fh:
            for el in json.load(fh).get("elements", []):
                g = el.get("geometry")
                if el.get("type") == "way" and g and len(g) >= 4:
                    a, _ = geod.polygon_area_perimeter([p["lon"] for p in g],
                                                       [p["lat"] for p in g])
                    areas[f"way/{el['id']}"] = abs(a)

    wire = {"gz_bytes": 0, "json_bytes": 0, "elements": 0, "per_key": {}}
    seen: dict[tuple[str, int], RawFeature] = {}
    for key in KEYS:
        path = SPIKE_B_RAW / f"brp-{key}.json.gz"
        if not path.exists():
            continue
        gz = path.stat().st_size
        with gzip.open(path, "rt", encoding="utf-8") as fh:
            text = fh.read()
        payload = json.loads(text)
        elements = [e for e in payload.get("elements", [])
                    if e.get("type") in ("node", "way", "relation")]
        wire["gz_bytes"] += gz
        wire["json_bytes"] += len(text)
        wire["elements"] += len(elements)
        wire["per_key"][key] = {"gz_bytes": gz, "json_bytes": len(text),
                                "elements": len(elements)}
        for el in elements:
            ident = (el["type"], el["id"])
            if ident in seen:
                seen[ident].tags.update(el.get("tags", {}))
                continue
            coord = _coord(el)
            if coord is None or coord[0] is None:
                continue
            fid = f"{el['type']}/{el['id']}"
            seen[ident] = RawFeature(id=fid, coord=coord,
                                     tags=dict(el.get("tags", {})),
                                     area_m2=areas.get(fid))
    return list(seen.values()), wire


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if not SPIKE_B_RAW.exists():
        raise SystemExit(f"missing {SPIKE_B_RAW} — SPIKE-B's committed pull is the input")

    features, wire = load_brp()
    print(f"=== {TOUR.name} ({TOUR.area_km2:,.0f} km2) ===")
    print(f"    source: SPIKE-B's committed pull, {wire['gz_bytes'] / 1e6:.2f} MB gz / "
          f"{wire['json_bytes'] / 1e6:.1f} MB JSON, {wire['elements']:,} elements")
    print(f"    deduped to {len(features):,} raw features\n")

    rows = []
    for name, layers in (("default 3 layers", DEFAULT_LAYERS),
                         ("all 6 layers", ALL_LAYERS)):
        # Three passes; the median, so a stray GC pause is not the headline.
        times, cands = [], 0
        for _ in range(3):
            with Meter() as m:
                candidates = score_notability(features, live_layers=set(layers))
            times.append(m.seconds)
            cands = len(candidates)
        times.sort()
        row = {
            "layers": sorted(layers),
            "index_s": round(times[1], 3),
            "peak_mb": round(m.peak_mb, 1),
            "features": len(features),
            "candidates": cands,
        }
        rows.append(row)
        print(f"  {name:20} index {row['index_s']:7.3f}s   "
              f"{len(features):,} feat -> {cands:,} cand   peak {row['peak_mb']:.0f} MB")

    out = {
        "extent": TOUR.key,
        "area_km2": round(TOUR.area_km2, 1),
        "source": "spikes/SPIKE-B/raw/brp-*.json.gz (committed; not re-queried)",
        "wire": wire,
        "runs": rows,
    }
    if args.json:
        print(f"\nwrote {common.write_results('tour_scale.json', out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
