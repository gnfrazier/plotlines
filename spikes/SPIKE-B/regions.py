"""The bbox SPIKE-B measures co-location cost and ranking against.

SPIKE-A calibrated notability against three *trip-sized* boxes (~25-30 km/side).
SPIKE-B's question is the opposite end: ARCH A21 / Q12 ask what co-location
analysis costs over a **realistic multi-day bbox** — ARCH §4.4 names "a 200 km
multi-day extent with many layers on" — and what a *reviewable* proposal count
is at that scale.

One real Overpass pull, `brp` — the Blue Ridge Parkway corridor from Asheville
to Boone, NC. ~90 x ~100 km, ~8,800 km2: a plausible 3-4 day cycling tour
extent (FR120), and the exact region PRD §5.4a walks its worked review pass
against ("An Author planning a Blue Ridge tour draws a bbox..."). Linville
Falls — §5.4a's top proposal card — sits inside it.

The area-scaling curve (issue point 1: "how both move with bbox area") is then
measured by **cropping** this one dataset to nested sub-boxes rather than
issuing more Overpass queries — the clustering cost is a function of candidate
count and extent, not of how the extract was fetched, and the fetch endpoint is
separately cacheable anyway (ARCH §8.2). `WORKED_PASS` is the §5.4a trip box:
the Grandfather Mountain / Linville sub-window of `brp`.

Overpass bbox order is south,west,north,east.
"""

from __future__ import annotations

from dataclasses import dataclass

from pyproj import Geod

_GEOD = Geod(ellps="WGS84")


@dataclass(frozen=True)
class Box:
    key: str
    name: str
    south: float
    west: float
    north: float
    east: float
    note: str = ""

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

    @property
    def span_km(self) -> tuple[float, float]:
        """(east-west, north-south) extent in km, measured across the middle."""
        midlat = (self.south + self.north) / 2
        _, _, ew = _GEOD.inv(self.west, midlat, self.east, midlat)
        _, _, ns = _GEOD.inv(self.west, self.south, self.west, self.north)
        return (ew / 1000, ns / 1000)

    def contains(self, lon: float, lat: float) -> bool:
        return self.west <= lon <= self.east and self.south <= lat <= self.north

    def crop(self, key: str, frac_area: float) -> "Box":
        """A concentric sub-box with `frac_area` of this box's area — the
        area-scaling sweep's nested windows. Linear span scales by sqrt(frac)."""
        f = frac_area ** 0.5
        clat = (self.south + self.north) / 2
        clon = (self.west + self.east) / 2
        dlat = (self.north - self.south) / 2 * f
        dlon = (self.east - self.west) / 2 * f
        return Box(
            key=key,
            name=f"{self.name} @ {frac_area:.0%} area",
            south=clat - dlat, west=clon - dlon,
            north=clat + dlat, east=clon + dlon,
        )


# The one real pull. Asheville (SW) to Boone (NE) along the Parkway.
BRP = Box(
    key="brp",
    name="Blue Ridge Parkway corridor, Asheville-Boone NC",
    south=35.50, west=-82.75, north=36.30, east=-81.65,
    note="~90 x ~100 km, ~8,800 km2. A 3-4 day tour extent (FR120). PRD §5.4a's "
         "worked review pass is set here; Linville Falls, Grandfather Mountain, "
         "Mount Mitchell, Blowing Rock, the Folk Art Center all inside.",
)

# PRD §5.4a's trip box — the Author 'draws a bbox' around the Grandfather
# Mountain / Linville Gorge cluster of the Parkway. ~28 x ~30 km.
WORKED_PASS = Box(
    key="worked",
    name="Grandfather Mountain / Linville — PRD §5.4a worked pass",
    south=35.90, west=-82.10, north=36.12, east=-81.78,
    note="Linville Falls, Linville Gorge, Grandfather Mountain, Blowing Rock, "
         "Price Lake, Beacon Heights, Rough Ridge. §5.4a: historic + natural + "
         "amenity layers, ~43 proposals back.",
)

# The area-scaling sweep: nested concentric crops of BRP.
SWEEP_FRACTIONS = (1.0, 0.5, 0.25, 0.12, 0.06, 0.03)
SWEEP = tuple(BRP.crop(f"brp-{int(fr*100):02d}", fr) for fr in SWEEP_FRACTIONS)
