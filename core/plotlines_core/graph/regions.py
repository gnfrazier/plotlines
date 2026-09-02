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
import logging
import os
import time
from dataclasses import dataclass
from pathlib import Path

import osmnx as ox
import requests

log = logging.getLogger("plotlines.regions")

#: Current cache-key ruleset. Bump to invalidate every cached graph on disk —
#: the key is `(bbox, network_type, GRAPH_RULESET_VERSION)`, so a bump alone
#: is enough; no migration of the cache directory is needed, a stale entry is
#: simply never looked up again.
#: Bumped to 2 for issue #206: the download tag set is part of the cache key's
#: meaning, and every graph cached under version 1 predates the access/legality
#: tags below (`motor_vehicle`, `ford`, node `barrier`, ...).
GRAPH_RULESET_VERSION = 2

#: Overpass endpoints `ensure_graph` will try in order, most-canonical first
#: (issue #229). Before this, a graph build called the single public
#: `overpass-api.de` with no retry and no alternative: when that host was
#: down, rate-limiting, or unreachable from the network, the whole `routing`
#: capability for the bbox failed with a raw `requests.ConnectionError` repr
#: surfaced verbatim in the client. `PLOTLINES_OVERPASS_ENDPOINTS` (a
#: comma-separated list) overrides this wholesale — a private mirror, or a
#: single pinned endpoint for an offline/test context.
DEFAULT_OVERPASS_ENDPOINTS: tuple[str, ...] = (
    "https://overpass-api.de/api",
    "https://overpass.kumi.systems/api",
    "https://overpass.private.coffee/api",
)

#: Per-endpoint retry budget and exponential-backoff base (seconds) for a
#: transient transport error. Kept small: a refused connection is instant, so
#: the failover cost is dominated by osmnx's own status-endpoint pause, which
#: `ensure_graph` disables once it is past the first (polite) attempt.
OVERPASS_ATTEMPTS_PER_ENDPOINT = 2
OVERPASS_BACKOFF_BASE_S = 2.0


class OverpassUnavailable(RuntimeError):
    """Every configured Overpass endpoint refused or timed out while building a
    region graph. Unlike a bare `requests.ConnectionError`, its `str()` is a
    finished, user-facing sentence: the sidecar surfaces it verbatim as the
    `routing` capability's reason (`service/plotlines_service/app.py`), so it
    must read as something an Author can act on, never an exception repr."""


def overpass_endpoints() -> tuple[str, ...]:
    """The ordered Overpass endpoints `ensure_graph` tries. Env override
    `PLOTLINES_OVERPASS_ENDPOINTS` (comma-separated) replaces the built-in
    list entirely; blank/absent falls back to `DEFAULT_OVERPASS_ENDPOINTS`."""
    raw = os.environ.get("PLOTLINES_OVERPASS_ENDPOINTS", "").strip()
    if raw:
        picked = tuple(e.strip().rstrip("/") for e in raw.split(",") if e.strip())
        if picked:
            return picked
    return DEFAULT_OVERPASS_ENDPOINTS

# osmnx's default `useful_tags_way` does NOT include `surface`. Carried over
# from spikes/shared/regions.py:53-56 — without it FR4's surface weight and
# any unpaved band are inert (the spike measured surface tagged on 0.0% of
# edges until it asked for the tag). `maxspeed`/`lanes` are kept for the same
# reason: a traffic model better than highway-class alone will want them.
#
# The second group is every remaining OSM key that `routing/access.py` and
# `scoring/profile.py` read off an edge — a tag not requested at download time
# is not recoverable later without re-downloading, so a legality rule keyed on
# an un-downloaded tag goes silently inert (issue #206). `motorcar`/`4wd_only`
# are not read by any rule yet; they are FR29a's remaining vehicle-access
# signals and are pulled now so that advisory can read them where OSM has them.
# `test_graph_regions.py` asserts this list covers everything those two modules
# read, so a future rule that reaches for a new tag fails a test rather than
# going inert on every real graph.
PLOTLINES_WAY_TAGS: tuple[str, ...] = (
    "surface", "tracktype", "smoothness", "maxspeed", "lanes", "bicycle",
    "foot", "canoe", "motor_vehicle", "motorcar", "4wd_only", "ford",
    "waterway", "oneway:bicycle", "climbing:access",
)
ox.settings.useful_tags_way = list(dict.fromkeys([
    *ox.settings.useful_tags_way,
    *PLOTLINES_WAY_TAGS,
]))

# OSM tags a `barrier` (gate, bollard, cycle_barrier, ...) on the *node* it sits
# on, not on a way. `routing/access.py` reads `barrier` off the edge dict like
# every other consumer here — its docstring names the node->edge fold as
# graph-construction's job. Request the node tag so `fold_node_barriers` (below)
# has something to fold; without it `_BARRIER_DEFAULTS` is unreachable on every
# real graph (issue #206).
PLOTLINES_NODE_TAGS: tuple[str, ...] = ("barrier",)
ox.settings.useful_tags_node = list(dict.fromkeys([
    *ox.settings.useful_tags_node,
    *PLOTLINES_NODE_TAGS,
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


def fold_node_barriers(graph) -> int:
    """Copy each `barrier`-tagged node's value onto its incident edges, in place.

    `routing/access.py` reads `barrier` off the edge dict (its module docstring:
    *"a real extraction pipeline ... would fold them onto the incident edge
    before reaching this module; that folding is graph-construction's job"*).
    This is that fold. A barrier at a node obstructs passage through the node in
    either direction, so the value lands on every incident edge — in and out.
    Returns the number of barrier nodes folded (for logging/tests).

    Runs after simplification, which is told to retain barrier nodes as
    endpoints (`node_attrs_include=["barrier"]`) so a gate mid-way is not
    collapsed into edge geometry and lost before it can be folded.
    """
    folded = 0
    for node, ndata in graph.nodes(data=True):
        raw = ndata.get("barrier")
        if not raw:
            continue
        node_values = raw if isinstance(raw, list) else [raw]
        incident = list(graph.out_edges(node, keys=True, data=True))
        incident += list(graph.in_edges(node, keys=True, data=True))
        for _u, _v, _k, edata in incident:
            existing = edata.get("barrier")
            merged = list(existing) if isinstance(existing, list) else \
                ([existing] if existing else [])
            for value in node_values:
                if value not in merged:
                    merged.append(value)
            edata["barrier"] = merged[0] if len(merged) == 1 else merged
        folded += 1
    return folded


def _download_region_graph(region: Region):
    """The live half of `ensure_graph`: one Overpass acquisition against
    whatever `ox.settings.overpass_url` currently points at, plus the
    simplify / barrier-fold / strong-connectivity prune. Split out so
    `ensure_graph` can drive it once per endpoint with backoff (issue #229)."""
    # Simplify by hand rather than letting `graph_from_bbox` do it: osmnx 2.x
    # gives no way to pass `node_attrs_include` through that call, and a barrier
    # node that is not also a junction would be collapsed into edge geometry —
    # and its tag lost — before `fold_node_barriers` could reach it (issue #206).
    graph = ox.graph_from_bbox(
        region.bbox, network_type=region.network_type, simplify=False,
    )
    graph = ox.simplify_graph(graph, node_attrs_include=["barrier"])
    fold_node_barriers(graph)

    # osmnx's default keeps the largest *weakly* connected component, which is
    # not a routable guarantee (spikes/shared/regions.py:198-203's finding): a
    # node on the far side of a one-way pair can be reachable while nothing is
    # reachable *from* it. Strong connectivity means any anchor can reach any
    # other, which every routing shape (loop/out-and-back/point-to-point) here
    # depends on.
    return ox.truncate.largest_component(graph, strongly=True)


def ensure_graph(
    region: Region,
    cache_dir: Path,
    *,
    force: bool = False,
    endpoints: tuple[str, ...] | None = None,
    attempts_per_endpoint: int = OVERPASS_ATTEMPTS_PER_ENDPOINT,
    backoff_base_s: float = OVERPASS_BACKOFF_BASE_S,
    sleep=time.sleep,
) -> Path:
    """Return the on-disk path to `region`'s graph, building it via Overpass
    if it is not already cached. A live network call unless `force=False` and
    the cache already has this exact `(bbox, network_type, ruleset)` key —
    callers that must not touch the network (unit tests) should pre-seed the
    cache path instead of calling this directly.

    Overpass is treated as a soft dependency (issue #229): each endpoint in
    `endpoints` (default `overpass_endpoints()`) is tried up to
    `attempts_per_endpoint` times with exponential backoff on a transient
    transport error, then the next endpoint. If every endpoint fails,
    `OverpassUnavailable` is raised with a user-facing message rather than a
    raw `requests` exception leaking to the client.
    """
    out_path = region.graph_path(cache_dir)
    if out_path.exists() and not force:
        log.info("ensure_graph key=%s bbox=%s nt=%s cache=hit", region.key,
                 region.bbox, region.network_type)
        return out_path

    configure_overpass_cache(cache_dir)
    endpoints = tuple(endpoints) if endpoints is not None else overpass_endpoints()
    log.info("ensure_graph key=%s bbox=%s nt=%s cache=miss endpoints=%s force=%s",
             region.key, region.bbox, region.network_type, list(endpoints), force)
    started = time.monotonic()

    # `overpass_url` and the rate-limit flag are process-global osmnx settings
    # shared with curation's own Overpass calls — drive them per endpoint here,
    # but leave them exactly as found.
    saved_url = ox.settings.overpass_url
    saved_rate_limit = ox.settings.overpass_rate_limit
    failures: list[str] = []
    try:
        for endpoint_index, endpoint in enumerate(endpoints):
            ox.settings.overpass_url = endpoint
            for attempt in range(1, attempts_per_endpoint + 1):
                # Honour the server's advertised slot pause on the very first
                # try (stay polite); once we are failing over we are only
                # probing alternates, so skip the 60 s status-pause osmnx
                # falls back to when a status endpoint is itself unreachable.
                ox.settings.overpass_rate_limit = (
                    saved_rate_limit
                    if (endpoint_index == 0 and attempt == 1)
                    else False
                )
                attempt_started = time.monotonic()
                try:
                    graph = _download_region_graph(region)
                except requests.exceptions.RequestException as exc:
                    elapsed = time.monotonic() - attempt_started
                    failures.append(f"{endpoint} ({type(exc).__name__})")
                    log.warning(
                        "ensure_graph key=%s endpoint=%s attempt=%d/%d FAILED "
                        "after %.1fs: %s: %s", region.key, endpoint, attempt,
                        attempts_per_endpoint, elapsed, type(exc).__name__, exc)
                    if attempt < attempts_per_endpoint:
                        backoff = backoff_base_s * 2 ** (attempt - 1)
                        log.info("ensure_graph key=%s backing off %.1fs before retry",
                                 region.key, backoff)
                        sleep(backoff)
                    continue
                out_path.parent.mkdir(parents=True, exist_ok=True)
                ox.io.save_graphml(graph, out_path)
                log.info(
                    "ensure_graph key=%s endpoint=%s attempt=%d OK: %d nodes, "
                    "%d edges, %.1fs total", region.key, endpoint, attempt,
                    graph.number_of_nodes(), graph.number_of_edges(),
                    time.monotonic() - started)
                return out_path
    finally:
        ox.settings.overpass_url = saved_url
        ox.settings.overpass_rate_limit = saved_rate_limit

    tried = ", ".join(failures) if failures else ", ".join(endpoints)
    log.error("ensure_graph key=%s EXHAUSTED all %d endpoints after %.1fs: %s",
              region.key, len(endpoints), time.monotonic() - started, tried)
    raise OverpassUnavailable(
        "Couldn't reach the map-data service to prepare routing for this area. "
        "This is almost always temporary — check your connection and try again "
        f"in a few minutes. (tried: {tried})"
    )
