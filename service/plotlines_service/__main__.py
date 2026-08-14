"""Sidecar entrypoint: `plotlines-sidecar --port=N --mode=sidecar --cache-dir=…`.

Matches the spawn contract in ARCH §7.3. Frozen builds target this module.
"""

from __future__ import annotations

import argparse
import multiprocessing
import signal
import sys
from pathlib import Path

import uvicorn

from .app import create_app
from .version import VERSION


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="plotlines-sidecar")
    parser.add_argument("--port", type=int, default=0,
                        help="port to bind; 0 lets the OS assign (client passes an "
                             "explicit port it pre-bound per §7.3)")
    parser.add_argument("--host", default="127.0.0.1",
                        help="sidecar mode binds loopback only — the trust boundary")
    parser.add_argument("--mode", default="sidecar", choices=("sidecar", "hosted"))
    parser.add_argument("--cache-dir", type=Path, default=None,
                        help="directory holding the cached graph and DEM")
    # Not required alongside --cache-dir: the client runs `--version` to perform the
    # A8 version check *before* it has spawned anything or chosen a cache dir.
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args(argv)
    if not args.version and args.cache_dir is None:
        parser.error("--cache-dir is required unless --version is given")
    return args


def main(argv: list[str] | None = None) -> int:
    # PyInstaller/Nuitka + any accidental process spawn: without this a frozen
    # child re-executes the whole program. Cheap insurance, painful without.
    multiprocessing.freeze_support()

    args = parse_args(argv)
    if args.version:
        print(VERSION)
        return 0

    if args.mode == "sidecar" and args.host != "127.0.0.1":
        print("refusing: sidecar mode binds loopback only (ARCH §7.1)", file=sys.stderr)
        return 2

    app = create_app(cache_dir=args.cache_dir, mode=args.mode)

    config = uvicorn.Config(app, host=args.host, port=args.port,
                            log_level="warning", access_log=False)
    server = uvicorn.Server(config)

    # SIGTERM → graceful shutdown (§7.3: SIGTERM → SIGKILL after grace).
    # uvicorn installs its own handlers; make SIGTERM explicit so a frozen binary
    # behaves the same as a source run.
    def _terminate(signum, _frame):
        server.should_exit = True

    signal.signal(signal.SIGTERM, _terminate)

    server.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
