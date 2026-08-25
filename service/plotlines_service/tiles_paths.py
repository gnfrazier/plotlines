"""Locating the committed home-region PMTiles archive (ARCH D41, FR96;
issue #154) — the same shipped-asset resolution pattern `version.py` uses for
`version.lock`, because both are data files a freezer bundles and a source
run finds relative to the repo.
"""

from __future__ import annotations

import sys
from pathlib import Path

_RELATIVE = Path("plotlines_service") / "data" / "home_region.pmtiles"


def _candidates() -> list[Path]:
    paths = []
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        paths.append(Path(meipass) / _RELATIVE)
    try:
        paths.append(Path(sys.executable).resolve().parent / _RELATIVE)
    except OSError:
        pass
    # Source checkout: service/plotlines_service/tiles_paths.py -> service/plotlines_service/data/
    paths.append(Path(__file__).resolve().parent / "data" / "home_region.pmtiles")
    return paths


def default_home_region_archive() -> Path:
    """The committed Buncombe County, NC archive — FR96's "shipped, not
    downloaded" basemap. Raises `FileNotFoundError` (never guesses) if a
    build shipped without it, the same way `version.py` treats a missing
    version.lock as a build defect rather than something to paper over."""
    for path in _candidates():
        if path.exists():
            return path
    raise FileNotFoundError(
        "committed home-region PMTiles archive not found in any candidate "
        f"location: {[str(p) for p in _candidates()]}"
    )
