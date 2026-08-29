"""Web-Mercator viewport math — just enough to answer "how many candidates land
in a 1280x720 window at zoom z, centred on the bbox centroid?"

No dependencies. Standard slippy-map formulas (EPSG:3857, 256 px tiles).
"""

from __future__ import annotations

import math

TILE_PX = 256.0


def _lon_to_world_x(lon: float, zoom: int) -> float:
    return (lon + 180.0) / 360.0 * TILE_PX * (2**zoom)


def _lat_to_world_y(lat: float, zoom: int) -> float:
    s = math.sin(math.radians(lat))
    s = min(max(s, -0.9999), 0.9999)
    y = 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)
    return y * TILE_PX * (2**zoom)


def viewport_bbox(
    center_lat: float, center_lon: float, zoom: int, px_w: int, px_h: int
) -> tuple[float, float, float, float]:
    """Return (south, west, north, east) of the window in degrees."""
    cx = _lon_to_world_x(center_lon, zoom)
    cy = _lat_to_world_y(center_lat, zoom)
    scale = TILE_PX * (2**zoom)

    west = (cx - px_w / 2) / scale * 360.0 - 180.0
    east = (cx + px_w / 2) / scale * 360.0 - 180.0

    def _world_y_to_lat(wy: float) -> float:
        n = math.pi - 2 * math.pi * (wy / scale)
        return math.degrees(math.atan(math.sinh(n)))

    north = _world_y_to_lat(cy - px_h / 2)
    south = _world_y_to_lat(cy + px_h / 2)
    return south, west, north, east


def in_bbox(lat: float, lon: float, bbox: tuple[float, float, float, float]) -> bool:
    s, w, n, e = bbox
    return s <= lat <= n and w <= lon <= e


def bbox_of(points: list[tuple[float, float]]) -> tuple[float, float, float, float]:
    lats = [p[0] for p in points]
    lons = [p[1] for p in points]
    return min(lats), min(lons), max(lats), max(lons)


def centroid(points: list[tuple[float, float]]) -> tuple[float, float]:
    return sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points)


def screen_xy(
    lat: float, lon: float, center_lat: float, center_lon: float,
    zoom: int, px_w: int, px_h: int,
) -> tuple[float, float]:
    """Pixel position of a point within the window (origin = window top-left)."""
    cx = _lon_to_world_x(center_lon, zoom)
    cy = _lat_to_world_y(center_lat, zoom)
    x = _lon_to_world_x(lon, zoom) - cx + px_w / 2
    y = _lat_to_world_y(lat, zoom) - cy + px_h / 2
    return x, y


def geodesic_area_m2(ring: list[tuple[float, float]]) -> float:
    """Approximate polygon area, spherical excess on an equirectangular
    projection about the ring's mean latitude. Good to a few percent — SPIKE-A
    used the same order of approximation for its park-area gate."""
    if len(ring) < 3:
        return 0.0
    r = 6_371_000.0
    lat0 = math.radians(sum(p[0] for p in ring) / len(ring))
    xs = [math.radians(lon) * r * math.cos(lat0) for _, lon in ring]
    ys = [math.radians(lat) * r for lat, _ in ring]
    area = 0.0
    for i in range(len(ring)):
        j = (i + 1) % len(ring)
        area += xs[i] * ys[j] - xs[j] * ys[i]
    return abs(area) / 2.0
