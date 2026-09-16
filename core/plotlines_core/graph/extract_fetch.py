"""Extent-triggered mirror-clip request and download — issue #274 (Phase 3.2
of epic #272; docs/Plotlines_OSM_Acquisition_Review.md §8(1)-(2), §11.5;
addendum Q1; PRD FR120/FR121/FR96/FR94; ARCH D41/D57).

**What this is.** Q1-C (§6.7, #262) put the covering-set resolution and the
way-deduplicating merge on the mirror, not the client: the client sends a
trip bbox to the mirror's one dynamic endpoint (`GET/POST /clip`) and gets
back one already-clipped `.osm.pbf`. This module is that request — the
client half — plus the honest, byte-observed FR121 progress it is reported
through, and the on-disk landing spot in `CacheLayout.osm_extract` (#273)
it lands in.

**What this is not.** It does not wire its result into `ensure_graph` or
`OsmLayerProvider.fetch` — replacing *those* transports is #275's job, and
until it lands this module's output is cached and reported but unconsumed.
"#274 and #275 are the pair that closes the loop; neither is meaningful
alone" (epic #272). It is also not a resolver: it never asks which extracts
cover a bbox (that question no longer has a client-side answer under Q1-C)
and it never merges anything.

**Trigger discipline (FR120/D41/D57 — "no eager download of any kind").**
Nothing in this module runs on its own; it is a plain function a caller
invokes. The only caller wired in as of this issue is
`service.plotlines_service.app.RegionState.build`, which itself only runs
from `POST /regions` — the same Author-declares-or-revises-the-extent
moment the region graph build already keys off. A fresh install with no
trip open makes zero calls into this module, by construction, not by a
flag.

**Honest progress (FR121).** `DownloadProgress` reports **observed bytes**,
never a time-based estimate — the opposite of `service.app.CapabilityState`,
whose `GRAPH_ESTIMATED_S` heuristic is exactly the kind of "fixed figure"
FR121 forbids and which this issue's acceptance criteria call out by name.
A download has a truer signal available (bytes actually received, and — when
the mirror's `Content-Length` header is present — a real total), so this
uses it instead of inventing an ETA.

**Reuse before request (§11.5's mitigation).** SPIKE-I (#265) measured the
two costs on opposite sides of the ledger: a clip's *egress* is cheap
(~2–3 MB, 130–614× smaller than the region extract it comes from, mean
325×; results.json), but its *compute* on the mirror is not (432–553 s
wall time per clip, independent of bbox size — "the clip is O(region
extract), not O(bbox)"). So the mitigation this module ships,
`find_reusable_extract`, is not tuned to save bytes — Q1-C already made
bytes a rounding error — it exists to avoid re-running an expensive,
byte-identical clip against a pin that has not moved. `EXTRACT_STALE_AFTER_DAYS`
reuses `tiles.mirror_state.MAX_PIN_AGE_DAYS` verbatim (45 days) rather than
inventing a second number: that constant is already "the mirror's own
pin cadence (monthly, Q2-B) plus a grace window," which is precisely the
question being asked here too — "could a newer pin plausibly exist yet?" —
just asked from the client's side of the same pin instead of the mirror's.

**Enlarging the bbox (FR120 revision).** `CacheLayout.osm_extract` keys
purely on the (rounded) bbox, so a revised, larger extent is simply a
different cache key — this module makes no attempt to diff or patch the
previous clip; it requests one new clip for the new bbox, exactly as the
issue's own "What to build" §4 recommends ("most likely one new clip for
the new bbox rather than a diff, since the clip is cheap and the merge is
what Q1-C removed"). This cannot discard a promoted anchor: anchors are
copied at promotion time (ARCH §4.2, D36) and never reference the extract
cache, so a bbox revision that changes which extract file is current has
nothing authored to lose. The superseded bbox's extract file is simply an
orphaned cache entry under the old key, cleaned up the same way a stale
pin directory is (`CacheLayout.sweep_stale_extracts`) rather than anything
this module manages.

**Failure honesty (§248's contract, extended).** Two exceptions, never
conflated, mirroring `graph.regions.OverpassUnavailable` /
`NoRoutableWaysError`: `MirrorUnreachable` (transport failure, or any
non-2xx that is not the mirror's own "no coverage" answer — including a
misconfigured `--client-key`/`401` or a `429` rate limit, since none of
those are a true statement about the bbox) and `NoExtractCoverage` (the
mirror's `404 no_mirror_coverage` — a real, finished answer about the area,
the same status `#248` protects on the Overpass side). **No Overpass
fallback exists behind this capability, by design, for the whole migration
window**: this download is additive (see "What this is not" above) and
never gates anything Overpass already serves, so there is nothing to fall
back *from* here — `ensure_graph` and `OsmLayerProvider.fetch` keep hitting
Overpass exactly as before until #275 swaps them, independent of whether
this capability is ready, loading, or failed.
"""

from __future__ import annotations

import json
import os
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlencode

from ..cache_layout import BBox, CacheLayout, trip_bbox_key
from ..osm_identity import osm_user_agent
from ..tiles.mirror_state import MAX_PIN_AGE_DAYS, pin_age_days

#: Matches `service.plotlines_service.mirror_clip.CLIENT_KEY_HEADER` byte
#: for byte — pinned by `service/tests/test_extract_fetch_client_key_header
#: _matches_server.py` rather than imported, since `plotlines_core` may not
#: import anything from `service` (P1's layering runs the other direction:
#: `service` depends on `core`, never the reverse).
CLIENT_KEY_HEADER = "X-Plotlines-Client-Key"

#: The response header `mirror_clip.py` carries the Geofabrik pin the clip
#: was cut from (added alongside this issue — see that module's own
#: docstring update). Required to land the file under the right
#: `CacheLayout.osm_extract(bbox, pin)` directory; its absence is treated as
#: a mirror-side protocol failure, not a reason to guess a pin.
PIN_HEADER = "X-Plotlines-Clip-Source-Pin"

#: Socket timeout passed to `urlopen` — `urllib.request` exposes a single
#: timeout covering both connect and each subsequent read, not a separate
#: pair (unlike, say, `requests`' `(connect, read)` tuple), so there is one
#: knob here, not two. Generous, not tight: SPIKE-I measured the mirror's
#: own clip compute at 432–553 s for a single-extract clip on its Pi
#: hardware (`results/RESULTS.md` §3.1), and this has to outlast that plus
#: the (small, ~2–3 MB) transfer, or a slow-but-working mirror reads as
#: unreachable. An unreachable host still fails fast under this — the
#: *connect* leg of a refused/black-holed host returns in milliseconds; it
#: is only a live-but-slow clip that needs the long ceiling.
READ_TIMEOUT_S = 900.0

_CHUNK_SIZE = 1 << 16  # 64 KiB per read — matches qa_proxy_client's copy loop granularity

#: §11.5's mitigation, restated as code: reuse an on-disk extract for this
#: bbox rather than requesting a new one, as long as its pin is no older
#: than this many days. Deliberately the *same* constant as
#: `tiles.mirror_state.MAX_PIN_AGE_DAYS` (45 days = the mirror's monthly
#: pin cadence, Q2-B, plus a grace window) rather than a second number —
#: see this module's docstring for why SPIKE-I's arithmetic argues for
#: tracking the mirror's own cadence rather than tuning for egress, which
#: Q1-C already made a rounding error (§11.5/Q6, results.json §4).
EXTRACT_STALE_AFTER_DAYS = MAX_PIN_AGE_DAYS


class MirrorUnreachable(RuntimeError):
    """The mirror could not be reached, or answered with anything other than
    a clean 200 or its own "no coverage" 404 — a transport failure, a
    5xx, a `401` (misconfigured client key), or a `429` (rate limited).
    None of these are a true statement about the bbox, so none of them may
    read as "no data here" (review §8(6), the #248 contract this extends).
    `str()` is a finished, user-facing sentence — the sidecar surfaces it
    verbatim as the `extract` capability's reason."""


class NoExtractCoverage(RuntimeError):
    """The mirror answered `404 no_mirror_coverage` — a true, finished
    answer about this bbox (nothing pinned on the mirror covers it), not an
    outage. Kept distinct from `MirrorUnreachable` exactly as
    `graph.regions.NoRoutableWaysError` is kept distinct from
    `OverpassUnavailable`: retrying an honest empty answer would just
    relabel it as a network outage it isn't."""


@dataclass
class DownloadProgress:
    """One extract download's observed-progress state — the byte-counting
    analogue of `service.app.CapabilityState`, which this deliberately does
    not reuse: that class's `progress()` is a *time* heuristic
    (`elapsed / estimated_s`), which is exactly the "fixed figure" FR121
    says a download must not report when a truer signal — bytes actually
    received — exists.

    `to_dict()` is shaped to slot into `GET /health`'s `capabilities.*`
    JSON next to `CapabilityState.to_dict()`'s output with the same
    `{"ready": bool, ...}` envelope, so a client reading `/health` does not
    need a second parsing rule for this capability.
    """

    status: str = "pending"  # pending -> downloading -> ready | failed
    bytes_downloaded: int = 0
    #: `None` until the mirror's `Content-Length` header is read — some
    #: intermediary could in principle strip it, and this must never fall
    #: back to a guessed total (FR121: observed progress only).
    total_bytes: int | None = None
    detail: str = ""
    #: Set on success to distinguish "just downloaded" from "reused a
    #: same-session cache hit without a network call" — both are `ready`,
    #: but the latter never touched `bytes_downloaded`/`total_bytes` as a
    #: transfer rate, only as a final file size.
    reused: bool = False

    @property
    def ready(self) -> bool:
        return self.status == "ready"

    def to_dict(self) -> dict:
        if self.status == "ready":
            d: dict = {"ready": True}
            if self.reused:
                d["reused"] = True
            return d
        if self.status == "failed":
            return {"ready": False, "reason": f"failed:{self.detail}"}
        if self.status == "downloading":
            d = {
                "ready": False,
                "reason": self.detail,
                "bytes_downloaded": self.bytes_downloaded,
            }
            if self.total_bytes is not None:
                d["total_bytes"] = self.total_bytes
                d["progress"] = (
                    round(self.bytes_downloaded / self.total_bytes, 2)
                    if self.total_bytes else 0.0
                )
            return d
        return {"ready": False, "reason": "pending"}


def find_reusable_extract(
    bbox: BBox,
    cache_dir: Path,
    *,
    now: datetime | None = None,
    max_age_days: float = EXTRACT_STALE_AFTER_DAYS,
) -> Path | None:
    """The freshest already-cached extract for `bbox` whose pin is no older
    than `max_age_days`, or `None` if none qualifies — §11.5's "a new trip
    in a region already on disk at a pin within *N* reuses it rather than
    fetching," made concrete.

    Scans `CacheLayout(cache_dir).extracts_dir`'s pin sub-directories (not
    an index — there is no index, deliberately, same discipline
    `mirror_clip.discover_region_extracts` documents for the mirror side)
    for a sibling holding this bbox's key file, and returns the
    youngest-pinned match. More than one qualifying pin is possible in the
    window between a mirror pin bump and the next `sweep_stale_extracts`
    call; this never reuses a stale one just because it sorts first.
    """
    now = now or datetime.now(timezone.utc)
    layout = CacheLayout(cache_dir)
    key = trip_bbox_key(bbox)
    if not layout.extracts_dir.is_dir():
        return None
    best: tuple[float, Path] | None = None
    for pin_dir in layout.extracts_dir.iterdir():
        if not pin_dir.is_dir():
            continue
        candidate = pin_dir / f"{key}.osm.pbf"
        if not candidate.is_file():
            continue
        age = pin_age_days(pin_dir.name, now=now)
        if age is None or age > max_age_days:
            continue
        if best is None or age < best[0]:
            best = (age, candidate)
    return best[1] if best else None


def _error_code(body: bytes) -> str | None:
    """The `{"error": "...", ...}` code from a `mirror_clip.py` finished
    JSON error body (`HTTPException(detail={"error": ..., "message": ...})`
    lands as `{"detail": {"error": ..., "message": ...}}` on the wire).
    `None` on anything unparsable — treated as an unrecognised failure, not
    a crash."""
    try:
        parsed = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    detail = parsed.get("detail") if isinstance(parsed, dict) else None
    return detail.get("error") if isinstance(detail, dict) else None


def fetch_extract(
    bbox: BBox,
    *,
    mirror_url: str,
    cache_dir: Path,
    client_key: str | None = None,
    progress: DownloadProgress | None = None,
    timeout_s: float = READ_TIMEOUT_S,
    version: str | None = None,
    urlopen=urllib.request.urlopen,
) -> Path:
    """Request `mirror_url`'s `/clip` for `bbox` and write the response to
    `CacheLayout(cache_dir).osm_extract(bbox, pin)`, `pin` read off the
    response's `PIN_HEADER`. Always requests fresh — call
    `find_reusable_extract` first (or use `ensure_extract`, which does) to
    skip the request entirely when a within-`N` cached extract already
    exists.

    **Restartable, not byte-range resumable, and deliberately so.** The
    write goes to a private temp file under the destination's own pin
    directory, renamed onto the real path only once the whole body has
    landed — an interrupted download leaves no partial or corrupt file at
    the addressable path, so a caller (a retried `POST /regions`) can
    simply call this again and it restarts cleanly from zero. True HTTP
    Range resume was considered and rejected: `mirror_clip.py` "re-clips on
    every request and caches nothing" (its own docstring) — the clip is
    computed fresh into memory and streamed out, so serving a Range request
    would still cost the mirror the **entire** 432–553 s clip (SPIKE-I
    §3.1: cost tracks the source extract, not the bbox or the output size),
    buying a resumed client nothing the mirror doesn't already pay in full
    for a restart. Implementing Range support without mirror-side caching
    of the clip output — which #262 explicitly chose not to build — would
    only add complexity for a resume that saves no compute.

    Raises `MirrorUnreachable` or `NoExtractCoverage` — see this module's
    docstring — never lets a raw `URLError`/`HTTPError` escape.
    """
    progress = progress if progress is not None else DownloadProgress()
    west, south, east, north = bbox
    query = urlencode({"west": west, "south": south, "east": east, "north": north})
    url = f"{mirror_url.rstrip('/')}/clip?{query}"
    headers = {"User-Agent": osm_user_agent(version)}
    if client_key:
        headers[CLIENT_KEY_HEADER] = client_key

    progress.status = "downloading"
    progress.detail = "requesting mirror clip"
    try:
        response = urlopen(
            urllib.request.Request(url, headers=headers), timeout=timeout_s
        )
    except urllib.error.HTTPError as exc:
        body = exc.read()
        code = _error_code(body)
        if exc.code == 404 and code == "no_mirror_coverage":
            progress.status = "failed"
            progress.detail = "no_mirror_coverage"
            raise NoExtractCoverage(
                "The Plotlines map-data mirror doesn't have OSM data for "
                "this area yet. Try a different area, or check back after "
                "the mirror's next monthly pin update."
            ) from exc
        progress.status = "failed"
        progress.detail = code or f"http_{exc.code}"
        raise MirrorUnreachable(
            "Couldn't reach the Plotlines map-data mirror to prepare local "
            "map data for this area. This is almost always temporary — "
            "check your connection and try again in a few minutes. "
            f"(mirror said: {exc.code} {code or exc.reason})"
        ) from exc
    except urllib.error.URLError as exc:
        progress.status = "failed"
        progress.detail = "unreachable"
        raise MirrorUnreachable(
            "Couldn't reach the Plotlines map-data mirror to prepare local "
            "map data for this area. This is almost always temporary — "
            f"check your connection and try again in a few minutes. ({exc.reason})"
        ) from exc

    with response:
        pin = response.headers.get(PIN_HEADER)
        if not pin:
            progress.status = "failed"
            progress.detail = "missing_pin_header"
            raise MirrorUnreachable(
                "The Plotlines map-data mirror answered without naming the "
                "data snapshot it clipped from. Couldn't safely cache the "
                "result — try again."
            )
        content_length = response.headers.get("Content-Length")
        progress.total_bytes = int(content_length) if content_length else None

        dest = CacheLayout(cache_dir).osm_extract(bbox, pin)
        dest.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(
            dir=dest.parent, prefix=".extract-", suffix=".part"
        )
        tmp_path = Path(tmp_name)
        downloaded = 0
        try:
            with os.fdopen(fd, "wb") as out:
                while True:
                    chunk = response.read(_CHUNK_SIZE)
                    if not chunk:
                        break
                    out.write(chunk)
                    downloaded += len(chunk)
                    progress.bytes_downloaded = downloaded
            tmp_path.replace(dest)
        except BaseException:
            tmp_path.unlink(missing_ok=True)
            progress.status = "failed"
            progress.detail = "download_interrupted"
            raise

    progress.status = "ready"
    progress.detail = "ready"
    progress.bytes_downloaded = dest.stat().st_size
    progress.total_bytes = progress.bytes_downloaded
    return dest


def ensure_extract(
    bbox: BBox,
    *,
    mirror_url: str,
    cache_dir: Path,
    client_key: str | None = None,
    progress: DownloadProgress | None = None,
    max_age_days: float = EXTRACT_STALE_AFTER_DAYS,
    now: datetime | None = None,
    timeout_s: float = READ_TIMEOUT_S,
    version: str | None = None,
    urlopen=urllib.request.urlopen,
) -> Path:
    """The one function a caller needs: reuse an on-disk extract within
    `max_age_days` (`find_reusable_extract`) if one exists, otherwise
    request a fresh clip (`fetch_extract`). This is what
    `service.plotlines_service.app.RegionState.build` calls at the
    FR120 extent-declared-or-revised moment.
    """
    progress = progress if progress is not None else DownloadProgress()
    reusable = find_reusable_extract(bbox, cache_dir, now=now, max_age_days=max_age_days)
    if reusable is not None:
        progress.status = "ready"
        progress.detail = "reused cached extract"
        progress.reused = True
        size = reusable.stat().st_size
        progress.bytes_downloaded = size
        progress.total_bytes = size
        return reusable
    return fetch_extract(
        bbox,
        mirror_url=mirror_url,
        cache_dir=cache_dir,
        client_key=client_key,
        progress=progress,
        timeout_s=timeout_s,
        version=version,
        urlopen=urlopen,
    )
