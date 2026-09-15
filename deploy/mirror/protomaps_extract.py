#!/usr/bin/env python3
"""Acquire a real Protomaps-basemap extract for the mirror — issue #394
(gap found auditing #257's own closing comment: "the real Protomaps planet
build (`MIRROR_ARCHIVE_URL`) is unacquired — nothing points a default
upstream at it").

`copy_basemap_standin.sh` (#257) copied in the SPIKE-14 corridor archive —
118 MB of **synthetic** test tiles, honestly named `<build>-wnc/corridor.
pmtiles` rather than `planet.pmtiles` so a bbox outside WNC fails as a
diagnosable coverage miss rather than a silent one. This script replaces
that synthetic content with a **real** extract cut from Protomaps' own
hosted daily planet build, at the same honest path — the "stand-in" becomes
real OSM-derived tiles without becoming a planet archive, which review §6.2
still forbids putting on the Pi ("do not put a planet archive on it —
regional extracts only").

## Why an extract, not the whole planet

`docs/Plotlines_OSM_Acquisition_Review.md` §6.0 (Q6 = D + C) defers hosting
the full planet build to zero-egress object storage "later" — unprovisioned,
no bucket, no credentials in this repo. Issue #375 already hit the identical
shape of problem on the Geofabrik side and answered it the same way: WNC is
the only region this mirror actually serves today, so precut a small extract
once and pin that, rather than mirror something whole-planet-sized nothing
here yet needs. This script is that answer for the basemap.

## Why the `pmtiles` CLI, not `plotlines_core.tiles.extract.extract_bbox`

`extract_bbox` is the right tool for a live per-trip request — it lazily
range-reads however many tiles one bbox needs (tens to low hundreds) through
`pmtiles.reader.Reader.get()`, which re-walks the archive's directory tree
and issues one HTTP request per tile with no request coalescing. Measured
against this script's own WNC-corridor bbox (43,328 tiles, z0-15) that path
was still running after two minutes and was killed rather than timed to
completion. The real `pmtiles extract` CLI (github.com/protomaps/go-pmtiles)
clusters directory lookups and coalesces adjacent tile ranges into few HTTP
requests — the same tool and the same live endpoint SPIKE-14 already
validated (`spikes/SPIKE-14/results/RESULTS.md` §4-5): **95 requests, 124 MB
transferred, ~11s wall time** for this exact bbox, measured against the real
`build.protomaps.com` archive while building this script. This is a one-time
bulk-acquisition tool, not the live request path FR92/94 governs — reaching
a third-party host here is the point, not a policy violation, so it always
passes `allow_unmirrored`-equivalent intent by construction rather than
going through `mirror.resolve_upstream` at all.

## Build-date discovery

Protomaps publishes no build index/manifest and retains only a short,
undocumented rolling window of daily builds — measured while building this
script: `20260908.pmtiles` 404s, `20260909.pmtiles`-`20260914.pmtiles` all
200. A date pinned once (the way `PROTOMAPS_BASEMAP_BUILD` or Geofabrik's
`pinned_date` are) would silently go dead within about a week, so
`find_latest_build_date` probes backward from today with a plain HEAD
request rather than trusting any previously-recorded date — the analogue of
Geofabrik's conditional-first check, adapted to an upstream with no index at
all.

## What gets published, and what doesn't

The output goes under the **existing honest path**
(`basemap/protomaps/<build-id>/corridor.pmtiles`, `WNC_CORRIDOR_BUILD_ID` by
default) — never `planet.pmtiles`, and never a whole-planet archive on disk.
`MIRROR_STATE.json`'s `basemap` key keeps its existing shape
(`build_id`, `covered_regions`) so `mirror_state.basemap_health()` and every
existing reader keep working unchanged, plus a new `source` sub-object
recording *which* upstream build this extract actually came from
(`planet_build_date`, `source_url`, `tile_count`, `transferred_bytes`) and
`extracted_at` — a real pull timestamp, so a re-run's freshness no longer
has to be inferred from the leading date embedded in `build_id` the way
`basemap_health`'s docstring says the manual-copy stand-in required.

Usage::

    ./protomaps_extract.py --root /srv/plotlines-mirror

Requires the `pmtiles` CLI (github.com/protomaps/go-pmtiles) on `PATH`, or
pass `--pmtiles-bin`; falls back to the repo-relative
`spikes/SPIKE-14/tools/pmtiles` binary this script's own commit measured
against, when present, purely as a development convenience.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOG = logging.getLogger("protomaps_extract")

DEFAULT_UPSTREAM_BASE_URL = "https://build.protomaps.com"
DEFAULT_MAX_LOOKBACK_DAYS = 14
DEFAULT_MAXZOOM = 15

# Kept in lockstep with core/plotlines_core/osm_identity.py's
# osm_user_agent() — this script runs standalone (deployed via
# `scp -r deploy/mirror`, see README.md) without the rest of the repo, so it
# cannot import that module at runtime. Only used for this script's own HEAD
# probes; the `pmtiles` CLI subprocess sends its own UA, which this script
# does not control (no such flag exists — see its --help).
PLOTLINES_USER_AGENT = (
    "Plotlines/mirror-protomaps-extract (+https://github.com/gnfrazier/plotlines)"
)


class BuildNotFound(RuntimeError):
    """No Protomaps daily build responded within the lookback window."""


class ExtractFailed(RuntimeError):
    """The `pmtiles extract` subprocess did not produce a usable archive."""


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _build_url(base_url: str, build_date: str) -> str:
    return f"{base_url.rstrip('/')}/{build_date}.pmtiles"


def _head_ok(url: str, *, timeout: float = 15.0) -> bool:
    req = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": PLOTLINES_USER_AGENT},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout):
            return True
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return False
        raise
    except urllib.error.URLError:
        raise


def find_latest_build_date(
    *,
    base_url: str = DEFAULT_UPSTREAM_BASE_URL,
    start: datetime | None = None,
    max_lookback_days: int = DEFAULT_MAX_LOOKBACK_DAYS,
) -> str:
    """Probe backward one day at a time from `start` (default: today, UTC)
    for the first `YYYYMMDD.pmtiles` that HEAD-responds 200. Protomaps
    publishes no build index, and this script's own measurement found the
    live retention window to be roughly a week — a date recorded once and
    reused later is not a safe assumption, so this always re-probes rather
    than trusting a cached value."""
    day = (start or _utcnow()).date()
    for offset in range(max_lookback_days):
        candidate = (day - timedelta(days=offset)).strftime("%Y%m%d")
        url = _build_url(base_url, candidate)
        LOG.debug("probing %s", url)
        if _head_ok(url):
            LOG.info("latest available build: %s", candidate)
            return candidate
    raise BuildNotFound(
        f"no Protomaps daily build found under {base_url} in the last "
        f"{max_lookback_days} days — Protomaps' retention window may have "
        f"changed; pass --build-date explicitly if you know a live one"
    )


def _resolve_pmtiles_bin(explicit: str | None) -> str:
    if explicit:
        return explicit
    found = shutil.which("pmtiles")
    if found:
        return found
    # Development convenience: the binary this script's own commit measured
    # against, vendored for SPIKE-14. Not something a Pi deploy should rely
    # on — that's why PATH is checked first.
    repo_root = Path(__file__).resolve().parents[2]
    fallback = repo_root / "spikes" / "SPIKE-14" / "tools" / "pmtiles"
    if fallback.is_file() and os.access(fallback, os.X_OK):
        return str(fallback)
    raise ExtractFailed(
        "no `pmtiles` binary found on PATH and no --pmtiles-bin given — "
        "install it from https://github.com/protomaps/go-pmtiles/releases"
    )


def run_pmtiles_extract(
    *,
    pmtiles_bin: str,
    source_url: str,
    out_path: Path,
    bbox: tuple[float, float, float, float],
    maxzoom: int,
    minzoom: int | None = None,
) -> str:
    """Runs `pmtiles extract` into `out_path` (a scratch file, never the
    published path directly — the caller publishes atomically). Returns the
    subprocess's combined stdout/stderr for logging/provenance; raises
    `ExtractFailed` on a non-zero exit or a missing output file."""
    west, south, east, north = bbox
    cmd = [
        pmtiles_bin, "extract", source_url, str(out_path),
        f"--bbox={west},{south},{east},{north}",
        f"--maxzoom={maxzoom}",
    ]
    if minzoom is not None:
        cmd.append(f"--minzoom={minzoom}")
    LOG.info("running: %s", " ".join(cmd))
    result = subprocess.run(cmd, capture_output=True, text=True)
    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0 or not out_path.is_file():
        raise ExtractFailed(
            f"pmtiles extract exited {result.returncode}: {output.strip()}"
        )
    return output


def publish_basemap_extract(
    *,
    root: Path,
    out_path: Path,
    build_id: str,
    region_name: str,
    bbox: tuple[float, float, float, float],
    source_url: str,
    planet_build_date: str,
    extracted_at: datetime,
    cli_output: str = "",
) -> Path:
    """Atomically moves `out_path` into the mirror tree under
    `basemap/protomaps/<build_id>/corridor.pmtiles` and merges the
    `basemap` key into `MIRROR_STATE.json` — never touching `geofabrik`,
    the same non-clobbering contract `copy_basemap_standin.sh` and
    `build_tree.sh` already document for the file as a whole."""
    state_path = root / "MIRROR_STATE.json"
    if not state_path.exists():
        raise SystemExit(
            f"error: {state_path} does not exist — run build_tree.sh "
            f"against {root} first."
        )

    dest_dir = root / "basemap" / "protomaps" / build_id
    dest = dest_dir / "corridor.pmtiles"
    dest_dir.mkdir(parents=True, exist_ok=True)

    # `out_path` may be on a different filesystem than `dest` (e.g. a
    # scratch dir vs. the mirror root) — os.replace requires the same one,
    # so copy-then-atomic-rename via a same-directory temp file rather than
    # assuming os.replace works directly across the two.
    fd, tmp_name = tempfile.mkstemp(dir=dest_dir, prefix=".extract-")
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        shutil.copyfile(out_path, tmp_path)
        os.replace(tmp_path, dest)
    except BaseException:
        tmp_path.unlink(missing_ok=True)
        raise

    with open(state_path) as f:
        state = json.load(f)
    state["basemap"] = {
        "build_id": build_id,
        "covered_regions": [{"name": region_name, "bbox": list(bbox)}],
        "source": {
            "provider": "protomaps",
            "planet_build_date": planet_build_date,
            "source_url": source_url,
            "size_bytes": dest.stat().st_size,
        },
        "extracted_at": _iso(extracted_at),
    }
    fd, tmp_state_name = tempfile.mkstemp(dir=root, prefix=".state-")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, indent=2)
            f.write("\n")
        os.replace(tmp_state_name, state_path)
    except BaseException:
        Path(tmp_state_name).unlink(missing_ok=True)
        raise

    LOG.info("published %s (%d bytes) -> %s", source_url, dest.stat().st_size, dest)
    if cli_output:
        LOG.debug("pmtiles extract output:\n%s", cli_output)
    return dest


def acquire(
    *,
    root: Path,
    bbox: tuple[float, float, float, float],
    region_name: str,
    build_id: str,
    upstream_base_url: str = DEFAULT_UPSTREAM_BASE_URL,
    build_date: str | None = None,
    max_lookback_days: int = DEFAULT_MAX_LOOKBACK_DAYS,
    maxzoom: int = DEFAULT_MAXZOOM,
    minzoom: int | None = None,
    pmtiles_bin: str | None = None,
    now: datetime | None = None,
) -> Path:
    """End to end: find a live build, extract `bbox` from it into a scratch
    file, then publish that scratch file into `root`. Never leaves a
    partial/half-extracted file at the published path — `run_pmtiles_extract`
    writes to a scratch path first and `publish_basemap_extract` moves it
    into place with `os.replace` only after the extract fully succeeded."""
    resolved_bin = _resolve_pmtiles_bin(pmtiles_bin)
    resolved_date = build_date or find_latest_build_date(
        base_url=upstream_base_url, start=now, max_lookback_days=max_lookback_days,
    )
    source_url = _build_url(upstream_base_url, resolved_date)

    with tempfile.TemporaryDirectory(prefix="protomaps-extract-") as scratch:
        scratch_out = Path(scratch) / "corridor.pmtiles"
        cli_output = run_pmtiles_extract(
            pmtiles_bin=resolved_bin, source_url=source_url, out_path=scratch_out,
            bbox=bbox, maxzoom=maxzoom, minzoom=minzoom,
        )
        return publish_basemap_extract(
            root=root, out_path=scratch_out, build_id=build_id,
            region_name=region_name, bbox=bbox, source_url=source_url,
            planet_build_date=resolved_date, extracted_at=now or _utcnow(),
            cli_output=cli_output,
        )


def main(argv: list[str] | None = None) -> int:
    # Defaults come from plotlines_core.tiles.mirror when it's importable
    # (a dev machine with plotlines-core installed — this script needs that
    # anyway for nothing beyond these constants, unlike geofabrik_pull.py
    # which is a fully standalone scp-only deploy). Falls back to the
    # literals those constants currently hold so --help still works without
    # plotlines-core on PATH.
    try:
        from plotlines_core.tiles.mirror import (
            WNC_CORRIDOR_BBOX as _DEFAULT_BBOX,
            WNC_CORRIDOR_BUILD_ID as _DEFAULT_BUILD_ID,
            WNC_CORRIDOR_REGION_NAME as _DEFAULT_REGION_NAME,
        )
    except ImportError:
        _DEFAULT_BBOX = (-83.6, 35.2, -81.0, 36.4)
        _DEFAULT_BUILD_ID = "20250101-wnc"
        _DEFAULT_REGION_NAME = "wnc-corridor"

    parser = argparse.ArgumentParser(
        description="Extract a real Protomaps-basemap region from the live "
                     "daily planet build and publish it to the Plotlines "
                     "mirror tree (issue #394).",
    )
    parser.add_argument("--root", type=Path, default=Path("/srv/plotlines-mirror"))
    parser.add_argument("--bbox", default=None,
                         help="west,south,east,north — default: the WNC "
                              "corridor plotlines_core.tiles.mirror.mirror "
                              "pins (the only region this mirror serves).")
    parser.add_argument("--region-name", default=_DEFAULT_REGION_NAME)
    parser.add_argument("--build-id", default=_DEFAULT_BUILD_ID,
                         help="Directory this publishes under: "
                              "basemap/protomaps/<build-id>/corridor.pmtiles.")
    parser.add_argument("--upstream-base-url", default=DEFAULT_UPSTREAM_BASE_URL)
    parser.add_argument("--build-date", default=None,
                         help="Explicit YYYYMMDD upstream build to extract "
                              "from. Default: probe for the latest one that "
                              "actually responds (see find_latest_build_date "
                              "— Protomaps publishes no index and retains "
                              "only a short rolling window).")
    parser.add_argument("--max-lookback-days", type=int,
                         default=DEFAULT_MAX_LOOKBACK_DAYS)
    parser.add_argument("--maxzoom", type=int, default=DEFAULT_MAXZOOM)
    parser.add_argument("--minzoom", type=int, default=None)
    parser.add_argument("--pmtiles-bin", default=None)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    if args.bbox:
        west, south, east, north = (float(v) for v in args.bbox.split(","))
        bbox = (west, south, east, north)
    else:
        bbox = _DEFAULT_BBOX

    try:
        acquire(
            root=args.root, bbox=bbox, region_name=args.region_name,
            build_id=args.build_id, upstream_base_url=args.upstream_base_url,
            build_date=args.build_date, max_lookback_days=args.max_lookback_days,
            maxzoom=args.maxzoom, minzoom=args.minzoom,
            pmtiles_bin=args.pmtiles_bin,
        )
    except (BuildNotFound, ExtractFailed) as exc:
        LOG.error("%s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
