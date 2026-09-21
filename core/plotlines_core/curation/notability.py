"""Notability filter and salience scoring — PRD FR98, ARCH §4.3.

`score_notability` is Stage 1 of the authoring pipeline (bbox -> layer
selection -> notability filter -> display -> ...). It never produces canon
(ARCH P10): a `Candidate` is data the trip considered, not an anchor.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Mapping

from .taxonomy import TypeTaxonomy, TAXONOMY, match_in, weight_for

# ARCH §4.2's candidate cache key is `(bbox, layer_set_version, filter_ruleset_version)`.
# Bump this when TAXONOMY's rules change so a stale ruleset version is never
# read as still describing the current scores.
#   1.1.0 — FR104 / ARCH Q16 provision-oriented pass: added the utility
#           amenities (toilets, cafe, restaurant, pharmacy, shower, bike
#           repair, …) the provision cluster is built from.
#   1.2.0 — SPIKE-A (#158): calibrated historic=* sub-weights and the
#           qualification gates against NC/WI/SoCal extracts. natural=tree
#           now gates on denotation *value*; man_made=bridge gated;
#           natural=peak weight 0.8→0.55; added leisure=nature_reserve and
#           amenity=place_of_worship.
#   1.3.0 — Story C7 (issue #43): added the lodging/campground types
#           (tourism=hotel/hostel/camp_site/alpine_hut/wilderness_hut) under
#           the "amenity" layer with role_affinity="station" — a place a
#           Character stops and stays, not a sight or a utility. No existing
#           row moved; the golden set is unchanged except this version stamp.
RULESET_VERSION = "1.3.0"


#: FR100 / ARCH D37 — the two geometry kinds a feature can carry beyond its
#: representative point. A `polygon` is one closed exterior ring (holes are
#: not carried: the candidate tier needs an extent and a boundary, and the
#: payload's `polygon` gains holes only when an Author draws them). A
#: `line` is an open path — a scenic byway, a rail-trail, a ridge — which is
#: the shape SPIKE-H §3 measured collapsing to a centroid (issue #403).
SHAPE_KINDS = ("polygon", "line")

_GEOJSON_TYPE = {"polygon": "Polygon", "line": "LineString"}
_KIND_FOR_GEOJSON = {v: k for k, v in _GEOJSON_TYPE.items()}


@dataclass(frozen=True)
class Shape:
    """A feature's own geometry, kind-tagged so a consumer never has to
    guess whether a coordinate run is a boundary or a path. `colocate.py`
    clips a polygon with Sutherland-Hodgman and takes its area centroid; a
    line put through the same code would be silently closed into a bogus
    polygon — the discriminator is what makes carrying lines safe.

    `coords` are (lon, lat) pairs. A polygon's are its closed exterior ring
    (>= 4 positions, first == last); a line's are >= 2 vertices."""

    kind: str
    coords: tuple[tuple[float, float], ...]

    def __post_init__(self) -> None:
        if self.kind not in SHAPE_KINDS:
            raise ValueError(f"shape kind {self.kind!r} not in {SHAPE_KINDS}")
        n = len(self.coords)
        if self.kind == "polygon":
            if n < 4:
                raise ValueError(f"polygon ring has {n} positions; needs at least 4")
            if tuple(self.coords[0]) != tuple(self.coords[-1]):
                raise ValueError("polygon ring is not closed: first position must equal last")
        elif n < 2:
            raise ValueError(f"line has {n} positions; needs at least 2")

    @property
    def extent(self) -> tuple[float, float, float, float]:
        """(west, south, east, north) of the coordinate run."""
        lons = [p[0] for p in self.coords]
        lats = [p[1] for p in self.coords]
        return (min(lons), min(lats), max(lons), max(lats))

    def to_geojson(self) -> dict:
        """RFC 7946 geometry object — the same vocabulary the trip payload's
        `polygon` / `line_string` $defs already speak, minus `source`, which
        is a promotion-time fact rather than an extraction-time one."""
        coords = [[x, y] for x, y in self.coords]
        return {
            "type": _GEOJSON_TYPE[self.kind],
            "coordinates": [coords] if self.kind == "polygon" else coords,
        }

    @classmethod
    def from_geojson(cls, doc: Mapping) -> "Shape":
        try:
            kind = _KIND_FOR_GEOJSON[doc["type"]]
            raw = doc["coordinates"]
            if kind == "polygon":
                raw = raw[0]  # exterior ring; further rings are not carried
            coords = tuple((float(p[0]), float(p[1])) for p in raw)
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            raise ValueError(f"not a Polygon/LineString geometry: {exc}") from exc
        return cls(kind=kind, coords=coords)


@dataclass(frozen=True)
class RawFeature:
    """One feature as extracted from a LayerProvider (ARCH §14.2), before
    notability filtering. `area_m2` is set for polygon features only —
    FR98(b)'s `leisure=park` area-threshold qualification reads it."""

    id: str
    coord: tuple[float, float]  # [lon, lat]
    tags: Mapping[str, str] = field(default_factory=dict)
    area_m2: float | None = None
    # FR100 / ARCH D37 — the feature's own polygon or line, so a plugin's
    # area (FR108 rest-day-on-a-polygon, area-entry triggers) or a byway's
    # path survives to something downstream can read, not just a
    # representative point. `None` for a point feature.
    geometry: Shape | None = None


@dataclass(frozen=True)
class Candidate:
    """A notability-scored feature, ranked but not promoted. FR99 — salience
    is a score, not a binary verdict, and is what the map renders as size,
    weight, or opacity."""

    id: str
    coord: tuple[float, float]
    layer: str
    salience: float
    role_affinity: str
    tags: Mapping[str, str]
    title: str | None = None
    # Carried through from the RawFeature so an area or line candidate is
    # not indistinguishable from a pin once scored (SPIKE-H §3). Both `None`
    # for a point.
    area_m2: float | None = None
    geometry: Shape | None = None


def score_with_taxonomy(
    features: Iterable[RawFeature],
    taxonomy: TypeTaxonomy,
    live_layers: Iterable[str],
) -> list[Candidate]:
    """`score_notability`'s body, parameterised on the taxonomy to match
    against instead of closed over the module-global `TAXONOMY`.

    This is what a plugin `LayerProvider.fetch_candidates` calls against its
    *own* declared taxonomy (ARCH §14.2, story N5): a provider scores against
    its own types and returns finished `Candidate`s, so a plugin's rows never
    have to be merged into the core table — the core-code edit ARCH §14.4
    forbids. Ranking, the qualification gate (FR98(b)) and the uncatalogued-
    wildcard floor are identical to the built-in path.
    """
    live = set(live_layers)
    out: list[Candidate] = []
    for feature in features:
        rule = match_in(taxonomy, feature.tags)
        if rule is None or rule.layer not in live:
            continue
        if not rule.qualification.satisfied_by(feature.tags, feature.area_m2):
            continue
        out.append(Candidate(
            id=feature.id,
            coord=feature.coord,
            layer=rule.layer,
            salience=weight_for(rule, feature.tags),
            role_affinity=rule.role_affinity,
            tags=dict(feature.tags),
            title=feature.tags.get("name"),
            area_m2=feature.area_m2,
            geometry=feature.geometry,
        ))
    out.sort(key=lambda c: c.salience, reverse=True)
    return out


def score_notability(
    features: Iterable[RawFeature],
    live_layers: Iterable[str],
) -> list[Candidate]:
    """FR98 — every candidate passes the notability filter before display.

    A feature whose type isn't in the taxonomy, whose layer isn't live, or
    that fails its qualification gate (FR98(b)) never becomes a Candidate —
    it is filtered out, not scored low. Results are ranked by salience,
    highest first, since that ranking is what a bbox-scale map needs to
    decide what to draw first (ARCH A21/Q15).

    Delegates to `score_with_taxonomy` against the built-in `TAXONOMY` — the
    same matching logic every plugin layer runs against its own.
    """
    return score_with_taxonomy(features, TAXONOMY, live_layers)
