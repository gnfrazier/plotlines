# SPIKE-C — Non-whitewater difficulty-grading coverage

**Run:** 2026-08-28 · **Issue:** [#170](https://github.com/gnfrazier/plotlines/issues/170)
**Covers:** PRD **FR14b**, FR14 · story **B9** `[P1]` · ARCH §7.4 (`terrain_technicality`), **Q13**

---

## Verdict

**The generalisation was wrong, and so was reopening it in the form FR14b takes.**

v1.0 took SPIKE-04's whitewater verdict and applied it to all technical terrain untested.
FR14b was right to reject that — the schemas are not equivalent and one of them is
genuinely dense. But FR14b's own framing, *"where a source does publish difficulty
grading for a mode, Plotlines reads it"*, does not survive measurement either. Across
**57,422 ways and 12,735 km in seven regions**, exactly **one of FR14b's four named
schemas clears the threshold declared before the run, and it clears it everywhere:**

| schema | mode | best North American coverage | homeland (Tyrol) | band |
|---|---|---:|---:|---|
| **`piste:difficulty`** | nordic | **100%** (Methow), 86.4% (Whites) | 97.2% | **read** |
| `mtb:scale:imba` | MTB | 39.3% (Bentonville, `highway=path`) | 0.1% | opportunistic |
| `sac_scale` | hiking | 31.8% (Whites, curated) | 55.1% | opportunistic |
| `mtb:scale` | MTB | 5.7% (Bentonville, curated) | 29.5% | absent |
| `trail_visibility` | hiking | 6.5% (Methow, `highway=path`) | 20.1% | absent |
| `mtb:scale:uphill` | MTB | 3.8% (Bentonville, curated) | 7.4% | absent |

Every figure above is each schema's **best cell anywhere in the region set**, over the
most favourable of four denominators. The `broad` numbers — the denominator a routed leg
is actually made of — are lower again: `sac_scale` reaches **7.9%** in the White Mountains
and **0.05%** in Bentonville.

**Four findings, and the third is the one that decides FR14b.**

| # | | |
|---|---|---|
| 1 | **Nordic is real and reads cleanly.** `piste:difficulty` is 86–100% wherever a nordic piste exists at all, in North America as much as in Austria. | FR14b **ships** for nordic |
| 2 | **The other three schemas are absent in North America and thin even at home.** Not one clears 40% anywhere, including the Tyrol. `sac_scale` at 55% *curated* is the single best land number in the whole set. | FR14b **narrows** |
| 3 | **Thin coverage here does not produce silence. It produces confident understatement.** At the coverage rates actually measured in North America, **16–32% of the grades the app would show for a leg are wrong, and every one of them is wrong in the easy direction.** | The **[unknown-tag rule does not transfer](#3-silence-or-wrong-answers)** |
| 4 | **The schema map is regional, and the two MTB scales are mirror images.** `mtb:scale:imba` is 39.3% in Bentonville and **0.10%** in the Tyrol; `mtb:scale` is 29.5% in the Tyrol and 0.19% in Bentonville. A single-schema implementation is wrong on one continent by construction. | Read *both*, never merge them |

**ARCH Q13 closes.** `terrain_technicality` stays Author-declared (FR14/B8) for hiking and
MTB. It is not "unproven" any more — it is measured, and the measurement says the data is
not there.

---

## Substrate

Seven regions, three concentric controls, not a sample. Full reasoning in `regions.py`.

| region | kind | km² | ways | km | `route=hiking` ways | `route=mtb` ways |
|---|---|---:|---:|---:|---:|---:|
| boulder | fixture | 40 | 6,604 | 459 | 0 | 0 |
| davis | fixture | 27 | 4,543 | 318 | 0 | 0 |
| viroqua | fixture | 251 | 69 | 41 | 0 | 0 |
| whites | mode-popular (hiking) | 2,132 | 4,916 | 2,642 | 816 | 36 |
| bentonville | mode-popular (MTB) | 1,196 | 10,433 | 1,642 | 7 | 695 |
| methow | mode-popular (nordic) | 1,640 | 985 | 1,236 | 82 | 0 |
| tyrol | schema homeland | 1,262 | 29,872 | 6,397 | 13,770 | 2,427 |

The fixtures are `spikes/shared/regions.py` verbatim, so these numbers sit directly beside
SPIKE-03's surface coverage (81.7% / 34.4% / 24.5%) and SPIKE-21's cue results on the same
ground. The mode-popular three are each the strongest North American case for *their*
schema — not for their terrain. The Tyrol is where `sac_scale` and `mtb:scale` were
invented; without it a continent-wide zero would be unreadable, because it could mean the
tag is dead, and it is not.

**Viroqua is worth pausing on: 69 path-like ways in 251 km².** Genuinely gravel, genuinely
steep, and essentially unmapped for trail. Any schema question asked of Viroqua returns
`n/a` for want of a denominator, which is itself the answer for a large part of rural
North America.

---

## 1. Coverage, per schema, per region

% of eligible ways carrying the tag. `n/a` = fewer than 30 eligible ways, so the
percentage would be an anecdote rather than a measurement — the counts still print.
Bold marks each schema's best cell.

### `sac_scale` — hiking

| region | broad n | broad % | strict n | strict % | curated n | curated % | % km (broad) |
|---|---:|---:|---:|---:|---:|---:|---:|
| boulder | 2,771 | 0.29 | 975 | 0.82 | 0 | n/a | 3.26 |
| davis | 1,996 | 0.00 | 80 | 0.00 | 0 | n/a | 0.00 |
| viroqua | 41 | 0.00 | 20 | n/a | 0 | n/a | 0.00 |
| **whites** | 3,395 | 7.86 | 1,688 | 11.43 | 522 | **31.80** | 19.04 |
| bentonville | 1,963 | 0.05 | 522 | 0.19 | 6 | n/a | 0.49 |
| methow | 843 | 1.30 | 384 | 2.86 | 32 | 0.00 | 6.33 |
| *tyrol* | 24,738 | 17.04 | 8,069 | 36.88 | 2,165 | *55.06* | 35.92 |

Values in the Whites: `mountain_hiking` 170, `hiking` 87, `demanding_mountain_hiking` 6,
`alpine_hiking` 3. The schema is *used* there — 407 km of it — it is simply used on 8% of
the trail network. The Presidential Range is not ungraded because nobody has been up it.

### `trail_visibility` — hiking

| region | broad n | broad % | strict % | curated % |
|---|---:|---:|---:|---:|
| boulder | 2,771 | 0.25 | 0.41 | n/a |
| davis | 1,996 | 0.00 | 0.00 | n/a |
| viroqua | 41 | 2.44 | n/a | n/a |
| whites | 3,395 | 2.65 | 3.38 | 0.96 |
| bentonville | 1,963 | 0.05 | 0.19 | n/a |
| **methow** | 843 | 2.97 | **6.51** | n/a |
| *tyrol* | 24,738 | 6.85 | *20.08* | 14.78 |

The weakest schema in the set, and the one whose absence costs most: `trail_visibility=no`
describes the failure a Character actually meets — losing the trail — and it appears **3
times in 12,735 km** outside the Tyrol.

### `mtb:scale` / `:uphill` / `:imba` — mountain biking

Best cell per schema, all four denominators:

| schema | region | broad % | strict % | curated % | signposted % |
|---|---|---:|---:|---:|---:|
| `mtb:scale` | bentonville | 0.76 | 0.19 | **5.71** | n/a (9) |
| `mtb:scale` | *tyrol* | 4.50 | 4.13 | *29.48* | *24.35* |
| `mtb:scale:uphill` | bentonville | 0.50 | 0.19 | **3.75** | n/a (9) |
| `mtb:scale:uphill` | *tyrol* | 1.00 | 0.90 | *7.42* | *12.17* |
| `mtb:scale:imba` | bentonville | 8.75 | **39.27** | 36.96 | n/a (9) |
| `mtb:scale:imba` | *tyrol* | 0.05 | 0.10 | 0.00 | 1.74 |

**Finding 4 lives in this table.** Bentonville — 239 `route=mtb` relations, 695 curated
ways, a professionally built and signed network — uses `mtb:scale:imba` on 39.3% of its
singletrack and `mtb:scale` on 0.19%. The Tyrol does the exact opposite: `mtb:scale` on
29.5% of curated ways, `mtb:scale:imba` on 0.00%. These are not two measurements of one
schema's health; they are two regional schemas that happen to describe the same thing.
FR14b already lists both, which turns out to be right for a reason it did not state.

`mtb:scale:imba` at Bentonville, 39.3% over 522 `highway=path` ways, is **the strongest
North American land-difficulty result in this spike** — and it still lands in
`opportunistic`, not `read`.

### `piste:difficulty` — nordic

Strict and broad are the same denominator: the tag is meaningless off a piste.

| region | `piste:type=nordic` ways | per 1,000 km² | km | tagged % | % km | band |
|---|---:|---:|---:|---:|---:|---|
| boulder | 11 | 276 | 2.8 | n/a (100.0) | 100.00 | n/a |
| davis | 0 | 0 | 0.0 | — | — | — |
| viroqua | 0 | 0 | 0.0 | — | — | — |
| **whites** | 575 | 270 | 280.2 | **86.43** | 85.78 | **read** |
| bentonville | 0 | 0 | 0.0 | — | — | — |
| **methow** | 299 | 182 | 204.4 | **100.00** | 100.00 | **read** |
| *tyrol* | 507 | 402 | 202.4 | *97.24* | 96.25 | **read** |

**One honest caveat, stated because it cuts against the finding.** This denominator is
self-selecting — the same mapper writes `piste:type` and `piste:difficulty` in the same
edit — so a high percentage means much less here than it would for `sac_scale`. The number
that carries the weight is the one beside it: **the Methow's 299 pistes at 182 per
1,000 km² and the Whites' 575 at 270 are within a factor of 2.2 and 1.5 of the Tyrol's
density.** North American nordic is not a thin version of the European case; it is the
same case at the same order of magnitude. Read the two columns together or not at all.

---

## 2. The controls — why a zero here is readable

Coverage of *ordinary* attributes over the **identical** ways, in the same box. This is
what separates "the schema is unused here" from "these ways carry no tags at all", and it
is the difference between a fixable problem and a closed one.

| region | denominator | eligible | `surface` | `name` | `width` | the schema |
|---|---|---:|---:|---:|---:|---:|
| whites | hiking broad | 3,395 | 33.1 | 38.6 | 0.2 | `sac_scale` **7.9** |
| bentonville | MTB broad | 4,238 | 74.4 | 59.7 | 32.2 | `mtb:scale` **0.8** |
| methow | hiking broad | 843 | 39.3 | 52.3 | 0.7 | `sac_scale` **1.3** |
| boulder | MTB broad | 1,771 | 74.9 | 39.3 | 32.8 | `mtb:scale` **0.0** |
| tyrol | hiking broad | 24,738 | 51.3 | 7.8 | 5.4 | `sac_scale` **17.0** |

**Bentonville is the clincher.** On the same 4,238 ways, `surface` is at 74.4%, `name` at
59.7%, `width` at 32.2% — and `mtb:scale` at 0.76%. These ways are among the best-attributed
trail in the dataset. Nobody is waiting to get round to them. The schema is not used
because the community that built and mapped this network chose a different one
(`mtb:scale:imba`, 39.3%), and that choice is a regional fact, not a backlog.

Note also that the Tyrol has *lower* `name` coverage (7.8%) than the Whites (38.6%) while
carrying twice the `sac_scale`. Attribution richness and schema adoption are independent
axes. A "these regions are just less mapped" explanation does not survive the table.

---

## 3. Silence or wrong answers?

The issue asks the question that a coverage table cannot answer: *where coverage is thin,
does that produce silence (acceptable — SPIKE-21's unknown-tag rule) or wrong answers (not
acceptable)?*

**It produces wrong answers, and SPIKE-21's precedent does not transfer.** The reason is
structural, not incidental. Cue derivation is per-edge: an untagged edge emits no cue, and
the loss is bounded by that edge. A difficulty grade for a leg is **worst-of** its ways —
a leg with one T5 pitch is a T5 leg however gentle its other 20 km are — and a worst-of
taken over a sample is **biased low by construction**. Every error this mechanism can
produce is an error in the dangerous direction. Overstatement cannot occur at all.

**Method** (`degrade.py`): take the one region with a ground truth — the Tyrol — and
assemble real legs from it: **63 fully-graded named `sac_scale` trails, 418 ways,
187.1 km**, of which 20 carry more than one grade and are therefore *at risk* of being
misreported. Take each leg's true worst-of. Thin the tagging to a target rate `p` and take
it again. Three outcomes: **silent** (nothing survived — the app says "no published
grade"), **correct**, or **understated** (a harder way was dropped and the app shows a
confident easier number). Three thinning models bracket how *correlated* real gaps are —
`random` (independent per way), `block` (a contiguous run within the leg, ways ordered by
id as a proxy for editing session), `leg` (whole legs together; understatement is 0% here
**by construction**, since the cluster unit equals the aggregation unit, and it is reported
only so that zero is read as the artefact it is).

`sac_scale`, 63 Tyrolean legs, swept at the rates actually measured in North America:

| coverage `p` | model | silent % | correct % | understated % | **understated given a grade was shown** |
|---:|---|---:|---:|---:|---:|
| 0.9% (methow, hiking-broad ≈1.3%) | random | 91.4 | 6.9 | 1.7 | **19.8%** |
| 5% | random | 71.9 | 23.0 | 5.1 | **18.0%** |
| 5% | block | 87.3 | 8.7 | 4.0 | **31.6%** |
| **7.9%** (whites, broad) | random | 59.7 | 33.4 | 6.8 | **17.0%** |
| **7.9%** (whites, broad) | block | 66.7 | 27.9 | 5.5 | **16.4%** |
| 10% | block | 52.4 | 38.0 | 9.6 | **20.1%** |
| 25% | block | 0.0 | 86.4 | 13.6 | **13.6%** |
| **31.8%** (whites, curated — the NA best case) | — | — | — | — | **≈12%** |
| 50% | block | 0.0 | 93.6 | 6.4 | 6.4% |
| 75% | block | 0.0 | 97.2 | 2.8 | 2.8% |

**At every coverage rate North America actually has, between one in six and one in three
of the grades this feature would print are wrong, and all of them are too easy.** The mean
error is 1.1 steps of the SAC scale — the difference between "mountain hiking" and
"demanding mountain hiking", or between "alpine hiking" and a T5 that wants hands.

**The crossover is independent corroboration of the declared band.** Interpolating for
where understatement-given-shown falls below the 10% ceiling declared before the run:

| schema | random | block |
|---|---:|---:|
| `sac_scale` | 37.5% | 37.5% |
| `mtb:scale` | 1.0% † | 31.7% |
| `piste:difficulty` | 56.5% | 64.0% |

† artefact of a 10-leg sample; the curve is non-monotonic at that size and the number
should not be used. `piste:difficulty` runs on only 4 legs and is reported for symmetry,
not for weight.

So the harm-derived floor for hiking and MTB is **≈32–38% coverage**, reached from the
damage rather than from A19's precedent, and the pre-declared `read` floor of 70% sits
comfortably above it. **The two methods agree, and nothing in North America comes near
either.** That agreement is a result; a disagreement would have been a more interesting
one and is the reason both were computed.

**The rule that falls out, and it is not "don't ship it".** Understatement is a property
of *aggregation*, never of display. A grade printed on the way that carries it is true by
definition. Everything above is an argument against summarising a leg, and no argument at
all against showing what the map says where it says it.

---

## 4. The honesty clause, as a payload

FR14b and B9 both require that source and coverage be *"stated honestly rather than
presenting sparse data as complete"*, and the issue asks for the figures "in a form the UI
can actually surface beside the grade" — A19's precedent, where the answer to thin
`surface` tagging was to show coverage beside the cue sheet.

`coverage.CoverageNote` is that form, and it is deliberately not a percentage in a
tooltip. It carries three states, and the sparse case is *structurally* unable to render
as the complete one — in the silent state `worst` is `None`, so there is no number to
print even by accident. Real output, from real legs:

```
graded    Carter-Moriah Trail (whites)
          "sac_scale published for every way on this leg (7 ways, 16.3 km), OpenStreetMap."

partial   Davis Path (whites)
          "mountain_hiking is the hardest grade among 3 of 7 graded ways (9.6 of 20.5 km,
           OpenStreetMap). 4 ways are ungraded — this is a floor, not a summary."

silent    Presidential Rail Trail (whites)
          "No published sac_scale for this leg. 34 ways, 31.0 km, none graded — the grade
           is the Author's to declare, not the map's to supply."
```

The `partial` wording — *"a floor, not a summary"* — is doing the work §3 measured the
need for. `Davis Path` is a real 20.5 km trail where 4 of 7 ways are ungraded; the number
shown is `mountain_hiking`, and §3 says there is roughly a one-in-six chance the truth is
harder. The claim string is written about the **evidence**, never about the terrain, so
the sentence stays true whichever way that lands.

**Two values-level findings that the payload has to survive**, both from real data:

- **The vocabularies are not closed.** `sac_scale=strolling` (38 ways, Tyrol) and
  `=undefined` (Whites); `trail_visibility=very_bad` and `=poor` (Whites);
  `mtb:scale:imba=2.5` and
  `3.5` (Boulder, 4 ways). These are reported as `unparsed` rather than counted as
  untagged, because a schema that is *used but not machine-readable* is a different
  finding from one that is unused — and an implementation that silently drops them
  understates coverage and, worse, drops a grade an Author can see on the map.
- **`piste:difficulty`'s published vocabulary includes `freeride` and `extreme`**, which
  are not ordinal continuations of `novice…expert` — a worst-of over the raw vocabulary
  would sort a freeride descent below an expert piste. **Neither value occurs anywhere in
  this sample**; all 1,300 graded pistes across four regions are `novice`/`easy`/
  `intermediate`/`advanced`. So this is a hazard read off the schema definition, not a
  measurement — but nordic is the one schema that ships a real aggregate, and it is the
  one place an off-scale value would silently produce a wrong ordering.

---

## What this decides

**ARCH Q13 — closed.** Non-whitewater difficulty coverage is measured. `sac_scale`,
`trail_visibility`, `mtb:scale` and `mtb:scale:uphill` do not support a read-first
capability anywhere, including their homeland. `mtb:scale:imba` supports one only in
purpose-built North American trail networks. `piste:difficulty` supports one everywhere a
nordic piste exists.

**ARCH §7.4 — `terrain_technicality` is no longer "unproven".** It is measured, and it
stays Author-declared. The paragraph should say so rather than continuing to point at an
unrun spike.

**FR14b — narrows to three clauses, from one.**

1. **Nordic reads.** `piste:difficulty` is read from source, per way and aggregated, with
   `freeride`/`extreme` handled as off-scale rather than as ordinal extremes.
2. **Hiking and MTB read opportunistically and never aggregate.** Where a way carries
   `sac_scale`, `trail_visibility`, `mtb:scale`, `mtb:scale:uphill` or `mtb:scale:imba`,
   show it on that way, attributed. Do **not** roll it up into a leg or day grade — §3
   measures that as a 16–32% chance of a confident understatement at real coverage rates.
   Both MTB scales are read; neither is converted into the other.
3. **Author declaration (FR14/B8) is the source for leg-level difficulty on land**, not a
   fallback for when the read fails. That is the inversion this spike produces: FR14b's
   *"reads it rather than requiring Author declaration"* has the primary and the fallback
   the wrong way round for hiking and MTB.

**B9's AC — narrowed to the schemas that clear it**, per the issue's own "done when".
"Coverage measured per region before shipping" is satisfied by this document, and the
per-region figures are in `coverage.json` in the shape the UI consumes.

**One thing this spike did not test.** All measurement is against OSM. FR14b says *"where
a source does publish"*, and a plugin layer (a land manager's own trail inventory, an
IMBA-affiliated trail org's feed) could publish grading at coverage OSM does not have —
SPIKE-H already showed real NPS data merging cleanly through `LayerProvider`. Nothing here
argues against that path; it argues that **OSM is not that source** for hiking and MTB.
The `CoverageNote.source` field exists for exactly that reason.

---

## Reproducing

```bash
.venv/bin/python spikes/SPIKE-C/analyze.py    # coverage.json + the tables above
.venv/bin/python spikes/SPIKE-C/degrade.py    # degrade.json (seed 20260828, 400 trials/leg)
```

Both are offline against the committed records in `raw/` (57,422 ways, ~1.0 MB gz). No
product code was changed.
