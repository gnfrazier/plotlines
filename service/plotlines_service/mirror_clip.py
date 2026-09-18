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
not flagged. Not Phase 3's `CacheLayout`-keyed client cache either — that
one lives on the client, keyed on `(bbox, pin)` against the client's own
disk. This module's `cache_dir` (issue #402) is a *server-side* cache of
the same shape, opt-in and off by default (`cache_dir=None` reproduces
§6.7's original "re-clips on every request, caches nothing" decision
exactly) — added once the wall-time finding below existed to make that
decision a measured tradeoff rather than a default nobody had numbers for.

**Why the wall-time direction changed.** SPIKE-I (#265) measured this
endpoint at 627-640s per request against a ~10x smaller outer band,
because a PBF stores data in id order and a full scan runs regardless of
bbox size — cost is O(pinned extract), not O(trip bbox). #375 (mechanism)
/ #402 (this module's remaining share) address that from two directions:
smaller pinned extracts (`geofabrik_pull.py --precut-wnc-corridor`, which
this module's own `clip_bbox` computes once at pin time) and everything
below — `.poly`-narrowed candidate selection, the disk-backed location
index, and the cache. None of them touch what a `/clip` response actually
contains; every measured number changes, no correctness surface does.

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

**The licence notice travels with the clip (issue #364).** `/clip` is a
second distribution channel alongside the static tree — Caddy's
`reverse_proxy /clip*` matcher terminates before `file_server`, so a caller
here never reads `COPYRIGHT.txt` — and a bbox clip is an extraction, making
its output a *Derivative* Database under ODbL rather than a Produced Work.
Every 200 therefore carries the notice in its own headers. See
`clip_licence_headers`.

**The pin travels with the clip too (issue #274).** `core.graph.
extract_fetch` (Phase 3.2's client-side download) has no way to learn
which Geofabrik pin a clip was cut from except this response — the mirror
never hands a client a region extract to inspect — and it needs that pin
to cache the result under `CacheLayout.osm_extract(bbox, pin)`'s correct
directory (a wrong or missing pin risks caching an extract under a
sibling's name, or not caching it safely at all). Every 200 therefore also
carries `X-Plotlines-Clip-Source-Pin`; see `ClipResult.pin` and
`current_pinned_date`.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import logging
import os
import shutil
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

#: The ODbL notice every `/clip` response carries (issue #364).
#:
#: A clip is an **extraction from** an OSM database, so its output is a
#: *Derivative* Database — not a Produced Work like the basemap archive —
#: and ODbL §4.3 wants the notice to travel with it. `deploy/mirror/
#: COPYRIGHT.txt` states the obligation as attaching to "the distribution
#: channel, not to the presence of a file on disk", and `/clip` is a second
#: channel: Caddy's `reverse_proxy /clip*` matcher terminates the request
#: before `file_server` ever runs, so a consumer that only ever calls
#: `/clip` never reads `osm/COPYRIGHT.txt` at all.
#:
#: Deliberately not routed through `web.about.about_attributions` — that
#: gate covers the *app's* About and export surfaces, and this service is
#: not the app (it never imports `app.py`, by #262's freeze isolation). The
#: notice here is the mirror's own redistribution obligation, the exact
#: parallel of the `COPYRIGHT.txt` files, so it is pinned to that file's
#: wording by `test_mirror_clip_licence_notice.py` rather than to a core
#: constant that serves a different surface.
CLIP_LICENCE_ID = "ODbL-1.0"
#: The canonical credit, matching `osm/COPYRIGHT.txt` and
#: `tiles.mirror.BASEMAP_ATTRIBUTION` byte for byte. JSON-safe, so this is
#: the form `/health` reports and the form any display surface should use.
CLIP_ATTRIBUTION = "© OpenStreetMap contributors"
#: The same credit for an HTTP *header*, where `©` cannot go. RFC 9110
#: field values are US-ASCII; Starlette emits them as latin-1, which makes
#: U+00A9 a byte (0xA9) that is not valid UTF-8 on the wire — a real client
#: decoding headers as UTF-8 fails on it, which is how this was caught here
#: rather than on the Pi. RFC 8187's `field*=UTF-8''…` encoding would carry
#: the glyph, but it buys nothing a reader of a licence notice needs, so the
#: header carries the unambiguous ASCII transliteration and `/health` plus
#: `osm/COPYRIGHT.txt` carry the typographic one.
CLIP_ATTRIBUTION_HEADER = "(c) OpenStreetMap contributors"
CLIP_TERMS_URL = "https://www.openstreetmap.org/copyright"
CLIP_LICENCE_URL = "https://opendatacommons.org/licenses/odbl/1-0/"


def clip_licence_headers() -> dict[str, str]:
    """The notice headers attached to every `/clip` 200.

    `Link: …; rel="license"` is the registered (RFC 8288) way to say this,
    so a generic HTTP client finds it without knowing Plotlines exists; the
    `X-Plotlines-Data-*` group carries the same facts in the parsed-field
    shape the rest of this response already uses (`X-Plotlines-Clip-*`).
    Both, rather than either: the standard header is the one an auditor or
    a third-party tool will look for, and the explicit group is the one
    Phase 3's client can read without parsing a `Link` value.

    Every value here must stay US-ASCII — see `CLIP_ATTRIBUTION_HEADER`.
    """
    return {
        "X-Plotlines-Data-Licence": CLIP_LICENCE_ID,
        "X-Plotlines-Data-Attribution": CLIP_ATTRIBUTION_HEADER,
        "X-Plotlines-Data-Terms": CLIP_TERMS_URL,
        "Link": f'<{CLIP_LICENCE_URL}>; rel="license"',
    }


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


def current_pinned_date(root: Path) -> str | None:
    """`MIRROR_STATE.json`'s `geofabrik.pinned_date` — the one value
    `discover_region_extracts` and `clip_bbox` (for issue #274's
    `X-Plotlines-Clip-Source-Pin` response header) both need, read once
    here rather than each re-parsing the state file. `None` when the state
    file is absent or carries no pin yet."""
    state_path = root / "MIRROR_STATE.json"
    if not state_path.exists():
        return None
    state = load_mirror_state(state_path)
    geofabrik = state.get("geofabrik") or {}
    return geofabrik.get("pinned_date") or None


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
    returns more than one extract.

    Issue #402 (named but left in #375): the header box is a *rectangle*
    around the extract's whole declared coverage, not its real shape — a
    state line runs diagonally, so a query bbox near it routinely sits
    inside both neighbours' rectangular header boxes while only one of them
    actually has data there. `_load_region_boundary` reads the extract's
    real boundary polygon from its sibling `.poly` file (Geofabrik's own
    Osmosis-format cutline, which `geofabrik_pull.py` now also pulls
    alongside the `.osm.pbf`) and narrows the header-box result with an
    actual point-in-polygon / edge-intersection test. This step is
    exclude-only and keeps the same safe-by-default discipline as the
    header box above: no `.poly` file on disk, or one that fails to parse,
    leaves the header box's answer untouched rather than guessing."""
    query_box = _bbox_to_box(bbox)
    kept = []
    for extract in extracts:
        header_box = _header_box(extract.path)
        if header_box is not None and not _boxes_intersect(header_box, query_box):
            continue
        boundary = _load_region_boundary(extract.path)
        if boundary is not None and not _polygon_intersects_bbox(boundary, bbox):
            continue
        kept.append(extract)
    return kept


class InvalidPoly(ValueError):
    """A `.poly` boundary file doesn't parse as the Osmosis polygon-filter
    format Geofabrik publishes for every region
    (https://wiki.openstreetmap.org/wiki/Osmosis/Polygon_Filter_File_Format)."""


def parse_poly(text: str) -> list[list[tuple[float, float]]]:
    """Parses an Osmosis `.poly` boundary file into a list of rings, each a
    list of `(lon, lat)` vertices — the file/polygon name on line 1 is
    ignored, and the file ends with a bare `END`.

    A ring name prefixed with `!` denotes a *hole* (an inner ring to
    subtract) in the true multipolygon; this parser drops hole rings
    entirely rather than subtracting them, so the returned shape is always
    a **superset** of the real one. That keeps `_polygon_intersects_bbox`
    on the same "uncertain coverage is kept, never excluded" side
    `select_covering_extracts` already documents for a missing header box:
    ignoring a hole can only ever make the test return `True` more often,
    never `False` where the truth is `True`. Every region this mirror pins
    today (`north-carolina`, `tennessee`) is a single outer ring with no
    holes; the hole-dropping fallback exists for whatever region is added
    next, not a case observed yet.
    """
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if len(lines) < 4 or lines[-1] != "END":
        raise InvalidPoly("not a well-formed .poly file (missing outer END)")
    rings: list[list[tuple[float, float]]] = []
    i = 1  # line 0 is the file/polygon name, ignored
    while i < len(lines) and lines[i] != "END":
        is_hole = lines[i].startswith("!")
        i += 1
        ring: list[tuple[float, float]] = []
        while i < len(lines) and lines[i] != "END":
            parts = lines[i].split()
            if len(parts) != 2:
                raise InvalidPoly(f"malformed coordinate line: {lines[i]!r}")
            try:
                lon, lat = float(parts[0]), float(parts[1])
            except ValueError as exc:
                raise InvalidPoly(f"malformed coordinate line: {lines[i]!r}") from exc
            ring.append((lon, lat))
            i += 1
        if i >= len(lines):
            raise InvalidPoly("ring not terminated with END")
        i += 1  # consume the ring's own END
        if not is_hole and len(ring) >= 3:
            rings.append(ring)
    if not rings:
        raise InvalidPoly("no outer ring found")
    return rings


def _region_poly_path(pbf_path: Path) -> Path:
    """The sibling `.poly` boundary path for a `<region>.osm.pbf` extract —
    same directory, same region name, `.poly` in place of `.osm.pbf`."""
    name = pbf_path.name
    if name.endswith(".osm.pbf"):
        name = name[: -len(".osm.pbf")]
    return pbf_path.with_name(name + ".poly")


def _load_region_boundary(pbf_path: Path) -> list[list[tuple[float, float]]] | None:
    """The extract's real boundary polygon, from its sibling `.poly` file —
    `None` when that file is absent (an older pin, from before this
    feature, or a region `geofabrik_pull.py` couldn't fetch one for — see
    its `_fetch_poly`) or fails to parse. Both collapse to the same
    'unknown coverage' case `select_covering_extracts` already treats as
    safe-to-include, never safe-to-exclude."""
    poly_path = _region_poly_path(pbf_path)
    if not poly_path.exists():
        return None
    try:
        return parse_poly(poly_path.read_text())
    except (InvalidPoly, OSError, UnicodeDecodeError) as exc:
        log.warning("region boundary %s failed to parse: %s", poly_path, exc)
        return None


def _point_in_ring(x: float, y: float, ring: list[tuple[float, float]]) -> bool:
    """Standard ray-casting point-in-polygon test against one ring."""
    inside = False
    x1, y1 = ring[-1]
    for x2, y2 in ring:
        if (y1 > y) != (y2 > y):
            x_at_y = (x2 - x1) * (y - y1) / (y2 - y1) + x1
            if x < x_at_y:
                inside = not inside
        x1, y1 = x2, y2
    return inside


def _ccw(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float]) -> float:
    return (c[1] - a[1]) * (b[0] - a[0]) - (b[1] - a[1]) * (c[0] - a[0])


def _on_segment(
    a: tuple[float, float], b: tuple[float, float], p: tuple[float, float]
) -> bool:
    return min(a[0], b[0]) <= p[0] <= max(a[0], b[0]) and min(a[1], b[1]) <= p[1] <= max(
        a[1], b[1]
    )


def _segments_intersect(
    p1: tuple[float, float],
    p2: tuple[float, float],
    p3: tuple[float, float],
    p4: tuple[float, float],
) -> bool:
    d1, d2 = _ccw(p3, p4, p1), _ccw(p3, p4, p2)
    d3, d4 = _ccw(p1, p2, p3), _ccw(p1, p2, p4)
    if ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0)) and d1 != 0 and d2 != 0:
        return True
    # Collinear/touching cases are treated as intersecting — the safe
    # (keep, don't exclude) side of any ambiguity here.
    if d1 == 0 and _on_segment(p3, p4, p1):
        return True
    if d2 == 0 and _on_segment(p3, p4, p2):
        return True
    if d3 == 0 and _on_segment(p1, p2, p3):
        return True
    if d4 == 0 and _on_segment(p1, p2, p4):
        return True
    return False


def _polygon_intersects_bbox(
    rings: list[list[tuple[float, float]]], bbox: BBox
) -> bool:
    """Whether the union of `rings` (a parsed `.poly` boundary, hole rings
    already dropped by `parse_poly`) intersects `bbox` at all — a plain
    planar test (no antimeridian handling), matching `_boxes_intersect`'s
    existing treatment of every bbox in this codebase as (west, south,
    east, north) degrees. Three cases cover every way two simple polygons
    can touch: a boundary vertex inside the bbox, a bbox corner inside the
    boundary, or an edge of one crossing an edge of the other (the case
    that catches a boundary passing straight through a bbox without either
    shape containing any of the other's vertices)."""
    west, south, east, north = bbox
    corners = [(west, south), (east, south), (east, north), (west, north)]
    bbox_edges = list(zip(corners, corners[1:] + corners[:1]))
    for ring in rings:
        for x, y in ring:
            if west <= x <= east and south <= y <= north:
                return True
        for corner in corners:
            if _point_in_ring(corner[0], corner[1], ring):
                return True
        n = len(ring)
        for i in range(n):
            r1, r2 = ring[i], ring[(i + 1) % n]
            for b1, b2 in bbox_edges:
                if _segments_intersect(r1, r2, b1, b2):
                    return True
    return False


def _merge_extracts(paths: list[Path], dest: Path) -> None:
    """Combine already-clipped outputs into one id-deduplicated, correctly-
    ordered stream, so a border way present (whole) in both regional cuts is
    written once, not twice. `osmium.MergeInputReader` is pyosmium's own
    `osmium merge` equivalent — still pyosmium's Python API, not the CLI
    (L1).

    Issue #376: `paths` must be small, already-clipped bbox outputs, never
    raw region extracts — `MergeInputReader.add_file` buffers every object
    from every input **in memory** before writing anything, and two full
    Geofabrik state extracts (hundreds of MB each) expand to several GB of
    in-memory objects, which is what killed the process in ~9s on the Pi.
    `clip_bbox` below only ever calls this on the small (~3-6 MB) per-
    extract clip outputs, not on `RegionExtract.path` directly."""
    reader = osmium.MergeInputReader()
    for path in paths:
        reader.add_file(str(path))
    with osmium.SimpleWriter(str(dest), overwrite=True) as writer:
        reader.apply(writer, simplify=True)


def _stamp_header_box(dest: Path, bbox: BBox, *, tmp_dir: Path) -> None:
    """Defect found live on the Pi while validating #402's precut fix,
    fixed here because it undermines this same PR's over-selection fix:
    neither `osmium.BackReferenceWriter` (the single-extract path) nor
    `_merge_extracts`'s `MergeInputReader`/`SimpleWriter` (the multi-extract
    path) sets a header box on `dest` — confirmed by reading back a real
    clip's header on the live mirror and finding it `invalid`. That silently
    disables `_header_box`'s fast exclude test for *any* clip this module
    produces that later gets pinned as a source extract — exactly what
    `precut_region` does. A live coverage-miss bbox nowhere near the WNC
    corridor was measured taking 100+ seconds (a full scan of the 97 MB
    precut extract) before correctly 404ing, instead of failing in
    milliseconds, because `select_covering_extracts` had to fall back to
    'unknown coverage, keep' with no header box to exclude on — and a
    `.poly` file doesn't cover this case either, since `precut_region`
    never writes one for its synthetic `dest_region`.

    Re-reads `dest` and rewrites it with `bbox` (the exact box actually
    requested, never a looser one) stamped as its header — one extra pass
    over this clip's own *output*, not its source, so the cost is
    proportional to what this request already produced rather than to
    whatever it scanned to produce it. Uses the same `MergeInputReader` /
    `SimpleWriter` pattern `_merge_extracts` already relies on (a single-
    file "merge" is just a copy with a new header)."""
    fd, tmp_name = tempfile.mkstemp(
        dir=tmp_dir, prefix=".mirror-clip-header-", suffix=".osm.pbf"
    )
    os.close(fd)
    tmp_path = Path(tmp_name)
    tmp_path.unlink()  # mkstemp creates it; SimpleWriter needs the name free
    header = osmium.io.Header()
    west, south, east, north = bbox
    header.add_box(osmium.osm.Box(west, south, east, north))
    reader = osmium.MergeInputReader()
    reader.add_file(str(dest))
    with osmium.SimpleWriter(str(tmp_path), header=header, overwrite=True) as writer:
        reader.apply(writer, simplify=True)
    os.replace(tmp_path, dest)


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


def _select_and_write(bbox: BBox, source: Path, dest: Path, *, tmp_dir: Path) -> int:
    """Issue #402 (`BackReferenceWriter` memory, named but left in #375):
    `apply_file`'s location index defaults to `idx="flex_mem"`, an
    in-process hash map — on the Colorado extract SPIKE-I measured
    `complete_ways` peaking at 2,842 MB with it. Switching to
    `sparse_file_array` (a disk-backed table, written to `tmp_dir` so it
    never lands on a `tmpfs`-mounted `/tmp`) measured 1,770 MB on the same
    extract with identical output — the location table's memory is a
    real, available reduction with no correctness or wall-time cost
    (RESULTS.md §3.3).

    This is **not** the fix for the dominant cost. SPIKE-I found ~77% of
    `complete_ways`' memory is `BackReferenceWriter`'s own second pass, not
    the location table, and pyosmium's public API has no lever for that
    pass itself: `dense_file_array` fails outright here (it allocates
    across the whole OSM id range) and `smart`'s relation-closure pass
    costs +54% wall time for exactly one extra node at trip-bbox scale. So
    this is the real, measured reduction that *is* available — not a full
    fix for the direction #402 names, which stays open pending a pyosmium
    API this module doesn't have today."""
    box = _bbox_to_box(bbox)
    fd, index_name = tempfile.mkstemp(
        dir=tmp_dir, prefix=".mirror-clip-locidx-", suffix=".dat"
    )
    os.close(fd)
    index_path = Path(index_name)
    index_path.unlink()  # sparse_file_array creates its own backing file
    try:
        with osmium.BackReferenceWriter(
            str(dest), str(source), overwrite=True, remove_tags=False
        ) as writer:
            selector = _CompleteWaysSelector(writer, box)
            selector.apply_file(
                str(source), locations=True, idx=f"sparse_file_array,{index_path}"
            )
        return selector.selected_count
    finally:
        index_path.unlink(missing_ok=True)


@dataclass(frozen=True)
class ClipResult:
    output_path: Path
    wall_time_s: float
    output_bytes: int
    #: `ru_maxrss` under `RUSAGE_SELF` at the moment this clip finished — a
    #: **process-lifetime** watermark, not a per-clip figure (issue #374):
    #: it never decreases, so on a long-lived service every clip after the
    #: largest one reports that one's number. Useful as "how much memory has
    #: this process ever needed," not as this clip's own cost — that's
    #: `clip_rss_delta_kb` below.
    service_peak_rss_kb: int | None
    #: `service_peak_rss_kb` sampled before this clip started, subtracted
    #: from the value after — issue #374's "measure the delta" option. Since
    #: `ru_maxrss` only ever increases, this is always >= 0, and it is
    #: **honest about its own limit**: a clip that doesn't push the process
    #: watermark any higher than a previous, larger clip already did reports
    #: 0 here, rather than inheriting that earlier clip's number under this
    #: clip's name. 0 means "no new high water reached," not "no memory
    #: used."
    clip_rss_delta_kb: int | None
    source_regions: tuple[str, ...]
    #: The Geofabrik pin (`MIRROR_STATE.json`'s `geofabrik.pinned_date`) the
    #: source extract(s) were pulled at — issue #274: the client needs this
    #: to cache the clip under `CacheLayout.osm_extract(bbox, pin)`'s
    #: correct pin directory, and has no other way to learn it (the mirror
    #: never returns a region extract for the client to inspect itself).
    #: Carried on the response as `X-Plotlines-Clip-Source-Pin`. `None` only
    #: if the pin vanished from `MIRROR_STATE.json` between
    #: `discover_region_extracts` finding a covering extract and this
    #: result being built — the extract files themselves don't move, but
    #: nothing prevents a concurrent pin bump from rewriting the state file
    #: mid-request.
    pin: str | None
    #: Issue #402 (clip cache, deliberately excluded at #262's original
    #: scope). `True` when this result was served from `cache_dir` rather
    #: than computed — `wall_time_s`/`clip_rss_delta_kb` are then the
    #: retrieval cost, not a real clip's, so a telemetry consumer must not
    #: average them together with an uncached clip's numbers.
    cache_hit: bool = False


def _current_rss_kb() -> int | None:
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss if resource else None


def _cache_key(bbox: BBox) -> str:
    """Stable across the exact same bbox floats only — deliberately not a
    quantized/rounded key. Two callers who mean "the same" bbox but arrive
    at slightly different floats miss the cache and get reclipped, which
    is always correct; a fuzzy key would trade that for the risk of ever
    treating two different bboxes as the same cached answer."""
    canonical = ",".join(repr(v) for v in bbox)
    return hashlib.sha256(canonical.encode()).hexdigest()[:24]


def _cache_paths(cache_dir: Path, pin: str, bbox: BBox) -> tuple[Path, Path]:
    key = _cache_key(bbox)
    pin_dir = cache_dir / pin
    return pin_dir / f"{key}.pbf", pin_dir / f"{key}.json"


def _read_cache(cache_dir: Path, pin: str, bbox: BBox, dest: Path) -> ClipResult | None:
    """A hit copies the cached bytes to `dest` and reports the copy itself
    as this call's (near-zero) wall time — `ClipResult.cache_hit=True`
    keeps that from being mistaken for a real scan's cost. Returns `None`
    on any miss, or on a cache entry that fails to read back cleanly, so a
    damaged cache degrades to "always miss" rather than failing the
    request the cache exists to make cheaper."""
    cached_pbf, cached_meta = _cache_paths(cache_dir, pin, bbox)
    if not cached_pbf.exists() or not cached_meta.exists():
        return None
    started = time.monotonic()
    try:
        meta = json.loads(cached_meta.read_text())
        source_regions = tuple(meta["source_regions"])
        shutil.copyfile(cached_pbf, dest)
        cached_pbf.touch()  # LRU freshness for _evict_cache
    except (OSError, ValueError, KeyError, TypeError) as exc:
        log.warning("clip cache read failed for %s (treating as a miss): %s", cached_pbf, exc)
        return None
    return ClipResult(
        output_path=dest,
        wall_time_s=time.monotonic() - started,
        output_bytes=dest.stat().st_size,
        service_peak_rss_kb=_current_rss_kb(),
        clip_rss_delta_kb=0,
        source_regions=source_regions,
        pin=pin,
        cache_hit=True,
    )


def _write_cache(
    cache_dir: Path, pin: str, bbox: BBox, result: ClipResult, max_bytes: int
) -> None:
    """Stores a freshly-computed `result` into the cache and evicts down to
    `max_bytes` afterward. Best-effort: any failure here is logged and
    swallowed rather than raised — a cache-write problem must never turn an
    otherwise-successful clip into a failed request."""
    cached_pbf, cached_meta = _cache_paths(cache_dir, pin, bbox)
    try:
        cached_pbf.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=cached_pbf.parent, prefix=".cache-")
        os.close(fd)
        shutil.copyfile(result.output_path, tmp_name)
        os.replace(tmp_name, cached_pbf)
        cached_meta.write_text(json.dumps({"source_regions": list(result.source_regions)}))
    except OSError as exc:
        log.warning("clip cache write failed for %s (serving uncached): %s", cached_pbf, exc)
        return
    _evict_cache(cache_dir, max_bytes)


def _evict_cache(cache_dir: Path, max_bytes: int) -> None:
    """Oldest-mtime-first eviction once the cache's total `.pbf` bytes
    exceed `max_bytes` (0 disables the ceiling). Not race-free under
    concurrent writers — `create_clip_app`'s handlers run in FastAPI's
    thread pool even though the process itself stays single (see the
    module docstring's concurrency note) — but the failure mode of losing
    that race is a transient overshoot or a redundant eviction, never
    wrong data: a missing cache entry only ever produces a cache miss."""
    if max_bytes <= 0:
        return
    entries = sorted(cache_dir.glob("*/*.pbf"), key=lambda p: p.stat().st_mtime)
    total = sum(p.stat().st_size for p in entries)
    for p in entries:
        if total <= max_bytes:
            break
        total -= p.stat().st_size
        p.unlink(missing_ok=True)
        p.with_suffix(".json").unlink(missing_ok=True)


def clip_bbox(
    bbox: BBox,
    *,
    root: Path,
    dest: Path,
    tmp_dir: Path | None = None,
    cache_dir: Path | None = None,
    cache_max_bytes: int = 0,
) -> ClipResult:
    """The one endpoint's whole job: bbox in, clipped `.osm.pbf` at `dest`
    out. Raises `NoMirrorCoverage` (acceptance criterion 5) when nothing
    pinned on this mirror covers `bbox` — either because no extract's
    declared coverage overlaps it, or because a clip against the extracts
    that might have produced literally nothing.

    Issue #402 (clip cache, deliberately excluded at #262's original scope:
    "this service re-clips on every request and caches nothing, because
    doing less is exactly what 'the mirror stays dumb' asks for at this
    phase" — a decision made before the wall-time finding existed).
    `cache_dir=None` (the default) reproduces that original behaviour
    exactly. When given, a cache lookup runs first, keyed on `(pin, bbox)`
    read from `MIRROR_STATE.json` **before** any extract is touched — the
    same early-pin-read tradeoff `discover_region_extracts` already makes
    elsewhere in this function, so a pin bump mid-request costs at most a
    redundant cache miss, never a wrong-pin hit."""
    validate_bbox(bbox)
    started = time.monotonic()
    started_rss_kb = _current_rss_kb()

    if cache_dir is not None:
        cache_pin = current_pinned_date(root)
        if cache_pin is not None:
            cached = _read_cache(cache_dir, cache_pin, bbox, dest)
            if cached is not None:
                log.info(
                    "clip bbox=%s pin=%s cache_hit=true output_bytes=%d",
                    bbox, cache_pin, cached.output_bytes,
                )
                return cached

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

    if len(candidates) == 1:
        selected = _select_and_write(bbox, candidates[0].path, dest, tmp_dir=tmp_dir)
    else:
        # Issue #376: clip each covering extract *first*, then merge the
        # small clipped outputs — never merge the raw extracts. The old
        # order ran `MergeInputReader` over the full multi-hundred-MB
        # Geofabrik extracts, which buffers every object from every input in
        # memory before writing anything; for a real NC+TN pair that was
        # ~3.9 GB in five seconds and the OOM killer took the process in
        # ~9s. A clipped output is ~3-6 MB, so merging *those* costs nothing
        # by comparison — the inversion the issue calls "obvious."
        log.info(
            "clip bbox=%s spans %d extracts (%s) — clipping each before merging",
            bbox, len(candidates), ", ".join(c.region for c in candidates),
        )
        partial_paths: list[Path] = []
        selected = 0
        try:
            for candidate in candidates:
                fd, partial_name = tempfile.mkstemp(
                    dir=tmp_dir, prefix=".mirror-clip-partial-", suffix=".osm.pbf"
                )
                os.close(fd)
                partial_path = Path(partial_name)
                partial_path.unlink()  # BackReferenceWriter refuses an existing file
                count = _select_and_write(
                    bbox, candidate.path, partial_path, tmp_dir=tmp_dir
                )
                selected += count
                if count > 0:
                    partial_paths.append(partial_path)
                else:
                    partial_path.unlink(missing_ok=True)

            if len(partial_paths) == 1:
                # The common over-selection case (e.g. a WNC bbox matching
                # both NC's and TN's header box while only NC actually has
                # data there): nothing to merge, and no second full pass.
                partial_paths[0].replace(dest)
                partial_paths.clear()
            elif len(partial_paths) > 1:
                _merge_extracts(partial_paths, dest)
        finally:
            for partial_path in partial_paths:
                partial_path.unlink(missing_ok=True)

    if selected == 0:
        dest.unlink(missing_ok=True)
        checked = ", ".join(c.region for c in candidates)
        raise NoMirrorCoverage(
            f"bbox {bbox} matched no feature in the mirrored extract(s) "
            f"({checked}) it might have overlapped"
        )

    _stamp_header_box(dest, bbox, tmp_dir=tmp_dir)

    wall_time_s = time.monotonic() - started
    service_peak_rss_kb = _current_rss_kb()
    clip_rss_delta_kb = (
        service_peak_rss_kb - started_rss_kb
        if service_peak_rss_kb is not None and started_rss_kb is not None
        else None
    )
    log.info(
        "clip bbox=%s sources=%s wall_time_s=%.2f output_bytes=%d "
        "service_peak_rss_kb=%s clip_rss_delta_kb=%s",
        bbox, [c.region for c in candidates], wall_time_s, dest.stat().st_size,
        service_peak_rss_kb, clip_rss_delta_kb,
    )
    result = ClipResult(
        output_path=dest,
        wall_time_s=wall_time_s,
        output_bytes=dest.stat().st_size,
        service_peak_rss_kb=service_peak_rss_kb,
        clip_rss_delta_kb=clip_rss_delta_kb,
        source_regions=tuple(c.region for c in candidates),
        pin=current_pinned_date(root),
    )
    # Store under the pin actually used for this clip (re-read just above,
    # not the early cache_pin) — the two only ever differ across a mid-
    # request pin bump, and storing under the freshly-read one keeps a
    # cache entry always attributable to the extracts that produced it.
    if cache_dir is not None and result.pin is not None:
        _write_cache(cache_dir, result.pin, bbox, result, cache_max_bytes)
    return result


# --------------------------------------------------------------------------
# HTTP layer
# --------------------------------------------------------------------------

#: Issue #263 — the shared Plotlines-client key every restricted `/clip`
#: request carries. Named as a module constant so a future client-side
#: caller (Phase 3, #272) has one spelling to import rather than a string
#: to copy.
CLIENT_KEY_HEADER = "X-Plotlines-Client-Key"


def normalize_client_key(raw: str | None) -> str | None:
    """Issue #371: collapse "no key configured" onto exactly one value.

    `deploy/mirror/docker-compose.yml` passes
    `MIRROR_CLIP_CLIENT_KEY=${MIRROR_CLIP_CLIENT_KEY:-}`, so an operator
    who leaves the variable unset — the documented default, and the one
    `--client-key --help` calls "leaves /clip open" — does not get an
    absent variable. Compose sets it to the empty string, `os.environ.get`
    returns `""` rather than `None`, and an `is not None` test arms the
    gate with a key no honest caller can present: 401 for everyone, while
    `hmac.compare_digest("", "")` would let a caller sending the header
    with an empty value straight through. Both halves of that come from
    treating `""` as a configured key, so it is fixed here once rather
    than at each reader.

    Whitespace is stripped for the same class of reason one step further
    out: a key sourced from a file or a heredoc arrives with a trailing
    newline attached, which is a deployment accident every time and a
    deliberate key never.

    Idempotent, so applying it at both the argparse and the app-
    construction boundary is safe.
    """
    if raw is None:
        return None
    return raw.strip() or None


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
    cache_dir: Path | None = None,
    cache_max_bytes: int = 0,
) -> FastAPI:
    app = FastAPI(title="plotlines-mirror-clip", version=VERSION)
    work_dir = Path(tmp_dir) if tmp_dir else Path(tempfile.gettempdir())
    work_dir.mkdir(parents=True, exist_ok=True)
    rate_limiter = _RateLimiter(rate_limit_per_minute, time_fn=rate_limit_time_fn)
    configured_key = normalize_client_key(client_key)

    def _enforce_clip_access(request: Request) -> None:
        """Issue #263: gate the one CPU-costing endpoint, not the static
        files. Client-key check only runs when a key is configured (unset
        — or empty, per #371's `normalize_client_key` — means open, the
        correct default for local/dev and these hermetic tests); the rate
        ceiling always runs, since the cost it bounds does not depend on
        whether a key is configured."""
        if configured_key is not None:
            presented = request.headers.get(CLIENT_KEY_HEADER)
            if presented is None or not hmac.compare_digest(presented, configured_key):
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
            result = clip_bbox(
                bbox, root=root, dest=dest, tmp_dir=work_dir,
                cache_dir=cache_dir, cache_max_bytes=cache_max_bytes,
            )
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

        if result.pin is None:
            # Issue #274: the client keys its cache on this pin and has no
            # other way to learn it — a response with no pin is unsafe to
            # cache, not merely incomplete. Rare: only a `MIRROR_STATE.json`
            # rewrite landing between `discover_region_extracts` and here
            # (a pin bump mid-request) produces it.
            result.output_path.unlink(missing_ok=True)
            log.error("clip FAILED bbox=%s: source pin vanished mid-request", bbox)
            raise HTTPException(
                500,
                detail={
                    "error": "clip_failed",
                    "message": "the mirror's pin changed while preparing this "
                                "clip — try again",
                },
            )

        body = result.output_path.read_bytes()
        headers = {
            "Content-Disposition": 'attachment; filename="clip.osm.pbf"',
            "X-Plotlines-Clip-Wall-Time-Ms": str(round(result.wall_time_s * 1000)),
            "X-Plotlines-Clip-Output-Bytes": str(result.output_bytes),
            "X-Plotlines-Clip-Source-Regions": ",".join(result.source_regions),
            "X-Plotlines-Clip-Source-Pin": result.pin,
            # Issue #374: renamed from `X-Plotlines-Clip-Peak-Rss-Kb` because
            # it is a process-lifetime watermark, not a per-clip figure — see
            # `ClipResult.service_peak_rss_kb`. `Clip-Rss-Delta-Kb` is the new,
            # honestly-imperfect per-clip figure the rename makes room for.
            "X-Plotlines-Service-Peak-Rss-Kb": (
                str(result.service_peak_rss_kb)
                if result.service_peak_rss_kb is not None else "unknown"
            ),
            "X-Plotlines-Clip-Rss-Delta-Kb": (
                str(result.clip_rss_delta_kb)
                if result.clip_rss_delta_kb is not None else "unknown"
            ),
            # Issue #402: a cache hit's wall-time/RSS headers above measure
            # the cache retrieval, not a real clip — this is how a caller or
            # a bench harness tells the two apart rather than averaging them.
            "X-Plotlines-Clip-Cache-Hit": "true" if result.cache_hit else "false",
            **clip_licence_headers(),
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
            # Issue #364 — what this service serves is ODbL-licensed, and an
            # operator probing /health should be able to see that the notice
            # is wired rather than having to fetch a clip to find out.
            "licence": {
                "licence": CLIP_LICENCE_ID,
                "attribution": CLIP_ATTRIBUTION,
                "terms_url": CLIP_TERMS_URL,
                "licence_url": CLIP_LICENCE_URL,
            },
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
             "person or account. Unset — or set to an empty/whitespace "
             "value, which is what docker-compose.yml's "
             "${MIRROR_CLIP_CLIENT_KEY:-} expands to when the operator "
             "sets nothing (#371) — leaves /clip open, which is correct "
             "for local/dev; production sets "
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
    _cache_dir_env = os.environ.get("MIRROR_CLIP_CACHE_DIR")
    parser.add_argument(
        "--cache-dir", type=Path,
        default=(Path(_cache_dir_env) if _cache_dir_env else None),
        help="issue #402: cache clip outputs here, keyed on (pin, bbox), "
             "instead of re-scanning an identical request. Unset (the "
             "default) reproduces #262's original 'stays dumb, caches "
             "nothing' behaviour exactly. Deliberately outside --root — "
             "this is derived, disposable state, not part of the mirror's "
             "static tree.",
    )
    parser.add_argument(
        "--cache-max-bytes", type=int,
        default=int(os.environ.get("MIRROR_CLIP_CACHE_MAX_BYTES", "0")),
        help="oldest-entry-first eviction ceiling for --cache-dir's total "
             "size, in bytes. 0 (the default) disables eviction — fine "
             "given the corridor-precut extract's few-MB clips, but an "
             "operator pinning a much larger area should set one.",
    )
    parser.add_argument(
        "--log-level", default="info", choices=("debug", "info", "warning", "error")
    )
    args = parser.parse_args(argv)

    # #371: normalise before the log line, not just before create_clip_app.
    # The two disagreeing is what hid this bug on the Pi — the log reported
    # `bool("")` as client_key_configured=False while the gate was armed and
    # 401-ing every request, so the one diagnostic an operator reaches for
    # denied the thing that was happening.
    client_key = normalize_client_key(args.client_key)

    configure_logging(None, args.log_level)  # stderr only — container/systemd journal owns capture
    log.info(
        "mirror-clip starting version=%s host=%s port=%s root=%s "
        "client_key_configured=%s rate_limit_per_minute=%s (issue #262/#263, "
        "epic #264 Phase 1.8/1.9 — pyosmium only, no osmium-tool CLI, "
        "addendum L1/1d)",
        VERSION, args.host, args.port, args.root,
        bool(client_key), args.rate_limit_per_minute,
    )

    app = create_clip_app(
        args.root,
        tmp_dir=args.tmp_dir,
        client_key=client_key,
        rate_limit_per_minute=args.rate_limit_per_minute,
        cache_dir=args.cache_dir,
        cache_max_bytes=args.cache_max_bytes,
    )
    config = uvicorn.Config(
        app, host=args.host, port=args.port, log_level=args.log_level, access_log=True
    )
    uvicorn.Server(config).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
