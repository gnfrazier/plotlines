"""The test payload — one real routed segment, shaped like what F3 actually exports.

Deliberately concrete, per the spike question: "a track, elevation, and several
course_points of distinct types (turn, water, food, danger, generic) for a real
routed segment." The geometry traces the French Broad River Greenway in
Asheville, NC — inside SPIKE-A's `avl` region, so the place names and the
notability vocabulary line up with the rest of the pipeline.

Three v2.0 clauses the spike issue added are baked in:

  * an **unrevealed** narrative plot point (`REVEAL_CANARY`), whose note text
    must be absent from the output bytes (punch-list §6A.2, first exercised here);
  * an **area anchor** (FR108) — a filled polygon, no obvious FIT representation;
  * a **role geometry offset** (FR107) — a station role sitting ~40 m off its
    anchor's point.

Nothing here imports from `plotlines_core`. The shapes mirror
`docs/schemas/trip_payload.schema.json` closely enough to make the mapping
in `course.py` obvious, without coupling the spike to the real model.
"""

from __future__ import annotations

import math

# canary string: if this appears anywhere in the exported bytes, reveal leaked.
REVEAL_CANARY = "CANARY-6A2 the mash tuns are under the collapsed springhouse floor"

_BASE_LAT, _BASE_LON = 35.5846, -82.5771
_START_UNIX = 1_726_000_000  # 2024-09-10T20:26:40Z — course files carry a nominal clock


def _greenway_polyline():
    """~3.2 km, 33 vertices, gently climbing 632 -> 651 m. Hand-shaped to bend
    at a real trail junction (vertex 12) and to run flat-then-up."""
    pts = []
    lat, lon = _BASE_LAT, _BASE_LON
    # leg 1 — NNE along the river, flat
    for i in range(13):
        lat += 0.00062 + 0.00003 * math.sin(i * 0.7)
        lon += 0.00021 + 0.00002 * math.cos(i * 0.5)
        ele = 632.0 + 0.4 * i
        pts.append((round(lat, 6), round(lon, 6), round(ele, 1)))
    # leg 2 — bear right at the greenway split, climb toward the depot
    for i in range(20):
        lat += 0.00018 + 0.00002 * math.sin(i * 0.9)
        lon += 0.00048 + 0.00003 * math.cos(i * 0.6)
        ele = 637.2 + 0.7 * i
        pts.append((round(lat, 6), round(lon, 6), round(ele, 1)))
    return pts


def _cumulative_distance(poly):
    out = [0.0]
    for (a_lat, a_lon, _), (b_lat, b_lon, _) in zip(poly, poly[1:]):
        out.append(out[-1] + _haversine_m(a_lat, a_lon, b_lat, b_lon))
    return out


def _haversine_m(lat1, lon1, lat2, lon2):
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def build_fixture() -> dict:
    poly = _greenway_polyline()
    dist = _cumulative_distance(poly)
    total_m = dist[-1]

    def at(frac):
        """(lat, lon, ele, distance_m) at a fraction along the polyline."""
        target = frac * total_m
        for i in range(1, len(dist)):
            if dist[i] >= target:
                span = dist[i] - dist[i - 1] or 1.0
                t = (target - dist[i - 1]) / span
                a, b = poly[i - 1], poly[i]
                return (
                    a[0] + t * (b[0] - a[0]),
                    a[1] + t * (b[1] - a[1]),
                    a[2] + t * (b[2] - a[2]),
                    target,
                )
        return (*poly[-1], total_m)

    lat_o, lon_o, _, off_dist = at(0.72)
    # ~40 m north-east offset for the FR107 station role
    lat_off = lat_o + 40.0 / 111_320.0
    lon_off = lon_o + 40.0 / (111_320.0 * math.cos(math.radians(lat_o)))

    plot_points = [
        # kind, reveal, course_point_type, name, note, position(lat,lon,dist_m)
        {
            "id": "pp-junction",
            "role": "narrative",
            "reveal": "always",
            "cp_type": "left",
            "name": "Bear left at the greenway split",
            "note": "Stay river-side; the right fork climbs to the road.",
            "pos": at(0.36),
        },
        {
            "id": "pp-spring",
            "role": "provision",
            "reveal": "always",
            "cp_type": "water",
            "name": "Riverside spring tap",
            "note": "Potable; last water before the depot.",
            "pos": at(0.20),
        },
        {
            "id": "pp-depot-cafe",
            "role": "provision",
            "reveal": "always",
            "cp_type": "food",
            "name": "Depot cafe",
            "note": "Opens 07:00. Cash only.",
            "pos": at(0.94),
        },
        {
            "id": "pp-washout",
            "role": "provision",
            "reveal": "always",          # a hazard — never subject to reveal (PRD 1.5)
            "hazard": True,
            "cp_type": "danger",
            "name": "Washout — dismount",
            "note": "Trail edge undercut after high water. Walk it.",
            "pos": at(0.58),
        },
        {
            "id": "pp-overlook",
            "role": "narrative",
            "reveal": "always",
            "cp_type": "generic",
            "name": "River overlook",
            "note": "Worth the stop.",
            "pos": at(0.47),
        },
        {
            # the reveal canary — held until arrival, must NOT reach the bytes
            "id": "pp-still-site",
            "role": "narrative",
            "reveal": "on_arrival",
            "cp_type": "generic",
            "name": "Old still site",
            "note": REVEAL_CANARY,
            "pos": at(0.83),
        },
        {
            # FR107 — a station role carried at a geometry offset from its anchor
            "id": "pp-shuttle-pickup",
            "role": "station",
            "reveal": "always",
            "cp_type": "generic",
            "name": "Shuttle pickup (offset)",
            "note": "Pin sits ~40 m off-trail at the lot.",
            "pos": (lat_off, lon_off, poly[-1][2], off_dist),
            "offset_from": "pp-depot-cafe",
        },
    ]

    area_anchors = [
        {
            # FR108 — filled polygon, no native FIT slot
            "id": "area-rail-district",
            "role": "narrative",
            "reveal": "always",
            "name": "Depot rail district",
            "polygon": [
                (poly[-1][0] + 0.0009, poly[-1][1] - 0.0011),
                (poly[-1][0] + 0.0013, poly[-1][1] + 0.0006),
                (poly[-1][0] - 0.0002, poly[-1][1] + 0.0014),
                (poly[-1][0] - 0.0011, poly[-1][1] + 0.0001),
                (poly[-1][0] - 0.0004, poly[-1][1] - 0.0012),
            ],
        }
    ]

    return {
        "trip": {"title": "French Broad Greenway — Depot Run", "sport": "cycling"},
        "segment": {
            "id": "seg-1",
            "mode": "cycling",
            "start_unix": _START_UNIX,
            "nominal_speed_mps": 4.4,     # ~15.8 km/h — TCX-style synthetic pacing
            "polyline": poly,             # (lat, lon, ele_m)
            "cumulative_m": dist,
            "total_m": total_m,
        },
        "plot_points": plot_points,
        "area_anchors": area_anchors,
        "reveal_canary": REVEAL_CANARY,
    }
