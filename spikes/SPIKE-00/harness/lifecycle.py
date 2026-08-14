"""SPIKE-00 lifecycle harness — exercises the ARCH §7.3 spawn protocol.

Stdlib only, on purpose: this stands in for the Flutter client, which has no Python.
It must prove the frozen binary can be driven by something that knows nothing about
Python packaging.

  find free port → spawn child → poll /health until ready → real /segments/generate
  over loopback → graceful stop → confirm clean exit → confirm no orphans

Runs on POSIX and on Windows. The two diverge in exactly the place §7.3 is most
specific — process control — so those calls live behind the shim in "platform
primitives" below instead of being sprinkled through the run. What differs and why:
spikes/SPIKE-00/results/WINDOWS.md.

Usage:
  python lifecycle.py <binary-or-cmd...> --cache-dir DIR [--label NAME] [--runs N]
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

READY_TIMEOUT_S = 120.0
SHUTDOWN_GRACE_S = 10.0

IS_WINDOWS = sys.platform == "win32"

# ── platform primitives ──────────────────────────────────────────────────────
#
# §7.3 is written in POSIX terms — spawn into a new session, SIGTERM, escalate to
# SIGKILL, check the process group for orphans. None of those three exist on
# Windows, and the naive translations are all wrong in the same direction: they
# look like they work while actually hard-killing the child.
#
#   spawn      start_new_session=True raises ValueError on Windows. The analogue
#              is CREATE_NEW_PROCESS_GROUP, which is also what makes the child
#              addressable by a console control event without hitting this parent.
#   stop       Popen.terminate() and send_signal(SIGTERM) both call
#              TerminateProcess() on Windows — an unblockable kill, no handler,
#              no cleanup. CTRL_BREAK_EVENT is the only stop the child can catch,
#              and it is delivered to the process *group* we created above.
#   orphans    There are no process groups to poll and no reparenting, so a dead
#              PPID proves nothing. Snapshot the children while the sidecar is
#              alive, then check those PIDs for liveness after it exits.


def _spawn_kwargs() -> dict:
    if IS_WINDOWS:
        return {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
    return {"start_new_session": True}


def _stop_signal() -> tuple:
    """(signal to send, label recorded in the report)."""
    if IS_WINDOWS:
        return signal.CTRL_BREAK_EVENT, "graceful-ctrl-break"
    return signal.SIGTERM, "graceful-sigterm"


def _pid_alive(pid: int) -> bool:
    if not IS_WINDOWS:
        try:
            os.kill(pid, 0)
            return True
        except (ProcessLookupError, PermissionError):
            return False
    import ctypes

    PROCESS_QUERY_LIMITED_INFORMATION, STILL_ACTIVE = 0x1000, 259
    k32 = ctypes.windll.kernel32
    handle = k32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return False
    code = ctypes.c_ulong()
    ok = k32.GetExitCodeProcess(handle, ctypes.byref(code))
    k32.CloseHandle(handle)
    return bool(ok) and code.value == STILL_ACTIVE


def _child_pids(pid: int) -> list[int]:
    """Direct children of `pid` — must be called while the parent is still alive.

    Windows keeps no parent link after exit and never reparents, so this snapshot
    is the only chance to learn what a crashed sidecar would leave behind.
    """
    if not IS_WINDOWS:
        return []
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive", "-Command",
             f"(Get-CimInstance Win32_Process -Filter 'ParentProcessId={pid}')"
             ".ProcessId"],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [int(tok) for tok in out.split() if tok.strip().isdigit()]


def _orphan_check(proc: subprocess.Popen, children: list[int]) -> str:
    if not IS_WINDOWS:
        try:
            os.killpg(os.getpgid(proc.pid), 0)
            return "process group still alive"
        except (ProcessLookupError, PermissionError):
            return "none"
    survivors = [pid for pid in children if _pid_alive(pid)]
    if _pid_alive(proc.pid):
        survivors.append(proc.pid)
    return "none" if not survivors else f"still alive: {survivors}"

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
                            **_spawn_kwargs())

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

    # Snapshot children while the sidecar still lives — on Windows this is the only
    # moment the parent link exists, and it is what the orphan sweep compares against.
    children = _child_pids(proc.pid)
    result["child_pids"] = children

    # §7.3: graceful stop → hard kill after grace.
    stop_signal, stop_label = _stop_signal()
    t0 = time.perf_counter()
    try:
        proc.send_signal(stop_signal)
    except OSError as exc:
        # Windows: GenerateConsoleCtrlEvent needs the sender to share a console with
        # the target group. Record the miss rather than papering over it — a client
        # that cannot deliver this has no graceful path at all.
        result["stop_signal_error"] = repr(exc)
        proc.kill()
        stop_label = "hard-kill-no-console"
    try:
        proc.wait(timeout=SHUTDOWN_GRACE_S)
        result["shutdown_s"] = round(time.perf_counter() - t0, 3)
        result["shutdown"] = stop_label
        result["exit_code"] = proc.returncode
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
        result["shutdown_s"] = round(time.perf_counter() - t0, 3)
        result["shutdown"] = "required-hard-kill"
        result["exit_code"] = proc.returncode

    result["orphans"] = _orphan_check(proc, children)

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
        "platform": f"{sys.platform} {platform.machine()}",
        "command": args.cmd,
        "runs": runs,
        # A run that routes correctly but had to be hard-killed, or that leaked a
        # process, is a §7.3 failure — so it fails the gate too, not just the route.
        "passed": (
            len(ok) == len(runs)
            and all(r.get("route_ok") for r in ok)
            and all(r.get("shutdown", "").startswith("graceful") for r in ok)
            and all(r.get("orphans") == "none" for r in ok)
        ),
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
