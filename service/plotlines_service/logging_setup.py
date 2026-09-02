"""Sidecar logging configuration (issue #232).

The sidecar had no logging at all: a region build that failed threw its
traceback away and kept only `f"{type(exc).__name__}: {exc}"`, and there was
no record of how often `POST /regions` re-queued a build. This wires a
rotating file handler (default under the cache dir, where the client already
knows to look) plus a stderr handler, so a `--log-file` is available for
every run and the frozen binary logs the same as a source run.
"""

from __future__ import annotations

import logging
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path

_FORMAT = "%(asctime)s %(levelname)-7s %(name)s: %(message)s"

#: Names the sidecar configures explicitly. The root logger also gets the
#: handlers so a stray third-party log line is not lost.
_SIDECAR_LOGGERS = ("plotlines.sidecar", "plotlines.regions", "uvicorn",
                    "uvicorn.error")


def default_log_file(cache_dir: Path) -> Path:
    return Path(cache_dir) / "logs" / "sidecar.log"


def configure_logging(log_file: Path | None, level: str = "info") -> Path | None:
    """Attach a rotating file handler (5 files x 2 MB) and a stderr handler to
    the root logger at `level`. Returns the resolved log path, or None when
    `log_file` is None (stderr only — used by tests)."""
    numeric = getattr(logging, level.upper(), logging.INFO)
    root = logging.getLogger()
    root.setLevel(numeric)

    formatter = logging.Formatter(_FORMAT)

    stderr_handler = logging.StreamHandler(sys.stderr)
    stderr_handler.setFormatter(formatter)
    root.addHandler(stderr_handler)

    resolved: Path | None = None
    if log_file is not None:
        resolved = Path(log_file)
        resolved.parent.mkdir(parents=True, exist_ok=True)
        file_handler = RotatingFileHandler(
            resolved, maxBytes=2_000_000, backupCount=5, encoding="utf-8",
        )
        file_handler.setFormatter(formatter)
        root.addHandler(file_handler)

    for name in _SIDECAR_LOGGERS:
        logging.getLogger(name).setLevel(numeric)

    return resolved
