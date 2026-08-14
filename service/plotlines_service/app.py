"""FastAPI app factory — sidecar mode now, hosted mode later (ARCH §7).

Endpoints invalid for a mode are **not registered**, not merely guarded (§7.1): a
sidecar has no /auth/* routes to attack.

SPIKE-00 scope: the routing endpoints that the spike actually exercises. The rest of
§7.2's surface is not implemented here.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from plotlines_core.elevation.sampler import ElevationSampler
from plotlines_core.graph.loader import LoadedGraph, load_graphml
from plotlines_core.routing.solve import NoRouteFound, generate_segment
from plotlines_core.scoring.profile import THEMES, WeightProfile

from .version import VERSION

GRAPH_FILE = "boulder_bike.graphml"
DEM_FILE = "boulder_dem.tif"


class Readiness:
    """Readiness, not liveness (§7.3). Up-but-loading is not ready."""

    def __init__(self) -> None:
        self.state = "loading"
        self.detail = "starting"
        self.graph: LoadedGraph | None = None
        self.sampler: ElevationSampler | None = None
        self.started_at = time.perf_counter()
        self.ready_at: float | None = None

    @property
    def ready(self) -> bool:
        return self.state == "ready"

    def load(self, cache_dir: Path) -> None:
        try:
            self.detail = "loading graph"
            self.graph = load_graphml(cache_dir / GRAPH_FILE)
            self.detail = "opening elevation"
            self.sampler = ElevationSampler(cache_dir / DEM_FILE)
            self.ready_at = time.perf_counter()
            self.state = "ready"
            self.detail = "ready"
        except Exception as exc:  # noqa: BLE001 — surface honestly, never hang
            self.state = "failed"
            self.detail = f"{type(exc).__name__}: {exc}"


class Coordinate(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class SegmentRequest(BaseModel):
    start: Coordinate
    end: Coordinate
    via: list[Coordinate] = Field(default_factory=list)
    mode: str = "cycling"
    theme: str = "balanced"
    weights: dict[str, float] | None = None


def create_app(cache_dir: Path, mode: str = "sidecar") -> FastAPI:
    app = FastAPI(title="plotlines-service", version=VERSION)
    state = Readiness()
    app.state.readiness = state

    threading.Thread(target=state.load, args=(cache_dir,), daemon=True).start()

    @app.get("/health")
    def health() -> dict:
        elapsed = (state.ready_at or time.perf_counter()) - state.started_at
        return {
            "status": state.state,
            "ready": state.ready,
            "detail": state.detail,
            "version": VERSION,
            "mode": mode,
            "startup_seconds": round(elapsed, 3),
            "graph": (
                {"nodes": state.graph.node_count, "edges": state.graph.edge_count}
                if state.graph else None
            ),
        }

    @app.post("/segments/generate")
    def segments_generate(req: SegmentRequest) -> dict:
        if not state.ready:
            raise HTTPException(503, f"sidecar not ready: {state.detail}")

        if req.weights:
            try:
                profile = WeightProfile(name=req.theme or "custom", **req.weights)
            except (TypeError, ValueError) as exc:
                raise HTTPException(422, f"bad weights: {exc}") from exc
        elif req.theme in THEMES:
            profile = THEMES[req.theme]
        else:
            raise HTTPException(422, f"unknown theme {req.theme!r}")

        try:
            segment = generate_segment(
                state.graph.graph,
                start=(req.start.lat, req.start.lon),
                end=(req.end.lat, req.end.lon),
                via=[(c.lat, c.lon) for c in req.via],
                profile=profile,
                mode=req.mode,
                sampler=state.sampler,
            )
        except NoRouteFound as exc:
            raise HTTPException(422, str(exc)) from exc
        return segment.to_dict()

    if mode == "hosted":
        # Auth / sync / share / group-relay live here (§7.1). Not built — and
        # deliberately absent rather than stubbed, so a sidecar can never expose them.
        pass

    return app
