"""Run the SPIKE-14 rendering matrix and write `results/results.json`.

Every cell is run several times and reported as a median with its spread. That is not
ceremony: the first pass at these numbers swung between 34 and 107 fps for the *same*
configuration, because a leftover process from an earlier probe was still holding a
CPU. On a software rasterizer with no GPU, a single run is not evidence.

Cold vs. warm is a deliberate axis. `vector_map_tiles` keeps a persistent file cache in
the system temp directory, and it survives across runs — the first version of this
harness reported zero tile reads because every tile came from a cache written by an
earlier experiment. Cold runs delete it; warm runs do not.
"""

from __future__ import annotations

import json
import os
import shutil
import statistics
import subprocess
import time
from pathlib import Path

SPIKE = Path(__file__).resolve().parent.parent
HARNESS = SPIKE / "harness"
BIN = HARNESS / "build/linux/x64/profile/bundle/spike14_harness"
CACHE = Path("/tmp/.vector_map")
REPEATS = 5


def wait_for_quiet(threshold: float = 1.2, timeout: int = 300) -> float:
    """Block until the 1-minute load average drops, so runs are comparable."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        load = os.getloadavg()[0]
        if load < threshold:
            return load
        time.sleep(5)
    return os.getloadavg()[0]


def run(payload: str, basemap: str, zoom: int, cold: bool, seconds: int = 10,
        offline: bool = False, shot: str | None = None) -> dict | None:
    if cold and CACHE.exists():
        shutil.rmtree(CACHE, ignore_errors=True)
    env = {
        **os.environ,
        "SPIKE14_PAYLOAD": payload,
        "SPIKE14_BASEMAP": basemap,
        "SPIKE14_ZOOM": str(zoom),
        "SPIKE14_SECONDS": str(seconds),
    }
    if shot:
        env["SPIKE14_SHOT"] = shot
    cmd = [str(BIN)]
    if offline:
        # A real network namespace, not a flag the app could ignore.
        cmd = ["unshare", "-rn", str(BIN)]
    proc = subprocess.run(cmd, cwd=HARNESS, env=env, capture_output=True,
                          text=True, timeout=400)
    for line in proc.stdout.splitlines():
        if line.startswith("SPIKE14_RESULT "):
            return json.loads(line[len("SPIKE14_RESULT "):])
    return None


def summarise(runs: list[dict]) -> dict:
    def med(key):
        vals = [r[key] for r in runs]
        return {
            "median": round(statistics.median(vals), 2),
            "min": round(min(vals), 2),
            "max": round(max(vals), 2),
        }

    return {
        "n": len(runs),
        "vertices": runs[0]["vertices"],
        "markers": runs[0]["markers"],
        "tile_reads": runs[0]["tile_reads"],
        "first_frame_ms": med("first_frame_ms"),
        "total_p50_ms": med("total_p50_ms"),
        "total_p95_ms": med("total_p95_ms"),
        "total_p99_ms": med("total_p99_ms"),
        "fps_p50": med("fps_p50"),
        "jank_frac": med("jank_frac"),
        "rss_kb": med("rss_kb"),
    }


def main() -> None:
    matrix = [
        ("route_only_day", dict(payload="day", basemap="none", zoom=14, cold=False)),
        ("route_only_multi", dict(payload="multi", basemap="none", zoom=14, cold=False)),
        ("route_only_stress", dict(payload="stress", basemap="none", zoom=14, cold=False)),
        ("vector_day_cold", dict(payload="day", basemap="vector", zoom=14, cold=True)),
        ("vector_multi_cold", dict(payload="multi", basemap="vector", zoom=14, cold=True)),
        ("vector_stress_cold", dict(payload="stress", basemap="vector", zoom=14, cold=True)),
        ("vector_multi_warm", dict(payload="multi", basemap="vector", zoom=14, cold=False)),
        ("vector_multi_offline", dict(payload="multi", basemap="vector", zoom=14,
                                      cold=True, offline=True)),
    ]

    out: dict = {"repeats": REPEATS, "cells": {}}
    for name, kwargs in matrix:
        load = wait_for_quiet()
        runs = []
        for _ in range(REPEATS):
            r = run(**kwargs)
            if r:
                runs.append(r)
        if runs:
            out["cells"][name] = {**summarise(runs), "load_at_start": round(load, 2)}
            c = out["cells"][name]
            print(f'{name:24} fps_p50={c["fps_p50"]["median"]:6} '
                  f'p95={c["total_p95_ms"]["median"]:6} '
                  f'jank={c["jank_frac"]["median"]}')

    (SPIKE / "results" / "results.json").write_text(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
