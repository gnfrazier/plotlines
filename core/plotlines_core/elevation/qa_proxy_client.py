"""QA-only elevation fetcher: talks to the Pi5 caching elevation proxy
(companion to epic #264), never to OpenTopography directly.

Short-term, QA/UAT-scoped infrastructure — **not** ARCH §12.1's Phase 2
production shared cache, and not #148's Phase 1 production path (the direct
`OpenTopographyClient`, wired into region builds since #148). Safe to delete
once the QA/UAT window closes. The
Pi5-side counterpart this talks to is
`service.plotlines_service.elevation_proxy`.

Unlike `plotlines_core.elevation.keys.OpenTopographyClient`, this fetcher
carries no API key and enforces no FR87 budget — the Pi5 proxy holds the real
key and enforces the free-tier ceiling on every sidecar's behalf. A sidecar
wiring this in never needs `PLOTLINES_OPENTOPOGRAPHY_API_KEY` set at all.
"""

from __future__ import annotations

import json
import shutil
import tempfile
import urllib.request
from pathlib import Path
from urllib.parse import urlencode

from plotlines_core.elevation.interface import BBox
from plotlines_core.osm_identity import osm_user_agent


class ElevationFilling(RuntimeError):
    """The proxy answered `202`: it is fetching this area (or waiting for
    the shared OpenTopography allowance to free up) on the fill contract
    (#520, ARCH D67). A *not yet* — never flat terrain, never a failure.
    `retry_after_s` says when asking again can succeed; for a spent
    allowance that is the ledger's reset, possibly hours away."""

    def __init__(self, message: str, *, fill_id: str | None,
                 retry_after_s: float | None, detail: str = ""):
        super().__init__(message)
        self.fill_id = fill_id
        self.retry_after_s = retry_after_s
        self.detail = detail


def qa_proxy_fetch(base_url: str, bbox: BBox, dest: Path) -> Path:
    """Download the DEM covering `bbox` from the Pi5 QA elevation proxy's
    `/dem` endpoint to `dest`.

    Matches the `Fetcher` shape `HttpElevationSource` expects. Raises on any
    non-2xx response or transport failure, and `ElevationFilling` on a
    `202` (#520: the proxy is fetching it). The region build reads
    `ElevationFilling` as a wait rather than an absence (#521).
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
    req = urllib.request.Request(url, headers={"User-Agent": osm_user_agent()})
    tmp_path: Path | None = None
    try:
        with urllib.request.urlopen(req, timeout=120.0) as response:
            if getattr(response, "status", 200) == 202:
                # #520: a JSON fill status, never a raster — it must not
                # land in the DEM cache.
                try:
                    fill = (json.loads(response.read().decode("utf-8")) or {}).get("fill") or {}
                except (ValueError, UnicodeDecodeError, AttributeError):
                    fill = {}
                retry = response.headers.get("Retry-After")
                raise ElevationFilling(
                    "The elevation proxy is fetching elevation for this area.",
                    fill_id=fill.get("fill_id"),
                    retry_after_s=(float(retry) if retry and retry.isdigit()
                                   else fill.get("retry_after_s")),
                    detail=fill.get("detail") or "",
                )
            with tempfile.NamedTemporaryFile(
                dir=str(dest.parent), suffix=".part", delete=False
            ) as tmp:
                tmp_path = Path(tmp.name)
                shutil.copyfileobj(response, tmp)
        tmp_path.replace(dest)
    except BaseException:
        # No `.part` left in the DEM cache for a transfer that died mid-body.
        if tmp_path is not None:
            tmp_path.unlink(missing_ok=True)
        raise
    return dest
