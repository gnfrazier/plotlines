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
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlencode

BBox = tuple[float, float, float, float]


def _parse_bbox(raw: str) -> BBox:
    parts = raw.split(",")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError(f"{raw!r} is not west,south,east,north")
    try:
        west, south, east, north = (float(p) for p in parts)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{raw!r}: {exc}") from None
    return west, south, east, north


def prewarm_one(base_url: str, bbox: BBox, *, timeout: float = 180.0) -> bool:
    """Fetch one bbox from the proxy. Returns whether it succeeded; never
    raises — a failed bbox (e.g. free_tier_exhausted, 503 + Retry-After)
    must not stop the rest of the list from being attempted."""
    west, south, east, north = bbox
    query = urlencode({"west": west, "south": south, "east": east, "north": north})
    url = f"{base_url}?{query}"
    start = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        retry_after = exc.headers.get("Retry-After")
        suffix = f" (Retry-After: {retry_after}s)" if retry_after else ""
        print(f"FAILED {bbox}: HTTP {exc.code} {detail}{suffix}", file=sys.stderr)
        return False
    except urllib.error.URLError as exc:
        print(f"FAILED {bbox}: {exc.reason}", file=sys.stderr)
        return False
    elapsed = time.monotonic() - start
    print(f"OK {bbox}: {len(body)} bytes in {elapsed:.1f}s")
    return True


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
