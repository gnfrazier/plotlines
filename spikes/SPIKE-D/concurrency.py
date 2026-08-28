"""SPIKE-D step 3 — do extraction and enrichment actually run concurrently, and
what do the Author's surfaces feel like while enrichment runs behind them?
Issue #159 point 2.

FR121 does not merely reorder two operations; it says the Author *works during*
the second one. That is a claim about a single Python process under one GIL,
and it is not answered by the ordering. Elevation enrichment is numpy and
rasterio over tens of thousands of graph nodes; notability scoring is a pure
Python loop over tens of thousands of features. If the first starves the
second, FR121's promise fails in a way no amount of correct `/health`
reporting would disclose.

The harness is the sidecar's own shape, not a simulation of it:

  * the real `create_app` served by **real uvicorn** on loopback, because
    `TestClient` runs the app in a portal thread and would confound exactly
    the scheduling this measures;
  * enrichment on a **daemon thread**, which is where `RegionState.build`
    already puts region work today;
  * requests issued over real HTTP from the main thread, so a blocked event
    loop shows up as latency rather than being invisible.

Three questions, each measured solo and then concurrently:

  1. **Does enrichment starve extraction?** `score_notability` over the real
     TRIP feature set — the POI-indexing half of FR121's "completes first".
  2. **Does extraction starve enrichment?** The same enrichment pass, timed
     with and without the authoring load running.
  3. **What does the Author feel?** p50/p95/max latency on `GET /health`
     (the client's poller) and `POST /candidates/score` (the workspace's hot
     path), idle versus during enrichment.

Requires `probe.py --phase graph --phase elevation` to have run: the
enrichment workload is a real graph and a real DEM, not a busy-loop.

Usage:
    .venv/bin/python spikes/SPIKE-D/concurrency.py [--json]
"""

from __future__ import annotations

import argparse
import statistics
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "service"))

import common  # noqa: E402
import requests  # noqa: E402
import uvicorn  # noqa: E402
from common import ALL_LAYERS, HERE  # noqa: E402
from regions import TRIP  # noqa: E402

from plotlines_core.curation.notability import score_notability  # noqa: E402
from plotlines_service.app import create_app  # noqa: E402

DEM = HERE / "cache" / "trip_dem.tif"
REGION_CACHE = HERE / "cache" / "regions"
SHARED_FIXTURES = HERE.parents[0] / "shared" / "fixtures"


def substrate() -> tuple[Path, Path, str]:
    """The graph and DEM the enrichment thread works over.

    Prefers the TRIP pair built by `probe.py --phase graph --phase elevation`.
    Falls back to SPIKE-01/02/03's committed Boulder fixture, because what
    this script measures is **contention between two threads in one Python
    process** — whether elevation enrichment starves notability scoring and
    the HTTP handlers — and that is a property of the interpreter and the
    libraries, not of which valley the graph came from. Which substrate ran
    is recorded in the output either way, and RESULTS says so.
    """
    from plotlines_core.graph import regions as region_lib

    trip_graph = region_lib.region_for(TRIP.bbox_lonlat, "bike").graph_path(REGION_CACHE)
    if trip_graph.exists() and DEM.exists():
        return trip_graph, DEM, f"TRIP ({TRIP.name})"

    boulder = SHARED_FIXTURES / "boulder.graphml"
    boulder_dem = SHARED_FIXTURES / "boulder_dem.tif"
    if boulder.exists() and boulder_dem.exists():
        return boulder, boulder_dem, "SPIKE-01/02/03 Boulder fixture (TRIP pair absent)"

    raise SystemExit(
        "no graph+DEM pair available — run probe.py --phase graph --phase elevation, "
        "or build the shared fixtures (spikes/shared/regions.py)"
    )


# ------------------------------------------------------------------ workloads


class Enrichment:
    """FR91's blocking, minutes-long operation, on a daemon thread.

    Samples every graph node against the DEM and recomputes edge grades —
    `spikes/shared/regions.py`'s own enrichment step, which is what a real
    `enrich_elevation` (ARCH §6.1) does. Loops until stopped so the load
    outlasts the measurement rather than the measurement chasing it.
    """

    def __init__(self, graph, dem_path: Path, extra_samples: int = 0) -> None:
        self.graph = graph
        self.dem_path = dem_path
        # FR91 calls enrichment "minutes-long"; the fixture graphs here are a
        # few seconds. `extra_samples` adds raster reads through
        # `ElevationSampler.sample` — the product's own read path — so a pass
        # can be scaled to a realistic duration and the contention tax can be
        # checked for whether it is a constant or grows with the job.
        self.extra_samples = extra_samples
        self._stop = threading.Event()
        self.passes = 0
        self.pass_times: list[float] = []
        self.thread: threading.Thread | None = None
        self._coords = self._sample_coords() if extra_samples else []

    def _sample_coords(self) -> list[tuple[float, float]]:
        import random

        import rasterio

        with rasterio.open(self.dem_path) as ds:
            west, south, east, north = ds.bounds
        rng = random.Random(159)  # the issue number — deterministic across runs
        return [(rng.uniform(south, north), rng.uniform(west, east))
                for _ in range(self.extra_samples)]

    def _one_pass(self) -> float:
        import osmnx as ox

        from plotlines_core.elevation.sampler import ElevationSampler

        t0 = time.perf_counter()
        g = ox.elevation.add_node_elevations_raster(self.graph, self.dem_path, cpus=1)
        ox.elevation.add_edge_grades(g, add_absolute=True)
        if self._coords:
            sampler = ElevationSampler(self.dem_path)
            try:
                sampler.sample(self._coords)
            finally:
                sampler.close()
        return time.perf_counter() - t0

    def _run(self) -> None:
        while not self._stop.is_set():
            self.pass_times.append(self._one_pass())
            self.passes += 1

    def __enter__(self) -> "Enrichment":
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        # Let the first pass get past import/open before anything is timed
        # against it, or the "concurrent" window measures rasterio's setup.
        time.sleep(1.0)
        return self

    def __exit__(self, *exc) -> None:
        self._stop.set()
        if self.thread is not None:
            self.thread.join(timeout=120)

    def solo_pass_s(self) -> float:
        """One uncontended pass — the denominator for question 2."""
        return self._one_pass()


def _percentiles(samples: list[float]) -> dict:
    if not samples:
        return {}
    ordered = sorted(samples)
    return {
        "n": len(ordered),
        "p50_ms": round(statistics.median(ordered) * 1000, 1),
        "p95_ms": round(ordered[min(int(len(ordered) * 0.95), len(ordered) - 1)] * 1000, 1),
        "max_ms": round(ordered[-1] * 1000, 1),
        "mean_ms": round(statistics.fmean(ordered) * 1000, 1),
    }


def _poll(url: str, n: int, *, post: dict | None = None) -> list[float]:
    samples = []
    session = requests.Session()
    for _ in range(n):
        t0 = time.perf_counter()
        if post is None:
            resp = session.get(url, timeout=60)
        else:
            resp = session.post(url, json=post, timeout=60)
        resp.raise_for_status()
        samples.append(time.perf_counter() - t0)
    return samples


def _index_pass(features) -> float:
    t0 = time.perf_counter()
    score_notability(features, live_layers=set(ALL_LAYERS))
    return time.perf_counter() - t0


# --------------------------------------------------------------------- server


def serve(app, port: int) -> uvicorn.Server:
    config = uvicorn.Config(app, host="127.0.0.1", port=port,
                            log_level="error", access_log=False)
    server = uvicorn.Server(config)
    threading.Thread(target=server.run, daemon=True).start()
    for _ in range(200):
        if server.started:
            return server
        time.sleep(0.05)
    raise RuntimeError("uvicorn did not start")


def free_port() -> int:
    import socket

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--out", default="concurrency.json",
                    help="results filename, so two enrichment scales can both be kept")
    ap.add_argument("--requests", type=int, default=60)
    ap.add_argument("--index-passes", type=int, default=5)
    ap.add_argument("--extra-samples", type=int, default=0,
                    help="extra DEM point-samples per enrichment pass, to scale "
                         "one pass toward FR91's 'minutes-long' (0 = graph only)")
    args = ap.parse_args()

    import osmnx as ox

    from plotlines_core.graph import regions as region_lib

    graph_path, dem_path, substrate_name = substrate()
    if not common.has_features("trip-all"):
        raise SystemExit("missing raw/trip-all.json.gz — run probe.py --phase extract")

    graph = ox.io.load_graphml(graph_path)
    features = common.load_features("trip-all")
    print(f"  substrate: {substrate_name}")
    print(f"  workload:  {graph.number_of_nodes():,}-node graph, "
          f"{len(features):,} raw features, {dem_path.stat().st_size / 1e6:.1f} MB DEM")

    port = free_port()
    app = create_app(HERE / "cache" / "concurrency")
    serve(app, port)
    base = f"http://127.0.0.1:{port}"
    score_body = {
        "live_layers": sorted(ALL_LAYERS),
        "features": [{"id": f.id, "coord": list(f.coord), "tags": f.tags,
                      "area_m2": f.area_m2} for f in features],
    }

    def workload(rounds: int) -> tuple[list[float], list[float], list[float], list[float]]:
        """One measurement window, **interleaved**: each round does an index
        pass, a burst of `/health` and `/layers` polls, and one
        `/candidates/score`.

        Interleaving rather than running each metric to completion in turn is
        not a stylistic choice. Enrichment is a repeating multi-second pass
        with distinct phases — raster open, node sampling, grade computation —
        and running one metric at a time samples one phase each, which is how
        the same script first reported notability both unaffected (x0.88) and
        3.5x slower on different runs. Every metric now sees the same mixture.
        """
        idx, health, layers, score = [], [], [], []
        per_round = max(args.requests // rounds, 1)
        for _ in range(rounds):
            idx.append(_index_pass(features))
            health.extend(_poll(f"{base}/health", per_round))
            layers.extend(_poll(f"{base}/layers", per_round))
            score.extend(_poll(f"{base}/candidates/score", 1, post=score_body))
        return idx, health, layers, score

    # ------------------------------------------------------------ solo
    print("\n=== solo (nothing else running) ===")
    idx_solo, health_solo, layers_solo, score_solo = workload(args.index_passes)
    enrich = Enrichment(graph, dem_path, extra_samples=args.extra_samples)
    enrich_solo = enrich.solo_pass_s()
    print(f"  score_notability      {statistics.fmean(idx_solo) * 1000:8.1f} ms mean "
          f"({len(features):,} features)")
    print(f"  GET  /health          {_percentiles(health_solo)['p50_ms']:8.1f} ms p50   "
          f"p95 {_percentiles(health_solo)['p95_ms']:.1f}")
    print(f"  GET  /layers          {_percentiles(layers_solo)['p50_ms']:8.1f} ms p50")
    print(f"  POST /candidates/score{_percentiles(score_solo)['p50_ms']:8.1f} ms p50")
    print(f"  enrichment pass       {enrich_solo:8.2f} s")

    # ------------------------------------------------------ concurrent
    print("\n=== with elevation enrichment running behind the Author ===")
    with enrich:
        idx_load, health_load, layers_load, score_load = workload(args.index_passes)
        # Keep the authoring load running until enrichment has finished at
        # least one contended pass, or question 2 has no numerator.
        while not enrich.pass_times:
            workload(1)
        enrich_conc = statistics.fmean(enrich.pass_times)

    idx_ratio = statistics.fmean(idx_load) / statistics.fmean(idx_solo)
    print(f"  score_notability      {statistics.fmean(idx_load) * 1000:8.1f} ms mean   "
          f"x{idx_ratio:.2f} vs solo")
    print(f"  GET  /health          {_percentiles(health_load)['p50_ms']:8.1f} ms p50   "
          f"p95 {_percentiles(health_load)['p95_ms']:.1f}   "
          f"max {_percentiles(health_load)['max_ms']:.1f}")
    print(f"  GET  /layers          {_percentiles(layers_load)['p50_ms']:8.1f} ms p50   "
          f"p95 {_percentiles(layers_load)['p95_ms']:.1f}")
    print(f"  POST /candidates/score{_percentiles(score_load)['p50_ms']:8.1f} ms p50   "
          f"p95 {_percentiles(score_load)['p95_ms']:.1f}")
    if enrich_conc:
        print(f"  enrichment pass       {enrich_conc:8.2f} s   "
              f"x{enrich_conc / enrich_solo:.2f} vs solo "
              f"({enrich.passes} passes completed)")

    out = {
        "workload": {
            "graph_nodes": graph.number_of_nodes(),
            "graph_edges": graph.number_of_edges(),
            "raw_features": len(features),
            "dem_bytes": dem_path.stat().st_size,
            "substrate": substrate_name,
            "extra_samples_per_pass": args.extra_samples,
        },
        "solo": {
            "score_notability_ms": round(statistics.fmean(idx_solo) * 1000, 1),
            "health": _percentiles(health_solo),
            "layers": _percentiles(layers_solo),
            "candidates_score": _percentiles(score_solo),
            "enrichment_pass_s": round(enrich_solo, 2),
        },
        "under_enrichment": {
            "score_notability_ms": round(statistics.fmean(idx_load) * 1000, 1),
            "score_notability_slowdown": round(idx_ratio, 2),
            "health": _percentiles(health_load),
            "layers": _percentiles(layers_load),
            "candidates_score": _percentiles(score_load),
            "enrichment_pass_s": round(enrich_conc, 2) if enrich_conc else None,
            "enrichment_slowdown": (round(enrich_conc / enrich_solo, 2)
                                    if enrich_conc else None),
            "enrichment_passes": enrich.passes,
        },
    }
    if args.json:
        print(f"\nwrote {common.write_results(args.out, out)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
