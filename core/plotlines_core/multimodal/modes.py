"""The traversal-mode registry (FR10 / B1, FR130 / M1) — ARCH §6.4.

FR10 [AMENDED v2.0] names eight **traversal modes** — cycling, hiking, paddling,
cross-country skiing, packrafting, riverboarding, mountain biking, and driving — and
draws a hard line between them and **station activities** (FR109): climbing,
canyoneering, and jumaring are performed *at* a place, not *between* two, and v1.0's
filing of them under "further modes, a scoping decision" was never buildable, because
`WeightProfile` models horizontal traversal and could not have absorbed them.

FR130 states the extension path this module *is*: adding a traversal mode requires
only a new `WeightProfile` entry and its domain parameters — **no parallel scorer**.
So a mode here is a row of data, never a branch of code:

  * `weights` — the mode's default `scoring.profile.WeightProfile`. The one scoring
    function (`scoring.profile.edge_cost`) consumes it unchanged; nothing in
    `routing/` switches on `mode` to score.
  * `network_type`, `access_mode`, `base_speed_kmh`, `medium` — the domain parameters
    M1 names. `access_mode` points at an existing `routing.access.MODE_CONSTRAINTS`
    row rather than duplicating it: mountain biking is legally cycling, packrafting is
    legally paddling, and cross-country skiing is legally foot travel. A mode with no
    legality opinion of its own routes exactly as it did before A11.

`tier` records what MVP ships as first-class (cycling, hiking, paddling — PRD §10's
"Multimodal breadth": v2.0 resolves *how* further modes extend, not *which* ship
when) without removing the rest from the list. An Author can author a packrafting
passage today; what "first-class" buys is a tuned weight profile and a router that
has been measured, not the mode's existence.

`transit` is deliberately **not** a traversal mode. FR29 [AMENDED v2.0] splits access
legs in two: driving legs are *routed*, with distance, time and a cue sheet, while
train, shuttle and flight legs are *authored notes* carrying identifiers, carrier and
times. `TRANSPORT_NOTE_MODES` holds that second half — a mode value the payload
accepts and the solver never sees.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

from plotlines_core.scoring.profile import WeightProfile

#: `tier` values. "first_class" is MVP's measured, tuned set; "extended" is a mode
#: that is authorable and configured but whose weights have not been validated
#: against real routes yet.
FIRST_CLASS = "first_class"
EXTENDED = "extended"


@dataclass(frozen=True)
class TraversalMode:
    """One traversal mode, entirely as data (FR130).

    Nothing here is a code path. `weights` is what the shared scorer consumes;
    the remaining fields are M1's domain parameters, read by graph building
    (`network_type`), legality (`access_mode` → `routing.access.MODE_CONSTRAINTS`),
    and timing (`base_speed_kmh`, the seed B7 refines into per-terrain speeds).
    """

    key: str
    label: str
    tier: str
    #: `land` | `water` | `snow`. What the mode travels over — the fact that makes
    #: a riverboarding passage's endpoints a put-in and a take-out rather than a
    #: trailhead, and keeps a snow mode's season out of a summer day's defaults.
    medium: str
    weights: WeightProfile
    #: OSMnx network type for the mode's graph (`graph.regions.Region`).
    network_type: str
    #: The `routing.access.MODE_CONSTRAINTS` row governing this mode's legality,
    #: or `None` for a mode with no access opinion (it routes unconstrained).
    access_mode: str | None
    #: Flat-ground default speed. B7 (FR16) makes this Author-configurable and
    #: terrain-aware; it is a domain parameter here, not a computation.
    base_speed_kmh: float

    @property
    def is_first_class(self) -> bool:
        return self.tier == FIRST_CLASS


#: FR10's list, in the order the PRD states it. Every entry is one row of
#: configuration; adding a ninth mode means adding a row here and nothing else.
TRAVERSAL_MODES: dict[str, TraversalMode] = {
    "cycling": TraversalMode(
        key="cycling",
        label="Ride",
        tier=FIRST_CLASS,
        medium="land",
        weights=WeightProfile(name="cycling"),
        network_type="bike",
        access_mode="cycling",
        base_speed_kmh=15.0,
    ),
    "hiking": TraversalMode(
        key="hiking",
        label="Hike",
        tier=FIRST_CLASS,
        medium="land",
        # Traffic stress matters more on foot than on a bike and directness less:
        # a walker takes the path, not the shoulder.
        weights=WeightProfile(name="hiking", quiet=0.8, scenic=0.7, directness=0.3),
        network_type="walk",
        access_mode="hiking",
        # SPIKE-05: hiking's system default needs no personal data, unlike cycling's.
        base_speed_kmh=5.0,
    ),
    "paddling": TraversalMode(
        key="paddling",
        label="Paddle",
        tier=FIRST_CLASS,
        medium="water",
        weights=WeightProfile(name="paddling", quiet=1.0, scenic=0.8, directness=0.4),
        # Paddling's own router lands in Leg 3 (MVP §1.3); the mode is authorable
        # from day one, which is what B1's AC requires. `all` is the widest OSMnx
        # network — waterways come from the water layer, not this graph.
        network_type="all",
        access_mode="paddling",
        base_speed_kmh=4.0,
    ),
    "cross_country_skiing": TraversalMode(
        key="cross_country_skiing",
        label="Ski",
        tier=EXTENDED,
        medium="snow",
        # Groomed track and quiet ground, and climbing is work on skinny skis.
        weights=WeightProfile(
            name="cross_country_skiing", quiet=0.9, scenic=0.8, directness=0.3,
            peaks=-0.3,
        ),
        network_type="all",
        # Nordic tracks follow foot-legal ways; `piste:*` is a layer concern, not
        # an access one.
        access_mode="hiking",
        base_speed_kmh=8.0,
    ),
    "packrafting": TraversalMode(
        key="packrafting",
        label="Packraft",
        tier=EXTENDED,
        medium="water",
        weights=WeightProfile(name="packrafting", quiet=1.0, scenic=0.8, directness=0.3),
        network_type="all",
        access_mode="paddling",
        base_speed_kmh=4.5,
    ),
    "riverboarding": TraversalMode(
        key="riverboarding",
        label="Riverboard",
        tier=EXTENDED,
        medium="water",
        weights=WeightProfile(name="riverboarding", quiet=1.0, scenic=0.8, directness=0.3),
        network_type="all",
        access_mode="paddling",
        base_speed_kmh=4.0,
    ),
    "mountain_biking": TraversalMode(
        key="mountain_biking",
        label="MTB",
        tier=EXTENDED,
        medium="land",
        # FR4's bipolar surface dials are what make this a *configuration* of
        # cycling rather than a second cycling scorer: seek singletrack outright,
        # avoid pavement, and take the climbing.
        weights=WeightProfile(
            name="mountain_biking", quiet=0.9, scenic=0.7, directness=0.2,
            peaks=0.4, surface_singletrack=1.0, surface_gravel=0.5,
            surface_paved=-0.6,
        ),
        network_type="bike",
        access_mode="cycling",
        base_speed_kmh=12.0,
    ),
    "driving": TraversalMode(
        key="driving",
        label="Drive",
        tier=EXTENDED,
        medium="land",
        # FR29 [AMENDED v2.0]: a driving leg is a real route to the trailhead, and
        # the Author wants the direct one — this is the one mode where directness
        # dominates and traffic aversion is close to indifferent.
        weights=WeightProfile(
            name="driving", quiet=0.1, scenic=0.2, directness=0.95,
            surface_paved=0.4,
        ),
        network_type="drive",
        access_mode="driving",
        base_speed_kmh=60.0,
    ),
}


#: FR29's other half: legs that are *authored notes*, not routes — identifiers,
#: carrier, scheduled times, links. A payload mode value the solver never sees.
#: Kept out of `TRAVERSAL_MODES` so no caller can hand one to a router by
#: iterating "the modes".
TRANSPORT_NOTE_MODES: dict[str, str] = {"transit": "Transit"}


#: FR109 / O4 — activities performed *at* a place, with a duration. These are
#: station roles on an anchor, never traversal modes, and `_assert_disjoint`
#: below turns that sentence into an invariant this module cannot violate.
#: Punchlist §2.6's fail signal is exactly "climbing or canyoneering appears
#: anywhere in a travel mode list".
STATION_ACTIVITIES: frozenset[str] = frozenset({
    "climbing", "canyoneering", "jumaring", "sauna", "hot_spring", "swimming",
})


def _assert_disjoint() -> None:
    overlap = STATION_ACTIVITIES & (set(TRAVERSAL_MODES) | set(TRANSPORT_NOTE_MODES))
    if overlap:
        raise AssertionError(
            f"station activities are not travel modes (FR109/O4): {sorted(overlap)}"
        )


_assert_disjoint()


# ---------------------------------------------------------------------------
# Lookups. Each takes an optional `registry` for the same reason
# `curation.defaults.resolve_default_layers` takes an optional `config`: the
# extension path FR130 describes has to be exercisable without mutating a
# module global.
# ---------------------------------------------------------------------------


def _registry(registry: Mapping[str, TraversalMode] | None) -> Mapping[str, TraversalMode]:
    return TRAVERSAL_MODES if registry is None else registry


def traversal_mode(
    mode: str, registry: Mapping[str, TraversalMode] | None = None
) -> TraversalMode | None:
    """The registry row for `mode`, or `None` — an unknown mode is not an error
    here (FR144: an Author may create a passage in an undeclared mode, and a
    plugin may declare one this build has never heard of)."""
    return _registry(registry).get(mode)


def is_traversal_mode(mode: str, registry: Mapping[str, TraversalMode] | None = None) -> bool:
    return mode in _registry(registry)


def is_station_activity(activity: str) -> bool:
    """FR109 — true for something authored as a station (O4), which must never
    be offered as a traversal mode."""
    return activity in STATION_ACTIVITIES


def weights_for(
    mode: str, registry: Mapping[str, TraversalMode] | None = None
) -> WeightProfile:
    """The mode's default weight profile — FR130's "a new `WeightProfile` entry".

    Falls back to the scorer's own default profile for an unknown mode rather
    than raising: a mode with no tuned profile still routes, it just routes
    balanced.
    """
    found = traversal_mode(mode, registry)
    return found.weights if found else WeightProfile()


def access_mode_for(
    mode: str, registry: Mapping[str, TraversalMode] | None = None
) -> str | None:
    """Which `routing.access.MODE_CONSTRAINTS` row governs `mode`'s legality.

    Falls through to `mode` itself for a mode the registry doesn't carry, so
    `routing.access` behaves for unknown modes exactly as it did before this
    registry existed.
    """
    found = traversal_mode(mode, registry)
    if found is None:
        return mode
    return found.access_mode


def network_type_for(
    mode: str, registry: Mapping[str, TraversalMode] | None = None
) -> str:
    found = traversal_mode(mode, registry)
    return found.network_type if found else "bike"


def base_speed_kmh(
    mode: str, registry: Mapping[str, TraversalMode] | None = None
) -> float | None:
    """B7/FR16's seed value. `None` for a mode with no speed model — including
    every `TRANSPORT_NOTE_MODES` value, whose timing is an authored schedule."""
    found = traversal_mode(mode, registry)
    return found.base_speed_kmh if found else None


def first_class_modes(
    registry: Mapping[str, TraversalMode] | None = None
) -> list[str]:
    """MVP's measured set, in registry order."""
    return [k for k, m in _registry(registry).items() if m.is_first_class]


def extended_modes(registry: Mapping[str, TraversalMode] | None = None) -> list[str]:
    return [k for k, m in _registry(registry).items() if not m.is_first_class]


def all_mode_keys(registry: Mapping[str, TraversalMode] | None = None) -> list[str]:
    """Every value `$defs/travel_mode` accepts: traversal modes then note modes.

    `docs/schemas/trip_payload.schema.json`'s enum is asserted against this in
    `core/tests/test_modes.py`, so the schema and the registry cannot drift.
    """
    return [*_registry(registry), *TRANSPORT_NOTE_MODES]


def mode_label(mode: str, registry: Mapping[str, TraversalMode] | None = None) -> str:
    """A human label, falling through to the raw wire value for an unknown mode
    (the client's `travel_mode.dart` does the same, deliberately — an unlabelled
    mode should still be nameable in a list)."""
    found = traversal_mode(mode, registry)
    if found:
        return found.label
    return TRANSPORT_NOTE_MODES.get(mode, mode)
