"""SPIKE-05 — the ETA module under test.

FR16 does not ask for "a speed model". It asks for **three** of them, and lets the Author
pick: a *system default*, a *custom Author pace*, or the *aggregated participant pace*.
That is the experiment, and it maps onto three concrete models with very different data
requirements:

| FR16 option | Model here | Data it needs |
|---|---|---|
| system default | `LiteratureModel` | **none** — published constants |
| custom Author pace | `PersonalModel` | that person's own history |
| aggregated participant pace | `PooledModel` | everyone's history for the mode |

The interesting question is not "does a speed model work" but **how much the personal and
pooled models actually buy over the free one**, because the free one is the only model
available for a new user planning their first trip. If the literature default is within
tolerance, FR16's other two options are polish. If it is not, they are load-bearing and
the Character-upload feature has to exist before ETAs can be shown at all.

**Every fitted number is produced under leave-one-out cross-validation.** The activity
being predicted is never in the data the model was fitted on. Without that, a model fitted
on twelve activities and scored on the same twelve would report a flattering number that
means nothing — the precise circularity this spike exists to avoid.

**Predicting moving time and predicting elapsed time are different problems** and are
scored separately. Moving time is physics and fitness. Elapsed time adds stops, which are
a decision — lunch, a photo, a mechanical — and are not predictable from terrain. Reporting
one number for both would hide which half is failing.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

# Grade bin midpoints, matching ingest.GRADE_BINS.
BIN_MIDPOINT = {
    "<-8%": -0.12, "-8%..-4%": -0.06, "-4%..-1%": -0.025, "-1%..1%": 0.0,
    "1%..4%": 0.025, "4%..8%": 0.06, ">8%": 0.12,
}


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class LiteratureModel:
    """FR16's *system default*: no personal data at all.

    Hiking uses **Tobler's hiking function**, the standard published walking-speed-vs-slope
    relation. Cycling and paddling have no equivalent single accepted curve, so they get a
    flat base speed with a linear grade penalty, using round numbers a planner would
    recognise. That asymmetry is honest: the hiking default rests on established work and
    the cycling one is a plausible constant, and the results should be read accordingly.
    """

    name = "literature (system default, no personal data)"

    BASE_KMH = {"cycling": 20.0, "offroad": 13.0, "paddling": 4.5}

    def speed_kmh(self, mode: str, terrain: str, grade: float) -> float:
        if mode == "hiking":
            # Tobler: W = 6·exp(−3.5·|S + 0.05|) km/h, fastest at a gentle −5% descent.
            return 6.0 * math.exp(-3.5 * abs(grade + 0.05))
        if mode == "paddling":
            return self.BASE_KMH["paddling"]
        base = self.BASE_KMH["offroad" if terrain == "offroad" else "cycling"]
        # Climbing costs more than descending returns — a deliberate asymmetry, because a
        # symmetric model predicts that a rolling route is free, which no one believes.
        if grade > 0:
            return max(4.0, base * (1 - 9.0 * grade))
        return min(base * 1.45, base * (1 - 3.0 * grade))

    def fit(self, activities):            # nothing to fit; present for interface parity
        return self


class BinnedModel:
    """Empirical speed per grade bin, distance-weighted across the fitted activities.

    Used for both FR16's *custom Author pace* (fitted on one person's own activities) and
    its *aggregated participant pace* (fitted across the pool). Here the corpus is one
    person, so the two coincide — a limit stated plainly in the results rather than
    papered over by calling the same number two things.
    """

    def __init__(self, name: str, group_by_terrain: bool = True):
        self.name = name
        self.group_by_terrain = group_by_terrain
        self.table: dict[tuple, dict[str, float]] = {}
        self.fallback: dict[tuple, float] = {}

    def _key(self, mode: str, terrain: str) -> tuple:
        return (mode, terrain) if self.group_by_terrain else (mode, "*")

    def fit(self, activities):
        totals: dict[tuple, dict[str, list]] = {}
        overall: dict[tuple, list] = {}
        for act, cls in activities:
            for key in {self._key(cls.mode, cls.terrain), (cls.mode, "*")}:
                # A mode-level total is always accumulated alongside the terrain-level
                # one, so a held-out activity whose terrain has no other examples falls
                # back to "this person on a bike" instead of a constant from nowhere.
                overall.setdefault(key, [0.0, 0.0])
                overall[key][0] += act.distance_km
                overall[key][1] += act.moving_s / 3600
            key = self._key(cls.mode, cls.terrain)
            for label, stats in act.speed_by_grade.items():
                if not stats["mean_kmh"]:
                    continue
                slot = totals.setdefault(key, {}).setdefault(label, [0.0, 0.0])
                slot[0] += stats["distance_km"]
                slot[1] += stats["distance_km"] / stats["mean_kmh"]   # hours in this bin

        self.table = {
            key: {label: (d / h) for label, (d, h) in bins.items() if h > 0}
            for key, bins in totals.items()
        }
        self.fallback = {key: (d / h) for key, (d, h) in overall.items() if h > 0}
        return self

    def speed_kmh(self, mode: str, terrain: str, grade: float) -> float:
        key = self._key(mode, terrain)
        label = _label_for(grade)
        bins = self.table.get(key, {})
        if label in bins:
            return bins[label]
        if bins:
            # Nearest populated bin rather than the overall average: a held-out activity
            # with a 10% climb should not be predicted at the person's flat-ground speed
            # just because they have never logged that grade before.
            nearest = min(bins, key=lambda lb: abs(BIN_MIDPOINT.get(lb, 0) - grade))
            return bins[nearest]
        # Terrain unseen (e.g. the corpus's single off-road ride, held out): use the
        # mode average. There is no honest constant for "mountain biking" here, and an
        # invented one produces an error figure that measures the constant rather than
        # the model — which is what an earlier version of this line did.
        speed = self.fallback.get(key) or self.fallback.get((mode, "*"))
        if speed:
            return speed
        raise Unpredictable(f"no fitted speed for mode={mode} terrain={terrain}")


class Unpredictable(Exception):
    """Raised when a model has no basis for a prediction. Reported as 'insufficient
    data', never silently replaced by a default — a wrong ETA presented confidently is
    the failure mode this whole spike exists to measure."""


class FlatAverageModel(BinnedModel):
    """The baseline that has to be beaten: one average speed per mode, grade ignored.

    If the grade-aware models cannot beat this, the grade machinery is unearned
    complexity and FR16 should ship a single number per mode.
    """

    name = "flat average (baseline — grade ignored)"

    def speed_kmh(self, mode: str, terrain: str, grade: float) -> float:
        key = self._key(mode, terrain)
        speed = self.fallback.get(key) or self.fallback.get((mode, "*"))
        if speed:
            return speed
        raise Unpredictable(f"no fitted speed for mode={mode} terrain={terrain}")


def _label_for(grade: float) -> str:
    edges = (-0.08, -0.04, -0.01, 0.01, 0.04, 0.08)
    if grade < edges[0]:
        return "<-8%"
    for lo, hi in zip(edges, edges[1:]):
        if lo <= grade < hi:
            return f"{lo:.0%}..{hi:.0%}"
    return ">8%"


# ---------------------------------------------------------------------------
# Prediction & evaluation
# ---------------------------------------------------------------------------

def predict_moving_s(model, activity, cls) -> float | None:
    """Time = Σ over grade bins of (distance in bin ÷ predicted speed in bin).

    The held-out activity supplies its *grade profile* — how far it goes at each
    steepness — which is exactly what a planned route provides before it is ridden. It
    does not supply any of its own speeds.
    """
    total_h = 0.0
    covered = 0.0
    for label, stats in activity.speed_by_grade.items():
        dist = stats["distance_km"]
        if dist <= 0:
            continue
        try:
            speed = model.speed_kmh(cls.mode, cls.terrain, BIN_MIDPOINT.get(label, 0.0))
        except Unpredictable:
            return None
        if not speed or speed <= 0:
            continue
        total_h += dist / speed
        covered += dist
    if covered <= 0:
        return None
    # Grade bins only cover moving distance; rescale to the activity's full distance so a
    # model is never rewarded for quietly predicting a shorter route.
    return total_h * 3600 * (activity.distance_km / covered)


@dataclass
class Evaluation:
    model: str
    target: str                 # 'moving' | 'elapsed'
    n: int
    mape: float                 # mean absolute percentage error
    median_ape: float
    worst_ape: float
    worst_label: str
    within_10pct: int
    within_20pct: int
    # Per-mode MAPE. The headline aggregate averages cycling and hiking together, and
    # they behave so differently that the combined number describes neither — this is
    # where the actual answer to FR16 lives.
    by_mode: dict[str, dict]
    per_activity: list[dict]


def leave_one_out(model_factory, dataset, target: str = "moving") -> Evaluation:
    """Refit from scratch for every held-out activity.

    Only same-mode activities are used for fitting, since a cycling speed tells you
    nothing about a paddling pace. An activity whose mode has no other examples is
    reported as unpredictable rather than silently dropped — with one paddling file in the
    corpus, that case is not hypothetical and hiding it would overstate coverage.
    """
    rows = []
    for i, (act, cls) in enumerate(dataset):
        others = [(a, c) for j, (a, c) in enumerate(dataset)
                  if j != i and c.mode == cls.mode]
        model = model_factory()
        if not isinstance(model, LiteratureModel):
            if not others:
                rows.append({"label": act.label, "mode": cls.mode, "terrain": cls.terrain,
                             "actual_s": None, "predicted_s": None, "ape": None,
                             "note": "no other activity of this mode to fit on"})
                continue
            model.fit(others)

        predicted = predict_moving_s(model, act, cls)
        if predicted is None:
            rows.append({"label": act.label, "mode": cls.mode, "terrain": cls.terrain,
                         "actual_s": None, "predicted_s": None, "ape": None,
                         "note": "no usable grade profile"})
            continue

        if target == "elapsed":
            # Stops are not predicted from terrain — the only honest naive rule is the
            # mode's own historical stop ratio, again fitted without the held-out file.
            ratios = [a.elapsed_s / a.moving_s for a, c in others
                      if a.moving_s > 0 and "device_no_pause_detection" not in a.quality_flags]
            ratio = (sum(ratios) / len(ratios)) if ratios else 1.0
            predicted *= ratio
            actual = act.elapsed_s
        else:
            actual = act.moving_s

        ape = abs(predicted - actual) / actual * 100 if actual else None
        # Flag predictions made with no same-terrain example to learn from. These are
        # extrapolations, and reading them as ordinary model error overstates how badly
        # the model does on terrain it has actually seen.
        same_terrain = any(c.terrain == cls.terrain for _, c in others)
        rows.append({"label": act.label, "mode": cls.mode, "terrain": cls.terrain,
                     "actual_s": round(actual), "predicted_s": round(predicted),
                     "ape": round(ape, 1) if ape is not None else None,
                     "note": "" if same_terrain or isinstance(model, LiteratureModel)
                             else "extrapolated: no same-terrain example to fit on"})

    scored = [r for r in rows if r["ape"] is not None]
    apes = sorted(r["ape"] for r in scored)
    worst = max(scored, key=lambda r: r["ape"]) if scored else {"ape": 0, "label": "-"}

    by_mode: dict[str, dict] = {}
    for mode in sorted({r["mode"] for r in rows}):
        # Extrapolated rows are held separately: including them scores the fallback rule
        # rather than the model, and excluding them silently would hide a real failure.
        got = [r for r in scored if r["mode"] == mode and not r["note"]]
        extra = [r for r in scored if r["mode"] == mode and r["note"]]
        by_mode[mode] = {
            "n": len(got),
            "mape": round(sum(r["ape"] for r in got) / len(got), 1) if got else None,
            "n_extrapolated": len(extra),
            "extrapolated_mape": (round(sum(r["ape"] for r in extra) / len(extra), 1)
                                  if extra else None),
            "n_unpredictable": sum(1 for r in rows
                                   if r["mode"] == mode and r["ape"] is None),
        }
    return Evaluation(
        model=model_factory().name,
        target=target,
        n=len(scored),
        mape=round(sum(apes) / len(apes), 1) if apes else float("nan"),
        median_ape=round(apes[len(apes) // 2], 1) if apes else float("nan"),
        worst_ape=round(worst["ape"], 1) if scored else float("nan"),
        worst_label=worst["label"],
        within_10pct=sum(1 for a in apes if a <= 10),
        within_20pct=sum(1 for a in apes if a <= 20),
        by_mode=by_mode,
        per_activity=rows,
    )
