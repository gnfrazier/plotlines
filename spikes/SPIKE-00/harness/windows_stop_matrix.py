"""Which Windows stop mechanisms actually give the sidecar a graceful exit?

ARCH §7.3's stop step is written in POSIX terms, and the plausible Windows
translations are not equivalent — some end the process without running a handler,
which severs a request in flight instead of finishing it. This enumerates them
against a real frozen sidecar and reports the exit code each produces, because the
exit code is what distinguishes "shut down" from "was killed":

    0           clean shutdown, the handler ran
    1           TerminateProcess — no handler, unblockable
    0xC000013A  STATUS_CONTROL_C_EXIT — killed by the default console handler

It then re-runs the winning mechanism from a parent with **no console at all**, which
is the situation the Flutter desktop client is actually in, because console control
events require the sender to share a console with the target. That case is the whole
reason this file exists: `CTRL_BREAK_EVENT` works from a terminal and **fails** from a
GUI process, so a client written against the terminal result alone would ship with no
graceful stop.

Getting that test right matters more than it looks. Neither `pythonw.exe` nor
`DETACHED_PROCESS` reliably yields a console-less process — a console-subsystem binary
is given a fresh console regardless, and the test then passes for the wrong reason.
`FreeConsole()` is unconditional, so that is what is used, in a child process so the
parent keeps a usable stdout.

Usage:  python windows_stop_matrix.py <sidecar.exe> <cache-dir>
"""
from __future__ import annotations

import ctypes
import json
import os
import signal
import socket
import subprocess
import sys
import time
import urllib.request

k32 = ctypes.windll.kernel32

NEW_GROUP = subprocess.CREATE_NEW_PROCESS_GROUP
CREATE_NO_WINDOW = 0x08000000
CTRL_BREAK = 1
STATUS_CONTROL_C_EXIT = 0xC000013A
GRACE_S = 15.0


def console_processes() -> int:
    buf = (ctypes.c_uint * 64)()
    return k32.GetConsoleProcessList(buf, 64)


def spawn_ready(exe: str, cache: str, flags: int = NEW_GROUP, timeout: float = 120.0):
    """Spawn a sidecar and block until /health reports ready."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    proc = subprocess.Popen(
        [exe, "--port", str(port), "--mode", "sidecar", "--cache-dir", cache],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=flags,
    )
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < timeout:
        try:
            with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/health", timeout=2
            ) as resp:
                if json.loads(resp.read()).get("ready"):
                    return proc
        except Exception:  # noqa: BLE001 — not ready yet is the normal case
            pass
        time.sleep(0.05)
    proc.kill()
    raise RuntimeError("sidecar never became ready")


def describe(code: int | None) -> str:
    if code == 0:
        return "0 — GRACEFUL (handler ran)"
    if code is not None and (code & 0xFFFFFFFF) == STATUS_CONTROL_C_EXIT:
        return "0xC000013A — not graceful (default console handler killed it)"
    return f"{code} — not graceful (hard kill)"


def attempt(name: str, exe: str, cache: str, stop, flags: int = NEW_GROUP) -> dict:
    try:
        proc = spawn_ready(exe, cache, flags)
    except RuntimeError as exc:
        return {"mechanism": name, "exit_code": f"setup failed: {exc}", "note": ""}
    note = ""
    t0 = time.perf_counter()
    try:
        stop(proc)
    except OSError as exc:
        note = f"SEND FAILED: {exc}"
        proc.kill()
    try:
        proc.wait(timeout=GRACE_S)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
        note = (note + "; " if note else "") + "did not stop within grace"
    return {
        "mechanism": name,
        "exit_code": describe(proc.returncode),
        "seconds": round(time.perf_counter() - t0, 3),
        "note": note,
    }


def attach_console_stop(proc: subprocess.Popen) -> None:
    """The recipe a console-less client must use.

    Borrow the sidecar's own console just long enough to signal into it. The client
    must mute its own Ctrl handling first, because the event reaches every process
    attached to that console — including, briefly, the client itself.
    """
    if not k32.AttachConsole(proc.pid):
        raise OSError(f"AttachConsole failed (err {k32.GetLastError()})")
    try:
        k32.SetConsoleCtrlHandler(None, True)
        if not k32.GenerateConsoleCtrlEvent(CTRL_BREAK, proc.pid):
            raise OSError(f"GenerateConsoleCtrlEvent failed "
                          f"(err {k32.GetLastError()})")
    finally:
        k32.FreeConsole()
        k32.SetConsoleCtrlHandler(None, False)


def report(rows: list[dict], out) -> None:
    for r in rows:
        line = f"  {r['mechanism']:<50} -> {r['exit_code']}"
        if r.get("seconds") is not None:
            line += f"   [{r['seconds']}s]"
        if r.get("note"):
            line += f"   {r['note']}"
        print(line, file=out, flush=True)
    print(file=out, flush=True)


def with_console(exe: str, cache: str) -> None:
    print(f"=== parent WITH a console (terminal; {console_processes()} processes "
          f"attached) ===")
    report([
        attempt("CTRL_BREAK_EVENT to the new process group", exe, cache,
                lambda p: os.kill(p.pid, signal.CTRL_BREAK_EVENT)),
        attempt("Popen.terminate()  [= TerminateProcess]", exe, cache,
                lambda p: p.terminate()),
        attempt("Popen.send_signal(SIGTERM)  [= TerminateProcess]", exe, cache,
                lambda p: p.send_signal(signal.SIGTERM)),
        attempt("CTRL_C_EVENT to the new process group", exe, cache,
                lambda p: os.kill(p.pid, signal.CTRL_C_EVENT)),
    ], sys.stdout)


def without_console(exe: str, cache: str, out_path: str) -> None:
    """Runs in a child process: FreeConsole cannot be undone for this process."""
    k32.FreeConsole()
    with open(out_path, "w", encoding="utf-8") as out:
        print(f"=== parent WITHOUT a console (FreeConsole; hwnd="
              f"0x{k32.GetConsoleWindow():x}, {console_processes()} attached) "
              f"— the Flutter GUI case ===", file=out)
        report([
            attempt("CTRL_BREAK_EVENT, sent directly", exe, cache,
                    lambda p: os.kill(p.pid, signal.CTRL_BREAK_EVENT)),
            attempt("CREATE_NO_WINDOW + AttachConsole + CTRL_BREAK", exe, cache,
                    attach_console_stop, flags=NEW_GROUP | CREATE_NO_WINDOW),
        ], out)


if __name__ == "__main__":
    exe, cache = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    if "--no-console-child" in sys.argv:
        without_console(exe, cache, sys.argv[sys.argv.index("--no-console-child") + 1])
        sys.exit(0)

    with_console(exe, cache)

    tmp = os.path.join(os.environ["TEMP"], "plsc-stop-matrix-noconsole.txt")
    subprocess.run([sys.executable, __file__, exe, cache,
                    "--no-console-child", tmp], timeout=900, check=True)
    with open(tmp, encoding="utf-8", errors="replace") as fh:
        print(fh.read())
