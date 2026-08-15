"""SPIKE-05 — working out what an activity actually *is*, from its numbers.

The supplied corpus is exactly the input the product should expect from a Character: a
folder of files named like `i1234567.fit` — an opaque export ID and nothing else. Two
things about it drive this module.

**The good news: devices do label the sport.** Every FIT file here carries
`sport = cycling | walking | paddling`, and both GPX files carry `type = Ride`. So mode
detection is mostly a lookup, and the honest thing is to say so rather than build a
classifier to solve a problem the metadata already solved.

**The bad news: the label stops exactly where it gets interesting.** All five cycling FIT
files say `cycling / generic`. One of them is a mountain-bike ride. The device knows it
was cycling and has no idea it was singletrack — and singletrack versus pavement is
precisely the distinction FR16 asks the ETA model to make ("pavement vs. singletrack").
So the useful classification job is not mode, it is **terrain within a mode**, and no
device metadata will ever supply it.

This module therefore does two separate things and reports them separately:

  1. `resolve_mode()` — take the device's word, fall back to signals when it says nothing.
  2. `infer_terrain()` — ignore the device entirely, because it has nothing to say.

**On confidence:** this corpus has one off-road ride. One. Every threshold below is a
hypothesis drawn from a single positive example, and the write-up says so. What can be
claimed honestly is narrower and more useful: the candidate signals *separate this
activity from its six road siblings by a wide margin on more than one axis at once*, which
is a reason to collect labelled data, not a validated rule.
"""

from __future__ import annotations

from dataclasses import dataclass

# --- mode thresholds --------------------------------------------------------
# Only used when the device says nothing. Deliberately loose: a wrong mode is a bad ETA,
# but a *guessed* mode presented as certain is worse, so anything ambiguous returns low
# confidence and the caller is expected to ask the Character.
CYCLING_MIN_KMH = 10.0
PADDLING_MAX_ASCENT_PER_KM = 8.0     # water is flat; trails are not
PADDLING_SPEED_RANGE = (1.5, 10.0)

# --- terrain thresholds (cycling) -------------------------------------------
# See the module docstring on how little these are worth yet.
OFFROAD_MAX_KMH = 17.0
OFFROAD_MIN_STOPS_PER_KM = 0.8
OFFROAD_MIN_SPEED_CV = 0.35


@dataclass
class Classification:
    mode: str
    mode_source: str          # 'device' | 'inferred'
    mode_confidence: str      # 'high' | 'medium' | 'low'
    terrain: str              # 'road' | 'offroad' | 'trail' | 'water' | 'unknown'
    terrain_confidence: str
    evidence: dict


def ascent_per_km(activity) -> float:
    return activity.ascent_m / max(activity.distance_km, 0.01)


def stops_per_km(activity) -> float:
    return activity.stop_count / max(activity.distance_km, 0.01)


def resolve_mode(activity, declared: str | None) -> tuple[str, str, str]:
    """Device label first. It is right here, and pretending otherwise to show off a
    classifier would be building a worse answer than the one already in the file."""
    if declared:
        return declared, "device", "high"

    speed = activity.avg_moving_speed_kmh
    climb = ascent_per_km(activity)

    if speed >= CYCLING_MIN_KMH:
        return "cycling", "inferred", "high"
    if (PADDLING_SPEED_RANGE[0] <= speed <= PADDLING_SPEED_RANGE[1]
            and climb <= PADDLING_MAX_ASCENT_PER_KM):
        # Ascent per km is the discriminator that matters, not speed: paddling and
        # hiking overlap almost exactly on speed (both ~4 km/h in this corpus) and are
        # an order of magnitude apart on climbing.
        return "paddling", "inferred", "medium"
    return "hiking", "inferred", "medium"


def infer_terrain(activity, mode: str) -> tuple[str, str, dict]:
    """Terrain within a mode — the part no device records.

    Three independent signals, because any one alone has an innocent explanation:
    a slow ride might be loaded touring, a stoppy ride might be urban traffic lights, a
    ragged pace might be a hilly road route. Requiring agreement is what makes the call
    worth anything on evidence this thin.
    """
    speed = activity.avg_moving_speed_kmh
    evidence = {
        "avg_moving_speed_kmh": speed,
        "stops_per_km": round(stops_per_km(activity), 2),
        "speed_cv": activity.speed_cv,
        "ascent_per_km": round(ascent_per_km(activity), 1),
        "has_power": activity.has_power,
    }

    if mode == "paddling":
        return "water", "high", evidence
    if mode == "hiking":
        # Hiking terrain (path vs scramble) would need the same treatment, but nothing
        # in this corpus distinguishes them and inventing a threshold would be fiction.
        return "trail", "low", evidence

    signals = {
        "slow_for_a_bike": speed < OFFROAD_MAX_KMH,
        "frequent_stops": stops_per_km(activity) >= OFFROAD_MIN_STOPS_PER_KM,
        "ragged_pace": activity.speed_cv >= OFFROAD_MIN_SPEED_CV,
    }
    evidence["signals"] = signals
    agree = sum(signals.values())

    if agree >= 2:
        return "offroad", ("medium" if agree == 3 else "low"), evidence
    return "road", ("medium" if agree == 0 else "low"), evidence


def classify(activity, declared: str | None) -> Classification:
    mode, source, confidence = resolve_mode(activity, declared)
    terrain, terrain_confidence, evidence = infer_terrain(activity, mode)
    return Classification(
        mode=mode,
        mode_source=source,
        mode_confidence=confidence,
        terrain=terrain,
        terrain_confidence=terrain_confidence,
        evidence=evidence,
    )
