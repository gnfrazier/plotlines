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
import socket
import time
from collections.abc import Callable
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from urllib.parse import urlparse

import osmnx as ox
import requests

from plotlines_core.osm_identity import apply_osm_http_identity, overpass_settings

log = logging.getLogger("plotlines.regions")

# Identify ourselves to Overpass/Nominatim before the first request can leave
# this process (issue #241, review §3.4). A real entrypoint re-applies this
# with the build version; importing this module — which every path that
# builds a graph does — is enough to stop osmnx's default UA, which names
# someone else's library, from ever going out. `DEFAULT_OVERPASS_ENDPOINTS`
# below is the other half of the same politeness policy.
apply_osm_http_identity()

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
#:
#: `overpass.private.coffee` was dropped in issue #232: it and
#: `overpass.kumi.systems` resolve to the same machine (193.219.97.30 /
#: `2a0d:f302:126:78ea::1`), so the list read as three endpoints but offered
#: only two distinct upstreams — and when that shared host was returning 502s
#: the "failover" hop landed straight back on it. `dedupe_endpoints` now
#: enforces at build time what this list could only assert by inspection.
#:
#: It was NOT replaced with a third public instance. Every region build here is
#: a multi-thousand-km² extract, and #232's own logs show 22 build attempts
#: against 6 bboxes in 40 minutes — a drag of the bbox handle commits a fresh
#: full-area query, and a settled failure requeues with no cooldown. Adding
#: mirrors spreads that load onto another volunteer operator instead of fixing
#: it; the durable answer is a self-hosted or paid instance via
#: `PLOTLINES_OVERPASS_ENDPOINTS`.
#:
#: Vetting a candidate, if one is ever added — through `ox.graph_from_bbox`,
#: never through `curl`, and never on its status code alone. Two live failures
#: that a status check calls healthy:
#:
#: * `overpass.osm.ch` answers `200 OK` with **zero elements** outside
#:   Switzerland — "this area has no roads", not "wrong endpoint". Check an
#:   out-of-region `out count`.
#: * `overpass.openstreetmap.fr` answers `403 Forbidden — only available to
#:   white-listed usages` to osmnx's user-agent while serving `curl` fine.
DEFAULT_OVERPASS_ENDPOINTS: tuple[str, ...] = (
    "https://overpass-api.de/api",
    "https://overpass.kumi.systems/api",
)

#: Per-endpoint retry budget and exponential-backoff base (seconds) for a
#: transient transport error. Kept small: the expensive failure mode — a host
#: whose socket will not open, which otherwise costs 60 s inside osmnx's
#: status-endpoint slot-pause fallback — is now short-circuited by the connect
#: probe below (`probe_endpoint`, issue #245) before osmnx is ever called, so
#: a wide retry budget here buys nothing but load on a struggling upstream.
OVERPASS_ATTEMPTS_PER_ENDPOINT = 2
OVERPASS_BACKOFF_BASE_S = 2.0

#: Timeout for `ensure_graph`'s pre-flight connect probe (issue #245). Short
#: by design: issue #240 measured a refused Overpass connection returning in
#: ~300 ms, so a few seconds is ample headroom for a healthy host on a slow
#: link while still turning an unreachable host's 60 s osmnx slot-pause into a
#: sub-second failover.
OVERPASS_PROBE_TIMEOUT_S = 3.0

#: What `ensure_graph` treats as "this endpoint is having a bad time" — retry
#: it, then fail over to the next one. Two distinct families:
#:
#: * `requests.exceptions.RequestException` — the transport never delivered a
#:   response (refused, reset, DNS, timeout).
#: * `ox._errors.ResponseStatusCodeError` — a response arrived, but with an
#:   error status and a body osmnx could not parse as JSON (an HTML 502/500
#:   from an overloaded mirror or its reverse proxy).
#:
#: The second was missing until issue #232, and its absence was the whole bug:
#: `ResponseStatusCodeError` subclasses `ValueError`, not `RequestException`,
#: so a mirror answering `502 Bad Gateway` escaped the retry/failover loop
#: entirely — no retry, no next endpoint, no `OverpassUnavailable`. The raw
#: exception repr surfaced as the `routing` capability's reason and the region
#: settled `failed` while a healthy endpoint further down the list was never
#: tried.
#:
#: `InsufficientResponseError` is deliberately NOT here. osmnx raises it for a
#: 200 response carrying no elements — which for a bbox with no routable ways
#: is a true answer about the area, not an outage. Retrying it across every
#: endpoint and then reporting "couldn't reach the map-data service" would
#: blame the network for an empty box.
TRANSIENT_OVERPASS_ERRORS: tuple[type[Exception], ...] = (
    requests.exceptions.RequestException,
    ox._errors.ResponseStatusCodeError,
)


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


@lru_cache(maxsize=64)
def _host_addresses(host: str) -> frozenset[str]:
    """`host`'s current addresses, memoised for the life of the process.

    Only ever used to decide whether two endpoint URLs name the same machine,
    so a stale answer costs at most one wasted failover hop — cheaper than a
    DNS round trip on every region build, and it keeps a synthetic endpoint
    list (tests, offline) to one lookup per host for the whole suite.
    """
    try:
        infos = socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)
    except OSError:
        return frozenset()
    return frozenset(info[4][0] for info in infos)


def resolve_endpoint_addresses(endpoint: str) -> frozenset[str]:
    """The IP addresses `endpoint`'s host currently resolves to, or an empty
    set if it does not resolve. Empty means "unknown", never "same as another"
    — an unresolvable host (a test's `a.example`, or a transient DNS failure)
    must never be deduped away."""
    host = urlparse(endpoint).hostname
    if not host:
        return frozenset()
    return _host_addresses(host)


def dedupe_endpoints(
    endpoints: tuple[str, ...],
    *,
    resolve=None,
) -> tuple[str, ...]:
    """`endpoints` with any entry that points at an already-listed machine
    removed, keeping the first occurrence and the original order.

    Failing over to a second URL for the *same* server buys nothing: whatever
    made the first attempt fail — an overloaded box returning 502s, a host
    that refuses connections — is waiting at the other name too. Issue #232
    shipped exactly that: two of three configured endpoints were aliases of
    one machine, so a three-endpoint list gave two real tries.

    Two endpoints are the same machine if their URLs match, if their hostnames
    match, or if their resolved address sets intersect. A host that does not
    resolve is compared by name only, so an offline or synthetic endpoint list
    survives intact.
    """
    resolve = resolve or resolve_endpoint_addresses
    kept: list[str] = []
    seen_hosts: set[str] = set()
    seen_addresses: set[str] = set()
    for endpoint in endpoints:
        host = (urlparse(endpoint).hostname or endpoint).lower()
        addresses = resolve(endpoint)
        if host in seen_hosts or (addresses & seen_addresses):
            log.info("dedupe_endpoints dropping %s — same host as an earlier "
                     "endpoint (host=%s addresses=%s)", endpoint, host,
                     sorted(addresses))
            continue
        kept.append(endpoint)
        seen_hosts.add(host)
        seen_addresses |= addresses
    return tuple(kept)


def probe_endpoint(
    endpoint: str, *, timeout_s: float = OVERPASS_PROBE_TIMEOUT_S,
) -> str | None:
    """Open and immediately close a TCP connection to `endpoint`'s host.

    Returns `None` if the socket opened within `timeout_s`; otherwise a short
    reason string. `ensure_graph` calls this before every osmnx attempt so a
    host it cannot reach fails over in well under a second instead of after
    the fixed 60 s pause osmnx takes when it cannot read that host's
    `/api/status` endpoint (issue #240; osmnx
    `_overpass._get_overpass_pause`'s `default_pause`, reached whenever the
    status GET raises `ConnectionError` — which a refused or black-holed host
    does). #240 measured the refusal itself returning in ~300 ms; the other
    ~60 s was pure waiting.

    **This covers exactly one failure class: refused / unreachable / unknown
    host.** A `None` result means the TCP handshake completed and nothing
    more. An endpoint that accepts the connection and then answers `502 Bad
    Gateway` from an overloaded reverse proxy — issue #232's actual failure —
    passes this probe unchanged; that case is still caught, one full attempt
    later, by the `ox._errors.ResponseStatusCodeError` arm of
    `TRANSIENT_OVERPASS_ERRORS`. The probe is a latency optimisation for the
    common refused case, **not** the thing that makes keeping
    `overpass_rate_limit` on affordable in general — some failing builds are
    still slow, and that is the accepted trade (OSM acquisition review §5.4,
    licensing addendum G4).
    """
    parsed = urlparse(endpoint)
    host = parsed.hostname
    if not host:
        return None  # nothing to probe — let osmnx deal with the odd value
    port = parsed.port or (80 if parsed.scheme == "http" else 443)
    try:
        with socket.create_connection((host, port), timeout=timeout_s):
            return None
    except socket.gaierror as exc:
        return f"name resolution failed ({exc})"
    except TimeoutError as exc:
        return f"timed out after {timeout_s:g}s ({exc})"
    except OSError as exc:
        return f"connect failed ({exc})"


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
    probe: Callable[[str], str | None] | None = None,
) -> Path:
    """Return the on-disk path to `region`'s graph, building it via Overpass
    if it is not already cached. A live network call unless `force=False` and
    the cache already has this exact `(bbox, network_type, ruleset)` key —
    callers that must not touch the network (unit tests) should pre-seed the
    cache path instead of calling this directly.

    Overpass is treated as a soft dependency (issue #229): each endpoint in
    `endpoints` (default `overpass_endpoints()`) is tried up to
    `attempts_per_endpoint` times with exponential backoff on a transient
    failure (`TRANSIENT_OVERPASS_ERRORS` — a failed transport *or* an error
    HTTP status), then the next endpoint. Endpoints that resolve to a machine
    already tried are dropped first (`dedupe_endpoints`), so the list's length
    is the number of real tries. If every endpoint fails, `OverpassUnavailable`
    is raised with a user-facing message rather than a raw exception leaking to
    the client.

    Before each osmnx attempt `probe` (default `probe_endpoint`) opens a
    short-timeout socket to the endpoint; a host that refuses or does not
    resolve is failed over immediately rather than after the 60 s osmnx spends
    in its status-endpoint slot-pause fallback for an unreachable host (issue
    #245, closes #240). The probe does not cover an endpoint that accepts the
    socket and then returns an error status — that is still a full attempt
    (addendum G4). The server's advertised rate-limit pause
    (`overpass_rate_limit`) is left at its configured value for every endpoint
    and every attempt: politeness is not traded for failover latency (#238
    mechanism 3).
    """
    probe = probe if probe is not None else probe_endpoint
    # Point osmnx's response cache inside `cache_dir` *before* the early
    # return can skip it (issue #242). This used to sit past the warm-cache
    # check, so a direct caller that hit the cache left `ox.settings`
    # untouched — and `/candidates` / `/geocode`, which never reach this
    # function at all, ran with the CWD-relative `./cache` default. A real
    # entrypoint (`create_app`, `diagnose_region`) now configures this at
    # startup too; this call stays as the floor for a direct `ensure_graph`
    # caller.
    configure_overpass_cache(cache_dir)

    out_path = region.graph_path(cache_dir)
    if out_path.exists() and not force:
        log.info("ensure_graph key=%s bbox=%s nt=%s cache=hit", region.key,
                 region.bbox, region.network_type)
        return out_path

    endpoints = tuple(endpoints) if endpoints is not None else overpass_endpoints()
    endpoints = dedupe_endpoints(endpoints)
    log.info("ensure_graph key=%s bbox=%s nt=%s cache=miss endpoints=%s force=%s",
             region.key, region.bbox, region.network_type, list(endpoints), force)
    started = time.monotonic()

    # `overpass_url` and the rate-limit flag are process-global osmnx settings
    # with no per-call override, and they are shared with the candidate path's
    # own Overpass calls in `curation/providers.py`. Before issue #244 this
    # loop drove them in the open: `/regions` and `/candidates` are both sync
    # `def` FastAPI endpoints, so a `/candidates` request the framework
    # scheduled on a threadpool sibling during a failover hop inherited this
    # endpoint — and, pre-#245, `overpass_rate_limit = False` — an upstream and
    # an impoliteness it never chose (licensing addendum G1). `overpass_settings`
    # holds `OSM_SETTINGS_LOCK` around each attempt and restores `overpass_url`
    # on the way out, so no concurrent osmnx caller can observe a hop's
    # endpoint. The cost is that a candidate fetch blocks for the length of an
    # attempt (option (b) in #244); Phase 1's mirror removes the shared
    # endpoint and with it the contention.
    failures: list[str] = []

    def _failed(endpoint: str, attempt: int, started_at: float,
                label: str, detail: str, *, backoff: bool = True) -> None:
        """Record one failed attempt — append to `failures` for the eventual
        `OverpassUnavailable` message and log it. Unless `backoff=False` (a
        probe failure, where nothing on the far end was actually contacted),
        sleep before the next attempt against this same endpoint."""
        failures.append(f"{endpoint} ({label})")
        log.warning(
            "ensure_graph key=%s endpoint=%s attempt=%d/%d FAILED after "
            "%.1fs: %s", region.key, endpoint, attempt, attempts_per_endpoint,
            time.monotonic() - started_at, detail)
        if backoff and attempt < attempts_per_endpoint:
            pause = backoff_base_s * 2 ** (attempt - 1)
            log.info("ensure_graph key=%s backing off %.1fs before retry",
                     region.key, pause)
            sleep(pause)

    for endpoint in endpoints:
        for attempt in range(1, attempts_per_endpoint + 1):
            attempt_started = time.monotonic()

            # Cheap connect probe before committing to osmnx (issue #245,
            # closes #240). A host that refuses the socket or does not resolve
            # otherwise costs a fixed 60 s inside osmnx's status-endpoint
            # slot-pause fallback before its first error; the probe fails it
            # over in well under a second. It does NOT catch a host that
            # accepts the socket and then 502s (issue #232) — that stays a
            # full attempt, which is the accepted trade (addendum G4).
            unreachable = probe(endpoint)
            if unreachable is not None:
                _failed(endpoint, attempt, attempt_started, "unreachable",
                        f"connect probe: {unreachable}", backoff=False)
                continue

            # `overpass_rate_limit` is left at its configured value here — no
            # `rate_limit=` argument. The pre-#245 loop set it `False` on
            # every attempt past the first to skip the slot pause on failover;
            # that dropped politeness exactly when we retry hardest (#238
            # mechanism 3), and the connect probe above now removes that
            # latency for the case it actually mattered for.
            try:
                with overpass_settings(url=endpoint):
                    graph = _download_region_graph(region)
            except TRANSIENT_OVERPASS_ERRORS as exc:
                _failed(endpoint, attempt, attempt_started,
                        type(exc).__name__, f"{type(exc).__name__}: {exc}")
                continue
            out_path.parent.mkdir(parents=True, exist_ok=True)
            ox.io.save_graphml(graph, out_path)
            log.info(
                "ensure_graph key=%s endpoint=%s attempt=%d OK: %d nodes, "
                "%d edges, %.1fs total", region.key, endpoint, attempt,
                graph.number_of_nodes(), graph.number_of_edges(),
                time.monotonic() - started)
            return out_path

    tried = ", ".join(failures) if failures else ", ".join(endpoints)
    log.error("ensure_graph key=%s EXHAUSTED all %d endpoints after %.1fs: %s",
              region.key, len(endpoints), time.monotonic() - started, tried)
    raise OverpassUnavailable(
        "Couldn't reach the map-data service to prepare routing for this area. "
        "This is almost always temporary — check your connection and try again "
        f"in a few minutes. (tried: {tried})"
    )
