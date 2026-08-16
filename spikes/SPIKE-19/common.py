"""Shared plumbing for the SPIKE-19 probes.

Two deliberate choices here, both about comparability.

**The regions and the cache come from SPIKE-04, by import.** This spike's whole job is to
say whether the successor dataset still supports what SPIKE-04 measured, and that is only
a comparison if the bounding boxes are provably the same ones. Copying three bboxes into a
new file would work right up until someone adjusted a decimal, at which point every
"3DHP has fewer kilometres than NHDPlus HR" statement in RESULTS.md would silently become
a statement about bbox drafting. Importing makes that impossible rather than unlikely.

**Geometry is stored rounded and flattened.** The service returns 3D coordinates whose Z
ordinate is 0.0 everywhere in these regions (see `probe_3dhp.py` — it is a finding, not a
fetch bug), and 15 significant figures of longitude for a river centreline is noise. Six
decimal places is ~11 cm at these latitudes, which is finer than the source's own
positional accuracy, and dropping the dead Z ordinate costs nothing. Together they take
the committed cache from tens of megabytes to something that belongs in a repository.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import requests

HERE = Path(__file__).parent
RAW = HERE / "raw"
RESULTS = HERE / "results"

# SPIKE-04's own modules, so the bboxes and the on-disk cache format are identical.
sys.path.insert(0, str(HERE.parent / "SPIKE-04"))
import cache  # noqa: E402,F401  (re-exported for the probes)
from regions import REGIONS, REGIONS_BY_KEY  # noqa: E402,F401

UA = "plotlines-spike19/0.1 (research spike; gnfrazier@gmail.com)"

# The 3DHP service. Note the layer number: the flowlines are layer **50**, not layer 1.
# Layer 1 does not exist on this service and asking for it returns an HTTP 500 with the
# body "json", which reads like a transport failure rather than a wrong layer id.
SERVICE = "https://3dhp.nationalmap.gov/arcgis/rest/services/usgs_3dhp_all/FeatureServer"
FLOWLINE_LAYER = 50
REACHCODE_LAYER = 40          # HydroLocation - Reach Code, External Connection

# USGS NLDI and the OGC API - Features successor to WaterServices. SPIKE-04 §5 established
# that WaterServices is decommissioned in Q1 2027; nothing here may depend on it.
NLDI = "https://api.water.usgs.gov/nldi/linked-data"
WATERDATA = "https://api.waterdata.usgs.gov"

COORD_PRECISION = 6


def get_json(url: str, params: dict | None = None, attempts: int = 4,
             timeout: int = 180) -> dict:
    """GET with backoff.

    The national services time out under load on large envelopes, and a timeout recorded
    as an empty result set is the failure mode that matters here: "no flowlines in this
    region" and "the server was busy" are the same empty list, and only one of them is a
    finding. Raise rather than return empty.
    """
    last = None
    for attempt in range(1, attempts + 1):
        try:
            resp = requests.get(url, params=params, headers={"User-Agent": UA},
                                timeout=timeout)
        except requests.RequestException as exc:
            last = type(exc).__name__
        else:
            if resp.status_code == 200:
                data = resp.json()
                if isinstance(data, dict) and "error" in data:
                    raise RuntimeError(f"service error: {data['error']}")
                return data
            last = f"HTTP {resp.status_code}"
        print(f"    {last} (attempt {attempt}/{attempts})", file=sys.stderr)
        time.sleep(5 * attempt)
    raise RuntimeError(f"{url} failed {attempts}x; last: {last}")


def envelope(region, layer: int = FLOWLINE_LAYER) -> dict:
    """ArcGIS envelope query params for a SPIKE-04 region.

    USGS wants west,south,east,north. `Region.bbox` is Overpass order (south,west,north,
    east) and would silently return a different rectangle rather than an error, so the
    ordinates are named explicitly here.
    """
    return {
        "geometry": f"{region.west},{region.south},{region.east},{region.north}",
        "geometryType": "esriGeometryEnvelope",
        "inSR": 4326,
        "spatialRel": "esriSpatialRelIntersects",
        "f": "json",
    }


def query_layer(region, layer: int, where: str, out_fields: str,
                geometry: bool = False, page: int = 2000) -> list[dict]:
    """Paginated feature pull. Returns attribute dicts, with `_paths` attached when
    geometry was requested."""
    url = f"{SERVICE}/{layer}/query"
    rows: list[dict] = []
    offset = 0
    while True:
        params = envelope(region, layer) | {
            "where": where,
            "outFields": out_fields,
            "returnGeometry": "true" if geometry else "false",
            "resultOffset": offset,
            "resultRecordCount": page,
        }
        if geometry:
            params |= {"outSR": 4326, "returnZ": "false"}
        data = get_json(url, params)
        feats = data.get("features", [])
        for f in feats:
            row = dict(f["attributes"])
            if geometry:
                row["_paths"] = [
                    [[round(p[0], COORD_PRECISION), round(p[1], COORD_PRECISION)]
                     for p in path]
                    for path in f.get("geometry", {}).get("paths", [])
                ]
            rows.append(row)
        print(f"    +{len(feats)} (total {len(rows):,})")
        if not data.get("exceededTransferLimit") or not feats:
            break
        offset += len(feats)
    return rows


def count_layer(region, layer: int, where: str) -> int:
    params = envelope(region, layer) | {"where": where, "returnCountOnly": "true"}
    return get_json(f"{SERVICE}/{layer}/query", params)["count"]
