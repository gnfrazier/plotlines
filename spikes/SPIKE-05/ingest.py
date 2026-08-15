"""SPIKE-05 layer A — activity files in, derived metrics out. No location data escapes.

This is the layer the product would keep. It answers "what did this person actually do"
from a `.fit` or `.gpx` file and emits numbers: durations, distances, ascent, and a
speed-by-grade distribution. It is deliberately the *only* module in the spike that opens
an activity file, so the privacy boundary is one file wide.

**What the boundary actually guarantees, precisely:**

  * **FIT files: no position field is ever read.** Cumulative distance and altitude are
    recorded fields in the FIT `record` message, so the parser never needs a coordinate to
    do its job. `position_lat`/`position_long` are not in the field list it asks for.
  * **GPX files: positions are read, used to sum segment lengths, and discarded inside
    this function.** They are not stored and never reach an `Activity`. This is a weaker
    guarantee than the FIT path and it is stated rather than glossed, because GPX has no
    recorded-distance field. Integrating the `speed` extension instead was tried and
    rejected — it came in 2.7% and 8.0% short on the two files here, and an 8% distance
    error would swamp the entire error budget of the model this spike is testing.

`Activity` has no coordinate fields, no filename, and no timestamps. The label is assigned
by mode and sequence (`cycling-01`), because two of the supplied files carry place names
in the filename and publishing those would leak exactly what committing the traces would.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path

import fitdecode
import gpxpy

# Altitude from a barometric or GPS sensor is noisy at 1 Hz — differencing it raw invents
# grades of ±30% on flat ground. Smooth over a distance window instead of a time window,
# so the smoothing is the same on a 6 km/h walk and a 35 km/h descent.
GRADE_WINDOW_M = 100.0

# Below this, the athlete is not travelling. Mode-specific because 0.5 m/s is a stop on a
# bike and a slow but real walking pace on a steep trail.
MOVING_THRESHOLD_MPS = {"cycling": 1.0, "hiking": 0.3, "paddling": 0.2}

# Grade bins for the speed distribution, as fractions (-0.08 = 8% descent).
GRADE_BINS = (-0.08, -0.04, -0.01, 0.01, 0.04, 0.08)

# FIT sport → the spike's mode vocabulary.
SPORT_TO_MODE = {"cycling": "cycling", "walking": "hiking", "hiking": "hiking",
                 "running": "hiking", "paddling": "paddling", "rowing": "paddling",
                 "stand_up_paddleboarding": "paddling"}


@dataclass
class Sample:
    """One trackpoint, reduced to the four things the metrics need."""
    t: float             # seconds since activity start
    dist_m: float        # cumulative distance
    alt_m: float | None
    speed_mps: float | None
    cadence: float | None = None
    power_w: float | None = None
    hr: float | None = None


@dataclass
class Activity:
    label: str
    source_format: str                      # 'fit' | 'gpx'
    declared_sport: str | None              # what the device said, if anything
    declared_sub_sport: str | None
    mode: str                               # resolved by classify.py
    distance_km: float
    moving_s: float                         # time actually travelling
    elapsed_s: float                        # wall clock, stops included
    device_timer_s: float | None            # the device's own moving time, if recorded
    device_elapsed_s: float | None
    ascent_m: float
    descent_m: float
    avg_moving_speed_kmh: float
    speed_cv: float = 0.0                   # coefficient of variation of moving speed
    speed_by_grade: dict[str, dict] = field(default_factory=dict)
    stop_count: int = 0
    stopped_s: float = 0.0
    has_power: bool = False
    has_cadence: bool = False
    has_hr: bool = False
    sample_count: int = 0
    quality_flags: list[str] = field(default_factory=list)


# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------

def read_fit(path: Path) -> tuple[list[Sample], dict]:
    """Positions are never requested. Distance and altitude are recorded fields."""
    wanted = {"timestamp", "distance", "altitude", "enhanced_altitude",
              "speed", "enhanced_speed", "cadence", "power", "heart_rate"}
    samples: list[Sample] = []
    session: dict = {}
    t0 = None

    with fitdecode.FitReader(str(path)) as reader:
        for frame in reader:
            if frame.frame_type != fitdecode.FIT_FRAME_DATA:
                continue
            if frame.name == "session":
                for f in frame.fields:
                    if f.name in ("sport", "sub_sport", "total_timer_time",
                                  "total_elapsed_time", "total_distance",
                                  "total_ascent", "total_descent"):
                        session.setdefault(f.name, f.value)
            elif frame.name == "sport":
                for f in frame.fields:
                    if f.name in ("sport", "sub_sport"):
                        session.setdefault(f.name, f.value)
            elif frame.name == "record":
                vals = {f.name: f.value for f in frame.fields if f.name in wanted}
                ts, dist = vals.get("timestamp"), vals.get("distance")
                if ts is None or dist is None:
                    continue
                t0 = t0 or ts
                samples.append(Sample(
                    t=(ts - t0).total_seconds(),
                    dist_m=float(dist),
                    alt_m=_first(vals, "enhanced_altitude", "altitude"),
                    speed_mps=_first(vals, "enhanced_speed", "speed"),
                    cadence=vals.get("cadence"),
                    power_w=vals.get("power"),
                    hr=vals.get("heart_rate"),
                ))
    return samples, session


def read_gpx(path: Path) -> tuple[list[Sample], dict]:
    """Coordinates are read here, summed into a cumulative distance, and dropped.

    Nothing positional leaves this function. See the module docstring for why this path
    cannot match the FIT path's stronger guarantee.
    """
    with open(path, encoding="utf-8") as fh:
        gpx = gpxpy.parse(fh)

    samples: list[Sample] = []
    session = {"sport": (gpx.tracks[0].type if gpx.tracks else None), "sub_sport": None}
    t0 = None
    cumulative = 0.0
    previous = None

    for track in gpx.tracks:
        for segment in track.segments:
            for point in segment.points:
                if point.time is None:
                    continue
                if previous is not None:
                    cumulative += point.distance_2d(previous) or 0.0
                previous = point                      # local only; never stored
                t0 = t0 or point.time
                ext = _gpx_extensions(point)
                samples.append(Sample(
                    t=(point.time - t0).total_seconds(),
                    dist_m=cumulative,
                    alt_m=point.elevation,
                    speed_mps=ext.get("speed"),
                    cadence=ext.get("cad"),
                    power_w=ext.get("watts"),
                    hr=ext.get("hr"),
                ))
    del previous, gpx                                  # explicit: no positions retained
    return samples, session


def _gpx_extensions(point) -> dict:
    out = {}
    for element in (point.extensions or []):
        for child in element:
            tag = child.tag.split("}")[-1]
            if tag in ("speed", "cad", "watts", "hr", "atemp"):
                try:
                    out[tag] = float(child.text)
                except (TypeError, ValueError):
                    pass
    return out


def _first(values: dict, *keys):
    for k in keys:
        if values.get(k) is not None:
            return float(values[k])
    return None


# ---------------------------------------------------------------------------
# Derivation
# ---------------------------------------------------------------------------

def smooth_altitude(samples: list[Sample]) -> list[float | None]:
    """Distance-windowed mean. A time window would smooth a descent six times harder than
    a climb at the same effort, which biases exactly the grade/speed relationship the ETA
    model is built on."""
    alts = [s.alt_m for s in samples]
    if all(a is None for a in alts):
        return alts
    filled, last = [], None
    for a in alts:
        last = a if a is not None else last
        filled.append(last if last is not None else 0.0)

    out, n = [], len(samples)
    lo = 0
    for i in range(n):
        while samples[i].dist_m - samples[lo].dist_m > GRADE_WINDOW_M / 2 and lo < i:
            lo += 1
        hi = i
        while hi + 1 < n and samples[hi + 1].dist_m - samples[i].dist_m < GRADE_WINDOW_M / 2:
            hi += 1
        out.append(sum(filled[lo:hi + 1]) / (hi - lo + 1))
    return out


def derive(samples: list[Sample], session: dict, label: str, mode: str,
           source_format: str) -> Activity:
    if len(samples) < 10:
        raise ValueError(f"{label}: only {len(samples)} usable samples")

    smoothed = smooth_altitude(samples)
    threshold = MOVING_THRESHOLD_MPS.get(mode, 0.5)

    moving_s = stopped_s = 0.0
    ascent = descent = 0.0
    stop_count = 0
    in_stop = False
    buckets: dict[str, list] = {}
    moving_speeds: list[float] = []

    for i in range(1, len(samples)):
        a, b = samples[i - 1], samples[i]
        dt = b.t - a.t
        dd = b.dist_m - a.dist_m
        if dt <= 0 or dt > 300 or dd < 0:
            continue                                   # clock jump or device reset

        speed = b.speed_mps if b.speed_mps is not None else (dd / dt)
        if speed >= threshold:
            moving_s += dt
            moving_speeds.append(speed)
            in_stop = False
        else:
            stopped_s += dt
            if not in_stop:
                stop_count += 1
                in_stop = True

        da = (smoothed[i] - smoothed[i - 1]) if smoothed[i] is not None else 0.0
        if da > 0:
            ascent += da
        else:
            descent -= da

        # Speed-by-grade only samples *moving* time: a grade bin's speed should describe
        # travel, not the average of travel and standing at a gate.
        if speed >= threshold and dd > 0:
            grade = da / dd if dd > 0.5 else 0.0
            grade = max(-0.30, min(0.30, grade))
            buckets.setdefault(_grade_label(grade), []).append((speed, dd, dt))

    distance_km = (samples[-1].dist_m - samples[0].dist_m) / 1000
    elapsed_s = samples[-1].t - samples[0].t

    speed_by_grade = {}
    for name, rows in sorted(buckets.items()):
        dist = sum(r[1] for r in rows)
        time = sum(r[2] for r in rows)
        speeds = sorted(r[0] for r in rows)
        speed_by_grade[name] = {
            "samples": len(rows),
            "distance_km": round(dist / 1000, 2),
            "mean_kmh": round((dist / time) * 3.6, 2) if time else None,
            "median_kmh": round(speeds[len(speeds) // 2] * 3.6, 2),
        }

    flags = []
    device_timer = session.get("total_timer_time")
    device_elapsed = session.get("total_elapsed_time")
    if device_timer and device_elapsed and abs(device_timer - device_elapsed) < 1.0:
        # `total_timer_time == total_elapsed_time` means the device's timer ran for the
        # whole activity — i.e. it did **no pause detection at all**. So its "timer time"
        # is elapsed time under a moving-time name, and it cannot serve as ground truth
        # for moving time. (My first reading of this was backwards: it looks like
        # auto-pause, and it is the opposite of auto-pause.) The stops on these files are
        # real and have to be found from the speed trace instead — which is why
        # `moving_s` below can differ from `device_timer_s` by a wide margin on exactly
        # these activities.
        flags.append("device_no_pause_detection")
    if not any(s.alt_m is not None for s in samples):
        flags.append("no_altitude")
    if distance_km < 1.0:
        flags.append("very_short")

    return Activity(
        label=label,
        source_format=source_format,
        declared_sport=session.get("sport"),
        declared_sub_sport=session.get("sub_sport"),
        mode=mode,
        distance_km=round(distance_km, 2),
        moving_s=round(moving_s, 1),
        elapsed_s=round(elapsed_s, 1),
        device_timer_s=round(device_timer, 1) if device_timer else None,
        device_elapsed_s=round(device_elapsed, 1) if device_elapsed else None,
        ascent_m=round(ascent),
        descent_m=round(descent),
        avg_moving_speed_kmh=round(distance_km / (moving_s / 3600), 2) if moving_s else 0.0,
        speed_cv=round(_cv(moving_speeds), 3),
        speed_by_grade=speed_by_grade,
        stop_count=stop_count,
        stopped_s=round(stopped_s, 1),
        has_power=any(s.power_w for s in samples),
        has_cadence=any(s.cadence for s in samples),
        has_hr=any(s.hr for s in samples),
        sample_count=len(samples),
        quality_flags=flags,
    )


def _cv(values: list[float]) -> float:
    """Coefficient of variation — how ragged the pace is, independent of how fast it is.
    Steady road riding and stop-start singletrack differ here even at the same average."""
    if len(values) < 10:
        return 0.0
    mean = sum(values) / len(values)
    if mean <= 0:
        return 0.0
    var = sum((v - mean) ** 2 for v in values) / len(values)
    return math.sqrt(var) / mean


def _grade_label(grade: float) -> str:
    edges = GRADE_BINS
    if grade < edges[0]:
        return f"<{edges[0]:.0%}"
    for lo, hi in zip(edges, edges[1:]):
        if lo <= grade < hi:
            return f"{lo:.0%}..{hi:.0%}"
    return f">{edges[-1]:.0%}"


def load(path: Path) -> tuple[list[Sample], dict, str]:
    suffix = path.suffix.lower()
    if suffix == ".fit":
        samples, session = read_fit(path)
        return samples, session, "fit"
    if suffix == ".gpx":
        samples, session = read_gpx(path)
        return samples, session, "gpx"
    raise ValueError(f"unsupported activity format: {path.suffix}")


def declared_mode(session: dict) -> str | None:
    """The device's own label, normalised — or None when it says nothing useful.
    GPX track types ('Ride') and FIT sports ('walking') are different vocabularies."""
    raw = (session.get("sport") or "").strip().lower()
    if not raw:
        return None
    if raw in SPORT_TO_MODE:
        return SPORT_TO_MODE[raw]
    if raw in ("ride", "virtualride", "ebikeride", "bike"):
        return "cycling"
    if raw in ("hike", "walk", "run", "trailrun"):
        return "hiking"
    if raw in ("kayaking", "canoeing", "kayak", "canoe"):
        return "paddling"
    return None
