"""Gzipped on-disk cache for the SPIKE-B Overpass pulls (copied from SPIKE-A).

Raw pulls are committed so `analyze.py` reproduces the published numbers offline and
nobody re-hits the Overpass commons (ARCH §14 P7). They compress ~10:1, so they are
stored gzipped; a plain `.json` written by hand still loads.
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path


def cache_path(path: Path) -> Path:
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
