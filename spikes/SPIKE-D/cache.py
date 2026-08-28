"""Gzipped on-disk cache for SPIKE-D's extraction artifacts (shape copied from
SPIKE-A/SPIKE-B).

What is cached here is the *product's* output — `RawFeature` lists as returned
by `OsmLayerProvider.fetch` — not raw Overpass JSON. SPIKE-A and SPIKE-B cached
the wire format because they were tuning what to do with it; SPIKE-D is timing
the pipeline, so what has to survive for the offline scripts is the thing the
timed stage produced.

Committing these means `analyze.py`, `concurrency.py` and `enlarge.py`
reproduce every published number without anyone re-hitting the Overpass commons
(ARCH §14 P7) — which is the same commons A23 is a risk about.
"""

from __future__ import annotations

import gzip
import json
from pathlib import Path

from plotlines_core.curation.notability import RawFeature


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


def dump_features(features: list[RawFeature]) -> list[dict]:
    return [
        {"id": f.id, "coord": list(f.coord), "tags": dict(f.tags), "area_m2": f.area_m2}
        for f in features
    ]


def read_features(rows: list[dict]) -> list[RawFeature]:
    return [
        RawFeature(id=r["id"], coord=(r["coord"][0], r["coord"][1]),
                   tags=r["tags"], area_m2=r.get("area_m2"))
        for r in rows
    ]
