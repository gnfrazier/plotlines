"""A hand-digitised Blue Ridge Parkway alignment through the `brp` bbox.

SPIKE-B's ranking question (issue point 2, ARCH Q12) is whether corridor
proximity should dominate the ranking *once a route exists*. That needs a
route. This is the Parkway itself — the spine a Blue Ridge tour is built on —
as a lon/lat polyline, digitised coarsely (~2-5 km between vertices) from the
BRP's known alignment: Folk Art Center in Asheville, NE past Craggy Gardens,
Mount Mitchell, Little Switzerland, Gillespie Gap, Linville Falls, Grandfather
Mountain, Price Lake, to Blowing Rock.

Coarse is fine: `colocate._dist_to_polyline_m` measures perpendicular distance
to the nearest segment, and 2-5 km vertices keep that accurate to ~50 m near
the road, which is well inside `corridor_decay_m`.
"""

from __future__ import annotations

# (lon, lat), SW -> NE along the Parkway.
BRP_ROUTE: list[tuple[float, float]] = [
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
]
