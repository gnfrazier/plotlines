# SPIKE-I — pre-registered bands

**Issue:** [#265](https://github.com/gnfrazier/plotlines/issues/265) ·
**Covers:** review §7.1, §8, §11.1, §11.5, §11.7, §6.7, §12 (Q1, Q6) ·
addendum **G5**, **2b**, **2c**, **L1** · ARCH **A23/A23a** · PRD **FR121**

This file is the pre-registration the addendum's **G5** and checklist item **2b** ask
for. It is written and committed **before the first measurement**, in the discipline
SPIKE-13 (`bands.py`) and SPIKE-21 used: the threshold is declared while the numbers
are still unknown, so "close enough" cannot be decided after they are visible.

SPIKE-21 is the precedent worth copying deliberately. Its ceiling was declared first,
**the first implementation failed it**, and the fix was structural rather than a
threshold sweep. A band you can fail is the point. Nothing below is written so that it
will pass.

The machine-readable form of every band in this document is `bands.py`; `run.py`
grades a completed run against it and exits non-zero on a fail. If this file and
`bands.py` ever disagree, `bands.py` is the one that ran — but they are committed in
the same commit, before `probe.py` is first executed, and neither is edited afterwards.

---

## 0. What is actually being compared, and why that is a choice

§8 says Phase 3 "replaces the *transport*, not the interfaces." §11.1 says the risk is
that `ox.graph_from_bbox` does far more than download — `network_type` filtering, way
splitting, simplification, strong-component truncation — and that **pyrosm is a
different implementation of the same idea**, so node ids, edge keys and geometry need
not match.

Those two sentences describe **two different swaps**, and conflating them is how this
spike would produce a number that answers neither. So both are built and both are
graded, separately:

| | Path | What changes | What does not |
|---|---|---|---|
| **T** | *transport swap* — clipped `.osm.pbf` → OSM elements in Overpass's own response shape → `osmnx._create_graph` → the identical post-download pipeline | the bytes, and the code that selects which ways match `network_type` | every line of osmnx after the download: way splitting, simplification, truncation, component pruning, length computation |
| **R** | *reimplementation* — clipped `.osm.pbf` → pyrosm → graph | the bytes **and** the whole graph construction | nothing |

`_download_region_graph` (`core/plotlines_core/graph/regions.py`) is the function under
test. It is, in order:

```python
graph = ox.graph_from_bbox(bbox, network_type=..., simplify=False)
graph = ox.simplify_graph(graph, node_attrs_include=["barrier"])
fold_node_barriers(graph)
return ox.truncate.largest_component(graph, strongly=True)
```

and `graph_from_bbox` → `graph_from_polygon` is itself one download call
(`_overpass._download_overpass_network`) followed by ~10 lines of post-processing
(`_create_graph`, two `truncate_graph_polygon` passes either side of an optional
simplify, two `largest_component` passes, `count_streets_per_node`). **Path T replaces
exactly the download call and nothing else** — the post-processing is called, not
reimplemented. Path R replaces all of it.

Pre-registering both is the point: if T passes its bands and R fails them, the finding
is not "parity fails", it is **"parity is a property of which swap you choose,"** and
§8 gets a named implementation rather than a warning. If T *also* fails, the failure is
in the bytes or in the way-filter reimplementation, and it is localised to two places
instead of the whole pipeline.

### 0.1 The one thing T still has to reimplement

Overpass's way selection is a **query filter**, not something the pbf carries.
`_get_network_filter(network_type)` is Overpass QL — for `bike`:

```
["highway"]["area"!~"yes"]["access"!~"private"]
["highway"!~"abandoned|bus_guideway|construction|corridor|elevator|escalator|footway|
  motor|no|planned|platform|proposed|raceway|razed|rest_area|services|steps"]
["bicycle"!~"no"]["service"!~"private"]
```

Path T must evaluate that against pbf way tags in Python. That reimplementation is the
single most likely source of a T-path difference, and it is the same defect class as
**SPIKE-E's** finding that `drive` silently drops `highway=track` and `highway=service`:
a filter that is subtly wrong produces a graph that is smaller and **reports success**.
So the filter is graded on its own, per way, before any graph is built — see **B0**.

Note also, because it governs the clip strategy in §3 below: the Overpass query is
`(way<filter>(poly:…);>;);out;`. The `>` recurses down to **every member node of every
matched way, including nodes outside the polygon**. Overpass has been handing us
*complete ways* all along. A clip that does not do the same cannot reach parity, which
is why `complete_ways` is not one of three equal options to benchmark — it is the
**floor**, and `simple` is measured to quantify what it would have cost us.

---

## 1. Controlling for the thing that is not a parity difference

A golden osmnx graph built today and a Geofabrik extract pinned on some other day are
**different snapshots of a database that changes every minute**. Every id that appears
in one and not the other would score as a parity failure while being nothing of the
kind. Left uncontrolled, this alone would decide the verdict.

Two controls, in order of preference, both declared now:

1. **Attic query (primary).** Read `osmosis_replication_timestamp` out of the clipped
   extract's pbf header and build the golden graph with
   `[date:"<that exact timestamp>"]` prepended to `ox.settings.overpass_settings`, so
   Overpass serves the database **as of the extract's own instant**. Both sides then
   describe the same snapshot and exact set identity is a legitimate thing to require.
   `probe.py` verifies the attic path is live (a dated query and an undated query over
   one small bbox must differ in at least one element, or must be shown identical for a
   stated reason) **before** any golden is built. A silently-ignored `[date:]` that
   returns today's data would make every band below meaningless in the permissive
   direction.
2. **Changeset attribution (fallback, if attic is unavailable or refused).** Every
   element in the symmetric difference is looked up through the OSM API and must be
   explained by a version whose timestamp falls **between** the two snapshots.
   **Unattributed differences are parity failures with zero tolerance.** A run that
   falls back to this control reports the attributed and unattributed counts separately
   and never merges them.

Either way the rule is the same and is registered here: **a difference is a failure
unless it is shown to be snapshot drift. It is never assumed to be.**

---

## 2. The parity bands

Graded per `(region × network_type × path)` cell. A band is met only if it is met in
**every** cell — a rollup can never launder one bad region, for SPIKE-13's reason.

### B0 — way-filter agreement (the precondition)

Before any graph is built: for every way in the clipped extract, compare the Python
filter's verdict against Overpass's. Overpass's verdict is observable — a way id is in
the golden response or it is not — so this is a confusion matrix, not an opinion.

| | band |
|---|---|
| **exact** | zero false accepts **and** zero false rejects, every cell |
| **fail** | anything else |

No tolerance, and deliberately so. A false reject is SPIKE-E's defect exactly: a real
way that never reaches the graph, on a path that reports success. A false accept is the
same defect wearing the other sign — an unroutable way inside a routable graph. There is
no "small" version of either; one way is a trailhead.

### B1 — node set identity

Compare OSM node id sets on the finished graph (post-simplify, post-`largest_component`).

| | band |
|---|---|
| **PARITY** | symmetric difference is **empty**, or every element in it is snapshot-attributed per §1 |
| **RECALIBRATE** | unattributed symmetric difference ≤ **0.5%** of the golden node count, in every cell |
| **RESCOPE** | anything above |

**Why 0.5% and not "a few nodes".** SPIKE-A's notability goldens and SPIKE-G's density
model are counted over candidate sets, not graph nodes, but the routing graph is what
`colocate.by_corridor_proximity` measures distance *along*. A half-percent node
difference concentrated at one trailhead is a different trip; spread evenly it is
noise. The band is therefore a ceiling on the **aggregate**, and any cell that uses more
than a tenth of it gets its differences enumerated individually in the write-up rather
than reported as a percentage.

### B2 — edge set and edge key stability

Two separate numbers, because they fail for different reasons.

**B2a — edge set**: the set of `(u, v, osmid-set)` triples.

| | band |
|---|---|
| **PARITY** | symmetric difference empty or fully snapshot-attributed |
| **RECALIBRATE** | unattributed symmetric difference ≤ **0.5%** of golden edge count |
| **RESCOPE** | above |

**B2b — edge key stability**: for every edge present in both graphs, does the osmnx key
`k` in `(u, v, k)` refer to the same underlying way set on both sides? `k` is assigned
by insertion order among parallel edges in `_add_paths`, so it is a function of **way
iteration order**, which is a property of the transport, not of the data.

| | band |
|---|---|
| **PARITY** | **100%** of common edges keep their `k`, every cell |
| **RECALIBRATE** | ≥ 99.9%, **and** every re-keyed edge is a genuine parallel-edge pair (`k > 0` exists for that `(u, v)`) |
| **RESCOPE** | below that, or a re-key on a `(u, v)` that has only one edge — which would mean `k` moved for a reason other than ordering |

**What a re-keyed edge breaks downstream**, since the issue asks the band to say:
nothing in the trip payload persists `(u, v, k)` — `docs/schemas/trip_payload.schema.json`
carries geometry, not graph references, and the only `(u, v, k)` consumers in core
(`routing/access.py:364-371`) resolve and use keys inside a single call. The real
exposure is the **cached graph on disk**: `region.graph_path(cache_dir)` is keyed on
`(bbox, network_type, GRAPH_RULESET_VERSION)`, which does not include the transport. A
client holding an Overpass-era `graph.graphml` and a Phase 3 build that re-keys would
resolve one against the other with no error and no cache miss. If B2b lands anywhere
below PARITY, **the deliverable is a `GRAPH_RULESET_VERSION` bump in Phase 3**, not a
tolerance — that constant exists for exactly this and costs one integer.

### B3 — largest strongly-connected component

`_download_region_graph` ends on `largest_component(strongly=True)`, so this is the
graph that actually routes, and it is the metric most sensitive to a single severed way
— which is precisely what §11.7 warns a bbox cut does.

| | band |
|---|---|
| **PARITY** | SCC node set identical, or differing only by snapshot-attributed nodes |
| **RECALIBRATE** | \|Δ size\| ≤ **1.0%** of golden SCC size, every cell, **and** the ratio SCC/total is within ±1.0 point of golden |
| **RESCOPE** | above — or the SCC is smaller by more than 1% in *any* cell, regardless of the aggregate |

The asymmetry in the RESCOPE row is intentional. A smaller SCC means real road has
fallen out of the routable set; a larger one means the clip brought in ways Overpass's
filter excluded. Both are bugs, but the first one silently shortens routes and is the
one SPIKE-E showed we ship without noticing.

### B4 — geometry

Per-edge `length` delta over edges matched by `(u, v, osmid-set)`, reported as a
**distribution** (p50 / p95 / p99 / max), never a mean.

| | band |
|---|---|
| **PARITY** | **max \|Δ\| ≤ 1 mm** per edge, and max \|Δ\| on total route-relevant length ≤ 1 mm × edge count |
| **RECALIBRATE** | p99 ≤ **0.5 m** and max ≤ **5 m**, with every edge above 0.5 m individually explained |
| **RESCOPE** | above |

**1 mm is not a tight band, it is the honest one.** A pbf stores coordinates as
nanodegree integers at granularity 100 — exactly 1e-7 degrees — and Overpass JSON emits
7 decimal places. The two representations are the *same numbers*. `length` is a
great-circle distance computed by the same `distance.add_edge_lengths` call on both
sides. So for path T, any delta at all is a float-formatting artefact and anything
above a millimetre means a node moved, which is a data difference, not a geometry
difference. Path R gets the same band applied and is expected to be the one that needs
the RECALIBRATE row — it computes its own geometry.

### B5 — `PLOTLINES_WAY_TAGS` survival — **zero tolerance**

The fourteen way tags in `graph.regions.PLOTLINES_WAY_TAGS` and the node tag
`PLOTLINES_NODE_TAGS = ("barrier",)`. This is the **#206** class of defect: a rule keyed
on an un-downloaded tag goes silently inert on every real graph, and SPIKE-E found it
live.

Asserted at **three** points, because the loader's promise is not evidence:

1. **On the bytes of the clipped `.osm.pbf`**, read directly with pyosmium — not through
   osmnx, not through pyrosm. Per tag: the count of ways carrying it in the source
   extract restricted to the bbox, versus in the clip.
2. **On the built graph**, per tag: edge count carrying it, golden versus local.
3. **On the fold**: `barrier` node count in the clip, and edges carrying a folded
   `barrier` after `fold_node_barriers`, golden versus local.

| | band |
|---|---|
| **PARITY** | for every one of the fifteen tags, local count ≥ golden count, and any excess is snapshot-attributed. **Zero losses.** |
| **fail** | one tag lost anywhere, at any of the three points |

There is no RECALIBRATE row. A tag that survives on 99% of edges is a rule that is wrong
1% of the time with no way to tell which time, and `test_graph_regions.py` already
asserts that `PLOTLINES_WAY_TAGS` covers every key `routing/access.py` and
`scoring/profile.py` read. Losing one here is losing a shipped rule.

---

## 3. Clip strategy, and what it costs (§7.1(3), addendum **L1**)

**The strategies are not flags.** `simple` / `complete_ways` / `smart` are
**osmium-tool** concepts and osmium-tool is GPL-3.0; the clip goes through **pyosmium's
Python API** (BSD-2-Clause), so the equivalent behaviour is implemented here and then
compared. That is priced as real spike scope, per L1's second-order note.

What each has to mean, written down before measuring so the comparison is of behaviour
and not of names:

| | behaviour | what it costs |
|---|---|---|
| `simple` | keep ways with ≥1 node in the bbox; keep only those of their nodes that are *also* in the bbox | one pass; severed ways with holes in the geometry |
| `complete_ways` | keep ways with ≥1 node in the bbox; keep **all** their nodes, including those outside | two passes (or one pass plus a node-id back-reference set) |
| `smart` | `complete_ways`, plus relations whose members are kept, plus the members those relations reference | three passes |

`service/plotlines_service/mirror_clip.py` already implements one of these
(`_CompleteWaysClip`) deliberately, per #262. This spike does not replace it; it
implements the other two **in the spike** for comparison and grades the shipped one
against the parity bands above.

### B6 — clip cost, measured server-side

Per addendum **2c** and **Q1-C** these are taken **on the mirror**, through the real
`/clip` HTTP endpoint, not in-process on the dev box. Any figure taken anywhere else is
labelled as such in the write-up and does not count toward the band.

Budgets, set against the interaction they sit inside — FR120's "Author declares the
extent" moment, reported through FR121's capability channel, against a **measured**
graph build of 36.7–116.6 s that the clip is strictly upstream of:

| | band |
|---|---|
| **PARITY** | p95 wall time ≤ **20 s** for a realistic trip bbox; peak RSS ≤ **1.5 GB**; output ≤ **2%** of the source extract |
| **RECALIBRATE** | p95 ≤ **60 s**; peak RSS ≤ **3 GB**; output ≤ 5% |
| **RESCOPE** | above either — the clip is not a step that can hide inside the existing readiness wait, and §6.7/§9's cost profile needs rethinking before Phase 3 |

RSS matters more than it looks: the Pi 5 has 8 GB and also serves the static tree. A
clip that needs 3 GB is one concurrent request away from being the mirror's availability
story, which is §11.3's whole warning.

### B7 — the border case (§11.7)

A bbox straddling two Geofabrik extracts. A road network is connected, so a bbox cut
severs ways — and Geofabrik cuts at the state line, so the two extracts each carry half
of every crossing way.

| | band |
|---|---|
| **PARITY** | the clip over the border bbox produces a graph whose largest SCC **contains every crossing way** present in the golden, i.e. B1–B4 hold in the border cell exactly as in an interior cell |
| **RECALIBRATE** | crossing ways survive but the SCC splits, **and** the split is detectable from the clip output alone (so Phase 3 can fail loudly rather than route around it) |
| **RESCOPE** | a crossing way is lost, or the split is undetectable — a severed network that reports success is the failure mode this whole band exists to catch |

The undetectability clause is the load-bearing one. Two disconnected halves that each
route fine internally is exactly the shape of a bug nobody notices until an Author's
route is quietly 40 km longer.

---

## 4. The arithmetic and the fallback trigger

### B8 — Q6's egress arithmetic (§11.5, §12-Q6)

Not a pass/fail band — the only open question in §12 with no measurement attached, and
this spike is where it gets one. Reported as a table, with the guess stated as a guess:

`extract size per region` × `trips per Author per region` versus
`clip output size` × the same, for a stated range of trips-per-Author-per-region
(**1, 3, 10**) and a stated Author population (**100, 1 000, 10 000**). The ratio of the
two columns is the number Q1-C bought, and it is reported as a ratio precisely so it
survives being wrong about the population.

### B9 — the Q1-D trigger (§6.7, §12-Q1)

Q1 adopted **C** with **D** as the stated fallback and named exactly one thing that
would force D: *"Author edits the bbox on a mountain with no signal."* §6.7 says that is
a measurement, not a guess, and that SPIKE-I is where it gets made.

Measured, not argued: with the network down, given only what the client already holds
after one successful `/clip` for bbox *A*, what fraction of bbox *B* is servable?

| | band |
|---|---|
| **C holds** | an offline edit that **shrinks or nudges** the bbox is servable from the held clip for ≥ 90% of a realistic edit distribution, and an edit that grows it fails **loudly and immediately** with a message naming the network as the reason |
| **D triggered** | a common edit shape is unservable *and* the failure is indistinguishable from an empty area, or the re-clippable fraction is low enough that offline editing is effectively unavailable |

"Realistic edit distribution" is fixed before the run as: **shrink** (bbox scaled 0.5–0.95
about its centre), **nudge** (translated by 0–25% of its own span), **grow** (scaled
1.05–2.0). Equal weight, since nothing measured tells us the real mix — and stating that
it is an assumption is the point of writing it down now.

---

## 5. Verdict

The three bands the whole run rolls up to. The middle one is the one that matters,
because it is the one §8 and #276 are written against.

```
PARITY       B0 exact, B1–B5 all PARITY, B6 PARITY or RECALIBRATE, B7 PARITY.
             Phase 3's transport swap is safe as written. SPIKE-A's goldens and
             SPIKE-G's density model do not need re-earning.

RECALIBRATE  No band worse than RECALIBRATE, and B0/B5 still exact/zero-loss.
             §8 stands, but the swap is not done until #276 re-runs SPIKE-A's
             golden candidate sets, SPIKE-G's ~2,800 ceiling and SPIKE-21's cue
             derivation against the new path, and A23/A23a are re-answered with
             the clip's numbers rather than Overpass's.

RESCOPE      Any band at RESCOPE, or B0/B5 failed at all. Phase 3 does not happen
             as written; §12's answers reopen — specifically Q1-C against its D
             fallback, and Q6's arithmetic against a transport that costs more
             than the one it replaces.
```

**B0 and B5 are vetoes.** They sit outside the rollup because they are not degrees of
parity — a filter that drops a real way, or a tag that does not survive, is a defect
that ships and reports success, which is the one outcome this spike exists to prevent.

---

## 6. What is measured where

| leg | where it runs | why |
|---|---|---|
| B0–B5 parity | dev box | comparing two graphs is not a timing measurement |
| B6 clip cost | **the Pi mirror, through `/clip`** | addendum **2c**: Q1-C is decidable only on server-side numbers |
| B7 border | clip on the Pi, parity on the dev box | same split |
| B8 arithmetic | offline, from B6's sizes | |
| B9 offline edit | dev box, network down | it is a client-side question |

Any leg that cannot run where this table says it runs is reported as **not measured**,
with the substitute named. It is never quietly relabelled.

## 7. Regions

The shared fixture regions (`spikes/shared/regions.py`), so the result is comparable to
SPIKE-01/02/03/05 and SPIKE-E, plus one border bbox that exists only here.

| key | region | extract | network_type |
|---|---|---|---|
| `boulder` | Boulder, CO | `north-america/us/colorado` | `bike`, **and** `drive` |
| `davis` | Davis, CA | `north-america/us/california` | `bike` |
| `viroqua` | Viroqua, WI | `north-america/us/wisconsin` | `bike` |
| `coline` | CO/WY state line, US 287 | `colorado` **+** `wyoming` | `bike` |

`boulder` runs twice because SPIKE-E's finding — `network_type="drive"` is a *download
filter* that silently drops `highway=track` and `highway=service` — lives in exactly the
code path B0 reimplements. If the Python filter reproduces osmnx's `drive` behaviour
exactly, it reproduces that defect exactly too, and that is the correct outcome for a
parity spike: **parity with a known defect is parity**. The defect is SPIKE-E's to fix
and is out of scope here; what is in scope is not accidentally fixing or worsening it
while swapping the transport, which is a thing B0 can see and a node count cannot.

`coline` is the §11.7 border case: US 287 crosses the state line at 41°N, and Geofabrik
cuts both extracts there.

---

## 8. No product code changes

Same discipline as SPIKE-A/C/D/E/F/G/H. Nothing under `core/plotlines_core/` or
`service/plotlines_service/` is edited by this spike. Where a finding implies a product
change — a `GRAPH_RULESET_VERSION` bump, a filter fix, a clip-strategy change — it is
filed as an issue and named in `results/RESULTS.md`, not applied here.
