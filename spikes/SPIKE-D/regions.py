"""The trip bboxes SPIKE-D measures against — issue #159.

The spike question is explicit that the extent must be "one an Author would
actually draw — not a CI fixture", so the primary box is the one PRD §5.4a
already walks its worked review pass against: an Author planning a Blue Ridge
tour draws a box around the Grandfather Mountain / Linville Gorge cluster.
SPIKE-B used the same window as its `WORKED_PASS` sub-box, which means the two
spikes' numbers are directly comparable — SPIKE-B measured what co-location
costs *over* a candidate set, SPIKE-D measures what it costs to *get* one.

Three extents, spanning what FR120 permits an Author to declare:

  TRIP     Grandfather Mountain / Linville, ~29 x 24 km, ~700 km2.
           A basecamp trip: several days ridden out of one valley. The
           default case, and the one D34's "cheap reorder" claim has to
           hold for.
  TOUR     The Asheville-Boone Parkway corridor, ~99 x 89 km, ~8,800 km2 —
           ARCH §4.4's "200 km multi-day extent with many layers on", and
           SPIKE-B's `brp`. The upper bound an Author can reach without
           doing something unreasonable.
  ENLARGED TRIP grown north-east to take in Boone — FR120/N1's "enlarging
           re-extracts only the added area". Chosen so the growth is an
           L-shaped annulus (both axes grow), which is the case a naive
           "just refetch the whole thing" implementation gets away with on
           a single-axis test.

`SWEEP` crops TRIP and TOUR concentrically so extraction time is reported as
a curve against area rather than two points — the same technique SPIKE-B used,
except that here the crops are *fetched*, not sliced, because fetch cost is
exactly what is being measured.

Overpass bbox order is south,west,north,east; osmnx/GeoJSON order is
west,south,east,north. `Box` carries both.
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
        """south,west,north,east — Overpass order."""
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
        midlat = (self.south + self.north) / 2
        _, _, ew = _GEOD.inv(self.west, midlat, self.east, midlat)
        _, _, ns = _GEOD.inv(self.west, self.south, self.west, self.north)
        return (ew / 1000, ns / 1000)

    def contains(self, lon: float, lat: float) -> bool:
        return self.west <= lon <= self.east and self.south <= lat <= self.north

    def crop(self, key: str, frac_area: float) -> "Box":
        f = frac_area ** 0.5
        clat = (self.south + self.north) / 2
        clon = (self.west + self.east) / 2
        dlat = (self.north - self.south) / 2 * f
        dlon = (self.east - self.west) / 2 * f
        return Box(key=key, name=f"{self.name} @ {frac_area:.0%}",
                   south=clat - dlat, west=clon - dlon,
                   north=clat + dlat, east=clon + dlon)

    def tiles(self, n_lon: int, n_lat: int) -> list["Box"]:
        """Split into an `n_lon` x `n_lat` grid — A23's tile-and-retry unit."""
        dlon = (self.east - self.west) / n_lon
        dlat = (self.north - self.south) / n_lat
        out = []
        for i in range(n_lon):
            for j in range(n_lat):
                out.append(Box(
                    key=f"{self.key}-t{i}{j}",
                    name=f"{self.name} tile {i},{j}",
                    west=self.west + i * dlon, east=self.west + (i + 1) * dlon,
                    south=self.south + j * dlat, north=self.south + (j + 1) * dlat,
                ))
        return out


# --------------------------------------------------------------------- extents

TRIP = Box(
    key="trip",
    name="Grandfather Mountain / Linville, NC",
    south=35.90, west=-82.10, north=36.12, east=-81.78,
    note="PRD §5.4a's worked pass box; SPIKE-B's WORKED_PASS. Linville Falls, "
         "Linville Gorge, Grandfather Mountain, Blowing Rock, Price Lake, "
         "Beacon Heights, Rough Ridge. A basecamp trip extent.",
)

TOUR = Box(
    key="tour",
    name="Blue Ridge Parkway corridor, Asheville-Boone NC",
    south=35.50, west=-82.75, north=36.30, east=-81.65,
    note="SPIKE-B's `brp`. ARCH §4.4's multi-day extent — the upper bound.",
)

# FR120/N1: the Author extends north-east to take in Boone and the Watauga
# valley. Both axes grow, so the added area is an L, not a strip.
ENLARGED = Box(
    key="enlarged",
    name="TRIP + Boone / Watauga valley",
    south=35.90, west=-82.10, north=36.26, east=-81.60,
    note="FR120's enlargement case. Contains TRIP exactly; the added area is "
         "the L-shaped difference (north strip + east strip + the corner).",
)

# Extraction time as a curve, not two points.
SWEEP_FRACTIONS = (1.0, 0.5, 0.25, 0.10)
TRIP_SWEEP = tuple(TRIP.crop(f"trip-{int(f * 100):03d}", f) for f in SWEEP_FRACTIONS)
TOUR_SWEEP = tuple(TOUR.crop(f"tour-{int(f * 100):03d}", f) for f in SWEEP_FRACTIONS)

# A23's baseline access pattern, applied to TRIP. 2x2 keeps each tile near the
# ~175 km2 that SPIKE-04 §8 found public Overpass would actually complete.
TRIP_TILES = TRIP.tiles(2, 2)
TOUR_TILES = TOUR.tiles(4, 4)


def rect_difference(outer: Box, inner: Box) -> list[Box]:
    """`outer` minus `inner` as up to four disjoint rectangles — the added
    area of an FR120 enlargement, and the only thing N1 permits a re-extract
    to fetch. Assumes `inner` is contained in `outer` (an enlargement always
    is; a shrink is FR139's prompt, not an extraction).

    Cut order is north strip, south strip, then the west and east strips of
    what is left, so the pieces never overlap and never double-count a corner.
    """
    parts: list[Box] = []
    if outer.north > inner.north:
        parts.append(Box(key=f"{outer.key}-add-n", name="added: north strip",
                         south=inner.north, north=outer.north,
                         west=outer.west, east=outer.east))
    if outer.south < inner.south:
        parts.append(Box(key=f"{outer.key}-add-s", name="added: south strip",
                         south=outer.south, north=inner.south,
                         west=outer.west, east=outer.east))
    mid_s, mid_n = inner.south, inner.north
    if outer.west < inner.west:
        parts.append(Box(key=f"{outer.key}-add-w", name="added: west strip",
                         south=mid_s, north=mid_n,
                         west=outer.west, east=inner.west))
    if outer.east > inner.east:
        parts.append(Box(key=f"{outer.key}-add-e", name="added: east strip",
                         south=mid_s, north=mid_n,
                         west=inner.east, east=outer.east))
    return [p for p in parts if p.area_km2 > 0.01]


if __name__ == "__main__":
    for box in (TRIP, TOUR, ENLARGED):
        ew, ns = box.span_km
        print(f"{box.key:9} {ew:6.1f} x {ns:5.1f} km   {box.area_km2:9,.0f} km2   {box.name}")
    print()
    added = rect_difference(ENLARGED, TRIP)
    total = sum(p.area_km2 for p in added)
    print(f"enlargement adds {total:,.0f} km2 in {len(added)} rectangles "
          f"({total / ENLARGED.area_km2:.0%} of the new extent):")
    for p in added:
        print(f"  {p.key:16} {p.area_km2:8,.0f} km2")
