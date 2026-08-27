# SPIKE-A — Notability ruleset calibration

**Issue:** #158 · **Covers:** FR98, FR97, FR100; story N3 → N4/N4a; ARCH §4.3, Q11, risk A20
**Run:** 2026-08-27 · **Regions:** three trip-sized bboxes — `avl` / `lwr` / `sgv` (see `regions.py`)

---

## TL;DR

- The pre-spike ruleset (`RULESET_VERSION 1.1.0`) produced **5,453 candidates in a 382 km² San Gabriel trip bbox — one every 0.07 km²**, and **4,149 of them were street trees**. Unreviewable. The `natural=tree` gate checked that `denotation` was *present*, not what it *said*, and 3,988 LA street trees carry `denotation=avenue`.
- Two findings changed **code, not just values**:
  1. **`Qualification.requires_value`** — a bare-presence gate is not a gate. `natural=tree` now requires `denotation ∈ {natural_monument, landmark, memorial, historic}`.
  2. **`natural=peak` cannot be gated by any single attribute** in mountain terrain — every knoll in the Blue Ridge is named and carries `ele`. Fixed by cutting its base weight 0.8 → 0.55 until SPIKE-B can scale it by prominence + corridor proximity.
- `historic=*` sub-weights were **extended from the values that actually appear** (`historic=district` 0.9 was scoring 0.2; `historic=yes` 0.05 was scoring 0.2). `man_made=bridge` gated (name ≠ notability — 66 of 68 named San Gabriel bridges are named after the road they carry). Added `leisure=nature_reserve` and `amenity=place_of_worship` (both in `osm_reference.md` as strong fits, neither was in the taxonomy).
- After calibration: **`sgv` 5,453 → 1,208, `avl` 749 → 715, `lwr` 63 → 72.** `natural=tree` candidates: 4,149 → **0** in all three regions, which is the correct answer.
- **Recommendation: one default ruleset, no regional dimension.** The gates and thresholds hold in all three regions unchanged. What varies 10–30× by region is candidate *volume*, and that is a ranking / corridor-proximity problem (Q15, SPIKE-B), not a ruleset one.
- **ARCH Q11 can be closed.** ARCH Q16 was closed separately (#177) and was a prerequisite — provision salience could not be calibrated until the utility amenities existed.

---

## Method

For each region, one Overpass `out center tags` pull per FR97 layer family
(`historic`, `tourism`, `amenity`, `natural`, `leisure`, `man_made`), plus a
`leisure` geometry pull for the `leisure=park` area gate. Raw pulls are cached
gzipped under `raw/` and committed, so `analyze.py` reproduces every number
offline. The analysis runs `plotlines_core.curation.score_notability` **exactly
as the product would** — no spike-local scoring.

Bboxes are trip-sized on purpose (~25–30 km/side, a plausible FR120 authoring
extent). A state-sized box would answer a question the product never asks.

| region | place | km² | character |
|---|---|---:|---|
| `avl` | Asheville & the French Broad, NC | 487 | dense, varied: historic downtown, Biltmore, river mill districts, Blue Ridge overlooks, thick brewery/café layer |
| `lwr` | Lower Wisconsin Riverway (Spring Green–Sauk City) | 693 | rural flatwater trail, small towns, state land, Taliesin / House on the Rock |
| `sgv` | San Gabriel foothills (Pasadena–Sierra Madre), CA | 382 | dry built-up foothill zone: Old Pasadena historic core, mountain trailheads, street trees and pocket parks everywhere |

---

## What the shipped ruleset did (v1.1.0, before this spike)

| region | raw features | → candidates | per 100 km² | worst single type |
|---|---:|---:|---:|---|
| `avl` | 5,574 | **749** | 154 | `amenity=restaurant` 289 |
| `lwr` | 1,019 | **63** | 9 | `amenity=shelter` 14 |
| `sgv` | 16,860 | **5,453** | 1,426 | **`natural=tree` 4,149** |

`sgv` is the failure. Risk A20 said over-filtering hides the castle and
under-filtering floods the map; this is the flood, and its cause is precise:

```
natural=tree  qualification = requires_any=("denotation",)     # "has a denotation tag"
sgv denotation values:  avenue 3,988 · <none> 3,819 · park 99 · urban 56 · garden 3 · citrus 1
```

`denotation=avenue` means *a row of trees along a street* — the definitional
opposite of a natural monument. The gate passed all 4,149 tagged trees.

---

## Calibration

### Structural (code)

| change | why | file |
|---|---|---|
| **`Qualification.requires_value: Mapping[str, tuple[str,...]]`** | a gate must be able to check a value, not just presence | `taxonomy.py` |
| `natural=tree` → `requires_value={"denotation": ("natural_monument","landmark","memorial","historic")}` | the only denotation values that mean "notable" | `taxonomy.py` |
| `natural=peak` base weight **0.8 → 0.55** | 61 named, `ele`-tagged knolls in the French Broad valley; no attribute separates a Blue Ridge bump from a summit. Lower weight keeps them from dominating rank until SPIKE-B has prominence + corridor context | `taxonomy.py` |

### Values

| type | before | after | measured basis |
|---|---|---|---|
| `historic=*` sub-weights | 10 values | **+12 values**: `district` 0.9, `citywalls` 0.85, `aqueduct` 0.7, `railway_station`/`train_station` 0.6, `tomb` 0.55, `aircraft`/`locomotive`/`ship` 0.5, `building`/`house` 0.35, `yes` 0.05 | `historic=district` (Pasadena Civic Center District) and `historic=building` were the most common wildcard values seen and both scored 0.2 (uncataloged floor); `historic=yes` is pure noise and also scored 0.2 |
| `man_made=bridge` | ungated, 0.3 | gated `requires_any=("heritage","wikidata","wikipedia")` | 141 in `sgv`, 30 in `avl`; **0 of the `avl` ones named**, and 66 of 68 named `sgv` ones named after the carried road ("Gould Avenue", "I 210"). Only a heritage/wiki signal finds the Colorado Street Bridge |
| `leisure=nature_reserve` | **absent** | added, narrative, 0.7, ungated | 11 in `lwr`, 34 in `sgv`; low-density, effectively always notable; `osm_reference.md` calls it a strong fit |
| `amenity=place_of_worship` | **absent** | added, narrative (sight layer), 0.45, gated `requires_any=("heritage","wikidata","wikipedia")` | 165 in `avl` raw — too many ungated; the heritage/wiki subset is 5 (`avl`) / 7 (`sgv`), which is the architecturally-recognised set |

Full calibrated ruleset in config form: **`results/notability_ruleset.v1.2.0.json`**
(27 rules, regenerable via `export_ruleset.py`).

---

## Results after calibration (v1.2.0)

| region | → candidates | per 100 km² | narrative | provision | `natural=tree` |
|---|---:|---:|---:|---:|---:|
| `avl` | **715** (was 749) | 147 | 194 | 521 | 0 (was 13) |
| `lwr` | **72** (was 63) | 10 | 37 | 35 | 0 |
| `sgv` | **1,208** (was 5,453) | 316 | **321** | 887 | **0** (was 4,149) |

The golden sets (`results/golden/{avl,lwr,sgv}.json`) are the full sorted
candidate lists. Spot-check of `sgv`'s top: *Pasadena Civic Center District*
(0.9), then a run of mountain viewpoints and `historic=ruins` (Switzer Camp, a
real CCC-era site), then *Monrovia Canyon Park* (`nature_reserve`). The ruleset
now surfaces the right things first.

### What a human would have wanted kept, that was dropped
Nothing found. The denotation-value gate drops only street/garden trees; every
region had **zero** `denotation=natural_monument` trees, so there was no notable
tree to lose. `man_made=bridge` gating drops road overpasses and keeps
heritage-listed spans.

### What noise survived
- **`natural=peak`** — 61 in `avl`. Lowered weight, not eliminated. A named
  peak near a route is a legitimate waypoint; the fix is corridor-aware
  ranking (SPIKE-B), not a Stage-1 gate.
- **`leisure=park`** — 74 in `avl`, 65 in `sgv`. The name-or-area gate passes
  named pocket parks ("Pack Square", "Pritchard Park") — which are real civic
  places, so this is arguably correct. If SPIKE-B finds them noisy near
  corridors, raise `min_area_m2` to ~40,000.
- **`man_made=tower`** — 42 in `sgv` (name-gated). Borderline; left as is.

---

## Are the correct values regional?

**No — one default ruleset, no regional dimension.** Every gate and threshold
in v1.2.0 produces sensible output in all three regions without a regional
branch. The punch-list expected regional values; the measurement does not
support adding that complexity.

What *is* strongly regional is **candidate volume** — `sgv` carries 30× the
`avl` per-km² count of some types — but that is a map-rendering and
proposal-ranking concern (ARCH Q15 / SPIKE-B), not a notability-rule concern.
The one type with a regional density signal, `natural=peak` (61 `avl` / 7
`lwr`), is handled by the weight cut plus deferred prominence scaling rather
than a regional rule.

---

## Provisions are not the reviewable surface

Provision-affinity candidates dominate raw volume (`avl` 521, `sgv` 887 — mostly
`restaurant` / `fast_food` / `cafe`, the FR104 / Q16 additions). This is **by
design and not a calibration failure**: a nameless drinking fountain is still a
valid provision, so a qualification gate is the wrong tool. Provisions become
reviewable through FR104 co-location clustering and corridor-proximity filtering
(SPIKE-B / Stage 3), not through Stage-1 notability. The Q16 rows stand
unchanged.

---

## The unmatched tail (rules we deliberately do *not* have)

Top unmatched types across the three regions: `amenity=parking`,
`leisure=swimming_pool`, `leisure=pitch`, `amenity=bench`, `amenity=waste_basket`,
`man_made=utility_pole`, `man_made=surveillance`, `natural=wood`,
`amenity=bicycle_parking`, `tourism=hotel` (FR14's domain), `tourism=information`.
These omissions are all **correct** — none is a sight or a provision-cluster
input.

Two genuine gaps were found and filled (`nature_reserve`, `place_of_worship`).
One judgment call is **left open**: `natural=water` (238 `avl`, 132 `lwr`) — a
named lake is notable, a retention pond is not, and `water=*` sub-typing plus a
name/area gate is the likely shape. Non-blocking; noted for a later pass.

---

## Deliverables

| artifact | what |
|---|---|
| `core/plotlines_core/curation/taxonomy.py` | calibrated ruleset; `Qualification.requires_value` added |
| `core/plotlines_core/curation/notability.py` | `RULESET_VERSION` `1.1.0` → **`1.2.0`** |
| `results/notability_ruleset.v1.2.0.json` | the ruleset in versioned-config form (ARCH §4.3), regenerable via `export_ruleset.py` |
| `results/golden/{avl,lwr,sgv}.json` | per-region golden candidate sets (regenerable via `analyze.py --write-golden`) |
| `core/tests/fixtures/golden_candidates/` | compact hand-curated golden set + `regen.py`, covering every calibration case |
| `core/tests/test_curation_golden.py` | the golden-route test for the curation tier (ARCH §15.1) |
| `raw/*.json.gz` | the committed Overpass pulls |

---

## Limits / caveats

- **Three bboxes, not a survey.** They span the product's named regions and the
  density axes that matter, but a fourth region could surface a value the
  `historic=*` table still misses.
- **The `historic` sample is thin** — ~130 historic features across all three
  regions combined. The sub-weights are a notability *judgment* informed by
  *which* values appear, not a frequency fit. They are versioned config
  precisely so a later region can adjust them without a release.
- **Areas are approximate** — computed from `out geom` polygon vertices with a
  geodesic area, good to a few percent, which is well inside the 20,000 m²
  `leisure=park` threshold's tolerance.
- **Salience values are still seeds.** This spike fixed the gates (the A20
  failure mode) and the gross mis-weights (`peak` 0.8, `district` 0.2). The
  fine ordering among mid-band narrative types is a SPIKE-B tuning question
  against ranked proposals, not a Stage-1 one.

---

## Residual open items (none blocking Leg 2.5)

1. **SPIKE-B** — proposal ranking + corridor proximity. Owns `natural=peak`
   prominence scaling and whether `leisure=park` needs a tighter area gate.
2. **`natural=water` rule** — a later mapping pass, same shape as Q16.
3. **Move the ruleset to a config-file loader** in `core` (read
   `notability_ruleset.v*.json` at import instead of the literal tuple). Small,
   recommended, not done here — the values are proven to serialize losslessly
   (`export_ruleset.py`), which was the architectural question.
