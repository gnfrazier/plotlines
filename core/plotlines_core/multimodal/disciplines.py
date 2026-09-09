"""The discipline registry — issue #315, the second axis under a traversal mode.

Issue #315 settled a model question that had been decided once the other way:
**a discipline is a variant *under* a mode, not a mode of its own** (Model B).
`cycling` stays one `travel_mode`; road / gravel / mountain is a second axis
that selects a `WeightProfile`. Nothing in the payload's `travel_mode`
vocabulary changes — that enum is now the set of *categories* (`modes.py`), and
this module is the set of *disciplines* that refine one.

The shape deliberately mirrors `modes.py`: a frozen dataclass, one
module-level dict, lookups that take an optional `registry=` so the extension
path is exercisable without mutating a global (FR130), and an import-time
invariant. A discipline is configuration — it names a `WeightProfile` and a
category, and it never becomes a branch of the scorer.

`mountain_biking`, `packrafting` and `riverboarding` used to be their own
`travel_mode` values; they are now the `mountain`, `packraft` and `riverboard`
disciplines and **reuse the exact weight profiles they carried as modes**, so
there is one source of tuning, not two. `multimodal.legacy` maps the old
spelling forward.

`grades_difficulty` is a capability flag for future work (B9 / FR14b): the
owner's #315 note marks difficulty grading in scope for the land disciplines
(Cycle, Foot) and out for Paddle / Ski (the data would come from a plugin).
**Nothing reads this flag yet** — SPIKE-C found OSM land grading too thin to
aggregate, and no grading surface exists. It is recorded here so the future
B9 work has the fact and the trip-creation control does not over-promise.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

from plotlines_core.multimodal.modes import (
    EXTENDED,
    FIRST_CLASS,
    STATION_ACTIVITIES,
    TRANSPORT_NOTE_MODES,
    TRAVERSAL_MODES,
)
from plotlines_core.scoring.profile import THEMES, WeightProfile


@dataclass(frozen=True)
class Discipline:
    """One discipline, entirely as data (FR130 applied to the second axis).

    `weights` is what the shared scorer consumes once a solve resolves
    `(mode, discipline)` to a profile; `category` is the `TRAVERSAL_MODES` key
    this refines and is what governs the routing graph and legality — a
    discipline never changes either.
    """

    key: str
    label: str
    #: a `TRAVERSAL_MODES` key.
    category: str
    #: `first_class` where the profile is one that shipped and was measured
    #: (a category base, a SPIKE-tuned theme, or a reused ex-mode profile);
    #: `extended` where the dials are a conservative first guess. The
    #: trip-creation control communicates tuned-vs-generic from this, not from
    #: which row a discipline sits in.
    tier: str
    weights: WeightProfile
    #: Future B9 / FR14b capability flag. Nothing consumes it yet.
    grades_difficulty: bool

    @property
    def is_first_class(self) -> bool:
        return self.tier == FIRST_CLASS


def _base(category: str) -> WeightProfile:
    """The category's own default profile — the honest starting point for a
    discipline that has no measured dials of its own."""
    return TRAVERSAL_MODES[category].weights


#: The MVP set, in category order (owner's #315 comment). `riverboard` is
#: carried for wire validity and legacy migration (`packrafting`'s sibling was
#: `riverboarding`) but is not offered in the MVP control.
DISCIPLINES: dict[str, Discipline] = {
    # ---- Cycle -----------------------------------------------------------
    "road": Discipline(
        key="road", label="Road", category="cycling", tier=FIRST_CLASS,
        weights=_base("cycling").replace(name="road"),
        grades_difficulty=True,
    ),
    "gravel": Discipline(
        key="gravel", label="Gravel", category="cycling", tier=FIRST_CLASS,
        # SPIKE-03's tuned gravel theme, verbatim — the one dial set that was
        # measured for "seek gravel outright".
        weights=THEMES["gravel"].replace(name="gravel"),
        grades_difficulty=True,
    ),
    "mountain": Discipline(
        key="mountain", label="Mountain", category="cycling", tier=FIRST_CLASS,
        # The profile `mountain_biking` carried as a mode — bipolar surface
        # dials that seek singletrack and avoid pavement (FR4).
        weights=WeightProfile(
            name="mountain", quiet=0.9, scenic=0.7, directness=0.2, peaks=0.4,
            surface_singletrack=1.0, surface_gravel=0.5, surface_paved=-0.6,
        ),
        grades_difficulty=True,
    ),
    # ---- Foot ----------------------------------------------------------
    "hike": Discipline(
        key="hike", label="Hike", category="hiking", tier=FIRST_CLASS,
        weights=_base("hiking").replace(name="hike"),
        grades_difficulty=True,
    ),
    "run": Discipline(
        key="run", label="Run", category="hiking", tier=EXTENDED,
        # A runner takes a slightly more direct line than a hiker; otherwise
        # the foot profile. Not measured — extended.
        weights=_base("hiking").replace(name="run", directness=0.4),
        grades_difficulty=True,
    ),
    "trail_run": Discipline(
        key="trail_run", label="Trail run", category="hiking", tier=EXTENDED,
        weights=_base("hiking").replace(
            name="trail_run", directness=0.35,
            surface_singletrack=0.5, surface_paved=-0.3,
        ),
        grades_difficulty=True,
    ),
    # ---- Paddle --------------------------------------------------------
    "canoe": Discipline(
        key="canoe", label="Canoe", category="paddling", tier=FIRST_CLASS,
        weights=_base("paddling").replace(name="canoe"),
        grades_difficulty=False,
    ),
    "kayak": Discipline(
        key="kayak", label="Kayak", category="paddling", tier=FIRST_CLASS,
        # OSM carries no signal that separates a kayak line from a canoe line;
        # the label drives plugin data and cue vocabulary, not the weights.
        weights=_base("paddling").replace(name="kayak"),
        grades_difficulty=False,
    ),
    "packraft": Discipline(
        key="packraft", label="Packraft", category="paddling", tier=FIRST_CLASS,
        # The profile `packrafting` carried as a mode.
        weights=WeightProfile(
            name="packraft", quiet=1.0, scenic=0.8, directness=0.3,
        ),
        grades_difficulty=False,
    ),
    "riverboard": Discipline(
        key="riverboard", label="Riverboard", category="paddling", tier=EXTENDED,
        # `riverboarding`'s ex-mode profile. Not surfaced at MVP; here for
        # wire validity and the legacy migration.
        weights=WeightProfile(
            name="riverboard", quiet=1.0, scenic=0.8, directness=0.3,
        ),
        grades_difficulty=False,
    ),
    # ---- Ski ----------------------------------------------------------
    "nordic": Discipline(
        key="nordic", label="Nordic", category="cross_country_skiing", tier=EXTENDED,
        weights=_base("cross_country_skiing").replace(name="nordic"),
        grades_difficulty=False,
    ),
    "skimo": Discipline(
        key="skimo", label="Skimo", category="cross_country_skiing", tier=EXTENDED,
        # Ski mountaineering climbs on purpose — flip the base profile's climb
        # aversion.
        weights=_base("cross_country_skiing").replace(name="skimo", peaks=0.3),
        grades_difficulty=False,
    ),
    "backcountry": Discipline(
        key="backcountry", label="Backcountry", category="cross_country_skiing",
        tier=EXTENDED,
        weights=_base("cross_country_skiing").replace(
            name="backcountry", peaks=0.1, scenic=0.9,
        ),
        grades_difficulty=False,
    ),
    "resort": Discipline(
        key="resort", label="Resort", category="cross_country_skiing", tier=EXTENDED,
        # Lift-served: the engine is barely routing here — take the direct line.
        weights=_base("cross_country_skiing").replace(
            name="resort", directness=0.8, peaks=0.0,
        ),
        grades_difficulty=False,
    ),
    # ---- Drive -------------------------------------------------------
    "street": Discipline(
        key="street", label="Street", category="driving", tier=EXTENDED,
        weights=_base("driving").replace(name="street"),
        grades_difficulty=False,
    ),
    "high_clearance": Discipline(
        key="high_clearance", label="High clearance", category="driving",
        tier=EXTENDED,
        # A high-clearance vehicle is not looking for pavement and will take a
        # rougher, less direct forest road to the trailhead. FR29a's
        # vehicle-access advisory (issue #206) is the real consumer; these
        # dials are a placeholder until it lands.
        weights=_base("driving").replace(
            name="high_clearance", surface_paved=0.0, directness=0.9,
        ),
        grades_difficulty=False,
    ),
}


def _assert_disjoint() -> None:
    keys = set(DISCIPLINES)
    overlap = keys & (
        set(TRAVERSAL_MODES) | set(TRANSPORT_NOTE_MODES) | set(STATION_ACTIVITIES)
    )
    if overlap:
        raise AssertionError(
            f"a discipline key must not also be a mode or station activity "
            f"(#315): {sorted(overlap)}"
        )
    stray = {d.category for d in DISCIPLINES.values()} - set(TRAVERSAL_MODES)
    if stray:
        raise AssertionError(
            f"discipline categories must be real traversal modes (#315): "
            f"{sorted(stray)}"
        )
    for key, d in DISCIPLINES.items():
        if d.key != key:
            raise AssertionError(f"discipline key mismatch: {key!r} vs {d.key!r}")


_assert_disjoint()


# ---------------------------------------------------------------------------
# Lookups. Each takes an optional `registry` for the reason `modes.py`'s do:
# FR130's extension path has to be exercisable without mutating a module
# global, and an unknown key is not an error (an Author or plugin may name a
# discipline this build has never heard of — FR144's posture, applied here).
# ---------------------------------------------------------------------------


def _registry(
    registry: Mapping[str, Discipline] | None,
) -> Mapping[str, Discipline]:
    return DISCIPLINES if registry is None else registry


def discipline(
    key: str, registry: Mapping[str, Discipline] | None = None
) -> Discipline | None:
    return _registry(registry).get(key)


def is_discipline(
    key: str, registry: Mapping[str, Discipline] | None = None
) -> bool:
    return key in _registry(registry)


def disciplines_for(
    category: str, registry: Mapping[str, Discipline] | None = None
) -> list[str]:
    """The discipline keys that refine `category`, in registry order."""
    return [k for k, d in _registry(registry).items() if d.category == category]


def category_of(
    key: str, registry: Mapping[str, Discipline] | None = None
) -> str | None:
    found = discipline(key, registry)
    return found.category if found else None


def weights_for_discipline(
    key: str, registry: Mapping[str, Discipline] | None = None
) -> WeightProfile:
    """The discipline's weight profile, or the scorer's own default for an
    unknown key — a passage with a discipline this build does not know still
    routes, it just routes balanced (mirrors `modes.weights_for`)."""
    found = discipline(key, registry)
    return found.weights if found else WeightProfile()


def discipline_label(
    key: str, registry: Mapping[str, Discipline] | None = None
) -> str:
    found = discipline(key, registry)
    return found.label if found else key


def all_discipline_keys(
    registry: Mapping[str, Discipline] | None = None
) -> list[str]:
    """Every value `$defs/discipline` accepts, in registry order.

    `docs/schemas/trip_payload.schema.json`'s `$defs/discipline` enum is
    asserted against this in `core/tests/test_disciplines.py`, so the schema
    and the registry cannot drift.
    """
    return list(_registry(registry))
