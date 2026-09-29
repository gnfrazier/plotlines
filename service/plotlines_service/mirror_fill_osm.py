"""The OSM layer's fill — issue #518 (epic #516, ARCH D67).

A `/clip` miss inside a Geofabrik-published region stops being a final
`404` and becomes a fill: pull the covering Geofabrik region(s) under
`geofabrik_pull.py`'s own rules, precut the grid cell the trip sits in, and
publish the cell as a pinned extract `/clip` then reads.

**The precut unit is a 1° grid cell** — measured, not assumed (#518; the
numbers and the choice are recorded there and in `deploy/mirror/README.md`).
Three candidates were on the table:

- (c) *the whole state* — `/clip` cost is O(pinned extract): 617 s for
  full-state North Carolina on the Pi (#402), ~10× SPIKE-I's band. Out.
- (b) *the trip bbox plus a buffer* — the fastest clip afterwards, but the
  precut itself is a full scan of the state (~450–1,675 s per cut on the
  Pi, #530's log), paid again for every trip that falls outside the last
  buffer. Nothing is reused.
- (a) *a fixed grid cell* — the same full-state scan once per cell, then
  every later trip inside it reuses the cell. Measured on the Pi for a
  Greensboro trip bbox: against #530's **2°** cell (118 MB) the clip took
  **166.6 s**; against a **1°** cell cut from the same data (43 MB) it took
  **54.8 s** — inside SPIKE-I's ≤60 s outer band — and 70.9 s for a trip
  three times the size. The precut costs one full-state scan either way, so
  the smaller cell costs nothing extra per fill and a third per clip.

Fill cells are named `cell-1d-wNNN-nNN` and cover the whole square. The
grid nests inside #530's 2° one, so a filled cell never straddles a seeded
`priority-…` cell's edge; a filled cell supersedes a `priority-…` cell whose
clamped extent it contains (the file stays on disk, as #530's own supersede
does). #530's cells stay 2° until they are re-cut with
`--precut-cell-degrees 1`.

**Etiquette is `geofabrik_pull.py`'s, not a second copy of it** (§6.6,
addendum P5): every Geofabrik request goes through `pull_region` — the
at-most-daily cadence, the `.md5` check before any body, the Plotlines
`User-Agent`, verify-before-publish, backoff, and #530's two-minute spacing
between requests. A region already on disk and checked inside 24 h makes no
request at all, so two fills in one state inside a day issue one download.
Sources are recorded under `geofabrik.fill_sources`, never
`geofabrik.regions`: registered, a full-state file would be scanned whole
by every `/clip` that touches it, which is the cost the cell exists to
avoid.

**Coverage is decided locally.** `plan` reads the mirrored `index-v1.json`
(#259) and the `areas` record — no request. A bbox no Geofabrik leaf region
reaches is `no_upstream_coverage` with no job.
"""

from __future__ import annotations

import importlib.util
import json
import logging
import math
import shutil
import sys
import tempfile
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Mapping

from .mirror_fill import (
    STAGING_PREFIX,
    AreaPlan,
    FillContext,
    FillFailed,
    FilledArea,
    FillPlan,
    NoUpstreamCoverageError,
    StoreBook,
)

log = logging.getLogger("plotlines.mirror_fill.osm")

BBox = tuple[float, float, float, float]

LAYER = "osm"

#: The precut unit, in degrees — see the module docstring for the Pi
#: measurement that chose it over #530's 2°. Nests inside that 2° grid.
CELL_DEGREES = 1.0

CELL_PREFIX = "cell-"

#: `geofabrik_pull.py` lives beside the mirror tree, not in this package —
#: it is deployed as a standalone stdlib script. The container copies it to
#: the same relative place (`service/Dockerfile.mirror-clip`).
_PULL_SCRIPT = Path(__file__).resolve().parents[2] / "deploy" / "mirror" / "geofabrik_pull.py"


def load_geofabrik_pull(path: Path = _PULL_SCRIPT):
    """The pull script as a module — one set of etiquette, not two."""
    name = "geofabrik_pull"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:  # pragma: no cover - deploy error
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclass() needs this at import time
    spec.loader.exec_module(module)
    return module


def cell_name(i: int, j: int, degrees: float = CELL_DEGREES) -> str:
    """`cell-1d-w080-n36`: the size is in the name, because two layers
    fill on different grids (#519's basemap cells are 2°) and a name should
    never mean two pieces of ground."""
    west, south = i * degrees, j * degrees
    ew = "w" if west < 0 else "e"
    ns = "s" if south < 0 else "n"
    return (f"{CELL_PREFIX}{degrees:g}d-{ew}{abs(round(west)):03d}-"
            f"{ns}{abs(round(south)):02d}")


def cells_for(bbox: BBox, degrees: float = CELL_DEGREES) -> list[tuple[str, BBox, BBox]]:
    """`(name, square, piece)` for every grid square `bbox` has area in —
    `piece` is the part of `bbox` inside the square. A bbox that only
    touches a square's edge does not reach into it."""
    west, south, east, north = bbox
    out = []
    for i in range(math.floor(west / degrees), math.ceil(east / degrees)):
        for j in range(math.floor(south / degrees), math.ceil(north / degrees)):
            square = (i * degrees, j * degrees, (i + 1) * degrees, (j + 1) * degrees)
            piece = (max(west, square[0]), max(south, square[1]),
                     min(east, square[2]), min(north, square[3]))
            if piece[0] >= piece[2] or piece[1] >= piece[3]:
                continue
            out.append((cell_name(i, j, degrees), square, piece))
    return out


def _contains(outer, inner) -> bool:
    return (outer[0] <= inner[0] and outer[1] <= inner[1]
            and outer[2] >= inner[2] and outer[3] >= inner[3])


def _intersects(a, b) -> bool:
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


# --------------------------------------------------------------------------
# index-v1.json
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class GeofabrikRegion:
    """One leaf of Geofabrik's index: `path` is the download path
    `pull_region` takes (`north-america/us/north-carolina`)."""

    id: str
    path: str
    bbox: BBox
    rings: tuple[tuple[tuple[float, float], ...], ...]


def _region_path(pbf_url: str) -> str | None:
    marker = "download.geofabrik.de/"
    if marker not in pbf_url or not pbf_url.endswith("-latest.osm.pbf"):
        return None
    return pbf_url.split(marker, 1)[1][: -len("-latest.osm.pbf")]


def parse_index(index: dict) -> list[GeofabrikRegion]:
    """The index's leaf regions — a region with a child is never a fill
    source; its children are smaller and cover the same ground."""
    features = index.get("features") or []
    parents = {(f.get("properties") or {}).get("parent") for f in features}
    regions = []
    for f in features:
        props = f.get("properties") or {}
        rid = props.get("id")
        if not rid or rid in parents:
            continue
        path = _region_path((props.get("urls") or {}).get("pbf", ""))
        geom = f.get("geometry") or {}
        if path is None or geom.get("type") not in ("Polygon", "MultiPolygon"):
            continue
        polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
        rings = tuple(tuple((float(x), float(y)) for x, y, *_ in poly[0]) for poly in polys if poly)
        if not rings:
            continue
        xs = [x for r in rings for x, _ in r]
        ys = [y for r in rings for _, y in r]
        regions.append(GeofabrikRegion(rid, path, (min(xs), min(ys), max(xs), max(ys)), rings))
    return regions


def covering_regions(regions: list[GeofabrikRegion], bbox: BBox) -> list[GeofabrikRegion]:
    """The smallest leaf regions whose real outline reaches `bbox`.

    Geofabrik's leaves overlap: `us` and `us-south` have no children (the
    states hang off `north-america`), so they are leaves too, and a
    Greensboro bbox reaches `us`, `us-south` and `us/north-carolina`. A
    candidate whose bounding box contains another candidate's is dropped —
    the smaller one covers that ground with fewer bytes to scan."""
    from .mirror_clip import _polygon_intersects_bbox

    hits = [r for r in regions
            if _intersects(r.bbox, bbox)
            and _polygon_intersects_bbox([list(ring) for ring in r.rings], bbox)]
    return sorted(
        (r for r in hits
         if not any(o is not r and _contains(r.bbox, o.bbox) and r.bbox != o.bbox for o in hits)),
        key=lambda r: r.path)


# --------------------------------------------------------------------------
# The filler
# --------------------------------------------------------------------------


class OsmFiller:
    """`LayerFiller` for the OSM layer. `pull` is `geofabrik_pull`'s module
    (injectable for tests); `throttle` is one `RequestThrottle` shared by
    every fill this worker runs, so the spacing holds between fills too."""

    layer = LAYER
    #: A fill is a Geofabrik `.md5` check, maybe a body, a `.poly`, two
    #: minutes apart, then a full-state scan: minutes, not seconds.
    retry_hint_s = 30

    def __init__(
        self,
        root: Path,
        *,
        pull=None,
        base_url: str | None = None,
        request_spacing: timedelta | None = None,
        now=None,
    ):
        self.root = Path(root)
        self.pull = pull or load_geofabrik_pull()
        self.base_url = base_url or self.pull.DEFAULT_BASE_URL
        spacing = self.pull.DEFAULT_REQUEST_SPACING if request_spacing is None else request_spacing
        self.throttle = self.pull.RequestThrottle(spacing)
        self.book = StoreBook(self.root)
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._index_lock = threading.Lock()
        self._index_cache: tuple[Path, float, list[GeofabrikRegion]] | None = None

    # -- local reads -------------------------------------------------------

    def _state(self) -> dict:
        try:
            return json.loads((self.root / "MIRROR_STATE.json").read_text())
        except (FileNotFoundError, ValueError):
            return {}

    def _pin(self, state: dict) -> str | None:
        return (state.get("geofabrik") or {}).get("pinned_date")

    def index_regions(self) -> list[GeofabrikRegion] | None:
        """The mirrored `index-v1.json` (#259), newest pin first — cached
        on the file's mtime, since it is 3.8 MB and changes monthly."""
        base = self.root / "osm" / "geofabrik"
        pin = self._pin(self._state())
        candidates = []
        if pin:
            candidates.append(base / pin / "index-v1.json")
        if base.exists():
            candidates += sorted(base.glob("*/index-v1.json"), reverse=True)
        path = next((p for p in candidates if p.exists()), None)
        if path is None:
            return None
        mtime = path.stat().st_mtime
        with self._index_lock:
            if self._index_cache and self._index_cache[:2] == (path, mtime):
                return self._index_cache[2]
            regions = parse_index(json.loads(path.read_text()))
            self._index_cache = (path, mtime, regions)
            return regions

    def _row_extent(self, row: dict) -> BBox | None:
        """What a stored OSM area claims to cover. A precut row carries its
        bbox; a full-state row (seeded from `geofabrik.regions`) does not,
        and its PBF header rectangle overclaims across a state line, so it
        is never counted as covering — a trip there gets a cell of its
        own, which is also what keeps its clip fast."""
        bbox = row.get("bbox")
        return tuple(bbox) if bbox else None

    def _covering_row(self, piece: BBox, records: Mapping[str, dict], pin: str | None):
        for key, row in records.items():
            if row.get("layer") != LAYER:
                continue
            extent = self._row_extent(row)
            if extent is None or not _contains(extent, piece):
                continue
            if pin and not row["path"].startswith(f"osm/geofabrik/{pin}/"):
                continue  # a pin bump left it behind; /clip no longer reads it
            if (self.root / row["path"]).exists():
                return row
        return None

    # -- LayerFiller -------------------------------------------------------

    def plan(self, bbox: BBox, records: Mapping[str, dict]) -> FillPlan:
        state = self._state()
        pin = self._pin(state)
        regions = self.index_regions()
        areas: list[AreaPlan] = []
        seen: set[str] = set()
        uncovered = []
        for name, square, piece in cells_for(bbox):
            row = self._covering_row(piece, records, pin)
            if row is not None:
                if row["area"] not in seen:
                    seen.add(row["area"])
                    areas.append(AreaPlan(row["area"], row["path"],
                                          tuple(row["bbox"]) if row.get("bbox") else None))
                continue
            if regions is not None and not covering_regions(regions, piece):
                uncovered.append(piece)
                continue
            if pin is None:
                # No pin to publish under. The fetch says so as a failure;
                # it is not a coverage fact.
                pin_dir = "unpinned"
            else:
                pin_dir = pin
            areas.append(AreaPlan(name, f"osm/geofabrik/{pin_dir}/{name}.osm.pbf", square))
        if not areas:
            return FillPlan(no_coverage=(
                f"no Geofabrik region covers bbox {bbox} — nothing upstream to "
                "fill it from"))
        return FillPlan(areas=tuple(areas))

    def fetch(self, area: AreaPlan, ctx: FillContext) -> FilledArea:
        state = self._state()
        pin = self._pin(state)
        if pin is None or not area.path.startswith(f"osm/geofabrik/{pin}/"):
            raise FillFailed("no_pin", "this mirror has no current Geofabrik pin to fill under"
                             if pin is None else
                             f"the mirror's pin moved to {pin} since this fill was planned")
        regions = self.index_regions()
        if regions is None:
            raise FillFailed("no_index", "this mirror has no index-v1.json to resolve "
                             "Geofabrik regions from (run geofabrik_pull.py --pull-index)")
        sources = covering_regions(regions, area.bbox)
        if not sources:
            raise NoUpstreamCoverageError(f"no Geofabrik region covers {area.bbox}")

        for n, region in enumerate(sources):
            ctx.progress(n / (len(sources) + 1), f"pulling {region.path} from Geofabrik")
            self._pull_source(region.path, pin)
        ctx.progress(len(sources) / (len(sources) + 1),
                     f"precutting {area.area} from {', '.join(r.path for r in sources)}")
        self._precut(area, pin, [r.path for r in sources], ctx)
        return FilledArea(
            upstream="geofabrik:" + ",".join(r.path for r in sources) + f"@{pin}",
            meta={"precut_from": [r.path for r in sources]})

    def _pull_source(self, region: str, pin: str) -> None:
        """One region through `pull_region`, bookkeeping kept under
        `geofabrik.fill_sources` so cadence and backoff survive between
        fills without registering the full-state file for `/clip`."""
        stored = (self._state().get("geofabrik") or {}).get("fill_sources") or {}
        private = {"geofabrik": {"regions": {region: dict(stored.get(region) or {})}}}
        result = self.pull.pull_region(
            region=region, root=self.root, pinned_date=pin, state=private,
            base_url=self.base_url, now=self._now, throttle=self.throttle)
        entry = private["geofabrik"]["regions"][region]

        def _save(state: dict) -> None:
            state.setdefault("geofabrik", {}).setdefault("fill_sources", {})[region] = entry

        self.book.update(_save)
        log.info("fill osm: source %s -> %s %s", region, result.action, result.detail)
        dest = self.root / "osm" / "geofabrik" / pin / f"{region}.osm.pbf"
        if result.action in ("failed", "skipped_backoff") and not dest.exists():
            raise FillFailed(
                "upstream_unavailable",
                f"Geofabrik did not deliver {region}: {result.detail}")
        if not dest.exists():
            # A cadence skip with no file (a previous pin) — nothing to cut.
            raise FillFailed("source_missing", f"{region} was checked today but is not "
                             f"on disk under pin {pin}")

    def _precut(self, area: AreaPlan, pin: str, sources: list[str], ctx: FillContext) -> None:
        from .mirror_clip import NoMirrorCoverage, clip_bbox

        pin_dir = self.root / "osm" / "geofabrik" / pin
        scratch = Path(tempfile.mkdtemp(dir=pin_dir, prefix=f"{STAGING_PREFIX}scratch-"))
        try:
            # A scratch mirror naming only this cell's sources, the way
            # #530's precut_cells does, so clip_bbox reads nothing else.
            scratch_pin = scratch / "osm" / "geofabrik" / pin
            for region in sources:
                link = scratch_pin / f"{region}.osm.pbf"
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(pin_dir / f"{region}.osm.pbf")
                poly = pin_dir / f"{region}.poly"
                if poly.exists():
                    link.with_name(Path(region).name + ".poly").symlink_to(poly)
            (scratch / "MIRROR_STATE.json").write_text(json.dumps({
                "geofabrik": {"pinned_date": pin, "regions": {r: {} for r in sources}}}))
            staged = ctx.staging_path(area.path)
            staged.unlink()  # BackReferenceWriter refuses an existing file
            try:
                result = clip_bbox(area.bbox, root=scratch, dest=staged, tmp_dir=scratch)
            except NoMirrorCoverage as exc:
                staged.unlink(missing_ok=True)
                raise NoUpstreamCoverageError(str(exc)) from None
            log.info("fill osm: precut %s from %s in %.1fs (%d bytes)",
                     area.area, sources, result.wall_time_s, result.output_bytes)
            ctx.publish(staged, area.path)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)

    # -- bookkeeping hooks (called under the store lock) --------------------

    def register(self, state: dict, row: dict) -> None:
        """Makes the cell visible to `/clip` (`geofabrik.regions`) and
        retires any registered precut this cell's square fully contains —
        #530's supersede, applied per cell; the file stays on disk."""
        geofabrik = state.setdefault("geofabrik", {})
        regions = geofabrik.setdefault("regions", {})
        square = tuple(row["bbox"])
        for name, entry in list(regions.items()):
            precut = (entry or {}).get("precut_bbox")
            if name != row["area"] and precut and _contains(square, tuple(precut)):
                regions.pop(name)
                log.info("fill osm: %s supersedes %s", row["area"], name)
        now = row["filled_at"]
        regions[row["area"]] = {
            "precut_from": list((row.get("meta") or {}).get("precut_from") or []),
            "precut_bbox": list(square),
            "pulled_at": now,
            "checked_at": now,
            "filled": True,
        }

    def unregister(self, state: dict, row: dict) -> None:
        ((state.get("geofabrik") or {}).get("regions") or {}).pop(row["area"], None)
