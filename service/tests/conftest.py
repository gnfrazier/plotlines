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

import pytest

from plotlines_service.app import DiagnoseRegistry, Readiness


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
