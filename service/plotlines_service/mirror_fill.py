"""The mirror's fill worker and its contract — issue #517 (epic #516,
ARCH D67).

**What this is.** D67 splits the mirror in two. The **store** is immutable
paths served as plain files (Caddy on the Pi, a zero-egress bucket once
hosted), and it never gains logic. The **fill worker** is this module: it
takes a fill request for an area the store does not hold, fetches that area
from upstream on its own queue, publishes it into the store with the same
atomic temp-file → `os.replace` step the extract scripts use, and reports
progress. Each layer (OSM #518, basemap #519, elevation #520) plugs in a
`LayerFiller`; this module fetches nothing itself.

**The contract.**

    POST /fill {layer, west, south, east, north}
        → 202 {fill_id, state: "fetching", retry_after_s, …}   a job runs
        → 200 {fill_id: null, state: "ready"}                  already stored
        → 200 {fill_id: null, state: "no_upstream_coverage"}   terminal
        → 200 {fill_id, state: "failed:<reason>", retry_after_s}
    GET  /fill/{fill_id}
        → {fill_id, layer, state, detail, retry_after_s, progress, areas}

`state` is one of four values, and each means one thing to a caller:

- `fetching` — **wait**. The area is on its way; poll `GET /fill/{id}` no
  sooner than `retry_after_s`. Never a final answer (D67, D66: a poll, not
  a longer deadline). A quota wait (#520) is `fetching` too.
- `ready` — the area is in the store; read it the ordinary way.
- `no_upstream_coverage` — **won't**. No upstream publishes this area
  (open ocean, outside every Geofabrik region). Decided locally, at once,
  with no job and no upstream request. Do not poll.
- `failed:<reason>` — the fill ran and did not land (`failed:restarted`,
  `failed:timeout`, `failed:upstream_…`). Transient by default (D66): a
  new `POST /fill` after `retry_after_s` starts a fresh job.

**Single-flight falls out of identity.** A filler maps a request bbox to
the store *areas* covering it (a Geofabrik region, a grid cell) — locally,
from data on disk, never over the network. One job runs per `(layer,
area)`, and `fill_id` is a hash of the layer and its sorted area keys, so
N requests for one missing area get one job and one id, and a later
request inside an in-flight job's area maps to the same area and joins it.

**Bookkeeping.** `MIRROR_STATE.json`'s `areas` record holds one row per
stored area: layer, area, path, upstream source, `filled_at`,
`last_read_at`, `bytes`, `pinned`. The existing `geofabrik.regions` and
`basemap.covered_regions` entries are seeded into it as its first rows —
pinned, `seeded: true` — rather than kept as a second system, so the
pre-warm scripts' areas (#515, #530) are never evicted.

**Eviction.** Past `store_cap_bytes`, the least-recently-read *unpinned*
areas are deleted until the store fits. `last_read_at` is stamped when a
`POST /fill` answers `ready` for an area and when `/clip` reads one — Caddy
serves the static files and records nothing, by design.

**The worker's own hygiene (D66 applied to the worker).** A request thread
only plans and enqueues; `LayerFiller.fetch` runs on the worker's own pool.
A job whose run passes `job_timeout_s` is reported `failed:timeout`. The
job journal lives outside the store (`state_dir`), and on start every job
that was mid-fetch is reported `failed:restarted` and every `.fill-*`
staging file under the store is removed, so a killed worker leaves no
partial file at a store path and no job `fetching` forever. A job that was
*waiting* (`FillDeferred`, #520's quota wait) had nothing in flight and is
simply rescheduled.

Single process, like the rest of the mirror-clip service: the job table and
single-flight are in memory, so `--workers > 1` would give each worker its
own table.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import shutil
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from stat import S_IMODE as stat_mode
from typing import Callable, Iterable, Mapping, Protocol

from pydantic import BaseModel

try:
    import fcntl  # POSIX only; the mirror runs in a Linux container
except ImportError:  # pragma: no cover - never exercised on the Linux target
    fcntl = None  # type: ignore[assignment]

log = logging.getLogger("plotlines.mirror_fill")

BBox = tuple[float, float, float, float]

FETCHING = "fetching"
READY = "ready"
NO_UPSTREAM_COVERAGE = "no_upstream_coverage"
FAILED_PREFIX = "failed:"

#: The prefix every staging file the worker writes carries. Nothing under a
#: store path ever starts with it, so the restart sweep can remove exactly
#: the worker's partial output and nothing else.
STAGING_PREFIX = ".fill-"

#: `retry_after_s` for a running job when its filler gives no better
#: estimate. A hint for the poller, not a promise about when the job ends.
DEFAULT_RETRY_AFTER_S = 15

#: How long a failed area waits before a new `POST /fill` starts another
#: job for it — the #247 cooldown shape, so a failing upstream is not
#: hammered by every poller's retry.
DEFAULT_FAILED_COOLDOWN_S = 300.0

#: Past this much *run* time (not waiting time — a quota wait can be a
#: day), a job is reported `failed:timeout`. A full-state Geofabrik pull
#: plus precut is minutes (SPIKE-I); an hour is a stuck job.
DEFAULT_JOB_TIMEOUT_S = 3600.0

#: `last_read_at` is rewritten at most this often per area, so a busy
#: area does not turn every read into a `MIRROR_STATE.json` write.
DEFAULT_TOUCH_INTERVAL_S = 3600.0

#: Finished jobs and their tickets stay answerable this long, then drop out
#: of the journal.
DEFAULT_JOB_RETENTION_S = 24 * 3600.0


def failed(reason: str) -> str:
    return f"{FAILED_PREFIX}{reason}"


def is_failed(state: str) -> bool:
    return state.startswith(FAILED_PREFIX)


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


# --------------------------------------------------------------------------
# What a layer plugs in
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class AreaPlan:
    """One store area a request needs. `area` is the layer's stable key
    for it (a region name, a grid-cell name); `path` is the store-relative
    file the fill publishes."""

    area: str
    path: str
    bbox: BBox | None = None
    #: The layer's own word that the area is already in its store, for a
    #: layer whose store is not the `areas` record (#520: the elevation
    #: proxy's DEM cache). Answered `ready` with no job.
    present: bool = False


@dataclass(frozen=True)
class FillPlan:
    """A filler's answer to "what covers this bbox". Either the areas
    (possibly already stored) or a finished sentence saying no upstream
    publishes it."""

    areas: tuple[AreaPlan, ...] = ()
    no_coverage: str | None = None


@dataclass(frozen=True)
class FilledArea:
    """What a successful `fetch` reports. `upstream` names the source
    (`geofabrik:north-carolina@2026-09-01`); `extra_paths` are sibling
    files published with the area (a `.poly`) that eviction removes too."""

    upstream: str
    extra_paths: tuple[str, ...] = ()
    #: Layer-specific facts kept on the area's row (`meta`), for the
    #: filler's own `register` hook to read back.
    meta: Mapping[str, object] = field(default_factory=dict)


class FillDeferred(Exception):
    """Raised by `fetch` when the upstream cannot be asked yet but will be
    askable later — #520's spent OpenTopography allowance. The job stays
    `fetching` and is re-run after `retry_after_s`; nothing was spent."""

    def __init__(self, retry_after_s: float, detail: str):
        super().__init__(detail)
        self.retry_after_s = max(1.0, float(retry_after_s))
        self.detail = detail


class FillFailed(Exception):
    """Raised by `fetch` with a short machine reason (`upstream_404`,
    `md5_mismatch`) that becomes `failed:<reason>`."""

    def __init__(self, reason: str, detail: str = ""):
        super().__init__(detail or reason)
        self.reason = reason
        self.detail = detail or reason


class NoUpstreamCoverageError(Exception):
    """Raised by `fetch` when the upstream turns out to publish nothing for
    the area after all (a filler should decide this in `plan` whenever it
    can, so no job starts)."""


class LayerFiller(Protocol):
    """One layer's half of the contract.

    `plan` runs **on the request thread**, so it must be local and fast: it
    reads what is on disk (a mirrored `index-v1.json`, grid arithmetic,
    `records`) and never makes a network call (D66). `fetch` runs on the
    worker's own pool and is where every upstream request happens; it
    writes only through `ctx.staging_path` + `ctx.publish`."""

    layer: str

    def plan(self, bbox: BBox, records: Mapping[str, dict]) -> FillPlan: ...

    def fetch(self, area: AreaPlan, ctx: "FillContext") -> FilledArea: ...


#: The mode every file the worker leaves in the store gets: world-readable,
#: owner-writable. The store is served as plain files, and the mirror's own
#: scripts run as its owner, not as whoever the worker runs as (#517's
#: follow-up: a root worker wrote MIRROR_STATE.json 0600 and locked the
#: `greg`-run re-cut out of its own state file).
STORE_FILE_MODE = 0o644


def open_state_lock(lock_path: Path) -> int:
    """The state file's `flock` target, opened **read-only** — `flock` needs
    no write access, so a lock file created by another user (the cron
    scripts, or a worker running as someone else) never blocks this caller.
    Created 0644 if absent. Returns an fd; the caller closes it."""
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    return os.open(lock_path, os.O_RDONLY | os.O_CREAT, STORE_FILE_MODE)


def replace_keeping_mode(tmp: Path | str, dest: Path) -> None:
    """`os.replace(tmp, dest)`, but `dest` keeps the mode (and, for a
    process that may chown, the owner) it had — or gets `STORE_FILE_MODE`
    and its directory's owner when new. `mkstemp`'s 0600 must never reach a
    store path: the scripts that share the store run as its owner."""
    try:
        st = dest.stat()
        mode, uid, gid = stat_mode(st.st_mode), st.st_uid, st.st_gid
    except FileNotFoundError:
        parent = dest.parent.stat()
        mode, uid, gid = STORE_FILE_MODE, parent.st_uid, parent.st_gid
    os.chmod(tmp, mode)
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        os.chown(tmp, uid, gid)
    os.replace(tmp, dest)


class FillContext:
    """What `fetch` gets: a progress callback and the one publish path into
    the store."""

    def __init__(self, root: Path, job: "_Job", on_progress: Callable[[], None]):
        self.root = root
        self._job = job
        self._on_progress = on_progress

    def progress(self, fraction: float | None, detail: str | None = None) -> None:
        self._job.progress = None if fraction is None else max(0.0, min(1.0, fraction))
        if detail is not None:
            self._job.detail = detail
        self._on_progress()

    def staging_path(self, rel_path: str) -> Path:
        """A fresh staging path in the same directory as `rel_path`'s final
        location (so `publish`'s `os.replace` never crosses filesystems),
        named with `STAGING_PREFIX` so a restart can find and remove it."""
        final = self.root / rel_path
        final.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(
            dir=final.parent, prefix=f"{STAGING_PREFIX}{self._job.job_id[:8]}-",
            suffix=f"-{final.name}")
        os.close(fd)
        return Path(name)

    def publish(self, staged: Path, rel_path: str) -> Path:
        """Atomically moves a staged file to its store path — the same
        temp-file → `os.replace` step `geofabrik_pull.py` and
        `protomaps_extract.py` use. A reader sees the old file or the new
        one, never a half-written one."""
        final = self.root / rel_path
        final.parent.mkdir(parents=True, exist_ok=True)
        replace_keeping_mode(staged, final)
        return final


# --------------------------------------------------------------------------
# Store bookkeeping — MIRROR_STATE.json's `areas` record
# --------------------------------------------------------------------------


def area_key(layer: str, area: str) -> str:
    return f"{layer}/{area}"


def _file_bytes(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def seed_area_records(state: dict, root: Path) -> bool:
    """Brings `state["areas"]` in line with the entries the pull and extract
    scripts already write, so they are the record's first rows rather than
    a second system. Adds a pinned, `seeded: true` row for every
    `geofabrik.regions` and `basemap.covered_regions` entry that lacks
    one, and drops a seeded row whose source entry is gone (a precut
    `replace_sources` run unregisters its sources). Rows a fill wrote
    (`seeded` false) are never touched here. Returns whether anything
    changed."""
    areas = state.get("areas")
    if not isinstance(areas, dict):
        areas = {}
    before = json.dumps(areas, sort_keys=True)
    wanted: dict[str, dict] = {}

    geofabrik = state.get("geofabrik") or {}
    pin = geofabrik.get("pinned_date")
    for name, entry in (geofabrik.get("regions") or {}).items():
        if not pin:
            break
        entry = entry or {}
        rel = f"osm/geofabrik/{pin}/{name}.osm.pbf"
        precut = entry.get("precut_bbox")
        wanted[area_key("osm", name)] = {
            "layer": "osm",
            "area": name,
            "path": rel,
            "bbox": list(precut) if precut else None,
            "upstream": (
                f"precut:{','.join(entry.get('precut_from') or [])}"
                if entry.get("precut_from") else f"geofabrik:{name}"
            ),
            "filled_at": entry.get("pulled_at") or entry.get("checked_at"),
            "last_read_at": None,
            "bytes": _file_bytes(root / rel),
            "pinned": True,
            "seeded": True,
        }

    covered = (state.get("basemap") or {}).get("covered_regions")
    if isinstance(covered, dict):
        for name, entry in covered.items():
            entry = entry or {}
            rel = entry.get("path")
            if not rel:
                continue
            source = entry.get("source") or {}
            wanted[area_key("basemap", name)] = {
                "layer": "basemap",
                "area": name,
                "path": rel,
                "bbox": list(entry["bbox"]) if entry.get("bbox") else None,
                # #519: a multi-area archive's real areas, when recorded.
                "parts": [list(p) for p in entry["parts"]] if entry.get("parts") else None,
                "upstream": f"protomaps:{source.get('planet_build_date') or 'unknown'}",
                "filled_at": entry.get("extracted_at"),
                "last_read_at": None,
                "bytes": _file_bytes(root / rel),
                "pinned": True,
                "seeded": True,
            }

    for key in [k for k, row in areas.items() if row.get("seeded") and k not in wanted]:
        del areas[key]
    for key, row in wanted.items():
        existing = areas.get(key)
        if existing is None:
            areas[key] = row
        elif existing.get("seeded"):
            # Keep the read stamp; refresh what the source entry says.
            row["last_read_at"] = existing.get("last_read_at")
            areas[key] = row
    state["areas"] = areas
    return json.dumps(areas, sort_keys=True) != before


class StoreBook:
    """Read-modify-write access to the `areas` record in the store's state
    file. Every write re-reads the file under an exclusive `flock` and
    replaces it atomically, so the pull scripts' own writes to *other*
    keys are never clobbered by a stale copy held here — and they, in
    turn, carry `areas` forward from disk (`geofabrik_pull.save_state`)."""

    def __init__(self, root: Path, state_path: Path | None = None):
        self.root = Path(root)
        self.state_path = Path(state_path) if state_path else self.root / "MIRROR_STATE.json"
        self._lock = threading.Lock()

    def _flock(self):
        book = self

        class _Guard:
            def __enter__(self_inner):
                book._lock.acquire()
                self_inner.fh = None
                if fcntl is not None:
                    lock_path = book.state_path.with_name(book.state_path.name + ".lock")
                    try:
                        self_inner.fh = open_state_lock(lock_path)
                        fcntl.flock(self_inner.fh, fcntl.LOCK_EX)
                    except BaseException:
                        if self_inner.fh is not None:
                            os.close(self_inner.fh)
                        book._lock.release()
                        raise
                return self_inner

            def __exit__(self_inner, *exc):
                if self_inner.fh is not None:
                    fcntl.flock(self_inner.fh, fcntl.LOCK_UN)
                    os.close(self_inner.fh)
                book._lock.release()

        return _Guard()

    def _read(self) -> dict:
        try:
            return json.loads(self.state_path.read_text())
        except FileNotFoundError:
            return {}

    def _write(self, state: dict) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.state_path.parent, prefix=".state-")
        try:
            with os.fdopen(fd, "w") as f:
                f.write(json.dumps(state, indent=2) + "\n")
            replace_keeping_mode(tmp, self.state_path)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise

    def update(self, fn: Callable[[dict], bool | None]) -> dict:
        """Runs `fn(state)` on a fresh read under the lock; writes back
        unless `fn` returns `False`. Seeding runs first on every update, so
        the record never drifts from the scripts' entries."""
        with self._flock():
            state = self._read()
            seeded = seed_area_records(state, self.root)
            changed = fn(state)
            if seeded or changed is not False:
                self._write(state)
            return state

    def records(self) -> dict[str, dict]:
        """The current `areas` record, seeded, without writing."""
        state = self._read()
        seed_area_records(state, self.root)
        return dict(state.get("areas") or {})


# --------------------------------------------------------------------------
# Jobs and the worker
# --------------------------------------------------------------------------


@dataclass
class _Job:
    job_id: str
    layer: str
    area: str
    path: str
    bbox: BBox | None
    state: str = FETCHING
    detail: str = ""
    progress: float | None = None
    created_at: float = 0.0
    #: Monotonic-clock start of the current run; `None` while waiting on a
    #: `FillDeferred` or once finished.
    run_started_at: float | None = None
    #: Wall-clock seconds-since-epoch the job next runs, while deferred.
    deferred_until: float | None = None
    finished_at: float | None = None
    retry_after_s: float | None = None

    @property
    def key(self) -> str:
        return area_key(self.layer, self.area)

    def to_json(self) -> dict:
        return {
            "job_id": self.job_id, "layer": self.layer, "area": self.area,
            "path": self.path, "bbox": list(self.bbox) if self.bbox else None,
            "state": self.state, "detail": self.detail,
            "created_at": self.created_at,
            "running": self.run_started_at is not None,
            "deferred_until": self.deferred_until,
            "finished_at": self.finished_at,
            "retry_after_s": self.retry_after_s,
        }


@dataclass(frozen=True)
class FillStatus:
    """What a `POST /fill` or `GET /fill/{id}` answers."""

    fill_id: str | None
    layer: str
    state: str
    detail: str = ""
    retry_after_s: int | None = None
    progress: float | None = None
    areas: tuple[str, ...] = ()
    jobs_started: int = 0

    def to_json(self) -> dict:
        return {
            "fill_id": self.fill_id,
            "layer": self.layer,
            "state": self.state,
            "detail": self.detail,
            "retry_after_s": self.retry_after_s,
            "progress": self.progress,
            "areas": list(self.areas),
        }


class UnknownLayer(ValueError):
    pass


def fill_id_for(layer: str, areas: Iterable[str]) -> str:
    canonical = layer + "|" + "|".join(sorted(areas))
    return hashlib.sha256(canonical.encode()).hexdigest()[:20]


class FillWorker:
    """The fill worker. `request` and `status` are what the HTTP layer
    calls; both return at once. `fetch` work runs on `self._pool`."""

    def __init__(
        self,
        root: Path,
        fillers: Iterable[LayerFiller],
        *,
        state_dir: Path,
        state_path: Path | None = None,
        max_workers: int = 1,
        store_cap_bytes: int = 0,
        job_timeout_s: float = DEFAULT_JOB_TIMEOUT_S,
        failed_cooldown_s: float = DEFAULT_FAILED_COOLDOWN_S,
        touch_interval_s: float = DEFAULT_TOUCH_INTERVAL_S,
        job_retention_s: float = DEFAULT_JOB_RETENTION_S,
        clock: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
    ):
        self.root = Path(root)
        self.fillers = {f.layer: f for f in fillers}
        self.book = StoreBook(self.root, state_path)
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.journal_path = self.state_dir / "fill_jobs.json"
        self.store_cap_bytes = max(0, int(store_cap_bytes))
        self.job_timeout_s = job_timeout_s
        self.failed_cooldown_s = failed_cooldown_s
        self.touch_interval_s = touch_interval_s
        self.job_retention_s = job_retention_s
        self._clock = clock
        self._wall = wall_clock
        self._lock = threading.RLock()
        self._jobs: dict[str, _Job] = {}
        self._tickets: dict[str, dict] = {}
        self._timers: list[threading.Timer] = []
        self._closed = False
        self._pool = ThreadPoolExecutor(
            max_workers=max(1, max_workers), thread_name_prefix="mirror-fill")
        self._recover()

    # -- lifecycle ---------------------------------------------------------

    def _recover(self) -> None:
        """Start-up: a job that was mid-fetch when the last process died is
        `failed:restarted`; one that was waiting on a deferral is resumed;
        every staging file under the store is removed."""
        removed = 0
        if self.root.exists():
            for staged in sorted(self.root.rglob(f"{STAGING_PREFIX}*"), reverse=True):
                try:
                    if staged.is_dir() and not staged.is_symlink():
                        shutil.rmtree(staged)
                    else:
                        staged.unlink()
                    removed += 1
                except OSError as exc:  # pragma: no cover - permissions
                    log.warning("fill: could not remove staging file %s: %s", staged, exc)
        # A layer whose fetch writes its own temp names (#520: the
        # OpenTopography client's `*.part`) names them, and they go too.
        for filler in self.fillers.values():
            for pattern in getattr(filler, "stale_globs", ()):
                for stale in self.root.glob(pattern):
                    stale.unlink(missing_ok=True)
                    removed += 1
        if removed:
            log.warning("fill: removed %d partial staging file(s) left by a previous run", removed)

        try:
            journal = json.loads(self.journal_path.read_text())
        except (FileNotFoundError, ValueError):
            journal = {}
        now_wall = self._wall()
        resumed = []
        for key, row in (journal.get("jobs") or {}).items():
            job = _Job(
                job_id=row["job_id"], layer=row["layer"], area=row["area"],
                path=row["path"], bbox=tuple(row["bbox"]) if row.get("bbox") else None,
                state=row["state"], detail=row.get("detail", ""),
                created_at=row.get("created_at", 0.0),
                deferred_until=row.get("deferred_until"),
                finished_at=row.get("finished_at"),
                retry_after_s=row.get("retry_after_s"),
            )
            if job.state == FETCHING:
                if row.get("deferred_until") and not row.get("running"):
                    resumed.append(job)
                else:
                    job.state = failed("restarted")
                    job.detail = "the fill worker restarted while this area was being fetched"
                    job.finished_at = now_wall
                    job.retry_after_s = None
            self._jobs[key] = job
        self._tickets = dict(journal.get("tickets") or {})
        self._save_journal()
        for job in resumed:
            if job.layer in self.fillers:
                self._schedule(job, max(0.0, (job.deferred_until or now_wall) - now_wall))
            else:
                job.state = failed("restarted")
                job.detail = f"layer {job.layer!r} is no longer configured"
        self.book.update(lambda state: None)  # seed the record once at start

    def shutdown(self, wait: bool = False) -> None:
        with self._lock:
            self._closed = True
            for t in self._timers:
                t.cancel()
        self._pool.shutdown(wait=wait, cancel_futures=True)

    # -- journal -----------------------------------------------------------

    def _save_journal(self) -> None:
        with self._lock:
            now_wall = self._wall()
            for key in [k for k, j in self._jobs.items()
                        if j.finished_at is not None
                        and now_wall - j.finished_at > self.job_retention_s]:
                del self._jobs[key]
            for fid in [f for f, t in self._tickets.items()
                        if now_wall - t.get("created_at", now_wall) > self.job_retention_s
                        and not any(area_key(t["layer"], a) in self._jobs for a in t["areas"])]:
                del self._tickets[fid]
            payload = {
                "jobs": {k: j.to_json() for k, j in self._jobs.items()},
                "tickets": self._tickets,
            }
            fd, tmp = tempfile.mkstemp(dir=self.state_dir, prefix=".journal-")
            with os.fdopen(fd, "w") as f:
                f.write(json.dumps(payload, indent=2))
            os.replace(tmp, self.journal_path)

    # -- store -------------------------------------------------------------

    def _stored(self, layer: str, area: AreaPlan, records: Mapping[str, dict]) -> bool:
        """In the store means recorded *at the path the plan names* and on
        disk. A plan can move an area — a Geofabrik re-pin puts the next
        cell under a new pin directory — and the row left at the old path
        must not answer `ready` for it."""
        if area.present:
            return True
        row = records.get(area_key(layer, area.area))
        return (row is not None and row["path"] == area.path
                and (self.root / row["path"]).exists())

    def touch(self, layer: str, area: str) -> None:
        """Stamps `last_read_at` for eviction, at most once per
        `touch_interval_s` per area."""
        key = area_key(layer, area)
        now = _utcnow()

        def _touch(state: dict) -> bool:
            row = (state.get("areas") or {}).get(key)
            if row is None:
                return False
            last = _parse_iso(row.get("last_read_at"))
            if last is not None and (now - last).total_seconds() < self.touch_interval_s:
                return False
            row["last_read_at"] = _iso(now)
            return True

        records = self.book.records()
        row = records.get(key)
        if row is None:
            return
        last = _parse_iso(row.get("last_read_at"))
        if last is not None and (now - last).total_seconds() < self.touch_interval_s:
            return
        self.book.update(_touch)

    def store_bytes(self) -> int:
        return sum(int(r.get("bytes") or 0) for r in self.book.records().values())

    def evict(self) -> list[str]:
        """Deletes least-recently-read unpinned areas until the store's
        recorded bytes fit `store_cap_bytes` (0 disables the cap). A pinned
        area is never evicted, even when pinned areas alone exceed the cap
        — that is logged, not fixed by deleting a seed. An area with a job
        in flight is skipped."""
        if self.store_cap_bytes <= 0:
            return []
        evicted: list[str] = []
        with self._lock:
            busy = {k for k, j in self._jobs.items() if j.state == FETCHING}

        def _evict(state: dict) -> bool:
            areas = state.get("areas") or {}
            total = sum(int(r.get("bytes") or 0) for r in areas.values())
            if total <= self.store_cap_bytes:
                return False

            def _age_key(item):
                _, row = item
                ts = _parse_iso(row.get("last_read_at")) or _parse_iso(row.get("filled_at"))
                return ts.timestamp() if ts else 0.0

            for key, row in sorted(areas.items(), key=_age_key):
                if total <= self.store_cap_bytes:
                    break
                if row.get("pinned") or key in busy:
                    continue
                for rel in [row["path"], *(row.get("extra_paths") or [])]:
                    (self.root / rel).unlink(missing_ok=True)
                filler = self.fillers.get(row.get("layer"))
                unregister = getattr(filler, "unregister", None)
                if unregister is not None:
                    unregister(state, row)
                total -= int(row.get("bytes") or 0)
                del areas[key]
                evicted.append(key)
            if total > self.store_cap_bytes:
                log.warning(
                    "fill: store is %d bytes over its %d-byte cap with only pinned "
                    "or in-flight areas left", total - self.store_cap_bytes,
                    self.store_cap_bytes)
            return bool(evicted)

        self.book.update(_evict)
        for key in evicted:
            log.info("fill: evicted %s (least recently read, over the store cap)", key)
        return evicted

    # -- requests ----------------------------------------------------------

    def request(self, layer: str, bbox: BBox) -> FillStatus:
        """Plan, and start a job for each missing area not already in
        flight. Returns at once; never waits on a fetch."""
        filler = self.fillers.get(layer)
        if filler is None:
            raise UnknownLayer(layer)
        records = self.book.records()
        plan = filler.plan(bbox, records)
        if plan.no_coverage is not None:
            return FillStatus(None, layer, NO_UPSTREAM_COVERAGE, plan.no_coverage)

        missing = [a for a in plan.areas if not self._stored(layer, a, records)]
        for a in plan.areas:
            if a not in missing:
                self.touch(layer, a.area)
                self._maybe_refresh(filler, layer, a, records)
        if not missing:
            return FillStatus(
                None, layer, READY, "already in the store",
                areas=tuple(a.area for a in plan.areas))

        started = 0
        with self._lock:
            if self._closed:
                raise RuntimeError("fill worker is shut down")
            now_wall = self._wall()
            for area in missing:
                job = self._jobs.get(area_key(layer, area.area))
                if job is not None and job.state == FETCHING:
                    continue  # single-flight: join the job already running
                if (job is not None and is_failed(job.state) and job.finished_at is not None
                        and now_wall - job.finished_at < self.failed_cooldown_s):
                    continue  # cooling down; the ticket reports the failure
                job = _Job(
                    job_id=uuid.uuid4().hex, layer=layer, area=area.area,
                    path=area.path, bbox=area.bbox, created_at=now_wall,
                    detail="queued",
                    retry_after_s=getattr(filler, "retry_hint_s", DEFAULT_RETRY_AFTER_S),
                )
                self._jobs[job.key] = job
                # A layer that already knows it must wait (#520: the
                # OpenTopography allowance is spent) says so here, so the
                # very first answer carries the real `retry_after_s` and no
                # fetch runs just to find that out.
                deferral = getattr(filler, "deferral", None)
                wait = deferral(area) if deferral is not None else None
                if wait is not None:
                    job.deferred_until = now_wall + wait[0]
                    job.retry_after_s = wait[0]
                    job.detail = wait[1]
                    self._schedule(job, wait[0])
                else:
                    self._schedule(job, 0.0)
                started += 1
            fid = fill_id_for(layer, (a.area for a in missing))
            self._tickets.setdefault(fid, {
                "layer": layer, "areas": sorted(a.area for a in missing),
                "bbox": list(bbox), "created_at": now_wall,
            })
            self._save_journal()
            status = self._ticket_status(fid)
        return FillStatus(
            status.fill_id, status.layer, status.state, status.detail,
            status.retry_after_s, status.progress, status.areas, jobs_started=started)

    def _maybe_refresh(self, filler, layer: str, area: AreaPlan,
                       records: Mapping[str, dict]) -> None:
        """D65's TTL, carried into the fill contract (#519): a stored area
        whose filler says it is due is still answered `ready` — the stored
        copy serves — and a single-flight job replaces it behind that, with
        the same atomic publish, so no reader ever waits on a refresh."""
        refresh_due = getattr(filler, "refresh_due", None)
        row = records.get(area_key(layer, area.area))
        if refresh_due is None or row is None or not refresh_due(row):
            return
        with self._lock:
            job = self._jobs.get(area_key(layer, area.area))
            if job is not None and job.state == FETCHING:
                return
            if (job is not None and is_failed(job.state) and job.finished_at is not None
                    and self._wall() - job.finished_at < self.failed_cooldown_s):
                return
            job = _Job(job_id=uuid.uuid4().hex, layer=layer, area=area.area,
                       path=area.path, bbox=area.bbox, created_at=self._wall(),
                       detail="refreshing behind the stored copy")
            self._jobs[job.key] = job
            self._schedule(job, 0.0)
            self._save_journal()
        log.info("fill: %s is past its refresh age; refreshing behind the stored copy",
                 job.key)

    def status(self, fill_id: str) -> FillStatus | None:
        with self._lock:
            if fill_id not in self._tickets:
                return None
            return self._ticket_status(fill_id)

    def in_flight(self) -> int:
        with self._lock:
            return sum(1 for j in self._jobs.values() if j.state == FETCHING)

    def _ticket_status(self, fill_id: str) -> FillStatus:
        ticket = self._tickets[fill_id]
        layer = ticket["layer"]
        self._expire_timeouts()
        now_wall = self._wall()
        records = None
        states, details, retries, progresses = [], [], [], []
        for area in ticket["areas"]:
            job = self._jobs.get(area_key(layer, area))
            if job is None:
                if records is None:
                    records = self.book.records()
                row = records.get(area_key(layer, area))
                if row is not None and (self.root / row["path"]).exists():
                    states.append(READY)
                else:
                    states.append(failed("not_queued"))
                    details.append(f"{area}: no job and not in the store; request it again")
                continue
            states.append(job.state)
            if job.detail:
                details.append(f"{area}: {job.detail}")
            if job.state == FETCHING:
                if job.deferred_until is not None:
                    retries.append(max(1.0, job.deferred_until - now_wall))
                else:
                    retries.append(job.retry_after_s or DEFAULT_RETRY_AFTER_S)
                if job.progress is not None:
                    progresses.append(job.progress)
            elif is_failed(job.state) and job.finished_at is not None:
                remaining = self.failed_cooldown_s - (now_wall - job.finished_at)
                retries.append(max(0.0, remaining))

        failures = [s for s in states if is_failed(s)]
        if failures:
            state = failures[0]
        elif FETCHING in states:
            state = FETCHING
        else:
            state = READY
        retry = int(round(max(retries))) if retries and state != READY else None
        progress = (sum(progresses) / len(progresses)) if progresses and state == FETCHING else None
        return FillStatus(
            fill_id, layer, state, "; ".join(details), retry, progress,
            tuple(ticket["areas"]))

    def _expire_timeouts(self) -> None:
        now = self._clock()
        changed = False
        for job in self._jobs.values():
            if (job.state == FETCHING and job.run_started_at is not None
                    and now - job.run_started_at > self.job_timeout_s):
                job.state = failed("timeout")
                job.detail = f"the fill ran past {self.job_timeout_s:.0f}s"
                job.run_started_at = None
                job.finished_at = self._wall()
                changed = True
                log.warning("fill: %s timed out", job.key)
        if changed:
            self._save_journal()

    # -- running -----------------------------------------------------------

    def _schedule(self, job: _Job, delay_s: float) -> None:
        if delay_s <= 0:
            self._pool.submit(self._run, job.job_id, job.key)
            return
        timer = threading.Timer(delay_s, lambda: self._submit_later(job))
        timer.daemon = True
        with self._lock:
            self._timers = [t for t in self._timers if t.is_alive()]
            self._timers.append(timer)
        timer.start()

    def _submit_later(self, job: _Job) -> None:
        with self._lock:
            if self._closed:
                return
        try:
            self._pool.submit(self._run, job.job_id, job.key)
        except RuntimeError:  # pool shut down between the check and here
            pass

    def _current(self, job_id: str, key: str) -> _Job | None:
        job = self._jobs.get(key)
        return job if job is not None and job.job_id == job_id else None

    def _run(self, job_id: str, key: str) -> None:
        with self._lock:
            job = self._current(job_id, key)
            if job is None or job.state != FETCHING:
                return
            job.run_started_at = self._clock()
            job.deferred_until = None
            job.detail = "fetching from upstream"
            self._save_journal()
        filler = self.fillers[job.layer]
        area = AreaPlan(job.area, job.path, job.bbox)
        ctx = FillContext(self.root, job, lambda: None)
        try:
            filled = filler.fetch(area, ctx)
        except FillDeferred as exc:
            with self._lock:
                job = self._current(job_id, key)
                if job is None:
                    return
                job.run_started_at = None
                job.deferred_until = self._wall() + exc.retry_after_s
                job.detail = exc.detail
                job.retry_after_s = exc.retry_after_s
                self._save_journal()
                self._schedule(job, exc.retry_after_s)
            log.info("fill: %s deferred %.0fs: %s", key, exc.retry_after_s, exc.detail)
            return
        except FillFailed as exc:
            self._finish(job_id, key, failed(exc.reason), exc.detail)
            log.warning("fill: %s failed (%s): %s", key, exc.reason, exc.detail)
            return
        except NoUpstreamCoverageError as exc:
            self._finish(job_id, key, NO_UPSTREAM_COVERAGE, str(exc))
            return
        except Exception as exc:  # noqa: BLE001 — any fetch failure is a finished state
            self._finish(job_id, key, failed("upstream_error"), str(exc))
            log.exception("fill: %s failed", key)
            return

        final = self.root / job.path
        if not final.exists():
            self._finish(job_id, key, failed("not_published"),
                         f"the {job.layer} filler returned without publishing {job.path}")
            return
        now = _iso(_utcnow())
        row = {
            "layer": job.layer, "area": job.area, "path": job.path,
            "bbox": list(job.bbox) if job.bbox else None,
            "upstream": filled.upstream, "filled_at": now, "last_read_at": now,
            "bytes": _file_bytes(final), "pinned": False, "seeded": False,
            "extra_paths": list(filled.extra_paths),
            "meta": dict(filled.meta),
        }

        def _record(state: dict) -> None:
            state.setdefault("areas", {})[key] = row
            register = getattr(filler, "register", None)
            if register is not None:
                register(state, row)

        self.book.update(_record)
        self._finish(job_id, key, READY, f"filled from {filled.upstream}")
        log.info("fill: %s ready (%d bytes from %s)", key, row["bytes"], filled.upstream)
        try:
            self.evict()
        except OSError as exc:  # best-effort, like the clip cache's eviction
            log.warning("fill: eviction failed: %s", exc)

    def _finish(self, job_id: str, key: str, state: str, detail: str) -> None:
        with self._lock:
            job = self._current(job_id, key)
            if job is None:
                return
            job.state = state
            job.detail = detail
            job.progress = None
            job.run_started_at = None
            job.deferred_until = None
            job.finished_at = self._wall()
            job.retry_after_s = None
            self._save_journal()


# --------------------------------------------------------------------------
# HTTP layer
# --------------------------------------------------------------------------


class FillRequestBody(BaseModel):
    layer: str
    west: float
    south: float
    east: float
    north: float


def add_fill_routes(app, worker: FillWorker, *, start_gate, read_gate) -> None:
    """Mounts `POST /fill` and `GET /fill/{fill_id}` on `app`.

    `start_gate` guards `POST` — the one call that can start upstream work,
    so it carries the client key and the rate limit (#263). `read_gate`
    guards the poll: the key, but not the rate limit, since a sidecar
    polling a running fill every few seconds is the contract working, not
    abuse. Both are FastAPI dependencies supplied by the host service,
    so `/clip` and `/fill` share one limiter."""
    from fastapi import Depends, HTTPException
    from fastapi.responses import JSONResponse

    def _respond(status: FillStatus) -> JSONResponse:
        headers = {}
        if status.retry_after_s is not None:
            headers["Retry-After"] = str(max(1, status.retry_after_s))
        code = 202 if status.state == FETCHING else 200
        return JSONResponse(status.to_json(), status_code=code, headers=headers)

    @app.post("/fill", dependencies=[Depends(start_gate)])
    def post_fill(body: FillRequestBody) -> JSONResponse:
        bbox = (body.west, body.south, body.east, body.north)
        west, south, east, north = bbox
        if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
            raise HTTPException(400, detail={
                "error": "invalid_bbox",
                "message": f"bbox must be west<east, south<north in degrees (got {bbox})"})
        try:
            status = worker.request(body.layer, bbox)
        except UnknownLayer:
            raise HTTPException(400, detail={
                "error": "unknown_layer",
                "message": f"this mirror fills {sorted(worker.fillers)}, not {body.layer!r}",
            }) from None
        log.info("fill REQUEST layer=%s bbox=%s state=%s fill_id=%s jobs_started=%d",
                 body.layer, bbox, status.state, status.fill_id, status.jobs_started)
        return _respond(status)

    @app.get("/fill/{fill_id}", dependencies=[Depends(read_gate)])
    def get_fill(fill_id: str) -> JSONResponse:
        status = worker.status(fill_id)
        if status is None:
            raise HTTPException(404, detail={
                "error": "unknown_fill",
                "message": f"no fill {fill_id!r} on this mirror (finished fills "
                           "drop out after a day; request the area again)"})
        return _respond(status)


# --------------------------------------------------------------------------
# Running as the store's owner
# --------------------------------------------------------------------------


def run_as_store_owner(root: Path, own: Iterable[Path] = (), *, ops=os) -> tuple[int, int] | None:
    """Drop from root to the store's owner before the worker starts (#517's
    follow-up, found on the Pi 2026-09-29).

    The container runs as root; the store on the host belongs to the user
    whose cron scripts write it (`geofabrik_pull.py`, the precut runs). A
    root worker left root-owned files in a shared tree — `MIRROR_STATE.json`
    rewritten 0600, and every Geofabrik pull, `.md5`, `.poly` and precut a
    fill writes — and the next script run died on `PermissionError`.
    Running as the store root's own uid/gid makes everything the worker
    writes, through any code path, the same as what the scripts write.

    `own` are the worker's private directories (the fill journal, the clip
    cache, scratch) — handed to that user first, since a named volume
    starts root-owned. A no-op when not root, or when the store itself is
    root-owned. Returns the `(uid, gid)` switched to, else `None`."""
    if not hasattr(ops, "geteuid") or ops.geteuid() != 0:
        return None
    st = ops.stat(root)
    uid, gid = st.st_uid, st.st_gid
    if uid == 0:
        return None
    for top in own:
        top = Path(top)
        top.mkdir(parents=True, exist_ok=True)
        for dirpath, dirnames, filenames in os.walk(top):
            ops.chown(dirpath, uid, gid)
            for name in filenames:
                ops.chown(os.path.join(dirpath, name), uid, gid)
    ops.setgroups([])
    ops.setgid(gid)
    ops.setuid(uid)
    log.info("fill worker running as the store's owner uid=%d gid=%d", uid, gid)
    return uid, gid
