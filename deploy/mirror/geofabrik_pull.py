#!/usr/bin/env python3
"""Geofabrik pull client — issue #258 (Phase 1.4 of epic #264;
docs/Plotlines_OSM_Acquisition_Review.md §6.6, addendum finding P5,
checklist item 15).

§6.6: "Pull each region from Geofabrik **once**, verify against the
published `.md5`, and iterate against the Pi forever after... [and] we
should not repeat [the unexamined-cron mistake of #232] on the Geofabrik
side." This script is the specification the review names and does not
write out — cadence, conditional-first, identification, verify-before-
publish, and backoff are **rules in code**, not a bare cron entry, so
whoever runs it (a human bootstrapping a new region, or #260's monthly pin
bump) cannot accidentally hammer a volunteer-operated download server just
by invoking it more than once:

- **At most daily** (`--min-interval-hours`, default 24). A repeat run
  inside the window makes **no request at all** for that region — not even
  the conditional check — because Geofabrik's files update daily and
  anything faster only ever re-reads the same bytes.
- **Conditional first.** Outside the cadence window, only the small
  published `.md5` is fetched first. The `.osm.pbf` body is requested only
  when its digest differs from the one already recorded for the region.
- **Identified.** Every request carries `PLOTLINES_USER_AGENT` — the same
  contactable string issue #241 introduced for Overpass/Nominatim
  (`core/plotlines_core/osm_identity.py:osm_user_agent`), duplicated here
  rather than imported: this script is deployed standalone
  (`scp -r deploy/mirror`, see README.md) without the rest of the repo or
  plotlines-core's dependency tree, so it cannot import that module at
  runtime. `service/tests/test_geofabrik_pull.py` asserts the two strings
  match so they cannot silently drift apart.
- **Verify before publish.** The body downloads to a sibling temp file and
  is moved into place with `os.replace` (atomic on the same filesystem)
  only after its own MD5 matches the published one — a half-downloaded
  extract is never reachable at the immutable path a running mirror serves.
  A mismatch fails the pull and leaves whatever was previously at that path
  untouched.
- **Backs off on error** rather than retrying on the next tick: each
  consecutive failure doubles the wait before the *next* attempt is even
  considered (`_backoff_delay`), capped at a week, and every failure is
  written into `MIRROR_STATE.json` — feeding #260's staleness monitor
  rather than only a log line nobody is watching.

**Regions are named explicitly** (`--region north-america/us/north-carolina`,
repeatable), never discovered from Geofabrik's own `index-v1.json` — a
region's covering extent is a Plotlines decision, not something worth a
network round-trip to look up.

**`index-v1.json` itself is pulled separately, with `--pull-index`.** Issue
#259 found Geofabrik's own stated Open Data policy
(https://www.geofabrik.de/geofabrik/free.html): "any data we produce or
refine can be distributed in any way and through any channel" — a
redistribution grant for Geofabrik's *own* produced/refined data (which is
what the index is: their cut lines and metadata, not raw OSM data), distinct
from the ODbL statement that covers the `.osm.pbf` extracts. `pull_index`
applies the same etiquette as `pull_region` — at most daily, identified,
backs off on error — with an ETag-conditional GET standing in for the `.md5`
check regions get (Geofabrik publishes no digest for the index), and a
JSON-parses-cleanly check standing in for the `.md5` match before the
downloaded body is published to its immutable path.

Only this script's own `geofabrik.regions.<region>` / `geofabrik.index`
entries and `geofabrik.pinned_date` are written — `basemap` (owned by
`copy_basemap_standin.sh`, issue #257) and everything else in
`MIRROR_STATE.json` are left untouched, the same non-clobbering contract
`build_tree.sh` documents for the file as a whole.

Usage::

    ./geofabrik_pull.py --root /srv/plotlines-mirror \\
        --region north-america/us/north-carolina --pull-index

Run this by hand to bootstrap a new region, or from cron/#260's monthly pin
bump — the etiquette above holds regardless of how often it is invoked.

**`--precut-wnc-corridor` (issue #375)** clips the freshly-pulled full-state
extracts above down to the WNC corridor bbox and pins the (few-MB, rather
than few-hundred-MB) result instead, since `/clip`'s wall time scales with
the size of the pinned extract it has to scan, not the trip bbox, and
Geofabrik publishes no sub-state cuts for these states. See
`precut_region`'s docstring below. This one needs `plotlines-service`'s
`mirror-clip` extra (pyosmium) installed wherever it runs — deliberately
not a base dependency of this otherwise-standalone script, so a plain
`--region` pull with no `--precut-*` flag still needs nothing beyond the
standard library::

    ./geofabrik_pull.py --root /srv/plotlines-mirror \\
        --region north-america/us/north-carolina \\
        --region north-america/us/tennessee \\
        --precut-wnc-corridor

**Polite spacing (issue #530).** Every request to Geofabrik — `.md5`,
`.osm.pbf`, `.poly`, `index-v1.json` — starts at least
`--request-spacing-seconds` (default 120) after the previous one *ended*.
The rules above bound how often a region is touched. This bounds how
fast a multi-region run touches the server at all, which matters once
one invocation names a few dozen regions. A cadence- or backoff-skipped
region makes no request, so it waits for nothing.

**`--precut-priority-regions` (issue #530)** is the OSM counterpart to
`prewarm_basemap_priority_regions.py`: it pulls the Geofabrik regions under
the same QA/UAT priority areas the elevation proxy and the basemap were
pre-warmed for, and precuts them into a grid of non-overlapping cells. See
`priority_cells` and `precut_cells` below. Needs the repo venv (shapely/
pyproj for `priority_regions.py`, pyosmium for the clip)::

    .venv/bin/python deploy/mirror/geofabrik_pull.py --precut-priority-regions --dry-run
    .venv/bin/python deploy/mirror/geofabrik_pull.py --root /srv/plotlines-mirror \\
        --precut-priority-regions --pull-index
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import logging
import math
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

LOG = logging.getLogger("geofabrik_pull")

# Keep in lockstep with core/plotlines_core/osm_identity.py's
# osm_user_agent("mirror-geofabrik-pull") — see the module docstring above
# for why this is a duplicated literal rather than an import, and
# service/tests/test_geofabrik_pull.py for the drift assertion.
PLOTLINES_USER_AGENT = (
    "Plotlines/mirror-geofabrik-pull (+https://github.com/gnfrazier/plotlines)"
)

DEFAULT_BASE_URL = "https://download.geofabrik.de"
DEFAULT_MIN_INTERVAL = timedelta(hours=24)
DEFAULT_BACKOFF_BASE = timedelta(hours=1)
DEFAULT_BACKOFF_CAP = timedelta(days=7)
DEFAULT_REQUEST_SPACING = timedelta(minutes=2)

#: Geofabrik region paths look like `north-america/us/north-carolina`. This
#: guards against a typo'd or hostile `--region` value being used to build a
#: filesystem path (e.g. `..`, a leading `/`, or an unexpected scheme).
_REGION_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*(?:/[a-z0-9]+(?:-[a-z0-9]+)*)*$")


class InvalidRegion(ValueError):
    """A `--region` value isn't a well-formed Geofabrik region path."""


@dataclass
class PullResult:
    region: str
    action: str  # skipped_backoff | skipped_cadence | skipped_unchanged | pulled | failed
    detail: str = ""


class RequestThrottle:
    """Issue #530: holds every Geofabrik request at least `spacing` after the
    previous one finished. Wraps the request (`with throttle.spaced():`) so
    the gap is measured from when a download *ended*, not when it began, so
    a ten-minute `.osm.pbf` body still gets its full pause afterwards. One
    instance is shared across a whole `run()`, so the spacing holds between
    regions as well as between a region's own `.md5`/body/`.poly` calls.
    `spacing=0` (what `NO_SPACING` below uses) never sleeps."""

    def __init__(
        self,
        spacing: timedelta,
        *,
        sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._spacing_s = spacing.total_seconds()
        self._sleep = sleep
        self._clock = clock
        self._last_finished: float | None = None

    @contextlib.contextmanager
    def spaced(self):
        if self._last_finished is not None and self._spacing_s > 0:
            remaining = self._last_finished + self._spacing_s - self._clock()
            if remaining > 0:
                LOG.info("waiting %.0fs before the next Geofabrik request", remaining)
                self._sleep(remaining)
        try:
            yield
        finally:
            self._last_finished = self._clock()


NO_SPACING = RequestThrottle(timedelta(0))


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _backoff_delay(
    consecutive_failures: int,
    *,
    base: timedelta = DEFAULT_BACKOFF_BASE,
    cap: timedelta = DEFAULT_BACKOFF_CAP,
) -> timedelta:
    """Doubles per consecutive failure, capped — the wait before the *next*
    attempt is even considered, not a sleep held here."""
    if consecutive_failures <= 0:
        return timedelta(0)
    return min(base * (2 ** (consecutive_failures - 1)), cap)


def _validate_region(region: str) -> str:
    if not _REGION_RE.match(region):
        raise InvalidRegion(
            f"{region!r} doesn't look like a Geofabrik region path "
            f"(e.g. north-america/us/north-carolina)"
        )
    return region


def _md5_url(base_url: str, region: str) -> str:
    return f"{base_url.rstrip('/')}/{region}-latest.osm.pbf.md5"


def _pbf_url(base_url: str, region: str) -> str:
    return f"{base_url.rstrip('/')}/{region}-latest.osm.pbf"


def _poly_url(base_url: str, region: str) -> str:
    return f"{base_url.rstrip('/')}/{region}.poly"


def _index_url(base_url: str) -> str:
    return f"{base_url.rstrip('/')}/index-v1.json"


def _get(url: str, *, user_agent: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": user_agent})
    with urllib.request.urlopen(req) as resp:
        return resp.read()


class _NotModified(Exception):
    """Raised by `_get_conditional` on a 304 — the caller's cached copy is
    still current, distinguishing "unchanged" from every other failure."""


def _get_conditional(
    url: str, *, user_agent: str, etag: str | None
) -> tuple[bytes, str | None]:
    """GET with `If-None-Match: etag` when we have one. Returns (body,
    new_etag) on 200, or raises `_NotModified` on 304 — Geofabrik's stand-in
    for the `.md5` conditional check regions get, since it publishes no
    digest for `index-v1.json` itself."""
    headers = {"User-Agent": user_agent}
    if etag:
        headers["If-None-Match"] = etag
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.read(), resp.headers.get("ETag")
    except urllib.error.HTTPError as exc:
        if exc.code == 304:
            raise _NotModified from exc
        raise


def _get_streaming(url: str, dest: Path, *, user_agent: str) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": user_agent})
    with urllib.request.urlopen(req) as resp, open(dest, "wb") as f:
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            f.write(chunk)


def _parse_md5_file(body: bytes) -> str:
    """Geofabrik's `.md5` files are coreutils `md5sum` format:
    `<hex digest>  <filename>`. Returns the bare lowercase hex digest."""
    text = body.decode("ascii", errors="strict").strip()
    if not text:
        raise ValueError("empty .md5 file")
    digest = text.split()[0].lower()
    if len(digest) != 32 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError(f"unrecognised .md5 content: {text!r}")
    return digest


def _file_md5(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _published_md5(md5_path: Path) -> str | None:
    """The digest in a `.md5` sidecar `pull_region` wrote after verifying
    its body, or `None` if there is none or it doesn't parse."""
    try:
        return _parse_md5_file(md5_path.read_bytes())
    except (OSError, ValueError):
        return None


def _atomic_write(dest: Path, body: bytes) -> None:
    fd, tmp_name = tempfile.mkstemp(dir=dest.parent, prefix=".pull-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(body)
        os.replace(tmp_name, dest)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise


def _looks_like_valid_poly(body: bytes) -> bool:
    """A light structural check on an Osmosis `.poly` boundary body —
    deliberately standalone from `plotlines_service.mirror_clip.parse_poly`
    (the fuller parser that actually builds rings for the intersection
    test), the same "duplicate a small piece rather than import the rest
    of the repo" call this module's own `PLOTLINES_USER_AGENT` already
    makes, for the same reason: this script runs standalone on the Pi.
    Geofabrik publishes no digest for `.poly` files, the same gap
    `pull_index` already has for `index-v1.json`, so "this parses as the
    Osmosis polygon-filter shape" stands in for the `.md5` match as the
    verify-before-publish gate here (issue #402)."""
    try:
        text = body.decode("ascii")
    except UnicodeDecodeError:
        return False
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if len(lines) < 5 or lines[-1] != "END":
        return False
    coordinate_lines = 0
    for line in lines[2:-1]:
        if line == "END" or line.startswith("!"):
            continue
        parts = line.split()
        if len(parts) != 2:
            continue
        try:
            float(parts[0])
            float(parts[1])
        except ValueError:
            return False
        coordinate_lines += 1
    return coordinate_lines >= 3


def _fetch_poly(
    *, region: str, dest_pbf: Path, base_url: str, user_agent: str,
    throttle: RequestThrottle = NO_SPACING,
) -> None:
    """Best-effort: pulls the region's Osmosis `.poly` boundary alongside
    its already-published `.osm.pbf` (issue #402) —
    `mirror_clip.select_covering_extracts` uses it to narrow the
    rectangular header-box test with the extract's real shape, so a WNC-
    corridor bbox near the NC/TN line no longer forces scanning both
    states' full extracts when only one of them actually reaches there.
    Idempotent (skips once the file is on disk) and never fails the region
    pull as a whole: an extract with no `.poly` file is exactly the
    'unknown coverage, safe to include' case `select_covering_extracts`
    already falls back to for a missing header box, so a Geofabrik hiccup
    here costs precision, not correctness."""
    dest_poly = dest_pbf.with_name(dest_pbf.name[: -len(".osm.pbf")] + ".poly")
    if dest_poly.exists():
        return
    try:
        with throttle.spaced():
            body = _get(_poly_url(base_url, region), user_agent=user_agent)
    except (urllib.error.URLError, OSError) as exc:
        LOG.warning(
            "region %s: .poly fetch failed (%s) — over-selection at this "
            "region's borders stays unmitigated", region, exc,
        )
        return
    if not _looks_like_valid_poly(body):
        LOG.warning(
            "region %s: .poly body did not parse — over-selection at this "
            "region's borders stays unmitigated", region,
        )
        return
    _atomic_write(dest_poly, body)
    LOG.info("region %s: pulled boundary -> %s", region, dest_poly)


def _record_failure(
    region: str, entry: dict, when: datetime, reason: str
) -> PullResult:
    entry["consecutive_failures"] = entry.get("consecutive_failures", 0) + 1
    entry["last_failure"] = {"at": _iso(when), "reason": reason}
    LOG.error("region %s: %s (consecutive failures: %d)", region, reason,
              entry["consecutive_failures"])
    return PullResult(region, "failed", reason)


def pull_region(
    *,
    region: str,
    root: Path,
    pinned_date: str,
    state: dict,
    base_url: str = DEFAULT_BASE_URL,
    user_agent: str = PLOTLINES_USER_AGENT,
    min_interval: timedelta = DEFAULT_MIN_INTERVAL,
    now: Callable[[], datetime] = _utcnow,
    throttle: RequestThrottle = NO_SPACING,
) -> PullResult:
    """Pull one region, mutating only
    `state["geofabrik"]["regions"][region]` (and, on a real pull,
    `state["geofabrik"]["pinned_date"]`) in place. Every other key —
    `basemap` above all — is left exactly as found. The caller is
    responsible for persisting `state` to disk; this function does no I/O
    on `MIRROR_STATE.json` itself so it can be exercised without one."""
    region = _validate_region(region)
    regions = state.setdefault("geofabrik", {}).setdefault("regions", {})
    entry = regions.setdefault(region, {})
    current_time = now()

    consecutive_failures = entry.get("consecutive_failures", 0)
    last_failure = entry.get("last_failure")
    if consecutive_failures and last_failure:
        last_failure_at = _parse_iso(last_failure.get("at"))
        if last_failure_at is not None:
            resume_at = last_failure_at + _backoff_delay(consecutive_failures)
            if current_time < resume_at:
                LOG.info(
                    "region %s: backing off until %s (%d consecutive failures)",
                    region, _iso(resume_at), consecutive_failures,
                )
                return PullResult(region, "skipped_backoff",
                                   f"resumes at {_iso(resume_at)}")

    checked_at = _parse_iso(entry.get("checked_at"))
    if checked_at is not None and current_time - checked_at < min_interval:
        LOG.info(
            "region %s: checked %s ago, inside the %s cadence window — "
            "skipping, no request made", region, current_time - checked_at,
            min_interval,
        )
        return PullResult(region, "skipped_cadence",
                           f"last checked {_iso(checked_at)}")

    try:
        with throttle.spaced():
            md5_body = _get(_md5_url(base_url, region), user_agent=user_agent)
        remote_md5 = _parse_md5_file(md5_body)
    except (urllib.error.URLError, OSError, ValueError) as exc:
        # Deliberately not setting checked_at here: the 24h cadence gate is
        # for a *healthy, unchanged* upstream ("anything faster downloads
        # the same bytes"), and must not itself suppress a retry that the
        # (typically much shorter) backoff delay has already cleared — see
        # test_repeated_failures_back_off_instead_of_hammering.
        return _record_failure(region, entry, current_time,
                                f".md5 check failed: {exc}")
    entry["checked_at"] = _iso(current_time)

    dest = root / "osm" / "geofabrik" / pinned_date / f"{region}.osm.pbf"
    dest_md5 = dest.with_name(dest.name + ".md5")

    if dest.exists() and remote_md5 in (entry.get("md5"), _published_md5(dest_md5)):
        # The `.md5` sidecar counts too (issue #530): a precut removes its
        # sources from MIRROR_STATE.json but leaves their verified files on
        # disk, and re-registering one must not re-download hundreds of MB
        # this mirror already holds. The sidecar is only written after the
        # body's own digest matched, so it is as good as the state entry.
        LOG.info("region %s: unchanged (%s) — no body bytes transferred",
                  region, remote_md5)
        entry["md5"] = remote_md5
        entry["consecutive_failures"] = 0
        entry["last_failure"] = None
        _fetch_poly(region=region, dest_pbf=dest, base_url=base_url,
                    user_agent=user_agent, throttle=throttle)
        return PullResult(region, "skipped_unchanged", remote_md5)

    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=dest.parent, prefix=".pull-",
                                     suffix=".osm.pbf.tmp")
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        with throttle.spaced():
            _get_streaming(_pbf_url(base_url, region), tmp_path,
                            user_agent=user_agent)
    except (urllib.error.URLError, OSError) as exc:
        tmp_path.unlink(missing_ok=True)
        return _record_failure(region, entry, current_time,
                                f"download failed: {exc}")

    local_md5 = _file_md5(tmp_path)
    if local_md5 != remote_md5:
        tmp_path.unlink(missing_ok=True)
        return _record_failure(
            region, entry, current_time,
            f".md5 mismatch: published {remote_md5}, downloaded {local_md5}",
        )

    # Verified — publish. os.replace is atomic on the same filesystem, so
    # the immutable path never briefly shows a half-downloaded extract.
    os.replace(tmp_path, dest)
    _atomic_write(dest_md5, f"{remote_md5}  {region}-latest.osm.pbf\n".encode())

    entry["md5"] = remote_md5
    entry["pulled_at"] = _iso(current_time)
    entry["consecutive_failures"] = 0
    entry["last_failure"] = None
    state["geofabrik"]["pinned_date"] = pinned_date
    LOG.info("region %s: pulled %s -> %s", region, remote_md5, dest)
    _fetch_poly(region=region, dest_pbf=dest, base_url=base_url,
                user_agent=user_agent, throttle=throttle)
    return PullResult(region, "pulled", remote_md5)


def pull_index(
    *,
    root: Path,
    pinned_date: str,
    state: dict,
    base_url: str = DEFAULT_BASE_URL,
    user_agent: str = PLOTLINES_USER_AGENT,
    min_interval: timedelta = DEFAULT_MIN_INTERVAL,
    now: Callable[[], datetime] = _utcnow,
    throttle: RequestThrottle = NO_SPACING,
) -> PullResult:
    """Pull Geofabrik's `index-v1.json`, mutating only
    `state["geofabrik"]["index"]` — see issue #259 for why this is mirrored
    at all (Geofabrik's own stated policy for data it produces/refines,
    distinct from the ODbL grant that covers the `.osm.pbf` extracts) and
    `pull_region`'s docstring/tests for the shared etiquette. The same rules
    apply here with two substitutions forced by what Geofabrik actually
    publishes for this file: an ETag-conditional GET stands in for the
    `.md5` cadence check, and "the body parses as JSON" stands in for the
    `.md5` match as the verify-before-publish gate."""
    entry = state.setdefault("geofabrik", {}).setdefault("index", {})
    current_time = now()

    consecutive_failures = entry.get("consecutive_failures", 0)
    last_failure = entry.get("last_failure")
    if consecutive_failures and last_failure:
        last_failure_at = _parse_iso(last_failure.get("at"))
        if last_failure_at is not None:
            resume_at = last_failure_at + _backoff_delay(consecutive_failures)
            if current_time < resume_at:
                LOG.info(
                    "index: backing off until %s (%d consecutive failures)",
                    _iso(resume_at), consecutive_failures,
                )
                return PullResult("index-v1.json", "skipped_backoff",
                                   f"resumes at {_iso(resume_at)}")

    checked_at = _parse_iso(entry.get("checked_at"))
    if checked_at is not None and current_time - checked_at < min_interval:
        LOG.info(
            "index: checked %s ago, inside the %s cadence window — "
            "skipping, no request made", current_time - checked_at,
            min_interval,
        )
        return PullResult("index-v1.json", "skipped_cadence",
                           f"last checked {_iso(checked_at)}")

    dest = root / "osm" / "geofabrik" / pinned_date / "index-v1.json"

    try:
        with throttle.spaced():
            body, new_etag = _get_conditional(
                _index_url(base_url), user_agent=user_agent, etag=entry.get("etag"),
            )
    except _NotModified:
        LOG.info("index: unchanged (etag %s) — no body bytes transferred",
                  entry.get("etag"))
        entry["checked_at"] = _iso(current_time)
        entry["consecutive_failures"] = 0
        entry["last_failure"] = None
        return PullResult("index-v1.json", "skipped_unchanged", entry.get("etag", ""))
    except (urllib.error.URLError, OSError) as exc:
        return _record_failure("index-v1.json", entry, current_time,
                                f"fetch failed: {exc}")
    entry["checked_at"] = _iso(current_time)

    try:
        json.loads(body)
    except ValueError as exc:
        return _record_failure("index-v1.json", entry, current_time,
                                f"response is not valid JSON: {exc}")

    dest.parent.mkdir(parents=True, exist_ok=True)
    _atomic_write(dest, body)

    entry["etag"] = new_etag
    entry["pulled_at"] = _iso(current_time)
    entry["consecutive_failures"] = 0
    entry["last_failure"] = None
    LOG.info("index: pulled (etag %s) -> %s", new_etag, dest)
    return PullResult("index-v1.json", "pulled", new_etag or "")


def precut_region(
    *,
    root: Path,
    pinned_date: str,
    state: dict,
    dest_region: str,
    source_regions: list[str],
    bbox: tuple[float, float, float, float],
    replace_sources: bool = True,
) -> PullResult:
    """Issue #375: `/clip`'s wall time is O(the pinned region extract), not
    O(the trip bbox) — every request scans the *whole* source extract
    regardless of how small the requested bbox is, because a PBF stores
    data in id order, not spatial order (measured on the live Pi: 627-640s
    against a 60s outer band). Geofabrik publishes no sub-state extracts
    for the states this mirror pins (`north-carolina`, `tennessee` both
    say "No sub regions are defined for this region"), so the "smaller
    pinned extracts" lever the issue names has to be produced locally
    rather than downloaded.

    This clips whichever already-pulled `source_regions` are on this
    mirror down to `bbox` **once**, at pin time, and pins the (much
    smaller — a few MB rather than a few hundred) result as `dest_region`
    instead. `/clip` itself is unchanged: it still scans whatever extracts
    `MIRROR_STATE.json` names, so the entire wall-time win comes from what
    gets pinned, not from any request-path logic. `replace_sources=True`
    (the default) removes `source_regions` from `MIRROR_STATE.json` so a
    request for `bbox` scans only the small precut extract rather than
    both it and the sources it was cut from — appropriate exactly because
    WNC is the only region this mirror actually serves today (the
    basemap's own `WNC_CORRIDOR_*` stand-in already scopes to it, not a
    full-state build). The source `.osm.pbf` files themselves are left on
    disk either way; only their `MIRROR_STATE.json` registration changes.

    Reuses `plotlines_service.mirror_clip.clip_bbox` — the exact algorithm
    `/clip` runs per request — so the precut result is what a live request
    against the un-cut sources would already have produced, computed once
    instead of on every request. Requires `plotlines-service` installed
    with its `mirror-clip` extra (pyosmium); this is not something the Pi
    itself needs to run, so import it lazily rather than making a normal
    `--region` pull depend on it.
    """
    try:
        from plotlines_service.mirror_clip import clip_bbox
    except ImportError as exc:
        raise SystemExit(
            "error: --precut-wnc-corridor requires plotlines-service "
            "installed with its mirror-clip extra (pyosmium) — run this on "
            "a machine that has that installed (`uv sync --extra "
            "mirror-clip` in service/), not necessarily the Pi itself"
        ) from exc

    regions = state.setdefault("geofabrik", {}).setdefault("regions", {})
    missing = [r for r in source_regions if r not in regions]
    if missing:
        raise SystemExit(
            f"error: --precut source region(s) not pulled yet: {missing} "
            f"— pull them with --region first (in this invocation or a "
            f"prior one)"
        )

    dest_path = root / "osm" / "geofabrik" / pinned_date / f"{dest_region}.osm.pbf"
    LOG.info("precut %s: clipping %s to bbox=%s", dest_region, source_regions, bbox)
    result = clip_bbox(bbox, root=root, dest=dest_path, tmp_dir=dest_path.parent)

    if set(result.source_regions) != set(source_regions):
        raise SystemExit(
            f"error: precut actually drew from {sorted(result.source_regions)}, "
            f"not the declared --precut-source {sorted(source_regions)} — "
            f"refusing to guess which MIRROR_STATE.json entries to replace"
        )

    digest = _file_md5(dest_path)
    precut_time = _utcnow()
    regions[dest_region] = {
        "precut_from": list(source_regions),
        "precut_bbox": list(bbox),
        "pulled_at": _iso(precut_time),
        "checked_at": _iso(precut_time),
        "md5": digest,
    }
    if replace_sources:
        for region in source_regions:
            regions.pop(region, None)
    LOG.info("precut %s: pulled %s -> %s (replace_sources=%s)",
              dest_region, digest, dest_path, replace_sources)
    return PullResult(dest_region, "precut", digest)


# --------------------------------------------------------------------------
# Priority-region precut (issue #530)
# --------------------------------------------------------------------------

#: The Geofabrik regions under each `deploy/elevation/priority_regions.py`
#: area, keyed by its `region_key`, plus the WNC corridor. Named by hand
#: rather than discovered at run time, the same rule `--region` follows: a
#: region's covering extent is a Plotlines decision. Derived once
#: (2026-09-24) by intersecting each area's candidate bboxes with the
#: region polygons in Geofabrik's `index-v1.json`, leaf regions only, so
#: British Columbia is its admin regions and California is norcal/socal,
#: never the larger parent file. Re-derive it when an area in
#: `priority_regions.py` moves. `test_geofabrik_priority_precut.py` fails if
#: an area appears there without an entry here.
PRIORITY_REGION_SOURCES: dict[str, tuple[str, ...]] = {
    "wnc-corridor": (
        "north-america/us/north-carolina",
        "north-america/us/south-carolina",
        "north-america/us/tennessee",
    ),
    "nc": (
        "north-america/us/georgia",
        "north-america/us/kentucky",
        "north-america/us/north-carolina",
        "north-america/us/south-carolina",
        "north-america/us/tennessee",
        "north-america/us/virginia",
    ),
    "brp": (
        "north-america/us/district-of-columbia",
        "north-america/us/georgia",
        "north-america/us/indiana",
        "north-america/us/kentucky",
        "north-america/us/maryland",
        "north-america/us/north-carolina",
        "north-america/us/ohio",
        "north-america/us/south-carolina",
        "north-america/us/tennessee",
        "north-america/us/virginia",
        "north-america/us/west-virginia",
    ),
    "skyline": (
        "north-america/us/maryland",
        "north-america/us/virginia",
        "north-america/us/west-virginia",
    ),
    "bwcaw": (
        "north-america/canada/ontario",
        "north-america/us/minnesota",
    ),
    "yellowstone": (
        "north-america/us/idaho",
        "north-america/us/montana",
        "north-america/us/wyoming",
    ),
    "champlain": (
        "north-america/canada/ontario",
        "north-america/canada/quebec",
        "north-america/us/new-hampshire",
        "north-america/us/new-york",
        "north-america/us/vermont",
    ),
    "pct": (
        "north-america/canada/british-columbia/island-admreg",
        "north-america/canada/british-columbia/okanagan-admreg",
        "north-america/canada/british-columbia/southcoast-admreg",
        "north-america/mexico",
        "north-america/us/california/norcal",
        "north-america/us/california/socal",
        "north-america/us/nevada",
        "north-america/us/oregon",
        "north-america/us/washington",
    ),
}

#: The WNC corridor, always part of the priority precut, the same way
#: `prewarm_basemap_priority_regions.py` always includes it. Duplicates
#: `plotlines_core.tiles.mirror.WNC_CORRIDOR_BBOX` because this script runs
#: without `plotlines_core`. `test_geofabrik_priority_precut.py` pins the
#: two together.
WNC_CORRIDOR_KEY = "wnc-corridor"
WNC_CORRIDOR_BBOX = (-83.6, 35.2, -81.0, 36.4)

#: Grid cell size. A cell is pinned as its own extract, and `/clip` scans
#: every pinned extract whose header box a trip bbox touches, whole. So the
#: cell size sets the per-request cost the way the corridor's size did.
#: 2° is about the corridor's 2.6° x 1.2°, which measured ~102 s on the Pi
#: (#402).
DEFAULT_PRIORITY_CELL_DEGREES = 2.0

BBox = tuple[float, float, float, float]


@dataclass(frozen=True)
class PrecutCell:
    name: str
    bbox: BBox
    source_regions: tuple[str, ...]


def _cell_name(west: float, south: float) -> str:
    ew = "w" if west < 0 else "e"
    ns = "s" if south < 0 else "n"
    return f"priority-{ew}{abs(round(west)):03d}-{ns}{abs(round(south)):02d}"


def priority_cells(
    areas: list[tuple[str, BBox]],
    *,
    sources: dict[str, tuple[str, ...]] = PRIORITY_REGION_SOURCES,
    cell_degrees: float = DEFAULT_PRIORITY_CELL_DEGREES,
) -> list[PrecutCell]:
    """Cut `areas` (`(region_key, bbox)` pairs) into a fixed, degree-aligned
    grid and return one cell per grid square any area reaches.

    Why a grid rather than one precut per area: the areas overlap heavily
    (the NC bbox, both BRP tiles, Skyline and the WNC corridor all cover
    WNC). `/clip` would scan every overlapping precut for a WNC trip,
    whole, and its cost is O(pinned extract). Grid cells never overlap, so
    a trip bbox touches only the one to four small cells around it.

    Each cell's bbox is the grid square clamped to the envelope of the
    area pieces inside it. The pinned cell then claims no coverage beyond
    the areas, so a trip outside them still gets an honest
    `NoMirrorCoverage` instead of a partial clip. Its sources are every
    region listed for the areas that reach it."""
    unknown = sorted({key for key, _ in areas} - set(sources))
    if unknown:
        raise ValueError(
            f"no Geofabrik sources listed for area(s) {unknown} — add them to "
            f"PRIORITY_REGION_SOURCES"
        )
    envelopes: dict[tuple[int, int], list[float]] = {}
    keys: dict[tuple[int, int], set[str]] = {}
    for key, (west, south, east, north) in areas:
        for i in range(math.floor(west / cell_degrees), math.ceil(east / cell_degrees)):
            for j in range(math.floor(south / cell_degrees), math.ceil(north / cell_degrees)):
                piece = (
                    max(west, i * cell_degrees), max(south, j * cell_degrees),
                    min(east, (i + 1) * cell_degrees), min(north, (j + 1) * cell_degrees),
                )
                if piece[0] >= piece[2] or piece[1] >= piece[3]:
                    continue  # the area only touches this square's edge
                env = envelopes.get((i, j))
                if env is None:
                    envelopes[(i, j)] = list(piece)
                else:
                    envelopes[(i, j)] = [min(env[0], piece[0]), min(env[1], piece[1]),
                                         max(env[2], piece[2]), max(env[3], piece[3])]
                keys.setdefault((i, j), set()).add(key)
    return [
        PrecutCell(
            name=_cell_name(i * cell_degrees, j * cell_degrees),
            bbox=tuple(envelopes[(i, j)]),
            source_regions=tuple(sorted(set().union(*(sources[k] for k in keys[(i, j)])))),
        )
        for i, j in sorted(envelopes)
    ]


def _link_scratch_mirror(scratch: Path, *, root: Path, pinned_date: str,
                         source_regions: tuple[str, ...]) -> None:
    """A throwaway mirror tree naming only `source_regions`, symlinked to
    the real files, so `clip_bbox` reads exactly this cell's sources. Run
    against the live root, it would also pick up the WNC corridor and every
    cell already pinned."""
    real_dir = root / "osm" / "geofabrik" / pinned_date
    scratch_dir = scratch / "osm" / "geofabrik" / pinned_date
    for region in source_regions:
        for suffix in (".osm.pbf", ".poly"):
            target = real_dir / f"{region}{suffix}"
            if not target.exists():
                continue  # no .poly: clip_bbox treats that as unknown coverage
            link = scratch_dir / f"{region}{suffix}"
            link.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(target, link)
    (scratch / "MIRROR_STATE.json").write_text(json.dumps({
        "geofabrik": {"pinned_date": pinned_date,
                      "regions": {region: {} for region in source_regions}},
    }))


def precut_cells(
    *,
    root: Path,
    pinned_date: str,
    state: dict,
    cells: list[PrecutCell],
    replace_sources: bool = True,
    supersedes: tuple[str, ...] = (),
    checkpoint: Callable[[], None] = lambda: None,
) -> list[PullResult]:
    """Issue #530: pin one precut extract per `priority_cells` cell, each
    clipped by `mirror_clip.clip_bbox` from only that cell's sources. This
    is `precut_region`'s mechanism (#375) applied per cell. It drops that
    function's "drew from exactly the declared sources" check on purpose:
    a cell lists every region of the areas that reach it, and
    `clip_bbox`'s header-box/`.poly` selection rightly skips the ones that
    don't reach the cell itself.

    Each cell is clipped to a temp file and moved into place, so a re-run
    never rewrites a file `/clip` might be reading. A cell that clips to
    nothing (open water, say) is skipped and any earlier entry for it is
    removed. After every cell, `replace_sources` unregisters the full-region
    sources and `supersedes` unregisters extracts the cells now cover (the
    WNC corridor). Files stay on disk either way. `checkpoint` runs after
    each cell so a crash hours into a run keeps the cells already done.

    Memory: `clip_bbox` stamps each output's header box by reading the
    whole output in memory. A 2° cell over a dense metro is several times
    the corridor's 97 MB. If a run gets OOM-killed, rerun with a smaller
    `--precut-cell-degrees`, or run it on a larger machine and copy the
    pin directory over."""
    try:
        from plotlines_service.mirror_clip import NoMirrorCoverage, clip_bbox
    except ImportError as exc:
        raise SystemExit(
            "error: --precut-priority-regions requires plotlines-service "
            "installed with its mirror-clip extra (pyosmium) — run it from "
            "the repo venv (`uv sync --extra mirror-clip` in service/)"
        ) from exc

    regions = state.setdefault("geofabrik", {}).setdefault("regions", {})
    needed = sorted({r for cell in cells for r in cell.source_regions})
    missing = [r for r in needed if r not in regions]
    if missing:
        raise SystemExit(
            f"error: priority precut source region(s) not pulled yet: {missing}"
        )

    pin_dir = root / "osm" / "geofabrik" / pinned_date
    results = []
    for n, cell in enumerate(cells, start=1):
        LOG.info("precut %s (%d/%d): clipping %s to bbox=%s",
                 cell.name, n, len(cells), list(cell.source_regions), cell.bbox)
        dest = pin_dir / f"{cell.name}.osm.pbf"
        with tempfile.TemporaryDirectory(dir=pin_dir, prefix=".precut-") as scratch:
            scratch_root = Path(scratch)
            _link_scratch_mirror(scratch_root, root=root, pinned_date=pinned_date,
                                 source_regions=cell.source_regions)
            staged = scratch_root / "cell.osm.pbf"
            try:
                result = clip_bbox(cell.bbox, root=scratch_root, dest=staged,
                                   tmp_dir=scratch_root)
            except NoMirrorCoverage as exc:
                LOG.info("precut %s: nothing to pin (%s)", cell.name, exc)
                regions.pop(cell.name, None)
                results.append(PullResult(cell.name, "skipped_empty", str(exc)))
                checkpoint()
                continue
            os.replace(staged, dest)
        precut_time = _utcnow()
        regions[cell.name] = {
            "precut_from": list(result.source_regions),
            "precut_bbox": list(cell.bbox),
            "pulled_at": _iso(precut_time),
            "checked_at": _iso(precut_time),
            "md5": _file_md5(dest),
        }
        results.append(PullResult(cell.name, "precut", regions[cell.name]["md5"]))
        checkpoint()

    if replace_sources:
        for region in needed:
            regions.pop(region, None)
    for region in supersedes:
        regions.pop(region, None)
    LOG.info("precut: pinned %d cell(s); replace_sources=%s, superseded %s",
             sum(r.action == "precut" for r in results), replace_sources,
             list(supersedes))
    return results


def load_state(state_path: Path) -> dict:
    with open(state_path) as f:
        return json.load(f)


def save_state(state_path: Path, state: dict) -> None:
    _atomic_write(state_path, (json.dumps(state, indent=2) + "\n").encode())


def run(
    regions: list[str],
    *,
    root: Path,
    pinned_date: str,
    base_url: str = DEFAULT_BASE_URL,
    min_interval: timedelta = DEFAULT_MIN_INTERVAL,
    now: Callable[[], datetime] = _utcnow,
    pull_index_too: bool = False,
    precut: dict | None = None,
    priority_precut: dict | None = None,
    request_spacing: timedelta = DEFAULT_REQUEST_SPACING,
    sleep: Callable[[float], None] = time.sleep,
) -> list[PullResult]:
    """`precut`, when given, is
    `{"dest_region", "bbox", "replace_sources"}` (issue #375).
    `priority_precut` is `{"cells", "replace_sources", "supersedes"}`
    (issue #530, see `precut_cells`). Either is applied only after every
    region pull succeeds, never against a partial pull. `request_spacing`
    is the gap held between Geofabrik requests for the whole run."""
    state_path = root / "MIRROR_STATE.json"
    if not state_path.exists():
        raise SystemExit(
            f"error: {state_path} does not exist — run build_tree.sh "
            f"against {root} first."
        )
    state = load_state(state_path)
    throttle = RequestThrottle(request_spacing, sleep=sleep)
    results = []
    for region in regions:
        result = pull_region(region=region, root=root, pinned_date=pinned_date,
                              state=state, base_url=base_url,
                              min_interval=min_interval, now=now,
                              throttle=throttle)
        results.append(result)
        # Checkpoint after every region so a mid-run crash on region N
        # doesn't lose the state recorded for regions before it.
        save_state(state_path, state)
    if pull_index_too:
        results.append(pull_index(root=root, pinned_date=pinned_date, state=state,
                                   base_url=base_url, min_interval=min_interval,
                                   now=now, throttle=throttle))
        save_state(state_path, state)
    pulls_ok = not any(r.action == "failed" for r in results)
    if precut is not None and pulls_ok:
        results.append(precut_region(
            root=root, pinned_date=pinned_date, state=state,
            dest_region=precut["dest_region"], source_regions=regions,
            bbox=precut["bbox"], replace_sources=precut["replace_sources"],
        ))
        save_state(state_path, state)
    if priority_precut is not None and pulls_ok:
        results.extend(precut_cells(
            root=root, pinned_date=pinned_date, state=state,
            cells=priority_precut["cells"],
            replace_sources=priority_precut["replace_sources"],
            supersedes=priority_precut["supersedes"],
            checkpoint=lambda: save_state(state_path, state),
        ))
        save_state(state_path, state)
    return results


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Pull Geofabrik region extracts into the Plotlines "
                     "mirror tree — at most daily, conditional, identified, "
                     "backs off on error (issue #258).",
    )
    parser.add_argument("--root", type=Path, default=Path("/srv/plotlines-mirror"))
    parser.add_argument(
        "--region", action="append", default=[], dest="regions",
        help="Geofabrik region path, e.g. north-america/us/north-carolina "
             "(repeatable). Required unless --precut-priority-regions "
             "names the regions itself.",
    )
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument(
        "--pinned-date", default=None,
        help="Dated directory this pull writes into, e.g. 2026-09-01 "
             "(default: today, UTC). Keep this stable across routine runs; "
             "it only changes on a deliberate pin bump (#260).",
    )
    parser.add_argument("--min-interval-hours", type=float,
                         default=DEFAULT_MIN_INTERVAL.total_seconds() / 3600)
    parser.add_argument(
        "--pull-index", action="store_true", dest="pull_index_too",
        help="Also pull Geofabrik's index-v1.json (issue #259) — off by "
             "default; opt in explicitly rather than fetching a 3-4 MB file "
             "nobody asked for on every region-bootstrap invocation.",
    )
    parser.add_argument(
        "--precut-wnc-corridor", action="store_true",
        help="Issue #375: after the --region pulls above succeed, clip "
             "them down to the WNC corridor bbox (plotlines_core.tiles."
             "mirror.WNC_CORRIDOR_BBOX — the same corridor the basemap "
             "stand-in already serves) and pin the smaller result, since "
             "/clip's wall time scales with the pinned extract's size, "
             "not the trip bbox's, and Geofabrik publishes no sub-state "
             "extracts for these regions. Requires plotlines-service's "
             "mirror-clip extra (pyosmium) installed on this machine — "
             "not necessarily the Pi. Removes the --region sources from "
             "MIRROR_STATE.json by default; pass --precut-keep-sources to "
             "keep both (their .osm.pbf files stay on disk either way).",
    )
    parser.add_argument(
        "--precut-dest-region", default=None,
        help="Region name the precut result is pinned under (default: "
             "plotlines_core.tiles.mirror.WNC_CORRIDOR_REGION_NAME).",
    )
    parser.add_argument(
        "--precut-keep-sources", action="store_true",
        help="With --precut-wnc-corridor, keep the --region sources "
             "registered in MIRROR_STATE.json alongside the precut result "
             "instead of replacing them — accepts paying for a full scan "
             "of each source on every request that also matches the "
             "precut's header box (see #375's 'not fixed here' note).",
    )
    parser.add_argument(
        "--precut-priority-regions", action="store_true",
        help="Issue #530: pull the Geofabrik regions under the elevation/"
             "basemap priority areas (deploy/elevation/priority_regions.py, "
             "plus the WNC corridor) and pin one non-overlapping precut per "
             "grid cell. Replaces the full-region sources and the "
             "wnc-corridor precut in MIRROR_STATE.json unless "
             "--precut-keep-sources. Defaults --pinned-date to the mirror's "
             "current pin. Needs the repo venv (shapely/pyproj, pyosmium).",
    )
    parser.add_argument(
        "--priority-regions", default=None,
        help="With --precut-priority-regions: comma-separated "
             "priority_regions region_key values (default: all). The WNC "
             "corridor is always included.",
    )
    parser.add_argument(
        "--precut-cell-degrees", type=float,
        default=DEFAULT_PRIORITY_CELL_DEGREES,
        help="Grid cell size for --precut-priority-regions (default: "
             "%(default)s). Smaller cells mean smaller pinned extracts, "
             "cheaper /clip requests and less memory per cut.",
    )
    parser.add_argument(
        "--request-spacing-seconds", type=float,
        default=DEFAULT_REQUEST_SPACING.total_seconds(),
        help="Minimum gap between the end of one Geofabrik request and the "
             "start of the next (default: %(default)s).",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="With --precut-priority-regions: print the cells and the "
             "regions it would pull, then exit. No network, no writes.",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    if args.precut_priority_regions:
        if args.regions or args.precut_wnc_corridor:
            parser.error("--precut-priority-regions names its own regions and "
                         "covers the WNC corridor; drop --region and "
                         "--precut-wnc-corridor")
        try:
            cells = _selected_priority_cells(args.priority_regions,
                                             args.precut_cell_degrees)
        except ValueError as exc:
            parser.error(str(exc))
        regions = sorted({r for cell in cells for r in cell.source_regions})
        if args.dry_run:
            _print_priority_plan(cells, regions)
            return 0
        pinned_date = args.pinned_date or _current_pin(args.root)
        results = run(
            regions, root=args.root, pinned_date=pinned_date,
            base_url=args.base_url,
            min_interval=timedelta(hours=args.min_interval_hours),
            pull_index_too=args.pull_index_too,
            priority_precut={
                "cells": cells,
                "replace_sources": not args.precut_keep_sources,
                "supersedes": () if args.precut_keep_sources else (WNC_CORRIDOR_KEY,),
            },
            request_spacing=timedelta(seconds=args.request_spacing_seconds),
        )
        return 1 if any(r.action == "failed" for r in results) else 0

    if not args.regions:
        parser.error("--region is required (or pass --precut-priority-regions)")

    precut = None
    if args.precut_wnc_corridor:
        try:
            from plotlines_core.tiles.mirror import (
                WNC_CORRIDOR_BBOX,
                WNC_CORRIDOR_REGION_NAME,
            )
        except ImportError as exc:
            raise SystemExit(
                "error: --precut-wnc-corridor requires plotlines-core "
                "installed (it ships with plotlines-service, which also "
                "needs its mirror-clip extra for this flag) — run this on "
                "a machine that has that, not necessarily the Pi itself"
            ) from exc
        precut = {
            "dest_region": args.precut_dest_region or WNC_CORRIDOR_REGION_NAME,
            "bbox": WNC_CORRIDOR_BBOX,
            "replace_sources": not args.precut_keep_sources,
        }

    pinned_date = args.pinned_date or _utcnow().strftime("%Y-%m-%d")
    results = run(
        args.regions, root=args.root, pinned_date=pinned_date,
        base_url=args.base_url,
        min_interval=timedelta(hours=args.min_interval_hours),
        pull_index_too=args.pull_index_too,
        precut=precut,
        request_spacing=timedelta(seconds=args.request_spacing_seconds),
    )
    failed = [r for r in results if r.action == "failed"]
    return 1 if failed else 0


def _selected_priority_cells(keys_arg: str | None, cell_degrees: float) -> list[PrecutCell]:
    """The priority areas (the same `build_priority_candidates()` the
    elevation and basemap prewarms read, so the three can't drift), narrowed
    by `--priority-regions`, plus the WNC corridor, cut into cells."""
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "elevation"))
    try:
        from priority_regions import build_priority_candidates
    except ImportError as exc:
        raise SystemExit(
            "error: --precut-priority-regions needs shapely and pyproj for "
            "deploy/elevation/priority_regions.py — run it from the repo venv"
        ) from exc
    candidates = build_priority_candidates()
    if keys_arg:
        wanted = {k.strip() for k in keys_arg.split(",") if k.strip()}
        unknown = wanted - {c.region_key for c in candidates}
        if unknown:
            raise ValueError(f"unknown priority region key(s): {', '.join(sorted(unknown))}")
        candidates = [c for c in candidates if c.region_key in wanted]
    areas = [(WNC_CORRIDOR_KEY, WNC_CORRIDOR_BBOX)]
    areas += [(c.region_key, c.bbox) for c in candidates]
    return priority_cells(areas, cell_degrees=cell_degrees)


def _current_pin(root: Path) -> str:
    """The mirror's existing `geofabrik.pinned_date`, so new regions land in
    the same pin directory as what is already pinned. `/clip` reads one pin
    directory, so pulling into a new one would orphan the corridor. Today's
    date only when the mirror has no pin yet."""
    state_path = root / "MIRROR_STATE.json"
    try:
        pin = (load_state(state_path).get("geofabrik") or {}).get("pinned_date")
    except (OSError, ValueError):
        pin = None
    return pin or _utcnow().strftime("%Y-%m-%d")


def _print_priority_plan(cells: list[PrecutCell], regions: list[str]) -> None:
    print(f"{'cell':<20} {'bbox':<40} sources")
    for cell in cells:
        bbox = ", ".join(f"{v:.2f}" for v in cell.bbox)
        names = ", ".join(r.rsplit("/", 1)[-1] for r in cell.source_regions)
        print(f"{cell.name:<20} ({bbox}){'':<4} {names}")
    print(f"\n{len(cells)} cells; {len(regions)} Geofabrik regions to pull:")
    for region in regions:
        print(f"  {region}")


if __name__ == "__main__":
    raise SystemExit(main())
