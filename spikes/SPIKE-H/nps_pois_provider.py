"""NPS Public Points of Interest — a real, keyless ArcGIS MapServer REST
source (`mapservices.nps.gov`), federal (17 U.S.C. §105 — a U.S. Government
work carries no copyright in the US) and self-attributed: the service's own
`copyrightText` is `"National Park Service, ngp_support@nps.gov"`, so
`licence.satisfiable` is honestly `True` — this is the spike's *loadable*
real point source, the counterpart to `nc_markers_provider`'s blocked one.

Queried live against the TRIP bbox (Grandfather Mountain / Linville, NC —
`spikes/SPIKE-D/regions.py:TRIP`), which sits inside the Blue Ridge Parkway
unit (`UNITCODE=BLRI`): 97 real POIs, 12 distinct `POITYPE` values. This
provider's taxonomy covers 9 of them — see the module docstring in
`results/RESULTS.md` §2 for why `Gate`/`Parking Lot` are left unmatched
(the same "not every value is worth a row" choice `taxonomy.py` already
makes for OSM) and why 3 `Hospital`-tagged records are a source data error,
not a Plotlines qualification question.

`Mile Marker` is deliberately given `role_affinity="station"` — a real-world
instance of D47's third affinity, which until now only had a synthetic
example (`core/tests/test_curation_colocate.py`'s `crag`).
"""

from __future__ import annotations

import _paths  # noqa: F401

from arcgis_common import query_envelope
from contract import BBox, Candidate, LayerLicence, LayerLoadState, READY, TypeRule, score_with_taxonomy
from plotlines_core.curation.notability import RawFeature

BASE_URL = "https://mapservices.nps.gov/arcgis/rest/services/NationalDatasets/NPS_Public_POIs/MapServer"
LAYER_ID = 0

# (POITYPE, base_weight, role_affinity) — weights are illustrative, in the
# same spirit as taxonomy.py's seed rows before SPIKE-A calibration; this
# spike is not a calibration pass (that is SPIKE-A/B's job, for OSM), it is
# a test of whether a plugin's own taxonomy can drive real scoring at all.
_ROWS: tuple[tuple[str, float, str], ...] = (
    ("Waterfall", 0.75, "narrative"),
    ("Overlook", 0.65, "narrative"),
    ("Mountain Pass (saddle / Gap)", 0.40, "narrative"),
    ("Peak", 0.50, "narrative"),
    ("Bridge", 0.28, "narrative"),
    ("Visitor Center", 0.60, "provision"),
    ("Campground", 0.50, "provision"),
    ("Picnic Area", 0.40, "provision"),
    ("Mile Marker", 0.12, "station"),
    # NOT covered: "Gate", "Parking Lot" (generic infrastructure, not a
    # place an Author would surface) and "Hospital" (3 records in the TRIP
    # bbox — there is no hospital on the Blue Ridge Parkway; this is the
    # source's own tagging error, left unmatched rather than "fixed").
)

_TAXONOMY: tuple[TypeRule, ...] = tuple(
    TypeRule(layer="sight", key="poi_type", value=v, base_weight=w, role_affinity=aff)
    for v, w, aff in _ROWS
)

_OUT_FIELDS = "OBJECTID,POINAME,POITYPE,UNITNAME,UNITCODE"


class NPSPublicPOIsProvider:
    """FR100's `LayerProvider` against a real federal ArcGIS source. Supports
    an injected `delay_s` (see `arcgis_common.query_envelope`) so this same,
    real provider can also stand in for issue #160 point 6's "deliberately
    slow" case without a synthetic stub."""

    def __init__(self, *, cache_key: str = "nps_pois_trip", delay_s: float = 0.0) -> None:
        self._cache_key = cache_key
        self._delay_s = delay_s

    @property
    def licence(self) -> LayerLicence:
        return LayerLicence(
            id="US-PD-Fed",
            attribution="National Park Service, ngp_support@nps.gov",
            terms_url="https://www.nps.gov/aboutus/disclaimer.htm",
            note="17 U.S.C. §105 (U.S. Government work, no US copyright); "
                 "attribution string is the service's own copyrightText, "
                 "verified live 2026-08-28.",
        )

    @property
    def taxonomy(self):
        return _TAXONOMY

    def fetch_candidates(self, bbox: BBox) -> list[Candidate]:
        data = query_envelope(self._cache_key, BASE_URL, LAYER_ID, bbox,
                              out_fields=_OUT_FIELDS, delay_s=self._delay_s)
        features: list[RawFeature] = []
        for feat in data.get("features", []):
            attrs = feat["attributes"]
            geom = feat.get("geometry")
            if not geom:
                continue
            poi_type = attrs.get("POITYPE")
            if not poi_type:
                continue
            features.append(RawFeature(
                id=f"nps-poi/{attrs.get('OBJECTID')}",
                coord=(geom["x"], geom["y"]),
                tags={"poi_type": poi_type, "name": attrs.get("POINAME") or "",
                      "unit": attrs.get("UNITNAME") or ""},
            ))
        return score_with_taxonomy(features, self.taxonomy, live_layers={"sight"})

    def load_state(self) -> LayerLoadState:
        return LayerLoadState(READY)
