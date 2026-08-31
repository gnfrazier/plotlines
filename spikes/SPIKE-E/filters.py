"""The four graph variants, and why they are applied offline rather than fetched.

`multimodal/modes.py` ships `network_type="drive"` for the driving mode, which is an
OSMnx *download filter*: a string of Overpass clauses that decides which ways ever
reach the graph. The routing half of this spike is largely a question about that
string, so it is reproduced here rather than paraphrased — the literals below are
`osmnx._overpass._get_network_filter("drive")` and `("drive_service")` verbatim from
osmnx 2.1.1, and `tests/test_filters.py` asserts they still match the installed
osmnx, so an upgrade that changes the semantics fails a test instead of quietly
changing a published number.

**One pull, four variants.** Fetching four filters would be four Overpass queries per
region against an endpoint SPIKE-D measured at ×21 run-to-run variance and then
exhausted for a session. It would also make the comparison unreadable: two pulls an
hour apart are two different maps. So the probe fetches once with the widest
car-usable filter and every variant is a *predicate over the same edges*, which is
the same same-place-control discipline SPIKE-C used to make a zero readable.
`tests/test_filters.py` validates the reconstruction against a real
`network_type="drive"` pull committed alongside it (`raw/boulder-drive-control`).

The variants, narrowest first:

  ``drive``         what `modes.py` ships today
  ``drive_service`` osmnx's service-road-inclusive variant
  ``drive_track``   + `highway=track`: forest roads and two-tracks
  ``drive_track_private``  + ways tagged `access=private`, which on a National
                    Forest road often means "gated in winter" rather than "not
                    yours to drive" — kept as a separate variant precisely so
                    that judgement is visible instead of assumed
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# osmnx 2.1.1's own strings, verbatim.
# ---------------------------------------------------------------------------

OSMNX_DRIVE = (
    '["highway"]["area"!~"yes"]["access"!~"private"]'
    '["highway"!~"abandoned|bridleway|bus_guideway|construction|corridor|cycleway|'
    'elevator|escalator|footway|no|path|pedestrian|planned|platform|proposed|raceway|'
    'razed|rest_area|service|services|steps|track"]'
    '["motor_vehicle"!~"no"]["motorcar"!~"no"]'
    '["service"!~"alley|driveway|emergency_access|parking|parking_aisle|private"]'
)

OSMNX_DRIVE_SERVICE = (
    '["highway"]["area"!~"yes"]["access"!~"private"]'
    '["highway"!~"abandoned|bridleway|bus_guideway|construction|corridor|cycleway|'
    'elevator|escalator|footway|no|path|pedestrian|planned|platform|proposed|raceway|'
    'razed|rest_area|services|steps|track"]'
    '["motor_vehicle"!~"no"]["motorcar"!~"no"]'
    '["service"!~"emergency_access|parking|parking_aisle|private"]'
)

#: What the probe actually downloads: `drive_service` with `track` allowed back in and
#: the `access` clause dropped, so both are measurable offline rather than invisible.
FETCH_FILTER = (
    '["highway"]["area"!~"yes"]'
    '["highway"!~"abandoned|bridleway|bus_guideway|construction|corridor|cycleway|'
    'elevator|escalator|footway|no|path|pedestrian|planned|platform|proposed|raceway|'
    'razed|rest_area|services|steps"]'
    '["motor_vehicle"!~"no"]["motorcar"!~"no"]'
    '["service"!~"emergency_access|parking|parking_aisle|private"]'
)

DRIVE_TRACK = (
    '["highway"]["area"!~"yes"]["access"!~"private"]'
    '["highway"!~"abandoned|bridleway|bus_guideway|construction|corridor|cycleway|'
    'elevator|escalator|footway|no|path|pedestrian|planned|platform|proposed|raceway|'
    'razed|rest_area|services|steps"]'
    '["motor_vehicle"!~"no"]["motorcar"!~"no"]'
    '["service"!~"emergency_access|parking|parking_aisle|private"]'
)

DRIVE_TRACK_PRIVATE = FETCH_FILTER

#: Narrowest → widest. Order matters: every table in `analyze.py` is printed in it,
#: so a reader watches what each concession buys.
VARIANTS: dict[str, str] = {
    "drive": OSMNX_DRIVE,
    "drive_service": OSMNX_DRIVE_SERVICE,
    "drive_track": DRIVE_TRACK,
    "drive_track_private": DRIVE_TRACK_PRIVATE,
}

#: The variant the product ships today.
SHIPPED = "drive"


# ---------------------------------------------------------------------------
# Clause parsing. Overpass `!~` is an unanchored regex over the tag value, not an
# equality test — `["motor_vehicle"!~"no"]` drops `motor_vehicle=nope` too. The
# parser keeps that behaviour rather than "fixing" it, because the question is what
# the shipped filter does, not what it meant to do.
# ---------------------------------------------------------------------------

_CLAUSE = re.compile(r'\["([^"]+)"(?:(!~|~)"([^"]*)")?\]')


@dataclass(frozen=True)
class Clause:
    key: str
    op: str | None   # None = "tag must be present", "!~" = must not match, "~" = must
    pattern: re.Pattern | None


def parse(filter_string: str) -> list[Clause]:
    clauses: list[Clause] = []
    for key, op, pattern in _CLAUSE.findall(filter_string):
        clauses.append(Clause(
            key=key,
            op=op or None,
            pattern=re.compile(pattern) if op else None,
        ))
    return clauses


def _values(tags: dict, key: str) -> list[str]:
    """Every value under `key`. After way merging an osmnx edge can carry a list of
    values that disagreed across the merged ways — `routing/access.py` learned the
    same lesson (`_values` there); a filter that reads only the first element
    admits an edge that is half `motor_vehicle=no`."""
    raw = tags.get(key)
    if raw is None:
        return []
    if isinstance(raw, (list, tuple, set)):
        return [str(v) for v in raw]
    return [str(raw)]


def passes(tags: dict, clauses: list[Clause]) -> bool:
    """Whether one way's tags survive a download filter."""
    for clause in clauses:
        values = _values(tags, clause.key)
        if clause.op is None:
            if not values:
                return False
            continue
        matched = any(clause.pattern.search(v) for v in values)
        if clause.op == "!~" and matched:
            return False
        if clause.op == "~" and not matched:
            return False
    return True


def variant_predicate(variant: str):
    clauses = parse(VARIANTS[variant])
    return lambda tags: passes(tags, clauses)
