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

The sub-weights and gates were calibrated by **SPIKE-A** (issue #158,
2026-08-27) against real OSM extracts in three trip-sized bboxes — Asheville
NC, the Lower Wisconsin Riverway, and the San Gabriel foothills. See
`spikes/SPIKE-A/results/RESULTS.md`; the golden candidate sets that lock this
ruleset's output live in `core/tests/fixtures/golden_candidates/`. The two
structural findings that changed code rather than values: bare-presence
qualification is not enough (`Qualification.requires_value`), and
`natural=peak` cannot be gated by any single attribute in mountain terrain.

The `provision`-affinity rows carry the utility-amenity coverage FR104's
cluster proposals are built from (ARCH Q16). `docs/osm_reference.md` was
scoped to a touring cyclist's *sights* and cycling infrastructure — it is a
directional working reference, never a source of truth or an allowlist; the
OSM wiki (`Key:amenity` etc.) is. FR104's two worked examples — "toilet +
drinking water + shelter" and "café + restroom + bike repair station" —
were inexpressible until these rows existed.
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

# A layer taxonomy is just a tuple of rules — the built-in `TAXONOMY` below is
# one, and a plugin `LayerProvider` (ARCH §14.2, story N5) supplies its own of
# the same shape. ARCH's line "each type declares a primary role affinity and a
# salience weight" is `TypeRule` verbatim, so there is no rival record type.
TypeTaxonomy = tuple["TypeRule", ...]


@dataclass(frozen=True)
class Qualification:
    """FR98(b) — a displayability gate, not a score.

    Satisfied if any of `requires_any`'s tag keys carries a non-empty value,
    if any `requires_value` key carries one of its listed values, or if
    `min_area_m2` is set and the feature's area meets it. A rule with none of
    the three is unconditionally satisfied (most types never over-trigger and
    need no gate at all).

    `requires_value` exists because SPIKE-A found bare-presence gates are not
    enough: in the San Gabriel foothills 3,988 street trees carry
    `denotation=avenue` — a value meaning *row of trees along a street*, the
    opposite of notable — so `requires_any=("denotation",)` passed every one
    of them. `natural=tree` now demands `denotation ∈ {natural_monument, …}`.
    """

    requires_any: tuple[str, ...] = ()
    requires_value: Mapping[str, tuple[str, ...]] = field(default_factory=dict)
    min_area_m2: float | None = None

    def satisfied_by(self, tags: Mapping[str, str], area_m2: float | None) -> bool:
        if not self.requires_any and not self.requires_value and self.min_area_m2 is None:
            return True
        if any(tags.get(k) for k in self.requires_any):
            return True
        if any(tags.get(k) in allowed for k, allowed in self.requires_value.items()):
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
    # Values below the split line were added by SPIKE-A from the values that
    # actually appear in the NC / WI / SoCal extracts: `historic=district`
    # (a whole conservation area) is the strongest thing the wildcard sees
    # and was scoring 0.2; `historic=yes`/`building` are the noisy long tail.
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
            # --- SPIKE-A additions (measured 2026-08-27) ---
            "district": 0.9,
            "citywalls": 0.85,
            "aqueduct": 0.7,
            "railway_station": 0.6,
            "train_station": 0.6,
            "tomb": 0.55,
            "aircraft": 0.5,
            "locomotive": 0.5,
            "ship": 0.5,
            "building": 0.35,
            "house": 0.35,
            "yes": 0.05,
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
        # SPIKE-A: a bare `denotation` presence check let 4,149 street trees
        # through in San Gabriel (3,988 of them `denotation=avenue`). The
        # notable values are these four; everything else is a street or
        # garden tree. Zero tree candidates survived in all three regions
        # after this change — which is the correct answer, not a regression.
        qualification=Qualification(requires_value={
            "denotation": ("natural_monument", "landmark", "memorial", "historic"),
        }),
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
    # FR104 / ARCH Q16 — the provision-oriented mapping pass. Co-locatable
    # utility amenities, sourced from the OSM wiki (`Key:amenity`), not from
    # `docs/osm_reference.md`, which never carried them. All `provision`
    # affinity, so a cluster of any of them proposes a rest-stop / provision
    # anchor (ARCH D47). Seed weights like every other row here — SPIKE-A
    # calibrates against real regional extracts, it does not gate.
    TypeRule(layer="amenity", key="amenity", value="toilets", base_weight=0.5,
              role_affinity="provision"),
    TypeRule(layer="amenity", key="amenity", value="water_point", base_weight=0.45,
              role_affinity="provision"),
    TypeRule(layer="amenity", key="amenity", value="shower", base_weight=0.4,
              role_affinity="provision"),
    TypeRule(layer="amenity", key="amenity", value="cafe", base_weight=0.55,
              role_affinity="provision"),
    TypeRule(layer="amenity", key="amenity", value="restaurant", base_weight=0.55,
              role_affinity="provision"),
    TypeRule(layer="amenity", key="amenity", value="fast_food", base_weight=0.45,
              role_affinity="provision"),
    TypeRule(layer="amenity", key="amenity", value="pharmacy", base_weight=0.5,
              role_affinity="provision"),
    TypeRule(layer="amenity", key="amenity", value="bicycle_repair_station", base_weight=0.6,
              role_affinity="provision"),
    TypeRule(layer="amenity", key="amenity", value="compressed_air", base_weight=0.45,
              role_affinity="provision"),
    # SPIKE-A: peak was 0.8 — high enough that 61 named knolls in the French
    # Broad valley outranked every museum and viewpoint. In a mountain region
    # every bump is named and carries `ele`, so no single attribute gates it;
    # the fix is a lower base weight until SPIKE-B can scale it by prominence
    # and corridor proximity.
    TypeRule(layer="natural", key="natural", value="peak", base_weight=0.55,
              role_affinity="narrative"),
    TypeRule(layer="natural", key="natural", value="spring", base_weight=0.6,
              role_affinity="provision"),
    # SPIKE-A: bridge was ungated at 0.3 — 141 in San Gabriel, 30 in
    # Asheville. `name` does NOT gate it: 66 of the 68 named San Gabriel
    # bridges are named after the road they carry ("Commonwealth Avenue",
    # "I 210") — cartographic labelling, not notability. Only a heritage /
    # wiki signal separates the Colorado Street Bridge from a freeway
    # overpass, so that is the gate.
    TypeRule(layer="man_made", key="man_made", value="bridge", base_weight=0.3,
              role_affinity="narrative",
              qualification=Qualification(requires_any=("heritage", "wikidata", "wikipedia"))),
    # SPIKE-A additions — `osm_reference.md` flags both as strong fits and
    # neither was in the taxonomy, so they fell to the unmatched tail.
    # `leisure=nature_reserve` is low-density and effectively always notable;
    # `amenity=place_of_worship` is common (165 in Asheville) so it is gated
    # to the architecturally-recognised subset (heritage / wiki signal).
    TypeRule(layer="leisure", key="leisure", value="nature_reserve", base_weight=0.7,
              role_affinity="narrative"),
    TypeRule(layer="sight", key="amenity", value="place_of_worship", base_weight=0.45,
              role_affinity="narrative",
              qualification=Qualification(requires_any=("heritage", "wikidata", "wikipedia"))),
)


def match_in(taxonomy: TypeTaxonomy, tags: Mapping[str, str]) -> TypeRule | None:
    """The `taxonomy` entry for `tags`, or None if nothing recognizes it.

    An exact `key=value` rule wins over a wildcard on the same key, so a
    named ``historic=memorial`` scores off its own entry rather than the
    wildcard's sub-weight table.

    Parameterised on `taxonomy` rather than closed over the module-global
    `TAXONOMY` so a plugin `LayerProvider` (ARCH §14.2, story N5) can score
    its own feature types against its own declared taxonomy without its rows
    being merged into the core table — the core-code edit ARCH §14.4 forbids.
    """
    exact = None
    wildcard = None
    for rule in taxonomy:
        if rule.key not in tags:
            continue
        if not rule.is_wildcard and tags[rule.key] == rule.value:
            exact = rule
        elif rule.is_wildcard and wildcard is None:
            wildcard = rule
    return exact or wildcard


def match(tags: Mapping[str, str]) -> TypeRule | None:
    """`match_in` against the built-in `TAXONOMY`. Kept as the name the
    notability filter and existing callers use."""
    return match_in(TAXONOMY, tags)


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
