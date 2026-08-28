"""Gzipped on-disk cache for SPIKE-C's Overpass pulls — issue #170.

Same shape as SPIKE-04's and SPIKE-D's, with one deliberate difference: **what is
cached is not the raw Overpass response.**

This spike needs two things out of every eligible way — its tags (to know whether a
difficulty schema is present) and its *length* (so coverage can be reported by
kilometre as well as by way count). Length is the only thing geometry is for, and
geometry is ~95% of the bytes. Committing the raw `out geom` responses for seven
regions would be ~40 MB gzipped for data that is thrown away after one `Geod` call.

So `probe.py` distils each tile the moment it arrives — every way becomes
`{id, length_m, tags}`, **all** tags kept, nothing pre-filtered — and that is what is
committed. `analyze.py` and `degrade.py` reproduce every published number from it
offline, which is the property that actually matters (ARCH §14 P7), and re-analysing
against a tag nobody thought of at fetch time still works.

Delete a file under `raw/` to refetch that region.
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
