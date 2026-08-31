"""FR29a's vehicle-access advisory, as a spike-local prototype (no product change).

The requirement: the Author declares an expected vehicle capability, Plotlines reads
the road's own signals and **flags where the route exceeds it**, in the leg summary and
on the cue sheet, naming the signal that triggered the flag — **advisory, never a
constraint**, on the same footing as FR14's gauge band.

Three design decisions, each of which is where this could go quietly wrong:

**1. There is no `passable` field, and no state that renders as "confirmed fine".**
SPIKE-C's `CoverageNote` shipped its honesty clause as a *type* rather than a comment —
in the sparse state there is no value to print even by accident — and the same trick
applies here with more force, because the failure mode is worse. A difficulty grade
that fails low disappoints a hiker; an access advisory that fails silent puts a loaded
sedan on a shelf road at dusk. `Advisory.state` has three values and the summary text
for each is generated from the coverage that state was computed from, so
`insufficient_signal` cannot be phrased as `no_contrary_signal`.

**2. The ladder tops out above what the Author can declare.** FR29a's declaration is
2WD / AWD / high-clearance / 4WD. OSM's `smoothness` goes two rungs further
(`very_horrible`, `impassable`), so `Capability.BEYOND_4WD` exists inside the model
and is never offered as a declaration — a road that no vehicle on the ladder can use
must be able to exceed the top of the ladder, or the worst road in the set comes back
"within your declared capability".

**3. `motor_vehicle` is on FR29a's signal list but is not a capability signal.**
`motor_vehicle=private|no|destination` says who may drive, not what they need to drive
in. It is reported as a separate `access_notes` list rather than folded into the
capability ladder — conflating "you cannot legally drive here" with "you need a truck"
would produce a flag an Author cannot act on by borrowing a better vehicle.

Value → capability mappings come from the OSM wiki's own vehicle descriptions for each
key (`Key:smoothness`'s vehicle classes, `Key:tracktype`'s grades, `Key:4wd_only`), not
from taste. Where the wiki describes a class rather than a drivetrain the mapping is
stated in the table below and is the obvious place to argue with this prototype.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import IntEnum

from regions import BANDS


class Capability(IntEnum):
    """The Author-declared ladder (FR29a), plus one rung above it — see the module
    docstring. Ordered, so "exceeds" is `required > declared` and nothing else."""

    TWO_WD = 0
    AWD = 1
    HIGH_CLEARANCE = 2
    FOUR_WD = 3
    BEYOND_4WD = 4


#: What an Author may declare. `BEYOND_4WD` is deliberately absent.
DECLARABLE: tuple[Capability, ...] = (
    Capability.TWO_WD, Capability.AWD, Capability.HIGH_CLEARANCE, Capability.FOUR_WD,
)

LABEL = {
    Capability.TWO_WD: "2WD",
    Capability.AWD: "AWD",
    Capability.HIGH_CLEARANCE: "high-clearance",
    Capability.FOUR_WD: "4WD",
    Capability.BEYOND_4WD: "beyond 4WD",
}


@dataclass(frozen=True)
class Rule:
    key: str
    value: str
    requires: Capability
    #: Why, in the words a leg summary can print.
    note: str


#: Ordered by key then severity. Every row's `note` is the phrase that reaches the
#: Author, because "the specific signal that triggered the flag" (C13a's AC) is the
#: whole value of the feature — "rough road ahead" is not actionable, "smoothness=very_bad
#: for 4.1 km" is.
RULES: tuple[Rule, ...] = (
    # `Key:4wd_only` — "the way is passable only with a four wheel drive vehicle".
    Rule("4wd_only", "yes", Capability.FOUR_WD, "tagged 4wd_only"),
    # `Key:smoothness` — the wiki's own vehicle classes, rung for rung.
    Rule("smoothness", "bad", Capability.AWD, "smoothness=bad (robust wheels)"),
    Rule("smoothness", "very_bad", Capability.HIGH_CLEARANCE,
         "smoothness=very_bad (high clearance)"),
    Rule("smoothness", "horrible", Capability.FOUR_WD,
         "smoothness=horrible (heavy-duty off-road)"),
    Rule("smoothness", "very_horrible", Capability.BEYOND_4WD,
         "smoothness=very_horrible (specialised off-road)"),
    Rule("smoothness", "impassable", Capability.BEYOND_4WD,
         "smoothness=impassable (no wheeled vehicle)"),
    # `Key:tracktype` — grade1 solid .. grade5 soft.
    Rule("tracktype", "grade3", Capability.AWD, "tracktype=grade3 (even mix, soft)"),
    Rule("tracktype", "grade4", Capability.HIGH_CLEARANCE,
         "tracktype=grade4 (mostly soft)"),
    Rule("tracktype", "grade5", Capability.FOUR_WD, "tracktype=grade5 (soft, no hard core)"),
    # `Key:surface` — graded gravel is a 2WD road and is not flagged; the rungs start
    # where the tread stops being maintained.
    Rule("surface", "unpaved", Capability.AWD, "surface=unpaved"),
    Rule("surface", "dirt", Capability.AWD, "surface=dirt"),
    Rule("surface", "earth", Capability.AWD, "surface=earth"),
    Rule("surface", "ground", Capability.AWD, "surface=ground"),
    Rule("surface", "grass", Capability.HIGH_CLEARANCE, "surface=grass"),
    Rule("surface", "sand", Capability.HIGH_CLEARANCE, "surface=sand"),
    Rule("surface", "mud", Capability.FOUR_WD, "surface=mud"),
    Rule("surface", "rock", Capability.FOUR_WD, "surface=rock"),
    # A ford is not a drivetrain question, but it is the one physical obstacle on an
    # approach that a passenger car cannot simply take slowly.
    Rule("ford", "yes", Capability.HIGH_CLEARANCE, "unbridged ford"),
    Rule("ford", "stepping_stones", Capability.HIGH_CLEARANCE, "unbridged ford"),
)

#: `highway=track` with no other signal. The class itself is FR29a's weakest listed
#: signal and it is used only as a fallback — a track that carries `tracktype` or
#: `smoothness` is judged on those.
TRACK_FALLBACK = Rule("highway", "track", Capability.AWD,
                      "highway=track, no surface or grade tagged")

#: Access values worth surfacing beside the advisory without being capability flags.
ACCESS_NOTES = {
    "no": "motor vehicles prohibited",
    "private": "private road",
    "permit": "permit required",
    "destination": "local/destination traffic only",
    "customers": "customers only",
    "agricultural": "agricultural traffic only",
    "forestry": "forestry traffic only",
}

_RULE_INDEX: dict[tuple[str, str], Rule] = {(r.key, r.value): r for r in RULES}

#: The keys whose *presence* means this stretch of road has been surveyed for
#: condition at all. Presence, not value: `surface=asphalt` is a read that says 2WD,
#: and counting only the values that trigger a flag would make a well-surveyed paved
#: approach look unsurveyed — the exact inversion the honesty clause exists to stop.
SURVEY_KEYS: tuple[str, ...] = ("surface", "smoothness", "tracktype", "4wd_only", "ford")

#: How long an **unsurveyed** gap two flagged runs may span and still be reported as
#: one section. Pre-registered at 500 m, from the shape of the data rather than taste:
#: OSM condition tagging is fragmented along a single named road (a mapper tags the
#: stretch they drove), and a per-edge flag on Big Sandy Opening Road emits dozens of
#: sections describing one continuous dirt road. Merging is only ever across ways with
#: **no contrary signal of their own** — a run is never merged across a stretch tagged
#: clear, because that would report a rough section where the map says there is road.
GAP_TOLERANCE_M = 500.0

#: The coverage floor below which an unflagged leg says nothing at all. Taken from the
#: pre-registered bands rather than chosen here, so the advisory's honesty threshold
#: and the coverage table's cannot drift apart.
OPPORTUNISTIC_FLOOR = dict(BANDS)["opportunistic"]
READ_FLOOR = dict(BANDS)["read"]


def _first(value):
    return value[0] if isinstance(value, list) and value else value


def _tag(data: dict, key: str) -> str | None:
    value = _first(data.get(key))
    return str(value).lower() if value is not None else None


def requirement_for(data: dict) -> tuple[Capability, list[Rule]]:
    """What this edge demands of a vehicle, and every rule that said so.

    Worst-of across signals, which is the only defensible direction: a road tagged
    `surface=dirt` *and* `smoothness=very_bad` is a high-clearance road, not an
    average of the two.
    """
    hits = [
        rule for key in ("4wd_only", "smoothness", "tracktype", "surface", "ford")
        if (rule := _RULE_INDEX.get((key, _tag(data, key) or "\0"))) is not None
    ]
    if not hits and _tag(data, "highway") == "track":
        hits = [TRACK_FALLBACK]
    if not hits:
        return Capability.TWO_WD, []
    worst = max(rule.requires for rule in hits)
    return worst, [rule for rule in hits if rule.requires == worst]


@dataclass(frozen=True)
class Flag:
    """One contiguous run of route that exceeds the declared capability."""

    start_m: float
    end_m: float
    requires: Capability
    signal: str
    note: str
    way: str

    @property
    def length_m(self) -> float:
        return self.end_m - self.start_m


@dataclass(frozen=True)
class AccessNote:
    start_m: float
    end_m: float
    value: str
    note: str
    way: str


@dataclass
class Advisory:
    """The result. Note what is *not* here: no `passable`, no `ok`, no boolean of any
    kind that a template could render as a clean bill of health."""

    declared: Capability
    #: "flagged" | "no_contrary_signal" | "insufficient_signal"
    state: str
    flags: list[Flag] = field(default_factory=list)
    access_notes: list[AccessNote] = field(default_factory=list)
    route_km: float = 0.0
    signal_km: float = 0.0
    signal_pct: float = 0.0
    flagged_km: float = 0.0
    #: Flagged runs before gap merging — the number a per-edge implementation would
    #: print. Kept because the ratio between the two is a finding, not a detail.
    raw_sections: int = 0

    @property
    def summary(self) -> str:
        """The leg-summary line (C13a: "in the leg summary and on the cue sheet").

        Generated per state from the coverage that state was computed from — the
        sparse case has no phrasing in common with the clear one, by construction.
        """
        declared = LABEL[self.declared]
        if self.state == "flagged":
            worst = max(flag.requires for flag in self.flags)
            return (
                f"{len(self.flags)} section(s), {self.flagged_km:.1f} of "
                f"{self.route_km:.1f} km, exceed the declared {declared} — up to "
                f"{LABEL[worst]}. Read on {self.signal_pct:.0f}% of this leg's "
                f"kilometres; the rest is unsurveyed."
            )
        if self.state == "no_contrary_signal":
            return (
                f"No signal on this route exceeds {declared}, read on "
                f"{self.signal_pct:.0f}% of its {self.route_km:.1f} km. "
                f"That is no contrary signal found, not a road confirmed passable."
            )
        return (
            f"Not enough of this route is surveyed to advise on {declared}: "
            f"{self.signal_pct:.0f}% of {self.route_km:.1f} km carries any surface, "
            f"grade or smoothness tag. The road's condition is the Author's to "
            f"declare, not the map's to supply."
        )


def surveyed(data: dict) -> bool:
    """Whether this edge has been surveyed for condition at all — see `SURVEY_KEYS`.
    `highway=track` counts, since the class is itself one of FR29a's signals."""
    return (any(_tag(data, key) is not None for key in SURVEY_KEYS)
            or _tag(data, "highway") == "track")


def _merge(raw: list[Flag], gaps: list[tuple[float, float, bool]]) -> list[Flag]:
    """Runs at the same requirement are one section, across unsurveyed gaps only.

    `gaps` is every unflagged stretch of the route with a flag saying whether it
    carried a signal of its own. A run may swallow an unsurveyed gap up to
    `GAP_TOLERANCE_M`; it may never swallow a surveyed one, however short — merging
    across a stretch the map says is good road would report rough ground where the
    map has evidence there is none.
    """
    def unsurveyed_between(a: float, b: float) -> bool:
        if b - a <= 0.0:
            return True
        if b - a > GAP_TOLERANCE_M:
            return False
        return not any(
            has_signal
            for start, end, has_signal in gaps
            if start >= a - 1e-6 and end <= b + 1e-6
        )

    merged: list[Flag] = []
    for flag in sorted(raw, key=lambda f: f.start_m):
        if merged:
            last = merged[-1]
            if last.requires == flag.requires and unsurveyed_between(last.end_m, flag.start_m):
                merged[-1] = Flag(
                    start_m=last.start_m, end_m=flag.end_m, requires=last.requires,
                    signal=_join(last.signal, flag.signal, ", "),
                    note=_join(last.note, flag.note, "; "),
                    way=_join(last.way, flag.way, " / "),
                )
                continue
        merged.append(flag)
    return merged


#: How many distinct signals or road names a merged section names before it stops
#: listing them. A 27 km section of one dirt road is one fact; the same section
#: rendered as its forty constituent OSM ways is a wall of text nobody reads, and an
#: advisory nobody reads is an advisory that does not warn.
NAME_CAP = 3


def _join(existing: str, addition: str, sep: str) -> str:
    """Merge two descriptions, de-duplicated, order-preserving, capped."""
    parts: list[str] = []
    for chunk in (*existing.split(sep), *addition.split(sep)):
        chunk = chunk.strip()
        if chunk and chunk not in parts and not chunk.startswith("+"):
            parts.append(chunk)
    if len(parts) <= NAME_CAP:
        return sep.join(parts)
    return sep.join(parts[:NAME_CAP]) + f"{sep}+{len(parts) - NAME_CAP} more"


def assess(route_edges, declared: Capability,
           floor: float = OPPORTUNISTIC_FLOOR) -> Advisory:
    """Assess a solved route against a declared capability.

    `route_edges` is an iterable of `(start_m, end_m, data)` — the shape
    `trips.cues.Route.edges` already has, so the advisory lands on the same axis as
    the cue sheet rather than on a parallel one. **Nothing here mutates the route,
    the graph, or the edge dicts**: the advisory reads and reports. `tests/` asserts
    that a route solved before an assessment is identical to the one solved after it
    (FR29a: "it never excludes or reroutes").

    `floor` is the signal coverage below which an unflagged route reports
    `insufficient_signal` rather than `no_contrary_signal`. It defaults to the
    pre-registered `opportunistic` band because that is the value this spike started
    from; `analyze.py` reports every approach at the `read` band as well, and the
    degrade model is what decides between them.
    """
    flags: list[Flag] = []
    notes: list[AccessNote] = []
    gaps: list[tuple[float, float, bool]] = []
    route_m = 0.0
    signal_m = 0.0
    flagged_m = 0.0

    for start_m, end_m, data in route_edges:
        length = max(0.0, end_m - start_m)
        route_m = max(route_m, end_m)
        has_signal = surveyed(data)
        if has_signal:
            signal_m += length
        requires, hits = requirement_for(data)
        name = str(_first(data.get("name")) or _first(data.get("ref")) or "unnamed road")

        if requires > declared and hits:
            rule = hits[0]
            flags.append(Flag(start_m=start_m, end_m=end_m, requires=requires,
                              signal=f"{rule.key}={rule.value}", note=rule.note,
                              way=name))
            flagged_m += length
        else:
            gaps.append((start_m, end_m, has_signal))

        access = _tag(data, "motor_vehicle") or _tag(data, "access")
        if access in ACCESS_NOTES:
            notes.append(AccessNote(start_m=start_m, end_m=end_m, value=access,
                                    note=ACCESS_NOTES[access], way=name))

    signal_pct = 100.0 * signal_m / route_m if route_m else 0.0
    merged = _merge(flags, gaps)
    if merged:
        state = "flagged"
    elif signal_pct >= floor:
        state = "no_contrary_signal"
    else:
        state = "insufficient_signal"

    return Advisory(
        declared=declared,
        state=state,
        flags=merged,
        access_notes=_merge_notes(notes),
        route_km=round(route_m / 1000.0, 2),
        signal_km=round(signal_m / 1000.0, 2),
        signal_pct=round(signal_pct, 1),
        flagged_km=round(flagged_m / 1000.0, 2),
        raw_sections=len(flags),
    )


def _merge_notes(raw: list[AccessNote]) -> list[AccessNote]:
    merged: list[AccessNote] = []
    for note in sorted(raw, key=lambda n: n.start_m):
        if merged and merged[-1].value == note.value and note.start_m - merged[-1].end_m < 1.0:
            last = merged[-1]
            merged[-1] = AccessNote(last.start_m, note.end_m, last.value, last.note,
                                    last.way)
            continue
        merged.append(note)
    return merged


def advisory_cues(advisory: Advisory) -> list[dict]:
    """The cue-sheet half of C13a's AC, in `trips.cues.Cue`'s shape.

    `kind="advisory"` is a new cue kind, not a reuse of `hazard`: a hazard is
    unconditional and never suppressible (FR115, and `cues._SAFETY_CRITICAL` enforces
    it), while this is a declared-capability comparison the Author can change by
    declaring a different vehicle. Filing it as a hazard would make an advisory
    unhideable and a hazard arguable, and both of those are worse.
    """
    cues = [
        {
            "kind": "advisory",
            "distance_along_m": round(flag.start_m, 1),
            "instruction": (
                f"{flag.note} for {flag.length_m / 1000.0:.1f} km on {flag.way} — "
                f"needs {LABEL[flag.requires]}, you declared {LABEL[advisory.declared]}"
            ),
        }
        for flag in advisory.flags
    ]
    cues.extend(
        {
            "kind": "advisory",
            "distance_along_m": round(note.start_m, 1),
            "instruction": f"{note.note} ({note.value}) on {note.way}",
        }
        for note in advisory.access_notes
    )
    return sorted(cues, key=lambda cue: cue["distance_along_m"])
