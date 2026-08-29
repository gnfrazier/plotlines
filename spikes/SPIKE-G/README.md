# SPIKE-G — Candidate & proposal rendering at bbox scale

**Issue:** [#161](https://github.com/gnfrazier/plotlines/issues/161) ·
**Covers:** PRD **FR99 / FR102 / FR105a / FR108 / FR120** · stories **N3** `[MVP]`, **N4a** `[P1]`, **O3** `[MVP]` · ARCH **Q15** ★, risk **A16** ·
**Run before:** the curation workspace UI (N3) ·
**Result:** [`results/RESULTS.md`](results/RESULTS.md)

```bash
# offline — the CI-safe self-check. Re-derives every published figure from
# SPIKE-A's committed extracts and the pre-registered coefficients, and asserts
# the verdict still reproduces.
python spikes/SPIKE-G/run.py --dry-run

# offline — the full sweep (region x strategy x zoom x platform) -> JSON
python spikes/SPIKE-G/analyze.py results/render_budget.json

# tests
core/.venv/bin/python -m pytest spikes/SPIKE-G/tests -q
```

## Why this spike exists

ARCH **Q15** ★ was starred and open with no spike behind it — every other
starred v2.0 question got a letter, this one got a task ("re-measure A16 with
candidates on screen"). Risk **A16** asks the same thing from the other side.
**SPIKE-14 measured the basemap and the route and found the route free and the
basemap ~1 GB — but it measured no markers.** A dense trip bbox draws *thousands*
of independently-positioned, hit-testable candidate markers with salience encoded
in size/weight/opacity, plus filled polygon area anchors (FR108). That is a
different problem and it is on every Author screen.

## The two halves

**The bar (`bands.py`) and the model (`costmodel.py` + coefficients in
`regions.py`) are pre-registered** — declared before any number is read, the
discipline SPIKE-13 used for its delivery bands and SPIKE-21 for its cues/km
ceiling. The densities are **not invented** — they are SPIKE-A's real
post-calibration candidate sets in three trip-sized bboxes (`avl` / `lwr` /
`sgv`), reconstructed to real coordinates and real polygon rings from SPIKE-A's
committed Overpass pulls (`extract.py`; verified 0 unresolved ids).

**The live measurement is not run here.** It needs the SPIKE-14 `flutter_map`
harness driven on two desktop GPUs; this environment is software-raster only
(WSLg, `llvmpipe`). SPIKE-13 took exactly this route — pre-registered bands plus
a ready spec — when its live half needed infrastructure that did not exist yet.
[`HARNESS.md`](HARNESS.md) specifies the run that upgrades the estimates to
numbers, as a delta against SPIKE-14 so the marker cost is attributable.

## Files

| file | what it is |
|---|---|
| `regions.py` | **Pre-registered** — SPIKE-14 measured anchors, SPIKE-A region facts, and every cost coefficient with its basis. Change these only with a written reason. |
| `geo.py` | Web-Mercator viewport math — how many candidates land in a 1280×720 window at zoom *z*. |
| `extract.py` | Joins SPIKE-A's golden candidate sets to real coordinates + polygon rings from its committed `raw/` pulls. Read-only, offline. |
| `strategies.py` | The four Q15 strategies (`naive`, `zoom_threshold`, `cluster_grid`, `salience_gated`) reduced to a `RenderPlan` — primitive counts + interaction properties. |
| `costmodel.py` | Prices a `RenderPlan` in frame time, memory, and selection latency against SPIKE-14's numbers. |
| `bands.py` | Pre-registered GREEN / AMBER / RED bands and the re-stated A16 budget. |
| `analyze.py` | The sweep → `results/render_budget.json` + the recommendation. |
| `run.py` | `--dry-run` self-check gate. |
| `HARNESS.md` | The live re-measurement spec (extends the SPIKE-14 harness). |
| `results/RESULTS.md` | The verdict and what it decides. |
| `results/render_budget.json` | `analyze.py` output. |
| `tests/` | `pytest` over the geometry, the strategies, the cost model, the bands, and the analysis. |

## No product code changed

Same discipline as SPIKE-A / SPIKE-C / SPIKE-D / SPIKE-H: nothing here edits
`plotlines-core` or `plotlines-service`. What the spike decides is written up in
`results/RESULTS.md` and reconciled into PRD/ARCH by the story that owns Q15 (N3
/ N4a).
