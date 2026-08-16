"""Run the SPIKE-14 rendering matrix and write `results/results{,_windows}.json`.

Every cell is run several times and reported as a median with its spread. That is not
ceremony: the first pass at these numbers swung between 34 and 107 fps for the *same*
configuration, because a leftover process from an earlier probe was still holding a
CPU. On a software rasterizer with no GPU, a single run is not evidence.

Cold vs. warm is a deliberate axis. `vector_map_tiles` keeps a persistent file cache in
the system temp directory, and it survives across runs — the first version of this
harness reported zero tile reads because every tile came from a cache written by an
earlier experiment. Cold runs delete it; warm runs do not.

**Runs on Linux and Windows.** The spike's Linux pass left "the second desktop platform"
open, so this script grew a Windows path rather than a Windows twin — one script means
the two platforms are measured by the same code, which is the whole point of comparing
them. Three things genuinely differ and are branched explicitly below: where the built
binary lands, how you tell the machine is idle enough to measure on, and how you take
the network away. Only the last one is a real loss of rigour, and it is labelled as such
in the results rather than papered over.
"""

from __future__ import annotations

import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

WINDOWS = sys.platform == "win32"

SPIKE = Path(__file__).resolve().parent.parent
HARNESS = SPIKE / "harness"
BIN = (HARNESS / "build/windows/x64/runner/Profile/spike14_harness.exe" if WINDOWS
       else HARNESS / "build/linux/x64/profile/bundle/spike14_harness")
# `vector_map_tiles` builds this path from path_provider's `getTemporaryDirectory()`,
# which is /tmp on Linux and %LOCALAPPDATA%\Temp on Windows.
CACHE = Path("/tmp/.vector_map") if not WINDOWS else Path(tempfile.gettempdir()) / ".vector_map"
OUT = SPIKE / "results" / ("results_windows.json" if WINDOWS else "results.json")
REPEATS = 5


def wait_for_quiet(threshold: float = 1.2, timeout: int = 300) -> float:
    """Block until the machine is idle enough for one run to resemble the next.

    Linux uses the 1-minute load average directly. Windows has no load average at all —
    the closest honest equivalent is the fraction of CPU time that is not idle, read
    from `GetSystemTimes`, so the Windows threshold is a *fraction* and the two numbers
    in `load_at_start` are not the same quantity. They are recorded under the same key
    because they serve the same purpose: evidence that the machine was quiet.
    """
    deadline = time.time() + timeout
    probe = _cpu_busy_fraction if WINDOWS else (lambda: os.getloadavg()[0])
    limit = 0.25 if WINDOWS else threshold
    while time.time() < deadline:
        value = probe()
        if value < limit:
            return value
        time.sleep(5)
    return probe()


def _cpu_busy_fraction(sample_s: float = 2.0) -> float:
    """Busy fraction of total CPU time over `sample_s`, via GetSystemTimes.

    Deliberately ctypes rather than psutil: this script's only job on a benchmark run is
    to stay out of the way, and adding a dependency to measure idleness is a poor trade.
    Note that GetSystemTimes' kernel time *includes* idle time, hence total = kernel+user.
    """
    import ctypes
    import ctypes.wintypes

    class FILETIME(ctypes.Structure):
        _fields_ = [("low", ctypes.wintypes.DWORD), ("high", ctypes.wintypes.DWORD)]

    def snapshot() -> tuple[int, int, int]:
        idle, kern, user = FILETIME(), FILETIME(), FILETIME()
        ctypes.windll.kernel32.GetSystemTimes(
            ctypes.byref(idle), ctypes.byref(kern), ctypes.byref(user))
        as_int = lambda f: (f.high << 32) | f.low  # noqa: E731
        return as_int(idle), as_int(kern), as_int(user)

    i0, k0, u0 = snapshot()
    time.sleep(sample_s)
    i1, k1, u1 = snapshot()
    total = (k1 - k0) + (u1 - u0)
    return 0.0 if total == 0 else 1.0 - (i1 - i0) / total


def audit_sockets(pid: int) -> list[str]:
    """Every non-loopback remote endpoint the process held, sampled while it ran.

    This is the Windows stand-in for `unshare -rn`, and it is **weaker evidence**: it
    observes that the process made no outside connection, rather than making one
    impossible. Severing the network for one process on Windows means a firewall rule,
    which needs Administrator; this session does not have it. Sampled rather than
    continuous, so a very short-lived connection could slip between polls — which is why
    the Linux namespace result stays the load-bearing one for P2's offline claim.
    """
    script = (
        f"$c = @(); "
        f"1..12 | ForEach-Object {{ "
        f"  $c += @(Get-NetTCPConnection -OwningProcess {pid} -ErrorAction SilentlyContinue "
        f"        | Where-Object {{ $_.RemoteAddress -notin @('0.0.0.0','127.0.0.1','::','::1') }} "
        f"        | ForEach-Object {{ \"$($_.RemoteAddress):$($_.RemotePort)\" }}); "
        f"  $c += @(Get-NetUDPEndpoint -OwningProcess {pid} -ErrorAction SilentlyContinue "
        f"        | ForEach-Object {{ \"udp:$($_.LocalAddress):$($_.LocalPort)\" }}); "
        f"  Start-Sleep -Milliseconds 800 }}; "
        f"$c | Sort-Object -Unique"
    )
    proc = subprocess.run(["powershell", "-NoProfile", "-Command", script],
                          capture_output=True, text=True, timeout=120)
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


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

    audited: list[str] | None = None
    if offline and not WINDOWS:
        # A real network namespace, not a flag the app could ignore.
        proc = subprocess.run(["unshare", "-rn", str(BIN)], cwd=HARNESS, env=env,
                              capture_output=True, text=True, timeout=400)
    elif offline and WINDOWS:
        # stdout goes to a file, not a pipe. The theme reader emits tens of kilobytes of
        # "unsupported expression" warnings at startup, and nobody is draining a pipe
        # while the socket audit runs — the harness would block on its own logging and
        # the cell would hang rather than fail.
        with tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace") as sink:
            popen = subprocess.Popen([str(BIN)], cwd=HARNESS, env=env,
                                     stdout=sink, stderr=subprocess.DEVNULL)
            audited = audit_sockets(popen.pid)
            popen.wait(timeout=400)
            sink.seek(0)
            proc = subprocess.CompletedProcess([str(BIN)], popen.returncode,
                                               sink.read(), "")
    else:
        proc = subprocess.run([str(BIN)], cwd=HARNESS, env=env, capture_output=True,
                              text=True, timeout=400)

    for line in proc.stdout.splitlines():
        if line.startswith("SPIKE14_RESULT "):
            result = json.loads(line[len("SPIKE14_RESULT "):])
            if audited is not None:
                result["network_isolation"] = "socket-audit (no admin; weaker than unshare)"
                result["remote_endpoints_observed"] = audited
            elif offline:
                result["network_isolation"] = "unshare -rn"
            return result
    return None


def summarise(runs: list[dict]) -> dict:
    def med(key):
        vals = [r[key] for r in runs]
        return {
            "median": round(statistics.median(vals), 2),
            "min": round(min(vals), 2),
            "max": round(max(vals), 2),
        }

    out = {
        "platform": runs[0].get("platform", "linux"),
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
    for key in ("network_isolation", "remote_endpoints_observed"):
        if key in runs[0]:
            out[key] = runs[0][key]
    return out


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

    out: dict = {"repeats": REPEATS, "platform": "windows" if WINDOWS else "linux",
                 "cells": {}}
    for name, kwargs in matrix:
        load = wait_for_quiet()
        # The Windows offline cell polls the OS for open sockets while the harness runs,
        # which is CPU the harness would otherwise have had. Repeating it would multiply
        # that perturbation without strengthening the claim, which is a yes/no.
        repeats = 1 if (WINDOWS and kwargs.get("offline")) else REPEATS
        runs = []
        for _ in range(repeats):
            r = run(**kwargs)
            if r:
                runs.append(r)
        if runs:
            out["cells"][name] = {**summarise(runs), "load_at_start": round(load, 2)}
            c = out["cells"][name]
            print(f'{name:24} fps_p50={c["fps_p50"]["median"]:6} '
                  f'p95={c["total_p95_ms"]["median"]:6} '
                  f'jank={c["jank_frac"]["median"]}')
        else:
            print(f"{name:24} NO RESULT")

    OUT.write_text(json.dumps(out, indent=2))
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
