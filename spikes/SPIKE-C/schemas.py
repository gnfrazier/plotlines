"""What counts as a difficulty schema, what counts as an eligible way, and what
counts as "usable" — all three declared **before** the run — issue #170.

The single most manipulable number in a coverage spike is the *denominator*. "Is
`sac_scale` coverage 3% or 40%?" has no answer until someone says what it is a
percentage of, and any conclusion is reachable by drafting that set to taste. So the
denominators live here, in one file, written down before any query was issued, with
the reasoning attached — and every published figure is reported against **two** of
them (a strict one and a broad one) so the choice is visible instead of buried.

The same goes for the threshold. SPIKE-21 declared its legibility ceiling (4.0
cues/km) before the run and its first implementation *failed* it, which is the only
reason that number meant anything. `BANDS` below is this spike's equivalent.
"""

from __future__ import annotations

from dataclasses import dataclass

# --------------------------------------------------------------------- eligibility

#: Footway values that are street furniture, not trail. `sac_scale` on a road
#: crossing is not a thing anyone would ever map, so counting crossings in the
#: hiking denominator would depress coverage in exact proportion to how *urban* a
#: bbox is — turning a mapping question into a geometry-of-the-bbox question.
_NON_TRAIL_FOOTWAY = {"sidewalk", "crossing", "traffic_island", "link", "access_aisle"}

#: Nordic pistes are the denominator for `piste:difficulty`; `piste:type` is a
#: semicolon list in the wild (`nordic;skitour`).
NORDIC_PISTE = "nordic"


def _is_trail_footway(tags: dict) -> bool:
    return tags.get("highway") == "footway" and \
        tags.get("footway") not in _NON_TRAIL_FOOTWAY


def eligible_hiking_strict(tags: dict) -> bool:
    """`highway=path` — the way type the `sac_scale` wiki page is written about.

    The conservative reading, and the one most favourable to FR14b: if coverage is
    thin even here, it is thin on the ways the schema was designed for.
    """
    return tags.get("highway") == "path"


def eligible_hiking_broad(tags: dict) -> bool:
    """Everything a hiker actually walks off-street: path, track, bridleway, steps,
    and footway that is not sidewalk/crossing furniture.

    Broader than the wiki's reading, and deliberately so — an Author's hiking day
    routes over all of these, so this is the denominator the *product* would face
    if it tried to grade a leg rather than a way.
    """
    h = tags.get("highway")
    return h in {"path", "track", "bridleway", "steps"} or _is_trail_footway(tags)


def eligible_mtb_strict(tags: dict) -> bool:
    """`highway=path` — singletrack, what `mtb:scale` grades."""
    return tags.get("highway") == "path"


def eligible_mtb_broad(tags: dict) -> bool:
    """Path, track, bridleway, cycleway — everything rideable off-road."""
    return tags.get("highway") in {"path", "track", "bridleway", "cycleway"}


def eligible_mtb_signposted(tags: dict) -> bool:
    """The subset a mountain-bike mapper has already touched: `mtb=*` present, or an
    `mtb:*` key of any kind other than the graded ones.

    This is the honest best case for `mtb:scale`. A community that signs and maps its
    trails for mountain biking is exactly the community that would grade them, so
    coverage over *this* denominator separates "the schema is unused" from "the
    schema is used, but only on the small part of the network anyone has curated".
    """
    if "mtb" in tags:
        return True
    return any(k.startswith("mtb:") and k not in MTB_GRADE_KEYS for k in tags)


def eligible_nordic(tags: dict) -> bool:
    """`piste:type` containing `nordic`. Unlike the other two this denominator is
    *self-selecting* — the same mapper writes `piste:type` and `piste:difficulty` in
    the same edit — so a high percentage here means much less than a high percentage
    for `sac_scale`, and the number that carries the weight is the absolute density
    of nordic pistes per 1,000 km2. Read them together or not at all.
    """
    return NORDIC_PISTE in {v.strip() for v in tags.get("piste:type", "").split(";")}


MTB_GRADE_KEYS = frozenset({"mtb:scale", "mtb:scale:uphill", "mtb:scale:imba"})


# ------------------------------------------------------------------------ schemas

@dataclass(frozen=True)
class Schema:
    key: str
    mode: str
    tag: str
    #: Ordered value vocabulary, easiest first. Used to rank a route's hardest way
    #: and — in `degrade.py` — to decide whether a thinned reading *understates*.
    values: tuple[str, ...]
    strict: object          # eligibility predicate: the wiki's reading
    broad: object           # eligibility predicate: what a routed leg actually covers
    strict_label: str
    broad_label: str
    note: str


SAC = ("hiking", "mountain_hiking", "demanding_mountain_hiking",
       "alpine_hiking", "demanding_alpine_hiking", "difficult_alpine_hiking")

#: Easiest-first. `trail_visibility` is an ordinal where *worse* is harder, so the
#: tuple runs excellent -> no; `no` is the dangerous end.
VISIBILITY = ("excellent", "good", "intermediate", "bad", "horrible", "no")

MTB_SCALE = tuple(str(i) for i in range(7))
MTB_UPHILL = tuple(str(i) for i in range(6))
MTB_IMBA = tuple(str(i) for i in range(5))

PISTE_DIFFICULTY = ("novice", "easy", "intermediate", "advanced", "expert",
                    "freeride", "extreme")

SCHEMAS: tuple[Schema, ...] = (
    Schema("sac_scale", "hiking", "sac_scale", SAC,
           eligible_hiking_strict, eligible_hiking_broad,
           "highway=path", "path/track/bridleway/steps/trail-footway",
           "PRD FR14b's named hiking schema. Six-step Swiss Alpine Club grading."),
    Schema("trail_visibility", "hiking", "trail_visibility", VISIBILITY,
           eligible_hiking_strict, eligible_hiking_broad,
           "highway=path", "path/track/bridleway/steps/trail-footway",
           "FR14b's second hiking schema. Not a difficulty grade so much as a "
           "route-finding one — and the failure it describes (losing the trail) is "
           "the one a Character actually meets."),
    Schema("mtb:scale", "mtb", "mtb:scale", MTB_SCALE,
           eligible_mtb_strict, eligible_mtb_broad,
           "highway=path", "path/track/bridleway/cycleway",
           "Downhill/level technical difficulty, 0-6. The European scale."),
    Schema("mtb:scale:uphill", "mtb", "mtb:scale:uphill", MTB_UPHILL,
           eligible_mtb_strict, eligible_mtb_broad,
           "highway=path", "path/track/bridleway/cycleway",
           "Climbing difficulty, 0-5. Separate key because a trail can be trivial "
           "down and unrideable up."),
    Schema("mtb:scale:imba", "mtb", "mtb:scale:imba", MTB_IMBA,
           eligible_mtb_strict, eligible_mtb_broad,
           "highway=path", "path/track/bridleway/cycleway",
           "The North American scale (green circle -> double black), 0-4. The one "
           "schema in FR14b's list whose home market *is* North America, which makes "
           "it the single most informative measurement in this spike."),
    Schema("piste:difficulty", "nordic", "piste:difficulty", PISTE_DIFFICULTY,
           eligible_nordic, eligible_nordic,
           "piste:type=nordic", "piste:type=nordic",
           "Strict and broad are the same set: `piste:difficulty` is meaningless off "
           "a piste, so there is no honest wider denominator to report against."),
)

SCHEMAS_BY_KEY = {s.key: s for s in SCHEMAS}

#: Same-place, same-ways controls. Coverage of an *ordinary* attribute over the
#: identical denominator, so a low schema number can be read as "this schema is
#: unused here" rather than "these ways carry no tags at all". `surface` is the
#: direct comparator to SPIKE-03/A19; `name` measures whether anyone has curated
#: these ways in the first place.
CONTROL_TAGS = ("surface", "smoothness", "name", "incline", "width")


# --------------------------------------------------------------------- thresholds

@dataclass(frozen=True)
class Band:
    key: str
    floor_pct: float
    meaning: str


#: **Declared before the run**, SPIKE-21-style, so the verdict is not fitted to the
#: numbers that came back.
#:
#: The floors are not arbitrary. A19 already established the working precedent on
#: the same kind of question: `surface` at 81.7% (Boulder) produced usable cue-sheet
#: output, `surface` at 34.4% (Davis) produced *none at all* on any route, and 24.5%
#: (Viroqua) produced two across 132 km. The product's own experience is therefore
#: that something in the 30s is functionally silent and something in the 80s works.
#: 70 and 20 bracket that, with the middle band being the case FR14b actually has to
#: decide: enough data to show *somewhere*, never enough to summarise a leg.
BANDS: tuple[Band, ...] = (
    Band("read", 70.0,
         "Read it. Coverage is dense enough that a per-leg summary is more often "
         "right than absent, and the Author is not being shown a confident wrong "
         "number."),
    Band("opportunistic", 20.0,
         "Show it where it exists, never aggregate it. A grade on the way that "
         "carries it is always true; a grade on a leg assembled from mostly-untagged "
         "ways is a guess wearing a number."),
    Band("absent", 0.0,
         "Ask. FR14/B8's Author declaration is the only source, and the surface says "
         "so rather than showing an empty field."),
)

#: Below this many eligible ways a percentage is not a measurement, it is an anecdote.
#: This spike has several such cells — `mtb:scale` over the five signposted ways in the
#: White Mountains reads "100%" — and printing them as coverage would be the exact
#: dishonesty FR14b's own honesty clause is about. They are reported as `n/a`, with the
#: raw counts still shown so nothing is hidden.
MIN_ELIGIBLE = 30

#: The second half of the "read" test, and the one that decides between *silence*
#: and *wrong answers*. Measured by `degrade.py`: given that a grade is shown at
#: all, how often is it easier than the truth? Understatement is the asymmetric
#: failure — an overstated grade sends an Author to look, an understated one does
#: not.
MAX_UNDERSTATEMENT_PCT = 10.0


def band_for(pct: float, eligible: int | None = None) -> Band | None:
    """The band a coverage figure falls in, or `None` when the sample is too small
    to have one. `None` is deliberately not "absent": an unmeasurable cell and an
    empty one are different findings and must not print the same."""
    if eligible is not None and eligible < MIN_ELIGIBLE:
        return None
    for band in BANDS:
        if pct >= band.floor_pct:
            return band
    return BANDS[-1]


def rank(schema: Schema, value: str) -> int | None:
    """Ordinal position of a raw tag value, or None if it is not in the vocabulary.

    Real data carries `mtb:scale=2+`, `1-`, `S2`, and `sac_scale=T3`. These are not
    typos to be discarded — a way graded `2+` is graded — so the informal suffixes and
    the T-prefix are normalised rather than dropped, and anything still unrecognised
    is reported as `unparsed` instead of silently counted as untagged. A schema that
    is *used* but not machine-readable is a different finding from one that is unused.
    """
    v = value.strip().lower()
    if schema.tag.startswith("mtb:scale"):
        v = v.lstrip("s")
        v = v.rstrip("+-")
    elif schema.tag == "sac_scale" and v.startswith("t") and v[1:].isdigit():
        idx = int(v[1:]) - 1
        return idx if 0 <= idx < len(schema.values) else None
    try:
        return schema.values.index(v)
    except ValueError:
        return None
