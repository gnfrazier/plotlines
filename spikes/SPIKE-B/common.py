"""Shared load path for the SPIKE-B scripts.

Reads the `raw/` Overpass pulls, converts them to `plotlines_core` `RawFeature`s,
and runs the product's own `score_notability` over them — the same discipline as
SPIKE-A: the spike measures and tunes the product's code, it does not
reimplement it.
"""

from __future__ import annotations

import sys
import time
import tracemalloc
from pathlib import Path

from pyproj import Geod

CORE = Path(__file__).resolve().parents[2] / "core"
sys.path.insert(0, str(CORE))
sys.path.insert(0, str(Path(__file__).parent))

import cache  # noqa: E402
from regions import BRP, Box  # noqa: E402

from plotlines_core.curation.notability import (  # noqa: E402
    RawFeature, score_notability, Candidate,
)
from plotlines_core.curation.taxonomy import LAYERS  # noqa: E402

HERE = Path(__file__).parent
RAW = HERE / "raw"
RESULTS = HERE / "results"
KEYS = ("historic", "tourism", "amenity", "natural", "leisure", "man_made")
_GEOD = Geod(ellps="WGS84")

# FR97's six OSM families -> the taxonomy layer id score_notability expects.
# `tourism` maps to the "sight" layer; the rest are 1:1 with their key.
_KEY_TO_LAYER = {
    "historic": "historic", "tourism": "sight", "amenity": "amenity",
    "natural": "natural", "leisure": "leisure", "man_made": "man_made",
}
ALL_LAYERS = tuple(sorted(LAYERS))


def _poly_area_m2(geom: list[dict]) -> float | None:
    if not geom or len(geom) < 4:
        return None
    lons = [p["lon"] for p in geom]
    lats = [p["lat"] for p in geom]
    area, _ = _GEOD.polygon_area_perimeter(lons, lats)
    return abs(area)


def _coord(el: dict) -> tuple[float, float] | None:
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


def load_raw_features() -> list[RawFeature]:
    """Every raw element in the `brp` pull, deduped by (type, id), with polygon
    areas attached from the leisure-geom pull for FR98(b)'s park gate."""
    areas: dict[str, float] = {}
    geom_path = RAW / "brp-leisure-geom.json"
    if cache.exists(geom_path):
        for el in cache.load(geom_path).get("elements", []):
            if el.get("type") == "way" and el.get("geometry"):
                a = _poly_area_m2(el["geometry"])
                if a is not None:
                    areas[f"way/{el['id']}"] = a

    seen: dict[tuple[str, int], RawFeature] = {}
    for key in KEYS:
        path = RAW / f"brp-{key}.json"
        if not cache.exists(path):
            continue
        for el in cache.load(path).get("elements", []):
            if el.get("type") not in ("node", "way", "relation"):
                continue
            ident = (el["type"], el["id"])
            if ident in seen:
                seen[ident].tags.update(el.get("tags", {}))
                continue
            coord = _coord(el)
            if coord is None or coord[0] is None:
                continue
            fid = f"{el['type']}/{el['id']}"
            seen[ident] = RawFeature(
                id=fid, coord=coord, tags=dict(el.get("tags", {})),
                area_m2=areas.get(fid),
            )
    return list(seen.values())


def candidates_for(
    features: list[RawFeature],
    layers: tuple[str, ...] = ALL_LAYERS,
) -> list[Candidate]:
    """`score_notability` over the given live layer set (issue point 1: the
    layer-count axis of the cost sweep is just this set shrinking)."""
    return score_notability(features, live_layers=set(layers))


def crop_candidates(cands: list[Candidate], box: Box) -> list[Candidate]:
    return [c for c in cands if box.contains(c.coord[0], c.coord[1])]


class Meter:
    """perf_counter + tracemalloc around a block. `with Meter() as m: ...`
    then read `m.seconds` and `m.peak_mb`."""

    def __enter__(self) -> "Meter":
        tracemalloc.start()
        self._t = time.perf_counter()
        return self

    def __exit__(self, *exc) -> None:
        self.seconds = time.perf_counter() - self._t
        _, peak = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        self.peak_mb = peak / 1e6
