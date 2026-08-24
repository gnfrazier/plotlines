"""LayerProvider — the extraction seam for candidate features (ARCH §14.2,
D40, D47). Only the OSM-backed implementation lives here for MVP; a
plugin's own LayerProvider ships as its own package (FR100 — Leg 2.5's
data-input contract, not this story).

`OsmLayerProvider` is deliberately built the way any plugin `LayerProvider`
would be: it reads `taxonomy.TAXONOMY` for what to ask Overpass for, rather
than a privileged internal tag list (ARCH §14.2's "proof of realness" test —
if the built-in layers can't be expressed this way, the interface is wrong).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Protocol

from .notability import RawFeature
from .taxonomy import TAXONOMY

_EARTH_R_M = 6_371_000.0


@dataclass(frozen=True)
class BBox:
    west: float
    south: float
    east: float
    north: float


class LayerProvider(Protocol):
    """ARCH §14.2 — what a curation data layer, built-in or plugin, must
    supply: a licence (enforced at registration, not this story — ARCH
    §12.2/D45), and both point and area geometry for a bbox+layer-set query
    in one call."""

    licence: str

    def fetch(self, bbox: BBox, layers: set[str]) -> list[RawFeature]: ...


def osm_tags_for(layers: set[str]) -> dict[str, "bool | list[str]"]:
    """The `tags=` filter `osmnx.features_from_bbox` expects, derived from
    the taxonomy rather than hand-maintained separately from it. A wildcard
    rule (`historic=*`) asks Overpass for the whole key; a non-wildcard rule
    asks for its specific value alongside any sibling values already
    requested for that key.
    """
    tags: dict[str, object] = {}
    for rule in TAXONOMY:
        if rule.layer not in layers:
            continue
        if rule.is_wildcard:
            tags[rule.key] = True
            continue
        existing = tags.get(rule.key)
        if existing is True:
            continue  # a wildcard on this key already asks for everything
        values = set(existing) if isinstance(existing, (set, list)) else set()
        values.add(rule.value)
        tags[rule.key] = values
    return {k: (sorted(v) if isinstance(v, set) else v) for k, v in tags.items()}


def _approx_area_m2(geom, at_lat: float) -> float:
    """A rough equirectangular-projection area estimate — enough to clear
    FR98(b)'s area-threshold qualification check without pulling a
    projection library into this seam for one comparison against a round
    number (20,000 m^2). Not appropriate for anything precision-sensitive;
    `graph/loader.py`'s own haversine helpers are the pattern this follows
    for "good enough at MVP scale, cheap, no extra dependency."""
    import math

    lat_rad = math.radians(at_lat)
    m_per_deg_lat = math.pi * _EARTH_R_M / 180.0
    m_per_deg_lon = m_per_deg_lat * math.cos(lat_rad)
    minx, miny, maxx, maxy = geom.bounds
    # geom.area is in square degrees; rescale each axis to metres rather
    # than multiplying by a single squared scalar, since a degree of
    # longitude and a degree of latitude are not the same length.
    if (maxx - minx) <= 0 or (maxy - miny) <= 0:
        return 0.0
    return geom.area * m_per_deg_lon * m_per_deg_lat


def feature_from_geometry(feature_id: str, geometry, tags: dict[str, str]) -> RawFeature | None:
    """Pure conversion from a Shapely geometry + its OSM tags to a
    `RawFeature` — split out from `OsmLayerProvider.fetch` so it is
    unit-testable without a live Overpass call (mirrors how
    `graph/loader.py` keeps its geometry math free of the network/disk read
    that feeds it).
    """
    if geometry is None or geometry.is_empty:
        return None
    centroid = geometry.centroid
    area_m2 = None
    if geometry.geom_type in ("Polygon", "MultiPolygon"):
        area_m2 = _approx_area_m2(geometry, centroid.y)
    return RawFeature(id=feature_id, coord=(centroid.x, centroid.y), tags=tags, area_m2=area_m2)


class OsmLayerProvider:
    """ARCH §14.2's proof-of-realness test: the built-in OSM
    sightseeing/amenity/natural/historic/leisure/man-made layers, expressed
    *as* a LayerProvider rather than a privileged internal extraction path.
    """

    licence = "ODbL"

    def fetch(self, bbox: BBox, layers: set[str]) -> list[RawFeature]:
        import osmnx as ox

        tags = osm_tags_for(layers)
        if not tags:
            return []
        gdf = ox.features_from_bbox((bbox.west, bbox.south, bbox.east, bbox.north), tags)
        return [f for f in self._features_from_gdf(gdf) if f is not None]

    @staticmethod
    def _features_from_gdf(gdf) -> Iterable[RawFeature | None]:
        for idx, row in gdf.iterrows():
            feature_id = "/".join(str(p) for p in (idx if isinstance(idx, tuple) else (idx,)))
            tags = {
                str(k): str(v) for k, v in row.items()
                if k != "geometry" and v is not None and str(v) != "nan"
            }
            yield feature_from_geometry(feature_id, row.geometry, tags)
