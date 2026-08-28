"""SPIKE-D step 2 — exercise the `/health` contract, including a failing
layer. Issue #159 point 3; ARCH §8.3 (breaking B1); PRD N2, M12a.

Two apps, the same eight clauses.

**Shipped** is `plotlines_service.app.create_app` as it stands after issue
#154 — the real thing, not a mock. #154 built per-capability readiness and
per-*region* routing readiness and got both right; what it did not build is
the per-*layer* half, because at the time every layer was built-in,
synchronous, and served by one provider, so there was nothing for a state
machine to describe.

**Prototype** is the same contract with `plugin_layers.LayerRegistry` behind
`capabilities.layers` and a `/candidates` that subtracts a failed layer
instead of aborting. It exists to show that the clauses the shipped app misses
are missable — that they need a mechanism, not a wider `try`.

The clauses are N2's acceptance criteria and §8.3's four rules, one assertion
each. A clause is only reported PASS when the *behaviour* holds; nothing here
counts a plausible-looking response body as a pass.

Usage:
    .venv/bin/python spikes/SPIKE-D/health.py           # table
    .venv/bin/python spikes/SPIKE-D/health.py --json    # -> results/health.json
"""

from __future__ import annotations

import argparse
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "core"))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "service"))

import common  # noqa: E402,F401  — sets the osmnx cache location
from fastapi import FastAPI, HTTPException  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from plugin_layers import (  # noqa: E402
    LayerRegistry, StubPluginProvider, UnlicensedPluginProvider,
)
from plotlines_core.curation.notability import RawFeature, RULESET_VERSION, score_notability  # noqa: E402
from plotlines_core.curation.providers import BBox  # noqa: E402
from plotlines_core.curation.taxonomy import LAYERS  # noqa: E402
from plotlines_service.app import create_app  # noqa: E402

# Two features inside the TRIP bbox so a plugin layer has something to return
# and "the workspace still works" is checked by getting real candidates back,
# not by a 200.
_BATTLEFIELD = RawFeature(id="plugin/battle-1", coord=(-81.95, 36.00),
                          tags={"historic": "battlefield", "name": "Test Ridge"})
_MANOR = RawFeature(id="plugin/manor-1", coord=(-81.92, 36.02),
                    tags={"historic": "manor", "name": "Test Manor"})

# A bbox that is never pre-seeded, so `POST /regions` settles to failed with
# no network — the "a capability failing must not block the others" case.
_MISSING_BBOX = [-1.0, -1.0, 1.0, 1.0]


class Offline:
    """No test in this file may reach Overpass. Both apps get a provider that
    returns fixtures, and `graph_from_bbox` is refused outright (below), so a
    region build fails deterministically instead of querying the commons for a
    bbox in the middle of the Atlantic.

    `fail_on` models the realistic per-layer failure: one layer in a live set
    whose upstream is down, inside a `fetch` that covers several layers at
    once. That is the shape `OsmLayerProvider` has — one call, many layers —
    and it is the case C6 turns on.
    """

    licence = "ODbL"

    def __init__(self, fail_on: set[str] | None = None) -> None:
        self.fail_on = fail_on or set()

    def fetch(self, bbox: BBox, layers: set[str]) -> list[RawFeature]:
        bad = self.fail_on & layers
        if bad:
            raise TimeoutError(f"upstream timed out for {sorted(bad)}")
        return [f for f in (_BATTLEFIELD, _MANOR) if "historic" in layers]


def _refuse_network() -> None:
    """`ensure_graph` calls `ox.graph_from_bbox` on a cache miss. Every region
    in this file is deliberately un-cached, so without this the "a failing
    capability must not block the others" clause is tested by making a real
    multi-megabyte Overpass query — the exact load A23 is a risk about."""
    import osmnx as ox

    def refuse(*_args, **_kwargs):
        raise RuntimeError("no network access in this spike's health checks")

    ox.graph_from_bbox = refuse


# ------------------------------------------------------------------ prototype


def build_prototype(cache_dir: Path) -> tuple[FastAPI, LayerRegistry]:
    """The shipped app plus the per-layer mechanism, mounted as its own
    routes. `/health2` and `/candidates2` rather than replacing the originals:
    FastAPI keeps the first route registered for a path, and a spike that
    silently shadowed the shipped endpoints would be comparing two things it
    could not tell apart."""
    app = create_app(cache_dir)
    app.state.layer_provider = Offline()

    registry = LayerRegistry()
    registry.register_builtin(set(LAYERS), Offline())
    registry.register_plugin(
        "plugin_battlefields",
        StubPluginProvider(licence="CC-BY-4.0", features=[_BATTLEFIELD]),
        warmup_s=1.5, estimated_s=2.0,
    )
    registry.register_plugin("plugin_manors", UnlicensedPluginProvider())
    registry.register_plugin(
        "plugin_crags",
        StubPluginProvider(licence="ODbL",
                           raise_on_fetch=TimeoutError("upstream crag API timed out")),
    )

    @app.get("/health2")
    def health2() -> dict:
        body = app.state.readiness
        return {
            "capabilities": {
                "tiles": {"ready": True},
                "layers": registry.capability(),
                "layers_detail": registry.per_layer_detail(),
                "routing": {"regions": body.routing_capabilities()},
                "elevation": {"ready": False,
                              "reason": "elevation_source_not_configured:tracked_in_148"},
            },
        }

    @app.get("/candidates2")
    def candidates2(west: float, south: float, east: float, north: float,
                    layers: str) -> dict:
        live = {l for l in layers.split(",") if l}
        if not live:
            raise HTTPException(422, "no live layers requested")
        features, errors = registry.fetch(BBox(west, south, east, north), live)
        served = live - set(errors)
        candidates = score_notability(features, live_layers=served)
        return {
            "ruleset_version": RULESET_VERSION,
            "candidates": [{"id": c.id, "layer": c.layer, "salience": c.salience}
                           for c in candidates],
            # The half the shipped shape has no room for: what the Author got
            # is not what the Author asked for, and they are told which part.
            "layers_served": sorted(served),
            "layers_unavailable": errors,
        }

    return app, registry


# -------------------------------------------------------------------- clauses


class Report:
    def __init__(self) -> None:
        self.rows: list[dict] = []

    def check(self, app_name: str, clause: str, source: str, ok: bool,
              observed: str) -> None:
        self.rows.append({"app": app_name, "clause": clause, "source": source,
                          "pass": bool(ok), "observed": observed})

    def to_dict(self) -> dict:
        return {
            "clauses": self.rows,
            "summary": {
                app: {
                    "passed": sum(1 for r in self.rows if r["app"] == app and r["pass"]),
                    "total": sum(1 for r in self.rows if r["app"] == app),
                }
                for app in dict.fromkeys(r["app"] for r in self.rows)
            },
        }


def _wait_until(fn, predicate, timeout: float = 20.0):
    deadline = time.perf_counter() + timeout
    value = fn()
    while not predicate(value):
        if time.perf_counter() > deadline:
            return value
        time.sleep(0.05)
        value = fn()
    return value


def exercise(name: str, client: TestClient, health_path: str, candidates_path: str,
             report: Report, *, registry: LayerRegistry | None = None) -> None:
    caps = client.get(health_path).json()["capabilities"]
    bbox_q = {"west": -82.10, "south": 35.90, "east": -81.78, "north": 36.12}

    # C1 — §8.3: the Curation Workspace is usable before any region work.
    report.check(name, "C1 layers ready immediately", "ARCH §8.3, N2",
                 caps["layers"].get("ready") is True,
                 f"layers.ready={caps['layers'].get('ready')}")

    # C2 — N2: per-layer state lives inside the layers capability.
    per = caps["layers"].get("per_layer", {})
    report.check(name, "C2 per_layer present", "N2, ARCH §8.3",
                 bool(per), f"{len(per)} layers reported")

    # C3 — N2: a slow plugin layer is `loading` while built-ins are usable.
    loading = [k for k, v in per.items() if v == "loading"]
    builtin_ready = all(per.get(l) == "ready" for l in LAYERS if l in per)
    report.check(name, "C3 slow plugin layer shows loading", "N2 AC",
                 bool(loading) and builtin_ready,
                 f"loading={loading or 'none'}, builtins ready={builtin_ready}")

    # C4 — N2: a failure names which layer and why.
    failed = {k: v for k, v in per.items() if v.startswith("failed")}
    named = any(":" in v and v.split(":", 1)[1] for v in failed.values())
    report.check(name, "C4 failure names layer and reason", "N2 AC, ARCH §8.3",
                 bool(failed) and named,
                 f"failed={failed or 'none'}")

    # C5 — N2: one layer failing never blocks the others or the workspace.
    report.check(name, "C5 failed layer does not gate the capability", "N2 AC",
                 bool(failed) and caps["layers"].get("ready") is True,
                 f"{len(failed)} failed, layers.ready={caps['layers'].get('ready')}")

    # C6 — N2: extraction over a mixed live set still serves the good layers.
    mixed = ",".join(sorted(LAYERS)) + ",plugin_crags"
    resp = client.get(candidates_path, params={**bbox_q, "layers": mixed})
    served_ok = resp.status_code == 200 and bool(resp.json().get("candidates"))
    report.check(name, "C6 extraction survives one bad layer", "N2 AC",
                 served_ok,
                 f"HTTP {resp.status_code}, "
                 f"{len(resp.json().get('candidates', [])) if resp.status_code == 200 else 0} "
                 f"candidates back")

    # C7 — N2 / M13: the Author is told which layers they did not get.
    told = resp.status_code == 200 and bool(resp.json().get("layers_unavailable"))
    report.check(name, "C7 response names unavailable layers", "N2 AC, M13",
                 told,
                 (f"layers_unavailable="
                  f"{resp.json().get('layers_unavailable') if resp.status_code == 200 else 'n/a'}"))

    # C8 — B1: a failing *region* build never touches the layers capability.
    key = client.post("/regions", json={"bbox": _MISSING_BBOX}).json()["region"]
    body = _wait_until(
        lambda: client.get(health_path).json()["capabilities"],
        lambda c: c["routing"]["regions"].get(key, {}).get("reason", "").startswith("failed:"),
        timeout=30.0,
    )
    region_failed = body["routing"]["regions"].get(key, {}).get("reason", "").startswith("failed:")
    report.check(name, "C8 failed region leaves layers ready", "ARCH §8.3 B1",
                 region_failed and body["layers"].get("ready") is True,
                 f"region failed={region_failed}, layers.ready={body['layers'].get('ready')}")

    if registry is not None:
        # The loading plugin should settle to ready on its own — a `loading`
        # that never resolves is the spinner N2 exists to remove.
        settled = _wait_until(registry.per_layer,
                              lambda p: p.get("plugin_battlefields") == "ready",
                              timeout=10.0)
        report.check(name, "C9 loading layer settles to ready", "N2 AC, FR121",
                     settled.get("plugin_battlefields") == "ready",
                     f"plugin_battlefields={settled.get('plugin_battlefields')}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    report = Report()
    _refuse_network()

    with tempfile.TemporaryDirectory() as tmp:
        shipped = create_app(Path(tmp))
        shipped.state.layer_provider = Offline(fail_on={"plugin_crags"})
        with TestClient(shipped) as client:
            exercise("shipped", client, "/health", "/candidates", report)

    with tempfile.TemporaryDirectory() as tmp:
        proto, registry = build_prototype(Path(tmp))
        with TestClient(proto) as client:
            exercise("prototype", client, "/health2", "/candidates2", report,
                     registry=registry)

    width = max(len(r["clause"]) for r in report.rows)
    for app in ("shipped", "prototype"):
        print(f"\n=== {app} ===")
        for row in report.rows:
            if row["app"] != app:
                continue
            mark = "PASS" if row["pass"] else "FAIL"
            print(f"  {mark}  {row['clause']:<{width}}  {row['observed']}")
    summary = report.to_dict()["summary"]
    print()
    for app, s in summary.items():
        print(f"  {app:10} {s['passed']}/{s['total']} clauses")

    if args.json:
        path = common.write_results("health.json", report.to_dict())
        print(f"\nwrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
