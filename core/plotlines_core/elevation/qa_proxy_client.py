"""QA-only elevation fetcher: talks to the Pi5 caching elevation proxy
(companion to epic #264), never to OpenTopography directly.

Short-term, QA/UAT-scoped infrastructure — **not** the Phase 2 production
shared cache tracked under issue #148/FR87 (ARCH §12.1). Safe to delete once
the QA/UAT window closes or #148 lands with its own production client. The
Pi5-side counterpart this talks to is
`service.plotlines_service.elevation_proxy`.

Unlike `plotlines_core.elevation.keys.OpenTopographyClient`, this fetcher
carries no API key and enforces no FR87 budget — the Pi5 proxy holds the real
key and enforces the free-tier ceiling on every sidecar's behalf. A sidecar
wiring this in never needs `PLOTLINES_OPENTOPOGRAPHY_API_KEY` set at all.
"""

from __future__ import annotations

import shutil
import tempfile
import urllib.request
from pathlib import Path
from urllib.parse import urlencode

from plotlines_core.elevation.interface import BBox


def qa_proxy_fetch(base_url: str, bbox: BBox, dest: Path) -> Path:
    """Download the DEM covering `bbox` from the Pi5 QA elevation proxy's
    `/dem` endpoint to `dest`.

    Matches the `Fetcher` shape `HttpElevationSource` expects. Raises on any
    non-2xx response or transport failure; `HttpElevationSource.get()` reads
    that as a cache miss and the resolver degrades to flat elevation (FR88)
    rather than propagating further.
    """
    min_lon, min_lat, max_lon, max_lat = bbox
    query = urlencode(
        {
            "west": f"{min_lon}",
            "south": f"{min_lat}",
            "east": f"{max_lon}",
            "north": f"{max_lat}",
        }
    )
    url = f"{base_url}?{query}"
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120.0) as response:
        with tempfile.NamedTemporaryFile(
            dir=str(dest.parent), suffix=".part", delete=False
        ) as tmp:
            tmp_path = Path(tmp.name)
            shutil.copyfileobj(response, tmp)
    tmp_path.replace(dest)
    return dest
