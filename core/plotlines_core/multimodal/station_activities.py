"""The station-activity registry — FR109 / O4, the third extension path.

ARCH §7.3 names three ways the traversal model extends, and they are not alike.
A **traversal category** (`modes.py`) is a `WeightProfile` plus domain
parameters. A **discipline** under a category (`disciplines.py`, issue #315) is
a `WeightProfile` one axis down. A **station activity** — climbing,
canyoneering, jumaring, a sauna, a hot spring, a swimming hole, a summit
scramble, a canyon descent — needs **no routing change at all**: it is
performed *at* a place, not *between* two, so it never reaches the scorer, the
graph, or legality. It is an activity-type config entry consumed by `content/`
(the station role on an anchor) and by day timing (`trips.dashboard`).

**The rule behind the list** (§0's seed-set test, `plotlines-constraints`):
an activity belongs here when a Character **reaches it by some traversal mode
and then does it, for a while, without going anywhere** — it has an expected
duration and no origin/destination pair. If naming a thing as a station
activity would let an Author draw a passage *in* it, it is a traversal mode or
a discipline, not this. `_assert_disjoint` turns the "never a travel mode"
half of that into an import-time invariant; punch-list §2.6's fail signal is
exactly "climbing or canyoneering appears anywhere in a travel mode list".

**Adding an activity type is a config entry, not code** (O4's AC): a new row
in `ACTIVITY_TYPES` below, nothing else — no scorer branch, no new class, no
schema enum to widen. `$defs/station_activity.activity_type` is a plain
string, not an enum, on purpose: the payload has to accept an activity a
plugin declares that this build has never heard of (FR144's posture, the same
one `modes.traversal_mode` takes for an unknown mode). This registry supplies
the label and the default duration for the set the app ships knowing about;
an unknown key still round-trips, it just carries no label of its own. This is
the one place this module diverges from `disciplines.py` (whose keys *are* a
schema enum) — see `core/tests/test_station_activities.py`.

The shape otherwise mirrors `disciplines.py`: a frozen dataclass, one
module-level dict, lookups that take an optional `registry=` so the extension
path is exercisable without mutating a global (FR130), and an import-time
invariant.
"""

from __future__ import annotations

import math
from collections.abc import Mapping
from dataclasses import dataclass

#: `medium` values, mirroring `modes.TraversalMode.medium`: what the activity
#: happens on/in. Drives nothing in core today — it is here so a future icon
#: or filter has the fact without re-deriving it from the key.
MEDIA = ("land", "water", "snow")


@dataclass(frozen=True)
class ActivityType:
    """One station-activity type, entirely as data (O4: "a config entry, not
    code"). Nothing here is a code path — no field is read by the scorer, the
    graph builder, or legality."""

    key: str
    label: str
    #: `land` | `water` | `snow`.
    medium: str
    #: A sensible starting duration in seconds for this kind of stop, or
    #: `None` where there is no meaningful default (the Author always sets
    #: it). A seed for the authoring control, never imposed — the value that
    #: feeds day timing is the one on the role's `StationActivity`, which the
    #: Author can always override.
    default_duration_s: float | None

    def __post_init__(self) -> None:
        if self.medium not in MEDIA:
            raise ValueError(f"activity medium {self.medium!r} not in {MEDIA}")
        if self.default_duration_s is not None:
            d = float(self.default_duration_s)
            if not math.isfinite(d) or d < 0:
                raise ValueError(
                    f"activity {self.key!r}: default_duration_s must be a finite "
                    f"non-negative number, got {self.default_duration_s!r}"
                )


_H = 3600.0

#: The set the app ships knowing about. The first three are FR109's named
#: examples ("climbing, canyoneering, and jumaring are stations, not travel
#: modes"); the rest are the other station cases the PRD reaches for (crag,
#: hot spring, sauna, swimming hole, summit scramble, canyon descent).
ACTIVITY_TYPES: dict[str, ActivityType] = {
    "climbing": ActivityType(
        key="climbing", label="Climbing", medium="land", default_duration_s=3 * _H,
    ),
    "canyoneering": ActivityType(
        key="canyoneering", label="Canyoneering", medium="water",
        default_duration_s=4 * _H,
    ),
    "jumaring": ActivityType(
        key="jumaring", label="Jumaring", medium="land", default_duration_s=2 * _H,
    ),
    "summit_scramble": ActivityType(
        key="summit_scramble", label="Summit scramble", medium="land",
        default_duration_s=int(1.5 * _H),
    ),
    "hot_spring": ActivityType(
        key="hot_spring", label="Hot spring", medium="water", default_duration_s=_H,
    ),
    "sauna": ActivityType(
        key="sauna", label="Sauna", medium="land", default_duration_s=_H,
    ),
    "swimming": ActivityType(
        key="swimming", label="Swimming hole", medium="water",
        default_duration_s=_H,
    ),
}


def _assert_registry() -> None:
    for key, activity in ACTIVITY_TYPES.items():
        if activity.key != key:
            raise AssertionError(f"activity key mismatch: {key!r} vs {activity.key!r}")


_assert_registry()


#: The keys the app ships knowing about, as a frozenset — what `modes.py`
#: re-exports as `STATION_ACTIVITIES` for its own disjointness invariant and
#: for `is_station_activity`. A working set, not a closed enum (see the module
#: docstring): the payload accepts an activity key not in here.
STATION_ACTIVITY_KEYS: frozenset[str] = frozenset(ACTIVITY_TYPES)


# ---------------------------------------------------------------------------
# Lookups. Each takes an optional `registry` for the same reason
# `disciplines.py`'s do: FR130's extension path has to be exercisable without
# mutating a module global, and an unknown key is never an error here.
# ---------------------------------------------------------------------------


def _registry(
    registry: Mapping[str, ActivityType] | None,
) -> Mapping[str, ActivityType]:
    return ACTIVITY_TYPES if registry is None else registry


def activity_type(
    key: str, registry: Mapping[str, ActivityType] | None = None
) -> ActivityType | None:
    return _registry(registry).get(key)


def is_activity_type(
    key: str, registry: Mapping[str, ActivityType] | None = None
) -> bool:
    return key in _registry(registry)


def activity_label(
    key: str, registry: Mapping[str, ActivityType] | None = None
) -> str:
    """The activity's label, falling through to the raw key for one this build
    does not know (a plugin-declared activity) — mirrors `modes.mode_label`."""
    found = activity_type(key, registry)
    return found.label if found else key


def default_duration_s_for(
    key: str, registry: Mapping[str, ActivityType] | None = None
) -> float | None:
    found = activity_type(key, registry)
    return found.default_duration_s if found else None


def all_activity_type_keys(
    registry: Mapping[str, ActivityType] | None = None
) -> list[str]:
    """Every activity type the app ships knowing about, in registry order.

    NOT asserted against a schema enum (unlike `all_mode_keys` /
    `all_discipline_keys`): `$defs/station_activity.activity_type` is a plain
    string. `core/tests/test_station_activities.py` instead asserts every key
    here produces a payload that validates.
    """
    return list(_registry(registry))
