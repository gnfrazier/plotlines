"""SPIKE-00 lifecycle harness — exercises the ARCH §7.3 spawn protocol.

Stdlib only, on purpose: this stands in for the Flutter client, which has no Python.
It must prove the frozen binary can be driven by something that knows nothing about
Python packaging.

  find free port → spawn child → poll /health until ready → real /segments/generate
  over loopback → SIGTERM → confirm clean exit → confirm no orphans

Usage:
  python lifecycle.py <binary-or-cmd...> --cache-dir DIR [--label NAME] [--runs N]
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

READY_TIMEOUT_S = 120.0
SHUTDOWN_GRACE_S = 10.0

REQUEST = {
    "start": {"lat": 40.015, "lon": -105.285},
    "end": {"lat": 40.005, "lon": -105.262},
    "via": [{"lat": 40.020, "lon": -105.270}],
    "theme": "quiet_scenic",
    "mode": "cycling",
}


def free_port() -> int:
    """§7.3: bind :0, read the assigned port, release it, hand it to the child."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def get_json(url: str, payload: dict | None = None, timeout: float = 30.0):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"content-type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def one_run(cmd: list[str], cache_dir: str) -> dict:
    port = free_port()
    argv = [*cmd, "--port", str(port), "--mode", "sidecar", "--cache-dir", cache_dir]

    t_spawn = time.perf_counter()
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)

    result: dict = {"pid": proc.pid, "port": port}
    health = None
    t_first_response = None

    while True:
        if time.perf_counter() - t_spawn > READY_TIMEOUT_S:
            proc.kill()
            out, err = proc.communicate()
            result["error"] = "timed out waiting for ready"
            result["stderr"] = err.decode()[-2000:]
            return result
        if proc.poll() is not None:
            out, err = proc.communicate()
            result["error"] = f"sidecar exited early rc={proc.returncode}"
            result["stderr"] = err.decode()[-2000:]
            return result
        try:
            health = get_json(f"http://127.0.0.1:{port}/health", timeout=2.0)
            if t_first_response is None:
                t_first_response = time.perf_counter()
            if health.get("ready"):
                break
            if health.get("status") == "failed":
                proc.terminate()
                result["error"] = f"sidecar load failed: {health.get('detail')}"
                return result
        except (urllib.error.URLError, socket.timeout, ConnectionError, OSError):
            pass
        time.sleep(0.02)

    t_ready = time.perf_counter()
    result["http_listening_s"] = round(t_first_response - t_spawn, 3)
    result["cold_start_to_ready_s"] = round(t_ready - t_spawn, 3)
    result["health"] = health

    # A real route over loopback — the actual spike question.
    t0 = time.perf_counter()
    try:
        seg = get_json(f"http://127.0.0.1:{port}/segments/generate", REQUEST)
    except Exception as exc:  # noqa: BLE001
        proc.terminate()
        result["error"] = f"/segments/generate failed: {exc!r}"
        return result
    result["generate_roundtrip_s"] = round(time.perf_counter() - t0, 3)
    result["segment"] = {
        "distance_m": seg["distance_m"],
        "node_count": seg["node_count"],
        "coordinate_count": len(seg["coordinates"]),
        "solve_ms": seg["solve_ms"],
        "elevation": seg["elevation"],
    }
    # A route that is empty or degenerate is a failure even if HTTP said 200.
    result["route_ok"] = bool(
        seg["distance_m"] > 100 and len(seg["coordinates"]) >= 10
    )

    # §7.3: SIGTERM → graceful, SIGKILL after grace.
    t0 = time.perf_counter()
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=SHUTDOWN_GRACE_S)
        result["shutdown_s"] = round(time.perf_counter() - t0, 3)
        result["shutdown"] = "graceful-sigterm"
        result["exit_code"] = proc.returncode
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
        result["shutdown_s"] = round(time.perf_counter() - t0, 3)
        result["shutdown"] = "required-sigkill"
        result["exit_code"] = proc.returncode

    # Orphan sweep: did the child leave anything behind in its process group?
    try:
        os.killpg(os.getpgid(proc.pid), 0)
        result["orphans"] = "process group still alive"
    except (ProcessLookupError, PermissionError):
        result["orphans"] = "none"

    proc.stdout.close()
    proc.stderr.close()
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", nargs="+")
    ap.add_argument("--cache-dir", required=True)
    ap.add_argument("--label", default="sidecar")
    ap.add_argument("--runs", type=int, default=3)
    args = ap.parse_args()

    runs = [one_run(args.cmd, args.cache_dir) for _ in range(args.runs)]
    ok = [r for r in runs if "error" not in r]
    report = {
        "label": args.label,
        "command": args.cmd,
        "runs": runs,
        "passed": len(ok) == len(runs) and all(r.get("route_ok") for r in ok),
    }
    if ok:
        starts = sorted(r["cold_start_to_ready_s"] for r in ok)
        report["cold_start_median_s"] = starts[len(starts) // 2]
        report["cold_start_min_s"] = starts[0]
        report["cold_start_max_s"] = starts[-1]
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
