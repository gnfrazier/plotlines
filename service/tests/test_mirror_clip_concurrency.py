"""Regression for issue #494: `/clip` ran `clip_bbox` (pyosmium, ~100s wall
time / ~1.77 GB peak RSS on the live Pi per #402) inline on FastAPI's shared
thread pool with no concurrency bound at all — `_RateLimiter` (#263) is
per-IP-per-minute, so it alone permits `rate_limit_per_minute` concurrent
clips from one address, and two concurrent clips of different bboxes is
exactly the shape #402 measured OOM-killing the process in ~9s. `/health`
answers on the same shared pool, so a saturated `/clip` took it down too.

`_ClipConcurrencyLimiter` now gates entry into `clip_bbox` with a
non-blocking `threading.BoundedSemaphore`: a caller past
`max_concurrent_clips` gets an immediate 503 `clip_busy` with `Retry-After`
instead of queuing behind someone else's clip, and `/health` — which reads
only the filesystem and never touches the semaphore — keeps answering
throughout. This asserts all three acceptance criteria from the issue: the
bound is exact, the excess is a fast 503/Retry-After, and `/health` stays
live while clips are running.
"""

from __future__ import annotations

import threading
import time
from pathlib import Path

from fastapi.testclient import TestClient

from mirror_clip_fixtures import build_mirror_tree, node, write_pbf

from plotlines_service import mirror_clip
from plotlines_service.mirror_clip import create_clip_app

_BBOX = {"west": -82.6, "south": 34.9, "east": -81.9, "north": 35.6}


def _mirror_with_one_region(tmp_path: Path) -> Path:
    src = write_pbf(
        tmp_path / "src.osm.pbf",
        nodes=[node(1, -82.2, 35.2, {"natural": "peak", "name": "Test Peak"})],
        box=(-83.0, 34.0, -81.0, 36.0),
    )
    return build_mirror_tree(tmp_path / "mirror", regions={"the-region": src})


def _blocking_clip_bbox(entered: threading.Event, released: threading.Event):
    """Stands in for the real `clip_bbox`: signals `entered` the moment it
    starts running (i.e. the semaphore admitted it) and then blocks until
    `released`, simulating the real ~100s clip without actually spending
    that wall time in the test. Bounded at 15s purely so a broken test can't
    hang the suite — the test always sets `released` itself well before
    that."""

    def _fake(*args, **kwargs):
        entered.set()
        released.wait(timeout=15.0)
        raise RuntimeError("should never be reached — test releases first")

    return _fake


def test_a_second_clip_while_one_is_running_gets_a_fast_503_with_retry_after(
    tmp_path: Path, monkeypatch,
) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    entered = threading.Event()
    released = threading.Event()
    monkeypatch.setattr(
        mirror_clip, "clip_bbox", _blocking_clip_bbox(entered, released)
    )
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    first_result: dict = {}

    def call_first() -> None:
        first_result["response"] = tc.get("/clip", params=_BBOX)

    first_thread = threading.Thread(target=call_first)
    first_thread.start()
    assert entered.wait(timeout=5.0), "first /clip never started running clip_bbox"

    try:
        start = time.monotonic()
        second = tc.get("/clip", params=_BBOX)
        elapsed = time.monotonic() - start
    finally:
        released.set()
        first_thread.join(timeout=5.0)

    assert elapsed < 1.0, (
        f"the second /clip took {elapsed:.2f}s — it must fail fast, never "
        "queue behind the first clip's own duration"
    )
    assert second.status_code == 503
    assert second.json()["detail"]["error"] == "clip_busy"
    assert second.headers["retry-after"] == str(mirror_clip.CLIP_BUSY_RETRY_AFTER_S)
    assert "Traceback" not in second.text
    assert not first_thread.is_alive()


def test_health_answers_while_a_clip_is_running(tmp_path: Path, monkeypatch) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    entered = threading.Event()
    released = threading.Event()
    monkeypatch.setattr(
        mirror_clip, "clip_bbox", _blocking_clip_bbox(entered, released)
    )
    tc = TestClient(create_clip_app(mirror, tmp_dir=tmp_path / "scratch"))

    clip_thread = threading.Thread(target=lambda: tc.get("/clip", params=_BBOX))
    clip_thread.start()
    assert entered.wait(timeout=5.0), "/clip never started running clip_bbox"

    try:
        start = time.monotonic()
        health = tc.get("/health")
        elapsed = time.monotonic() - start
    finally:
        released.set()
        clip_thread.join(timeout=5.0)

    assert health.status_code == 200
    assert health.json()["ready"] is True
    assert elapsed < 1.0, (
        f"/health took {elapsed:.2f}s with a clip in flight — it must never "
        "share the clip's concurrency bound"
    )


def test_n_concurrent_clips_exactly_max_concurrency_run_the_rest_get_503(
    tmp_path: Path, monkeypatch,
) -> None:
    mirror = _mirror_with_one_region(tmp_path)
    max_concurrency = 2
    request_count = 5
    entered_count = 0
    entered_lock = threading.Lock()
    all_admitted_ran = threading.Event()
    released = threading.Event()

    def _fake(*args, **kwargs):
        nonlocal entered_count
        with entered_lock:
            entered_count += 1
            if entered_count == max_concurrency:
                all_admitted_ran.set()
        # Released, then fails — the admitted requests' own outcome (a 500
        # `clip_failed`, same as any other `clip_bbox` exception) isn't the
        # thing this test asserts; only that exactly `max_concurrency` of
        # them ever got in, and every other request never touched this
        # function at all.
        released.wait(timeout=15.0)
        raise RuntimeError("simulated clip failure — the test releases first")

    monkeypatch.setattr(mirror_clip, "clip_bbox", _fake)
    tc = TestClient(
        create_clip_app(
            mirror, tmp_dir=tmp_path / "scratch", max_concurrent_clips=max_concurrency
        )
    )

    results: list[dict] = [{} for _ in range(request_count)]

    def call(i: int) -> None:
        results[i]["response"] = tc.get("/clip", params=_BBOX)

    threads = [threading.Thread(target=call, args=(i,)) for i in range(request_count)]
    for t in threads:
        t.start()

    try:
        assert all_admitted_ran.wait(timeout=5.0), (
            f"expected exactly {max_concurrency} clips to be admitted, but "
            f"only {entered_count} ever started"
        )
        # Give the excess requests a moment to be refused — they never touch
        # clip_bbox at all, so this should resolve almost immediately.
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            finished = sum(1 for r in results if "response" in r)
            if finished == request_count - max_concurrency:
                break
            time.sleep(0.02)
    finally:
        released.set()
        for t in threads:
            t.join(timeout=5.0)

    assert entered_count == max_concurrency, (
        f"exactly {max_concurrency} clips should have run, but "
        f"{entered_count} did"
    )
    statuses = [r["response"].status_code for r in results]
    assert sorted(statuses) == sorted(
        [503] * (request_count - max_concurrency) + [500] * max_concurrency
    )
    for r in results:
        detail = r["response"].json()["detail"]
        if r["response"].status_code == 503:
            assert detail["error"] == "clip_busy"
        else:
            assert detail["error"] == "clip_failed"
