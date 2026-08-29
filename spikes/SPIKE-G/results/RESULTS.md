# SPIKE-G results — Candidate & proposal rendering at bbox scale

**Recorded:** 2026-08-29 · **Issue:** [#161](https://github.com/gnfrazier/plotlines/issues/161)
**Covers:** PRD **FR99 / FR102 / FR105a / FR108 / FR120** · stories **N3** `[MVP]`, **N4a** `[P1]`, **O3** `[MVP]` · ARCH **Q15** ★, risk **A16**

---

## Verdict

**Salience-gated rendering, with a canvas-dot tail and a clustering backstop.**
Of the three strategies ARCH Q15 names, salience-gating is the one that keeps the
frame under budget, keeps selection instant, *and* satisfies FR99 / N4a intent —
because the information it gates on is free (the pipeline already computes it,
FR98) and it degrades in the product's own terms.

Concretely, for the curation workspace map:

1. **Render the top-K candidates in the viewport by salience as hit-testable
   widget markers**, where **K ≈ 300 on a GPU desktop** (`regions.cut_k`, from
   the SPIKE-14 warm-frame headroom minus a polygon/dot allowance). On the
   software-raster floor K collapses to ~0 — that is a documented floor, not the
   shipping target, exactly as SPIKE-14 framed its own Linux numbers.
2. **Render every other in-viewport candidate as a canvas dot** on one shared
   `CustomPainter` layer — positioned, sized/opacity'd by salience, *not* a
   widget and *not* individually hit-tested. Dots are ~50× cheaper per frame and
   ~180× cheaper in memory than a widget marker.
3. **Fall back to grid clustering only below the trip-overview zoom, or when the
   in-viewport candidate count exceeds ~2,800** (the measured-model GPU density
   ceiling). The shipped notability ruleset (SPIKE-A v1.2.0) never approaches
   this in a trip bbox — `sgv` is the worst at 1,208. The pre-calibration flood
   (`sgv` v1.1.0, 5,453) is over the ceiling, so clustering is the backstop
   against a ruleset regression, not a routine mode.

This is a **recommendation on a model calibrated to SPIKE-14's measurements**,
not a fresh measurement. The live run is specified in `HARNESS.md` and its
load-bearing coefficient (per-frame widget-marker cost) is flagged there as the
number to confirm. That is the same standing as SPIKE-13's verdict.

## Method

No product code. `plotlines-core` / `plotlines-service` untouched — same
discipline as SPIKE-A/C/D/H.

* **Densities are SPIKE-A's, not invented** (the issue's explicit instruction).
  `extract.py` joins SPIKE-A's post-calibration golden candidate sets to real
  coordinates and real polygon rings from its committed Overpass pulls. 0 of
  1,995 candidate ids across the three regions were unresolved.

  | region | place | km² | candidates (v1.2.0) | per 100 km² | area anchors | flood (v1.1.0) |
  |---|---|---:|---:|---:|---:|---:|
  | `avl` | Asheville & the French Broad, NC | 487 | 715 | 147 | 79 | 749 |
  | `lwr` | Lower Wisconsin Riverway, WI | 693 | 72 | 10 | 20 | 63 |
  | `sgv` | San Gabriel foothills, CA | 382 | **1,208** | **316** | 100 | **5,453** |

* **The cost model is pre-registered** (`regions.py`, declared before any result
  was read) and calibrated to SPIKE-14's published anchors: the 60 Hz budget
  (16.7 ms), the warm basemap frame it draws on top of (Linux p95 15.5 ms /
  Windows GPU p95 7.6 ms), the ~1 GB Windows client budget, and "route geometry
  is free" (the polyline is charged nothing). Marker / dot / polygon / hit-test
  coefficients each carry a `basis` string; the widget-marker per-frame cost is
  the one set from practitioner consensus rather than measurement, and
  `HARNESS.md` exists to replace it.

* **The sweep** (`analyze.py`): every `region × strategy × zoom {10,12,14,16} ×
  platform {linux-swraster, windows-gpu}`, priced in frame time, memory, and
  selection latency, classified against pre-registered bands. z10 ≈ the whole
  trip bbox (the overview "find the good spots" runs over); z14–16 ≈ placing an
  individual anchor.

## 1. Frame time — the naive layer is the problem SPIKE-14 didn't measure

Warm basemap frame + candidate layer, p95, at the trip-overview zoom (z10), GPU:

| strategy | `avl` (715) | `sgv` (1,208) | over 16.7 ms budget? |
|---|---:|---:|---|
| **naive** (every candidate a widget) | 22.9 ms | **33.5 ms** | **yes — RED** |
| zoom-threshold (blank < z13) | 7.6 ms | 7.6 ms | no, but nothing is drawn |
| cluster-grid | 7.9 ms | 7.9 ms | no |
| **salience-gated** (K≈300 + dots) | **14.9 ms** | **15.8 ms** | **no — 0.9 ms to spare** |

On the **software-raster floor** the naive layer is 50–75 ms/frame — a slideshow.
Salience-gated is 19–22 ms there (over budget, hence AMBER overall), driven not
by the ~0 widgets but by the **filled area anchors and the dot tail**: ~100
polygon anchors at bbox density cost more per frame on `llvmpipe` than 1,200
point markers would. On GPU that inverts and everything fits.

**Route geometry is free (SPIKE-14) and stays free — the polyline is one draw.
The candidate layer is the new cost, and only the naive form of it breaks the
budget.**

## 2. Selection latency — a function of the *live widget count*, not of density

The issue's own line: "a map that renders at 60 fps and takes 300 ms to answer a
tap is still unusable." Modelled, `map → list` latency is dominated not by
hit-testing but by the **`MarkerLayer` rebuild a naive `setState` triggers** —
every live widget marker re-laid-out once, on the tap:

| strategy | live widgets (`sgv` z10) | `map → list` incl. rebuild | usable (≤ 250 ms)? |
|---|---:|---:|---|
| naive | 1,207 | 55 ms | yes, but janky |
| salience-gated | 305 | 20 ms | yes, comfortably |
| cluster-grid | ~15 | 20 ms | yes — but the tap is *ambiguous* |

`list → map` (select a card → camera moves) is O(1) and **not density-sensitive**
in any strategy (~20 ms). Cluster-extent highlight is O(members) — trivial.
Selection is not where any strategy fails on latency; it *is* where cluster-grid
fails on **correctness** — a tap on a count glyph cannot resolve to one card, so
N4a's "select the cluster on the map → select its card" and FR99's "promote
directly from the map" don't hold without a zoom-in first.

## 3. The three strategies, judged on all of frame / selection / intent

| strategy | worst band | why |
|---|---|---|
| **zoom-threshold** | **RED** | Below the threshold the overview is **blank**. The one zoom where the Author most needs to see the field — running co-location analysis over the whole bbox — shows nothing. Hard fail on FR99/N3. |
| **naive** | **RED** | Frame blows the budget past ~800 candidates in view (both dense regions). Fine only in the sparse `lwr` (72). Not a strategy — it's the absence of one. |
| **cluster-grid** | **AMBER** | Fits the frame and selection budgets everywhere with room to spare, and gives a genuinely useful overview. But it **aggregates salience into a count** (FR99 wants salience *visible*) and makes a map tap ambiguous (N4a). Good as the zoomed-out affordance and the >ceiling backstop; wrong as the primary mode. |
| **salience-gated** | **AMBER** (GREEN in `lwr`) | Fits frame + selection on GPU at every zoom with headroom; keeps salience visible *by construction* (the widgets **are** the notable ones); supports promote-from-map and exact tap→card. AMBER only because the software-raster floor can't draw the polygon+dot tail in budget — SPIKE-14's documented floor, not the target. |

## 4. Areas (FR108) — first-class, and the surprise cost on the floor

Every region has real polygon anchors (`avl` 79, `lwr` 20, `sgv` 100 — parks,
nature reserves, historic districts). Reconstructed rings average ~7 vertices,
tail to ~300 (`sgv` — a wilderness boundary). Priced per vertex:

* **On GPU, negligible** — ~1–2 ms/frame for every area anchor in a dense bbox,
  tessellation is cheap.
* **On the software-raster floor, dominant** — the filled+stroked polygons are
  the single biggest contributor to salience-gated's over-budget frame there,
  ahead of the point markers. If a low-end integrated-GPU-less machine is ever in
  scope, area anchors need their own zoom-gate or a simplified-hull render.

Areas do not change the strategy choice; they raise the polygon/dot allowance
baked into K (`regions.CUT_K_CORESIDENT_ALLOWANCE_MS = 3 ms`).

## 5. A16 — re-measured with candidates on screen

SPIKE-14 said "budget the desktop client at ~1 GB on Windows with a basemap."
A16 asks for that re-taken with candidates displayed. Modelled:

| component | MB (Windows GPU working set) |
|---|---:|
| SPIKE-14 basemap client (route + vector basemap) | ~1,000 |
| salience-gated candidate layer at its density ceiling (305 widgets @ 9 KB + ~2,500 dots @ 0.05 KB + ~2,500 polygon verts @ 0.12 KB) | **~3** |
| tile-cache bounds + selection/animation transients (headroom) | ~150 |
| **A16 restated** | **~1,153 MB → budget ~1.15 GB** |

**The candidate layer is memory-cheap under the recommended strategy** — ~3 MB,
because a bounded widget count plus flat dot/vertex arrays is nothing next to the
tile cache. The naive layer at `sgv` density is ~11 MB (1,207 widgets), still
small — **memory is not where the naive layer hurts; frame time and rebuild
latency are.** A16's mitigation lever is unchanged: **tile-cache bounds**, not
candidate culling.

**Restated A16:** *Budget the curation workspace at ~1.15 GB working set on a
Windows GPU client — SPIKE-14's ~1 GB basemap client plus ~3 MB for the
salience-gated candidate layer at its ~2,800-candidate display ceiling plus
~150 MB tile/transient headroom. The candidate layer is not a material memory
cost under the recommended render strategy; the ~1 GB basemap figure remains the
number to re-measure on a release build. Re-measure with `HARNESS.md`.*

## Decides (closes Q15)

* **Rendering strategy for the curation workspace map: salience-gated widget
  markers (top-K by salience) + a canvas-dot tail for the rest + grid clustering
  as the sub-overview-zoom and over-ceiling backstop.** Not zoom-thresholding
  (blank overview), not clustering-as-primary (salience invisible, tap
  ambiguous), not naive (breaks the frame budget past ~800 in view).
* **Display-density ceiling: ~2,800 candidates in a single viewport** on a GPU
  desktop before the p95 interaction frame tips over 16.7 ms. The shipped
  notability ruleset stays well under this in a trip bbox (worst measured 1,208);
  the ceiling is the tripwire for a ruleset regression, and the point at which
  the clustering backstop must engage.
* **K (the salience cut) is derived, not chosen** — `regions.cut_k(platform)` =
  (warm-frame headroom − 3 ms polygon/dot allowance) ÷ per-marker frame cost.
  ~300 on GPU, ~0 on software raster.
* **A16 restated** as above: ~1.15 GB, candidate layer immaterial, tile cache
  still the lever.
* **Selection is safe on latency, not on correctness for clustering** — the
  naive `MarkerLayer` rebuild-on-select is the thing to avoid; keep the live
  widget count bounded (which salience-gating does) and `map → list` stays ~20 ms.
* **Area anchors (FR108) are first-class and cheap on GPU**; on a hypothetical
  GPU-less client they need their own gate. Not a blocker for MVP desktop.

## What did not clear

* **This is a calibrated model, not a measurement.** The per-frame widget-marker
  cost — the coefficient K and the naive verdict both pivot on — is set from
  practitioner consensus. `HARNESS.md` specifies the two-platform Flutter run
  that replaces it. Until then the *shape* of the answer (salience-gating wins,
  naive breaks, clustering degrades intent) is robust to a 2–3× error in that
  coefficient; the *exact* K and ceiling are not.
* **macOS** — untouched, as in SPIKE-14. Two platforms was the bar.
* **Proposals (N4a / FR105a) vs candidates.** The model treats a proposal
  overlay as ~6% of the candidate load (co-location collapses thousands of
  candidates into tens of proposals, then FR105a caps them). Candidates are the
  worst case and the one the recommendation is sized to; proposals ride for free
  under it. If N4a's proposal cards carry their own dense sub-geometry, that is a
  separate small measurement.

## Doc edits this spike owes (N3 / N4a carry them)

* **ARCH Q15** — mark resolved 2026-08-29 by SPIKE-G; record the strategy
  (salience-gated + dot tail + clustering backstop), the ~2,800 GPU density
  ceiling, and the derived-K rule.
* **ARCH A16** — replace the "should be re-measured with candidates displayed"
  note with the restated ~1.15 GB budget and "candidate layer is immaterial;
  tile-cache bounds remain the lever."
* **PRD §5.4a design note / FR99 / FR105a / FR108** — replace "the rendering
  strategy … is an open architectural question (ARCH Q15)" with "salience-gated
  (SPIKE-G): the notable candidates render as hit-testable markers, the rest as a
  salience-styled dot field, with clustering below the overview zoom."
* **PRD §12 (open architectural questions)** — strike the "Rendering candidates
  and proposals at bbox scale" bullet.
* **`Plotlines_Research_Spikes.md`** — add the SPIKE-G entry (there *was* no
  SPIKE-G; #161 proposes it) + summary-table row: resolved 2026-08-29 on a
  calibrated model, live harness specified.
* **`Plotlines_MVP_Redirection_Punchlist.md`** — §2A.5 (Q15) and the #161 row:
  resolved; carry the density ceiling and the A16 restatement.
