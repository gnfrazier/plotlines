"""FastAPI app factory — sidecar mode now, hosted mode later (ARCH §7).

Endpoints invalid for a mode are **not registered**, not merely guarded (§7.1): a
sidecar has no /auth/* routes to attack.

SPIKE-00 scope: the routing endpoints that the spike actually exercises. The rest of
§7.2's surface is not implemented here.
"""

from __future__ import annotations

import threading
import time
import uuid
from pathlib import Path

import osmnx as ox
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from plotlines_core.curation.defaults import resolve_default_layers
from plotlines_core.curation.notability import RawFeature, RULESET_VERSION, score_notability
from plotlines_core.curation.providers import BBox, OsmLayerProvider
from plotlines_core.curation.taxonomy import LAYERS
from plotlines_core.elevation.sampler import ElevationSampler
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
from plotlines_core.trips.compose import compose_day, split_trip
from plotlines_core.trips.cues import derive_cue_sheet, route_polyline
from plotlines_core.trips.payload import Day as PayloadDay
from plotlines_core.trips.payload import Segment as PayloadSegment
from plotlines_core.trips.payload import Transition as PayloadTransition
from plotlines_core.trips.payload import WeightProfile as PayloadWeightProfile

from .payload_io import parse_dataclass
from .version import VERSION

GRAPH_FILE = "boulder_bike.graphml"
DEM_FILE = "boulder_dem.tif"


# Heuristic wall-clock estimates for the progress/eta a still-loading
# capability reports (ARCH §8.3's "terrain data loading — routing available
# in about 3 minutes"). Neither is measured telemetry (SPIKE-D is where that
# would come from) — they only keep the estimate from being a bare guess with
# no relation to elapsed time. Graph load is typically sub-second off local
# disk; elevation enrichment is the "minutes-long" operation FR91 names.
GRAPH_ESTIMATED_S = 5.0
ELEVATION_ESTIMATED_S = 180.0


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


class Readiness:
    """Per-capability readiness (ARCH §8.3, breaking change B1; PRD FR121).

    Startup order is load-bearing: the graph loads first (it is what
    layer/POI extraction and candidate scoring need *not at all* — those
    endpoints never consult this class — but it is also the cheaper of the
    two loads and routing cannot come up without it), and elevation
    enrichment runs after, off the request-handling path (FR91). Layer/POI
    and tile capabilities have no startup dependency in this codebase and
    are reported ready unconditionally in `health()` — they were never
    gated on this class to begin with (B1's whole point).
    """

    def __init__(self) -> None:
        self.graph_state = CapabilityState(GRAPH_ESTIMATED_S)
        self.elevation_state = CapabilityState(ELEVATION_ESTIMATED_S)
        self.graph: LoadedGraph | None = None
        self.sampler: ElevationSampler | None = None
        self.started_at = time.perf_counter()

    @property
    def routing_ready(self) -> bool:
        """Routing needs the graph, and needs elevation enrichment to have
        settled — succeeded or failed — before it reports ready (§8.3's
        `"routing": {"reason": "elevation_enriching"}`). A failed elevation
        load still unblocks routing rather than wedging it forever; it just
        means elevation-dependent metrics stay unavailable."""
        return self.graph_state.ready and self.elevation_state.settled

    def routing_capability(self) -> dict:
        if not self.graph_state.ready:
            if self.graph_state.status == "failed":
                return {"ready": False, "reason": f"graph_failed:{self.graph_state.detail}"}
            d = {"ready": False, "reason": "graph_loading",
                 "progress": round(self.graph_state.progress(), 2)}
            eta = self.graph_state.eta_s()
            if eta is not None:
                d["eta_s"] = round(eta, 1)
            return d
        if self.elevation_state.status == "loading":
            d = {"ready": False, "reason": "elevation_enriching",
                 "progress": round(self.elevation_state.progress(), 2)}
            eta = self.elevation_state.eta_s()
            if eta is not None:
                d["eta_s"] = round(eta, 1)
            return d
        return {"ready": True}

    def load(self, cache_dir: Path) -> None:
        self.graph_state.start("loading graph")
        try:
            self.graph = load_graphml(cache_dir / GRAPH_FILE)
            self.graph_state.succeed("graph loaded")
        except Exception as exc:  # noqa: BLE001 — surface honestly, never hang
            self.graph_state.fail(f"{type(exc).__name__}: {exc}")

        # Runs regardless of the graph outcome — elevation is an independent
        # capability (§8.3: one capability failing never blocks another).
        self.elevation_state.start("opening elevation")
        try:
            self.sampler = ElevationSampler(cache_dir / DEM_FILE)
            self.elevation_state.succeed("elevation ready")
        except Exception as exc:  # noqa: BLE001 — surface honestly, never hang
            self.elevation_state.fail(f"{type(exc).__name__}: {exc}")


class Coordinate(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class SegmentRequest(BaseModel):
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

    start: Coordinate
    via: list[Coordinate] = Field(default_factory=list)
    target_m: float = Field(gt=0)


class BandInput(BaseModel):
    metric: str
    minimum: float | None = None
    maximum: float | None = None


class DiagnoseRequest(BaseModel):
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


def create_app(cache_dir: Path, mode: str = "sidecar") -> FastAPI:
    app = FastAPI(title="plotlines-service", version=VERSION)
    state = Readiness()
    app.state.readiness = state
    diagnose_jobs: dict[str, DiagnoseJob] = {}

    threading.Thread(target=state.load, args=(cache_dir,), daemon=True).start()

    @app.get("/health")
    def health() -> dict:
        """Per-capability readiness (ARCH §8.3, breaking change B1; PRD
        FR121). No single `ready` flag: `tiles` and `layers` report ready
        unconditionally (neither has a startup dependency in this codebase —
        the Curation Workspace must be usable while elevation enriches
        behind it), `routing` and `elevation` report their real load state,
        each with a progress estimate while loading. `per_layer` is `LAYERS`
        (the built-in OSM taxonomy) reported ready; a future plugin loader
        (ARCH §14) is where a layer could report `loading`/`failed` here —
        that mechanism does not exist yet, so every entry is `ready` today.

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
                "routing": state.routing_capability(),
                "elevation": state.elevation_state.to_dict(),
            },
        }

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

    def _loop_to_dict(loop: Loop, mode: str, theme: str, shape: str, sampler: ElevationSampler | None) -> dict:
        """Shapes a `Loop` (routing/loops.py) into the same response family
        `Segment.to_dict()` (routing/solve.py) returns, plus the loop-specific
        fields (`closed`, `hit_via`, `target_m`) point_to_point has no opinion
        about. `route_polyline` — not a straight node-to-node line — because
        it's already needed for cue derivation elsewhere and gives the client
        the real curved way geometry rather than SPIKE-00's simplification.
        """
        route = route_polyline(state.graph.graph, loop.walk)
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

    @app.post("/segments/generate")
    def segments_generate(req: SegmentRequest) -> dict:
        if not state.routing_ready:
            reason = state.routing_capability().get("reason", "not ready")
            raise HTTPException(503, f"routing not ready: {reason}")
        profile = _resolve_profile(req.theme, req.weights)
        graph = state.graph.graph
        via = [(c.lat, c.lon) for c in req.via]

        try:
            if req.shape == "loop":
                if req.target_m is None:
                    raise HTTPException(422, "loop shape requires target_m")
                loop = generate_loop(graph, (req.start.lat, req.start.lon),
                                     req.target_m, profile, via=via)
                return _loop_to_dict(loop, req.mode, req.theme, "loop", state.sampler)

            if req.shape == "out_and_back":
                end = (req.end.lat, req.end.lon) if req.end else None
                loop = generate_out_and_back(graph, (req.start.lat, req.start.lon),
                                             profile, via=via, end=end,
                                             target_m=req.target_m)
                return _loop_to_dict(loop, req.mode, req.theme, "out_and_back", state.sampler)

            if req.end is None:
                raise HTTPException(422, "point_to_point shape requires end")
            segment = generate_segment(
                graph,
                start=(req.start.lat, req.start.lon),
                end=(req.end.lat, req.end.lon),
                via=via,
                profile=profile,
                mode=req.mode,
                sampler=state.sampler,
            )
        except NoRouteFound as exc:
            raise HTTPException(422, str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc
        return segment.to_dict()

    def _solve_walk(req: CuesRequest) -> tuple[list[int], list]:
        """Shape-aware re-solve shared with `/segments/generate`'s loop/
        out_and_back paths, but always returning a `(path, walk)` pair —
        `derive_cue_sheet` needs the walk regardless of which shape produced it.
        """
        profile = _resolve_profile(req.theme, req.weights)
        graph = state.graph.graph
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
        if not state.routing_ready:
            reason = state.routing_capability().get("reason", "not ready")
            raise HTTPException(503, f"routing not ready: {reason}")
        try:
            _, walk = _solve_walk(req)
        except NoRouteFound as exc:
            raise HTTPException(422, str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc

        sheet, stats = derive_cue_sheet(
            state.graph.graph, walk,
            segment_id=req.segment_id,
            nodes=req.nodes, hazards=req.hazards,
            portages=req.portages, alternates=req.alternates,
        )
        return {"cue_sheet": sheet.to_dict(), "stats": stats}

    @app.post("/segments/envelope")
    def segments_envelope(req: EnvelopeRequest) -> dict:
        if not state.routing_ready:
            reason = state.routing_capability().get("reason", "not ready")
            raise HTTPException(503, f"routing not ready: {reason}")
        envelope = probe_envelope(
            state.graph.graph,
            start=(req.start.lat, req.start.lon),
            target_m=req.target_m,
            via=[(c.lat, c.lon) for c in req.via],
        )
        return {k: [lo, hi] for k, (lo, hi) in envelope.items()}

    @app.post("/segments/diagnose")
    def segments_diagnose(req: DiagnoseRequest) -> dict:
        if not state.routing_ready:
            reason = state.routing_capability().get("reason", "not ready")
            raise HTTPException(503, f"routing not ready: {reason}")
        try:
            bands = BandSet.of(*(
                Band(b.metric, b.minimum, b.maximum) for b in req.bands
            ))
        except ValueError as exc:
            raise HTTPException(422, str(exc)) from exc

        job_id = str(uuid.uuid4())
        job = DiagnoseJob()
        diagnose_jobs[job_id] = job

        def run() -> None:
            try:
                result = diagnose(
                    state.graph.graph,
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
            {"label": row.get("display_name", q), "coord": [float(row["lon"]), float(row["lat"])]}
            for _, row in gdf.iterrows()
        ]
        return {"results": results}

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
