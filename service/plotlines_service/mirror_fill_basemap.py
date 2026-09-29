"""The basemap layer's fill on the Pi — issue #519 (epic #516, ARCH D67).

A miss extracts the covering grid cell from Protomaps' latest daily build
into its own archive in the store, through the same tool and the same
rules D65 set for `protomaps_extract.py`: the `pmtiles extract` CLI (never
`tiles/extract.py` against a planet archive — see that script's docstring),
the newest live build found by probing backward (Protomaps keeps only about
a week), z0–15.

**The unit is a 2° grid cell** (`cell-2d-wNNN-nNN`). The OSM fill uses 1°
because `/clip`'s cost is O(pinned extract) (#518's measurement); a basemap
read is one ranged GET whatever the archive's size, so the larger cell costs
nothing per tile and halves the fills a wandering Author triggers. Measured
live: the Greensboro cell in 22.0 s, 141.5 MB. The grids nest, and the
degree is in the name, so a name never means two pieces of ground.

**Refresh.** D65's TTL carries over: a cell older than
`mirror_state.DEFAULT_BASEMAP_TTL_DAYS` (30 d) is still served, and a
refresh is queued behind it (`refresh_due`), replacing the file in place
with the extract scripts' temp-file → `os.replace` step. A reader never
sees a half-written archive and never waits on the refresh.

**No upstream coverage** never applies: the planet build covers the world.
Once a bucket exists the store holds the whole planet and this filler is
not configured at all (#523).
"""

from __future__ import annotations

import importlib.util
import logging
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Mapping

from .mirror_fill import AreaPlan, FillContext, FillFailed, FilledArea, FillPlan
from .mirror_fill_osm import cells_for

log = logging.getLogger("plotlines.mirror_fill.basemap")

LAYER = "basemap"

#: The basemap's own grid — see the module docstring for why it is not the
#: OSM fill's 1°. `BasemapArchiveSet.missing_cells` defaults to the same.
CELL_DEGREES = 2.0

#: Store directory for filled cells. Stable per cell, like D65's per-region
#: path pins, so a refresh replaces the archive rather than moving it.
CELL_DIR = "basemap/protomaps/cells"

#: `mirror_state.DEFAULT_BASEMAP_TTL_DAYS`, duplicated because the mirror
#: service does not otherwise need core's tile modules; pinned by test.
TTL_DAYS = 30.0

_EXTRACT_SCRIPT = (Path(__file__).resolve().parents[2]
                   / "deploy" / "mirror" / "protomaps_extract.py")


def load_protomaps_extract(path: Path = _EXTRACT_SCRIPT):
    name = "protomaps_extract"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:  # pragma: no cover - deploy error
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _contains(outer, inner) -> bool:
    return (outer[0] <= inner[0] and outer[1] <= inner[1]
            and outer[2] >= inner[2] and outer[3] >= inner[3])


def _parse_iso(ts: str | None) -> datetime | None:
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


class BasemapFiller:
    """`LayerFiller` for the basemap. `extract` is `protomaps_extract`'s
    module (injectable for tests); `pmtiles_bin` defaults to the CLI on
    `PATH` (the container installs a pinned release)."""

    layer = LAYER
    #: A cell extract measured ~11 s for the corridor bbox (SPIKE-14), plus
    #: the build probe: seconds to a minute.
    retry_hint_s = 10

    def __init__(self, root: Path, *, extract=None, pmtiles_bin: str | None = None,
                 upstream_base_url: str | None = None, maxzoom: int | None = None,
                 ttl_days: float = TTL_DAYS, now=None):
        self.root = Path(root)
        self.extract = extract or load_protomaps_extract()
        self.pmtiles_bin = pmtiles_bin
        self.upstream_base_url = upstream_base_url or self.extract.DEFAULT_UPSTREAM_BASE_URL
        self.maxzoom = self.extract.DEFAULT_MAXZOOM if maxzoom is None else maxzoom
        self.ttl = timedelta(days=ttl_days)
        self._now = now or (lambda: datetime.now(timezone.utc))

    def _covering_row(self, piece, records: Mapping[str, dict]):
        for row in records.values():
            if row.get("layer") != LAYER:
                continue
            parts = row.get("parts") or ([row["bbox"]] if row.get("bbox") else [])
            if any(_contains(tuple(p), piece) for p in parts) and (self.root / row["path"]).exists():
                return row
        return None

    def plan(self, bbox, records: Mapping[str, dict]) -> FillPlan:
        areas: list[AreaPlan] = []
        seen: set[str] = set()
        for name, square, piece in cells_for(bbox, CELL_DEGREES):
            row = self._covering_row(piece, records)
            if row is not None:
                if row["area"] not in seen:
                    seen.add(row["area"])
                    areas.append(AreaPlan(row["area"], row["path"],
                                          tuple(row["bbox"]) if row.get("bbox") else None))
                continue
            if name not in seen:
                seen.add(name)
                areas.append(AreaPlan(name, f"{CELL_DIR}/{name}.pmtiles", square))
        return FillPlan(areas=tuple(areas))

    def refresh_due(self, row: dict) -> bool:
        """A filled cell past the TTL is refreshed behind the stored copy.
        Seeded archives are `protomaps_extract.py`'s to refresh, not this."""
        if row.get("seeded") or row.get("layer") != LAYER:
            return False
        filled = _parse_iso(row.get("filled_at"))
        return filled is None or self._now() - filled > self.ttl

    def fetch(self, area: AreaPlan, ctx: FillContext) -> FilledArea:
        ex = self.extract
        ctx.progress(0.0, "finding the latest Protomaps build")
        try:
            build = ex.find_latest_build_date(base_url=self.upstream_base_url)
        except ex.BuildNotFound as exc:
            raise FillFailed("no_upstream_build", str(exc)) from None
        source_url = ex._build_url(self.upstream_base_url, build)
        staged = ctx.staging_path(area.path)
        staged.unlink()  # pmtiles extract writes a fresh file
        ctx.progress(0.2, f"extracting {area.area} from Protomaps build {build}")
        try:
            ex.run_pmtiles_extract(
                pmtiles_bin=ex._resolve_pmtiles_bin(self.pmtiles_bin), source_url=source_url,
                out_path=staged, bbox=area.bbox, maxzoom=self.maxzoom)
        except ex.ExtractFailed as exc:
            staged.unlink(missing_ok=True)
            raise FillFailed("extract_failed", str(exc)) from None
        ctx.publish(staged, area.path)
        return FilledArea(upstream=f"protomaps:{build}", meta={"source_url": source_url})
