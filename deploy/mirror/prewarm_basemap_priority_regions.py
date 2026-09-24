#!/usr/bin/env python3
"""Pre-warm the mirror's basemap over the same QA/UAT priority regions the
elevation proxy was pre-warmed for (issue #453's live retest: an extent
drawn around Greensboro rendered grey, because the mirror's only basemap
archive is the WNC corridor and `corridor.pmtiles` has nothing past z7
outside `WNC_CORRIDOR_BBOX`).

The region list is not restated here — it is
`deploy/elevation/priority_regions.build_priority_candidates()`, the exact
candidate bboxes `prewarm_priority_regions.py` spent OpenTopography quota
on (North Carolina, Blue Ridge Parkway +100mi, Skyline Drive +50mi, the
Boundary Waters, Yellowstone, Lake Champlain +50mi, the PCT +15mi), so the
two can't drift. `--regions` narrows it by `region_key`.

## One archive, not one per region

The sidecar reads exactly one `--tiles-upstream` URL, so a file per region
(the way `protomaps_extract.py`'s `DEFAULT_REGIONS` publishes) would leave
every region but the one the client names unreachable. This cuts a single
archive covering all of them: the candidate bboxes go to `pmtiles extract`
as one GeoJSON MultiPolygon (`--region`), and the result is published
through `protomaps_extract.acquire` — same honest path convention, same
atomic publish, same `MIRROR_STATE.json` entry shape — as
`basemap/protomaps/<build>-priority/priority.pmtiles`. The WNC corridor is
always included, so this archive is a superset of `corridor.pmtiles` and
can replace it as the client's `PLOTLINES_TILES_UPSTREAM`. It is published
non-primary: the corridor stays the region `basemap_health()` reports.

One consequence to know about: the archive header's bounds are the
MultiPolygon's envelope (roughly the continental US here), and `/health`
reports those bounds. The client's out-of-coverage notice (#318) therefore
treats a viewport between two regions (Kansas, say) as covered and shows a
plain grey map there instead of the notice.

## Running it

Needs `shapely`/`pyproj` (through `priority_regions.py`), so run it from the
repo-root venv like its elevation sibling, on the Pi, where `--root` is the
live mirror tree and `pmtiles` is installed:

    .venv/bin/python deploy/mirror/prewarm_basemap_priority_regions.py --dry-run
    .venv/bin/python deploy/mirror/prewarm_basemap_priority_regions.py --root /srv/plotlines-mirror

TTL-driven like `protomaps_extract.py`: a re-run within `--ttl-days` is a
no-op, `--force` re-extracts anyway.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import tempfile
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
sys.path.insert(0, str(_HERE.parent / "elevation"))
import protomaps_extract as pe  # noqa: E402 - sibling import, path set above
from priority_regions import (  # noqa: E402
    BBox,
    RegionCandidate,
    bbox_area_km2,
    build_priority_candidates,
)

LOG = logging.getLogger("prewarm_basemap_priority_regions")

try:
    from plotlines_core.tiles.mirror import PROTOMAPS_BASEMAP_BUILD as _BASEMAP_BUILD
except ImportError:
    _BASEMAP_BUILD = "20250101"

REGION_NAME = "priority-regions"
BUILD_ID = f"{_BASEMAP_BUILD}-priority"
FILENAME = "priority.pmtiles"
MIRROR_BASE_URL = "http://tiles.plotlines.app"

#: The corridor archive's measured density — `corridor.pmtiles` as published
#: 2026-09-21 (118,401,816 bytes, z0-15) over `WNC_CORRIDOR_BBOX` — used only
#: for `--dry-run`'s size estimate. Towns are denser than the PCT's desert
#: and wilderness, so the estimate leans high.
_CORRIDOR_BYTES = 118_401_816
_CORRIDOR_BBOX: BBox = (-83.6, 35.2, -81.0, 36.4)


def selected_candidates(region_keys: set[str] | None = None) -> list[RegionCandidate]:
    candidates = build_priority_candidates()
    if region_keys is None:
        return candidates
    unknown = region_keys - {c.region_key for c in candidates}
    if unknown:
        raise ValueError(f"unknown region key(s): {', '.join(sorted(unknown))}")
    return [c for c in candidates if c.region_key in region_keys]


def area_bboxes(candidates: list[RegionCandidate]) -> list[BBox]:
    """The candidates' bboxes plus the WNC corridor, which every archive
    this script publishes must cover (it replaces `corridor.pmtiles`)."""
    return [_CORRIDOR_BBOX] + [c.bbox for c in candidates]


def region_geojson(bboxes: list[BBox]) -> dict:
    """One MultiPolygon, one closed counter-clockwise ring per bbox — what
    `pmtiles extract --region` takes. Overlapping boxes are fine: the CLI
    unions the tile sets."""
    polygons = [
        [[[w, s], [e, s], [e, n], [w, n], [w, s]]]
        for w, s, e, n in bboxes
    ]
    return {"type": "MultiPolygon", "coordinates": polygons}


def envelope(bboxes: list[BBox]) -> BBox:
    return (
        min(b[0] for b in bboxes), min(b[1] for b in bboxes),
        max(b[2] for b in bboxes), max(b[3] for b in bboxes),
    )


def estimate_bytes(bboxes: list[BBox]) -> int:
    """Upper-ish estimate: summed box area (overlaps counted twice) at the
    corridor's density."""
    density = _CORRIDOR_BYTES / bbox_area_km2(_CORRIDOR_BBOX)
    return int(sum(bbox_area_km2(b) for b in bboxes) * density)


def published_url(base_url: str = MIRROR_BASE_URL) -> str:
    return f"{base_url.rstrip('/')}/basemap/protomaps/{BUILD_ID}/{FILENAME}"


def prewarm(
    *,
    root: Path,
    candidates: list[RegionCandidate],
    ttl_days: float = pe.DEFAULT_TTL_DAYS,
    force: bool = False,
    **acquire_kwargs,
) -> Path | None:
    """Extract and publish the one priority archive, or return `None` with
    no network call if it is within `ttl_days`. `acquire_kwargs` pass
    straight through to `protomaps_extract.acquire` (`build_date`,
    `maxzoom`, `pmtiles_bin`, `upstream_base_url`, ...)."""
    state_path = root / "MIRROR_STATE.json"
    if not state_path.exists():
        raise SystemExit(
            f"error: {state_path} does not exist — run build_tree.sh against {root} first."
        )
    state = json.loads(state_path.read_text())
    now = acquire_kwargs.pop("now", None) or pe._utcnow()
    if not force and pe.region_is_fresh(state, REGION_NAME, ttl_days=ttl_days, now=now):
        LOG.info("skip %s: extracted within the last %.1f days", REGION_NAME, ttl_days)
        return None

    bboxes = area_bboxes(candidates)
    with tempfile.TemporaryDirectory(prefix="prewarm-basemap-") as scratch:
        geojson_path = Path(scratch) / "priority-regions.geojson"
        geojson_path.write_text(json.dumps(region_geojson(bboxes)))
        return pe.acquire(
            root=root, bbox=envelope(bboxes), region_name=REGION_NAME,
            build_id=BUILD_ID, filename=FILENAME, primary=False,
            region_geojson=geojson_path, now=now, **acquire_kwargs,
        )


def _print_plan(candidates: list[RegionCandidate]) -> None:
    bboxes = area_bboxes(candidates)
    print(f"{'region':<14} {'tile':>5}  {'area km2':>10}  bbox")
    print(f"{'wnc-corridor':<14} {'-':>5}  {bbox_area_km2(_CORRIDOR_BBOX):>10,.0f}  {_CORRIDOR_BBOX}")
    for c in candidates:
        bbox = tuple(round(v, 3) for v in c.bbox)
        print(f"{c.region_key:<14} {c.tile_index:>2}/{c.tile_count:<2}  {c.area_km2:>10,.0f}  {bbox}")
    print(f"\nenvelope: {tuple(round(v, 3) for v in envelope(bboxes))}")
    print(f"estimated size: ~{estimate_bytes(bboxes) / 1e9:.1f} GB at z0-{pe.DEFAULT_MAXZOOM} "
          f"(corridor density; overlaps counted twice)")
    print(f"publishes: basemap/protomaps/{BUILD_ID}/{FILENAME}")
    print(f"client:    PLOTLINES_TILES_UPSTREAM={published_url()}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Extract one mirror basemap archive covering the elevation "
                    "proxy's priority regions (issue #453).",
    )
    parser.add_argument("--root", type=Path, default=Path("/srv/plotlines-mirror"))
    parser.add_argument("--regions", default=None,
                        help="Comma-separated priority_regions region_key values "
                             "(default: all). The WNC corridor is always included.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print the areas, envelope and a size estimate; no network.")
    parser.add_argument("--ttl-days", type=float,
                        default=float(os.environ.get(pe.ENV_TTL_DAYS, pe.DEFAULT_TTL_DAYS)))
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--upstream-base-url", default=pe.DEFAULT_UPSTREAM_BASE_URL)
    parser.add_argument("--build-date", default=None)
    parser.add_argument("--max-lookback-days", type=int, default=pe.DEFAULT_MAX_LOOKBACK_DAYS)
    parser.add_argument("--maxzoom", type=int, default=pe.DEFAULT_MAXZOOM)
    parser.add_argument("--pmtiles-bin", default=None)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    wanted = ({k.strip() for k in args.regions.split(",") if k.strip()}
              if args.regions else None)
    try:
        candidates = selected_candidates(wanted)
    except ValueError as exc:
        parser.error(str(exc))

    if args.dry_run:
        _print_plan(candidates)
        return 0

    try:
        dest = prewarm(
            root=args.root, candidates=candidates, ttl_days=args.ttl_days, force=args.force,
            upstream_base_url=args.upstream_base_url, build_date=args.build_date,
            max_lookback_days=args.max_lookback_days, maxzoom=args.maxzoom,
            pmtiles_bin=args.pmtiles_bin,
        )
    except (pe.BuildNotFound, pe.ExtractFailed) as exc:
        LOG.error("%s", exc)
        return 1
    if dest is not None:
        print(f"published {dest} ({dest.stat().st_size / 1e9:.2f} GB)")
    print(f"PLOTLINES_TILES_UPSTREAM={published_url()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
