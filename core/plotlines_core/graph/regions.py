"""Region graph acquisition — promoted from `spikes/shared/regions.py` (issue
#154, ARCH D41/new). Pure library code (P1: no fastapi import).

Before this, the sidecar routed every trip against one committed Boulder
fixture regardless of the Author's declared bbox (README.md, pre-#154). This
module is the bbox -> graph half of the fix: given a trip's bbox, acquire (or
reuse a cached) routable graph for exactly that area.

**Deliberately graph-only.** `spikes/shared/regions.py` also builds a DEM via
an AWS Terrarium fetcher; that is a spike-only shortcut and is *not* promoted
here — D20/FR85 pin elevation to GEDTM30 via OpenTopography with no fallback,
and a second elevation source is exactly what D20 forbids. Elevation
acquisition for an on-demand region stays gated on FR87 (issue #148); a
region built by this module reports `routing` ready while `elevation` stays
honestly not-ready (issue #154's explicit scoping note).
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

import osmnx as ox

#: Current cache-key ruleset. Bump to invalidate every cached graph on disk —
#: the key is `(bbox, network_type, GRAPH_RULESET_VERSION)`, so a bump alone
#: is enough; no migration of the cache directory is needed, a stale entry is
#: simply never looked up again.
GRAPH_RULESET_VERSION = 1

# osmnx's default `useful_tags_way` does NOT include `surface`. Carried over
# from spikes/shared/regions.py:53-56 — without it FR4's surface weight and
# any unpaved band are inert (the spike measured surface tagged on 0.0% of
# edges until it asked for the tag). `maxspeed`/`lanes` are kept for the same
# reason: a traffic model better than highway-class alone will want them.
ox.settings.useful_tags_way = list(dict.fromkeys([
    *ox.settings.useful_tags_way,
    "surface", "tracktype", "smoothness", "maxspeed", "lanes", "bicycle",
]))


def configure_overpass_cache(cache_dir: Path) -> None:
    """Point osmnx's own Overpass response cache at a real app-support
    directory. Carried over from spikes/shared/regions.py:44-46 — without
    this, stray Nominatim/Overpass responses land wherever the process
    happened to start (`cache/`, `client/cache/` in the pre-#154 codebase)."""
    ox.settings.cache_folder = str(cache_dir / "overpass")
    ox.settings.use_cache = True


@dataclass(frozen=True)
class Region:
    """One Author-declared trip bbox, resolved to a cache key and on-disk
    paths. `bbox` is (west, south, east, north) — osmnx 2.x order."""

    key: str
    bbox: tuple[float, float, float, float]
    network_type: str = "bike"

    @property
    def centre(self) -> tuple[float, float]:
        west, south, east, north = self.bbox
        return ((south + north) / 2.0, (west + east) / 2.0)

    def graph_path(self, cache_dir: Path) -> Path:
        return cache_dir / "regions" / self.key / "graph.graphml"


def region_key(bbox: tuple[float, float, float, float], network_type: str = "bike",
               ruleset_version: int = GRAPH_RULESET_VERSION) -> str:
    """A stable, deterministic cache key for `(bbox, network_type,
    ruleset_version)`. Rounded to ~1 cm at the equator so two requests for
    "the same" bbox that differ only in float noise (e.g. a re-drawn but
    visually identical bbox) hit the same cache entry."""
    payload = json.dumps({
        "bbox": [round(coord, 7) for coord in bbox],
        "network_type": network_type,
        "ruleset_version": ruleset_version,
    }, sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def region_for(bbox: tuple[float, float, float, float], network_type: str = "bike"
              ) -> Region:
    return Region(key=region_key(bbox, network_type), bbox=bbox, network_type=network_type)


def ensure_graph(region: Region, cache_dir: Path, *, force: bool = False) -> Path:
    """Return the on-disk path to `region`'s graph, building it via Overpass
    if it is not already cached. A live network call unless `force=False` and
    the cache already has this exact `(bbox, network_type, ruleset)` key —
    callers that must not touch the network (unit tests) should pre-seed the
    cache path instead of calling this directly.
    """
    out_path = region.graph_path(cache_dir)
    if out_path.exists() and not force:
        return out_path

    configure_overpass_cache(cache_dir)
    graph = ox.graph_from_bbox(region.bbox, network_type=region.network_type)

    # osmnx's default keeps the largest *weakly* connected component, which is
    # not a routable guarantee (spikes/shared/regions.py:198-203's finding): a
    # node on the far side of a one-way pair can be reachable while nothing is
    # reachable *from* it. Strong connectivity means any anchor can reach any
    # other, which every routing shape (loop/out-and-back/point-to-point) here
    # depends on.
    graph = ox.truncate.largest_component(graph, strongly=True)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    ox.io.save_graphml(graph, out_path)
    return out_path
