"""Regression for issue #504: `/clusters/analyze` called
`registry.fetch_candidates_all` directly on its own request thread, with no
dedicated pool and no deadline — the one call the post-#488 review's #490 fix
did not reach, since #490 patched `_fetch_candidates`'s caller
(`candidates_extract`) rather than the shared extraction call itself.

`clusters_analyze` now goes through the same `_fetch_candidates` helper
`/candidates` uses, running the fetch on `Readiness._candidate_fetch_pool`
and giving up after `_CANDIDATE_FETCH_TIMEOUT_S` regardless of whether the
fetch itself ever returns. This asserts `/clusters/analyze` still answers
promptly with an honest per-layer timeout and that `/layers` (on the shared
pool) is untouched while the stuck fetch is still occupying its own pool —
the same shape `test_candidates_stuck_fetch.py` asserts for `/candidates`.
"""

from __future__ import annotations

import threading
import time

from fastapi.testclient import TestClient

from plotlines_core.curation.registry import LayerRegistry
from plotlines_service import app as app_module


def test_a_stuck_cluster_fetch_does_not_block_other_endpoints(tmp_path, monkeypatch):
    monkeypatch.setattr(app_module, "_CANDIDATE_FETCH_TIMEOUT_S", 0.2)

    # Bounded at 15s purely so a broken test can't hang the whole suite —
    # the test always calls `unblock.set()` itself, well before that, once
    # it no longer needs the fetch to be stuck.
    unblock = threading.Event()

    def hung_fetch_candidates_all(self, bbox, layers):
        unblock.wait(timeout=15.0)
        return [], {}

    monkeypatch.setattr(LayerRegistry, "fetch_candidates_all", hung_fetch_candidates_all)

    client = TestClient(app_module.create_app(tmp_path))

    analyze_result: dict = {}

    def call_clusters_analyze() -> None:
        start = time.monotonic()
        resp = client.post(
            "/clusters/analyze",
            json={"bbox": [0.0, 0.0, 0.01, 0.01], "layers": ["historic"]},
        )
        analyze_result["elapsed"] = time.monotonic() - start
        analyze_result["body"] = resp.json()

    analyze_thread = threading.Thread(target=call_clusters_analyze)
    analyze_thread.start()
    # Let the stuck fetch actually claim its worker before racing /layers
    # against it.
    time.sleep(0.05)

    try:
        start = time.monotonic()
        layers_resp = client.get("/layers")
        layers_elapsed = time.monotonic() - start
    finally:
        analyze_thread.join(timeout=5.0)
        unblock.set()  # release the now-orphaned candidate-fetch worker
        client.app.state.readiness.shutdown()

    assert not analyze_thread.is_alive(), "/clusters/analyze never returned"
    assert analyze_result["elapsed"] < 2.0, (
        "/clusters/analyze should give up on a stuck fetch, not wait on it")
    body = analyze_result["body"]
    assert body["layers_unavailable"] == {
        "historic": "failed:candidate_fetch_timed_out"}
    assert body["layers_served"] == []
    assert body["proposals"] == []

    assert layers_resp.status_code == 200
    assert layers_elapsed < 1.0, (
        f"/layers took {layers_elapsed:.2f}s with a stuck cluster fetch "
        "in flight — it must never share a thread pool with "
        "/clusters/analyze")
