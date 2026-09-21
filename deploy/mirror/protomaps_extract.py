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

Each region's output goes under its own **honest path**
(`basemap/protomaps/<build-id>/<filename>`, e.g. `WNC_CORRIDOR_BUILD_ID`'s
`corridor.pmtiles`) — never `planet.pmtiles`, and never a whole-planet
archive on disk. `build_id` is a stable path pin per region (like
Geofabrik's `pinned_date`), not the upstream planet build date — a refresh
overwrites the same file in place rather than growing a new one, per
review §6.2's "regional extracts only" and this issue's own retention
answer (one file per region is already bounded, nothing to sweep).
`MIRROR_STATE.json`'s `basemap.covered_regions` is a dict keyed by region
name (issue #457 generalized it from a single-region list), each entry
carrying `bbox`, `path`, `build_id`, a `source` sub-object recording *which*
upstream build this extract actually came from (`planet_build_date`,
`source_url`, `size_bytes`) and `extracted_at` — a real pull timestamp, so a
re-run's freshness no longer has to be inferred from the leading date
embedded in `build_id` the way `basemap_health`'s docstring says the manual-
copy stand-in required. The *primary* region (today: the WNC corridor, the
only one `SidecarUpstreams.tilesUpstream`'s built-in default points at)
additionally mirrors its own entry up to `basemap.build_id`/`source`/
`extracted_at` at the top level, so `mirror_state.basemap_health()` and the
client's existing flat reading of `capabilities.mirror.basemap` keep
working unchanged.

## Repeatable, TTL-driven refresh (issue #457)

This script is safe to run frequently (daily, from cron/systemd timer on
the Pi) — the same "at most daily, conditional" discipline
`geofabrik_pull.py` follows for the OSM side. Run with no region-selecting
flags and it walks `DEFAULT_REGIONS`, skipping any region whose
`covered_regions[name].extracted_at` is within `--ttl-days` (default
`DEFAULT_TTL_DAYS` = 30, distinct from Geofabrik's 45-day pin-age grace
window — Protomaps' own daily builds live only about a week, per
`find_latest_build_date`, so a region left stale for a month is many builds
behind, not one late cron tick) and re-probing/re-extracting any region
that isn't. `--regions wnc-corridor,nc` narrows the run to named keys;
`--force` bypasses the freshness check for every selected region.

Usage::

    ./protomaps_extract.py --root /srv/plotlines-mirror
    ./protomaps_extract.py --root /srv/plotlines-mirror --regions nc --force

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
from dataclasses import dataclass
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

# Kept in lockstep with core/plotlines_core/tiles/mirror_state.py's
# DEFAULT_BASEMAP_TTL_DAYS, the same duplication-with-a-comment pattern
# PLOTLINES_USER_AGENT above uses — this script cannot import core. Basemap
# tiles get their own cadence, distinct from Geofabrik's 45-day
# MAX_PIN_AGE_DAYS: Protomaps' own daily builds live only about a week
# (find_latest_build_date's measured retention window), so 30 days stale
# means many builds behind, not one late cron tick.
DEFAULT_TTL_DAYS = 30.0
ENV_TTL_DAYS = "PLOTLINES_TILES_TTL_DAYS"

# Defaults come from plotlines_core.tiles.mirror when it's importable (a dev
# machine with plotlines-core installed — this script needs that anyway for
# nothing beyond these constants, unlike geofabrik_pull.py which is a fully
# standalone scp-only deploy). Falls back to the literals those constants
# currently hold so --help (and DEFAULT_REGIONS below) still work without
# plotlines-core on PATH — the Pi deploy this script actually ships to.
try:
    from plotlines_core.tiles.mirror import (
        WNC_CORRIDOR_BBOX as _WNC_BBOX,
        WNC_CORRIDOR_BUILD_ID as _WNC_BUILD_ID,
        WNC_CORRIDOR_REGION_NAME as _WNC_REGION_NAME,
    )
except ImportError:
    _WNC_BBOX = (-83.6, 35.2, -81.0, 36.4)
    _WNC_BUILD_ID = "20250101-wnc"
    _WNC_REGION_NAME = "wnc-corridor"


@dataclass(frozen=True)
class RegionSpec:
    """One named basemap region this mirror can carry — bbox in, a
    published file out. `build_id` is a stable per-region path pin (like
    Geofabrik's `pinned_date`), not the upstream planet build date that
    `--build-date`/`find_latest_build_date` resolves per run; a refresh
    overwrites the same `basemap/protomaps/<build_id>/<filename>` in place.
    `primary=True` additionally mirrors this region's entry up to
    `state["basemap"]`'s top-level `build_id`/`source`/`extracted_at`, the
    flat shape `mirror_state.basemap_health()` and the client already read —
    today that is the WNC corridor alone, the only region
    `SidecarUpstreams.tilesUpstream`'s built-in default points at (#457)."""
    key: str
    label: str
    bbox: tuple[float, float, float, float]
    build_id: str
    filename: str
    primary: bool = False


#: The mirror's basemap coverage list — issue #457 generalizes this from the
#: single WNC-corridor region #394 shipped. Adding a region is adding an
#: entry here, not new machinery (`refresh_all` walks whatever is passed).
#: Bboxes are simple rectangles, not corridor-buffered polylines —
#: `deploy/elevation/priority_regions.py`'s buffering exists for a per-km2
#: OpenTopography request cap this script has no equivalent of, and pulling
#: in its `shapely`/`pyproj` dependency would cost every standalone deploy
#: of this script (see module docstring: `scp -r deploy/mirror` only).
DEFAULT_REGIONS: tuple[RegionSpec, ...] = (
    RegionSpec(
        key=_WNC_REGION_NAME, label="Western NC corridor",
        bbox=_WNC_BBOX, build_id=_WNC_BUILD_ID,
        filename="corridor.pmtiles", primary=True,
    ),
    RegionSpec(
        key="nc", label="North Carolina (full state)",
        bbox=(-84.32, 33.75, -75.40, 36.59), build_id="20250101-nc",
        filename="nc.pmtiles",
    ),
)


class BuildNotFound(RuntimeError):
    """No Protomaps daily build responded within the lookback window."""


class ExtractFailed(RuntimeError):
    """The `pmtiles extract` subprocess did not produce a usable archive."""


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def region_extracted_at(state: dict, region_name: str) -> datetime | None:
    """The last real pull timestamp recorded for `region_name` in a loaded
    `MIRROR_STATE.json`, or `None` if that region has never been published
    (a fresh mirror, or a region newly added to `DEFAULT_REGIONS`)."""
    covered = (state.get("basemap") or {}).get("covered_regions") or {}
    if not isinstance(covered, dict):
        return None  # a pre-#457 list-shaped basemap block — nothing to read
    return _parse_iso(covered.get(region_name, {}).get("extracted_at"))


def region_is_fresh(state: dict, region_name: str, *, ttl_days: float, now: datetime) -> bool:
    """Whether `region_name`'s extract is within `ttl_days` of `now` — the
    check `refresh_region` uses to skip a `pmtiles extract` subprocess
    entirely for a region that doesn't need one yet."""
    extracted_at = region_extracted_at(state, region_name)
    if extracted_at is None:
        return False
    age_days = (now - extracted_at).total_seconds() / 86400.0
    return age_days <= ttl_days


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
    filename: str = "corridor.pmtiles",
    primary: bool = True,
) -> Path:
    """Atomically moves `out_path` into the mirror tree under
    `basemap/protomaps/<build_id>/<filename>` and merges this region's entry
    into `MIRROR_STATE.json`'s `basemap.covered_regions` dict (issue #457
    generalized this from a single-region list — never touching
    `geofabrik`, the same non-clobbering contract `copy_basemap_standin.sh`
    and `build_tree.sh` already document for the file as a whole).
    `primary=True` (the default, matching pre-#457 single-region behaviour)
    also mirrors this region's `build_id`/`source`/`extracted_at` up to
    `state["basemap"]`'s own top level, the flat shape
    `mirror_state.basemap_health()` and the client already read."""
    state_path = root / "MIRROR_STATE.json"
    if not state_path.exists():
        raise SystemExit(
            f"error: {state_path} does not exist — run build_tree.sh "
            f"against {root} first."
        )

    dest_dir = root / "basemap" / "protomaps" / build_id
    dest = dest_dir / filename
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
    basemap = state.get("basemap") or {}
    covered = basemap.get("covered_regions")
    if not isinstance(covered, dict):
        covered = {}  # fresh mirror, or a pre-#457 list-shaped block — replaced below

    source = {
        "provider": "protomaps",
        "planet_build_date": planet_build_date,
        "source_url": source_url,
        "size_bytes": dest.stat().st_size,
    }
    extracted_at_iso = _iso(extracted_at)
    covered[region_name] = {
        "name": region_name,
        "bbox": list(bbox),
        "path": f"basemap/protomaps/{build_id}/{filename}",
        "build_id": build_id,
        "source": source,
        "extracted_at": extracted_at_iso,
    }
    basemap["covered_regions"] = covered
    if primary:
        basemap["build_id"] = build_id
        basemap["source"] = source
        basemap["extracted_at"] = extracted_at_iso
    state["basemap"] = basemap

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
    filename: str = "corridor.pmtiles",
    primary: bool = True,
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
        scratch_out = Path(scratch) / filename
        cli_output = run_pmtiles_extract(
            pmtiles_bin=resolved_bin, source_url=source_url, out_path=scratch_out,
            bbox=bbox, maxzoom=maxzoom, minzoom=minzoom,
        )
        return publish_basemap_extract(
            root=root, out_path=scratch_out, build_id=build_id,
            region_name=region_name, bbox=bbox, source_url=source_url,
            planet_build_date=resolved_date, extracted_at=now or _utcnow(),
            cli_output=cli_output, filename=filename, primary=primary,
        )


@dataclass
class RefreshResult:
    """One region's outcome from a `refresh_all` pass — a no-op skip (no
    `pmtiles extract` subprocess invoked, no state/file write) or a real
    `acquire()` publish."""
    region: RegionSpec
    skipped: bool
    reason: str | None
    dest: Path | None


def refresh_region(
    *,
    root: Path,
    spec: RegionSpec,
    ttl_days: float = DEFAULT_TTL_DAYS,
    force: bool = False,
    now: datetime | None = None,
    upstream_base_url: str = DEFAULT_UPSTREAM_BASE_URL,
    build_date: str | None = None,
    max_lookback_days: int = DEFAULT_MAX_LOOKBACK_DAYS,
    maxzoom: int = DEFAULT_MAXZOOM,
    minzoom: int | None = None,
    pmtiles_bin: str | None = None,
) -> RefreshResult:
    """Check-and-refresh for one region: reads the currently-published
    `MIRROR_STATE.json`, skips `spec` entirely (no probe, no subprocess) if
    its `extracted_at` is within `ttl_days` of `now`, otherwise re-probes
    for the latest live Protomaps build and re-extracts, overwriting
    `spec`'s file in place. This is what makes the acquisition repeatable
    rather than one-shot (issue #457) — safe to call daily from cron/systemd
    on the Pi, same discipline `geofabrik_pull.py` follows."""
    now = now or _utcnow()
    state_path = root / "MIRROR_STATE.json"
    if not state_path.exists():
        raise SystemExit(
            f"error: {state_path} does not exist — run build_tree.sh "
            f"against {root} first."
        )
    with open(state_path) as f:
        state = json.load(f)

    if not force and region_is_fresh(state, spec.key, ttl_days=ttl_days, now=now):
        LOG.info("skip %s: extracted within the last %.1f days", spec.key, ttl_days)
        return RefreshResult(region=spec, skipped=True, reason="fresh", dest=None)

    dest = acquire(
        root=root, bbox=spec.bbox, region_name=spec.key, build_id=spec.build_id,
        upstream_base_url=upstream_base_url, build_date=build_date,
        max_lookback_days=max_lookback_days, maxzoom=maxzoom, minzoom=minzoom,
        pmtiles_bin=pmtiles_bin, now=now, filename=spec.filename, primary=spec.primary,
    )
    return RefreshResult(region=spec, skipped=False, reason=None, dest=dest)


def refresh_all(
    *,
    root: Path,
    regions: tuple[RegionSpec, ...] = DEFAULT_REGIONS,
    ttl_days: float = DEFAULT_TTL_DAYS,
    force: bool = False,
    now: datetime | None = None,
    **kwargs,
) -> list[RefreshResult]:
    """`refresh_region` over every region in `regions`, in order. `**kwargs`
    (`upstream_base_url`, `build_date`, `max_lookback_days`, `maxzoom`,
    `minzoom`, `pmtiles_bin`) pass straight through — one set of upstream
    options for the whole run, matching how `--build-date`/`--maxzoom`/etc.
    already applied to the single region this script used to acquire."""
    now = now or _utcnow()
    return [
        refresh_region(root=root, spec=spec, ttl_days=ttl_days, force=force, now=now, **kwargs)
        for spec in regions
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Pull/refresh the mirror's Protomaps-basemap regions "
                     "from the live daily planet build (issue #394, #457).",
    )
    parser.add_argument("--root", type=Path, default=Path("/srv/plotlines-mirror"))
    parser.add_argument("--regions", default=None,
                         help="Comma-separated region keys to refresh "
                              "(default: every DEFAULT_REGIONS entry — "
                              f"{', '.join(r.key for r in DEFAULT_REGIONS)}).")
    parser.add_argument("--ttl-days", type=float,
                         default=float(os.environ.get(ENV_TTL_DAYS, DEFAULT_TTL_DAYS)),
                         help=f"Skip a region whose extract is younger than this "
                              f"(default: {DEFAULT_TTL_DAYS}, env {ENV_TTL_DAYS}).")
    parser.add_argument("--force", action="store_true",
                         help="Re-extract every selected region even if fresh.")
    parser.add_argument("--bbox", default=None,
                         help="west,south,east,north — extracts exactly this one "
                              "ad hoc region instead of walking --regions. Pairs "
                              "with --region-name/--build-id.")
    parser.add_argument("--region-name", default=None,
                         help="Required with --bbox: the covered_regions key "
                              "this ad hoc extract is published/tracked under.")
    parser.add_argument("--build-id", default=None,
                         help="With --bbox: directory this publishes under "
                              "(basemap/protomaps/<build-id>/<filename>). "
                              "Default: <region-name>.")
    parser.add_argument("--filename", default="corridor.pmtiles",
                         help="With --bbox: the published file's name.")
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
        if not args.region_name:
            parser.error("--bbox requires --region-name")
        west, south, east, north = (float(v) for v in args.bbox.split(","))
        specs: tuple[RegionSpec, ...] = (RegionSpec(
            key=args.region_name, label=args.region_name,
            bbox=(west, south, east, north),
            build_id=args.build_id or args.region_name,
            filename=args.filename, primary=True,
        ),)
    elif args.regions:
        wanted = {key.strip() for key in args.regions.split(",") if key.strip()}
        specs = tuple(r for r in DEFAULT_REGIONS if r.key in wanted)
        missing = wanted - {r.key for r in specs}
        if missing:
            parser.error(f"unknown region key(s): {', '.join(sorted(missing))}")
    else:
        specs = DEFAULT_REGIONS

    try:
        results = refresh_all(
            root=args.root, regions=specs, ttl_days=args.ttl_days, force=args.force,
            upstream_base_url=args.upstream_base_url, build_date=args.build_date,
            max_lookback_days=args.max_lookback_days, maxzoom=args.maxzoom,
            minzoom=args.minzoom, pmtiles_bin=args.pmtiles_bin,
        )
    except (BuildNotFound, ExtractFailed) as exc:
        LOG.error("%s", exc)
        return 1

    for result in results:
        if result.skipped:
            LOG.info("%s: skipped (%s)", result.region.key, result.reason)
        else:
            LOG.info("%s: refreshed -> %s", result.region.key, result.dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
