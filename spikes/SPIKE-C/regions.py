"""The seven regions SPIKE-C measures — issue #170.

The issue is specific about the design: the three **shared fixture regions**, *plus at
least one region where the mode is genuinely popular*, "since coverage of a niche schema
is a function of local mapper community more than of terrain". That sentence is the whole
experiment. A schema can be absent from Boulder for two completely different reasons —
nobody uses the schema anywhere, or nobody in Boulder uses it — and only the second is a
reason to keep FR14b alive as an opportunistic read.

So the region set is three concentric controls, not a sample:

  **Fixtures** (`boulder`, `davis`, `viroqua`) — the exact bboxes in `spikes/shared/
  regions.py`, so SPIKE-C's numbers sit beside SPIKE-03's surface coverage (81.7% /
  34.4% / 24.5%) and SPIKE-21's cue results on the same ground. This is the "average
  North American place an Author actually draws a box around" case.

  **Mode-popular North America** (`whites`, `bentonville`, `methow`) — one per mode,
  each picked as the strongest North American case for *that* schema, not for its
  terrain. The Presidentials/Franconia for hiking, Bentonville for built MTB (the
  strongest `mtb:scale:imba` case on the continent), the Methow for nordic (the
  largest groomed nordic network in the US). If a schema is thin *here* it is thin
  everywhere in North America, and no amount of Author education fixes it.

  **Schema homeland** (`tyrol`) — Innsbruck/Seefeld. `sac_scale` is a Swiss Alpine
  Club scale, `mtb:scale` is a German scale, and both were mapped into OSM by the
  communities that invented them. This is the upper bound: what the schema looks
  like where it is native. Without it, a continent-wide zero is unreadable — it could
  mean the tag is dead, and it does not. One region covers all three schemas because
  the Tyrol carries hiking, MTB *and* nordic pistes in the same valley.

Bboxes are deliberately different sizes (they follow trail systems, not a grid), so
every count is also reported per 1,000 km2 — the same discipline SPIKE-04 used, for the
same reason: comparing a raw count from a 36 km2 box against one from a 2,000 km2 box
manufactures a regional difference out of nothing but bbox drafting.

Overpass bbox order is south,west,north,east; osmnx/GeoJSON order is west,south,east,north.
`Region` carries both, named apart, because getting it backwards returns an empty result
rather than an error — and in a spike whose job is to count things, a silent zero is the
single most dangerous failure mode.
"""

from __future__ import annotations

from dataclasses import dataclass

from pyproj import Geod

_GEOD = Geod(ellps="WGS84")


@dataclass(frozen=True)
class Region:
    key: str
    name: str
    kind: str          # "fixture" | "mode-popular" | "homeland"
    modes: tuple[str, ...]   # which schemas this region is a *designed* test of
    south: float
    west: float
    north: float
    east: float
    note: str

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

    def per_1000km2(self, count: int) -> float:
        return round(count / self.area_km2 * 1000, 1)

    def tiles(self, n: int) -> list[str]:
        """An n x n grid of Overpass bboxes.

        A full-region `out geom` pull over a dense footway network draws a 504 from the
        gateway while the status endpoint still reports free slots — that is the gateway
        cutting off a long response, not rate limiting (SPIKE-04 hit the same wall).
        Ways crossing a tile boundary are returned by both tiles and de-duplicated by id
        on merge; `length_m` comes from the *clipped* geometry Overpass returns, so a
        way spanning two tiles keeps only the longer of its two clipped halves rather
        than being double-counted. See `probe.merge_ways`.
        """
        dlat = (self.north - self.south) / n
        dlon = (self.east - self.west) / n
        return [
            f"{self.south + i * dlat},{self.west + j * dlon},"
            f"{self.south + (i + 1) * dlat},{self.west + (j + 1) * dlon}"
            for i in range(n) for j in range(n)
        ]


REGIONS: tuple[Region, ...] = (
    # ------------------------------------------------------------- fixtures
    Region(
        key="boulder", name="Boulder, CO", kind="fixture", modes=("hiking", "mtb"),
        south=39.98, west=-105.30, north=40.04, east=-105.23,
        note="`spikes/shared/regions.py` verbatim. Mountain-adjacent city; SPIKE-03 "
             "measured 81.7% surface coverage on its bike graph — the best-attributed "
             "of the three fixtures, which makes it the fixture most likely to carry "
             "a niche schema if any of them do.",
    ),
    Region(
        key="davis", name="Davis, CA", kind="fixture", modes=("hiking", "mtb"),
        south=38.53, west=-121.78, north=38.57, east=-121.71,
        note="Flat cycling town, 34.4% surface coverage. Included for the same reason "
             "SPIKE-03 included it: it is where a schema should honestly come back "
             "empty, and the app must not manufacture an answer.",
    ),
    Region(
        key="viroqua", name="Viroqua, WI (Driftless)", kind="fixture",
        modes=("hiking", "mtb", "nordic"),
        south=43.48, west=-91.00, north=43.62, east=-90.80,
        note="Rural coulee country, 24.5% surface coverage — genuinely gravel, "
             "genuinely steep, and thinly mapped. The Driftless also has real nordic "
             "skiing, so it is a second nordic datapoint at fixture density.",
    ),

    # -------------------------------------------------- mode-popular (North America)
    Region(
        key="whites", name="White Mountains, NH", kind="mode-popular", modes=("hiking",),
        south=44.00, west=-71.75, north=44.40, east=-71.15,
        note="Franconia Notch, the Pemigewasset Wilderness, the Presidential Range. "
             "The most heavily hiked technical terrain in the eastern US, with an "
             "unusually organised trail community (AMC) and above-continent-average "
             "OSM trail mapping. The strongest North American `sac_scale` case there is.",
    ),
    Region(
        key="bentonville", name="Bentonville / Bella Vista, AR", kind="mode-popular",
        modes=("mtb",),
        south=36.15, west=-94.35, north=36.45, east=-93.95,
        note="Self-described mountain-biking capital of the world: several hundred "
             "miles of purpose-built, professionally signed, IMBA-graded trail with a "
             "funded trail organisation behind it. If `mtb:scale:imba` — the North "
             "American scale — is used anywhere on the continent, it is used here.",
    ),
    Region(
        key="methow", name="Methow Valley, WA", kind="mode-popular", modes=("nordic",),
        south=48.40, west=-120.60, north=48.80, east=-120.10,
        note="Winthrop / Mazama / Sun Mountain — the largest groomed cross-country ski "
             "network in the United States (~200 km, MVSTA-groomed and signed by "
             "difficulty on the ground). The strongest North American `piste:difficulty` "
             "case.",
    ),

    # ------------------------------------------------------------- homeland
    Region(
        key="tyrol", name="Innsbruck / Seefeld, Tyrol, AT", kind="homeland",
        modes=("hiking", "mtb", "nordic"),
        south=47.10, west=11.10, north=47.40, east=11.60,
        note="Where these schemas come from. `sac_scale` is the Swiss Alpine Club's, "
             "`mtb:scale` is the German MTB community's; both entered OSM through the "
             "people who wrote them. Seefeld (nordic world-championship venue) sits in "
             "the same box. This is the upper bound the North American numbers are read "
             "against — and it is also the only region with enough tagged ways to run "
             "the thinning experiment in `degrade.py`.",
    ),
)

REGIONS_BY_KEY = {r.key: r for r in REGIONS}

#: Tile grid per region. The fixtures are small enough to fetch whole; the larger
#: boxes are quartered so one gateway timeout costs one tile, not the region.
TILES = {"boulder": 1, "davis": 1, "viroqua": 1,
         "whites": 2, "bentonville": 2, "methow": 2, "tyrol": 3}


if __name__ == "__main__":
    for r in REGIONS:
        print(f"{r.key:12} {r.kind:13} {r.area_km2:8,.0f} km2   "
              f"{'/'.join(r.modes):18} {r.name}")
