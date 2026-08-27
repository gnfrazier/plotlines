# SPIKE-B — Co-location cluster ranking and cost

**Issue:** #169 · **Covers:** FR102–FR105a; stories N4 / N4a `[P1]`; ARCH §4.4, **Q12**, risk **A21**, D47
**Run:** 2026-08-27 · **Region:** the Blue Ridge Parkway corridor, Asheville → Boone NC (`brp`, ~8,800 km²) — the region PRD §5.4a walks its worked review pass against
**Depends on:** SPIKE-A (#158) — ranking over an uncalibrated salience score measures nothing; this ran against `RULESET_VERSION 1.2.0`.

---

## TL;DR

- **Cost is a non-issue.** ~3,000 candidates over a real 8,800 km² multi-day bbox with all six OSM layers live cluster and rank in **~160 ms at ~1.5 MB peak**. A synthetic 30,000-candidate stress (denser than the real Blue Ridge, over a 200 km-equivalent extent) is **~3.6 s / 16 MB**. As a separate cacheable endpoint (ARCH §8.2) this is headroom, not a crutch — **the analysis does not need bounding.** Risk **A21** closes.
- **Q12 answered — corridor proximity does *not* dominate, and is not in the default rank.** Folding an `exp(-distance/decay)` factor into the score buried *Wiseman's View* (a real Linville Gorge destination, ~6 km off the paved Parkway) beneath tight roadside-viewpoint pairs. The shipped default sort is **combined salience × tightness**; corridor proximity is a **bulk filter axis** (N4a) and an **opt-in resort** (`by_corridor_proximity`) an Author with a route will almost always want. This matches N4a's own wording ("default sort is combined salience × tightness, resortable by distance-from-route").
- **The FR105a cap is `30 + 0.5 × route-km`.** Proposals run **~1 per 18 km²**, so an unbounded 20,000 km² bbox yields ~1,100 — the cap is mandatory. 30 floor covers §5.4a's ~40; a 250 km tour caps at ~155. The count beyond the cap is always returned — **never a silent truncation** (N4a).
- **Two findings changed nothing but confirmed the design:**
  1. **Affinity union (FR105 / D47) is generic.** A synthetic plugin layer declaring `battlefield` / `manor_house` / `covered_bridge` → narrative and `crag` → station clustered alongside OSM candidates and produced correct role sets **with no core change**, including a `provision+station` proposal — the **station role's first path from analysis**. (Punch-list 4.17 passes.)
  2. **Rejection memory survives a re-run with a new layer.** After bulk-rejecting a filter set and adding the plugin layer, **0** rejected clusters reappeared; `diff_runs` marked exactly the genuinely-new proposals. Rejected *spots* stay rejected even when a new layer's feature joins the cluster.
- **One thing handed back:** ranking discrimination is capped by the **salience signal**, which is near-flat in mountain terrain (`tourism=viewpoint` 0.7, `natural=peak` 0.55 — SPIKE-A's deliberate hold). The ranking function is sound but under-fed. **SPIKE-A's deferred `natural=peak` / `tourism=viewpoint` prominence sub-scaling is the next lever, not a cleverer aggregation here.**
- **Mapping gap surfaced:** `waterway=waterfall` is outside FR97's six families, so §5.4a's canonical "castle beside a waterfall" cluster is only computable when the waterfall also carries `tourism=attraction` (Linville Falls does; most don't). Non-blocking; same shape as SPIKE-A's `natural=water` residual.

---

## Method

One Overpass pull per FR97 family (`historic`, `tourism`, `amenity`, `natural`,
`leisure`, `man_made`) over `brp` — 99 × 89 km, 8,815 km², 31,818 raw features —
plus a `leisure` geometry pull for the park area gate. Cached gzipped under
`raw/`, committed, so every number reproduces offline.

`analyze.py` / `ranking.py` / `plugin.py` / `rejection.py` run
`plotlines_core.curation`'s **own** `score_notability` and the
`analyze_colocation` this spike wrote — no spike-local scoring or clustering.
The area-scaling curve is measured by **cropping** the one extract to nested
concentric sub-boxes, not by more Overpass queries: the clustering cost is a
function of candidate count and extent, and the fetch is separately cacheable.

`route.py` is the Parkway itself, hand-digitised as a 20-vertex lon/lat
polyline (Folk Art Center → Craggy Gardens → Mount Mitchell → Little
Switzerland → Linville Falls → Grandfather Mountain → Blowing Rock), used
wherever "a route exists".

The clustering: a uniform-grid connected-components pre-pass (near-linear),
then **complete-linkage** agglomeration inside each component so every
cluster's diameter ≤ `max_diameter_m` (160 m). Single linkage at *any* radius
chained a town's amenities into one 100-member blob; the diameter ceiling is
what keeps a proposal to a walkable "one stop" and splits a main street into
the few real clusters on it. A `_SPLIT_CAP` guard grid-splits pathologically
large components so the worst case stays bounded.

---

## 1. Cost (issue point 1, risk A21)

### Area sweep — concentric crops of the real extract

| area km² | candidates | clustering ms | peak MB | proposals (uncapped) |
|---:|---:|---:|---:|---:|
| 8,815 | 2,966 | **160** | 1.45 | 480 |
| 4,407 | 1,293 | 48 | 0.52 | 181 |
| 2,204 | 529 | 17 | 0.20 | 66 |
| 1,058 | 271 | 9 | 0.09 | 35 |
| 529 | 137 | 4 | 0.04 | 17 |

Candidate count scales ~linearly with area. Time scales slightly
super-linearly (denser boxes → larger connected components → more
complete-linkage work), but the absolute numbers are trivial everywhere real.

### Layer-count sweep (full box)

| live layers | candidates | ms | peak MB |
|---|---:|---:|---:|
| 2 — historic + natural | 1,018 | 20 | 0.45 |
| 3 — + sight | 1,262 | 32 | 0.56 |
| 4 — + amenity | 2,713 | 142 | 1.37 |
| 6 — all | 2,968 | 163 | 1.45 |

The `amenity` layer is the cost step — it is the densest and the one that
forms the large town-centre components.

### Dense sweep — synthetic (jittered copies, a 200 km dense-country proxy)

| ×factor | candidates | ms | peak MB |
|---:|---:|---:|---:|
| 1 | 2,968 | 160 | 1.5 |
| 2 | 5,936 | 553 | 6.6 |
| 5 | 14,840 | 1,304 | 6.8 |
| 10 | 29,680 | 3,598 | 16.5 |

30,000 candidates — denser than the real Blue Ridge spread across a 200 km
extent — is **~3.6 s and 16 MB**. For a named Author action served from a
separate cacheable endpoint, that is fine with room to spare.

**Verdict:** affordable outright. The cacheable-endpoint mitigation (ARCH
§8.2) is not needed to make it feel fast; it is needed only so a re-run does
not re-pay the cost. No bounding of the analysis itself is required.

---

## 2. Ranking function (issue point 2, ARCH Q12)

### The function

```
salience_score = noisy_or(member saliences)          # 1 - Π(1 - sᵢ); FR102/FR105a "combined salience"
tightness      = 1 / (1 + rms_dist_to_centroid_m / 90)
rank_score     = salience_score · (0.72 + 0.28 · tightness)
```

`tightness_floor` 0.72 (was 0.6 in the first cut): at 0.6 an `s=1.0` 5-member
cluster fell *below* tight `s=0.85` pairs on compactness alone. 0.72 lets
tightness re-order without overturning a real salience gap.

### Corridor proximity — four treatments compared

Against PRD §5.4a's scenario (Grandfather Mtn / Linville box, 4 layers, the
Parkway as route). Ranks of recognisable destinations an Author would promote:

| destination | default (sal×tight) | corridor resort d=2500 | corridor resort d=800 | dominant (dist bands) |
|---|:--:|:--:|:--:|:--:|
| Wiseman's View (6 km off paved BRP) | **1** | 20 | 20 | 18 |
| Wilson Center (1 km) | **2** | 7 | 7 | 6 |
| Plunge Basin Overlook (0.8 km) | 8 | 6 | 6 | 7 |
| Beacon Heights (0.1 km) | 20 | **5** | **4** | **4** |
| Grandmother View (0.0 km) | 11 | **1** | **1** | **1** |
| Erwin's View Outlook (1 km) | 15 | 8 | 8 | 10 |

- **Default (route ignored in the sort)** puts the two genuinely major sights
  first (*Wiseman's View*, *Wilson Center*) but also floats
  *Viewpoint @20 km* and *The Tropical Grill @6.6 km* into the top 5, because
  in this region salience is near-flat and those clusters win on
  tightness/count. This is N4a's specified default — the map/route is not
  consulted until the Author resorts or filters.
- **Corridor resort (`by_corridor_proximity`, `exp(-d/2500)`)** is the view
  an Author with a route wants: it pulls the on-Parkway overlooks
  (*Beacon Heights* 20→5, *Grandmother View* 11→1) up and pushes the 20 km-off
  clusters down. *Wiseman's View* drops to 20 — correct: it is 6 km down a
  gravel forest road, genuinely not "on" a Parkway tour.
- **`d=800` vs `d=2500`** — near-identical top-10. The decay scale is not
  sensitive in this data; 2500 m is the gentler choice.
- **Dominant (distance *bands* as the primary key)** offers nothing the smooth
  resort doesn't, and is more brittle (band-edge cliffs). Rejected.

**Decision:** corridor proximity is **not** in the default `rank_score`. It is
(a) `distance_to_route_m` on every proposal for the N4a filter, and (b)
`by_corridor_proximity()` — the opt-in resorted view. Folding it into the
default score is the "corridor dominates" failure the issue warned about: it
buried a real destination under roadside pairs.

### "Does the ranking put the right ones near the top?"

Partly — and the gap is instructive. The default top-10 is *Wiseman's View*,
*Wilson Center*, then a run of viewpoint clusters that are salience-tied at
~0.9 and separated only by tightness and member count. **Nearly every
candidate in a Blue Ridge box is a flat-weighted `tourism=viewpoint` (0.7) or
`natural=peak` (0.55).** No aggregation function manufactures discrimination
that is not in the input. SPIKE-A explicitly deferred `natural=peak`
prominence scaling "until SPIKE-B can scale it by prominence + corridor
proximity" — this spike is the evidence that it now blocks ranking quality.
**Recommended next step (notability, not ranking):** sub-scale
`tourism=viewpoint` and `natural=peak` by topographic prominence / `ele` /
`wikidata`-presence.

---

## 3. The reviewable cap (issue point 3, FR105a / N4a)

Uncapped proposal count vs bbox scale, from the area-sweep crops:

| area km² | candidates | proposals |
|---:|---:|---:|
| 8,815 | 2,966 | 480 |
| 4,407 | 1,293 | 181 |
| 2,204 | 529 | 66 |
| 1,058 | 271 | 35 |
| 529 | 137 | 17 |

**~1 proposal per 18 km².** A 200 × 100 km bbox → ~1,100 proposals. A pure
area cap would have to 10× on a large bbox to hold a constant fraction, which
defeats the point. Tie the cap to **route length** where a route exists — a
longer tour legitimately has more worth reviewing, but corridor km grows ~1D,
not ~2D like area:

```
cap = 30 + round(0.5 · route_km)          # 30 with no route
```

- §5.4a's 30 km trip box (~40 proposals) → cap 30, "+10 beyond".
- The 100 km BRP corridor → cap 80.
- A 3–4 day ~250 km tour → cap ~155.

The count beyond the cap is **always** returned (`analyze_colocation_full`
gives `(shown, n_beyond)`); N4a's dense state says how many and offers a
filter — it never truncates silently.

### §5.4a worked pass, re-run

38 proposals from the box (§5.4a's illustrative 43). The shortfall is
**SPIKE-A**: §5.4a's "19 single-tree and small-park" noise proposals no longer
occur — SPIKE-A's Stage-1 gates removed that candidate class. So the
bulk-salience-reject action now removes ~7 real-but-minor clusters, not 19
tree pins, and the corridor distance filter does the heavy lifting. Post
SPIKE-A + SPIKE-B, **fewer, higher-quality proposals reach individual review
than §5.4a envisioned** — which is the intended direction.

---

## 4. Proposal kinds & affinity union (issue point 4, FR103–FR105, D47)

The four `kind`s all appear in one run and read differently:

| kind | suggests | example (worked-pass box) |
|---|---|---|
| `narrative` | a plot point | *Wiseman's View* — `historic=memorial` + `tourism=viewpoint` |
| `provision` | a rest stop | *The Tropical Grill* — `cafe` + `restaurant` + `toilets` |
| `narrative+provision` | a major stop | *Wilson Center* — `museum` + `restaurant` + `shelter` + `toilets` |
| `narrative+station` / `provision+station` | + a station role | (plugin `crag` + OSM feature) |

`role_affinities` is the sorted union of member `role_affinity` (FR105). The
`kind` is derived from that union — one code path, no per-recipe branch.

### Plugin layer — the §0 regression test (punch-list 4.17)

A synthetic plugin `LayerProvider` declaring types that appear in **no** PRD
example:

| plugin type | declared affinity | salience |
|---|---|---|
| `battlefield` | narrative | 0.80 |
| `manor_house` | narrative | 0.75 |
| `covered_bridge` | narrative | 0.60 |
| `crag` | **station** | 0.70 |

Dropped ~35 m from real OSM candidates, they clustered and were proposed
**with no core change**:

- `battlefield` + `historic=district` → `narrative`
- `manor_house` + `viewpoint` + `peak` → `narrative`
- `crag` + `drinking_water` → **`provision+station`**, roles `(provision, station)`
- `crag` + `restaurant` → **`provision+station`**

The `crag` cases are the **station role's first path from analysis** — D47's
"gives the station role its first path" made concrete. Locked by
`test_curation_colocate.py::test_plugin_station_affinity_participates_with_no_core_change`.

---

## 5. Rejection memory + re-run (issue point 5, FR110 / N4a)

Scenario: run over the worked-pass box with the route → bulk-reject every
provision cluster >1.2 km off route (13 of them; §5.4a's "provision clusters
along a road they aren't using") → their member-id sets become the trip's
rejection set → re-run **with the plugin layer added** and the rejection set
passed back.

| | count |
|---|---:|
| run 1 proposals | 38 |
| bulk-rejected | 13 |
| run 2, plugin added, **no** memory | 41 |
| run 2, plugin added, **with** memory | **28**  (= 41 − 13, exact) |
| rejected clusters that **reappeared** | **0** |
| rejected *spots* kept out despite a plugin feature joining the cluster | 4 |
| `diff_runs` vs run 1: new / carried over | 4 / 24 |

- **Every prior rejection survived** the layer addition. `28 = 41 − 13`
  exactly — nothing rejected slipped back in.
- The rejection set is member-id **frozensets** (ARCH §4.4 "a small rejection
  set, not the cluster itself"). A fresh proposal is suppressed if its member
  set has Jaccard ≥ 0.6 with any rejected set — so a rejected 2-member spot
  that a plugin feature *joins* (→ 3 members, Jaccard 0.67) **stays rejected**:
  the Author already said no to that place. 4 such cases here.
- `diff_runs(previous, current)` sets `is_new` from the same Jaccard test, so
  genuinely-new proposals (3 of the 4 carry a plugin feature) are flagged and
  unchanged ones are not. Complete-linkage means adding a layer can *reshape*
  a nearby cluster; when it does, the reshaped proposal correctly surfaces as
  new rather than silently replacing the old one.

---

## Deliverables

| artifact | what |
|---|---|
| `core/plotlines_core/curation/colocate.py` | `analyze_colocation` / `analyze_colocation_full`, `ColocationParams` (SPIKE-B-tuned defaults as config), `by_corridor_proximity`, `reviewable_cap`, `diff_runs` |
| `core/tests/test_curation_colocate.py` | 20 tests locking clustering, affinity union, the ranking decisions, the cap, and rejection/re-run |
| `spikes/SPIKE-B/analyze.py` | cost sweeps (area / layer-count / synthetic-dense) → `results/cost.json` |
| `spikes/SPIKE-B/ranking.py` | worked-pass reconstruction, corridor-treatment comparison, cap justification → `results/ranking.json` |
| `spikes/SPIKE-B/plugin.py` | affinity-union + plugin-layer + station-path test → `results/plugin.json` |
| `spikes/SPIKE-B/rejection.py` | rejection-memory + re-run-diff test → `results/rejection.json` |
| `spikes/SPIKE-B/raw/*.json.gz` | the committed Overpass pulls (~0.75 MB) |
| `route.py` | the digitised Blue Ridge Parkway alignment |

ARCH **Q12** resolved · risk **A21** measured/mitigated · punch-list **4.17**
closed · PRD "cluster proposal ranking at scale" open item closed.

---

## Limits / caveats

- **One region.** The Blue Ridge is a viewpoint-and-peak monoculture, which is
  exactly why the flat-salience ceiling showed up so clearly — but a
  castle-and-abbey region (where `historic=*` sub-weights give real spread)
  would exercise the salience half of the rank harder. The cost and cap
  findings are region-independent; the "right 5 near the top" finding is
  region-shaped and points at notability.
- **The route is hand-digitised**, ~2–5 km between vertices. That is accurate
  to ~50 m near the road, well inside `corridor_decay_m`; it is not a solved
  route with real surface geometry.
- **Synthetic densification** multiplies real candidates with spatial jitter.
  It reaches realistic *counts* for a large dense bbox but not a realistic
  *spatial distribution* — real dense regions cluster harder, so the cost
  numbers there are if anything conservative.
- **The cap formula's slope (0.5/route-km) is a judgement**, not a measured
  human-throughput number. It is `ColocationParams` config precisely so a
  usability pass on the real review screen can move it without a release.
- **`by_corridor_proximity` is a resort of the already-capped list.** If an
  Author wants corridor-proximate proposals that fell *outside* the cap, the
  filter (not the resort) is the tool — which is N4a's model.

---

## Residual open items (none blocking Leg 6.5)

1. **Prominence sub-scaling for `natural=peak` / `tourism=viewpoint`** — a
   notability (SPIKE-A-domain) pass. This is the single biggest lever on
   ranking quality and SPIKE-A already flagged it as deferred to "when
   SPIKE-B has prominence + corridor context". SPIKE-B has now shown it is the
   bottleneck.
2. **`waterway=waterfall` mapping** — outside FR97's six families; a mapping
   pass, same shape as SPIKE-A's `natural=water` residual.
3. **Cap slope calibration** against the real review screen (a usability
   question, not a spike).
4. **Complete-linkage reshape on re-run** — documented and handled by
   `diff_runs`' Jaccard tolerance, but worth a note in the N4a UI spec: adding
   a layer can renumber a nearby proposal, and that is surfaced as "new", not
   hidden.
