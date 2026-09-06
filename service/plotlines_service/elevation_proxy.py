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

**What this is not.** This is not issue #148/FR87's production Phase 2 build
(ARCH §12.1's "device → hosted cache → provider" shape, built for real here at
QA scale only). No end-to-end `CapabilityState` tracking, no tier/key
management UX, no Render-hosted service path. Safe to delete once the QA
window closes or #148 lands with its own implementation.

**Concurrency.** Run as a single process (no `--workers > 1`, no multiple
replicas sharing one cache directory). `CallLedger` is single-writer by
design (`plotlines_core.elevation.keys`); the module-level lock here is what
keeps a load-test burst of identical-bbox misses from each spending a call
before the first one's write-back lands.
"""

from __future__ import annotations

import argparse
import logging
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Mapping

import uvicorn
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse

from plotlines_core.cache_layout import CacheLayout
from plotlines_core.elevation.interface import BBox, LocalCacheSource
from plotlines_core.elevation.keys import (
    EnterpriseKeyRequired,
    FreeTierExhausted,
    OpenTopographyClient,
    client_from_env,
)

from .logging_setup import configure_logging
from .version import VERSION

log = logging.getLogger("plotlines.elevation_proxy")


def create_proxy_app(
    cache_dir: Path,
    *,
    env: Mapping[str, str] | None = None,
    client: OpenTopographyClient | None = None,
) -> FastAPI:
    """Build the proxy app. `client` is test-only dependency injection — the
    real entrypoint always leaves it `None` so `client_from_env` runs and
    fails loud (`MissingApiKey`/`EnterpriseKeyRequired`) at startup rather
    than per-request, the moment a key is missing or mis-tiered."""
    layout = CacheLayout(cache_dir).ensure_dirs()
    cache = LocalCacheSource(layout.elevation_dir)
    if client is None:
        client = client_from_env(layout.elevation_dir, env=env)
    lock = threading.Lock()

    app = FastAPI(title="plotlines-elevation-proxy", version=VERSION)

    @app.get("/dem")
    def get_dem(
        west: float = Query(...),
        south: float = Query(...),
        east: float = Query(...),
        north: float = Query(...),
    ) -> FileResponse:
        bbox: BBox = (west, south, east, north)
        with lock:
            cached = cache.get(bbox)
            if cached is not None:
                return FileResponse(cached.path, media_type="image/tiff")

            try:
                client.authorize()
            except FreeTierExhausted as exc:
                next_free = client.ledger.next_free_at()
                headers = {}
                if next_free is not None:
                    wait_s = max(
                        1, int((next_free - datetime.now(timezone.utc)).total_seconds())
                    )
                    headers["Retry-After"] = str(wait_s)
                log.warning("dem REFUSED bbox=%s reason=free_tier_exhausted", bbox)
                raise HTTPException(
                    503,
                    detail={"error": "free_tier_exhausted", "message": str(exc)},
                    headers=headers,
                ) from None
            except EnterpriseKeyRequired as exc:
                log.error("dem REFUSED bbox=%s reason=enterprise_key_required", bbox)
                raise HTTPException(
                    503,
                    detail={"error": "enterprise_key_required", "message": str(exc)},
                ) from None

            dest = cache.reserve(bbox)
            try:
                path = client.fetch(client.base_url, bbox, dest)
            except Exception as exc:  # noqa: BLE001 — any upstream failure is 502
                log.warning("dem FETCH FAILED bbox=%s: %s", bbox, exc)
                raise HTTPException(
                    502,
                    detail={"error": "upstream_fetch_failed", "message": str(exc)},
                ) from exc
            log.info(
                "dem FETCHED bbox=%s remaining=%s", bbox, client.remaining_calls
            )
            return FileResponse(path, media_type="image/tiff")

    @app.get("/health")
    def proxy_health() -> dict:
        next_free = client.ledger.next_free_at()
        return {
            "ready": True,
            "remaining_calls_24h": client.remaining_calls,
            "next_free_at": next_free.isoformat() if next_free else None,
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
        "--log-level", default="info", choices=("debug", "info", "warning", "error")
    )
    args = parser.parse_args(argv)

    configure_logging(None, args.log_level)  # stderr only — the container/systemd journal owns capture
    log.info(
        "elevation proxy starting version=%s host=%s port=%s cache_dir=%s "
        "(QA/UAT companion to epic #264 — not #148's production path)",
        VERSION, args.host, args.port, args.cache_dir,
    )

    app = create_proxy_app(args.cache_dir)
    config = uvicorn.Config(
        app, host=args.host, port=args.port, log_level=args.log_level, access_log=True
    )
    uvicorn.Server(config).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
