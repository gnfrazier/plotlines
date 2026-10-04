"""Pi5 QA/UAT caching elevation proxy — companion to epic #264, not #148.

`python -m plotlines_service.elevation_proxy --cache-dir /srv/plotlines-elevation-cache`

**What this is.** QA and UAT testing (plus load-test bursts) can put several
machines' worth of elevation lookups against OpenTopography's free-tier
ceiling (50 calls/24h, PRD FR87) in a short window, risking key revocation.
This is a small, standalone service — deliberately outside
`plotlines_service.app`'s import graph, so it never rides along in the frozen
sidecar binary — that holds the *one* real OpenTopography key, serves DEMs to
every QA/dev sidecar from a permanent on-disk cache (terrain doesn't change,
so a cache hit never expires), and lets `POST /regions` on those sidecars
report real elevation instead of the fixed `elevation_source_not_configured`
state every sidecar reports today.

**What this is not.** This is not issue #148/FR87's production source — #148
(D69) settled that as the sidecar's own local cache, then OpenTopography
direct with a key. No tier/key management UX, no Render-hosted service path.

**Its contract is the production one (#520, ARCH D67).** The proxy is
QA-scoped for its *source* — one OpenTopography key, shared by every QA
sidecar — but since #520 it answers on the mirror's fill contract
(`mirror_fill.py`, #517), the same one the OSM and basemap fills use:

- a cached bbox is the raster, as before;
- a miss is `202 {"state": "fetching", "fill": {…}}` with `Retry-After`,
  and the fetch runs on the worker's own queue — never inside the request
  (D66). Two misses for one bbox share one job and spend one call; that is
  #517's single-flight, replacing the lock this module used to keep for it;
- a spent allowance (FR87's 50 calls / 24 h) is still `fetching`, with
  `retry_after_s` pointing at the moment the ledger frees a call, and no
  call is spent. A wait, never flat terrain presented as real (FR88);
- `failed:<reason>` is a fetch that ran and did not land.

`POST /fill {"layer": "elevation", …}` and `GET /fill/{id}` are mounted too.
Deleting this proxy once the QA window closes deletes one source, not the
contract.

**Concurrency.** Run as a single process (no `--workers > 1`, no multiple
replicas sharing one cache directory). `CallLedger` is single-writer by
design (`plotlines_core.elevation.keys`); the fill worker's one-worker queue
is its only writer, and single-flight per bbox is what keeps a load-test
burst of identical-bbox misses from each spending a call.
"""

from __future__ import annotations

import argparse
import hmac
import logging
import math
import os
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping

import rasterio
import uvicorn
from rasterio.windows import Window, from_bounds
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse

from plotlines_core.cache_layout import CacheLayout
from plotlines_core.elevation.interface import BBox, LocalCacheSource
from plotlines_core.elevation.keys import (
    EnterpriseKeyRequired,
    FreeTierExhausted,
    OpenTopographyClient,
    client_from_env,
)

from .logging_setup import configure_logging
from .client_key import CLIENT_KEY_HEADER, normalize_client_key
from .mirror_fill import (
    FETCHING,
    READY,
    AreaPlan,
    FillDeferred,
    FilledArea,
    FillFailed,
    FillPlan,
    STAGING_PREFIX,
    FillWorker,
    add_fill_routes,
)
from .version import VERSION

log = logging.getLogger("plotlines.elevation_proxy")

#: Issue #495 put the fetch on its own pool behind this deadline; #520 goes
#: one step further — `/dem` no longer waits on the fetch at all (it answers
#: `202 fetching` and the fill worker runs it), so the number now bounds a
#: fill job's run: past it the job is `failed:timeout`, never `fetching`
#: forever. Margin over `OpenTopographyClient`'s own 120 s socket timeout,
#: which, like every synchronous transport's, does not cover a stalled DNS
#: lookup (#488).
_DEM_FETCH_TIMEOUT_S = 150.0


class CoveringRasters:
    """Issue #629 — which cached DEM already covers a bbox.

    The cache is keyed by exact bbox (`bbox_key`), so before this the full
    North Carolina prewarm raster served no trip inside it: every new trip
    bbox was a miss that spent one of the 50 daily calls. The bounds come
    from each raster's own header (the key is a hash, not a bbox), read once
    per file and re-read only when its mtime changes. A file rasterio can't
    open — an OpenTopography error body saved as `.tif`, a staging file —
    covers nothing."""

    def __init__(self, cache_dir: Path) -> None:
        self.cache_dir = Path(cache_dir)
        self._lock = threading.Lock()
        #: name -> (mtime_ns, (west, south, east, north, xres, yres) or None)
        self._index: dict[str, tuple[int, tuple[float, ...] | None]] = {}

    @staticmethod
    def _read_bounds(path: Path) -> tuple[float, ...] | None:
        try:
            with rasterio.open(path) as ds:
                if ds.crs is None or ds.crs.to_epsg() != 4326:
                    return None
                b = ds.bounds
                xres, yres = ds.res
                return (b.left, b.bottom, b.right, b.top, xres, yres)
        except Exception:  # noqa: BLE001 — unreadable covers nothing
            return None

    def _refresh(self) -> None:
        seen: set[str] = set()
        for path in self.cache_dir.glob("*.tif"):
            if path.name.startswith(STAGING_PREFIX):
                continue
            try:
                mtime = path.stat().st_mtime_ns
            except OSError:
                continue
            seen.add(path.name)
            held = self._index.get(path.name)
            if held is None or held[0] != mtime:
                self._index[path.name] = (mtime, self._read_bounds(path))
        for gone in set(self._index) - seen:
            del self._index[gone]

    def refresh(self) -> None:
        with self._lock:
            self._refresh()

    def find(self, bbox: BBox, *, exclude: Path | None = None,
             refresh: bool = True) -> Path | None:
        """The smallest cached raster whose extent contains `bbox`, or None.
        A raster may fall short of a requested edge by up to one pixel:
        OpenTopography snaps a fetch's extent to its pixel grid.

        `refresh=False` reads the index as it stands, with no disk I/O —
        for `deferral`, which `FillWorker.request` calls on the request
        thread under the worker's lock."""
        west, south, east, north = bbox
        best: tuple[float, Path] | None = None
        with self._lock:
            if refresh:
                self._refresh()
            entries = list(self._index.items())
        for name, (_, b) in entries:
            if b is None or (exclude is not None and name == exclude.name):
                continue
            left, bottom, right, top, xres, yres = b
            if (left <= west + xres and bottom <= south + yres
                    and right >= east - xres and top >= north - yres):
                area = (right - left) * (top - bottom)
                if best is None or area < best[0]:
                    best = (area, self.cache_dir / name)
        return best[1] if best else None


def crop_raster(src: Path, bbox: BBox, dest: Path) -> None:
    """Writes the window of `src` covering `bbox` to `dest`, rounded outward
    to whole pixels so the crop covers the bbox, clamped to `src`. Same
    dtype, CRS and nodata as the source."""
    west, south, east, north = bbox
    with rasterio.open(src) as ds:
        win = from_bounds(west, south, east, north, transform=ds.transform)
        col0 = max(0, math.floor(win.col_off))
        row0 = max(0, math.floor(win.row_off))
        col1 = min(ds.width, math.ceil(win.col_off + win.width))
        row1 = min(ds.height, math.ceil(win.row_off + win.height))
        window = Window(col0, row0, max(1, col1 - col0), max(1, row1 - row0))
        data = ds.read(window=window)
        profile = ds.profile.copy()
        profile.update(driver="GTiff", width=window.width, height=window.height,
                       transform=ds.window_transform(window), compress="deflate")
        for k in ("blockxsize", "blockysize", "tiled"):
            profile.pop(k, None)
    with rasterio.open(dest, "w", **profile) as out:
        out.write(data)


class ElevationFiller:
    """`mirror_fill.LayerFiller` for elevation (#520). The store is the
    proxy's own DEM cache (`LocalCacheSource`), so `plan` answers a cached
    bbox as `present` without the `areas` record. One area per bbox, keyed
    the way the cache already is."""

    layer = "elevation"
    retry_hint_s = 10
    #: `OpenTopographyClient.fetch` writes a `*.part` beside its target; a
    #: worker killed mid-body leaves one, and restart removes it.
    stale_globs = ("*.part",)

    def __init__(self, cache: LocalCacheSource, client: OpenTopographyClient,
                 *, now=lambda: datetime.now(timezone.utc)):
        self.cache = cache
        self.client = client
        self._now = now
        self.covering = CoveringRasters(cache.cache_dir)
        # Index at startup, so `deferral`'s no-I/O lookup knows the prewarm
        # rasters from the first request on; `fetch` refreshes it after.
        self.covering.refresh()

    def plan(self, bbox: BBox, records) -> FillPlan:
        path = self.cache.reserve(bbox)
        return FillPlan(areas=(AreaPlan(
            area=path.stem, path=path.name, bbox=bbox,
            present=self.cache.get(bbox) is not None),))

    def _wait_s(self) -> float | None:
        next_free = self.client.ledger.next_free_at()
        if next_free is None:
            return None
        return max(1.0, (next_free - self._now()).total_seconds())

    def deferral(self, area: AreaPlan) -> tuple[float, str] | None:
        """FR87: the allowance is spent — the job waits for the ledger to
        free a call, and the first answer already says how long. Not when a
        cached raster covers the area (#629): that serves with no call."""
        if self.covering.find(area.bbox, refresh=False) is not None:
            return None
        try:
            self.client.authorize()
        except FreeTierExhausted:
            wait = self._wait_s() or 3600.0
            return wait, ("the shared OpenTopography allowance is spent for now; "
                          f"this area is fetched when it frees up in about {wait / 60:.0f} min")
        except EnterpriseKeyRequired:
            return None  # the fetch reports it as a failure
        return None

    def fetch(self, area: AreaPlan, ctx) -> FilledArea:
        if self.cache.get(area.bbox) is not None:  # landed meanwhile
            return FilledArea(upstream="opentopography:cached")
        covering = self.covering.find(area.bbox)
        if covering is not None:
            # Issue #629 — crop, written to this bbox's own key so the next
            # request is an exact hit. Runs here, on the fill worker, not in
            # `/dem`: a window read of a 907 MB striped raster reads every
            # row the window crosses, seconds on the Pi.
            staged = ctx.staging_path(area.path)
            ctx.progress(None, "cropping a cached DEM that covers this area")
            try:
                crop_raster(covering, area.bbox, staged)
            except Exception as exc:  # noqa: BLE001 — fall through to a fetch
                staged.unlink(missing_ok=True)
                log.warning("dem CROP FAILED bbox=%s from=%s: %s",
                            area.bbox, covering.name, exc)
            else:
                ctx.publish(staged, area.path)
                log.info("dem CROPPED bbox=%s from=%s", area.bbox, covering.name)
                return FilledArea(upstream=f"cache-crop:{covering.stem}")
        try:
            self.client.authorize()
        except FreeTierExhausted:
            wait = self._wait_s() or 3600.0
            raise FillDeferred(wait, "the shared OpenTopography allowance is spent for now; "
                                     "waiting for it to free up") from None
        except EnterpriseKeyRequired as exc:
            raise FillFailed("enterprise_key_required", str(exc)) from None
        staged = ctx.staging_path(area.path)
        ctx.progress(None, "fetching the DEM from OpenTopography")
        try:
            self.client.fetch(self.client.base_url, area.bbox, staged)
        except Exception as exc:  # noqa: BLE001 — any upstream failure
            staged.unlink(missing_ok=True)
            raise FillFailed("upstream_fetch_failed", str(exc)) from None
        ctx.publish(staged, area.path)
        log.info("dem FETCHED bbox=%s remaining=%s", area.bbox, self.client.remaining_calls)
        return FilledArea(upstream="opentopography")


def create_proxy_app(
    cache_dir: Path,
    *,
    env: Mapping[str, str] | None = None,
    client: OpenTopographyClient | None = None,
    client_key: str | None = None,
    state_dir: Path | None = None,
) -> FastAPI:
    """Build the proxy app. `client` is test-only dependency injection — the
    real entrypoint always leaves it `None` so `client_from_env` runs and
    fails loud (`MissingApiKey`/`EnterpriseKeyRequired`) at startup rather
    than per-request, the moment a key is missing or mis-tiered.

    `client_key` (#520): when set, a miss (which starts a fill) and the
    `/fill` routes need the `X-Plotlines-Client-Key` header, as on the
    mirror (#263, #517). Unset keeps the proxy's QA posture — LAN-published
    only, no auth of its own — so existing QA sidecars keep working."""
    layout = CacheLayout(cache_dir).ensure_dirs()
    cache = LocalCacheSource(layout.elevation_dir)
    if client is None:
        client = client_from_env(layout.elevation_dir, env=env)
    filler = ElevationFiller(cache, client)
    worker = FillWorker(
        layout.elevation_dir, [filler],
        state_dir=state_dir or (Path(cache_dir) / "fill-journal"),
        state_path=Path(cache_dir) / "FILL_STATE.json",
        job_timeout_s=_DEM_FETCH_TIMEOUT_S,
    )
    configured_key = normalize_client_key(client_key)

    app = FastAPI(title="plotlines-elevation-proxy", version=VERSION)
    app.state.fill_worker = worker

    def _gate(request: Request) -> None:
        if configured_key is None:
            return
        presented = request.headers.get(CLIENT_KEY_HEADER)
        if presented is None or not hmac.compare_digest(presented, configured_key):
            raise HTTPException(401, detail={
                "error": "unauthorized_client",
                "message": f"this endpoint requires a {CLIENT_KEY_HEADER} header"})

    add_fill_routes(app, worker, start_gate=_gate, read_gate=_gate)

    @app.get("/dem")
    def get_dem(
        request: Request,
        west: float = Query(...),
        south: float = Query(...),
        east: float = Query(...),
        north: float = Query(...),
    ):
        bbox: BBox = (west, south, east, north)
        cached = cache.get(bbox)
        if cached is not None:
            return FileResponse(cached.path, media_type="image/tiff")
        _gate(request)
        status = worker.request("elevation", bbox)
        if status.state == READY:  # landed between the two looks
            cached = cache.get(bbox)
            if cached is not None:
                return FileResponse(cached.path, media_type="image/tiff")
        if status.state == FETCHING:
            log.info("dem FILLING bbox=%s fill_id=%s", bbox, status.fill_id)
            return JSONResponse(
                {"state": status.state, "fill": status.to_json()}, status_code=202,
                headers={"Retry-After": str(max(1, status.retry_after_s or 1))})
        # failed:<reason> — transient, never a raster and never flat terrain.
        log.warning("dem REFUSED bbox=%s reason=%s: %s", bbox, status.state, status.detail)
        headers = ({"Retry-After": str(max(1, status.retry_after_s))}
                   if status.retry_after_s else {})
        raise HTTPException(
            503,
            detail={"error": status.state.removeprefix("failed:"), "state": status.state,
                    "fill_id": status.fill_id, "message": status.detail},
            headers=headers)

    @app.get("/health")
    def proxy_health() -> dict:
        next_free = client.ledger.next_free_at()
        return {
            "ready": True,
            "remaining_calls_24h": client.remaining_calls,
            "next_free_at": next_free.isoformat() if next_free else None,
            "fill": {"in_flight": worker.in_flight()},
        }

    return app


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="plotlines-elevation-proxy")
    parser.add_argument(
        "--host",
        default="0.0.0.0",
        help="bind address inside the container/host network namespace "
             "(publish to loopback only at the Docker/systemd layer — this "
             "proxy has no auth of its own)",
    )
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument(
        "--cache-dir",
        type=Path,
        required=True,
        help="NVMe-backed directory for the permanent DEM cache and the "
             "OpenTopography call ledger",
    )
    parser.add_argument(
        "--client-key", default=os.environ.get("ELEVATION_PROXY_CLIENT_KEY"),
        help="issue #520: when set, a /dem miss (which starts a fill) and "
             "/fill need the X-Plotlines-Client-Key header, as on the mirror "
             "(#263, #517). Unset keeps the QA posture: LAN-published, no "
             "auth of its own. A cached /dem is always open.",
    )
    parser.add_argument(
        "--log-level", default="info", choices=("debug", "info", "warning", "error")
    )
    args = parser.parse_args(argv)

    configure_logging(None, args.log_level)  # stderr only — the container/systemd journal owns capture
    log.info(
        "elevation proxy starting version=%s host=%s port=%s cache_dir=%s "
        "(QA/UAT companion to epic #264 — not #148's production path)",
        VERSION, args.host, args.port, args.cache_dir,
    )

    app = create_proxy_app(args.cache_dir, client_key=args.client_key)
    config = uvicorn.Config(
        app, host=args.host, port=args.port, log_level=args.log_level, access_log=True
    )
    uvicorn.Server(config).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
