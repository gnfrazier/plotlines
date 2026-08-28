"""Generic ArcGIS MapServer/FeatureServer REST query, with the same
gzipped-JSON disk cache convention SPIKE-A/B/D use so a re-run never re-hits
a public government endpoint for a query this spike already made. Every
`raw/*.json.gz` file here is a **real** response, captured live against the
URLs named in issue #160 point 2 (2026-08-28) — nothing in this spike is
synthetic ArcGIS data.
"""

from __future__ import annotations

import gzip
import json
import time
from pathlib import Path
from typing import Optional

import requests

RAW = Path(__file__).resolve().parent / "raw"

USER_AGENT = "plotlines-spikeH/0.1 (research spike, issue #160; contact via github.com/gnfrazier/plotlines)"


def _cache_path(name: str) -> Path:
    return RAW / f"{name}.json.gz"


def cached_get(name: str, url: str, params: dict, *, timeout: float = 25.0,
               force: bool = False) -> dict:
    """`GET url?params` as ArcGIS JSON, cached to `raw/{name}.json.gz`. Raises
    on a transport error or an ArcGIS-level `{"error": ...}` body — a bad
    layer id or a malformed query answers HTTP 200 with an error payload,
    not a 4xx, so the error has to be read out of the body."""
    path = _cache_path(name)
    if path.exists() and not force:
        with gzip.open(path, "rt", encoding="utf-8") as fh:
            return json.load(fh)

    resp = requests.get(url, params={**params, "f": "json"}, timeout=timeout,
                        headers={"User-Agent": USER_AGENT})
    resp.raise_for_status()
    data = resp.json()
    if isinstance(data, dict) and "error" in data:
        err = data["error"]
        raise RuntimeError(f"ArcGIS error querying {name} ({url}): "
                          f"{err.get('code')} {err.get('message')}")

    RAW.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wt", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"))
    return data


def query_envelope(name: str, base_url: str, layer_id: int, bbox, *,
                   out_fields: str = "*", extra: Optional[dict] = None,
                   delay_s: float = 0.0, timeout: float = 25.0) -> dict:
    """A bbox-intersects query against one MapServer/FeatureServer layer,
    requesting WGS84 in and out so callers never touch the service's native
    state-plane/whatever spatial reference. `delay_s`, applied only on an
    actual network fetch (never on a cache hit), stands in for a slow remote
    plugin — issue #160 point 6 — without fabricating latency that never
    happened on a warm run."""
    url = f"{base_url}/{layer_id}/query"
    params = {
        "geometry": f"{bbox.west},{bbox.south},{bbox.east},{bbox.north}",
        "geometryType": "esriGeometryEnvelope",
        "inSR": 4326,
        "outSR": 4326,
        "spatialRel": "esriSpatialRelIntersects",
        "outFields": out_fields,
        **(extra or {}),
    }
    if delay_s and not _cache_path(name).exists():
        time.sleep(delay_s)
    return cached_get(name, url, params, timeout=timeout)
