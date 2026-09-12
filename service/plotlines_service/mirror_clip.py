"""Mirror-side bbox clip — issue #262 (Phase 1.8 of epic #264;
docs/Plotlines_OSM_Acquisition_Review.md §6.7, addendum L1/Q1-C/2c).

`python -m plotlines_service.mirror_clip --root /srv/plotlines-mirror`

**What this is.** Q1-C: the client never resolves a covering set, never
merges extracts, and never sees a region file. It sends a trip bbox and gets
back one clipped `.osm.pbf`. This is the one endpoint the mirror grows for
that — everything else on the mirror stays plain static files. It reads only
the pinned Geofabrik region extracts `deploy/mirror/geofabrik_pull.py`
already put on disk; it acquires nothing itself.

**What this is not.** Not SPIKE-I (#265) — that's the pre-registered,
controlled parity/timing measurement against a golden osmnx graph. This is
the seam SPIKE-I measures, "the seam plus enough implementation to be
measured," and it deliberately implements one completeness strategy
(`_CompleteWaysClip`, below) rather than osmium-tool's three, per L1's
finding that `simple`/`complete_ways`/`smart` are CLI concepts with no
pyosmium equivalent to select — the equivalent behaviour has to be coded,
not flagged. Not Phase 3's `CacheLayout`-keyed client cache either: this
service re-clips on every request and caches nothing, because doing less is
exactly what "the mirror stays dumb" asks for at this phase.

**Why this lives outside `plotlines-core`.** §6.7 calls this "identical to
Phase 4's hosted clip" — the algorithm is meant to be reused, which would
normally argue for `core`. But `core` is what `packaging/build_sidecar.sh`
freezes into every desktop/mobile client, and SPIKE-J (#266) — whether
pyosmium survives that freeze on all four targets — has not run yet.
Shipping `osmium` into every client build ahead of that measurement would
reintroduce, on every desktop, exactly the "client-side native clip
dependency" Q1-C's whole point was to remove (see the issue's own "Why").
So this module lives in `service`, is never imported by `app.py` /
`__main__.py`, and `osmium` is declared as the `mirror-clip` **extra** in
`pyproject.toml`, not a base dependency — the same "outside the frozen
binary's import graph" isolation `elevation_proxy.py` already uses, for the
same reason (that one sidesteps rasterio/GDAL; this one sidesteps pyosmium).

**No GPL-licensed binary anywhere in this path (addendum L1).** The clip
goes through pyosmium's Python API only — `osmium.SimpleHandler`,
`osmium.BackReferenceWriter`, `osmium.MergeInputReader` — never the
`osmium` CLI (`osmium-tool` is GPL-3.0; `pyosmium`/libosmium are
BSD-2-Clause). Nothing in this module or its Dockerfile shells out to an
`osmium` binary; there is no such binary in the image.

**Concurrency.** Single process, like `elevation_proxy.py` — the clip's cost
profile under concurrent requests is exactly what §9 flags as unmeasured,
so this rehearsal does not guess at one. Do not add `--workers > 1`.

**Reachability (issue #263, §6.8/1d).** Decided split: the mirror's plain
static files (region extracts, the basemap archive) stay open — that is
§6's "stay dumb" discipline, and it is bytes, not compute. This module's
one dynamic endpoint is the CPU-costing one ("an open clip endpoint is an
open CPU endpoint"), so `/clip` alone is restricted, by two independent,
deliberately non-account mechanisms: a shared `X-Plotlines-Client-Key`
header (identifies "a Plotlines-built client," never a person — unset
leaves the endpoint open, which is correct for local/dev and for the
hermetic tests below) and a per-client-IP rate ceiling that applies either
way, since the CPU cost does not depend on whether a key is configured. See
`_enforce_clip_access` and `_RateLimiter`.
"""

from __future__ import annotations

import argparse
import hmac
import logging
import os
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

import osmium
import uvicorn
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel
from starlette.background import BackgroundTask

from plotlines_core.tiles.mirror_state import load_mirror_state

from .logging_setup import configure_logging
from .version import VERSION

try:
    import resource  # POSIX only — this service only ever runs in the Linux
    # container built by Dockerfile.mirror-clip, but the guard costs nothing
    # and keeps this module importable (if never actually run) elsewhere.
except ImportError:  # pragma: no cover - not exercised on the Linux CI/Pi target
    resource = None  # type: ignore[assignment]

log = logging.getLogger("plotlines.mirror_clip")

#: (west, south, east, north) in degrees — the order every bbox in this
#: codebase uses (cache_layout.py, tiles/extract.py, curation/providers.py).
BBox = tuple[float, float, float, float]


class NoMirrorCoverage(ValueError):
    """No pinned region extract on this mirror covers the requested bbox —
    acceptance criterion 5: this must reach the client as a finished
    sentence, never a stack trace."""


def validate_bbox(bbox: BBox) -> None:
    west, south, east, north = bbox
    if not (-180.0 <= west <= 180.0 and -180.0 <= east <= 180.0):
        raise ValueError(f"bbox longitude out of range: west={west}, east={east}")
    if not (-90.0 <= south <= 90.0 and -90.0 <= north <= 90.0):
        raise ValueError(f"bbox latitude out of range: south={south}, north={north}")
    if west >= east:
        raise ValueError(f"bbox west must be < east (got west={west}, east={east})")
    if south >= north:
        raise ValueError(f"bbox south must be < north (got south={south}, north={north})")


def _bbox_to_box(bbox: BBox) -> "osmium.osm.Box":
    west, south, east, north = bbox
    return osmium.osm.Box(west, south, east, north)


def _boxes_intersect(a: "osmium.osm.Box", b: "osmium.osm.Box") -> bool:
    return (
        a.bottom_left.lon <= b.top_right.lon
        and b.bottom_left.lon <= a.top_right.lon
        and a.bottom_left.lat <= b.top_right.lat
        and b.bottom_left.lat <= a.top_right.lat
    )


@dataclass(frozen=True)
class RegionExtract:
    region: str
    path: Path


def discover_region_extracts(root: Path) -> list[RegionExtract]:
    """The region `.osm.pbf` files this mirror has actually pulled and
    verified, per `MIRROR_STATE.json` (`geofabrik_pull.py`'s record) — not a
    directory listing, since Q6 (bucket portability) treats a listing as
    something a consumer must never depend on."""
    state_path = root / "MIRROR_STATE.json"
    if not state_path.exists():
        return []
    state = load_mirror_state(state_path)
    geofabrik = state.get("geofabrik") or {}
    pinned_date = geofabrik.get("pinned_date")
    regions = geofabrik.get("regions") or {}
    if not pinned_date or not regions:
        return []
    extracts = []
    for region in regions:
        path = root / "osm" / "geofabrik" / pinned_date / f"{region}.osm.pbf"
        if path.exists():
            extracts.append(RegionExtract(region=region, path=path))
    return extracts


def _header_box(path: Path) -> "osmium.osm.Box | None":
    """The extract's own declared coverage, read off its PBF header — not
    asserted, the same discipline `WNC_CORRIDOR_BBOX` documents for the
    basemap archive. `None` when the header carries no valid box (some
    hand-built fixtures, or a producer that never set one): treated as
    *unknown*, not *excluded* — see `select_covering_extracts`."""
    reader = osmium.io.Reader(str(path))
    try:
        box = reader.header().box()
    finally:
        reader.close()
    return box if box.valid() else None


def select_covering_extracts(
    bbox: BBox, extracts: Iterable[RegionExtract]
) -> list[RegionExtract]:
    """Extracts whose declared coverage might overlap `bbox`. An extract
    with a valid header box that provably does *not* intersect is excluded;
    one with no declared box is kept (unknown coverage is a safe-to-include,
    not a safe-to-exclude, default — excluding it risks silently under-
    covering a real trip bbox). The border case named in the issue —
    Buncombe County ~30 km from Tennessee — is the ordinary case where this
    returns more than one extract."""
    query_box = _bbox_to_box(bbox)
    kept = []
    for extract in extracts:
        header_box = _header_box(extract.path)
        if header_box is not None and not _boxes_intersect(header_box, query_box):
            continue
        kept.append(extract)
    return kept


def _merge_extracts(paths: list[Path], dest: Path) -> None:
    """The bbox-spans-two-extracts case: combine the covering extracts into
    one id-deduplicated, correctly-ordered stream before clipping, so a
    border way present (whole) in both regional cuts is written once, not
    twice. `osmium.MergeInputReader` is pyosmium's own `osmium merge`
    equivalent — still pyosmium's Python API, not the CLI (L1)."""
    reader = osmium.MergeInputReader()
    for path in paths:
        reader.add_file(str(path))
    with osmium.SimpleWriter(str(dest), overwrite=True) as writer:
        reader.apply(writer, simplify=True)


class _CompleteWaysSelector(osmium.SimpleHandler):
    """Streams every node, way, and relation touching `box` into `writer`,
    keeping any selected way **whole** rather than truncating it at the
    boundary — severing a way is exactly the correctness risk §11.7 flags
    ("clipping a graph is not clipping tiles"). This is the pyosmium-native
    equivalent of osmium-tool's `complete_ways` strategy: `writer` is an
    `osmium.BackReferenceWriter`, which — once this pass decides what's
    "in" — pulls in whatever additional nodes a selected way needs from the
    reference source. `simple` (truncate at the boundary) and `smart`
    (also repair multipolygon relations, complete nested relations) are not
    implemented; SPIKE-I (#265) is where that trade-off gets evidence.

    Requires `apply_file(..., locations=True)` so `way.nodes[i].location` is
    populated from nodes already seen earlier in the same file — this is
    what lets a single pass decide way membership without a separate
    node-location index.
    """

    def __init__(self, writer: "osmium.BackReferenceWriter", box: "osmium.osm.Box"):
        super().__init__()
        self._writer = writer
        self._box = box
        self._way_ids: set[int] = set()
        self._node_ids: set[int] = set()
        self.selected_count = 0

    def node(self, n) -> None:
        if n.location.valid() and self._box.contains(n.location):
            self._node_ids.add(n.id)
            self._writer.add_node(n)
            self.selected_count += 1

    def way(self, w) -> None:
        hit = any(
            nr.location.valid() and self._box.contains(nr.location) for nr in w.nodes
        )
        if hit:
            self._way_ids.add(w.id)
            self._writer.add_way(w)
            self.selected_count += 1

    def relation(self, r) -> None:
        # Best-effort: a relation is kept when it references a way or node
        # already selected. Nested relation members and relations reachable
        # only through one are not chased — the "smart" strategy's job, not
        # this one's (see the class docstring).
        touches = any(
            (m.type == "w" and m.ref in self._way_ids)
            or (m.type == "n" and m.ref in self._node_ids)
            for m in r.members
        )
        if touches:
            self._writer.add_relation(r)
            self.selected_count += 1


def _select_and_write(bbox: BBox, source: Path, dest: Path) -> int:
    box = _bbox_to_box(bbox)
    with osmium.BackReferenceWriter(
        str(dest), str(source), overwrite=True, remove_tags=False
    ) as writer:
        selector = _CompleteWaysSelector(writer, box)
        selector.apply_file(str(source), locations=True)
    return selector.selected_count


@dataclass(frozen=True)
class ClipResult:
    output_path: Path
    wall_time_s: float
    output_bytes: int
    peak_rss_kb: int | None
    source_regions: tuple[str, ...]


def clip_bbox(
    bbox: BBox, *, root: Path, dest: Path, tmp_dir: Path | None = None
) -> ClipResult:
    """The one endpoint's whole job: bbox in, clipped `.osm.pbf` at `dest`
    out. Raises `NoMirrorCoverage` (acceptance criterion 5) when nothing
    pinned on this mirror covers `bbox` — either because no extract's
    declared coverage overlaps it, or because a clip against the extracts
    that might have produced literally nothing."""
    validate_bbox(bbox)
    started = time.monotonic()

    extracts = discover_region_extracts(root)
    if not extracts:
        raise NoMirrorCoverage(f"mirror at {root} has no pinned OSM extracts yet")

    candidates = select_covering_extracts(bbox, extracts)
    if not candidates:
        checked = ", ".join(e.region for e in extracts)
        raise NoMirrorCoverage(
            f"no pinned extract covers bbox {bbox} (checked: {checked})"
        )

    tmp_dir = tmp_dir or dest.parent
    merged_tmp: Path | None = None
    try:
        if len(candidates) == 1:
            source = candidates[0].path
        else:
            fd, merged_name = tempfile.mkstemp(
                dir=tmp_dir, prefix=".mirror-clip-merge-", suffix=".osm.pbf"
            )
            os.close(fd)
            merged_tmp = Path(merged_name)
            log.info(
                "clip bbox=%s spans %d extracts (%s) — merging before clip",
                bbox, len(candidates), ", ".join(c.region for c in candidates),
            )
            _merge_extracts([c.path for c in candidates], merged_tmp)
            source = merged_tmp

        selected = _select_and_write(bbox, source, dest)
    finally:
        if merged_tmp is not None and merged_tmp.exists():
            merged_tmp.unlink()

    if selected == 0:
        dest.unlink(missing_ok=True)
        checked = ", ".join(c.region for c in candidates)
        raise NoMirrorCoverage(
            f"bbox {bbox} matched no feature in the mirrored extract(s) "
            f"({checked}) it might have overlapped"
        )

    wall_time_s = time.monotonic() - started
    peak_rss_kb = (
        resource.getrusage(resource.RUSAGE_SELF).ru_maxrss if resource else None
    )
    log.info(
        "clip bbox=%s sources=%s wall_time_s=%.2f output_bytes=%d peak_rss_kb=%s",
        bbox, [c.region for c in candidates], wall_time_s, dest.stat().st_size,
        peak_rss_kb,
    )
    return ClipResult(
        output_path=dest,
        wall_time_s=wall_time_s,
        output_bytes=dest.stat().st_size,
        peak_rss_kb=peak_rss_kb,
        source_regions=tuple(c.region for c in candidates),
    )


# --------------------------------------------------------------------------
# HTTP layer
# --------------------------------------------------------------------------

#: Issue #263 — the shared Plotlines-client key every restricted `/clip`
#: request carries. Named as a module constant so a future client-side
#: caller (Phase 3, #272) has one spelling to import rather than a string
#: to copy.
CLIENT_KEY_HEADER = "X-Plotlines-Client-Key"


class ClipRequestBody(BaseModel):
    west: float
    south: float
    east: float
    north: float


class _RateLimiter:
    """Fixed-window per-client-IP ceiling on `/clip`, issue #263's abuse
    posture — applied whether or not a client key is configured, since the
    CPU cost of a clip does not depend on that. In-memory and single-
    process (this service never runs with `--workers > 1`, see the module
    docstring), so there is no cross-process state to reconcile. Nothing
    here persists past the rolling window or a process restart, and the key
    is a request IP, never an identity — an operational abuse guard, not
    per-user tracking."""

    _WINDOW_S = 60.0

    def __init__(
        self, limit_per_minute: int, *, time_fn: Callable[[], float] = time.monotonic
    ):
        self._limit = limit_per_minute
        self._time_fn = time_fn
        self._windows: dict[str, tuple[float, int]] = {}

    def allow(self, key: str) -> bool:
        if self._limit <= 0:  # 0 or negative disables the ceiling outright
            return True
        now = self._time_fn()
        window_start, count = self._windows.get(key, (now, 0))
        if now - window_start >= self._WINDOW_S:
            window_start, count = now, 0
        count += 1
        self._windows[key] = (window_start, count)
        return count <= self._limit


def _client_ip(request: Request) -> str:
    # Caddy's reverse_proxy sets X-Forwarded-For; request.client.host would
    # otherwise be Caddy's own address, collapsing every real caller onto
    # one rate-limit bucket.
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def create_clip_app(
    root: Path,
    *,
    tmp_dir: Path | None = None,
    client_key: str | None = None,
    rate_limit_per_minute: int = 30,
    rate_limit_time_fn: Callable[[], float] = time.monotonic,
) -> FastAPI:
    app = FastAPI(title="plotlines-mirror-clip", version=VERSION)
    work_dir = Path(tmp_dir) if tmp_dir else Path(tempfile.gettempdir())
    work_dir.mkdir(parents=True, exist_ok=True)
    rate_limiter = _RateLimiter(rate_limit_per_minute, time_fn=rate_limit_time_fn)

    def _enforce_clip_access(request: Request) -> None:
        """Issue #263: gate the one CPU-costing endpoint, not the static
        files. Client-key check only runs when a key is configured (unset
        means open — the correct default for local/dev and these hermetic
        tests); the rate ceiling always runs, since the cost it bounds does
        not depend on whether a key is configured."""
        if client_key is not None:
            presented = request.headers.get(CLIENT_KEY_HEADER)
            if presented is None or not hmac.compare_digest(presented, client_key):
                log.warning(
                    "clip REFUSED reason=unauthorized_client ip=%s", _client_ip(request)
                )
                raise HTTPException(
                    401,
                    detail={
                        "error": "unauthorized_client",
                        "message": f"this endpoint requires a {CLIENT_KEY_HEADER} header",
                    },
                )
        if not rate_limiter.allow(_client_ip(request)):
            log.warning(
                "clip REFUSED reason=rate_limited ip=%s", _client_ip(request)
            )
            raise HTTPException(
                429,
                detail={
                    "error": "rate_limited",
                    "message": (
                        f"more than {rate_limit_per_minute} /clip requests in "
                        "the last minute from this address"
                    ),
                },
            )

    def _run_clip(bbox: BBox) -> Response:
        fd, out_name = tempfile.mkstemp(
            dir=work_dir, prefix=".mirror-clip-", suffix=".osm.pbf"
        )
        os.close(fd)
        dest = Path(out_name)
        dest.unlink()  # BackReferenceWriter refuses to write over an existing file
        try:
            result = clip_bbox(bbox, root=root, dest=dest, tmp_dir=work_dir)
        except ValueError as exc:
            dest.unlink(missing_ok=True)
            if isinstance(exc, NoMirrorCoverage):
                log.warning("clip REFUSED bbox=%s reason=no_mirror_coverage: %s", bbox, exc)
                raise HTTPException(
                    404, detail={"error": "no_mirror_coverage", "message": str(exc)}
                ) from None
            log.warning("clip REFUSED bbox=%s reason=invalid_bbox: %s", bbox, exc)
            raise HTTPException(
                400, detail={"error": "invalid_bbox", "message": str(exc)}
            ) from None
        except Exception as exc:  # noqa: BLE001 — any clip failure is a finished sentence
            dest.unlink(missing_ok=True)
            log.error("clip FAILED bbox=%s: %s", bbox, exc)
            raise HTTPException(
                500, detail={"error": "clip_failed", "message": str(exc)}
            ) from exc

        body = result.output_path.read_bytes()
        headers = {
            "Content-Disposition": 'attachment; filename="clip.osm.pbf"',
            "X-Plotlines-Clip-Wall-Time-Ms": str(round(result.wall_time_s * 1000)),
            "X-Plotlines-Clip-Output-Bytes": str(result.output_bytes),
            "X-Plotlines-Clip-Source-Regions": ",".join(result.source_regions),
            "X-Plotlines-Clip-Peak-Rss-Kb": (
                str(result.peak_rss_kb) if result.peak_rss_kb is not None else "unknown"
            ),
        }
        return Response(
            content=body,
            media_type="application/octet-stream",
            headers=headers,
            background=BackgroundTask(result.output_path.unlink, missing_ok=True),
        )

    @app.get("/clip", dependencies=[Depends(_enforce_clip_access)])
    def get_clip(
        west: float = Query(...),
        south: float = Query(...),
        east: float = Query(...),
        north: float = Query(...),
    ) -> Response:
        return _run_clip((west, south, east, north))

    @app.post("/clip", dependencies=[Depends(_enforce_clip_access)])
    def post_clip(body: ClipRequestBody) -> Response:
        return _run_clip((body.west, body.south, body.east, body.north))

    @app.get("/health")
    def clip_health() -> dict:
        extracts = discover_region_extracts(root)
        return {
            "ready": True,
            "root": str(root),
            "pinned_extracts": [e.region for e in extracts],
        }

    return app


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="plotlines-mirror-clip")
    parser.add_argument(
        "--host", default="0.0.0.0",
        help="bind address inside the container/host network namespace — "
             "publish only to Caddy's reverse-proxy route at the Docker/"
             "systemd layer, the same posture elevation_proxy.py takes; "
             "this process's own access control is --client-key/"
             "--rate-limit-per-minute below (issue #263), not the bind "
             "address",
    )
    parser.add_argument("--port", type=int, default=8095)
    parser.add_argument(
        "--root", type=Path, required=True,
        help="the mirror tree root (e.g. /srv/plotlines-mirror) holding "
             "MIRROR_STATE.json and osm/geofabrik/<pinned_date>/*.osm.pbf",
    )
    parser.add_argument(
        "--tmp-dir", type=Path, default=None,
        help="scratch directory for merge/clip temp files (default: the "
             "container's own temp dir — nothing here needs to persist "
             "past the request it was written for)",
    )
    parser.add_argument(
        "--client-key", default=os.environ.get("MIRROR_CLIP_CLIENT_KEY"),
        help="shared Plotlines-client key every /clip request must carry "
             "in the X-Plotlines-Client-Key header (issue #263, review "
             "§6.8/1d) — identifies a Plotlines-built client, never a "
             "person or account. Unset (the default) leaves /clip open, "
             "which is correct for local/dev; production sets "
             "MIRROR_CLIP_CLIENT_KEY. The mirror's static files are "
             "unaffected either way — this only ever gates /clip.",
    )
    parser.add_argument(
        "--rate-limit-per-minute", type=int,
        default=int(os.environ.get("MIRROR_CLIP_RATE_LIMIT_PER_MINUTE", "30")),
        help="per-client-IP ceiling on /clip requests per rolling minute "
             "(issue #263) — enforced regardless of --client-key, since "
             "the CPU cost this bounds does not depend on whether a key "
             "is configured. 0 disables the ceiling.",
    )
    parser.add_argument(
        "--log-level", default="info", choices=("debug", "info", "warning", "error")
    )
    args = parser.parse_args(argv)

    configure_logging(None, args.log_level)  # stderr only — container/systemd journal owns capture
    log.info(
        "mirror-clip starting version=%s host=%s port=%s root=%s "
        "client_key_configured=%s rate_limit_per_minute=%s (issue #262/#263, "
        "epic #264 Phase 1.8/1.9 — pyosmium only, no osmium-tool CLI, "
        "addendum L1/1d)",
        VERSION, args.host, args.port, args.root,
        bool(args.client_key), args.rate_limit_per_minute,
    )

    app = create_clip_app(
        args.root,
        tmp_dir=args.tmp_dir,
        client_key=args.client_key,
        rate_limit_per_minute=args.rate_limit_per_minute,
    )
    config = uvicorn.Config(
        app, host=args.host, port=args.port, log_level=args.log_level, access_log=True
    )
    uvicorn.Server(config).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
