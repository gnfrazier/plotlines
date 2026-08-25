"""FastAPI app factory — sidecar mode now, hosted mode later (ARCH §7).

Endpoints invalid for a mode are **not registered**, not merely guarded (§7.1): a
sidecar has no /auth/* routes to attack.

Region- and content-scoped surface built out so far: curation (`/layers`,
`/candidates*`), routing (`/regions`, `/segments/*`), trip composition
(`/days/compose`, `/trips/split`), `/geocode`, and content (`/tiles/{z}/{x}/{y}`).
The rest of §8.2's surface (accounts, group relay, reading — all hosted-mode-only)
is not implemented here.
"""

from __future__ import annotations

import threading
import time
import uuid
from pathlib import Path

import osmnx as ox
from fastapi import FastAPI, HTTPException, Response
from pydantic import BaseModel, Field

from plotlines_core.curation.defaults import resolve_default_layers
from plotlines_core.curation.notability import RawFeature, RULESET_VERSION, score_notability
from plotlines_core.curation.providers import BBox, OsmLayerProvider
from plotlines_core.curation.taxonomy import LAYERS
from plotlines_core.elevation.sampler import ElevationSampler
from plotlines_core.graph import regions as region_lib
from plotlines_core.graph.loader import LoadedGraph, load_graphml, nearest_node
from plotlines_core.routing.diagnose import diagnose
from plotlines_core.routing.loops import (
    Loop, generate_loop, generate_out_and_back, solve_circuit,
)
from plotlines_core.routing.search import probe_envelope
from plotlines_core.routing.solve import NoRouteFound, generate_segment
from plotlines_core.scoring.bands import Band, BandSet
from plotlines_core.scoring.metrics import edge_walk, measure
from plotlines_core.scoring.profile import THEMES, WeightProfile
from plotlines_core.tiles.archive import Archive, valid_zxy
from plotlines_core.tiles.extract import NoTilesInBbox, extract_bbox
from plotlines_core.trips.compose import compose_day, split_trip
from plotlines_core.trips.cues import derive_cue_sheet, route_polyline
from plotlines_core.trips.payload import Day as PayloadDay
from plotlines_core.trips.payload import Segment as PayloadSegment
from plotlines_core.trips.payload import Transition as PayloadTransition
from plotlines_core.trips.payload import WeightProfile as PayloadWeightProfile

from .payload_io import parse_dataclass
from .tiles_paths import default_home_region_archive
from .version import VERSION

# Heuristic wall-clock estimate for the progress/eta a still-building region
# reports (ARCH §8.3's "terrain data loading — routing available in about 3
# minutes"), not measured telemetry (SPIKE-D is where that would come from)
# — it only keeps the estimate from being a bare guess with no relation to
# elapsed time. A bbox-scoped Overpass fetch + graph build is typically a few
# seconds for an MVP-sized trip area.
GRAPH_ESTIMATED_S = 8.0

# Elevation acquisition is explicitly out of scope for this region-build path
# (issue #154's scoping note): D20/FR85 pin the source to GEDTM30 via
# OpenTopography with no fallback, and that pipeline is gated on FR87 (issue
# #148) — promoting spikes/shared/regions.py's Terrarium fetcher would be a
# second elevation source, which D20 forbids. So `elevation` reports this
# fixed, honest not-ready state for every region rather than ever loading —
# never blocking routing, which needs only the graph (FR121).
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

    @property
    def routing_ready(self) -> bool:
        return self.graph_state.ready

    def routing_capability(self) -> dict:
        return self.graph_state.to_dict()

    def build(self, cache_dir: Path, tiles_upstream: str | Path) -> None:
        self.graph_state.start("building graph")
        try:
            region = region_lib.Region(key=self.key, bbox=self.bbox,
                                       network_type=self.network_type)
            path = region_lib.ensure_graph(region, cache_dir)
            self.graph = load_graphml(path)
            self.graph_state.succeed("graph ready")
        except Exception as exc:  # noqa: BLE001 — surface honestly, never hang (A6)
            self.graph_state.fail(f"{type(exc).__name__}: {exc}")
            return  # no graph, no point extracting tiles for this region

        # Tiles are best-effort and independent of routing (B1: one
        # capability's failure never blocks another) — a bbox outside the
        # configured tile source's coverage leaves `/tiles` to answer
        # honestly per-request (404) rather than wedging region build.
        try:
            tiles_path = cache_dir / "regions" / self.key / "tiles.pmtiles"
            if not tiles_path.exists():
                extract_bbox(tiles_upstream, self.bbox, tiles_path)
            self.tiles_archive = Archive(tiles_path)
        except NoTilesInBbox:
            pass
        except Exception:  # noqa: BLE001 — tiles are best-effort; never fail the region for this
            pass


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

    def __init__(self, cache_dir: Path, tiles_upstream: str | Path) -> None:
        self.cache_dir = cache_dir
        self.tiles_upstream = tiles_upstream
        self.regions: dict[str, RegionState] = {}
        self._lock = threading.Lock()
        self.started_at = time.perf_counter()

    def ensure_region(self, bbox: tuple[float, float, float, float],
                      network_type: str = "bike") -> str:
        """Idempotent: a second call with the same (bbox, network_type)
        returns the same key without starting a second build."""
        key = region_lib.region_key(bbox, network_type)
        with self._lock:
            region = self.regions.get(key)
            if region is None:
                region = RegionState(key, bbox, network_type)
                self.regions[key] = region
                threading.Thread(
                    target=region.build, args=(self.cache_dir, self.tiles_upstream),
                    daemon=True,
                ).start()
        return key

    def region(self, key: str) -> RegionState | None:
        return self.regions.get(key)

    def routing_capabilities(self) -> dict:
        """§8.3's per-region `routing` breakdown — empty until an Author has
        drawn a trip bbox and the client has called `POST /regions`."""
        return {key: region.routing_capability() for key, region in self.regions.items()}


class Coordinate(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class RegionRequest(BaseModel):
    """FR120/D41 — the Author's trip bbox, ensuring a routable graph exists
    for exactly that area (issue #154). `bbox` is [west, south, east, north]
    (osmnx order)."""

    bbox: list[float] = Field(min_length=4, max_length=4)
    network_type: str = "bike"


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
    # One of loop | out_and_back | point_to_point (FR7/A7).
    shape: str = "point_to_point"
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
    shape: str = "point_to_point"
    theme: str = "balanced"
    weights: dict[str, float] | None = None
    target_m: float | None = None
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


class TripSplitRequest(BaseModel):
    """C3 — assemble days into a trip and apply per-mode day limits. Despite
    the ARCH §7.2 endpoint name, this assembles rather than splits — see
    `trips/compose.py`'s `split_trip` docstring for why the name stuck."""

    days: list[dict] = Field(default_factory=list)
    title: str = "Untitled plotline"
    limits: dict[str, dict[str, float]] | None = None
    default_weights: dict | None = None


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


class DiagnoseJob:
    def __init__(self) -> None:
        self.done = False
        self.result: dict | None = None
        self.error: str | None = None


def create_app(cache_dir: Path, mode: str = "sidecar", *,
               tiles_upstream: str | Path | None = None) -> FastAPI:
    app = FastAPI(title="plotlines-service", version=VERSION)
    state = Readiness(cache_dir, tiles_upstream or default_home_region_archive())
    app.state.readiness = state
    home_tiles = Archive(default_home_region_archive())
    diagnose_jobs: dict[str, DiagnoseJob] = {}

    @app.get("/health")
    def health() -> dict:
        """Per-capability readiness (ARCH §8.3, breaking change B1; PRD
        FR120/FR121; issue #154). No single `ready` flag: `tiles` and
        `layers` report ready unconditionally (neither has a process-wide
        startup dependency — the Curation Workspace must be usable
        immediately). `routing` is **per region** (D41: there is no
        process-wide "the graph" any more — every trip bbox gets its own),
        keyed by the region id `POST /regions` returned; empty until an
        Author has drawn a bbox. `elevation` is a fixed not-ready state for
        every region (see `ELEVATION_NOT_CONFIGURED`'s docstring) — never
        blocking routing, which needs only the graph. `per_layer` is
        `LAYERS` (the built-in OSM taxonomy) reported ready; a future plugin
        loader (ARCH §14) is where a layer could report `loading`/`failed`
        here — that mechanism does not exist yet, so every entry is `ready`
        today.

        Version-mismatch refusal (A8, M12) is unchanged and lives entirely
        client-side in `SidecarManager.start()`, before the sidecar is even
        spawned — `/health` was never part of that check and still isn't.
        """
        return {
            "app_version": VERSION,
            "sidecar_version": VERSION,
            "mode": mode,
            "capabilities": {
                "tiles": {"ready": True},
                "layers": {
                    "ready": True,
                    "per_layer": {layer: "ready" for layer in sorted(LAYERS)},
                },
                "routing": {"regions": state.routing_capabilities()},
                "elevation": ELEVATION_NOT_CONFIGURED,
            },
        }

    @app.post("/regions", status_code=202)
    def regions_ensure(req: RegionRequest) -> dict:
        """FR120/D41, ARCH D25's 202-and-poll house style applied to region
        acquisition — issue #154. Idempotent: an Author revising the same
        bbox again (or a second client call for a bbox already ensured)
        returns the same key without starting a second build. Poll
        `GET /health`'s `capabilities.routing.regions[key]` for progress.
        """
        bbox = tuple(req.bbox)
        key = state.ensure_region(bbox, req.network_type)
        return {"region": key}

    @app.get("/layers")
    def layers(mode: str = "cycling", day_type: str = "route") -> dict:
        """FR97 — the layer catalog plus this (mode, day type) pair's default
        live set. Deliberately independent of the graph/elevation loading
        state tracked in `Readiness`: layer/POI capability comes up ahead of
        elevation (ARCH B1/D34/§8.3), and the Curation Workspace must be
        usable while enrichment still runs."""
        return {
            "layers": sorted(LAYERS),
            "default_live": sorted(resolve_default_layers(mode, day_type)),
            "ruleset_version": RULESET_VERSION,
        }

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

    # On `app.state`, not a closure-local, so a test can substitute a fake
    # provider the same way `app.state.readiness` is substitutable — a live
    # Overpass call has no place inside a unit test.
    app.state.layer_provider = OsmLayerProvider()

    @app.get("/candidates")
    def candidates_extract(west: float, south: float, east: float, north: float,
                           layers: str) -> dict:
        """ARCH §8.2 endpoint surface, FR98/FR99 — extracts a bbox's raw
        features via the built-in `OsmLayerProvider` (ARCH §14.2) and
        notability-filters them in one call. `layers` is a comma-separated
        live-layer set (FR97's Author selection); a live layer this catalog
        doesn't recognize is simply never asked for.

        Synchronous for MVP: ARCH §7.2 describes this as a job for a large
        multi-day bbox, which this endpoint does not yet implement — a
        future pass can make it async without changing what it returns.
        """
        live = {layer for layer in layers.split(",") if layer}
        try:
            features = app.state.layer_provider.fetch(BBox(west, south, east, north), live)
        except Exception as exc:  # noqa: BLE001 — an honest "no data" beats a 500 (ARCH §7.2)
            raise HTTPException(422, f"could not extract features for this area: {exc}") from exc
        candidates = score_notability(features, live_layers=live)
        return _candidates_response(candidates)

    def _resolve_profile(theme: str, weights: dict[str, float] | None) -> WeightProfile:
        if weights:
            try:
                return WeightProfile(name=theme or "custom", **weights)
            except (TypeError, ValueError) as exc:
                raise HTTPException(422, f"bad weights: {exc}") from exc
        if theme in THEMES:
            return THEMES[theme]
        raise HTTPException(422, f"unknown theme {theme!r}")

    def _loop_to_dict(graph, loop: Loop, mode: str, theme: str, shape: str,
                      sampler: ElevationSampler | None) -> dict:
        """Shapes a `Loop` (routing/loops.py) into the same response family
        `Segment.to_dict()` (routing/solve.py) returns, plus the loop-specific
        fields (`closed`, `hit_via`, `target_m`) point_to_point has no opinion
        about. `route_polyline` — not a straight node-to-node line — because
        it's already needed for cue derivation elsewhere and gives the client
        the real curved way geometry rather than SPIKE-00's simplification.
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
            if req.shape == "loop":
                if req.target_m is None:
                    raise HTTPException(422, "loop shape requires target_m")
                loop = generate_loop(graph, (req.start.lat, req.start.lon),
                                     req.target_m, profile, via=via)
                return _loop_to_dict(graph, loop, req.mode, req.theme, "loop", region.sampler)

            if req.shape == "out_and_back":
                end = (req.end.lat, req.end.lon) if req.end else None
                loop = generate_out_and_back(graph, (req.start.lat, req.start.lon),
                                             profile, via=via, end=end,
                                             target_m=req.target_m)
                return _loop_to_dict(graph, loop, req.mode, req.theme, "out_and_back", region.sampler)

            if req.end is None:
                raise HTTPException(422, "point_to_point shape requires end")
            segment = generate_segment(
                graph,
                start=(req.start.lat, req.start.lon),
                end=(req.end.lat, req.end.lon),
                via=via,
                profile=profile,
                mode=req.mode,
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
                                 profile, via=via)
            return loop.path, loop.walk

        if req.shape == "out_and_back":
            end = (req.end.lat, req.end.lon) if req.end else None
            loop = generate_out_and_back(graph, (req.start.lat, req.start.lon), profile,
                                         via=via, end=end, target_m=req.target_m)
            return loop.path, loop.walk

        if req.end is None:
            raise HTTPException(422, "point_to_point shape requires end")
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

        job_id = str(uuid.uuid4())
        job = DiagnoseJob()
        diagnose_jobs[job_id] = job
        graph = region.graph.graph

        def run() -> None:
            try:
                result = diagnose(
                    graph,
                    start=(req.start.lat, req.start.lon),
                    target_m=req.target_m,
                    bands=bands,
                    via=[(c.lat, c.lon) for c in req.via],
                )
                job.result = result.to_dict()
            except Exception as exc:  # noqa: BLE001 — surface honestly (A6)
                job.error = str(exc)
            finally:
                job.done = True

        # SPIKE-02: 1.3-15.0s to diagnose vs 27-218ms to solve — this cannot sit
        # inside a request the Author is waiting on (ARCH §7.2).
        threading.Thread(target=run, daemon=True).start()
        return {"id": job_id}

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

        for region in state.regions.values():
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
        return day.to_dict()

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
        return trip.to_dict()

    if mode == "hosted":
        # Auth / sync / share / group-relay live here (§7.1). Not built — and
        # deliberately absent rather than stubbed, so a sidecar can never expose them.
        pass

    return app
