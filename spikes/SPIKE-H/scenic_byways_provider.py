"""US Scenic Byways (NC layer) — issue #160 point 2's route-overlay
candidate, and point 3's exhibit: **does `fetch_candidates` carry area/route
geometry, or only a point?**

A real ArcGIS MapServer REST source (`geo.dot.gov`, FHWA/US DOT — federal,
17 U.S.C. §105), `esriGeometryPolyline`. Queried live against SPIKE-D's TOUR
box (Blue Ridge Parkway corridor, Asheville-Boone): 14 real NC-designated
byways, one — "Forest Heritage Scenic Byway" — carrying **1,457 vertices**.

**This is deliberately the negative case.** `RawFeature.coord` is one
`(lon, lat)` point; `RawFeature.area_m2` is a scalar for a polygon's *area*,
not its boundary; `Candidate.coord` is likewise one point. Nothing in
core's actual data shapes has anywhere to put a polyline. `feature_from_
geometry` (`core/plotlines_core/curation/providers.py`) calls `geometry.
centroid` on whatever Shapely geometry it is handed — it does not raise on
a `LineString` — so a byway *can* become a `RawFeature`/`Candidate` without
an exception, and that is exactly the trap: it silently degrades a 40 km
route into one point with no record that anything was lost. `fetch_
candidates` below does the same reduction on purpose, and reports the
discarded vertex/path count in `tags` — not because tags is where geometry
belongs, but because there is nowhere else in the current shape to put it.
See `results/RESULTS.md` §3 for what this means for ARCH's `ShapeDataProvider`
claim.
"""

from __future__ import annotations

import math

import _paths  # noqa: F401

from arcgis_common import query_envelope
from contract import BBox, Candidate, LayerLicence, LayerLoadState, READY, TypeRule, score_with_taxonomy
from plotlines_core.curation.notability import RawFeature

BASE_URL = "https://geo.dot.gov/server/rest/services/US_Scenic_Byways/MapServer"
LAYER_ID = 71  # NC_ScenicByways

_TAXONOMY: tuple[TypeRule, ...] = (
    TypeRule(layer="sight", key="feature_type", value="scenic_byway",
             base_weight=0.6, role_affinity="narrative"),
)

_OUT_FIELDS = "FID,NAME,DESIGNATS,STATE,BYWAY_ID"

_EARTH_R_M = 6_371_000.0


def _polyline_length_m(paths: list[list[list[float]]]) -> float:
    """Real great-circle length of every path in the feature — used only to
    report how much distance one centroid point discards, not to feed
    anything downstream."""
    total = 0.0
    for path in paths:
        for (lon1, lat1), (lon2, lat2) in zip(path, path[1:]):
            phi1, phi2 = math.radians(lat1), math.radians(lat2)
            dphi = math.radians(lat2 - lat1)
            dlmb = math.radians(lon2 - lon1)
            a = (math.sin(dphi / 2) ** 2
                 + math.cos(phi1) * math.cos(phi2) * math.sin(dlmb / 2) ** 2)
            total += 2 * _EARTH_R_M * math.asin(min(1.0, math.sqrt(a)))
    return total


def _centroid(paths: list[list[list[float]]]) -> tuple[float, float]:
    """The same reduction `feature_from_geometry` performs via Shapely's
    `.centroid` — reimplemented here with the vertex mean (close enough for
    what this is demonstrating: a route becomes one point either way) so
    this module does not need a MultiLineString round-trip through Shapely
    just to prove the point."""
    xs: list[float] = []
    ys: list[float] = []
    for path in paths:
        for lon, lat in path:
            xs.append(lon)
            ys.append(lat)
    return (sum(xs) / len(xs), sum(ys) / len(ys))


class USScenicBywaysProvider:
    """FR100's `LayerProvider`, deliberately exercising route geometry
    rather than points — the counterpart to the two point sources."""

    def __init__(self, *, cache_key: str = "nc_scenic_byways_tour") -> None:
        self._cache_key = cache_key

    @property
    def licence(self) -> LayerLicence:
        return LayerLicence(
            id="US-PD-Fed",
            attribution="U.S. Department of Transportation, Federal Highway Administration",
            terms_url="https://www.fhwa.dot.gov/policyinformation/data.cfm",
            note="17 U.S.C. §105 (U.S. Government work). The service's own "
                 "copyrightText is empty (verified live 2026-08-28) — unlike "
                 "nps_pois_provider, this attribution is asserted from the "
                 "publisher's identity, not read off the response.",
        )

    @property
    def taxonomy(self):
        return _TAXONOMY

    def fetch_candidates(self, bbox: BBox) -> list[Candidate]:
        data = query_envelope(self._cache_key, BASE_URL, LAYER_ID, bbox,
                              out_fields=_OUT_FIELDS)
        features: list[RawFeature] = []
        for feat in data.get("features", []):
            attrs = feat["attributes"]
            geom = feat.get("geometry")
            paths = (geom or {}).get("paths")
            if not paths:
                continue
            n_paths = len(paths)
            n_verts = sum(len(p) for p in paths)
            length_km = _polyline_length_m(paths) / 1000.0
            lon, lat = _centroid(paths)
            features.append(RawFeature(
                id=f"nc-byway/{attrs.get('BYWAY_ID')}",
                coord=(lon, lat),
                # length_km/paths/vertices exist only so RESULTS can report
                # what a route reduces to — see module docstring. Nothing
                # downstream (score_with_taxonomy, colocate) reads them.
                tags={"feature_type": "scenic_byway", "name": attrs.get("NAME") or "",
                      "designation": attrs.get("DESIGNATS") or "",
                      "length_km": f"{length_km:.1f}", "n_paths": str(n_paths),
                      "n_vertices": str(n_verts)},
            ))
        return score_with_taxonomy(features, self.taxonomy, live_layers={"sight"})

    def load_state(self) -> LayerLoadState:
        return LayerLoadState(READY)
