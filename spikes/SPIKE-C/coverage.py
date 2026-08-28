"""SPIKE-C step 2 — the coverage measurement, and the payload the UI would surface.

Two things live here, and the second is the reason the first has a particular shape.

**The measurement.** `measure(ways, schema)` counts, over a stated denominator, how many
eligible ways carry the schema and how many kilometres they represent. Both, always:
way-count is what the issue asks for and what compares to SPIKE-03's surface figures,
kilometre-share is what an Author's leg is actually made of, and where the two disagree
the disagreement is itself the finding.

**The honesty payload.** FR14b and B9 both require that *"source and coverage be stated
honestly rather than presenting sparse data as complete"*, and the issue asks for the
figures "in a form the UI can actually surface beside the grade" — A19's precedent, where
the fix for thin `surface` tagging was to show tag coverage beside the cue sheet.

`CoverageNote` is that form. It is deliberately not a percentage in a tooltip. It carries
the four things a reader needs to decide whether to trust a grade — how many of the ways
under it were graded, how much of the distance, which vocabulary the numbers came from,
and the resulting band — plus a `claim` string that states the *limit* rather than the
number. The distinction it exists to enforce:

    graded    "T3 — demanding mountain hiking"          the way carries the tag
    partial   "T3 on 4 of 31 graded ways; 27 ungraded"  a floor, never a summary
    silent    "No published grade for this leg"         not "easy"

A leg where nothing is tagged must render as the third, never as the first — and the
type makes it awkward to do otherwise, because `worst` is `None` there and there is no
number to print. That is the whole design intent: the sparse case should be hard to
present as the complete case, not merely discouraged in a comment.

This is a spike-local prototype. It changes no product code — same discipline as SPIKE-D
and SPIKE-H — but it is the shape B9 would ship if FR14b survives.
"""

from __future__ import annotations

import sys
from dataclasses import asdict, dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from schemas import CONTROL_TAGS, Schema, band_for, rank  # noqa: E402


def by_tags(pred):
    """Lift a tag-level eligibility predicate to a way-level one.

    Denominators are written against tags in `schemas.py`, but two of them —
    `route=hiking`/`route=mtb` membership — are properties of the way's *id*, not its
    tags. Rather than give every predicate an argument it does not need, everything is
    normalised to way-level here and the tag-only ones are lifted.
    """
    return lambda way: pred(way["tags"])


@dataclass(frozen=True)
class Coverage:
    """Coverage of one schema over one denominator in one region."""

    schema: str
    denominator: str
    eligible_ways: int
    tagged_ways: int
    eligible_km: float
    tagged_km: float
    unparsed_ways: int          # tag present, value outside the vocabulary
    values: dict                # raw value -> way count, for the distribution table

    @property
    def pct_ways(self) -> float:
        return 100.0 * self.tagged_ways / self.eligible_ways if self.eligible_ways else 0.0

    @property
    def pct_km(self) -> float:
        return 100.0 * self.tagged_km / self.eligible_km if self.eligible_km else 0.0

    @property
    def band(self) -> str:
        band = band_for(self.pct_ways, self.eligible_ways)
        return band.key if band else "n/a"

    def to_dict(self) -> dict:
        d = asdict(self)
        d.update(pct_ways=round(self.pct_ways, 2), pct_km=round(self.pct_km, 2),
                 band=self.band,
                 eligible_km=round(self.eligible_km, 1),
                 tagged_km=round(self.tagged_km, 1))
        return d


def measure(ways: list[dict], schema: Schema, eligible, label: str) -> Coverage:
    """Coverage of one schema over one explicitly-named denominator.

    The denominator is passed in rather than selected by a flag, because this spike
    reports three of them per schema and the whole point is that the choice stays
    visible at every call site.
    """
    n_elig = n_tag = n_unparsed = 0
    km_elig = km_tag = 0.0
    values: dict[str, int] = {}
    for way in ways:
        tags = way["tags"]
        if not eligible(way):
            continue
        n_elig += 1
        km = way["length_m"] / 1000.0
        km_elig += km
        raw = tags.get(schema.tag)
        if raw is None:
            continue
        n_tag += 1
        km_tag += km
        values[raw] = values.get(raw, 0) + 1
        if rank(schema, raw) is None:
            n_unparsed += 1
    return Coverage(schema=schema.key, denominator=label,
                    eligible_ways=n_elig, tagged_ways=n_tag,
                    eligible_km=km_elig, tagged_km=km_tag,
                    unparsed_ways=n_unparsed,
                    values=dict(sorted(values.items(), key=lambda kv: -kv[1])))


def controls(ways: list[dict], schema: Schema, eligible) -> dict:
    """Coverage of ordinary attributes over the *identical* denominator.

    This is what stops a zero from being unreadable. If `sac_scale` is at 2% and
    `surface` is at 60% on the same ways in the same box, the ways are attributed and
    the schema is not used. If both are at 2%, nobody has touched these ways at all,
    and that is a different problem with a different fix.
    """
    n = 0
    hits = {t: 0 for t in CONTROL_TAGS}
    for way in ways:
        if not eligible(way):
            continue
        n += 1
        for tag in CONTROL_TAGS:
            if tag in way["tags"]:
                hits[tag] += 1
    return {t: round(100.0 * c / n, 2) if n else 0.0 for t, c in hits.items()}


# ------------------------------------------------------- the UI-facing honesty payload

@dataclass(frozen=True)
class CoverageNote:
    """What B9 would render beside a difficulty grade.

    `claim` is the load-bearing field. It is written as a statement about the *evidence*,
    not about the terrain, so that the sparse case cannot be mistaken for an easy one.
    """

    schema: str
    source: str
    state: str            # "graded" | "partial" | "silent"
    worst: str | None     # hardest value found, or None when nothing is graded
    graded_ways: int
    total_ways: int
    graded_km: float
    total_km: float
    claim: str

    @property
    def pct_ways(self) -> float:
        return 100.0 * self.graded_ways / self.total_ways if self.total_ways else 0.0


def _ways(n: int) -> str:
    return f"{n} way" if n == 1 else f"{n} ways"


def note_for_leg(ways: list[dict], schema: Schema, *, broad: bool = True,
                 source: str = "OpenStreetMap") -> CoverageNote:
    """Build the honesty payload for one leg's worth of ways.

    The aggregation rule is **worst-of**, because difficulty does not average: a leg
    with one T5 pitch is a T5 leg however gentle its other 20 km are. That choice is
    what makes missing coverage dangerous rather than merely lossy — the untagged way
    is exactly as likely to be the crux as any other — and it is the failure
    `degrade.py` quantifies.
    """
    eligible = schema.broad if broad else schema.strict
    legs = [w for w in ways if eligible(w["tags"])]
    graded = [w for w in legs if schema.tag in w["tags"]]

    total_km = sum(w["length_m"] for w in legs) / 1000.0
    graded_km = sum(w["length_m"] for w in graded) / 1000.0

    ranked = [(rank(schema, w["tags"][schema.tag]), w) for w in graded]
    ranked = [(r, w) for r, w in ranked if r is not None]
    worst = max(ranked, key=lambda rw: rw[0])[1]["tags"][schema.tag] if ranked else None

    ungraded = len(legs) - len(graded)
    if not graded:
        state, claim = "silent", (
            f"No published {schema.tag} for this leg. "
            f"{_ways(len(legs))}, {total_km:.1f} km, none graded — the grade is the "
            f"Author's to declare, not the map's to supply.")
    elif len(graded) == len(legs):
        state, claim = "graded", (
            f"{schema.tag} published for every way on this leg "
            f"({_ways(len(legs))}, {total_km:.1f} km), {source}.")
    else:
        state, claim = "partial", (
            f"{worst} is the hardest grade among {len(graded)} of {len(legs)} graded "
            f"ways ({graded_km:.1f} of {total_km:.1f} km, {source}). "
            f"{_ways(ungraded)} {'is' if ungraded == 1 else 'are'} ungraded — this is "
            f"a floor, not a summary.")

    return CoverageNote(schema=schema.tag, source=source, state=state, worst=worst,
                        graded_ways=len(graded), total_ways=len(legs),
                        graded_km=round(graded_km, 2), total_km=round(total_km, 2),
                        claim=claim)
