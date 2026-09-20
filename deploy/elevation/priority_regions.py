#!/usr/bin/env python3
"""QA/UAT priority regions for the Pi5 elevation proxy's live pre-warm run
(issue #450's ceiling-exhaustion check, spent productively — see
`prewarm_priority_regions.py` and `deploy/elevation/README.md`).

Pure geometry, no network calls — every function here is testable standalone
and none of them touch the proxy or OpenTopography. Unlike its sibling
`prewarm_cache.py` (stdlib-only, copy-anywhere), this module needs `shapely`
and `pyproj` for real corridor buffering, so it is not meant to be copied
somewhere without those installed — run it from a dev box with `core`'s
geospatial stack available (`pip install shapely pyproj` is enough on its
own; nothing here actually imports `plotlines_core`).

This lives in `deploy/elevation/`, not `core/plotlines_core/`, because it is
QA-scoped, deletable tooling — the same posture the proxy module's own
docstring claims ("safe to delete once the QA window closes"). Putting it in
`core` would pull this one-off geometry into the frozen-sidecar build's
import graph and `core`'s permanent test suite for no lasting benefit.

OpenTopography's Global DEM API caps a single request's bounding-box area at
450,000 km2 for 30m-class datasets (SRTM GL1, COP30, NASADEM, and — by the
same "all other data" bucket, per opentopography.org/developers and
portal.opentopography.org/apidocs — GEDTM30, the dataset this proxy
requests). `MAX_TILE_AREA_KM2` below is a self-imposed margin under that
real cap. This constraint is not enforced anywhere else in this repo, and a
request that exceeds it is not free to get wrong: `OpenTopographyClient.fetch`
(`core/plotlines_core/elevation/keys.py`) records the call against the
50-calls/24h ledger *before* issuing the HTTP request, so an oversized bbox
that OpenTopography rejects still spends one of the 50 calls for nothing.
"""

from __future__ import annotations

from dataclasses import dataclass

from pyproj import Geod, Transformer
from shapely.geometry import LineString
from shapely.ops import transform as shapely_transform

BBox = tuple[float, float, float, float]  # west, south, east, north — matches
                                           # plotlines_core.elevation.interface.BBox

_GEOD = Geod(ellps="WGS84")

MI_TO_KM = 1.609344

#: Self-imposed margin under OpenTopography's real 450,000 km2 cap for
#: 30m-class datasets (see module docstring).
MAX_TILE_AREA_KM2 = 400_000.0

BRP_BUFFER_KM = 100 * MI_TO_KM        # 160.9344 — per the user's spec
SKYLINE_BUFFER_KM = 50 * MI_TO_KM     # 80.4672
CHAMPLAIN_BUFFER_KM = 50 * MI_TO_KM   # 80.4672
PCT_BUFFER_KM = 15 * MI_TO_KM         # 24.14016 — a practical single-track
                                       # trail corridor, not specified by the
                                       # user; confirmed default via review.


def bbox_area_km2(bbox: BBox) -> float:
    """Geodesic area via `pyproj.Geod` (WGS84 ellipsoid) — the same method
    `spikes/SPIKE-B/regions.py`'s `Box.area_km2` already uses, not a flat
    degrees-squared approximation, which would misjudge how close a bbox is
    to the real per-request area cap depending on latitude."""
    west, south, east, north = bbox
    lons = [west, east, east, west]
    lats = [south, south, north, north]
    area_m2, _ = _GEOD.polygon_area_perimeter(lons, lats)
    return abs(area_m2) / 1e6


def _aeqd_transformers(center_lon: float, center_lat: float):
    """A local azimuthal-equidistant projection centered on `(center_lon,
    center_lat)` — distances from the center are preserved exactly, which is
    what a mileage buffer needs. Using one shared degrees-per-mile constant
    across every region would meaningfully skew a 100mi buffer differently
    at North Carolina's ~36N than at Lake Champlain's ~44N; projecting
    locally sidesteps that without hand-picked per-region constants."""
    proj = (
        f"+proj=aeqd +lat_0={center_lat} +lon_0={center_lon} "
        "+datum=WGS84 +units=m +no_defs"
    )
    to_local = Transformer.from_crs("EPSG:4326", proj, always_xy=True)
    to_lonlat = Transformer.from_crs(proj, "EPSG:4326", always_xy=True)
    return to_local, to_lonlat


def buffer_polyline_to_bbox(vertices: list[tuple[float, float]], buffer_km: float) -> BBox:
    """Buffer a lon/lat polyline by `buffer_km` on every side and return the
    bounding box of the result. Buffering happens in a local
    azimuthal-equidistant projection centered on the vertices' centroid, not
    in raw degrees."""
    if len(vertices) < 2:
        raise ValueError("need at least 2 vertices to buffer a polyline")
    center_lon = sum(v[0] for v in vertices) / len(vertices)
    center_lat = sum(v[1] for v in vertices) / len(vertices)
    to_local, to_lonlat = _aeqd_transformers(center_lon, center_lat)
    local_line = LineString([to_local.transform(lon, lat) for lon, lat in vertices])
    buffered = local_line.buffer(buffer_km * 1000.0)
    lonlat_poly = shapely_transform(to_lonlat.transform, buffered)
    west, south, east, north = lonlat_poly.bounds
    return (west, south, east, north)


def split_bbox_to_cap(bbox: BBox, max_area_km2: float = MAX_TILE_AREA_KM2) -> list[BBox]:
    """Recursively halve `bbox` along its longer geographic axis (measured in
    km, not raw degrees) until every piece is at or under `max_area_km2`.
    A no-op if `bbox` is already under the cap. Safety net for every fixed
    region below, and the primitive `chunk_polyline_into_tiles` falls back
    to for a single over-cap window."""
    area = bbox_area_km2(bbox)
    if area <= max_area_km2:
        return [bbox]
    west, south, east, north = bbox
    midlat = (south + north) / 2
    _, _, ew_m = _GEOD.inv(west, midlat, east, midlat)
    _, _, ns_m = _GEOD.inv(west, south, west, north)
    pieces: list[BBox] = []
    if ew_m >= ns_m:
        mid = (west + east) / 2
        pieces.extend(split_bbox_to_cap((west, south, mid, north), max_area_km2))
        pieces.extend(split_bbox_to_cap((mid, south, east, north), max_area_km2))
    else:
        mid = (south + north) / 2
        pieces.extend(split_bbox_to_cap((west, south, east, mid), max_area_km2))
        pieces.extend(split_bbox_to_cap((west, mid, east, north), max_area_km2))
    return pieces


def chunk_polyline_into_tiles(
    vertices: list[tuple[float, float]],
    buffer_km: float,
    max_area_km2: float = MAX_TILE_AREA_KM2,
) -> list[BBox]:
    """Walk `vertices` in order, growing a window from each start point as
    far as it can go before its buffered bbox would exceed `max_area_km2`,
    then start the next window one vertex back from where the previous one
    closed — a 1-vertex overlap, so there is no coverage gap at the seam.
    One code path for every corridor region below; a short corridor (BRP,
    Skyline, Champlain, at these buffer widths) just happens to resolve to a
    single tile, same as PCT resolving to many."""
    if len(vertices) < 2:
        raise ValueError("need at least 2 vertices")
    n = len(vertices)
    tiles: list[BBox] = []
    start = 0
    while start < n - 1:
        end = start + 1
        best_bbox = buffer_polyline_to_bbox(vertices[start : end + 1], buffer_km)
        if bbox_area_km2(best_bbox) > max_area_km2:
            # Even the minimal (single-segment) window is over cap — not
            # expected at the buffer widths this script uses, but split it
            # defensively and move on rather than looping forever.
            tiles.extend(split_bbox_to_cap(best_bbox, max_area_km2))
            start = end + 1
            continue
        while end + 1 < n:
            candidate = buffer_polyline_to_bbox(vertices[start : end + 2], buffer_km)
            if bbox_area_km2(candidate) > max_area_km2:
                break
            end += 1
            best_bbox = candidate
        tiles.append(best_bbox)
        start = end  # 1-vertex overlap: the next window starts here, not end+1
    return tiles


@dataclass(frozen=True)
class RegionCandidate:
    region_key: str
    label: str
    priority: int
    tile_index: int
    tile_count: int
    bbox: BBox
    area_km2: float


# --------------------------------------------------------------------------
# Real geometry — hand-authored coarse waypoints ("practical", not
# survey-grade; buffer widths of 15-100mi comfortably absorb a few km of
# imprecision here).
# --------------------------------------------------------------------------

# Blue Ridge Parkway, Rockfish Gap VA (mile 0, north terminus) -> Cherokee NC
# / Great Smoky Mountains NP boundary (mile 469, south terminus).
#
# The middle segment (Asheville -> Blowing Rock, mile 382 -> 294) is ported
# verbatim from `spikes/SPIKE-B/route.py`'s `BRP_ROUTE` — a real, previously
# hand-digitised alignment at ~2-5km vertex spacing. It only covered ~88 of
# the parkway's 469 miles; the waypoints before and after it here extend to
# the actual full parkway (the real region this task asked for), at the
# coarser ~30-80km spacing "practical" calls for.
BRP_ROUTE: list[tuple[float, float]] = [
    # -- extension: GSMNP boundary (mile 469) to Asheville (mile 382) -- #
    (-83.108, 35.545),   # Oconaluftee / Cherokee, GSMNP boundary — south terminus
    (-83.083, 35.489),   # Waterrock Knob
    (-82.755, 35.415),   # Mount Pisgah
    # -- ported verbatim from spikes/SPIKE-B/route.py -- #
    (-82.494, 35.588),   # Folk Art Center, Asheville
    (-82.455, 35.612),   # US 70 / Oteen
    (-82.412, 35.648),   # Bull Creek / Craven Gap
    (-82.381, 35.699),   # Craggy Gardens visitor center
    (-82.330, 35.730),   # Glassmine Falls overlook
    (-82.280, 35.749),   # NC 128 / Mount Mitchell spur junction
    (-82.230, 35.765),   # Black Mountain Gap
    (-82.178, 35.792),   # Buck Creek Gap / NC 80
    (-82.142, 35.813),   # Crabtree Falls
    (-82.098, 35.847),   # Little Switzerland
    (-82.030, 35.860),   # Gillespie Gap / Museum of NC Minerals
    (-81.985, 35.910),   # Bear Den overlook
    (-81.928, 35.958),   # Linville Falls
    (-81.895, 36.010),   # NC 181 / Jonas Ridge
    (-81.855, 36.060),   # Linn Cove Viaduct (Grandfather Mountain)
    (-81.815, 36.096),   # Beacon Heights
    (-81.790, 36.100),   # Rough Ridge
    (-81.760, 36.118),   # NC 221 / Holloway Mountain Rd
    (-81.725, 36.137),   # Price Lake
    (-81.680, 36.140),   # US 321 / Blowing Rock
    # -- extension: Blowing Rock (mile 294) to Rockfish Gap (mile 0) -- #
    (-81.150, 36.450),   # Doughton Park
    (-80.870, 36.620),   # Fancy Gap / VA state line
    (-80.320, 36.830),   # Rocky Knob / Mabry Mill
    (-79.930, 37.250),   # Roanoke Mountain
    (-79.600, 37.420),   # Peaks of Otter
    (-79.320, 37.570),   # Otter Creek / James River
    (-78.850, 37.980),   # Humpback Rocks
    (-78.850, 38.030),   # Rockfish Gap — north terminus
]

# Skyline Drive, Front Royal VA -> Rockfish Gap VA (where it meets the BRP's
# north terminus, matching the coordinate above).
SKYLINE_DRIVE_ROUTE: list[tuple[float, float]] = [
    (-78.199, 38.912),   # Front Royal, north entrance
    (-78.320, 38.780),   # Compton Gap / Skyline Caverns
    (-78.354, 38.601),   # Skyland
    (-78.437, 38.522),   # Big Meadows
    (-78.590, 38.330),   # Swift Run Gap (US 33)
    (-78.720, 38.150),   # Loft Mountain
    (-78.858, 38.030),   # Rockfish Gap, south entrance (I-64/US 250)
]

# Pacific Crest Trail, Campo CA (southern terminus) -> Manning Park BC
# (northern terminus), one waypoint per well-known landmark.
PCT_ROUTE: list[tuple[float, float]] = [
    (-116.466, 32.589),  # Campo, CA — southern terminus
    (-116.421, 32.867),  # Mount Laguna
    (-116.652, 33.286),  # Warner Springs
    (-116.716, 33.746),  # Idyllwild / San Jacinto
    (-116.868, 34.238),  # Big Bear
    (-117.459, 34.337),  # Cajon Pass
    (-117.633, 34.365),  # Wrightwood
    (-118.316, 34.499),  # Agua Dulce
    (-118.532, 35.135),  # Tehachapi Pass
    (-118.038, 35.666),  # Walker Pass
    (-118.086, 36.028),  # Kennedy Meadows South
    (-118.365, 36.578),  # Kearsarge Pass area
    (-118.663, 37.081),  # Muir Pass
    (-118.960, 37.605),  # Red's Meadow / Mammoth
    (-119.359, 37.873),  # Tuolumne Meadows
    (-119.606, 38.320),  # Sonora Pass
    (-120.038, 38.847),  # Echo Lake / South Lake Tahoe
    (-120.323, 39.328),  # Donner Pass
    (-121.240, 40.112),  # Belden
    (-121.786, 41.038),  # Burney Falls
    (-122.312, 41.436),  # Castle Crags
    (-122.325, 41.409),  # Mount Shasta / Callahan's
    (-123.117, 41.845),  # Seiad Valley
    (-122.596, 42.056),  # Oregon border (Siskiyou Summit)
    (-122.121, 42.910),  # Crater Lake
    (-121.784, 43.897),  # Elk Lake / Bend
    (-121.845, 44.418),  # Santiam Pass
    (-121.710, 45.331),  # Mount Hood / Timberline Lodge
    (-121.897, 45.663),  # Cascade Locks (Columbia River Gorge)
    (-121.386, 46.638),  # White Pass
    (-121.413, 47.425),  # Snoqualmie Pass
    (-121.089, 47.745),  # Stevens Pass
    (-120.665, 48.307),  # Stehekin
    (-120.727, 48.512),  # Rainy Pass
    (-120.804, 49.000),  # Manning Park, BC — north terminus
]

# North-south axis Lake Champlain sits on, buffered through the same
# chunk_polyline_into_tiles path rather than a bespoke rectangle expander.
LAKE_CHAMPLAIN_AXIS: list[tuple[float, float]] = [
    (-73.45, 43.50),
    (-73.35, 44.00),
    (-73.30, 44.50),
    (-73.20, 44.90),
    (-73.10, 45.05),
]

# Simple rectangles.
NC_BBOX: BBox = (-84.32, 33.75, -75.40, 36.59)
BWCAW_BBOX: BBox = (-92.9, 47.75, -90.2, 48.30)
YELLOWSTONE_BBOX: BBox = (-111.16, 44.13, -109.83, 45.11)

#: Tiny, remote (Alaska Peninsula) bbox untouched by anything else in this
#: module's candidate lists — used only if a full run (including widened
#: PCT re-tiling) completes without ever observing a natural 503, to still
#: deliberately trigger and confirm the ceiling-exhaustion behavior.
SYNTHETIC_CONFIRMATION_BBOX: BBox = (-160.00, 55.00, -159.99, 55.01)


def _candidates_from_bbox(
    bbox: BBox, *, region_key: str, label: str, priority: int, max_area_km2: float
) -> list[RegionCandidate]:
    pieces = split_bbox_to_cap(bbox, max_area_km2)
    return [
        RegionCandidate(
            region_key=region_key,
            label=label,
            priority=priority,
            tile_index=i + 1,
            tile_count=len(pieces),
            bbox=piece,
            area_km2=bbox_area_km2(piece),
        )
        for i, piece in enumerate(pieces)
    ]


def _candidates_from_polyline(
    vertices: list[tuple[float, float]],
    buffer_km: float,
    *,
    region_key: str,
    label: str,
    priority: int,
    max_area_km2: float,
) -> list[RegionCandidate]:
    tiles = chunk_polyline_into_tiles(vertices, buffer_km, max_area_km2)
    return [
        RegionCandidate(
            region_key=region_key,
            label=label,
            priority=priority,
            tile_index=i + 1,
            tile_count=len(tiles),
            bbox=tile,
            area_km2=bbox_area_km2(tile),
        )
        for i, tile in enumerate(tiles)
    ]


def build_priority_candidates(
    *,
    pct_buffer_km: float = PCT_BUFFER_KM,
    max_tile_area_km2: float = MAX_TILE_AREA_KM2,
) -> list[RegionCandidate]:
    """The full, ordered (priority 1-7) candidate list. Pure and
    network-free — computing this spends no OpenTopography quota."""
    candidates: list[RegionCandidate] = []
    candidates += _candidates_from_bbox(
        NC_BBOX, region_key="nc", label="North Carolina (full state)",
        priority=1, max_area_km2=max_tile_area_km2,
    )
    candidates += _candidates_from_polyline(
        BRP_ROUTE, BRP_BUFFER_KM, region_key="brp",
        label="Blue Ridge Parkway (+100mi)", priority=2, max_area_km2=max_tile_area_km2,
    )
    candidates += _candidates_from_polyline(
        SKYLINE_DRIVE_ROUTE, SKYLINE_BUFFER_KM, region_key="skyline",
        label="Skyline Drive (+50mi)", priority=3, max_area_km2=max_tile_area_km2,
    )
    candidates += _candidates_from_bbox(
        BWCAW_BBOX, region_key="bwcaw",
        label="Boundary Waters Canoe Area Wilderness", priority=4,
        max_area_km2=max_tile_area_km2,
    )
    candidates += _candidates_from_bbox(
        YELLOWSTONE_BBOX, region_key="yellowstone",
        label="Yellowstone National Park", priority=5, max_area_km2=max_tile_area_km2,
    )
    candidates += _candidates_from_polyline(
        LAKE_CHAMPLAIN_AXIS, CHAMPLAIN_BUFFER_KM, region_key="champlain",
        label="Lake Champlain (+50mi)", priority=6, max_area_km2=max_tile_area_km2,
    )
    candidates += _candidates_from_polyline(
        PCT_ROUTE, pct_buffer_km, region_key="pct",
        label="Pacific Crest Trail (Campo CA northward)", priority=7,
        max_area_km2=max_tile_area_km2,
    )
    return candidates


def pct_tiles_with_wider_buffer(
    multiplier: float,
    *,
    base_buffer_km: float = PCT_BUFFER_KM,
    priority: int = 8,
    max_tile_area_km2: float = MAX_TILE_AREA_KM2,
) -> list[RegionCandidate]:
    """Re-tile the whole PCT route at `base_buffer_km * multiplier` — the
    "spend remaining budget on extra useful PCT coverage" fallback used when
    the base priority list completes without ever naturally exhausting the
    ceiling."""
    buffer_km = base_buffer_km * multiplier
    return _candidates_from_polyline(
        PCT_ROUTE, buffer_km, region_key="pct-wide",
        label=f"PCT re-tile (+{buffer_km / MI_TO_KM:.0f}mi)",
        priority=priority, max_area_km2=max_tile_area_km2,
    )
