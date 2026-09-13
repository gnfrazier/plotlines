# SPIKE-I — Local extract and graph parity

**Issue:** [#265](https://github.com/gnfrazier/plotlines/issues/265) ·
**Epic:** [#268](https://github.com/gnfrazier/plotlines/issues/268) ·
**Bands:** [`../HARNESS.md`](../HARNESS.md) / [`../bands.py`](../bands.py), committed
before the first measurement ·
**Method:** [`METHOD.md`](METHOD.md) · **Numbers:** [`results.json`](results.json)

---

## Verdict: **RESCOPE** — and the reason is the opposite of the one §11.1 predicted

The review expected the danger to be in **graph construction**: "pyrosm is a
different implementation of the same idea; node IDs, edge keys and geometry need
not match," with everything calibrated to date measured on osmnx output. That
risk is real and this spike measured it — but it is **avoidable by construction**,
and it is not what fails.

What fails is the **clip transport itself**, which the review treated as the
settled part.

| | band | result |
|---|---|---|
| **B0** way-filter agreement *(veto)* | exact | **exact** — 0 false accepts, 0 false rejects, every cell |
| **B1** node set identity | exact, or ≤0.5% attributed | **exact** — path T, every cell |
| **B2a** edge set | exact, or ≤0.5% | **exact** — path T |
| **B2b** edge key stability | 100% | **100%** |
| **B3** largest SCC | identical | **identical** |
| **B4** geometry | max ≤1 mm | **0.0 m** |
| **B5** tag survival *(veto)* | zero losses | **zero** |
| **B6** clip cost, server-side | p95 ≤20 s / ≤1.5 GB | **432 s / 2,853 MB — RESCOPE** |
| **B7** border case | crossing ways survive | **does not complete — RESCOPE** |

**Path T reaches parity exactly. Path R does not come close. The clip that feeds
either one cannot meet its budget, and on a two-extract bbox it crashes.**

So the finding is not "parity fails." It is:

> Phase 3's graph-construction swap is safe **as long as it is a transport swap
> and not a reimplementation** — feed the clipped bytes into osmnx's own
> `_create_graph` and the graph is bit-identical. What needs rescoping is §6.7's
> clip, which is O(region extract) per request and does not survive the border
> case at all.

---

## 1. Parity: two swaps, two completely different answers

`HARNESS.md` §0 split §11.1's risk in two before the run, because the review
describes two different experiments in one paragraph:

- **path T** — clipped `.osm.pbf` → OSM elements in Overpass's own response
  shape → `osmnx._create_graph` → the identical post-download pipeline.
- **path R** — clipped `.osm.pbf` → pyrosm → graph.

`bands.classify` does not prefer either; encoding a preference would have been
deciding the answer in the pre-registration.

| cell | character | golden nodes / edges | path T (all 4 arms) | path R (pyrosm) |
|---|---|---|---|---|
| boulder-bike | mountain-adjacent urban grid | 9,581 / 24,388 | **exact** — 0 / 0 | 62,940 nodes (**6.6×**) |
| boulder-drive | same bbox, `drive` filter | 2,153 / 5,447 | **exact** — 0 / 0 | 38,495 nodes (**17.9×**) |
| davis-bike | flat, dense bike network | 5,594 / 14,159 | **exact** — 0 / 0 | 31,696 nodes (**5.7×**) |
| viroqua-bike | sparse rural Driftless | 2,133 / 5,085 | **exact** — 0 / 0 | 25,465 nodes (**11.9×**) |
| coline-bike | CO/WY line, merged source | 73 / 161 | **exact** — 0 / 0 | 9,346 nodes (**128×**) |

Every path-T cell: node diff **0**, edge diff **0**, edge-key stability **1.0000**,
largest SCC identical, max per-edge length delta **0**, tag losses **none**,
way-filter disagreements **none**. `bands.veto_reasons` returns an empty list —
B0 and B5, the two checks that sit outside the ladder, both pass clean.

Path R fails B1/B2a/B3 in every cell, and B2b and B4 in two. Its geometry
divergence is not float noise: **max per-edge length deltas of 208.9 m
(boulder) and 282.4 m (davis)** on edges that match by `(u, v, osmid-set)` —
pyrosm computes its own geometry and its own lengths.

Path T's exactness is total, not approximate: identical node sets, identical
edge sets, **100%** edge-key stability, largest SCC identical, and a maximum
per-edge length delta of **0.0 m** across 11,144 edges on the first cell measured
— not "within a millimetre", but bit-identical, which is what B4's 1 mm band
predicted would be the honest outcome if the transport were the only thing that
changed. A pbf stores coordinates as nanodegree integers at granularity 100 and
Overpass JSON emits seven decimal places: the same numbers, run through the same
`add_edge_lengths` call.

Path R is off by **5.6×** on bike and **16.4×** on drive. pyrosm does not collapse
geometry nodes to intersections the way `simplify_graph` does, and its `cycling`
/ `driving` network types are not osmnx's `bike` / `drive` filters. Both are
defensible choices by pyrosm; neither is the graph SPIKE-A, SPIKE-G, the scoring
weights and SPIKE-21 were calibrated against.

### 1.1 The `drive` filter reproduces SPIKE-E's defect exactly, which is correct

`boulder-drive` exists because SPIKE-E found `network_type="drive"` is a
*download* filter that silently drops `highway=track` and `highway=service`
before a way reaches the graph. On the same bbox the drive golden is **2,153**
nodes against bike's **9,581** — 22%.

Path T reproduces that to the node. **Parity with a known defect is parity.**
The local filter is parsed from `_get_network_filter`'s own Overpass QL string
rather than transcribed, so it cannot drift from osmnx and cannot accidentally
"fix" a defect that is SPIKE-E's to own. If it had fixed it, the transport swap
would have silently changed routing behaviour, which is precisely the class of
change a node count cannot see.

### 1.2 A prediction of mine failed, and that is a result

`HARNESS.md` flagged two harness variables discovered by reading osmnx's source:
the 500 m query buffer, and vertex-vs-intersects way selection. I expected the
buffer to be **load-bearing** — that a clip taken at the raw trip bbox could not
reproduce a golden whose simplification and component selection ran on a
buffered graph — and wrote verdict clause I-9 asserting the raw arm would *not*
be exact.

**It is exact.** All four path-T arms agree in every cell measured.

The reason, in hindsight: `complete_ways` keeps a selected way **whole**, so the
clip already extends past the bbox by up to a full way length — comfortably more
than 500 m for the ways that matter at a boundary. The buffer's work was already
done by the completeness strategy.

This is good news for Phase 3 (the shipped `/clip` output is sufficient as-is,
with no buffered-bbox request needed) and it is recorded here rather than
quietly corrected: clause I-9 asserted a *prediction*, not a band, and it has
been rewritten to assert the measured relationship. The bands in `bands.py` were
untouched — they never mentioned the buffer.

### 1.3 What the exactness does and does not license

It licenses one thing precisely: **§8's transport swap, implemented as path T,
needs no re-validation of SPIKE-A's golden candidate sets, SPIKE-G's ~2,800
density ceiling, the scoring weights or SPIKE-21's cue derivation** — because
the graph those were calibrated against is the graph that comes out, to the
node, the edge key and the millimetre. §11.1 told us to budget for that
re-validation; on this evidence it is not owed for the graph. (**#276** should
still run against the *candidate* path, which this spike did not touch.)

It does **not** license adopting pyrosm, and the numbers say why loudly: 5.7× to
128× node inflation, and 200–280 m per-edge geometry deltas. A Phase 3 that
reached for pyrosm would have invalidated every one of those calibrations
silently, while every node-count smoke test passed.

Two honest limits on the parity claim itself:

- **`coline`'s golden is 73 nodes.** It confirms parity across a *merged*
  source, which is worth having, but it is a thin cell — see §3.2a.
- **Four of the fifteen watched tags (`canoe`, `motorcar`, `4wd_only`,
  `climbing:access`) have zero occurrences in these bboxes**, so B5 is
  vacuously satisfied for them here. Their survival is untested, not proven.

---

## 2. Tag survival (B5) — zero losses, and the fold works

Asserted at three points, on the bytes rather than the loader's promise: the
clipped pbf read directly with pyosmium, the built graph, and the `barrier`
node→edge fold `routing/access.py` depends on. `boulder-bike`:

| tag | source in bbox | clip | golden edges | local edges |
|---|---|---|---|---|
| `surface` | 8,805 | 13,658 | 20,059 | **20,059** |
| `tracktype` | 412 | 692 | 760 | **760** |
| `smoothness` | 123 | 220 | 286 | **286** |
| `maxspeed` | 2,756 | 6,441 | 9,736 | **9,736** |
| `lanes` | 2,094 | 6,073 | 5,089 | **5,089** |
| `bicycle` | 3,291 | 4,873 | 6,409 | **6,409** |
| `foot` | 2,787 | 3,843 | 3,736 | **3,736** |
| `motor_vehicle` | 561 | 732 | 1,132 | **1,132** |
| `ford` | 6 | 6 | 4 | **4** |
| `waterway` | 418 | 467 | 0 | **0** |
| `oneway:bicycle` | 54 | 59 | 107 | **107** |
| `canoe`, `motorcar`, `4wd_only`, `climbing:access` | 0 | 0 | 0 | **0** |
| `barrier` (node → folded onto edges) | 1,138 | 1,205 | 417 | **417** |

Golden and local agree exactly on every row. Three things this table shows that
a pass/fail line would not:

- **The clip carries *more* than the bbox, by design.** `surface` is on 8,805
  ways inside the box and 13,658 in the clip — `complete_ways` keeps selected
  ways whole, so the clip reaches past the boundary. That is the property that
  made the raw-bbox arm reach parity (§1.2).
- **`waterway` is 418 in the source and 0 in both graphs.** The `bike` network
  filter excludes it, identically on both sides. A tag present in the bytes and
  absent from the graph is not a loss when the *golden* drops it too — which is
  exactly why B5 compares golden against local rather than bytes against graph.
- **`fold_node_barriers` works and is not vacuous**: 1,205 barrier nodes in the
  clip become 417 barrier-carrying edges, the same 417 on both sides. #206's
  defect — the tag requested but the fold never reaching the edge — would have
  shown here as golden 417 / local 0.

---

## 3. The clip, measured server-side on the mirror (B6/B7)

Addendum **2c** requires these be taken server-side or Q1-C is not decidable, and
`bands.clip_band` refuses PARITY to any figure whose `measured_on_mirror` is
false. These were taken through the real `/clip` endpoint, behind Caddy, on the
real Pi:

```
Raspberry Pi 5 Model B Rev 1.0 · aarch64 · 4 cores · 8,063 MB · NVMe (784 GB free)
Docker 29.8.0 · plotlines-mirror-clip:latest (611 MB) · Caddy 2.11.4
extracts pinned 2026-09-12: north-carolina (428 MB), tennessee (189 MB)
```

### 3.1 Single extract: 432 s and 2,853 MB, and the cost does not depend on the bbox

| bbox | area | output | server wall | peak RSS |
|---|---|---|---|---|
| `-78.70,35.75,-78.60,35.82` | ~64 km² | 5,774,074 B | **432.64 s** | **2,853 MB** |
| `-78.7,35.7,-78.5,35.9` | ~390 km² | 16,851,413 B | **461.87 s** | 3,008 MB |
| `-78.70,35.75,-78.60,35.82` (concurrent) | ~64 km² | 5,774,074 B | 627.19 s | *(contaminated, #374)* |

A bbox **6× larger in area** and 2.9× larger in output cost **6.8% more wall
time**. The clip is O(region extract), not O(bbox): `apply_file(locations=True)`
scans the whole source and `BackReferenceWriter` scans it again, and PBF blocks
are id-ordered rather than spatially ordered, so there is nothing to skip.

Against B6's pre-registered ≤20 s PARITY / ≤60 s outer band, **432 s is ~7× the
outer band** — on a step that sits upstream of an already-measured 36.7–116.6 s
graph build, inside FR120's "declare the extent" moment.

Peak *system* memory on the Pi reached **5,318 MB of 8,063** for one clip with
nothing else running.

Filed as **[#375](https://github.com/gnfrazier/plotlines/issues/375)**.

**How it scales with the extract — and the two ways I got this wrong before
measuring it properly.**

| extract | size | bbox | wall | peak RSS | output |
|---|---|---|---|---|---|
| wyoming | 94 MB | 26 km² | 65-71 s | 1,896 MB | 1.13 MB |
| colorado | 381 MB | 40 km² | 230-246 s | 2,842-2,867 MB | 2.9-3.3 MB |
| wisconsin | 293 MB | 250 km² | 129-140 s | **4,914 MB** | 0.48-0.49 MB |
| california | 1,328 MB | 27 km² | **553.6 / 553.5 s** | 4,403-4,436 MB | 2.8-3.0 MB |

**Wall time tracks the extract, and only the extract.** The two California rows
are raw and buffered extents over the same source: **553.6 s and 553.5 s**, a
tenth of a second apart for different bboxes. Wisconsin's 250 km² bbox — six
times Colorado's area — clips in *half* Colorado's time, because Wisconsin is
the smaller file. This is the O(extract) result stated as plainly as data can
state it.

**Peak RSS does not track anything so cleanly, and my first two claims about it
were both wrong.** I originally extrapolated linearly and predicted California
would need ~10 GB and be unclippable on an 8 GB Pi; it needed 4.4 GB. I then
wrote that the cost was "sublinear in extract size"; Wisconsin refutes that too
— a 293 MB extract peaked at **4,914 MB**, *higher* than California's 1,328 MB
extract, while producing a sixth of the output bytes.

What the four points actually support is narrower and less comfortable:

- RSS ranged **1.9-4.9 GB** across four extracts with **no monotonic
  relationship** to file size, bbox area, or output size.
- So the clip's memory is **not capacity-plannable from the extract's size**,
  which is the property an operator would most want it to have. On an 8 GB Pi
  that also serves the static tree, "somewhere between 2 and 5 GB, and we
  cannot tell you which from the inputs" is the honest statement.
- The likely mechanism is that `flex_mem`'s node-location table is sized by id
  *range* and density rather than count, and switches representation — but this
  spike measured four points and did not instrument libosmium, so that is a
  hypothesis and is labelled as one.

The load-bearing conclusion is unchanged and is about time, not memory: **"it
does not fit in RAM" is not an accurate statement of the problem and should not
be carried forward. "It takes seven to ten minutes, and you cannot predict its
memory from its inputs" is.**

### 3.2 Two extracts: it does not complete. Six attempts, six failures.

| cell | spans two extracts | result |
|---|---|---|
| `raleigh` | no | 2/2 **200 OK** |
| `asheville` | yes | 0/2 — **502** |
| `nc-tn` | yes | 0/2 — **502** |

Plus two occurrences before this harness existed, with the identical signature.

```
11:20:14.636  clip bbox=(-82.6,35.55,-82.5,35.62) spans 2 extracts — merging before clip
11:20:23.457  mirror-clip starting ...                      <- process restarted
```

Dead in **8.8 seconds**, no traceback, no completion line. Host memory over that
window: 2,248 MB → **6,163 MB** → 775 MB. `MergeInputReader.add_file` buffers
every object from every input before anything is written.

`docker inspect` says `OOMKilled=false ExitCode=0`, which is misleading — the
container's PID 1 is `uv` and it exits 0 after its child is killed, so Docker's
OOM flag never fires.

**And this is not an edge case on this mirror.** `select_covering_extracts`
compares *rectangular* PBF header boxes:

| extract | lon | lat |
|---|---|---|
| north-carolina | −84.32190 … −73.73960 | 32.55781 … 36.58979 |
| tennessee | −90.31329 … −81.64416 | 34.98269 … 36.68075 |

They overlap across lon −84.32…−81.64. Every bbox in **western North Carolina**
— the product's flagship region, the one the `20250101-wnc` basemap stand-in
covers — selects both extracts and takes the merge path. The Asheville bbox above
is ~60 km inside North Carolina.

Filed as **[#376](https://github.com/gnfrazier/plotlines/issues/376)**.

**What the merge actually costs**, measured on a dev box with headroom — the Pi
crash could only bound it from below:

| | |
|---|---|
| inputs | colorado 381 MB + wyoming 94 MB = **475 MB** |
| merged output | 476 MB | 
| wall | **20.6 s** |
| process RSS, before → peak | 1,203 MB → **6,915 MB** |
| **merge allocation** | **~5.7 GB for 475 MB of input — ~12×** |

At ~12×, the pinned NC + TN pair (617 MB) wants ~7.4 GB; the Pi had ~5.8 GB
available. The host trace climbing 2,248 → 6,163 MB in five seconds is that
arithmetic playing out.

Two things follow. **No Pi-class host survives a two-extract merge of adjacent
US states** — 617 MB of input needing 7.4 GB is not a tuning problem. And **the
merge is not the expensive part**: 20.6 s against 432–553 s to then clip the
result. Inverting the order — clip each extract separately, merge the two 3–6 MB
*outputs* — avoids the large allocation entirely, and the outputs are already
the size `MergeInputReader` is the right tool for.

### 3.2a A limitation of the local border cell, stated rather than glossed

The `coline` cell (CO/WY line on US 287) was chosen for where it sits, not for
what is on it, and its golden is **73 nodes**. Parity across a merged source is
still worth measuring there, but with a graph that small the cell is a **weak
test of whether a bbox cut severs ways** — there is barely a network to sever.

The substantive §11.7 evidence is the Pi's NC/TN pair, which is the review's own
worked example, and there the question is moot in a stronger way: the clip never
completes, so "do crossing ways survive" cannot be asked until #376 is fixed.
B7 is graded on that, not on `coline`'s 73 nodes.

Picking a border bbox with a real network on it is a cheap improvement to this
spike and is worth doing when #376's fix is verified — a rerun then would
measure both the fix and the parity question in one pass.

### 3.3 What the strategies cost (§7.1(3), addendum L1)

`simple` / `complete_ways` / `smart` are osmium-tool concepts and osmium-tool is
GPL-3.0, so L1 requires the equivalent behaviour be **implemented through
pyosmium's API and compared**, not selected by flag. It was. Colorado extract
(381 MB), Boulder bbox, dev box:

| strategy | extent | wall | peak RSS | output | nodes | ways |
|---|---|---|---|---|---|---|
| `simple` | raw | 280.4 s | 1,109 MB | 2.30 MB | 247,205 | 37,725 |
| `complete_ways` | raw | 246.3 s | 2,842 MB | 2.93 MB | 296,832 | 42,623 |
| `smart` | raw | 351.1 s | 2,842 MB | 2.94 MB | 296,833 | 42,623 |
| `simple` | buffered | 284.1 s | 1,114 MB | 2.67 MB | 295,041 | 44,362 |
| `complete_ways` | buffered | 230.2 s | 2,867 MB | 3.28 MB | 343,201 | 49,068 |
| `smart` | buffered | 354.1 s | 2,860 MB | 3.28 MB | 343,202 | 49,068 |

**`smart` is not worth it.** +54% wall time over `complete_ways` for exactly one
extra node, no extra ways, identical output size. Its relation-closure pass —
chasing relations referenced by kept relations to a fixpoint — finds nothing at
trip-bbox scale. The shipped choice (`complete_ways`) is correct.

**`complete_ways` is the floor, not one of three options.** osmnx's query is
`(way<filter>(poly:…);>;);out;` and that `>` recurses to every member node of
every matched way, including nodes outside the polygon. Overpass has been
returning complete ways since the first graph build, so `simple` — which leaves
dangling node references, 417 such ways in a Wyoming sample — cannot reach
parity by construction.

**Where the memory actually goes**, by differencing variants on one extract:

| variant | peak RSS |
|---|---|
| `simple` (location index, no back-references) | 1,109 MB |
| `complete_ways` (shipped) | 2,842 MB |
| `complete_ways` + `sparse_file_array` location index | 1,770 MB (−6.6%) |
| `complete_ways` + `dense_file_array` | fails: `mmap (remap) failed` |

~77% of the cost is the `BackReferenceWriter` pass, **not** the node-location
table. Moving the location index to disk — the obvious first guess — recovers
almost nothing, and `dense_file_array` is structurally wrong here because it
allocates across the whole OSM id range. Any fix has to target the
back-reference pass.

---

## 4. Q6's egress arithmetic (B8) — Q1-C makes it a rounding error, confirmed

§12 closes by naming this "the only open question with no measurement attached."
Here is the measurement. Clip sizes are the `complete_ways` output for a real
trip bbox in each region:

| region | extract | trip bbox | clip | ratio |
|---|---|---|---|---|
| colorado | 381.4 MB | 39.6 km² | 2.931 MB | **130×** |
| california | 1,328.0 MB | 27.0 km² | 2.757 MB | **482×** |
| wisconsin | 292.7 MB | 249.8 km² | 0.477 MB | **614×** |
| *mean* | 667.4 MB | | 2.055 MB | **325×** |

Against a **stated guess** at trips-per-Author-per-region (1 / 3 / 10) and
Author population (100 / 1,000 / 10,000), at $0.09/GB origin egress:

| authors × trips | pulls | Q1-A/B: region extracts | Q1-C: bbox clips |
|---|---|---|---|
| 100 × 1 | 100 | 66.7 GB ($6.01) | 0.21 GB ($0.02) |
| 1,000 × 3 | 3,000 | 2,002 GB ($180.19) | 6.17 GB ($0.55) |
| 10,000 × 10 | 100,000 | **66,736 GB ($6,006)** | **206 GB ($18.50)** |

**§11.5's cost curve is real and Q1-C flattens it by ~325×.** The population and
trip-rate numbers are guesses and are labelled as such; the **ratio** is
measured, and it is the figure that survives being wrong about the population.
At 10,000 Authors the difference is roughly $6,000/month versus $18.50 — which
is why the decision reads as a rounding error rather than a budget.

Two caveats that belong with the number:

- **This prices bytes, not compute.** Q6 landed on **D + C** precisely because
  clipping server-side trades bandwidth for CPU, and §3 above is what that CPU
  now costs: ~432–553 s per clip. The egress win is real and the compute bill
  it buys is the thing this spike found unaffordable.
- The ratio varies 130×–614× with bbox-to-region size, so a single mean hides a
  factor of five. `wisconsin` has the best ratio despite the largest bbox,
  because its extract is small and its network sparse.

---

## 5. The Q1-D trigger (B9) — **D is triggered** on the pre-registered band

§6.7 named one thing that would force the D fallback — *"Author edits the bbox
on a mountain with no signal"* — and said it is "a measurement, not a guess, and
SPIKE-I is where it gets made."

What the client holds after Phase 3 is the **built graph**, not the clip: Q1-C
removed the client-side native dependency, so re-clipping a `.osm.pbf` offline
is not available at all. Serving an edited bbox offline therefore means
truncating the held graph, which is pure osmnx/networkx. Against the edit
distribution fixed in `HARNESS.md` §4 before the run (shrink 0.5–0.95, nudge
0–25% of span, grow 1.05–2.0, equal weight, seed 265, 200 each):

| cell | shrink | nudge | grow | **overall servable** |
|---|---|---|---|---|
| boulder-bike (urban) | 100% | 34% | 10% | **48.2%** |
| viroqua-bike (rural) | 100% | 13% | 1% | **38.0%** |

**Band: "C holds" required ≥90%. Measured 38–48%. → D is triggered.**

The mechanism is geometric and unsurprising once seen: the held graph covers the
trip bbox plus osmnx's 500 m buffer, which on a 0.07° box is ~7% of its span. A
nudge larger than that leaves coverage. Only shrinks are reliably servable.

**And within coverage, fidelity is imperfect.** On a median shrink — an edit the
coverage test calls fully servable — truncating the held graph does **not**
reproduce a fresh build:

| cell | truncated | fresh golden | difference |
|---|---|---|---|
| boulder-bike | 6,371 nodes | 6,409 | 75 missing, 37 extra |
| viroqua-bike | 1,491 nodes | 1,516 | 27 missing, 2 extra |

~0.6% and ~1.6% node differences. The held graph was already simplified and
component-pruned for the *original* bbox, so re-truncating it loses the boundary
context a fresh build would have had. So offline editing is not merely limited
in range — inside its range it returns a slightly different graph, quietly.

**What this means for Q1.** The D fallback exists to let a client pull a region
extract deliberately for a trip it knows is coming. B9 says the offline case
that would motivate it is real: 52–62% of plausible edits cannot be served at
all. But **D is not obviously the answer either**, because §3's findings mean a
client pulling a region extract would then need to clip it locally — which is
the native dependency Q1-C removed, at 432–553 s and 1.9–7.2 GB on hardware far
weaker than the mirror. The honest statement is that **B9 triggers D's
precondition while §3 undermines D's viability**, and that tension is
[#278](https://github.com/gnfrazier/plotlines/issues/278)'s to resolve, now with
numbers on both sides instead of neither.

---

## 6. What this decides

1. **Phase 3's transport swap is safe — as a transport swap.** Implement it as
   path T: read the clipped `.osm.pbf` into OSM elements in Overpass's response
   shape and hand them to osmnx's own `_create_graph` and post-download
   pipeline. Do **not** adopt pyrosm or any second graph builder. On this
   evidence the calibration re-validation §11.1 told us to budget for is not
   owed for the graph.
2. **§6.7's clip does not survive contact and blocks Phase 3 as written.**
   ~432–553 s per bbox, independent of bbox size; peak RSS 1.9–7.2 GB with no
   predictable relationship to inputs; **0 of 4** two-extract requests complete.
   #375 and #376 carry the measurements and the fix directions. Until they are
   addressed, the clip is not a step that can hide inside the existing readiness
   wait, and FR121's honest progress channel has nothing honest to report.
3. **Q6 is answered: ~325× egress reduction, measured.** The question closes as
   a rounding error, and §12-Q6's owed arithmetic is discharged (§4).
4. **Q1's D precondition is triggered and D's viability is undermined at the
   same time.** 38–48% of plausible offline edits are servable against a ≥90%
   band, *and* the local clip that D implies is the thing §3 found unaffordable.
   → #278, with numbers.
5. **A23/A23a can be closed with a real number** — the "local extracts remove
   the variance, still unmeasured" clause in punch-list 2A.3 now has a
   measurement, and it is not the happy one. → #287.
6. **`complete_ways` is the right strategy and the only viable one.** `smart`
   costs +40–54% wall time for ≤1 extra node across two very different sources;
   `simple` cannot reach parity because Overpass has always returned complete
   ways. On a merged source all three cost identically, so strategy selection
   cannot rescue the border case.

---

## 7. Issues filed

| | |
|---|---|
| [#374](https://github.com/gnfrazier/plotlines/issues/374) | `X-Plotlines-Clip-Peak-Rss-Kb` is a process high-water mark, not a per-clip figure |
| [#375](https://github.com/gnfrazier/plotlines/issues/375) | `/clip` wall time is O(region extract) — 432 s per trip bbox against a 20 s budget |
| [#376](https://github.com/gnfrazier/plotlines/issues/376) | `/clip` dies on any two-extract bbox; rectangle coverage selection fires it for all of WNC |

## 8. What went right, and should be said

- **#364's licence obligation is met in practice.** Every `/clip` 200 carried
  `X-Plotlines-Data-Licence: ODbL-1.0`, the attribution, and
  `Link: <https://opendatacommons.org/licenses/odbl/1-0/>; rel="license"`,
  in US-ASCII as required. Verified live, not by reading the code.
- **The shipped clip is genuinely pyosmium-only.** No `osmium` binary in the
  image, nothing shells out to one — addendum **L1**'s acceptance criterion for
  this spike, checked on the running container.
- **`geofabrik_pull.py` behaved exactly as specified** pulling four extracts:
  identified, md5-verified, atomic, and it declined to re-pull inside its cadence
  window.
