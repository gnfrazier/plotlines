"""Plain-JSON GET with the gzipped disk cache convention SPIKE-A/B/D/H use, so
a re-run never re-hits a public government endpoint for a request this spike
already made (P7 — external resources are borrowed, not consumed).

Every `raw/*.json.gz` here is a **real** response captured live against the
URLs issue #176 names or that replaced them (2026-09-01). Nothing in this
spike is synthetic feed data.

Two differences from SPIKE-H's `arcgis_common.py`, both from the sources:

- **No `f=json` parameter.** These are not ArcGIS services; a WZDx feed is a
  plain GeoJSON document at a fixed URL with no query interface at all, which
  is itself one of the findings (see `RESULTS.md` §2 — "no bbox on the wire").
- **`fetch_ms` is recorded per fetch.** The timing arm needs the real transfer
  cost of a 10 MB statewide document, and it is only observable on the cold
  call.
"""

from __future__ import annotations

import gzip
import json
import time
from pathlib import Path

import requests

RAW = Path(__file__).resolve().parent / "raw"

USER_AGENT = (
    "plotlines-spike17/0.1 (research spike, issue #176; "
    "contact via github.com/gnfrazier/plotlines)"
)

#: Populated by `cached_get` on a cold fetch only — `{name: milliseconds}`.
FETCH_MS: dict[str, float] = {}
#: `{name: bytes}` for a cold fetch; the compressed size is on disk.
FETCH_BYTES: dict[str, int] = {}


def _cache_path(name: str) -> Path:
    return RAW / f"{name}.json.gz"


def cached_get(name: str, url: str, *, params: dict | None = None,
               timeout: float = 120.0, force: bool = False) -> dict:
    """`GET url` as JSON, cached to `raw/{name}.json.gz`."""
    path = _cache_path(name)
    if path.exists() and not force:
        with gzip.open(path, "rt", encoding="utf-8") as fh:
            return json.load(fh)

    started = time.perf_counter()
    resp = requests.get(url, params=params or {}, timeout=timeout,
                        headers={"User-Agent": USER_AGENT,
                                 "Accept": "application/json, application/geo+json"})
    resp.raise_for_status()
    body = resp.content
    FETCH_MS[name] = (time.perf_counter() - started) * 1000.0
    FETCH_BYTES[name] = len(body)
    data = json.loads(body)

    RAW.mkdir(parents=True, exist_ok=True)
    with gzip.open(path, "wt", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"))
    return data


def live_get(url: str, *, timeout: float = 120.0) -> tuple[dict, float, int]:
    """An uncached fetch — `(body, milliseconds, bytes)`. Used only by the
    volatility poll, which must see the live document each time and must not
    poison the committed cache with a later snapshot.
    """
    started = time.perf_counter()
    resp = requests.get(url, timeout=timeout,
                        headers={"User-Agent": USER_AGENT,
                                 "Accept": "application/json, application/geo+json"})
    resp.raise_for_status()
    body = resp.content
    return json.loads(body), (time.perf_counter() - started) * 1000.0, len(body)
