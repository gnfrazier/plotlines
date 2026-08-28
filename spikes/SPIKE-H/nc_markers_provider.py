"""NC Highway Historical Markers — issue #160 point 2's first named
candidate. A real ArcGIS MapServer REST source (point geometry), and the
spike's licence-gate exhibit (point 5): **verified live, 2026-08-28**, the
service publishes `copyrightText: ""`, `documentInfo.Author: ""`, and an
empty `<useLimit/>` in its own metadata endpoint. NC Ch. 132 governs public
*access* to the records, which is a different thing from a stated
redistribution licence — no such statement exists here, machine-readable or
otherwise. `licence` below reports exactly that rather than guessing a
value, so `satisfiable` is honestly `False` and the registry (§ registry.py)
never queries this provider (D45's registration-time gate).
"""

from __future__ import annotations

import _paths  # noqa: F401

from arcgis_common import query_envelope
from contract import BBox, Candidate, LayerLicence, LayerLoadState, READY, TypeRule, score_with_taxonomy
from plotlines_core.curation.notability import RawFeature

BASE_URL = "https://gis2.ncdcr.gov/dncrgis/rest/services/NCHHM_Public/NC_Highway_Historical_Markers/MapServer"
LAYER_ID = 0

_TAXONOMY: tuple[TypeRule, ...] = (
    TypeRule(layer="historic", key="marker_type", value="highway_marker",
             base_weight=0.55, role_affinity="narrative"),
)

_ATTR_TITLE = "HPOPUB.DBO.NCHHM_Markers.MarkerTitle"
_ATTR_TERM = "HPOPUB.DBO.NCHHM_Markers.MainTerm"
_ATTR_YEAR = "HPOPUB.DBO.NCHHM_Markers.YearCast"
_ATTR_OID = "HPOPUB.DBO.NCMarkers.OBJECTID"

_OUT_FIELDS = ",".join((_ATTR_OID, _ATTR_TITLE, _ATTR_TERM, _ATTR_YEAR))


class NCHighwayMarkersProvider:
    """FR100's `LayerProvider`, backing a real state-government ArcGIS
    source. The provider itself works fine — `load_state()` is `ready` and
    `fetch_candidates` returns real markers — it is `licence.satisfiable`
    that is false, which is the whole point of testing a real source rather
    than a synthetic unlicensed stub."""

    _cache_key = "nc_markers_trip"

    @property
    def licence(self) -> LayerLicence:
        return LayerLicence(
            id="", attribution="",
            terms_url="https://gis2.ncdcr.gov/dncrgis/rest/services/NCHHM_Public/"
                      "NC_Highway_Historical_Markers/MapServer",
            note="verified live 2026-08-28: service metadata's copyrightText, "
                 "documentInfo.Author and dataIdInfo/resConst/Consts/useLimit are "
                 "all empty. NC public-records law (G.S. Ch. 132) governs access, "
                 "not redistribution terms, so nothing here answers FR101.",
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
            if not geom:
                continue
            oid = attrs.get(_ATTR_OID)
            title = attrs.get(_ATTR_TITLE) or attrs.get(_ATTR_TERM) or f"Marker {oid}"
            features.append(RawFeature(
                id=f"nc-marker/{oid}",
                coord=(geom["x"], geom["y"]),
                tags={"marker_type": "highway_marker", "name": str(title).title(),
                      "year_cast": str(attrs.get(_ATTR_YEAR) or "")},
            ))
        return score_with_taxonomy(features, self.taxonomy, live_layers={"historic"})

    def load_state(self) -> LayerLoadState:
        return LayerLoadState(READY)
