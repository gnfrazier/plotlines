"""Layer taxonomy — PRD FR97/FR98, ARCH §4.3/§14.2 D47.

Spans the OSM sightseeing/amenity/natural/historic/leisure/man-made taxonomy
(FR97's AC). Every type declares a primary role affinity and a salience
weight (ARCH D47) so the built-in OSM layers are expressed the same way a
plugin's `LayerProvider` would declare its own taxonomy — no privileged
internal path (ARCH §14.2).

`historic=*` is the seed case for FR98(a): a wildcard type is sub-weighted by
value wherever its values differ materially in notability, so a castle
outranks a boundary stone rather than scoring identically. `Qualification` is
FR98(b): a type whose instance density in a bbox exceeds a reviewable
threshold (street trees, park polygons, generic "attraction" pins, silos and
water towers) requires a qualifying attribute before it is displayable at
all — this is a seed list, not exhaustive; a new layer is qualified by
applying the same rule, not by being added here (FR98).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Mapping

# FR97 — the six OSM groups the layer catalog spans. A plugin dataset (N5)
# is a seventh kind of layer id, declared by its own LayerProvider, not a
# member of this frozenset.
LAYERS: frozenset[str] = frozenset({
    "sight", "amenity", "natural", "historic", "leisure", "man_made",
})

# Below this, a wildcard value with no cataloged sub-weight scores as
# unremarkable rather than notable — the seed case (historic=*) names the
# values that matter; anything else falls to the taxonomy's own floor.
_UNCATALOGED_WILDCARD_WEIGHT = 0.2


@dataclass(frozen=True)
class Qualification:
    """FR98(b) — a displayability gate, not a score.

    Satisfied if any of `requires_any`'s tag keys carries a non-empty value,
    or if `min_area_m2` is set and the feature's area meets it. A rule with
    neither is unconditionally satisfied (most types never over-trigger and
    need no gate at all).
    """

    requires_any: tuple[str, ...] = ()
    min_area_m2: float | None = None

    def satisfied_by(self, tags: Mapping[str, str], area_m2: float | None) -> bool:
        if not self.requires_any and self.min_area_m2 is None:
            return True
        if any(tags.get(k) for k in self.requires_any):
            return True
        if self.min_area_m2 is not None and area_m2 is not None:
            return area_m2 >= self.min_area_m2
        return False


@dataclass(frozen=True)
class TypeRule:
    """One taxonomy entry: an OSM `key=value` (or `key=*` wildcard) mapped to
    a layer, a base salience weight in 0..1, a primary role affinity
    (ARCH D47's narrative | provision | station), and this type's
    qualification gate.

    `value_weights` sub-weights a wildcard rule by the feature's actual tag
    value (FR98(a)); it is empty and unused for a non-wildcard rule.
    """

    layer: str
    key: str
    value: str  # "*" for a wildcard rule
    base_weight: float
    role_affinity: str
    qualification: Qualification = field(default_factory=Qualification)
    value_weights: Mapping[str, float] = field(default_factory=dict)

    @property
    def is_wildcard(self) -> bool:
        return self.value == "*"


# Data, not an exhaustive product catalog — a seed set spanning all six
# layers (FR97's AC) plus every over-triggering tag ARCH/FR98 names by
# example. Extending coverage means adding rows here, never branching code.
TAXONOMY: tuple[TypeRule, ...] = (
    # historic=* — FR98(a)'s seed case. A castle, fort, or archaeological
    # site must outrank a boundary stone or milestone, not score identically.
    TypeRule(
        layer="historic", key="historic", value="*", base_weight=0.3,
        role_affinity="narrative",
        value_weights={
            "castle": 0.95,
            "fort": 0.9,
            "archaeological_site": 0.85,
            "monument": 0.75,
            "ruins": 0.7,
            "battlefield": 0.65,
            "wayside_shrine": 0.35,
            "wayside_cross": 0.3,
            "boundary_stone": 0.1,
            "milestone": 0.1,
        },
    ),
    TypeRule(
        layer="historic", key="historic", value="memorial", base_weight=0.4,
        role_affinity="narrative",
    ),
    # Over-triggering seeds named in FR98(b).
    TypeRule(
        layer="natural", key="natural", value="tree", base_weight=0.5,
        role_affinity="narrative",
        qualification=Qualification(requires_any=("denotation",)),
    ),
    TypeRule(
        layer="leisure", key="leisure", value="park", base_weight=0.4,
        role_affinity="narrative",
        qualification=Qualification(requires_any=("name",), min_area_m2=20_000.0),
    ),
    TypeRule(
        layer="sight", key="tourism", value="attraction", base_weight=0.6,
        role_affinity="narrative",
        qualification=Qualification(requires_any=("name",)),
    ),
    TypeRule(
        layer="man_made", key="man_made", value="silo", base_weight=0.3,
        role_affinity="narrative",
        qualification=Qualification(requires_any=("name", "heritage")),
    ),
    TypeRule(
        layer="man_made", key="man_made", value="water_tower", base_weight=0.3,
        role_affinity="narrative",
        qualification=Qualification(requires_any=("name", "heritage")),
    ),
    TypeRule(
        layer="man_made", key="man_made", value="tower", base_weight=0.35,
        role_affinity="narrative",
        qualification=Qualification(requires_any=("name",)),
    ),
    # Ordinary, non-over-triggering seeds spanning the remaining layers.
    TypeRule(layer="sight", key="tourism", value="viewpoint", base_weight=0.7,
              role_affinity="narrative"),
    TypeRule(layer="sight", key="tourism", value="museum", base_weight=0.7,
              role_affinity="narrative"),
    TypeRule(layer="amenity", key="amenity", value="drinking_water", base_weight=0.5,
              role_affinity="provision"),
    TypeRule(layer="amenity", key="amenity", value="shelter", base_weight=0.4,
              role_affinity="provision"),
    TypeRule(layer="amenity", key="leisure", value="sauna", base_weight=0.4,
              role_affinity="provision"),
    TypeRule(layer="natural", key="natural", value="peak", base_weight=0.8,
              role_affinity="narrative"),
    TypeRule(layer="natural", key="natural", value="spring", base_weight=0.6,
              role_affinity="provision"),
    TypeRule(layer="man_made", key="man_made", value="bridge", base_weight=0.3,
              role_affinity="narrative"),
)


def match(tags: Mapping[str, str]) -> TypeRule | None:
    """The taxonomy entry for `tags`, or None if nothing recognizes it.

    An exact `key=value` rule wins over a wildcard on the same key, so a
    named ``historic=memorial`` scores off its own entry rather than the
    wildcard's sub-weight table.
    """
    exact = None
    wildcard = None
    for rule in TAXONOMY:
        if rule.key not in tags:
            continue
        if not rule.is_wildcard and tags[rule.key] == rule.value:
            exact = rule
        elif rule.is_wildcard and wildcard is None:
            wildcard = rule
    return exact or wildcard


def weight_for(rule: TypeRule, tags: Mapping[str, str]) -> float:
    """FR98(a) — a wildcard rule is sub-weighted by the feature's own value;
    a value absent from the sub-weight table floors to the taxonomy's
    uncataloged-wildcard weight rather than the wildcard's `base_weight`,
    since an unlisted `historic=*` value is exactly the "boundary stone we
    never thought to name" case the rule exists to catch.
    """
    if not rule.is_wildcard:
        return rule.base_weight
    return rule.value_weights.get(tags.get(rule.key, ""), _UNCATALOGED_WILDCARD_WEIGHT)
