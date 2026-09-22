"""Issue #497 — the request-thread contract (ARCH §8.6, D66, A30) as a
failing test, not a docstring.

#488 was the second time an unbounded blocking call on the shared FastAPI
thread pool took the sidecar down (#466 was the first, same WSL-DNS-timing
class), and the review that followed it found five more live instances plus
the client half: #490 (`/candidates`'s `OSM_SETTINGS_LOCK`), #491 (Overpass
outage fan-out), #492 (`RegionState.build`'s four network phases), #493
(`/geocode`'s `_NOMINATIM_LOCK`), #494 (`/clip`'s concurrency), #495
(`elevation_proxy`'s `/dem` lock) and #496 (the client's own call timeouts).
Each of those landed with its own regression test that checks *one* stuck
call at a time — this module is the gate that gaps between them can't get
through: every outbound-touching endpoint stuck **at once**, proving none of
their dedicated pools/deadlines leaks into another's, and a static check
that a new endpoint can't reach outbound code without going through one of
them.

Two test modules already cover the smaller shape this issue also asks for:
`test_mirror_clip_concurrency.py` (#494 — `/clip`'s `BoundedSemaphore`,
`/health` untouched) and `test_elevation_proxy_stuck_fetch.py` (#495 —
`/dem`'s dedicated pool, `/health` untouched, a different bbox's cache hit
never waits on a stuck one). Both are the same shape as the dynamic test
below, just against their own smaller app.
"""

from __future__ import annotations

import ast
import socket
import threading
import time
from pathlib import Path

import osmnx as ox
from fastapi.testclient import TestClient

from plotlines_core.curation.registry import LayerRegistry
from plotlines_service import app as app_module

_APP_PY = Path(app_module.__file__)

_BBOX_A = (-105.0, 40.0, -104.9, 40.1)
_BBOX_B = (-106.0, 41.0, -105.9, 41.1)

#: Every outbound call this module knows to whitelist as "reached through a
#: named helper that takes a pool and a deadline" (the #488 shape) rather
#: than "called directly from a handler body". Kept here, beside the lint,
#: rather than inline in it, so a reviewer sees the whole roster at once.
_ALLOWED_OUTBOUND_HELPERS = {
    "_mirror_capability",       # #488 — Readiness._mirror_state_pool
    "_geocode_via_nominatim",   # #493 — Readiness._geocode_pool
    "_fetch_candidates",        # #490 — Readiness._candidate_fetch_pool
}


def _wait_until(predicate, timeout: float = 5.0, interval: float = 0.02) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def _fast_graph(monkeypatch) -> None:
    """Settle the graph phase instantly — this module is about the *other*
    phases and the *other* endpoints, never about `ensure_graph` itself."""
    monkeypatch.setattr(
        app_module.region_lib, "ensure_graph",
        lambda region, cache_dir: region.graph_path(cache_dir))
    monkeypatch.setattr(app_module, "load_graphml", lambda path: object())


# ─────────────────────────────────────────────────────────────────────────
# The dynamic half — every outbound-touching endpoint stuck at once
# ─────────────────────────────────────────────────────────────────────────


def test_every_endpoint_answers_under_a_blocked_resolver(tmp_path, monkeypatch):
    # Shrink every phase/fetch deadline so the whole scenario — four
    # different stuck calls at once — stays well inside the module's 10s
    # budget rather than each waiting out a production-sized ceiling.
    monkeypatch.setattr(app_module, "_MIRROR_STATE_FETCH_TIMEOUT_S", 0.3)
    monkeypatch.setattr(app_module, "_CANDIDATE_FETCH_TIMEOUT_S", 0.3)
    monkeypatch.setattr(app_module, "_GEOCODE_FETCH_TIMEOUT_S", 0.3)
    monkeypatch.setattr(app_module, "_TILES_PHASE_TIMEOUT_S", 0.3)
    _fast_graph(monkeypatch)

    # Bounded at 15s purely so a broken test can't hang the suite — the
    # test always calls `unblock.set()` itself, well before that.
    unblock = threading.Event()

    def hang(*_args, **_kwargs):
        unblock.wait(timeout=15.0)
        raise AssertionError("should have been abandoned, not run to completion")

    # Bullet 1 of the issue — block the resolver itself as a second, belt-
    # and-suspenders layer. Nothing in this process makes a real DNS call
    # (every transport below is monkeypatched at the library entry point,
    # same as #488/#490/#492/#493's own tests), so this mainly documents the
    # leg no library timeout covers; the library-level patches just below
    # are what the endpoints actually exercise.
    real_getaddrinfo = socket.getaddrinfo

    def hung_getaddrinfo(*args, **kwargs):
        unblock.wait(timeout=15.0)
        return real_getaddrinfo(*args, **kwargs)

    monkeypatch.setattr(socket, "getaddrinfo", hung_getaddrinfo)

    monkeypatch.setattr(app_module, "load_mirror_state", hang)
    monkeypatch.setattr(
        LayerRegistry, "fetch_candidates_all",
        lambda self, bbox, layers: hang())
    monkeypatch.setattr(ox, "geocode_to_gdf", hang)
    monkeypatch.setattr(app_module, "extract_bbox", hang)

    client = TestClient(app_module.create_app(
        tmp_path, mirror_state_url="http://mirror.invalid/MIRROR_STATE.json"))

    results: dict = {}

    def call_health():
        start = time.monotonic()
        resp = client.get("/health")
        results["health"] = {"elapsed": time.monotonic() - start, "response": resp}

    def call_candidates():
        start = time.monotonic()
        resp = client.get(
            "/candidates",
            params={"west": 0.0, "south": 0.0, "east": 0.01, "north": 0.01,
                    "layers": "historic"})
        results["candidates"] = {"elapsed": time.monotonic() - start, "response": resp}

    def call_geocode():
        start = time.monotonic()
        resp = client.get("/geocode", params={"q": "Asheville, NC"})
        results["geocode"] = {"elapsed": time.monotonic() - start, "response": resp}

    def call_region_a():
        start = time.monotonic()
        resp = client.post("/regions", json={"bbox": list(_BBOX_A)})
        results["region_a"] = {"elapsed": time.monotonic() - start, "response": resp}

    stuck_threads = [
        threading.Thread(target=call_health),
        threading.Thread(target=call_candidates),
        threading.Thread(target=call_geocode),
        threading.Thread(target=call_region_a),
    ]
    for t in stuck_threads:
        t.start()
    # Let every stuck call actually claim its own worker before racing the
    # local endpoints (and region B) against them.
    time.sleep(0.1)

    try:
        # Bullet 5 — a second region for a different bbox must not queue
        # behind the first's stuck tiles phase.
        region_b_key = client.post(
            "/regions", json={"bbox": list(_BBOX_B)}).json()["region"]

        # Bullet 3 — every local, no-network endpoint stays fast while all
        # four of the above sit stuck.
        for name, call in [
            ("layers", lambda: client.get("/layers")),
            ("tiles", lambda: client.get("/tiles/0/0/0")),
            ("attribution", lambda: client.get("/attribution")),
            ("about", lambda: client.get("/about")),
        ]:
            start = time.monotonic()
            resp = call()
            elapsed = time.monotonic() - start
            assert resp.status_code < 500, (
                f"/{name} returned {resp.status_code} while every outbound "
                f"call was stuck: {resp.text}")
            assert elapsed < 1.0, (
                f"/{name} took {elapsed:.2f}s with every outbound-touching "
                "endpoint stuck at once — it must never share a pool with "
                "any of them")

        # Bullet 5, continued — region B must reach a settled or actively-
        # building state, never sit at the bare "pending" a wedged build
        # queue would leave it at.
        def region_b_moved_past_pending() -> bool:
            cap = client.get("/health").json()["capabilities"]["routing"]["regions"].get(
                region_b_key, {"reason": "pending"})
            return cap.get("ready") is True or cap.get("reason") != "pending"

        assert _wait_until(region_b_moved_past_pending, timeout=5.0), (
            "region B stayed 'pending' while region A was stuck in its "
            "tiles phase — the single build-pool worker was wedged")

        for t in stuck_threads:
            t.join(timeout=5.0)
    finally:
        unblock.set()
        for t in stuck_threads:
            t.join(timeout=5.0)
        client.app.state.readiness.shutdown()

    # Bullet 4 — every stuck endpoint gives up by its own deadline with an
    # honest body: never a hang (already implied by the join above
    # succeeding), never a bare 500.
    assert not any(t.is_alive() for t in stuck_threads)

    health = results["health"]
    assert health["elapsed"] < 2.0, f"/health took {health['elapsed']:.2f}s"
    assert health["response"].status_code == 200
    assert health["response"].json()["capabilities"]["mirror"]["stale"] is True

    candidates = results["candidates"]
    assert candidates["elapsed"] < 2.0, f"/candidates took {candidates['elapsed']:.2f}s"
    assert candidates["response"].status_code == 200
    assert candidates["response"].json()["layers_unavailable"] == {
        "historic": "failed:candidate_fetch_timed_out"}

    geocode = results["geocode"]
    assert geocode["elapsed"] < 2.0, f"/geocode took {geocode['elapsed']:.2f}s"
    assert geocode["response"].status_code == 503

    region_a = results["region_a"]
    assert region_a["response"].status_code == 202
    # `POST /regions` itself only ever *enqueues* — issue #492's phase
    # deadlines bound the build worker, not this call, so this returns
    # immediately regardless of what the queued build later gets stuck on.
    assert region_a["elapsed"] < 1.0, f"POST /regions took {region_a['elapsed']:.2f}s"


# ─────────────────────────────────────────────────────────────────────────
# The static half — a new outbound call in a handler body fails CI
# ─────────────────────────────────────────────────────────────────────────


def _endpoint_handlers(tree: ast.Module) -> list[ast.FunctionDef]:
    """Every function directly decorated `@app.get(...)` / `@app.post(...)`
    / etc. — walks the whole module rather than assuming a fixed nesting
    depth, since every handler in `app.py` is defined inside `create_app`."""
    handlers = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef):
            continue
        for decorator in node.decorator_list:
            if (isinstance(decorator, ast.Call)
                    and isinstance(decorator.func, ast.Attribute)
                    and isinstance(decorator.func.value, ast.Name)
                    and decorator.func.value.id == "app"
                    and decorator.func.attr in
                    {"get", "post", "put", "patch", "delete"}):
                handlers.append(node)
                break
    return handlers


def _direct_outbound_calls(node: ast.FunctionDef) -> list[str]:
    """Names of any `ox.<attr>`, `requests.<attr>`, `urlopen(...)` or
    `socket.create_connection(...)` reached directly inside `node`'s own
    body — a call routed through one of `_ALLOWED_OUTBOUND_HELPERS` instead
    is exactly the shape #488's fix established and is not flagged."""
    offenders = []
    for sub in ast.walk(node):
        if isinstance(sub, ast.Attribute) and isinstance(sub.value, ast.Name):
            if sub.value.id == "ox":
                offenders.append(f"ox.{sub.attr}")
            elif sub.value.id == "requests":
                offenders.append(f"requests.{sub.attr}")
        if isinstance(sub, ast.Call):
            fn = sub.func
            if isinstance(fn, ast.Name) and fn.id == "urlopen":
                offenders.append("urlopen(...)")
            if (isinstance(fn, ast.Attribute) and fn.attr == "create_connection"
                    and isinstance(fn.value, ast.Name) and fn.value.id == "socket"):
                offenders.append("socket.create_connection(...)")
    return offenders


def test_no_endpoint_handler_calls_outbound_code_directly():
    """The static half of the gate: a handler body may call a named helper
    that itself owns a pool and a deadline (`_ALLOWED_OUTBOUND_HELPERS` —
    the #488 shape), but never reach `ox.*` / `requests.*` / `urlopen` /
    `socket.create_connection` itself. This is what makes "add an outbound
    call to a handler" fail CI instead of relying on the next reviewer to
    notice — exactly the gap #488/#490/#492/#493 each slipped through
    despite a docstring already explaining why the call in question was
    supposedly safe."""
    tree = ast.parse(_APP_PY.read_text(encoding="utf-8"), filename=str(_APP_PY))
    handlers = _endpoint_handlers(tree)
    assert len(handlers) >= 15, (
        f"only found {len(handlers)} `@app.*` handlers in {_APP_PY} — the "
        "decorator-matching walk in this test likely broke, not that the "
        "app lost endpoints")

    violations = {}
    for handler in handlers:
        offenders = _direct_outbound_calls(handler)
        if offenders:
            violations[handler.name] = offenders

    assert violations == {}, (
        "the following endpoint handlers reach outbound code directly "
        f"instead of through a named, pooled, deadlined helper: {violations}")
