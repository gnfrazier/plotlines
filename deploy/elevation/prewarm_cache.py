#!/usr/bin/env python3
"""Pre-warm the Pi5 QA/UAT elevation proxy's cache (issue #450, companion to
#304) for a known set of trip bboxes, so the free-tier ceiling (50
calls/24h, FR87) isn't spent live once QA/UAT testing starts.

Run from anywhere with network access to the proxy — on the Pi itself
against the default 127.0.0.1, or from a LAN machine against the Pi's
address — a plain stdlib HTTP client, same deployment simplicity as
deploy/mirror/geofabrik_pull.py:

    python3 prewarm_cache.py -- \\
        -82.75,35.35,-82.35,35.70 \\
        -83.10,35.65,-82.70,36.00

The `--` before the bbox list is required, not decorative: every real bbox
here has a negative `west`, and without `--` argparse reads
`-82.75,35.35,-82.35,35.70` as an attempted option flag rather than a
positional value and refuses it. `--` is the standard argparse idiom for
"everything after this is positional" and works the same way in any shell.

Each bbox is `west,south,east,north` — the order
plotlines_core.elevation.interface.BBox and the proxy's own /dem endpoint
use throughout. **The two examples above are starting points, not a fixed
list this script ships with** — substitute the QA test plan's own known
trip bboxes (they are the same Asheville-area cells
deploy/mirror/README.md's live clip rehearsal suggests, chosen only because
this Pi's mirror corridor already covers them).

A bbox already served returns instantly from the proxy's on-disk cache
(terrain doesn't change, so a cache hit never expires) — running this
script twice against the same list is the acceptance check for "a repeat
request for a pre-warmed bbox is served from cache with no OpenTopography
call": the first pass pays real fetch time, the second should be near-
instant for every bbox that succeeded.
"""

from __future__ import annotations

import argparse
import enum
import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from urllib.parse import urlencode

BBox = tuple[float, float, float, float]


class PrewarmOutcome(enum.Enum):
    """How one `/dem` attempt landed — finer-grained than `prewarm_one`'s
    plain bool, so a caller orchestrating a whole run (see
    `prewarm_priority_regions.py`) can tell a ceiling refusal (which means
    "stop, the budget is spent, this is expected") apart from an upstream
    rejection (which means "this bbox was likely too large — check tile
    sizing") apart from anything else."""

    OK = "ok"
    EXHAUSTED = "exhausted"          # 503 free_tier_exhausted / enterprise_key_required
    UPSTREAM_FAILED = "upstream_failed"  # 502 upstream_fetch_failed
    OTHER_ERROR = "other_error"


@dataclass(frozen=True)
class PrewarmResult:
    bbox: BBox
    outcome: PrewarmOutcome
    detail: str
    elapsed_s: float
    bytes_len: int | None
    retry_after_s: int | None


def _parse_bbox(raw: str) -> BBox:
    parts = raw.split(",")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(f"{raw!r} is not west,south,east,north")
    try:
        west, south, east, north = (float(p) for p in parts)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{raw!r}: {exc}") from None
    return west, south, east, north


def prewarm_one_detailed(base_url: str, bbox: BBox, *, timeout: float = 180.0) -> PrewarmResult:
    """Fetch one bbox from the proxy. Never raises — a failed bbox (e.g.
    free_tier_exhausted, 503 + Retry-After) must not stop the rest of a list
    from being attempted. Classifies the outcome (see `PrewarmOutcome`) by
    the JSON error body's `"error"` field, matching the shapes
    `service/plotlines_service/elevation_proxy.py`'s `/dem` endpoint sends —
    FastAPI's `HTTPException(detail={"error": ...})` wraps that dict under a
    top-level `"detail"` key on the wire, so `"error"` is read from there
    first and only falls back to the body's own top level for a body that
    isn't FastAPI-wrapped."""
    west, south, east, north = bbox
    query = urlencode({"west": west, "south": south, "east": east, "north": north})
    url = f"{base_url}?{query}"
    start = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        elapsed = time.monotonic() - start
        detail = exc.read().decode("utf-8", "replace")
        retry_after_raw = exc.headers.get("Retry-After")
        retry_after = (
            int(retry_after_raw) if retry_after_raw and retry_after_raw.isdigit() else None
        )
        error_key = None
        try:
            parsed = json.loads(detail)
            payload = parsed.get("detail", parsed) if isinstance(parsed, dict) else None
            error_key = payload.get("error") if isinstance(payload, dict) else None
        except (ValueError, AttributeError):
            pass
        if error_key in ("free_tier_exhausted", "enterprise_key_required"):
            outcome = PrewarmOutcome.EXHAUSTED
        elif error_key == "upstream_fetch_failed":
            outcome = PrewarmOutcome.UPSTREAM_FAILED
        else:
            outcome = PrewarmOutcome.OTHER_ERROR
        suffix = f" (Retry-After: {retry_after}s)" if retry_after else ""
        print(f"FAILED {bbox}: HTTP {exc.code} {detail}{suffix}", file=sys.stderr)
        return PrewarmResult(bbox, outcome, detail, elapsed, None, retry_after)
    except urllib.error.URLError as exc:
        elapsed = time.monotonic() - start
        print(f"FAILED {bbox}: {exc.reason}", file=sys.stderr)
        return PrewarmResult(bbox, PrewarmOutcome.OTHER_ERROR, str(exc.reason), elapsed, None, None)
    elapsed = time.monotonic() - start
    print(f"OK {bbox}: {len(body)} bytes in {elapsed:.1f}s")
    return PrewarmResult(bbox, PrewarmOutcome.OK, "", elapsed, len(body), None)


def prewarm_one(base_url: str, bbox: BBox, *, timeout: float = 180.0) -> bool:
    """Fetch one bbox from the proxy. Returns whether it succeeded; never
    raises. Unchanged contract — a thin wrapper over
    `prewarm_one_detailed`."""
    return prewarm_one_detailed(base_url, bbox, timeout=timeout).outcome is PrewarmOutcome.OK


def query_health(proxy_root: str, *, timeout: float = 30.0) -> dict:
    """`GET {proxy_root}/health` -> `{"ready", "remaining_calls_24h",
    "next_free_at"}`. Still stdlib-only (urllib + json); doesn't touch this
    script's copy-anywhere deployability."""
    url = f"{proxy_root.rstrip('/')}/health"
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--base-url",
        default="http://127.0.0.1:8090/dem",
        help="the proxy's /dem endpoint (default: %(default)s — run this on "
        "the Pi itself; pass the LAN address's :8090/dem from elsewhere)",
    )
    parser.add_argument(
        "bboxes",
        nargs="+",
        type=_parse_bbox,
        metavar="west,south,east,north",
        help="one or more trip bboxes from the QA test plan",
    )
    args = parser.parse_args(argv)

    results = [prewarm_one(args.base_url, bbox) for bbox in args.bboxes]
    failed = results.count(False)
    if failed:
        print(f"{failed}/{len(results)} bbox(es) failed to pre-warm", file=sys.stderr)
        return 1
    print(f"all {len(results)} bbox(es) pre-warmed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
