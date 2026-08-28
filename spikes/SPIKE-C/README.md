# SPIKE-C — Non-whitewater difficulty-grading coverage

**Issue:** [#170](https://github.com/gnfrazier/plotlines/issues/170) ·
**Covers:** PRD **FR14b**, FR14 · story **B9** `[P1]` · ARCH §7.4 (`terrain_technicality`), **Q13**
**Result:** [`results/RESULTS.md`](results/RESULTS.md)

```bash
.venv/bin/python spikes/SPIKE-C/probe.py       # fetch (network; ~12 min, cached after)
.venv/bin/python spikes/SPIKE-C/analyze.py     # the coverage table   -> results/coverage.json
.venv/bin/python spikes/SPIKE-C/degrade.py     # silence vs wrong answers -> results/degrade.json
```

`analyze.py` and `degrade.py` are offline. Everything they need is committed under
`raw/`, so every published number reproduces without touching the Overpass commons
(ARCH §14 P7) and without moving under the next reader.

## Why this spike exists

SPIKE-04 tested **`whitewater:section_grade` specifically** and found it effectively
absent in North America. That verdict is correct and stands. v1.0 then generalised it to
*all* technical terrain without testing it, and ARCH §7.4 says so out loud —
*"`terrain_technicality` remains unproven, not proven"*. This spike measures the schemas
that generalisation was applied to and never covered: `sac_scale`, `trail_visibility`,
`mtb:scale`/`:uphill`/`:imba`, `piste:difficulty`.

## Design

Three things were fixed before any query was issued, because each one is a place where a
coverage spike can quietly produce whatever answer it wants.

**1. The denominators.** "Is `sac_scale` coverage 3% or 40%?" has no answer until someone
says what it is a percentage *of*, and almost any conclusion is reachable by drafting that
set to taste. `schemas.py` defines four, and every figure is reported against all of them,
widest to narrowest — so the reader watches the number fail to improve as each concession
is made rather than being handed the one that suits:

| scope | denominator | why it is here |
|---|---|---|
| `broad` | path / track / bridleway / steps / non-sidewalk footway | what a routed leg is actually made of — the denominator the *product* faces |
| `strict` | `highway=path` | the way type the schema's own wiki page is written about |
| `curated` | member of a `route=hiking` / `route=mtb` relation | someone assembled this into a signed itinerary on purpose |
| `signposted` | carries any `mtb=`/`mtb:*` tag (MTB only) | a mountain-bike mapper has personally edited this way |

The last two are the best case FR14b can possibly have. A schema thin on ways a community
has hand-curated is not thin for want of time.

**2. The regions.** The issue asks for the shared fixtures plus *"at least one region where
the mode is genuinely popular, since coverage of a niche schema is a function of local
mapper community more than of terrain."* That sentence is the experiment. A schema absent
from Boulder could mean the schema is dead or that Boulder does not use it, and only the
second keeps FR14b alive. So: the three fixtures, one mode-popular North American region
per mode (`whites` / `bentonville` / `methow`), and one **schema homeland** — the Tyrol,
where `sac_scale` and `mtb:scale` were invented and where nordic pistes sit in the same
valley. Without the homeland a continent-wide zero is unreadable. See `regions.py`.

**3. The threshold.** SPIKE-21 declared its 4.0 cues/km legibility ceiling before the run
and its first implementation *failed* it, which is the only reason that number meant
anything. `schemas.BANDS` is the equivalent: **≥70% read it, 20–70% show it where it
exists but never aggregate, <20% ask.** The floors come from A19's precedent on the same
kind of question — `surface` at 81.7% produced usable cue sheets, at 34.4% produced none
at all — and `degrade.py` then derives the same floor independently from *harm* rather
than precedent. Anything under 30 eligible ways is reported `n/a`, not `absent`: an
unmeasurable cell and an empty one are different findings.

## Files

| file | what it is |
|---|---|
| `regions.py` | The seven regions, their bboxes, tiling, and why each one is in the set |
| `schemas.py` | Denominators, schema vocabularies, value normalisation, and the pre-declared bands |
| `probe.py` | One tiled `out geom` union per region + the relation census + curated membership |
| `cache.py` | Gzipped cache. **Distilled records, not raw responses** — see the module docstring |
| `coverage.py` | The measurement, and `CoverageNote` — the honesty payload B9 would render |
| `analyze.py` | The coverage table, the same-place controls, sample notes → `results/coverage.json` |
| `degrade.py` | The thinning experiment: does thin coverage go silent or go wrong? → `results/degrade.json` |
| `raw/` | Committed per-way records: `{id, length_m, tags}`, ~0.8 MB gz for 57,422 ways |

**Geometry is fetched and thrown away.** It exists only to turn each way into a length, so
coverage can be reported by kilometre as well as by way count — a schema tagged on the
400 m nobody walks and missing from the 40 km spine is not 50% covered in any sense an
Author cares about. Committing the raw responses would have been ~40 MB of geometry
serving one `Geod` call.

## No product code changed

Same discipline as SPIKE-D and SPIKE-H: `coverage.py` is a spike-local prototype of the
payload B9 would ship, not an edit to `plotlines-core`. What the spike decides is written
up in `results/RESULTS.md` and reconciled into the PRD/ARCH by whichever story owns it.
