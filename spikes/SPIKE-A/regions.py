"""The three trip-sized bboxes SPIKE-A calibrates the notability ruleset against.

FR98's rules are Stage 1 of the authoring pipeline and their values are guesses
(ARCH §4.3). This spike measures them against real OSM extracts. Region choice
mirrors `docs/osm_reference.md`'s "Open items" (NC / Wisconsin / Southern CA) and
SPIKE-04's regions, but the *bbox* is deliberately trip-sized, not state-sized:
the issue asks for "candidate count at a realistic trip bbox", and a 20,000 km2
box would answer a question nobody in the product ever poses. Each box here is a
plausible multi-day authoring extent (FR120) centred on a place with real
content, ~25-30 km on a side.

Overpass bbox order is south,west,north,east.
"""

from __future__ import annotations

from dataclasses import dataclass

from pyproj import Geod

_GEOD = Geod(ellps="WGS84")


@dataclass(frozen=True)
class Region:
    key: str
    name: str
    south: float
    west: float
    north: float
    east: float
    note: str

    @property
    def bbox(self) -> str:
        return f"{self.south},{self.west},{self.north},{self.east}"

    @property
    def bbox_lonlat(self) -> tuple[float, float, float, float]:
        """west,south,east,north — osmnx / GeoJSON order."""
        return (self.west, self.south, self.east, self.north)

    @property
    def area_km2(self) -> float:
        lons = [self.west, self.east, self.east, self.west]
        lats = [self.south, self.south, self.north, self.north]
        area_m2, _ = _GEOD.polygon_area_perimeter(lons, lats)
        return abs(area_m2) / 1e6

    def per_km2(self, count: int) -> float:
        return round(count / self.area_km2, 3)

    def per_100km2(self, count: int) -> float:
        return round(count / self.area_km2 * 100, 1)


REGIONS: tuple[Region, ...] = (
    Region(
        key="avl",
        name="Asheville & the French Broad, NC",
        south=35.46, west=-82.66, north=35.68, east=-82.44,
        note="Dense, varied content: a historic downtown, Biltmore, riverside mill "
             "districts, Blue Ridge overlooks, a thick brewery/cafe layer. The "
             "over-triggering case for the amenity and historic layers.",
    ),
    Region(
        key="lwr",
        name="Lower Wisconsin Riverway (Spring Green - Sauk City)",
        south=43.10, west=-90.18, north=43.34, east=-89.86,
        note="A designated flatwater trail through small towns and state land. "
             "Taliesin, House on the Rock, river bluffs. Sparser and more rural than "
             "Asheville - the mid case.",
    ),
    Region(
        key="sgv",
        name="San Gabriel foothills (Pasadena - Sierra Madre), CA",
        south=34.13, west=-118.20, north=34.30, east=-117.98,
        note="Southern California as `osm_reference.md` frames it: a dry, built-up "
             "foothill zone. Old Pasadena and the Gamble House give it a historic "
             "core; the mountains give it trailheads and viewpoints; street trees and "
             "pocket parks are everywhere. The regional-difference probe.",
    ),
)

REGIONS_BY_KEY = {r.key: r for r in REGIONS}
