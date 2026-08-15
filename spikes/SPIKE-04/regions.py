"""The three regions SPIKE-04 probes, and the geodesic area maths that makes their
counts comparable.

Why these three: they are the regions the product already names (`docs/osm_reference.md`
"Open items" — NC / Wisconsin / Southern CA), and they were picked there because they
differ in the way that matters here. Western NC is steep whitewater; southwest Wisconsin
is a flatwater state water trail; Southern California is a dry region where paddling is
coastal and reservoir-based rather than riverine. If paddling data only holds up in one
of them, that is the finding — a mode that works in a third of the product's own regions
is not "first-class" in the sense FR10 claims.

The bboxes are deliberately different sizes (they follow river systems, not a grid), so
every count in this spike is reported per 1,000 km2 as well as raw. Comparing a raw count
from a 21,000 km2 box against one from a 7,000 km2 box would manufacture a regional
difference out of nothing but bbox drafting.
"""

from __future__ import annotations

from dataclasses import dataclass

from pyproj import Geod

_GEOD = Geod(ellps="WGS84")


@dataclass(frozen=True)
class Region:
    key: str
    name: str
    # Overpass bbox order: south, west, north, east.
    south: float
    west: float
    north: float
    east: float
    note: str

    @property
    def bbox(self) -> str:
        return f"{self.south},{self.west},{self.north},{self.east}"

    @property
    def bbox_lonlat(self) -> str:
        """USGS wants west,south,east,north — the opposite convention. Getting this
        backwards returns an empty result set rather than an error, which reads exactly
        like 'no gauges here'. Keep the two orderings apart by name."""
        return f"{self.west},{self.south},{self.east},{self.north}"

    @property
    def area_km2(self) -> float:
        lons = [self.west, self.east, self.east, self.west]
        lats = [self.south, self.south, self.north, self.north]
        area_m2, _ = _GEOD.polygon_area_perimeter(lons, lats)
        return abs(area_m2) / 1e6

    def per_1000km2(self, count: int) -> float:
        return round(count / self.area_km2 * 1000, 2)


REGIONS: tuple[Region, ...] = (
    Region(
        key="wnc",
        name="Western North Carolina",
        south=35.0, west=-84.0, north=35.8, east=-82.3,
        note="French Broad, Nantahala, Tuckasegee, Pigeon. The strongest paddling case "
             "in the product's regions and the home of a large, active whitewater "
             "community — the best case, not the average one.",
    ),
    Region(
        key="swwi",
        name="Southwest Wisconsin",
        south=42.9, west=-91.2, north=43.4, east=-89.6,
        note="Lower Wisconsin State Riverway, Sauk City to the Mississippi. A "
             "designated flatwater water trail: the canoe-touring case, where class "
             "rating is irrelevant and access points and portages are everything.",
    ),
    Region(
        key="socal",
        name="Southern California",
        south=33.0, west=-118.7, north=34.2, east=-117.0,
        note="Los Angeles / Orange / western Riverside. Paddling here is coastal and "
             "reservoir, not riverine; the region's rivers are largely concrete flood "
             "channels. Included precisely because it should come back thin.",
    ),
)

REGIONS_BY_KEY = {r.key: r for r in REGIONS}
