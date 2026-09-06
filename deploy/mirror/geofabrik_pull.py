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
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import tempfile
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


def _atomic_write(dest: Path, body: bytes) -> None:
    fd, tmp_name = tempfile.mkstemp(dir=dest.parent, prefix=".pull-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(body)
        os.replace(tmp_name, dest)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise


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

    if remote_md5 == entry.get("md5") and dest.exists():
        LOG.info("region %s: unchanged (%s) — no body bytes transferred",
                  region, remote_md5)
        entry["consecutive_failures"] = 0
        entry["last_failure"] = None
        return PullResult(region, "skipped_unchanged", remote_md5)

    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=dest.parent, prefix=".pull-",
                                     suffix=".osm.pbf.tmp")
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
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
) -> list[PullResult]:
    state_path = root / "MIRROR_STATE.json"
    if not state_path.exists():
        raise SystemExit(
            f"error: {state_path} does not exist — run build_tree.sh "
            f"against {root} first."
        )
    state = load_state(state_path)
    results = []
    for region in regions:
        result = pull_region(region=region, root=root, pinned_date=pinned_date,
                              state=state, base_url=base_url,
                              min_interval=min_interval, now=now)
        results.append(result)
        # Checkpoint after every region so a mid-run crash on region N
        # doesn't lose the state recorded for regions before it.
        save_state(state_path, state)
    if pull_index_too:
        results.append(pull_index(root=root, pinned_date=pinned_date, state=state,
                                   base_url=base_url, min_interval=min_interval,
                                   now=now))
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
        "--region", action="append", required=True, dest="regions",
        help="Geofabrik region path, e.g. north-america/us/north-carolina "
             "(repeatable).",
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
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    pinned_date = args.pinned_date or _utcnow().strftime("%Y-%m-%d")
    results = run(
        args.regions, root=args.root, pinned_date=pinned_date,
        base_url=args.base_url,
        min_interval=timedelta(hours=args.min_interval_hours),
        pull_index_too=args.pull_index_too,
    )
    failed = [r for r in results if r.action == "failed"]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
