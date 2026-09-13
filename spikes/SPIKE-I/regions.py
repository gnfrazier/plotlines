"""SPIKE-I — the cells of the parity matrix, and the extracts behind them.

The regions are **imported** from `spikes/shared/regions.py`, not copied, for
the reason SPIKE-E gave when it did the same: a bbox re-typed into a second file
is a bbox that will drift, and the whole value of using the shared fixtures is
that SPIKE-01/02/03/05 and SPIKE-E measured *these* boxes. What this module adds
is the mapping each region needs and the shared file has no reason to carry —
which Geofabrik extract covers it — plus one bbox that exists only here.

`coline` is the §11.7 border case. Geofabrik cuts its extracts at
administrative boundaries, so a bbox straddling the Colorado/Wyoming line at
41°N is covered by *two* extracts, each holding half of every way that crosses.
A road network is connected; a bbox cut severs ways. Overpass handled that
invisibly and we are taking ownership of it, so it gets its own cell rather
than a paragraph.

`boulder` appears twice, once per `network_type`. SPIKE-E's finding — that
`network_type="drive"` is a *download filter* which silently drops
`highway=track` and `highway=service` before a way ever reaches the graph —
lives in exactly the code path B0 reimplements in Python. Parity with a known
defect is parity: the right outcome here is that the local filter reproduces
`drive`'s behaviour exactly, defect included. Fixing it is SPIKE-E's issue to
own, not this spike's; what this spike must not do is change it by accident
while swapping the transport, and a node count cannot see that happen.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

SPIKE = Path(__file__).resolve().parent
RAW = SPIKE / "raw"
EXTRACTS = SPIKE / "extracts"
RESULTS = SPIKE / "results"

# Import the shared fixtures rather than re-declaring their bboxes.
sys.path.insert(0, str(SPIKE.parent))
from shared.regions import REGIONS as SHARED_REGIONS  # noqa: E402

#: Geofabrik's download root. Region paths below are exactly the path segments
#: Geofabrik publishes, so the mirror's own `osm/geofabrik/<pin>/<region>` tree
#: (§6.3) keys on the same strings with no translation — the layout has to stay
#: a bucket layout (Q6), and inventing our own region names here would be the
#: first server-side rewrite.
GEOFABRIK_ROOT = "https://download.geofabrik.de"


@dataclass(frozen=True)
class Extract:
    """One pinned Geofabrik region extract."""

    #: Geofabrik's own path, e.g. "north-america/us/colorado".
    path: str

    @property
    def key(self) -> str:
        return self.path.rsplit("/", 1)[-1]

    @property
    def url(self) -> str:
        return f"{GEOFABRIK_ROOT}/{self.path}-latest.osm.pbf"

    @property
    def md5_url(self) -> str:
        return f"{self.url}.md5"

    @property
    def local(self) -> Path:
        return EXTRACTS / f"{self.key}.osm.pbf"


COLORADO = Extract("north-america/us/colorado")
CALIFORNIA = Extract("north-america/us/california")
WISCONSIN = Extract("north-america/us/wisconsin")
WYOMING = Extract("north-america/us/wyoming")


@dataclass(frozen=True)
class Cell:
    """One `(region x network_type)` cell. The `path` axis (T vs R) is applied
    by the graph builders, not enumerated here — both paths consume the same
    clip, and clipping twice would measure the filesystem."""

    key: str
    #: (west, south, east, north) — osmnx 2.x order, the order every bbox in
    #: this codebase uses.
    bbox: tuple[float, float, float, float]
    network_type: str
    extracts: tuple[Extract, ...]
    note: str

    @property
    def spans_two_extracts(self) -> bool:
        return len(self.extracts) > 1

    @property
    def area_km2(self) -> float:
        """Rough bbox area, for the §11.5/Q6 arithmetic and for sanity against
        `max_query_area_size` (an area over ~2,500 km² makes osmnx subdivide the
        query, which would change what the golden even is)."""
        import math

        west, south, east, north = self.bbox
        mid = math.radians((south + north) / 2.0)
        return (east - west) * 111.32 * math.cos(mid) * (north - south) * 110.57


def _shared(key: str) -> tuple[float, float, float, float]:
    return SHARED_REGIONS[key].bbox


CELLS: tuple[Cell, ...] = (
    Cell(
        key="boulder-bike",
        bbox=_shared("boulder"),
        network_type="bike",
        extracts=(COLORADO,),
        note="shared fixture; mountain-adjacent city, dense grid against foothills",
    ),
    Cell(
        key="boulder-drive",
        bbox=_shared("boulder"),
        network_type="drive",
        extracts=(COLORADO,),
        note="same box, SPIKE-E's filter: `drive` drops highway=track and "
             "highway=service at download time. Parity must reproduce that.",
    ),
    Cell(
        key="davis-bike",
        bbox=_shared("davis"),
        network_type="bike",
        extracts=(CALIFORNIA,),
        note="shared fixture; flat, dense bike network — the control for "
             "geometry deltas, since no relief means no terrain excuse",
    ),
    Cell(
        key="viroqua-bike",
        bbox=_shared("viroqua"),
        network_type="bike",
        extracts=(WISCONSIN,),
        note="shared fixture; rural Driftless — sparse network, thin tagging, "
             "the case where losing one way is a large fraction of the SCC",
    ),
    Cell(
        key="coline-bike",
        # US 287 crosses the CO/WY line at 41°N near Virginia Dale / Tie Siding.
        # Deliberately centred on the boundary so the bbox is genuinely halved
        # by Geofabrik's cut rather than merely close to it.
        bbox=(-105.55, 40.95, -105.35, 41.05),
        network_type="bike",
        extracts=(COLORADO, WYOMING),
        note="§11.7 border case: Geofabrik cuts at 41°N, so every crossing way "
             "is half in each extract",
    ),
)

CELLS_BY_KEY = {c.key: c for c in CELLS}

#: Every distinct extract the matrix needs, deduplicated — `colorado` serves
#: three cells.
ALL_EXTRACTS: tuple[Extract, ...] = tuple(
    dict.fromkeys(e for c in CELLS for e in c.extracts)
)


def bbox_polygon(bbox: tuple[float, float, float, float]):
    """The bbox as a shapely Polygon, in osmnx's own coordinate order."""
    from shapely.geometry import box

    west, south, east, north = bbox
    return box(west, south, east, north)


def buffered_polygon(bbox: tuple[float, float, float, float]):
    """The polygon osmnx actually *queries*, which is not the one it is asked for.

    `graph_from_polygon` projects the requested polygon, buffers it by 500 m,
    unprojects, and queries that — then truncates twice on the way back down.
    Path T has to select ways against the same buffered polygon or it is
    answering a different question than the golden, and the difference would
    show up as a parity failure that is really a harness bug.
    """
    from osmnx import projection

    poly = bbox_polygon(bbox)
    poly_proj, crs_utm = projection.project_geometry(poly)
    poly_proj_buff = poly_proj.buffer(500)
    poly_buff, _ = projection.project_geometry(poly_proj_buff, crs=crs_utm, to_latlong=True)
    return poly_buff
