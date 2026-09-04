"""FastAPI app factory — sidecar mode now, hosted mode later (ARCH §7).

Endpoints invalid for a mode are **not registered**, not merely guarded (§7.1): a
sidecar has no /auth/* routes to attack.

Region- and content-scoped surface built out so far: curation (`/layers`,
`/candidates*`), routing (`/regions`, `/segments/*`), trip composition
(`/days/compose`, `/trips/split`), `/geocode`, and content (`/tiles/{z}/{x}/{y}`).
The rest of §8.2's surface (accounts, group relay, reading — all hosted-mode-only)
is not implemented here. Hosted mode does build M4's seam: a `--web-domain` is
required and every session `Set-Cookie` is routed through one
`SessionCookiePolicy` (first-party `HttpOnly; Secure; SameSite=Lax` on the
shared parent — ARCH §10.3), so the auth endpoints, when built, cannot get it
wrong.
"""

from __future__ import annotations

import logging
import math
import threading
import time
import traceback
import uuid
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path

import osmnx as ox
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field

from plotlines_core.cache_layout import CacheLayout
from plotlines_core.curation.attribution import (
    MissingAttributionError, attributions_for,
)
from plotlines_core.web.about import (
    about_attributions, assert_about_attribution_complete, build_about_surface,
)
from plotlines_core.curation.colocate import (
    DEFAULTS as COLOCATION_DEFAULTS,
    ColocationParams,
    analyze_colocation_full,
    by_corridor_proximity,
    mark_new_against,
    reviewable_cap,
)
from plotlines_core.content.anchor import Anchor
from plotlines_core.curation.defaults import resolve_default_layers
from plotlines_core.curation.notability import RawFeature, RULESET_VERSION, score_notability
from plotlines_core.curation.providers import BBox, OsmLayerProvider
from plotlines_core.curation.registry import build_default_registry
from plotlines_core.elevation.sampler import ElevationSampler
from plotlines_core.graph import regions as region_lib
from plotlines_core.multimodal.modes import TRAVERSAL_MODES
from plotlines_core.osm_identity import apply_osm_http_identity
from plotlines_core.graph.loader import LoadedGraph, load_graphml, nearest_node
from plotlines_core.routing.access import mode_legal_graph
from plotlines_core.routing.diagnose import diagnose
from plotlines_core.routing.loops import (
    Loop, generate_loop, generate_out_and_back, solve_circuit,
)
from plotlines_core.routing.search import probe_envelope
from plotlines_core.routing.solve import NoRouteFound, generate_segment
from plotlines_core.scoring.bands import Band, BandSet, distance_is_advisory
from plotlines_core.scoring.metrics import edge_walk, measure
from plotlines_core.scoring.profile import THEMES, WeightProfile
from plotlines_core.tiles.archive import Archive, valid_zxy
from plotlines_core.tiles.extract import NoTilesInBbox, extract_bbox
from plotlines_core.web.session import SessionCookiePolicy
from plotlines_core.trips.compose import compose_day, split_trip
from plotlines_core.trips.cues import derive_cue_sheet, route_polyline
from plotlines_core.trips.dashboard import build_dashboard
from plotlines_core.trips.hazards import hazard_rollup
from plotlines_core.trips.spine import (
    compose_itinerary,
    distance_outcome,
    recap_spine,
    spine_cues,
    spine_legs_from_polyline,
)
from plotlines_core.trips.payload import Day as PayloadDay
from plotlines_core.trips.payload import Segment as PayloadSegment
from plotlines_core.trips.payload import Transition as PayloadTransition
from plotlines_core.trips.payload import WeightProfile as PayloadWeightProfile

from .payload_io import parse_dataclass
from .tiles_paths import default_home_region_archive
from .version import VERSION

log = logging.getLogger("plotlines.sidecar")

# Heuristic wall-clock estimate for the progress/eta a still-building region
# reports (ARCH §8.3's "terrain data loading — routing available in about 3
# minutes"), not measured telemetry (SPIKE-D is where that would come from)
# — it only keeps the estimate from being a bare guess with no relation to
# elapsed time. A bbox-scoped Overpass fetch + graph build is typically a few
# seconds for an MVP-sized trip area.
GRAPH_ESTIMATED_S = 8.0

# How many region graph builds may run at once. Each build is a full-region
# OSMnx acquisition — Overpass download, `MultiDiGraph` construction,
# `simplify_graph`, and a strong-connectivity prune — which for a county-sized
# bbox is minutes of CPU and ~1.5 GB of memory. Left unbounded, one client that
# ensured several regions at once (e.g. a trip declaring bike + hike + drive, a
# distinct `network_type` graph each) would run them all in parallel, saturate
# every core, and starve the event loop so `GET /health` timed out — at which
# point M12 restarted the sidecar mid-build and the restart re-queued the same
# work. Serialising builds keeps `/health` responsive; a queued build just
# waits its turn. Raise this only with a matching memory budget in mind.
REGION_BUILD_CONCURRENCY = 1

# Minimum wall-clock gap between a settled region-build failure and the next
# *accepted* requeue for the same region key (issue #247; OSM acquisition
# review §5.6, closing #238's second mechanism). Before this, `ensure_region`'s
# `REQUEUE_AFTER_FAILURE` branch had no floor: the client's 2 s `/health` poll
# (and, pre-#246, its per-revision `POST /regions`) could re-run a build the
# instant the last one settled `failed`, so an unreachable Overpass endpoint
# was retried tens of times a minute — the load profile that earns an IP-level
# block (#238's measurements: 22 attempts / 44 requests in 40 minutes). 60 s is
# a small fraction of the 37–117 s graph build it gates and long enough that a
# genuinely-down upstream is not hammered.
REGION_REQUEUE_COOLDOWN_S = 60.0

# Hard ceiling on *automatic* requeues after a settled failure for one region
# key in a session (issue #247). Past this, the `/health`-driven path stops on
# its own and the surfaced reason says so — a dead endpoint is not retried
# forever. The Author's explicit FR121 "Try again" is user-initiated and not
# subject to this cap (acquisition addendum P4: "a user-initiated action that
# fails is re-initiated by the user or not at all"), but it is still cooled by
# REGION_REQUEUE_COOLDOWN_S, with a single bypass per cooldown window so a
# stuck client cannot hold the loop open through it. 3 automatic tries spans a
# transient blip (~3 min at the cooldown) without approaching #238's volume;
# Phase 5 (#284) removes automatic retry mechanically.
REGION_AUTOMATIC_REQUEUE_CAP = 3

# Elevation acquisition is explicitly out of scope for this region-build path
# (issue #154's scoping note): D20/FR85 pin the source to GEDTM30 via
# OpenTopography with no fallback, and that pipeline is gated on FR87 (issue
# #148) — promoting spikes/shared/regions.py's Terrarium fetcher would be a
# second elevation source, which D20 forbids. So `elevation` reports this
# fixed, honest not-ready state for every region rather than ever loading —
# never blocking routing, which needs only the graph (FR121).
#
# When acquisition does land (#148), its cache is already located: the
# separate, bbox-scoped elevation cache at `CacheLayout(cache_dir).elevation_dir`
# (FR94), a sibling of the tile cache, read via
# `plotlines_core.elevation.phase1_resolver_for_layout`.
ELEVATION_NOT_CONFIGURED: dict = {
    "ready": False,
    "reason": "elevation_source_not_configured:tracked_in_148",
}


class CapabilityState:
    """One capability's readiness lifecycle: pending -> loading -> ready|failed.

    Backs the `/health` capability entries (§8.3) that have real startup work
    behind them (graph, elevation) — `tiles` and `layers` have none in this
    codebase and are reported ready inline in `health()` instead.
    """

    def __init__(self, estimated_s: float) -> None:
        self.status = "pending"
        self.detail = ""
        self.started_at: float | None = None
        self.estimated_s = estimated_s

    @property
    def ready(self) -> bool:
        return self.status == "ready"

    @property
    def settled(self) -> bool:
        """Done trying, either way — used to unblock a dependent capability
        without waiting forever on one that failed (FR121: never blocking
        the app)."""
        return self.status in ("ready", "failed")

    def start(self, detail: str) -> None:
        self.status = "loading"
        self.detail = detail
        self.started_at = time.perf_counter()

    def succeed(self, detail: str) -> None:
        self.status = "ready"
        self.detail = detail

    def fail(self, detail: str) -> None:
        self.status = "failed"
        self.detail = detail

    def progress(self) -> float:
        if self.status == "ready":
            return 1.0
        if self.status != "loading" or self.started_at is None or self.estimated_s <= 0:
            return 0.0
        elapsed = time.perf_counter() - self.started_at
        # Capped short of 1.0 — the estimate is a heuristic, never a promise
        # that "loading" is about to flip to "ready".
        return min(0.95, elapsed / self.estimated_s)

    def eta_s(self) -> float | None:
        if self.status != "loading" or self.started_at is None:
            return None
        elapsed = time.perf_counter() - self.started_at
        return max(self.estimated_s - elapsed, 1.0)

    def to_dict(self) -> dict:
        if self.status == "ready":
            return {"ready": True}
        if self.status == "failed":
            return {"ready": False, "reason": f"failed:{self.detail}"}
        if self.status == "loading":
            d: dict = {"ready": False, "reason": self.detail, "progress": round(self.progress(), 2)}
            eta = self.eta_s()
            if eta is not None:
                d["eta_s"] = round(eta, 1)
            return d
        return {"ready": False, "reason": "pending"}


@dataclass(frozen=True)
class RequeueDecision:
    """`RegionState.plan_requeue_after_failure`'s verdict (issue #247).

    `accepted` -> a build is (re)queued now. `reason` is the finished,
    user-facing sentence to hang on the `routing` capability when it is *not*
    (`""` when accepted) — legible on `/health` so an Author who pressed "Try
    again" and saw nothing learns why, rather than pressing it again.
    `bypassed_cooldown` records that this acceptance spent the one manual
    cooldown bypass for the current window.
    """

    accepted: bool
    reason: str = ""
    bypassed_cooldown: bool = False


class RegionState:
    """One Author-declared trip bbox's readiness lifecycle (ARCH §8.3, D41;
    PRD FR120/FR121; issue #154). Replaces the pre-#154 single committed
    Boulder fixture that every trip routed against regardless of its own
    bbox — each region here is built from exactly the bbox that requested
    it, keyed so two requests for "the same" bbox share one build and one
    in-memory graph.

    Elevation is never attempted for a region (see `ELEVATION_NOT_CONFIGURED`
    above) — only `graph_state` gates `routing`.
    """

    def __init__(self, key: str, bbox: tuple[float, float, float, float],
                network_type: str) -> None:
        self.key = key
        self.bbox = bbox
        self.network_type = network_type
        self.graph_state = CapabilityState(GRAPH_ESTIMATED_S)
        self.graph: LoadedGraph | None = None
        self.sampler: ElevationSampler | None = None  # never populated (see module docstring)
        self.tiles_archive: Archive | None = None
        # Build telemetry (issue #232) — every attempt this session, the last
        # failure's full traceback, and per-phase wall-clock. Surfaced by
        # `GET /regions/{key}/diagnostics` and the sidecar log so a build that
        # keeps failing can be root-caused without reading the client UI.
        self.build_attempts = 0
        self.last_error: str | None = None
        self.last_traceback: str | None = None
        self.timings: dict[str, float] = {}
        self.last_attempt_started_at: float | None = None
        self.last_attempt_finished_at: float | None = None
        #: Why the (best-effort, never region-failing) tile extraction did not
        #: produce an archive. `None` means it worked or was never reached.
        self.tiles_error: str | None = None
        # Requeue cooldown/cap bookkeeping (issue #247). `failed_at` is the
        # `time.monotonic()` of the last settled failure; the cooldown is
        # measured from it. `automatic_requeues` counts accepted `/health`-
        # driven requeues since this region was created or last built ok — the
        # cap acts on it. `cooldown_bypassed_at` is when a manual "Try again"
        # last spent its one-per-window cooldown bypass. All three reset on a
        # successful build.
        self.failed_at: float | None = None
        self.automatic_requeues = 0
        self.cooldown_bypassed_at: float | None = None

    @property
    def routing_ready(self) -> bool:
        return self.graph_state.ready

    def routing_capability(self) -> dict:
        d = self.graph_state.to_dict()
        # Additive and only while not ready (a ready region's entry stays
        # byte-identical) — `CapabilityStatus.fromJson` ignores it, but a
        # value that climbs on every `/health` poll is the visible signature
        # of a requeue storm (issue #232).
        if not self.graph_state.ready:
            d["attempts"] = self.build_attempts
        return d

    def requeue_cooldown_remaining(self, now: float) -> float:
        """Seconds left on the post-failure cooldown (issue #247), 0.0 when it
        has elapsed or no failure is on record. `now` is a `time.monotonic()`
        reading, the same clock `build()` stamps `failed_at` with."""
        if self.failed_at is None:
            return 0.0
        return max(0.0, REGION_REQUEUE_COOLDOWN_S - (now - self.failed_at))

    def plan_requeue_after_failure(self, *, manual: bool, now: float) -> RequeueDecision:
        """Decide whether a `POST /regions` for this settled-`failed` region
        may re-queue a build now (issue #247, review §5.6).

        `manual` is set only by the Author's explicit FR121 "Try again"
        (`RegionRequest.retry`); the automatic `/health`-poll path leaves it
        false. The automatic path is hard-capped and always waits out the
        cooldown; the manual path is uncapped (addendum P4) but still cooled,
        with one bypass per cooldown window so it cannot itself become the
        loop.
        """
        if not manual and self.automatic_requeues >= REGION_AUTOMATIC_REQUEUE_CAP:
            return RequeueDecision(
                accepted=False,
                reason=(
                    f"Couldn't prepare routing for this area after "
                    f"{REGION_AUTOMATIC_REQUEUE_CAP} attempts. Automatic retries "
                    f"have stopped; use Try again to retry."
                ),
            )
        remaining = self.requeue_cooldown_remaining(now)
        if remaining <= 0:
            return RequeueDecision(accepted=True)
        if manual and (
            self.cooldown_bypassed_at is None
            or now - self.cooldown_bypassed_at >= REGION_REQUEUE_COOLDOWN_S
        ):
            return RequeueDecision(accepted=True, bypassed_cooldown=True)
        return RequeueDecision(
            accepted=False,
            reason=(
                f"Couldn't prepare routing for this area. Retrying "
                f"automatically in {math.ceil(remaining)} s."
            ),
        )

    def diagnostics(self) -> dict:
        """Everything known about this region's build history (issue #232).
        Capturable with a single `curl .../regions/<key>/diagnostics`, so the
        flickering client notice never has to be read off the screen."""
        return {
            "key": self.key,
            "bbox": list(self.bbox),
            "network_type": self.network_type,
            "state": self.graph_state.status,
            "reason": self.graph_state.detail,
            "attempts": self.build_attempts,
            "timings_s": {k: round(v, 2) for k, v in self.timings.items()},
            "last_attempt_started_at": self.last_attempt_started_at,
            "last_attempt_finished_at": self.last_attempt_finished_at,
            "last_error": self.last_error,
            "last_traceback": self.last_traceback,
            "tiles_error": self.tiles_error,
        }

    def build(self, cache_dir: Path, tiles_upstream: str | Path,
              allow_unmirrored: bool = False) -> None:
        self.build_attempts += 1
        attempt = self.build_attempts
        self.last_attempt_started_at = time.time()
        self.tiles_error = None  # a retry re-attempts tiles too
        t0 = time.monotonic()
        self.graph_state.start("building graph")
        log.info("region build START key=%s attempt=%d bbox=%s nt=%s",
                 self.key, attempt, self.bbox, self.network_type)
        try:
            region = region_lib.Region(key=self.key, bbox=self.bbox,
                                       network_type=self.network_type)
            t_acq = time.monotonic()
            path = region_lib.ensure_graph(region, cache_dir)
            self.timings["ensure_graph"] = time.monotonic() - t_acq
            t_load = time.monotonic()
            self.graph = load_graphml(path)
            self.timings["load_graphml"] = time.monotonic() - t_load
            self.timings["total"] = time.monotonic() - t0
            self.last_error = None
            self.last_traceback = None
            # A clean build clears the requeue cooldown/cap ledger (issue
            # #247): the next failure, if any, starts a fresh window and a
            # fresh count.
            self.failed_at = None
            self.automatic_requeues = 0
            self.cooldown_bypassed_at = None
            self.graph_state.succeed("graph ready")
            log.info("region build OK key=%s attempt=%d timings=%s",
                     self.key, attempt, self.timings)
        except region_lib.OverpassUnavailable as exc:
            # Already a finished, user-facing sentence (issue #229) — surface it
            # verbatim, without the `type(exc).__name__` prefix the generic
            # branch adds. The client renders this reason directly.
            self.timings["total"] = time.monotonic() - t0
            self.last_error = str(exc)
            self.last_traceback = traceback.format_exc()
            self.last_attempt_finished_at = time.time()
            self.failed_at = time.monotonic()  # starts the requeue cooldown (#247)
            self.graph_state.fail(str(exc))
            log.warning("region build FAILED key=%s attempt=%d (overpass): %s",
                        self.key, attempt, exc)
            return
        except Exception as exc:  # noqa: BLE001 — surface honestly, never hang (A6)
            self.timings["total"] = time.monotonic() - t0
            self.last_error = f"{type(exc).__name__}: {exc}"
            self.last_traceback = traceback.format_exc()
            self.last_attempt_finished_at = time.time()
            self.failed_at = time.monotonic()  # starts the requeue cooldown (#247)
            self.graph_state.fail(f"{type(exc).__name__}: {exc}")
            log.error("region build FAILED key=%s attempt=%d: %s\n%s",
                      self.key, attempt, self.last_error, self.last_traceback)
            return  # no graph, no point extracting tiles for this region
        self.last_attempt_finished_at = time.time()

        # Tiles are best-effort and independent of routing (B1: one
        # capability's failure never blocks another) — a bbox outside the
        # configured tile source's coverage leaves `/tiles` to answer
        # honestly per-request (404) rather than wedging region build.
        #
        # The tile cache is the bbox-scoped, on-demand cache FR94 mandates:
        # keyed by the trip bbox alone (`CacheLayout.tile_archive`), a
        # sibling of the elevation cache under one root, and — unlike the
        # graph, which is `regions/<key>/` because it legitimately varies by
        # network type — shared across two trips that drew the same box.
        try:
            tiles_path = CacheLayout(cache_dir).tile_archive(self.bbox)
            if not tiles_path.exists():
                extract_bbox(tiles_upstream, self.bbox, tiles_path,
                             allow_unmirrored=allow_unmirrored)
            self.tiles_archive = Archive(tiles_path)
        except NoTilesInBbox:
            # Expected: the bbox is outside the tile source's coverage. `/tiles`
            # answers 404 per-request; nothing to report.
            log.info("region tiles: no coverage key=%s bbox=%s", self.key, self.bbox)
        except Exception as exc:  # noqa: BLE001 — tiles are best-effort; never fail the region for this
            # Best-effort, but not silent (issue #232): this was the one branch
            # in `build` that swallowed a failure without a trace, so a region
            # that routed fine but showed no basemap had nothing to explain it.
            self.tiles_error = f"{type(exc).__name__}: {exc}"
            log.warning("region tiles FAILED key=%s bbox=%s: %s\n%s",
                        self.key, self.bbox, self.tiles_error, traceback.format_exc())


class Readiness:
    """The sidecar's region registry (ARCH §8.3, breaking change B1; PRD
    FR120/FR121). Before #154, one `Readiness` loaded one committed graph at
    process startup and every request used it regardless of its own
    coordinates; now each Author-declared trip bbox gets its own `RegionState`,
    built on demand by `POST /regions` and looked up by key on every
    `/segments/*` call.

    Layer/POI and tile-from-the-committed-archive capabilities have no
    per-region startup dependency and are reported ready unconditionally in
    `health()` — they were never gated on this class (B1's whole point).
    """

    def __init__(self, cache_dir: Path, tiles_upstream: str | Path,
                 allow_unmirrored: bool = False) -> None:
        self.cache_dir = cache_dir
        self.tiles_upstream = tiles_upstream
        self.allow_unmirrored = allow_unmirrored
        self.regions: dict[str, RegionState] = {}
        self._lock = threading.Lock()
        self.started_at = time.perf_counter()
        # Serialise region builds (REGION_BUILD_CONCURRENCY) so a burst of
        # `ensure_region` calls can no longer peg every core at once and
        # starve `/health`. A queued build simply waits its turn.
        self._build_pool = ThreadPoolExecutor(
            max_workers=REGION_BUILD_CONCURRENCY,
            thread_name_prefix="region-build",
        )

    def shutdown(self) -> None:
        """Stop accepting builds and abandon any still queued. In-flight
        builds are left to finish (or be killed with the process); this
        only exists so a test / hosted-mode reload does not leak the pool."""
        self._build_pool.shutdown(wait=False, cancel_futures=True)

    def ensure_region(self, bbox: tuple[float, float, float, float],
                      network_type: str = "bike", *, manual: bool = False) -> str:
        """Idempotent: a second call with the same (bbox, network_type)
        returns the same key without starting a second build. Builds are
        queued onto a bounded pool (REGION_BUILD_CONCURRENCY), so a second
        *distinct* region ensured while one is still building waits rather
        than competing for CPU.

        `manual=True` marks the Author's explicit FR121 "Try again"
        (`RegionRequest.retry`), which the automatic `/health`-poll path never
        sets. It is what earns the one-per-window cooldown bypass and is not
        subject to the automatic-requeue cap (issue #247)."""
        key = region_lib.region_key(bbox, network_type)
        with self._lock:
            region = self.regions.get(key)
            if region is None:
                region = RegionState(key, bbox, network_type)
                self.regions[key] = region
                self._queue_build(region)
                log.info("ensure_region key=%s bbox=%s nt=%s decision=NEW_BUILD",
                         key, bbox, network_type)
            elif region.graph_state.status == "failed":
                # A settled failure (typically Overpass unreachable, issue
                # #229) is retryable, but not without limit (issue #247): a
                # cooldown floors the interval between a failure and the next
                # accepted requeue, and a cap stops the automatic path once a
                # dead endpoint has been retried enough. A build already
                # re-queued reads as "pending"/"loading", not "failed", so a
                # rapid double call won't stack two builds.
                decision = region.plan_requeue_after_failure(
                    manual=manual, now=time.monotonic())
                if decision.accepted:
                    if not manual:
                        region.automatic_requeues += 1
                    elif decision.bypassed_cooldown:
                        region.cooldown_bypassed_at = time.monotonic()
                    log.info(
                        "ensure_region key=%s nt=%s decision=REQUEUE_AFTER_FAILURE "
                        "(prior attempts=%d, manual=%s, bypass=%s, auto_requeues=%d, "
                        "last_error=%r)", key, network_type, region.build_attempts,
                        manual, decision.bypassed_cooldown, region.automatic_requeues,
                        region.last_error)
                    region.graph_state = CapabilityState(GRAPH_ESTIMATED_S)
                    self._queue_build(region)
                else:
                    # Leave the region `failed`, but make the wait legible on
                    # `/health` (FR121's "stated reason") — an Author who
                    # pressed "Try again" and saw nothing must not be left
                    # guessing, or they press it again.
                    region.graph_state.fail(decision.reason)
                    log.info(
                        "ensure_region key=%s nt=%s decision=REQUEUE_REFUSED "
                        "(manual=%s, auto_requeues=%d) %s", key, network_type,
                        manual, region.automatic_requeues, decision.reason)
        return key

    def _queue_build(self, region: "RegionState") -> None:
        self._build_pool.submit(
            region.build,
            self.cache_dir, self.tiles_upstream, self.allow_unmirrored,
        )

    def region(self, key: str) -> RegionState | None:
        with self._lock:
            return self.regions.get(key)

    def snapshot(self) -> list[tuple[str, "RegionState"]]:
        """A point-in-time `(key, region)` list, taken under the lock.

        Every reader outside `ensure_region` goes through this. `ensure_region`
        inserts under `_lock` but FastAPI runs sync endpoints on a threadpool,
        so an unlocked `.items()` / `.values()` walk elsewhere really does race
        a concurrent `POST /regions` and raises `RuntimeError: dictionary
        changed size during iteration`. That lands on `GET /health` — the one
        endpoint M12's `sidecar_manager` polls and restarts the sidecar over —
        which is the same restart loop #224 and #232 closed from the other
        side. Serialising builds kept `/health` responsive; this keeps it from
        failing outright.

        A shallow copy is enough: `RegionState` mutates its own fields in
        place, and reading a half-updated capability is a stale answer, never
        a crash.
        """
        with self._lock:
            return list(self.regions.items())

    def routing_capabilities(self) -> dict:
        """§8.3's per-region `routing` breakdown — empty until an Author has
        drawn a trip bbox and the client has called `POST /regions`."""
        return {key: region.routing_capability() for key, region in self.snapshot()}


class Coordinate(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class RegionRequest(BaseModel):
    """FR120/D41 — the Author's trip bbox, ensuring a routable graph exists
    for exactly that area (issue #154). `bbox` is [west, south, east, north]
    (osmnx order)."""

    bbox: list[float] = Field(min_length=4, max_length=4)
    network_type: str = "bike"
    #: Issue #247 — set only by the Author's explicit FR121 "Try again". Grants
    #: a settled-`failed` region one cooldown bypass per window and exempts the
    #: request from the automatic-requeue cap. The automatic settle-window /
    #: `/health`-poll path leaves it false and always waits the cooldown out.
    retry: bool = False


class SegmentRequest(BaseModel):
    # The trip's bbox key from `POST /regions` (D41: there is never a
    # *second, different* extent for analysis) — routing runs against
    # exactly this region's graph, never a process-wide default.
    region: str
    start: Coordinate
    # Required for shape=point_to_point; an out_and_back turnaround the Author
    # picked by hand; ignored for shape=loop (FR7/A7 — shape is independent
    # of weights, and a loop closes on `start` by definition).
    end: Coordinate | None = None
    via: list[Coordinate] = Field(default_factory=list)
    mode: str = "cycling"
    # One of loop | out_and_back | point_to_point (FR7/A7). Loop is the
    # AC-stated default — the shape needing only a start, no destination.
    shape: str = "loop"
    theme: str = "balanced"
    weights: dict[str, float] | None = None
    # Required for shape=loop; for out_and_back it's an envelope target used
    # only when `end` is absent (FR8/A8 — banded, never a soft target, but a
    # single-request generate has nowhere to carry a band, so this is the
    # point estimate a band would center on).
    target_m: float | None = None


class GeometryInput(BaseModel):
    coordinates: list[list[float]] = Field(default_factory=list)


class NodeInput(BaseModel):
    id: str
    kind: str
    coord: list[float] | None = None
    distance_along_m: float | None = None
    title: str | None = None
    instructions: str | None = None
    # C5 / F1 (FR133) — water, toilets, food, shelter. Woven into the cue's
    # own instruction text by `cues.node_cues`, not carried as a separate
    # logistics list.
    amenities: list[str] = Field(default_factory=list)


class HazardInput(BaseModel):
    id: str
    severity: str
    coord: list[float] | None = None
    distance_along_m: float | None = None
    title: str | None = None
    safety_note: str | None = None


class PortageInput(BaseModel):
    id: str
    geometry: GeometryInput
    exit_bank: str | None = None
    mandatory: bool = False
    distance_m: float | None = None


class AlternateInput(BaseModel):
    id: str
    kind: str
    geometry: GeometryInput
    label: str | None = None
    diverges_at_m: float | None = None


class CuesRequest(BaseModel):
    """F1/FR46 — re-solves the same request `/segments/generate` would (this
    endpoint trusts nothing the client sends about geometry, the same way
    `/segments/envelope` and `/segments/diagnose` don't either), then derives
    cues against the real graph and the Author's curated content.
    """

    region: str
    start: Coordinate
    end: Coordinate | None = None
    via: list[Coordinate] = Field(default_factory=list)
    # FR7/A7 — same default as `SegmentRequest.shape`.
    shape: str = "loop"
    theme: str = "balanced"
    weights: dict[str, float] | None = None
    target_m: float | None = None
    mode: str = "cycling"
    segment_id: str | None = None
    nodes: list[NodeInput] = Field(default_factory=list)
    hazards: list[HazardInput] = Field(default_factory=list)
    portages: list[PortageInput] = Field(default_factory=list)
    alternates: list[AlternateInput] = Field(default_factory=list)


class DayComposeRequest(BaseModel):
    """B2/D1/C3 — `compose_day` is the only supported way to build a day's
    derived half (ARCH §6.1): transition gap warnings and the roll-up. Raw
    `dict`s rather than typed pydantic mirrors of the payload tree — the
    client already validates this shape against `trip_payload.schema.json`
    before it ever sends it, and `payload_io.parse_dataclass` is what turns
    it into the real dataclasses `compose_day` needs.
    """

    segments: list[dict] = Field(default_factory=list)
    transitions: list[dict] = Field(default_factory=list)
    index: int = 1
    kind: str = "route"

    # E3 / FR39 / FR117 / FR118 (issue #214) — compose mode's places-first
    # derived views. `anchors` is the day's spine in the Author's chosen
    # order (the promoted anchors the single compose passage's `via` points
    # stand for); `target_m` is what the Author had in mind, if anything, so
    # A0a's `DistanceOutcome` can quantify the miss. With fewer than two
    # anchors the response carries no `itinerary`/`recap`/`cues` block —
    # there is no spine to organise the day around yet.
    anchors: list[dict] = Field(default_factory=list)
    target_m: float | None = None


class TripSplitRequest(BaseModel):
    """C3 — assemble days into a trip and apply per-mode day limits. Despite
    the ARCH §7.2 endpoint name, this assembles rather than splits — see
    `trips/compose.py`'s `split_trip` docstring for why the name stuck."""

    days: list[dict] = Field(default_factory=list)
    title: str = "Untitled plotline"
    limits: dict[str, dict[str, float]] | None = None
    default_weights: dict | None = None

    # D1 / FR31 / FR16 (issue #213) — the planning dashboard's time-model
    # inputs. All optional: with none of them the `dashboard` block the
    # response also carries is the distance/elevation panel D1's first AC
    # line requires, and the moving-time / elapsed-time / ETA fields stay
    # unset. `build_dashboard` owns what each one means.
    active_segment_id: str | None = None
    speeds: dict[str, float] | None = None
    day_hold_s: dict[str, float] | None = None
    day_start_at: dict[str, str] | None = None
    trip_start_at: str | None = None


class EnvelopeRequest(BaseModel):
    """A5 — the range this graph can actually deliver at this distance, so band
    sliders open on an attainable range rather than an abstract 0-5 (SPIKE-03).
    Loop shape only: `probe_envelope` walks the archetype set through
    `generate_loop`, which is the shape SPIKE-01/02/03 built band-awareness for.
    """

    region: str
    start: Coordinate
    via: list[Coordinate] = Field(default_factory=list)
    target_m: float = Field(gt=0)
    mode: str = "cycling"


class BandInput(BaseModel):
    metric: str
    minimum: float | None = None
    maximum: float | None = None


class DiagnoseRequest(BaseModel):
    region: str
    start: Coordinate
    via: list[Coordinate] = Field(default_factory=list)
    target_m: float = Field(gt=0)
    bands: list[BandInput]
    mode: str = "cycling"


class CandidateFeatureInput(BaseModel):
    """A raw LayerProvider feature (ARCH §14.2) awaiting notability scoring.
    Extraction itself (bbox -> raw features, e.g. via Overpass) is a
    LayerProvider concern outside this endpoint's contract; this scores
    whatever features the caller already holds."""

    id: str
    coord: list[float] = Field(min_length=2, max_length=2)
    tags: dict[str, str] = Field(default_factory=dict)
    area_m2: float | None = None


class CandidatesScoreRequest(BaseModel):
    """FR98 — score raw features against the live layer set. `live_layers`
    is the Author's per-trip/per-day selection (FR97), not the full catalog:
    a feature whose layer isn't live never becomes a candidate."""

    live_layers: list[str]
    features: list[CandidateFeatureInput] = Field(default_factory=list)


class ColocationParamsInput(BaseModel):
    """Optional overrides for `curation.colocate.ColocationParams` — SPIKE-B's
    tuned defaults apply for any field left unset. Data, not code (same
    discipline as the notability ruleset), so a later region can adjust a
    knob without a release."""

    max_diameter_m: float | None = None
    tightness_scale_m: float | None = None
    tightness_floor: float | None = None
    min_member_salience: float | None = None
    min_cluster_score: float | None = None
    corridor_decay_m: float | None = None
    cap_floor: int | None = None
    cap_per_route_km: float | None = None


class ClustersAnalyzeRequest(BaseModel):
    """FR102–FR105a, story N4 — co-location analysis as a **named Author
    action over a fixed bbox** (never ambient over a viewport). Extracts the
    bbox's candidates across `layers` (one failing layer never fails the
    run — same subtract-not-abort as `/candidates`), clusters across the
    live heterogeneous layers, and returns ranked, capped proposals.
    """

    bbox: list[float] = Field(min_length=4, max_length=4)  # [w, s, e, n]
    layers: list[str]
    #: Optional lon/lat polyline of an existing route — enables
    #: `distance_to_route_m` on every proposal, the corridor filter, the
    #: `sort=corridor` resort, and grows the reviewable cap by route-km.
    route: list[list[float]] = Field(default_factory=list)
    #: Member-id sets the Author has already rejected for this trip (ARCH
    #: §4.4's small rejection set). A fresh cluster matching one is dropped,
    #: so a re-run does not re-propose it (FR110).
    rejected: list[list[str]] = Field(default_factory=list)
    #: Member-id sets from the previous run — proposals not matching one are
    #: flagged `is_new` (N4a: "marks which proposals are new since the last
    #: run").
    previous: list[list[str]] = Field(default_factory=list)
    #: `rank` (default, combined salience × tightness) | `corridor` (resort
    #: pulling corridor-adjacent proposals up — an opt-in view, never the
    #: default, SPIKE-B/Q12).
    sort: str = "rank"
    params: ColocationParamsInput | None = None


class DiagnoseJob:
    def __init__(self, created_at: float) -> None:
        self.done = False
        self.result: dict | None = None
        self.error: str | None = None
        self.created_at = created_at


# How many diagnoses may run at once, and how many finished results are kept
# for the client to poll.
#
# Same reasoning as REGION_BUILD_CONCURRENCY, one endpoint over: SPIKE-02
# measured diagnose at 1.3-15.0s of CPU against 27-218ms to solve, so an
# unbounded thread per request lets a retry loop saturate every core and starve
# `/health` — the Buncombe failure mode, reached by a different door. Two at a
# time keeps a second Author-initiated diagnosis from queueing behind a slow
# one without putting the box under load.
#
# The registry is bounded too. It used to be a plain dict that was written on
# every request and never pruned, so each diagnosis retained a full result dict
# for the life of the process. `DIAGNOSE_JOB_TTL_S` is the window a client has
# to collect its result (the client polls every ~500ms, so this is generous);
# `DIAGNOSE_JOB_CAP` is the hard backstop that bounds memory regardless of TTL.
DIAGNOSE_CONCURRENCY = 2
DIAGNOSE_JOB_TTL_S = 300.0
DIAGNOSE_JOB_CAP = 64


class DiagnoseRegistry:
    """Bounded, self-pruning store for `/segments/diagnose` jobs.

    Eviction runs on submit, never on a timer: a sidecar that is not being
    asked to diagnose does not need to be doing anything. Finished jobs older
    than the TTL go first; if that still leaves more than the cap, the oldest
    are dropped regardless of age — a client that never polls cannot pin
    memory. An in-flight job is never evicted by age, only by the cap, and
    only once it is the oldest thing there is.
    """

    def __init__(self, ttl_s: float = DIAGNOSE_JOB_TTL_S,
                 cap: int = DIAGNOSE_JOB_CAP) -> None:
        self._jobs: dict[str, DiagnoseJob] = {}
        self._lock = threading.Lock()
        self._ttl_s = ttl_s
        self._cap = cap
        self._pool = ThreadPoolExecutor(
            max_workers=DIAGNOSE_CONCURRENCY, thread_name_prefix="diagnose",
        )

    def submit(self, run: "Callable[[DiagnoseJob], None]", *, now: float | None = None) -> str:
        now = time.monotonic() if now is None else now
        job_id = str(uuid.uuid4())
        job = DiagnoseJob(created_at=now)
        with self._lock:
            self._jobs[job_id] = job
            self._evict(now)

        def settle() -> None:
            # `done` is the registry's guarantee, not the caller's: the poll
            # endpoint answers "pending" until it flips, so a worker that died
            # on a path its own `finally` didn't cover would leave the client
            # polling forever.
            try:
                run(job)
            finally:
                job.done = True

        self._pool.submit(settle)
        return job_id

    def get(self, job_id: str) -> DiagnoseJob | None:
        with self._lock:
            return self._jobs.get(job_id)

    def _evict(self, now: float) -> None:
        # Caller holds the lock.
        for key, job in list(self._jobs.items()):
            if job.done and now - job.created_at > self._ttl_s:
                del self._jobs[key]
        if len(self._jobs) <= self._cap:
            return
        oldest = sorted(self._jobs.items(), key=lambda kv: kv[1].created_at)
        for key, _job in oldest[: len(self._jobs) - self._cap]:
            del self._jobs[key]

    def shutdown(self) -> None:
        self._pool.shutdown(wait=False, cancel_futures=True)

    def __len__(self) -> int:
        with self._lock:
            return len(self._jobs)


def create_app(cache_dir: Path, mode: str = "sidecar", *,
               tiles_upstream: str | Path | None = None,
               allow_unmirrored_tiles: bool = False,
               web_domain: str | None = None) -> FastAPI:
    # Issue #241 — stamp the contactable Plotlines UA/referer on every
    # Overpass and Nominatim call this app makes (region graph builds,
    # candidate fetches, and `/geocode`) before the first request goes out.
    # Both modes and both transports read the same two `ox.settings` fields,
    # so this one call at the app factory covers all of them with the real
    # build version.
    apply_osm_http_identity(VERSION)

    # Issue #242 — point osmnx's Overpass/Nominatim response cache inside the
    # Plotlines cache root here, at the app factory, rather than only inside
    # `ensure_graph` past its warm-cache early return. `/candidates` and
    # `/geocode` never call `ensure_graph`, so before this they ran with
    # `ox.settings.cache_folder` at its CWD-relative `./cache` default and
    # littered stray responses (issue #154) where nothing would read them
    # back — including the geocode results the Nominatim policy asks us to
    # cache. One call covers all three osmnx-mediated transports, like the
    # UA setup above.
    region_lib.configure_overpass_cache(cache_dir)

    state = Readiness(cache_dir, tiles_upstream or default_home_region_archive(),
                      allow_unmirrored=allow_unmirrored_tiles)

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        yield
        # Abandon any region builds still queued so the pool's worker thread
        # can't outlive the app (matters for a test / hosted-mode reload; the
        # sidecar itself is signal-killed). Same for queued diagnoses.
        state.shutdown()
        diagnose_jobs.shutdown()

    app = FastAPI(title="plotlines-service", version=VERSION, lifespan=lifespan)
    app.state.readiness = state

    home_tiles = Archive(default_home_region_archive())
    home_tiles_identity = home_tiles.info().identity
    diagnose_jobs = DiagnoseRegistry()
    # Both worker pools hang off `app.state`, like `readiness` above, so a
    # hosted reload can shut them down without reaching into the closure.
    app.state.diagnose_jobs = diagnose_jobs

    @app.get("/health")
    def health() -> dict:
        """Per-capability readiness (ARCH §8.3, breaking change B1; PRD
        FR120/FR121; issue #154, story N2). No single `ready` flag: `tiles`
        reports ready unconditionally (no process-wide startup dependency —
        the Curation Workspace must be usable immediately). `tiles.archive`
        is a short content fingerprint of the committed home-region PMTiles
        archive (issue #155): the client folds it into its raster tile-cache
        folder so renders derived from a superseded archive are dropped
        rather than served stale for the 30-day cache TTL.

        `layers` is driven by `app.state.layer_registry` (story N2): a real
        per-layer state machine, not a constant. `layers.ready` is **`any`,
        not `all`** — the capability is ready once any layer is usable, so
        one slow or remote plugin dataset never re-imposes the global flag
        B1 removed. `per_layer` carries `ready` / `loading` /
        `failed:<reason>` per layer, and `per_layer_detail` adds the
        picker's longer form (observed progress while loading, never a fixed
        ETA — acquisition runs ×2.96 slower while the Author works).

        `routing` is **per region** (D41), keyed by the region id
        `POST /regions` returned; empty until an Author has drawn a bbox.
        `elevation` is a fixed not-ready state for every region (see
        `ELEVATION_NOT_CONFIGURED`) — never blocking routing, which needs
        only the graph. A failing region build never touches `layers`.

        Version-mismatch refusal (A8, M12) is unchanged and lives entirely
        client-side in `SidecarManager.start()`, before the sidecar is even
        spawned — `/health` was never part of that check and still isn't.
        """
        registry = app.state.layer_registry
        layers_cap = registry.capability()
        layers_cap["per_layer_detail"] = registry.per_layer_detail()
        body = {
            "app_version": VERSION,
            "sidecar_version": VERSION,
            "mode": mode,
            "capabilities": {
                "tiles": {"ready": True, "archive": home_tiles_identity},
                "layers": layers_cap,
                "routing": {"regions": state.routing_capabilities()},
                "elevation": ELEVATION_NOT_CONFIGURED,
            },
        }
        # Hosted mode only: the same-site session contract (story M4). A
        # sidecar has no accounts and no `web` block — the key's absence is
        # itself the signal that this is loopback.
        policy = getattr(app.state, "session_cookie", None)
        if policy is not None:
            body["web"] = {
                "parent_domain": policy.parent_domain,
                "cookie": {"same_site": "Lax", "secure": True, "http_only": True},
            }
        return body

    @app.post("/regions", status_code=202)
    def regions_ensure(req: RegionRequest) -> dict:
        """FR120/D41, ARCH D25's 202-and-poll house style applied to region
        acquisition — issue #154. Idempotent: an Author revising the same
        bbox again (or a second client call for a bbox already ensured)
        returns the same key without starting a second build. Poll
        `GET /health`'s `capabilities.routing.regions[key]` for progress.
        """
        bbox = tuple(req.bbox)
        key = state.ensure_region(bbox, req.network_type, manual=req.retry)
        return {"region": key}

    @app.get("/regions/{key}/diagnostics")
    def region_diagnostics(key: str) -> dict:
        """Issue #232 — the full build history for one region: attempt count,
        per-phase timings, and the last failure's complete traceback (which
        `/health` deliberately does not carry). Read this to root-cause a
        region that keeps failing or never settles, without reading the
        client's disabled-control notice off the screen."""
        region = state.region(key)
        if region is None:
            raise HTTPException(status_code=404, detail=f"no region {key!r}")
        return region.diagnostics()

    # The layer registry (ARCH §8.3 / §14.2, stories N2/N5). Holds the six
    # built-in OSM layers and every plugin layer discovered via the
    # `plotlines.layer_providers` entry point, each with its own readiness
    # lifecycle and its own `LayerLicence`. On `app.state` so a test can
    # substitute one with no plugins / a fake OSM engine. `cache_layout`
    # gives the built-in OSM layers the on-disk candidate cache (issue #243,
    # FR94) so a sidecar restart mid-build does not throw the extract away.
    app.state.layer_registry = build_default_registry(
        cache_layout=CacheLayout(cache_dir))

    @app.get("/layers")
    def layers(mode: str = "cycling", day_type: str = "route") -> dict:
        """FR97 / FR100 / FR101 — the layer catalog (built-in OSM plus any
        loaded plugin dataset), each entry carrying its licence and
        attribution metadata and its per-layer readiness state, plus this
        (mode, day type) pair's default live set.

        Deliberately independent of the graph/elevation loading state tracked
        in `Readiness`: layer/POI capability comes up ahead of elevation
        (ARCH B1/D34/§8.3), and the Curation Workspace must be usable while
        enrichment still runs."""
        registry = app.state.layer_registry
        detail = registry.per_layer_detail()
        credits = {a.layer: a for a in attributions_for(registry)}
        catalog = []
        for layer in registry.known_layers():
            d = detail.get(layer, {})
            cred = credits.get(layer)
            catalog.append({
                "id": layer,
                "builtin": bool(d.get("builtin")),
                "state": d.get("state", "ready"),
                "version": d.get("version", ""),
                "licence": (
                    {"id": cred.licence_id, "attribution": cred.attribution,
                     "terms_url": cred.terms_url}
                    if cred is not None else None
                ),
                **({"reason": d["reason"]} if "reason" in d else {}),
                **({"progress": d["progress"]} if "progress" in d else {}),
            })
        return {
            "layers": registry.known_layers(),
            "catalog": catalog,
            "default_live": sorted(resolve_default_layers(mode, day_type)),
            "ruleset_version": RULESET_VERSION,
        }

    @app.get("/attribution")
    def attribution() -> dict:
        """FR95 / FR101 / ARCH §12.2 — attribution derived from the *loaded*
        layer set, not hardcoded. The About surface (K10), exports where the
        format permits, and printed itineraries / cue sheets all read this.
        `complete` is the release-gate answer: false with `missing` naming
        the offenders means a build failure, not a render-time warning.

        Elevation's CC BY line (FR86) and the basemap's ODbL `© OpenStreetMap`
        line (FR95, story M11) are always present — both ship with the home
        region — and are **separate obligations** under different licences,
        carried here so every export/print surface reads one source rather than
        a hardcoded credit list."""
        registry = app.state.layer_registry
        lines = about_attributions(registry)
        try:
            assert_about_attribution_complete(registry)
            complete, missing = True, []
        except MissingAttributionError as exc:
            complete = False
            missing = str(exc).split(": ", 1)[-1].split(", ")
        return {"attributions": lines, "complete": complete, "missing": missing}

    @app.get("/about")
    def about() -> dict:
        """K10 + K11 (issues #116/#117; FR86, FR95, FR101, FR138) — the About
        surface payload in one document: the running app version and (desktop)
        the sidecar version matching `/health`, every licensed source's
        attribution (elevation CC BY, basemap ODbL, and a line per loaded
        plugin layer), and the plain-language privacy statement that must be
        reachable from About on every platform, including Web guest and the
        share-token reading view.

        `attribution_complete` is the release-gate answer; a missing credit is
        a build failure (the build check calls `assert_about_attribution_complete`
        directly and raises)."""
        registry = app.state.layer_registry
        return build_about_surface(
            registry,
            app_version=VERSION,
            sidecar_version=VERSION if mode == "sidecar" else None,
            mode=mode,
        ).as_dict()

    def _candidates_response(candidates: list) -> dict:
        return {
            "ruleset_version": RULESET_VERSION,
            "candidates": [
                {
                    "id": c.id,
                    "coord": list(c.coord),
                    "layer": c.layer,
                    "salience": c.salience,
                    "role_affinity": c.role_affinity,
                    "title": c.title,
                    "tags": dict(c.tags),
                }
                for c in candidates
            ],
        }

    @app.post("/candidates/score")
    def candidates_score(req: CandidatesScoreRequest) -> dict:
        """FR98/FR99 — notability-filter and salience-score raw features
        against the caller's live layer selection. Unrecognized types and
        types that fail their qualification gate are omitted, not scored
        low (FR98(b))."""
        try:
            features = [
                RawFeature(id=f.id, coord=(f.coord[0], f.coord[1]), tags=f.tags,
                           area_m2=f.area_m2)
                for f in req.features
            ]
        except IndexError as exc:
            raise HTTPException(422, f"bad feature coord: {exc}") from exc
        candidates = score_notability(features, live_layers=req.live_layers)
        return _candidates_response(candidates)

    # Kept for backward compatibility with callers that predate the registry;
    # `/candidates` itself now goes through `app.state.layer_registry` so a
    # single failing layer never aborts the whole extraction (story N2).
    app.state.layer_provider = OsmLayerProvider()

    @app.get("/candidates")
    def candidates_extract(west: float, south: float, east: float, north: float,
                           layers: str) -> dict:
        """ARCH §8.2 endpoint surface, FR98/FR99, story N2 — extracts and
        notability-filters a bbox's features across the requested live
        layers. `layers` is a comma-separated live-layer set (FR97's Author
        selection).

        **One failing layer never fails the request** (SPIKE-D #159): the
        response returns the candidates from every layer that served,
        `layers_served` naming them, and `layers_unavailable` mapping each
        layer that did not to its reason (`loading`, `failed:<reason>`,
        `unknown_layer`). A request with no live layers at all is the only
        422 — that is a malformed request, not an empty area.

        Synchronous for MVP: ARCH §7.2 describes this as a job for a large
        multi-day bbox; a future pass can make it async without changing
        what it returns.
        """
        live = {layer for layer in layers.split(",") if layer}
        if not live:
            raise HTTPException(422, "no live layers requested")
        registry = app.state.layer_registry
        candidates, errors = registry.fetch_candidates_all(
            BBox(west, south, east, north), live)
        body = _candidates_response(candidates)
        body["layers_served"] = sorted(live - set(errors))
        body["layers_unavailable"] = errors
        return body

    def _colocation_params(inp: "ColocationParamsInput | None") -> ColocationParams:
        if inp is None:
            return COLOCATION_DEFAULTS
        overrides = {k: v for k, v in inp.model_dump().items() if v is not None}
        if not overrides:
            return COLOCATION_DEFAULTS
        base = COLOCATION_DEFAULTS
        return ColocationParams(**{
            f: overrides.get(f, getattr(base, f))
            for f in (
                "max_diameter_m", "tightness_scale_m", "tightness_floor",
                "min_member_salience", "min_cluster_score", "corridor_decay_m",
                "cap_floor", "cap_per_route_km",
            )
        })

    def _proposal_to_dict(p) -> dict:
        return {
            "id": p.id,
            "name": p.name,
            "kind": p.kind,
            "role_affinities": list(p.role_affinities),
            "members": [
                {
                    "candidate_id": m.candidate_id,
                    "layer": m.layer,
                    "type": m.type,
                    "title": m.title,
                    "salience": m.salience,
                    "role_affinity": m.role_affinity,
                }
                for m in p.members
            ],
            "centroid": list(p.centroid),
            "extent_m": p.extent_m,
            "tightness": p.tightness,
            "salience_score": p.salience_score,
            "rank_score": p.rank_score,
            "distance_to_route_m": p.distance_to_route_m,
            "is_new": p.is_new,
        }

    @app.post("/clusters/analyze")
    def clusters_analyze(req: ClustersAnalyzeRequest) -> dict:
        """ARCH §8.2, FR102–FR105a, story N4 — "find the good spots".

        A named Author action over the trip bbox: extract the bbox's
        candidates across the live layers, find spatial clusters across the
        heterogeneous layers, score each by combined salience (noisy-OR) ×
        tightness, propose a role set from the affinity union of its members
        (FR105 — a plugin layer's types participate on the day they load),
        and return the ranked list **capped** (FR105a) with the count beyond
        the cap always reported, never silently truncated.

        Separate from `/candidates` for the same reason `/segments/envelope`
        is separate from `/segments/generate` (D26): expensive, cacheable,
        and triggered by a distinct intent. It never writes canon (ARCH P10)
        — a proposal is reviewed and promoted or rejected, never auto-added.
        """
        west, south, east, north = req.bbox
        bbox = BBox(west, south, east, north)
        registry = app.state.layer_registry
        live = {l for l in req.layers if l}
        if not live:
            raise HTTPException(422, "no live layers requested")
        if req.sort not in ("rank", "corridor"):
            raise HTTPException(422, f"unknown sort {req.sort!r}")

        candidates, errors = registry.fetch_candidates_all(bbox, live)
        params = _colocation_params(req.params)
        route = [(pt[0], pt[1]) for pt in req.route] if len(req.route) >= 2 else None
        rejected = [frozenset(s) for s in req.rejected]

        proposals, n_beyond = analyze_colocation_full(
            candidates, bbox, params, route=route, rejected=rejected)
        if req.previous:
            proposals = mark_new_against(
                proposals, [frozenset(s) for s in req.previous])
        if req.sort == "corridor":
            proposals = by_corridor_proximity(proposals, params)

        return {
            "ruleset_version": RULESET_VERSION,
            "bbox": list(req.bbox),
            "sort": req.sort,
            "cap": reviewable_cap(params, route),
            "n_beyond_cap": n_beyond,
            "n_candidates": len(candidates),
            "layers_served": sorted(live - set(errors)),
            "layers_unavailable": errors,
            "proposals": [_proposal_to_dict(p) for p in proposals],
        }

    def _resolve_profile(theme: str, weights: dict[str, float] | None) -> WeightProfile:
        if weights:
            try:
                return WeightProfile(name=theme or "custom", **weights)
            except (TypeError, ValueError) as exc:
                raise HTTPException(422, f"bad weights: {exc}") from exc
        if theme in THEMES:
            return THEMES[theme]
        # FR130 / B1 — a traversal mode's own default profile is nameable here,
        # so a mountain-biking or driving passage can be solved with the weights
        # its registry row carries and no second scorer. The named-theme
        # catalogue still wins; only a string that is neither a theme nor a mode
        # is an error.
        mode_profile = TRAVERSAL_MODES.get(theme)
        if mode_profile is not None:
            return mode_profile.weights
        raise HTTPException(422, f"unknown theme {theme!r}")

    def _loop_to_dict(graph, loop: Loop, mode: str, theme: str, shape: str,
                      sampler: ElevationSampler | None,
                      *, target_advisory: bool = False) -> dict:
        """Shapes a `Loop` (routing/loops.py) into the same response family
        `Segment.to_dict()` (routing/solve.py) returns, plus the loop-specific
        fields (`closed`, `hit_via`, `target_m`) point_to_point has no opinion
        about. `route_polyline` — not a straight node-to-node line — because
        it's already needed for cue derivation elsewhere and gives the client
        the real curved way geometry rather than SPIKE-00's simplification.

        `target_advisory` (A9a/FR8a) is set by the caller when three or more
        via-anchors fixed the loop's length: `target_m`/`distance_error` are
        still reported, but the client presents the deviation as an editing
        decision (A0a) routed through `/segments/diagnose`, not as a missed
        constraint.
        """
        route = route_polyline(graph, loop.walk)
        coords_latlon = [(lat, lon) for lon, lat in route.coords]
        elevation = sampler.profile(coords_latlon) if sampler else {}
        return {
            "mode": mode,
            "theme": theme,
            "distance_m": round(loop.metrics.distance_m, 1) if loop.metrics else 0.0,
            "coordinates": route.coords,
            "elevation": elevation,
            "node_count": len(loop.path),
            "solve_ms": round(loop.solve_ms, 2),
            "geometry_wkt": "",
            "shape": shape,
            "closed": loop.closed,
            "hit_via": loop.hit_via,
            "target_m": loop.target_m,
            "distance_error": loop.distance_error,
            # A9a/FR8a — three or more via-anchors make the target advisory:
            # reported, not honoured (SPIKE-01: +30.7%/+81.9% at three vias).
            "target_advisory": target_advisory,
            # A9/FR8a AC — "a genuine loop rather than an out-and-back, with any
            # road ridden twice reported": `Loop.metrics` already computes this
            # split (SPIKE-01's lollipop distinction), it just never left the
            # server before now.
            "overlap_frac": round(loop.metrics.overlap_frac, 4) if loop.metrics else 0.0,
            "overlap_near_frac": round(loop.metrics.overlap_near_frac, 4) if loop.metrics else 0.0,
            "overlap_far_frac": round(loop.metrics.overlap_far_frac, 4) if loop.metrics else 0.0,
            # FR128/A11 — dismount/barrier/ford sections actually used, surfaced
            # rather than silently rolled through.
            "surfaced_constraints": loop.surfaced_constraints,
        }

    def _resolve_region(key: str) -> RegionState:
        """Every `/segments/*` call names the region it routes against
        (D41: never a process-wide default). Unknown key -> 404 (the client
        never called `POST /regions`, or raced ahead of a region that has
        since been dropped); known-but-not-ready -> 503 naming the reason
        (§8.3's "never a silent failure").
        """
        region = state.region(key)
        if region is None:
            raise HTTPException(404, f"unknown region {key!r} — call POST /regions first")
        if not region.routing_ready:
            reason = region.routing_capability().get("reason", "not ready")
            raise HTTPException(503, f"routing not ready for region {key!r}: {reason}")
        return region

    @app.post("/segments/generate")
    def segments_generate(req: SegmentRequest) -> dict:
        region = _resolve_region(req.region)
        profile = _resolve_profile(req.theme, req.weights)
        graph = region.graph.graph
        via = [(c.lat, c.lon) for c in req.via]

        try:
            # A9a/FR8a — three or more via-anchors fix the loop's length, so
            # the target distance is advisory (reported, not honoured). The
            # solve is unchanged; only how the response is framed differs.
            advisory = distance_is_advisory(req.target_m, len(via))

            if req.shape == "loop":
                if req.target_m is None:
                    raise HTTPException(422, "loop shape requires target_m")
                loop = generate_loop(graph, (req.start.lat, req.start.lon),
                                     req.target_m, profile, via=via, mode=req.mode)
                return _loop_to_dict(graph, loop, req.mode, req.theme, "loop",
                                     region.sampler, target_advisory=advisory)

            if req.shape == "out_and_back":
                end = (req.end.lat, req.end.lon) if req.end else None
                loop = generate_out_and_back(graph, (req.start.lat, req.start.lon),
                                             profile, via=via, end=end,
                                             target_m=req.target_m, mode=req.mode)
                return _loop_to_dict(graph, loop, req.mode, req.theme, "out_and_back",
                                     region.sampler, target_advisory=advisory)

            if req.end is None:
                raise HTTPException(422, "point_to_point shape requires end")
            segment = generate_segment(
                graph,
                start=(req.start.lat, req.start.lon),
                end=(req.end.lat, req.end.lon),
                via=via,
                profile=profile,
                mode=req.mode,
                shape="point_to_point",
                sampler=region.sampler,
            )
        except NoRouteFound as exc:
            raise HTTPException(422, str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        return segment.to_dict()

    def _solve_walk(req: CuesRequest, graph) -> tuple[list[int], list]:
        """Shape-aware re-solve shared with `/segments/generate`'s loop/
        out_and_back paths, but always returning a `(path, walk)` pair —
        `derive_cue_sheet` needs the walk regardless of which shape produced it.
        """
        profile = _resolve_profile(req.theme, req.weights)
        via = [(c.lat, c.lon) for c in req.via]

        if req.shape == "loop":
            if req.target_m is None:
                raise HTTPException(422, "loop shape requires target_m")
            loop = generate_loop(graph, (req.start.lat, req.start.lon), req.target_m,
                                 profile, via=via, mode=req.mode)
            return loop.path, loop.walk

        if req.shape == "out_and_back":
            end = (req.end.lat, req.end.lon) if req.end else None
            loop = generate_out_and_back(graph, (req.start.lat, req.start.lon), profile,
                                         via=via, end=end, target_m=req.target_m,
                                         mode=req.mode)
            return loop.path, loop.walk

        if req.end is None:
            raise HTTPException(422, "point_to_point shape requires end")
        # FR128/A11 — same legality filter the loop/out_and_back branches above
        # apply internally, needed explicitly here since `solve_circuit` is a
        # lower-level primitive with no `mode` of its own.
        graph = mode_legal_graph(graph, req.mode)
        start_node = nearest_node(graph, req.start.lat, req.start.lon)
        via_nodes = [nearest_node(graph, c.lat, c.lon) for c in req.via]
        end_node = nearest_node(graph, req.end.lat, req.end.lon)
        circuit = solve_circuit(graph, [start_node, *via_nodes, end_node], profile,
                                close=False)
        return circuit.path, edge_walk(graph, circuit.path, profile)

    @app.post("/segments/cues")
    def segments_cues(req: CuesRequest) -> dict:
        region = _resolve_region(req.region)
        graph = region.graph.graph
        try:
            _, walk = _solve_walk(req, graph)
        except NoRouteFound as exc:
            raise HTTPException(422, str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc

        sheet, stats = derive_cue_sheet(
            graph, walk,
            segment_id=req.segment_id,
            nodes=req.nodes, hazards=req.hazards,
            portages=req.portages, alternates=req.alternates,
        )
        return {"cue_sheet": sheet.to_dict(), "stats": stats}

    @app.post("/segments/envelope")
    def segments_envelope(req: EnvelopeRequest) -> dict:
        region = _resolve_region(req.region)
        try:
            envelope = probe_envelope(
                region.graph.graph,
                start=(req.start.lat, req.start.lon),
                target_m=req.target_m,
                via=[(c.lat, c.lon) for c in req.via],
                mode=req.mode,
            )
        except NoRouteFound as exc:
            raise HTTPException(422, str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        return {k: [lo, hi] for k, (lo, hi) in envelope.items()}

    @app.post("/segments/diagnose", status_code=202)
    def segments_diagnose(req: DiagnoseRequest) -> dict:
        region = _resolve_region(req.region)
        try:
            bands = BandSet.of(*(
                Band(b.metric, b.minimum, b.maximum) for b in req.bands
            ))
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc

        graph = region.graph.graph

        def run(job: DiagnoseJob) -> None:
            try:
                result = diagnose(
                    graph,
                    start=(req.start.lat, req.start.lon),
                    target_m=req.target_m,
                    bands=bands,
                    via=[(c.lat, c.lon) for c in req.via],
                    mode=req.mode,
                )
                job.result = result.to_dict()
            except Exception as exc:  # noqa: BLE001 — surface honestly (A6)
                job.error = str(exc)
            # `job.done` is set by the registry once this returns, however it
            # returns.

        # SPIKE-02: 1.3-15.0s to diagnose vs 27-218ms to solve — this cannot sit
        # inside a request the Author is waiting on (ARCH §7.2). The registry
        # runs it on a bounded pool and prunes finished jobs; see
        # `DiagnoseRegistry`.
        return {"id": diagnose_jobs.submit(run)}

    @app.get("/segments/diagnose/{job_id}")
    def segments_diagnose_poll(job_id: str) -> dict:
        job = diagnose_jobs.get(job_id)
        if job is None:
            raise HTTPException(404, "unknown diagnosis job")
        if not job.done:
            return {"status": "pending"}
        if job.error:
            raise HTTPException(500, job.error)
        return {"status": "done", "diagnosis": job.result}

    @app.get("/geocode")
    def geocode(q: str) -> dict:
        """ARCH §7.2 — Nominatim via OSMnx. Powers A10's first-run location
        prompt and New Route's location search. No key needed (ARCH §11),
        but it is a live network call to a shared public service — errors
        are reported honestly (MVP doc §4's "no data for area" family)
        rather than retried silently, and callers should not hammer it.

        Each result carries `bbox` (issue #154) alongside `coord` — Nominatim
        already returns the place's bounding geometry and the pre-#154
        endpoint discarded it, leaving the trip-area draw map with nothing
        to frame itself on but a point. **This never becomes the trip bbox**
        (FR96: the location prompt only ever centers the map) — it only lets
        the draw map open on a real extent instead of an arbitrary zoom.
        """
        if not q.strip():
            raise HTTPException(422, "empty query")
        try:
            gdf = ox.geocode_to_gdf(q)
        except (ValueError, RuntimeError) as exc:
            # osmnx raises a mix of exception types for "nothing found" vs.
            # a downstream Nominatim/network failure; both are the same
            # honest answer to an Author — no result, not a system error.
            raise HTTPException(422, f"no match for {q!r}: {exc}") from exc
        results = [
            {
                "label": row.get("display_name", q),
                "coord": [float(row["lon"]), float(row["lat"])],
                "bbox": [float(row["bbox_west"]), float(row["bbox_south"]),
                        float(row["bbox_east"]), float(row["bbox_north"])],
            }
            for _, row in gdf.iterrows()
        ]
        return {"results": results}

    @app.get("/tiles/{z}/{x}/{y}")
    def tiles(z: int, x: int, y: int) -> Response:
        """ARCH §8.2, FR92-94; issue #154. z/x/y is range-validated before
        any upstream work (FR93) — a request outside the tile pyramid never
        touches an archive at all. Answered from (a) any ensured region's
        on-demand cache extracted for that trip's own bbox, checked first
        since it is the Author's actual area, then (b) the committed home
        region archive (FR96) — and 404, honestly, if neither has data for
        this address rather than ever substituting another region's tile
        (the exact silence issue #154 was filed over, on the routing side).
        """
        if not valid_zxy(z, x, y):
            raise HTTPException(422, f"invalid tile address z={z} x={x} y={y}")

        for _key, region in state.snapshot():
            if region.tiles_archive is None:
                continue
            data = region.tiles_archive.tile(z, x, y)
            if data is not None:
                return _tile_response(data, region.tiles_archive.info())

        data = home_tiles.tile(z, x, y)
        if data is not None:
            return _tile_response(data, home_tiles.info())

        raise HTTPException(404, f"no basemap tile at z={z} x={x} y={y}")

    def _tile_response(data: bytes, info) -> Response:
        headers = {"Content-Encoding": info.content_encoding} if info.content_encoding else {}
        return Response(content=data, media_type=info.tile_content_type, headers=headers)

    @app.post("/days/compose")
    def days_compose(req: DayComposeRequest) -> dict:
        segments = [parse_dataclass(PayloadSegment, s) for s in req.segments]
        transitions = [parse_dataclass(PayloadTransition, t) for t in req.transitions]
        try:
            day = compose_day(segments, transitions, index=req.index, kind=req.kind)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        result = day.to_dict()

        # E3 / FR39 / FR117 / FR118 (issue #214) — the compose-mode
        # places-first views ride alongside the `Day` for the same reason
        # `/trips/split`'s `hazard_rollup` / `dashboard` do: they are derived,
        # not stored, and `plotlines_core.trips.spine` is the one place the
        # itinerary / recap / cue-sheet-of-places are computed, so a sidecar
        # and a future hosted assembly hand the client identical structure.
        # Only built when the request names a spine of two or more anchors.
        if len(req.anchors) >= 2:
            try:
                anchors = [parse_dataclass(Anchor, a) for a in req.anchors]
                if len(day.segments) == len(anchors) - 1:
                    # Already the one-passage-per-anchor-pair shape.
                    legs = day.segments
                    realised = None
                elif len(day.segments) == 1:
                    # The client's single-passage-through-via-points shape:
                    # split the solved polyline back into per-pair legs, but
                    # keep the real solved length as the reported outcome.
                    seg = day.segments[0]
                    legs = spine_legs_from_polyline(
                        anchors,
                        seg.geometry.coordinates if seg.geometry else None,
                        mode=seg.mode,
                    )
                    realised = distance_outcome(day.segments, target_m=req.target_m)
                else:
                    legs = None
                    realised = None
                if legs is not None:
                    itinerary = compose_itinerary(anchors, legs, target_m=req.target_m)
                    if realised is not None:
                        itinerary.distance = realised
                    result["itinerary"] = itinerary.to_dict()
                    result["recap"] = [e.to_dict() for e in recap_spine(itinerary)]
                    result["cues"] = [c.to_dict() for c in spine_cues(itinerary)]
            except ValueError as exc:
                raise HTTPException(422, str(exc)) from exc

        return result

    @app.post("/trips/split")
    def trips_split(req: TripSplitRequest) -> dict:
        days = [parse_dataclass(PayloadDay, d) for d in req.days]
        default_weights = (
            parse_dataclass(PayloadWeightProfile, req.default_weights)
            if req.default_weights else None
        )
        try:
            trip = split_trip(days, req.limits or {}, title=req.title,
                              default_weights=default_weights)
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        result = trip.to_dict()
        # C11 / FR27 / FR115 — the trip-wide hazard roll-up and the worst-first
        # sync-alert set ride *alongside* the payload, not inside it: the payload
        # schema is closed and these are derived (like `metrics`), one traversal
        # of every hazard the assembled trip carries. `hazard_rollup` is the one
        # producer this and hosted-mode assembly both call, so the two can never
        # hand the client a different list (issue #210).
        result["hazard_rollup"] = hazard_rollup(trip)
        # D1 / FR31 / FR16 (issue #213) — the live planning dashboard rides
        # alongside the payload for the same reason `hazard_rollup` does: it is
        # derived, not stored, and `build_dashboard` is the one place the FR16
        # moving-time / elapsed-time / ETA model is computed, so a sidecar and
        # (future) hosted assembly hand the client the identical numbers rather
        # than each rolling their own. With no time-model inputs on the request
        # it is the distance/elevation panel; the inputs fill in the rest.
        try:
            dashboard = build_dashboard(
                trip,
                active_segment_id=req.active_segment_id,
                speeds=req.speeds,
                day_hold_s=req.day_hold_s,
                day_start_at=req.day_start_at,
                trip_start_at=req.trip_start_at,
            )
        except ValueError as exc:
            # `active_segment_id` naming a segment the assembled trip does not
            # carry is the only ValueError `build_dashboard` raises.
            raise HTTPException(422, str(exc)) from exc
        result["dashboard"] = dashboard.to_dict()
        return result

    if mode == "hosted":
        # Auth / sync / share / group-relay endpoints live here (§7.1). Still
        # not built — and deliberately absent rather than stubbed, so a
        # sidecar can never expose them.
        #
        # What *is* built is M4's seam: the same-site session-cookie contract
        # (ARCH §10.3, D15). Hosted mode has no trust boundary of its own —
        # unlike a loopback sidecar — so the signed-in session rides a
        # first-party `HttpOnly; Secure; SameSite=Lax` cookie on the parent
        # domain that `app.<domain>` and `api.<domain>` share. That only
        # works on a real registered domain, so hosted mode *requires* one
        # (the same shape as sidecar mode refusing a non-loopback bind).
        if not web_domain:
            raise ValueError(
                "hosted mode requires --web-domain: the registrable parent that "
                "app.<domain> and api.<domain> share, so the session cookie is "
                "first-party and survives Safari/Firefox (ARCH §10.3, story M4). "
                "A *.onrender.com-style host is refused."
            )
        policy = SessionCookiePolicy(parent_domain=web_domain)
        app.state.session_cookie = policy

        def issue_session(response: Response, token: str, *, max_age: int | None = None) -> None:
            """The one way an auth endpoint opens a web session — every
            `Set-Cookie` for the session goes through the M4 policy."""
            response.headers.append(
                "set-cookie", policy.set_cookie_header(token, max_age=max_age)
            )

        def end_session(response: Response) -> None:
            """The one way an auth endpoint ends a web session."""
            response.headers.append("set-cookie", policy.clear_cookie_header())

        app.state.issue_session = issue_session
        app.state.end_session = end_session

    return app
