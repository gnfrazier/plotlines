"""Notability filter and salience scoring — PRD FR98, ARCH §4.3.

`score_notability` is Stage 1 of the authoring pipeline (bbox -> layer
selection -> notability filter -> display -> ...). It never produces canon
(ARCH P10): a `Candidate` is data the trip considered, not an anchor.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Mapping

from .taxonomy import match, weight_for

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
RULESET_VERSION = "1.2.0"


@dataclass(frozen=True)
class RawFeature:
    """One feature as extracted from a LayerProvider (ARCH §14.2), before
    notability filtering. `area_m2` is set for polygon features only —
    FR98(b)'s `leisure=park` area-threshold qualification reads it."""

    id: str
    coord: tuple[float, float]  # [lon, lat]
    tags: Mapping[str, str] = field(default_factory=dict)
    area_m2: float | None = None


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
    """
    live = set(live_layers)
    out: list[Candidate] = []
    for feature in features:
        rule = match(feature.tags)
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
        ))
    out.sort(key=lambda c: c.salience, reverse=True)
    return out
