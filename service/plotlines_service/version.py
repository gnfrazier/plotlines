"""Version stamping from packaging/version.lock (ARCH §12.1, risk A8).

The single source of truth both artifacts stamp themselves with. Frozen builds carry
version.lock as a bundled data file; source runs walk up to the repo root. If the
sidecar can't find it, that is a build defect and it says so rather than guessing —
a sidecar reporting the wrong version is exactly the A8 failure this file exists to
prevent.
"""

from __future__ import annotations

import sys
from pathlib import Path

UNKNOWN = "unknown"


def _candidates() -> list[Path]:
    """Every place version.lock might live, checked unconditionally.

    Deliberately *not* gated on `sys.frozen`: PyInstaller sets it, Nuitka does not
    (it sets `__compiled__`), and gating on the wrong flag is how this silently
    returned "unknown" from a Nuitka build during SPIKE-00 — an A8 mismatch check
    comparing against "unknown" is not a check at all. Probing every candidate costs
    a few stat() calls once at import and cannot pick the wrong freezer.
    """
    paths = []
    # PyInstaller unpacks bundled data under sys._MEIPASS (both onefile and onedir).
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        paths.append(Path(meipass) / "version.lock")
    # Nuitka standalone (and any freezer that ships data beside the binary).
    try:
        paths.append(Path(sys.executable).resolve().parent / "version.lock")
    except OSError:
        pass
    # Source checkout: service/plotlines_service/version.py → repo root
    paths.append(Path(__file__).resolve().parents[2] / "packaging" / "version.lock")
    return paths


def read_version() -> str:
    for path in _candidates():
        try:
            for line in path.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    return line
        except OSError:
            continue
    return UNKNOWN


VERSION = read_version()
