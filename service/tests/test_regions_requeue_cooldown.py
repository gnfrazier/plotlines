"""Issue #247 — cooldown and cap between a settled region-build failure and
the next requeue. OSM acquisition review §5.6, closing #238's second
mechanism.

Before this, `Readiness.ensure_region`'s `REQUEUE_AFTER_FAILURE` branch had no
floor: the client's 2 s `/health` poll (and, pre-#246, its per-revision
`POST /regions`) re-ran a build the instant the last one settled `failed`, so
an unreachable Overpass endpoint was retried tens of times a minute — the load
profile that earns an IP-level block.

The rules under test:

* a post-failure **cooldown** (`REGION_REQUEUE_COOLDOWN_S`) gates the next
  *accepted* requeue for a region key;
* an **automatic-requeue cap** (`REGION_AUTOMATIC_REQUEUE_CAP`) stops the
  `/health`-driven path entirely once a dead endpoint has been retried enough;
* the Author's explicit FR121 "Try again" (`manual=True`) may bypass the
  cooldown **once per window** and is not subject to the cap — but a second
  press inside the window is refused, so it cannot itself hold the loop open;
* every refusal leaves a **finished, legible sentence** on the routing
  capability reason (FR121's "stated reason"), never silence.
"""

from __future__ import annotations

import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient

from plotlines_core.graph import regions as region_lib
from plotlines_service.app import (
    REGION_AUTOMATIC_REQUEUE_CAP,
    Readiness,
    RegionState,
    create_app,
)

_BBOX = (-105.0, 40.0, -104.9, 40.1)


def _failed_region(*, automatic_requeues: int = 0,
                   cooldown_bypassed_at: float | None = None,
                   failed_at: float | None = None) -> RegionState:
    r = RegionState("k", _BBOX, "bike")
    r.graph_state.fail("Couldn't reach the map-data service ...")
    r.failed_at = time.monotonic() if failed_at is None else failed_at
    r.automatic_requeues = automatic_requeues
    r.cooldown_bypassed_at = cooldown_bypassed_at
    return r


# ── plan_requeue_after_failure — the pure verdict ───────────────────────────


def test_automatic_requeue_inside_the_cooldown_is_refused_with_a_countdown():
    r = _failed_region()
    now = r.failed_at + 5.0  # 5 s into a 60 s window

    d = r.plan_requeue_after_failure(manual=False, now=now)

    assert d.accepted is False
    assert d.bypassed_cooldown is False
    # A finished sentence with the remaining wait in it — not silence.
    assert d.reason.endswith(".")
    assert re.search(r"\b\d+ s\.", d.reason), d.reason
    assert "55 s" in d.reason  # ceil(60 - 5)


def test_automatic_requeue_is_accepted_once_the_cooldown_has_elapsed():
    r = _failed_region()
    now = r.failed_at + 61.0

    d = r.plan_requeue_after_failure(manual=False, now=now)

    assert d.accepted is True
    assert d.bypassed_cooldown is False
    assert d.reason == ""


def test_manual_try_again_bypasses_the_cooldown_exactly_once_per_window():
    r = _failed_region()
    t0 = r.failed_at + 2.0

    first = r.plan_requeue_after_failure(manual=True, now=t0)
    assert first.accepted is True
    assert first.bypassed_cooldown is True

    # The caller records the bypass; a second press 1 s later is inside the
    # same window and is refused — the manual path cannot itself be the loop.
    r.cooldown_bypassed_at = t0
    second = r.plan_requeue_after_failure(manual=True, now=t0 + 1.0)
    assert second.accepted is False
    assert re.search(r"\b\d+ s\.", second.reason), second.reason

    # A full cooldown after the bypass, it is available again.
    third = r.plan_requeue_after_failure(manual=True, now=t0 + 61.0)
    assert third.accepted is True


def test_after_the_cap_the_automatic_path_stops_with_a_finished_sentence():
    r = _failed_region(automatic_requeues=REGION_AUTOMATIC_REQUEUE_CAP,
                       failed_at=time.monotonic() - 3600)  # cooldown long gone

    d = r.plan_requeue_after_failure(manual=False, now=time.monotonic())

    assert d.accepted is False
    assert d.reason.endswith(".")
    assert str(REGION_AUTOMATIC_REQUEUE_CAP) in d.reason
    assert "stopped" in d.reason.lower()
    assert "try again" in d.reason.lower()  # tells the Author the way forward


def test_manual_try_again_is_not_subject_to_the_cap():
    r = _failed_region(automatic_requeues=REGION_AUTOMATIC_REQUEUE_CAP,
                       failed_at=time.monotonic() - 3600)

    d = r.plan_requeue_after_failure(manual=True, now=time.monotonic())

    assert d.accepted is True


# ── ensure_region — the wiring, under a poll ────────────────────────────────


def _always_fails(monkeypatch) -> list[int]:
    """Patch `RegionState.build` with a fake that only ever fails, stamping
    `failed_at` the way the real build does. Returns a one-element list whose
    value is the running attempt count."""
    calls = [0]
    lock = threading.Lock()

    def fake_build(self, cache_dir, tiles_upstream, allow_unmirrored=False):
        with lock:
            calls[0] += 1
        self.build_attempts += 1
        self.failed_at = time.monotonic()
        self.graph_state.fail("Couldn't reach the map-data service ...")

    monkeypatch.setattr("plotlines_service.app.RegionState.build", fake_build)
    return calls


def test_a_failing_region_rebuilds_at_most_once_per_cooldown_under_a_poll(tmp_path, monkeypatch):
    """AC1 — a continuous 2 s `/health` poll re-POSTing `/regions` must not
    drive more than one rebuild per cooldown window."""
    monkeypatch.setattr("plotlines_service.app.REGION_REQUEUE_COOLDOWN_S", 1.0)
    calls = _always_fails(monkeypatch)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    key = state.ensure_region(_BBOX, "bike")  # initial build
    state._build_pool.shutdown(wait=True)
    assert calls[0] == 1

    # ~20 automatic re-POSTs across ~0.2 s — well inside the cooldown window,
    # standing in for the client's 2 s `/health` poll. None may start a build.
    state._build_pool = ThreadPoolExecutor(max_workers=1)
    for _ in range(20):
        state.ensure_region(_BBOX, "bike")
        time.sleep(0.01)
    state._build_pool.shutdown(wait=True)
    assert calls[0] == 1, "a requeue slipped through inside the cooldown"

    # Past the window, the next automatic poll is allowed exactly one rebuild.
    time.sleep(1.1)
    state._build_pool = ThreadPoolExecutor(max_workers=1)
    state.ensure_region(_BBOX, "bike")
    state.ensure_region(_BBOX, "bike")  # immediately again — still cooled
    state._build_pool.shutdown(wait=True)
    assert calls[0] == 2

    reason = state.regions[key].routing_capability()["reason"]
    assert reason.startswith("failed:")


def test_automatic_requeues_stop_after_the_cap_and_say_so(tmp_path, monkeypatch):
    """AC2 — after `REGION_AUTOMATIC_REQUEUE_CAP` automatic requeues, further
    `/health`-driven requeues do nothing and the surfaced reason is a finished
    sentence that says the automatic path has stopped."""
    monkeypatch.setattr("plotlines_service.app.REGION_REQUEUE_COOLDOWN_S", 0.05)
    calls = _always_fails(monkeypatch)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    key = state.ensure_region(_BBOX, "bike")
    state._build_pool.shutdown(wait=True)

    # Poll past the cooldown, over and over. The cap is on accepted automatic
    # requeues, so builds stop at 1 (initial) + cap.
    for _ in range(REGION_AUTOMATIC_REQUEUE_CAP + 5):
        time.sleep(0.06)
        state._build_pool = ThreadPoolExecutor(max_workers=1)
        state.ensure_region(_BBOX, "bike")
        state._build_pool.shutdown(wait=True)

    assert calls[0] == 1 + REGION_AUTOMATIC_REQUEUE_CAP

    reason = state.regions[key].routing_capability()["reason"]
    assert reason.startswith("failed:")
    body = reason[len("failed:"):]
    assert body.endswith(".")
    assert "stopped" in body.lower()
    assert str(REGION_AUTOMATIC_REQUEUE_CAP) in body


def test_the_explicit_try_again_still_works_after_the_cap(tmp_path, monkeypatch):
    """The cap stops the *automatic* path only — the Author's "Try again"
    (`retry=true`) is user-initiated and still re-queues (addendum P4),
    subject to the cooldown."""
    monkeypatch.setattr("plotlines_service.app.REGION_REQUEUE_COOLDOWN_S", 0.05)
    calls = _always_fails(monkeypatch)

    state = Readiness(tmp_path, tmp_path / "home.pmtiles")
    state.ensure_region(_BBOX, "bike")
    state._build_pool.shutdown(wait=True)

    for _ in range(REGION_AUTOMATIC_REQUEUE_CAP + 3):
        time.sleep(0.06)
        state._build_pool = ThreadPoolExecutor(max_workers=1)
        state.ensure_region(_BBOX, "bike")
        state._build_pool.shutdown(wait=True)
    assert calls[0] == 1 + REGION_AUTOMATIC_REQUEUE_CAP

    time.sleep(0.06)
    state._build_pool = ThreadPoolExecutor(max_workers=1)
    state.ensure_region(_BBOX, "bike", manual=True)
    state._build_pool.shutdown(wait=True)
    assert calls[0] == 2 + REGION_AUTOMATIC_REQUEUE_CAP


def test_retry_true_over_http_bypasses_the_cooldown_once(tmp_path, monkeypatch):
    """End to end: `POST /regions {"retry": true}` is the FR121 "Try again"
    and gets the one in-window bypass; a bare `POST /regions` right after does
    not, and `/health` shows the remaining wait."""
    monkeypatch.setattr("plotlines_service.app.REGION_REQUEUE_COOLDOWN_S", 30.0)

    def boom(*_a, **_k):
        raise RuntimeError("nope")

    monkeypatch.setattr(region_lib, "ensure_graph", boom)

    client = TestClient(create_app(tmp_path))
    key = client.post("/regions", json={"bbox": list(_BBOX)}).json()["region"]

    def _reason():
        return (client.get("/health").json()["capabilities"]["routing"]
                ["regions"].get(key, {}).get("reason", ""))

    def _wait_failed():
        deadline = time.perf_counter() + 10
        while time.perf_counter() < deadline:
            if _reason().startswith("failed:"):
                return
            time.sleep(0.02)
        raise AssertionError("region never settled failed")

    _wait_failed()
    diag_url = f"/regions/{key}/diagnostics"
    assert client.get(diag_url).json()["attempts"] == 1

    # Bare re-POST inside the cooldown → refused, and the wait is legible.
    client.post("/regions", json={"bbox": list(_BBOX)})
    assert client.get(diag_url).json()["attempts"] == 1
    reason = _reason()
    assert reason.startswith("failed:")
    assert re.search(r"\b\d+ s\.", reason), reason

    # "Try again" → one bypass, the build re-runs (and fails again).
    client.post("/regions", json={"bbox": list(_BBOX), "retry": True})
    deadline = time.perf_counter() + 10
    while time.perf_counter() < deadline:
        if client.get(diag_url).json()["attempts"] == 2:
            break
        time.sleep(0.02)
    assert client.get(diag_url).json()["attempts"] == 2

    _wait_failed()
    # A second "Try again" in the same window → bypass spent, refused.
    client.post("/regions", json={"bbox": list(_BBOX), "retry": True})
    time.sleep(0.1)
    assert client.get(diag_url).json()["attempts"] == 2
