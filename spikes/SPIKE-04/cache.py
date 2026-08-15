"""Shared on-disk cache for the SPIKE-04 probes.

Everything the probes fetch is cached and committed, so `analyze.py` reproduces the
published numbers offline and nobody has to re-hit Overpass, USGS, or a state GIS server
to check the spike's arithmetic. That only works if the cache is a sane size to commit:
the raw pulls are ~35 MB of JSON and compress about 10:1, so they are stored gzipped.

Readers accept a plain `.json` too, so a cache written before this module existed — or by
hand during a debugging session — still loads.
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path


def cache_path(path: Path) -> Path:
    """Canonical (gzipped) location for a logical cache path."""
    return path if path.suffix == ".gz" else path.with_suffix(path.suffix + ".gz")


def exists(path: Path) -> bool:
    return cache_path(path).exists() or path.exists()


def load(path: Path):
    gz = cache_path(path)
    if gz.exists():
        with gzip.open(gz, "rt", encoding="utf-8") as fh:
            return json.load(fh)
    return json.loads(path.read_text(encoding="utf-8"))


def save(path: Path, obj) -> Path:
    gz = cache_path(path)
    gz.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(gz, "wt", encoding="utf-8") as fh:
        json.dump(obj, fh, separators=(",", ":"))
    return gz
