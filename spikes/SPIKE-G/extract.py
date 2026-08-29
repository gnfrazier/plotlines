"""Reconstruct real candidate positions and area-anchor polygons for a region,
from SPIKE-A's committed Overpass pulls. Read-only, offline, no re-fetch.

SPIKE-A's golden set (`spikes/SPIKE-A/results/golden/<region>.json`) is the
authoritative post-calibration candidate list — id, salience, layer,
role_affinity, type, title — but carries no geometry. Every candidate id
resolves to a coordinate in one of SPIKE-A's `raw/<region>-<family>.json.gz`
pulls (`out center tags`), so we join the two. Verified: 0 unresolved ids across
all three regions.

Area anchors (FR108): SPIKE-A also pulled `raw/<region>-leisure-geom.json.gz`
(`out geom`) for its park-area gate — real polygon rings. We attach a ring to
every candidate whose id matches a geom way, and treat park / nature_reserve /
garden / cemetery / recreation-ground / common candidates as area-rendered.
"""

from __future__ import annotations

import glob
import gzip
import json
import os
from dataclasses import dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
SPIKE_A = os.path.abspath(os.path.join(HERE, "..", "SPIKE-A"))

AREA_TYPE_HINTS = (
    "park", "nature_reserve", "garden", "cemetery",
    "recreation_ground", "common", "district", "pedestrian", "square",
)


@dataclass(frozen=True)
class Candidate:
    id: str
    lat: float
    lon: float
    salience: float
    layer: str
    role_affinity: str
    type: str
    title: str
    ring: tuple[tuple[float, float], ...] = ()  # non-empty => area anchor

    @property
    def is_area(self) -> bool:
        return bool(self.ring) or any(h in self.type for h in AREA_TYPE_HINTS)


def _coord_index(region: str) -> dict[str, tuple[float, float]]:
    idx: dict[str, tuple[float, float]] = {}
    for path in glob.glob(os.path.join(SPIKE_A, "raw", f"{region}-*.json.gz")):
        if "geom" in os.path.basename(path):
            continue
        with gzip.open(path) as fh:
            for el in json.load(fh)["elements"]:
                key = f"{el['type']}/{el['id']}"
                if "lat" in el:
                    idx[key] = (el["lat"], el["lon"])
                elif "center" in el:
                    idx[key] = (el["center"]["lat"], el["center"]["lon"])
    return idx


def _ring_index(region: str) -> dict[str, tuple[tuple[float, float], ...]]:
    rings: dict[str, tuple[tuple[float, float], ...]] = {}
    for path in glob.glob(os.path.join(SPIKE_A, "raw", f"{region}-*geom*.json.gz")):
        with gzip.open(path) as fh:
            for el in json.load(fh)["elements"]:
                geom = el.get("geometry")
                if not geom:
                    continue
                rings[f"{el['type']}/{el['id']}"] = tuple(
                    (pt["lat"], pt["lon"]) for pt in geom
                )
    return rings


def load_candidates(region: str) -> list[Candidate]:
    golden_path = os.path.join(SPIKE_A, "results", "golden", f"{region}.json")
    with open(golden_path) as fh:
        golden = json.load(fh)

    coords = _coord_index(region)
    rings = _ring_index(region)

    out: list[Candidate] = []
    for c in golden["candidates"]:
        cid = c["id"]
        if cid not in coords:
            raise KeyError(f"{region}: candidate {cid} has no coordinate in SPIKE-A raw")
        lat, lon = coords[cid]
        out.append(
            Candidate(
                id=cid,
                lat=lat,
                lon=lon,
                salience=float(c["salience"]),
                layer=c["layer"],
                role_affinity=c["role_affinity"],
                type=c["type"],
                title=c.get("title", ""),
                ring=rings.get(cid, ()),
            )
        )
    return out


def region_bbox(region: str) -> tuple[float, float, float, float]:
    with open(os.path.join(SPIKE_A, "results", "golden", f"{region}.json")) as fh:
        s, w, n, e = json.load(fh)["bbox_south_west_north_east"]
    return s, w, n, e
