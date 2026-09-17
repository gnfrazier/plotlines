# Issue #276 (Phase 3.4) — re-validating the osmnx-calibrated goldens against the extract-built path

**Issue:** [#276](https://github.com/gnfrazier/plotlines/issues/276) ·
**Epic:** [#272](https://github.com/gnfrazier/plotlines/issues/272) — OSM acquisition Phase 3 ·
**Gated on:** [#265](https://github.com/gnfrazier/plotlines/issues/265) (SPIKE-I) ·
**Depends on:** [#275](https://github.com/gnfrazier/plotlines/issues/275) — the local-clip candidate
and graph paths this issue re-validates against ·
**Script:** [`../revalidate_clip_candidates.py`](../revalidate_clip_candidates.py) ·
**Numbers:** [`revalidation_276.json`](revalidation_276.json)

---

## Verdict: no-op on all four calibrations — the candidate transport is exact, and the graph transport already was

§11.1 named four things calibrated on osmnx output: SPIKE-A's golden candidate
sets, SPIKE-G's density model and ~2,800 marker ceiling, the scoring weights,
and SPIKE-21's cue derivation. SPIKE-I (#265) measured the **graph**
transport (`graph/pbf_source.py`'s path T) and found it bit-identical to a
live-Overpass golden on every band, but said explicitly that #276 still
needed to run against the **candidate** path — a different mechanism
(`curation/providers.py::OsmLayerProvider._fetch_from_local_clip`, added by
#275) that SPIKE-I never touched.

This issue closes that gap:

| Calibration | Re-run how | Result |
|---|---|---|
| **SPIKE-A golden candidate sets** | Fresh measurement — live Overpass and the #275 local-clip path, from the *same* fetched bytes, scored by today's production `score_notability` | **Exact** — 0 added / 0 dropped / 0 changed, all three regions (§1) |
| **SPIKE-G density model / ~2,800 ceiling / A16 ~1.15 GB** | Restated, not re-run | **Confirmed unchanged** (§2) |
| **Scoring weights** (`scoring/profile.py`) | Restated, not re-run | **Confirmed unchanged** (§3) |
| **Cue derivation (SPIKE-21)** | Restated, not re-run | **Confirmed unchanged** (§3) |

The golden `results/golden/*.json` sets *do* show drift when compared
straight — but it is pre-existing ruleset drift, unrelated to the transport,
and it is filed rather than silently absorbed here (§1.3, #428).

---

## 1. SPIKE-A golden candidate sets — measured

### 1.1 Why a straight diff against `results/golden/` would have been the wrong measurement

SPIKE-A's golden sets are pinned at `RULESET_VERSION 1.2.0`. Current
`plotlines_core.curation.notability.RULESET_VERSION` is **1.3.0** (#43,
story C7 — lodging/campground types), and the live OSM data in these three
regions has moved in the two years-equivalent since SPIKE-A's `raw/` pulls
were captured. A raw diff against golden conflates three causes: transport,
ruleset version, and OSM churn. That conflation is exactly the "close
enough" failure addendum **G5** named for #265, and it is not a mistake to
repeat here.

So `revalidate_clip_candidates.py` fetches each region's Overpass response
**once** and builds candidates two ways from the identical bytes:

- **path O** — `OsmLayerProvider._features_from_gdf` over the same
  `_create_gdf(response_jsons, polygon, tags)` osmnx's own
  `features_from_bbox` runs. The pre-#275 live branch, today's taxonomy.
- **path T** — the same elements, written to a synthetic `.osm.pbf`
  (`osmium.osm.mutable.Node/Way/Relation` + `SimpleWriter` — the exact
  technique `core/tests/test_graph_pbf_source.py` uses for its fixtures) and
  read back through `OsmLayerProvider._fetch_from_local_clip` unmodified —
  the #275 branch, production code, not a reimplementation.

O vs T isolates the transport. Today's tags (`osm_tags_for(LAYERS)`, current
`TAXONOMY`) are used for both, on the same three SPIKE-A bboxes (`avl` /
`lwr` / `sgv`) so the comparison is like-for-like per the issue's own
instruction.

### 1.2 Result: exact, every region

| region | raw elements | path O candidates | path T candidates | O vs T |
|---|---:|---:|---:|---|
| avl (Asheville, NC) | 36,992 | 796 | 796 | **exact** — +0 / −0 / ~0 |
| lwr (Lower WI Riverway) | 10,488 | 76 | 76 | **exact** — +0 / −0 / ~0 |
| sgv (San Gabriel foothills, CA) | 41,400 | 1,294 | 1,294 | **exact** — +0 / −0 / ~0 |

Every candidate `id`, `salience` (to the stored 4dp), `layer` and
`role_affinity` agrees between the two paths, in every region. This is the
same finding shape SPIKE-I reported for the graph: the local-clip transport
is a transport, not a reimplementation, so a byte-identical source produces
a byte-identical result regardless of which pipeline the bytes travel
through. `_fetch_from_local_clip`'s own docstring claim — that it "calls the
exact same internal `_create_gdf(...)` `features_from_bbox` calls" — is
measured here, not just argued.

Two things this does **not** cover, named honestly:

- **The real mirror's `/clip` endpoint was not called.** `avl`'s bbox sits
  inside `WNC_CORRIDOR_BBOX` (`tiles/mirror.py`) so the live Pi mirror could
  in principle have served it, but `/clip` is gated by a shared
  `X-Plotlines-Client-Key` (issue #263) this environment does not hold, and
  SPIKE-I already measured the clip's own completeness (`complete_ways`,
  zero tag loss) exhaustively for the graph path — the same clipped bytes,
  read by a different consumer, is what §1 above tests. `lwr` and `sgv` fall
  outside the mirror's pinned NC/TN extracts entirely and could not have
  been clip-tested against the real mirror regardless.
- **Relations were exercised mechanically but sparsely.** avl's live pull
  carried 10 relations; `_write_pbf` round-trips them, but none of the three
  regions' candidate sets turned out to depend on relation membership for
  their score. Not a gap SPIKE-I's own graph parity work left either — see
  its §1.3 caveat on thin cells.

### 1.3 The golden-vs-current drift is real, pre-existing, and not this issue's to fix

Diffing path O (today's taxonomy) against the frozen goldens shows movement
in every region:

| region | golden (1.2.0) | today (1.3.0) | added | dropped |
|---|---:|---:|---:|---:|
| avl | 715 | 796 | 81 | 0 |
| lwr | 72 | 76 | 4 | 0 |
| sgv | 1,208 | 1,294 | 90 | 4 |

`git log -S'RULESET_VERSION = "1.3.0"'` attributes the bump to #43 (story
C7, "place lodging and campgrounds by type") — the additions read as its new
`tourism=camp_site/hostel/alpine_hut/wilderness_hut` values now qualifying.
#43's PR regenerated `core/tests/fixtures/golden_candidates/` (the compact
core-suite golden) but missed the three spike-level sets under
`results/golden/`. **This is not an extract-path defect** — O vs T is exact,
so the transport did not cause it — and it predates #275/#276 entirely.
Filed as **[#428](https://github.com/gnfrazier/plotlines/issues/428)** per
the acceptance criterion's "re-generated … or filed" clause, with the counts
above so whoever regenerates them has a starting point; not fixed here,
since it is a ruleset-history housekeeping item, not a transport-parity one.

---

## 2. SPIKE-G — density model, ~2,800 marker ceiling, A16 ~1.15 GB

**Restated unchanged**, not re-run, on two independent grounds:

1. **The ceiling is a rendering-technique capacity figure, not a
   per-bbox candidate count.** SPIKE-G (`spikes/SPIKE-G/results/RESULTS.md`)
   calibrates how many salience-gated markers the GPU can sustain before
   falling back to the dot-tail/cluster backstop — a property of the
   rendering pipeline and the hardware, exercised with synthetic candidate
   loads up to and past the ceiling. It does not depend on which transport
   produced any particular bbox's candidates.
2. **§1 above is the direct check that would have moved it if anything
   did**: the actual candidate *counts and identities* the local-clip
   transport produces are exact against the live-Overpass path, in every
   SPIKE-A region. A ceiling calibrated against candidate density is
   unaffected when the thing producing that density is proven unchanged.

No number in `spikes/SPIKE-G/results/RESULTS.md` moves. See the addendum
appended there.

## 3. Scoring weights and SPIKE-21 cue derivation

**Restated unchanged**, not re-run. Both operate entirely on the **routing
graph** — `scoring/profile.py`'s `Weights.at(position)` reads per-edge
attributes during the solve, and SPIKE-21's cue derivation splits at
intersections and reads edge tags along the solved route — and SPIKE-I
(#265) already measured the graph transport at exact parity: identical node
set, identical edge set, 100% edge-key stability, identical largest SCC, 0.0
m max per-edge geometry delta, zero tag losses, on every cell
(`spikes/SPIKE-I/results/RESULTS.md` §1, §1.3). A calibration that consumes
only the graph cannot move when the graph the transport produces is
bit-identical to the one it was calibrated against. See the addendum
appended to `spikes/SPIKE-21/results/RESULTS.md`.

`scoring/profile.py` carries no dedicated spike-record file — `Weights` /
`WeightScope` were shipped directly (M2, issue #130), and #276's own issue
body names `scoring/profile.py` as where this calibration "lives" rather
than a spike directory; this document is that calibration's record.

---

## Acceptance checklist (issue #276)

- [x] Each of the four calibrations has a recorded before/after against an
  extract-built graph/candidate path — §1 (measured), §2–3 (restated on
  SPIKE-I's graph-parity finding, with the reasoning for why that suffices).
- [x] Any golden set that moved is either re-generated with the change
  explained, or the difference is filed as an extract-path defect — §1.3,
  filed as #428 (explicitly **not** an extract-path defect; O vs T is
  exact).
- [x] SPIKE-G's marker ceiling and A16's memory figure are restated,
  confirmed unchanged — §2, and `spikes/SPIKE-G/results/RESULTS.md`'s
  addendum.
- [x] The result is written into the spike record, not only into the issue
  — this document, plus addenda in `spikes/SPIKE-G/results/RESULTS.md` and
  `spikes/SPIKE-21/results/RESULTS.md`.

## Reproducing

```bash
cd core && uv run --frozen python3 ../spikes/SPIKE-A/revalidate_clip_candidates.py
```

Needs live network access to an Overpass endpoint (the same one
`OsmLayerProvider.fetch`'s pre-#275 branch calls) — this measurement is
deliberately taken against a *fresh* live pull rather than SPIKE-A's
committed `raw/` cache, because that cache's `out center tags` queries never
recorded way node references and cannot be round-tripped through a `.osm.pbf`
at all; see §1.1 for why the comparison is structured to not need it to be
reproducible anyway (O and T come from the same fetch, so run-to-run OSM
churn cannot produce an O-vs-T false pass or false fail — only a churn
between *this* run and SPIKE-A's original `raw/` pulls, which §1.3 already
separates out).
