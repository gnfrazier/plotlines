"""Shared teardown for the service suite.

`create_app` starts two bounded worker pools — `Readiness`'s region-build pool
and `DiagnoseRegistry`'s — and `lifespan` shuts them down. But `TestClient` only
runs lifespan when it is used as a context manager, and most of this suite
constructs the client directly, so nothing closed them.

A leaked build pool is not merely untidy: a test that monkeypatches
`RegionState.build` or `region_lib.ensure_graph`, queues a build and returns
without joining leaves that build to run *after* pytest has reverted the patch.
It then does the real thing — a live Overpass fetch against the network — and
logs its failure into a `tmp_path` handler that has since been torn down, which
is where the stray "--- Logging error ---" in a full-suite run came from. A
suite that reaches the network is slow, flaky, and dependent on a third party
being up.

The hook is on the two constructors rather than on `create_app`, because tests
import `create_app` by name (`from plotlines_service.app import create_app`) and
a patch on the module attribute would not reach a name already bound in the test
module. Autouse, because the leak is invisible in the test that causes it and
surfaces somewhere else entirely (#235 C).
"""

from __future__ import annotations

import shutil
import time
from pathlib import Path

import networkx as nx
import osmnx as ox
import pytest
from fastapi.testclient import TestClient

from plotlines_core.graph import regions as region_lib
from plotlines_core.graph.loader import LoadedGraph
from plotlines_service import app as app_mod
from plotlines_service.app import DiagnoseRegistry, Readiness, create_app


@pytest.fixture(autouse=True)
def _stub_overpass_connect_probe(monkeypatch):
    """`ensure_graph` (issue #245) opens a real socket to each Overpass
    endpoint before it calls osmnx. This suite is never meant to touch the
    network, so report every endpoint reachable — a test that patches
    `graph_from_bbox` / `ensure_graph` is unaffected, and behaviour past the
    probe is exactly what it was before #245.
    """
    monkeypatch.setattr(region_lib, "probe_endpoint", lambda *_a, **_kw: None)


@pytest.fixture(autouse=True)
def shutdown_worker_pools(monkeypatch):
    """Close every pool built during a test, however the app was constructed."""
    built: list[Readiness | DiagnoseRegistry] = []

    for cls in (Readiness, DiagnoseRegistry):
        original = cls.__init__

        def tracking_init(self, *args, __original=original, **kwargs):
            __original(self, *args, **kwargs)
            built.append(self)

        monkeypatch.setattr(cls, "__init__", tracking_init)

    yield

    for instance in built:
        # `cancel_futures=True` (inside each `shutdown`) abandons anything still
        # queued; an in-flight build is left to finish rather than being torn
        # out from under itself.
        instance.shutdown()


# --- A ready Boulder region, parsed once per session -----------------------
#
# Seven endpoint suites used to carry a byte-identical `_client_with_boulder_
# region(tmp_path)` helper: copy the committed SPIKE-00 fixture graph to the
# exact cache path `ensure_graph` would build it at (so the build is a cache
# hit and never touches the network), start an app, `POST /regions`, poll
# `/health` until ready. Correct, but every one of its ~40 callers paid
# `ox.io.load_graphml` on the same 6 MB file — 0.4 s each, most of the
# service suite's wall time — to end up with the same graph.
#
# The fixture keeps every step of that contract (the on-disk copy, the 202-
# and-queue build, the readiness poll — `test_health.py` is what asserts the
# real parse path, and it still does its own copy without this fixture) and
# swaps only the parse: `plotlines_service.app.load_graphml` returns a
# `.copy()` of a session-cached graph. `nx.Graph.copy` gives each test fresh
# node/edge attribute dicts, which is the isolation the solvers need — they
# annotate edges in place (`_pl_access_flags`, `interest_salience`,
# `_pl_feat`) but never mutate an attribute *value* — at ~25 ms instead of
# 400. The patch is scoped to the fixture's own `monkeypatch`, so a test that
# does not request `boulder_region` sees the real loader.

_FIXTURE_GRAPH = (Path(__file__).resolve().parents[2] / "spikes" / "SPIKE-00" / "fixtures"
                  / "boulder_bike.graphml")
#: SPIKE-00's own fixture bbox. Exported so a test can post it back to
#: `/regions` and assert the key it gets is the one already built.
BOULDER_BBOX = [-105.30, 39.99, -105.25, 40.03]


@pytest.fixture(scope="session")
def _boulder_graph() -> nx.MultiDiGraph:
    if not _FIXTURE_GRAPH.exists():
        pytest.skip("SPIKE-00 fixture graph not present in this checkout")
    return ox.io.load_graphml(_FIXTURE_GRAPH)


@pytest.fixture
def boulder_region(tmp_path: Path, monkeypatch,
                   _boulder_graph: nx.MultiDiGraph) -> tuple[TestClient, str]:
    """`(client, key)` for an app rooted at `tmp_path` whose Boulder region
    is already built and reporting ready."""
    def _cached_load(path) -> LoadedGraph:
        return LoadedGraph(graph=_boulder_graph.copy(), source=Path(path),
                           load_seconds=0.0)
    monkeypatch.setattr(app_mod, "load_graphml", _cached_load)

    key = region_lib.region_key(tuple(BOULDER_BBOX), "bike")
    dest = tmp_path / "regions" / key / "graph.graphml"
    dest.parent.mkdir(parents=True)
    shutil.copy(_FIXTURE_GRAPH, dest)

    client = TestClient(create_app(tmp_path))
    got_key = client.post("/regions", json={"bbox": BOULDER_BBOX}).json()["region"]
    assert got_key == key

    deadline = time.perf_counter() + 20.0
    while not client.get("/health").json()["capabilities"]["routing"]["regions"][key]["ready"]:
        if time.perf_counter() > deadline:
            raise AssertionError("Boulder region never became ready")
        time.sleep(0.02)
    return client, key
