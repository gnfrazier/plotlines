"""SPIKE-C step 3 — does thin coverage produce *silence* or *wrong answers*?

This is the half of the issue that a coverage table cannot answer. Knowing
`sac_scale` sits at 3% in New Hampshire tells you the schema is thin; it does not tell
you whether shipping FR14b anyway is harmless or harmful. SPIKE-21's precedent is the
benign case — the unknown-tag rule meant thin `surface` coverage produced *no cue*,
which is a loss of capability and nothing worse. Difficulty is not obviously the same,
because the aggregation rule is different: cues are per-edge, but a grade for a leg is
**worst-of** its ways, and a worst-of taken over a sample is biased low by construction.

So: measure it, on real data, rather than argue it.

**Method.** Take the one region with enough tagged ways to have a ground truth — the
Tyrol, where these schemas are native — and assemble real legs from it. Each leg is a
group of ways sharing a `name`, which is as close to "a trail an Author would put in a
day" as OSM offers for free, and crucially it preserves the *spatial* correlation of
tagging: mappers grade a whole trail at a time, not a random 8% of the network.

For each leg with full coverage, take its true grade (worst-of, over all its ways).
Then thin the tagging to a target coverage `p` and take the grade again. Three outcomes:

    silent        nothing survived   -> the app says "no published grade". Acceptable.
    correct       worst-of survived  -> the app is right.
    understated   a harder way was dropped -> **the app shows a confident wrong number.**

Understatement is the asymmetric failure and the only one that matters. An overstated
grade sends an Author to go and look; an understated one tells a Character a T5 scramble
is a T2 walk. Overstatement cannot occur under worst-of thinning, which is itself worth
stating: every error this mechanism can produce is an error in the dangerous direction.

**Three thinning models, because the spread between them is the finding.** Tagging is
not sprinkled at random — a mapper grades a stretch of trail in one sitting — and how
*correlated* the gaps are decides whether thin coverage is dangerous or merely empty.

    random     each way keeps its tag independently with probability p. Maximum
               scatter: nearly every leg keeps *something*, and what it keeps is
               nearly always an understatement. The pessimistic bracket.
    block      a contiguous run of ways within the leg is tagged, the rest is not —
               ways ordered by id, which is a proxy for creation order and therefore
               for editing session, which is the correlation being modelled. This is
               the realistic middle: partial legs with gaps that clump.
    leg        whole legs keep or lose their tagging together. Understatement here is
               **0% by construction**, not by measurement — the cluster unit and the
               aggregation unit are the same, so a leg is either whole or absent. It
               is reported as the optimistic bracket precisely so that zero is read
               as the artefact it is.

Reality sits between `random` and `leg`, and `block` is the honest estimate of where.
The measured North American coverage rates are used as the `p` values, so the question
being answered is literally "if we shipped this in the White Mountains, what would it
say".

Usage:
    python spikes/SPIKE-C/degrade.py
"""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import cache  # noqa: E402
from schemas import MAX_UNDERSTATEMENT_PCT, Schema, rank  # noqa: E402

HERE = Path(__file__).parent
RAW = HERE / "raw"
RESULTS = HERE / "results"

#: Fixed so the published numbers reproduce exactly.
SEED = 20260828
TRIALS = 400

#: A leg needs enough ways for a worst-of to be losable at all. Below ~4 the
#: experiment degenerates: at 1 way, thinning is silence or truth and never error.
MIN_WAYS = 4


def legs_from(ways: list[dict], schema: Schema, eligible) -> list[list[dict]]:
    """Real named trails, fully graded, as the ground-truth legs.

    Only fully-graded legs qualify — a partially graded leg has no true worst-of to
    measure against, and using its observed worst as truth would bake the very
    understatement being measured into the baseline.
    """
    by_name: dict[str, list[dict]] = {}
    for way in ways:
        tags = way["tags"]
        if not eligible(tags):
            continue
        name = tags.get("name")
        if not name:
            continue
        by_name.setdefault(name, []).append(way)

    out = []
    for group in by_name.values():
        # `block` needs a stable within-leg order to run a contiguous window over;
        # way id is the only proxy for adjacency left after geometry was discarded,
        # and it approximates creation order, which is the correlation being modelled.
        group.sort(key=lambda w: w["id"])
        if len(group) < MIN_WAYS:
            continue
        if not all(schema.tag in w["tags"] for w in group):
            continue
        if any(rank(schema, w["tags"][schema.tag]) is None for w in group):
            continue
        out.append(group)
    return out


def _worst(group: list[dict], schema: Schema, kept: list[bool]) -> int | None:
    ranks = [rank(schema, w["tags"][schema.tag])
             for w, k in zip(group, kept) if k]
    return max(ranks) if ranks else None


MODELS = ("random", "block", "leg")


def _kept_mask(n: int, p: float, rng: random.Random, model: str) -> list[bool]:
    if model == "random":
        return [rng.random() < p for _ in range(n)]
    if model == "leg":
        return [rng.random() < p] * n
    # block: a contiguous run of round(p*n) ways at a random offset, wrapping, so the
    # tagged stretch is as likely to sit at the middle of a trail as at its head.
    k = int(round(p * n))
    if k <= 0:
        return [False] * n
    if k >= n:
        return [True] * n
    start = rng.randrange(n)
    kept = [False] * n
    for i in range(k):
        kept[(start + i) % n] = True
    return kept


def run_leg(group: list[dict], schema: Schema, p: float, rng: random.Random,
            *, model: str, trials: int) -> dict:
    truth = _worst(group, schema, [True] * len(group))
    silent = correct = understated = 0
    shortfall = []
    for _ in range(trials):
        kept = _kept_mask(len(group), p, rng, model)
        seen = _worst(group, schema, kept)
        if seen is None:
            silent += 1
        elif seen == truth:
            correct += 1
        else:
            understated += 1
            shortfall.append(truth - seen)
    return {"ways": len(group), "truth": truth,
            "silent": silent, "correct": correct, "understated": understated,
            "mean_shortfall_steps": (round(sum(shortfall) / len(shortfall), 2)
                                     if shortfall else 0.0)}


def sweep(ways: list[dict], schema: Schema, eligible, rates: list[float]) -> dict:
    legs = legs_from(ways, schema, eligible)
    if not legs:
        return {"legs": 0, "note": "no fully-graded multi-way named trail in this region"}

    # A leg whose ways are all the same grade cannot be understated by any thinning;
    # counting it would dilute the rate with cases that are structurally safe. Both
    # populations are reported — "how many legs are even at risk" is part of the answer.
    at_risk = [g for g in legs
               if len({rank(schema, w["tags"][schema.tag]) for w in g}) > 1]

    out = {"legs": len(legs), "legs_at_risk": len(at_risk),
           "ways_in_legs": sum(len(g) for g in legs),
           "km_in_legs": round(sum(w["length_m"] for g in legs for w in g) / 1000, 1),
           "trials_per_leg": TRIALS, "seed": SEED, "rates": {}}

    for p in rates:
        for model in MODELS:
            rng = random.Random(SEED)
            totals = {"silent": 0, "correct": 0, "understated": 0}
            shortfalls = []
            for group in legs:
                r = run_leg(group, schema, p, rng, model=model, trials=TRIALS)
                for k in totals:
                    totals[k] += r[k]
                if r["understated"]:
                    shortfalls.append(r["mean_shortfall_steps"])
            n = sum(totals.values())
            shown = totals["correct"] + totals["understated"]
            out["rates"].setdefault(f"{p:.3f}", {})[model] = {
                "silent_pct": round(100.0 * totals["silent"] / n, 1),
                "correct_pct": round(100.0 * totals["correct"] / n, 1),
                "understated_pct": round(100.0 * totals["understated"] / n, 1),
                # The number that decides FR14b: *given the app showed a grade*, how
                # often was that grade wrong. A schema can be mostly-silent and still
                # be unshippable if everything it does say is false.
                "understated_given_shown_pct": (
                    round(100.0 * totals["understated"] / shown, 1) if shown else None),
                "mean_shortfall_steps": (round(sum(shortfalls) / len(shortfalls), 2)
                                         if shortfalls else 0.0),
            }
    return out


def crossover(rates: dict, model: str, ceiling: float) -> float | None:
    """The coverage `p` at which understatement-given-a-grade-was-shown falls below
    `ceiling`, linearly interpolated between the two sweep points that bracket it.

    This is the number the declared `read` floor should be checked against. The band
    floors in `schemas.py` were set from A19's precedent — what `surface` coverage did
    to cue sheets — before any of this was measured; the crossover is the same floor
    derived independently, from the harm rather than from the precedent. Agreeing is a
    result; disagreeing would have been a more interesting one.
    """
    pts = []
    for key, models in rates.items():
        row = models.get(model)
        if row and row.get("understated_given_shown_pct") is not None:
            pts.append((float(key), row["understated_given_shown_pct"]))
    pts.sort()
    for (p0, v0), (p1, v1) in zip(pts, pts[1:]):
        if v0 > ceiling >= v1:
            if v0 == v1:
                return round(p1, 3)
            return round(p0 + (v0 - ceiling) * (p1 - p0) / (v0 - v1), 3)
    return None


def main() -> int:
    from regions import REGIONS_BY_KEY  # noqa: F401  (kept for symmetry / future use)
    from schemas import SCHEMAS_BY_KEY

    measured = json.loads((RESULTS / "coverage.json").read_text())
    ways = cache.load(RAW / "tyrol-ways.json")

    out = {"region": "tyrol", "why": (
        "The only region in the set with enough graded ways for a ground truth. "
        "The rates swept are the ones measured in North America, so the question is "
        "'what would this say if we shipped it there'."), "schemas": {}}

    for key in ("sac_scale", "mtb:scale", "piste:difficulty"):
        schema = SCHEMAS_BY_KEY[key]
        rows = [r for r in measured["coverage"]
                if r["schema"] == key and r["scope"] == "broad"]
        # Sweep the real North American coverage rates, plus round anchors so the
        # curve is readable between them.
        na = sorted({round(r["pct_ways"] / 100.0, 3) for r in rows
                     if r["region"] != "tyrol"})
        rates = sorted({*na, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90})
        result = sweep(ways, schema, schema.broad, rates)
        if result.get("rates"):
            result["crossover_pct"] = {
                model: (None if (c := crossover(result["rates"], model,
                                                MAX_UNDERSTATEMENT_PCT)) is None
                        else round(c * 100, 1))
                for model in MODELS
            }
        out["schemas"][key] = result
        print(f"{key}: {result.get('legs', 0)} legs, "
              f"{result.get('legs_at_risk', 0)} at risk, "
              f"crossover {result.get('crossover_pct')}")

    RESULTS.mkdir(exist_ok=True)
    (RESULTS / "degrade.json").write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {RESULTS / 'degrade.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
