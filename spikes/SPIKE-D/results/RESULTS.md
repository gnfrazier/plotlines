# SPIKE-D — Layer extraction and POI indexing timing

**Run:** 2026-08-27/28 · **Issue:** [#159](https://github.com/gnfrazier/plotlines/issues/159)
**Covers:** PRD **FR121**, FR91 (amended), FR120 · stories **N1**, **N2**, **M12a** · ARCH §8.3 (breaking **B1**), **D34**, risk **A23**

---

## Verdict

**D34 is not confirmed. It is inverted.**

ARCH D34 rests on one unmeasured sentence — *"Ordering is a reordering of
existing startup work, not new work (SPIKE-D confirms)."* The ordering it
specifies is layer extraction first, elevation enrichment second, on the
premise that the first is quick and the second is the "blocking, minutes-long
operation" (FR91). Measured on a real trip bbox:

| | 704 km² trip bbox |
|---|---|
| **Layer extraction + POI indexing** | **15.8 s** best of two samples, **178.5 s** worst |
| **Elevation enrichment** | **8.8 s** |
| **Graph build** (what routing actually waits on) | **36.7 s** |

Elevation enrichment is **0.56×** extraction — the *shorter* half. FR121 puts
the fast operation second and the slow, high-variance one in front of the
Author. And the thing that actually gates routing is not elevation at all: it
is the **graph build**, which is longer than both and which the shipped sidecar
already treats correctly (`RegionState.build`).

**Three of the issue's five questions came back positive, two negative:**

| # | Question | Result |
|---|---|---|
| 1 | Is the reorder cheap, as D34 assumes? | **No** — see above. The premise is backwards, though the *conclusion* (don't block the app) survives on other grounds. |
| 2 | Can the two run concurrently without starving extraction? | **Yes.** Notability scoring is unaffected (×1.15). The sidecar's HTTP surfaces take a bounded ~30 ms tax. |
| 3 | Does the `/health` contract hold, including a failing layer? | **Shipped app: 3 of 8 clauses.** The per-*layer* half of §8.3 has no mechanism; one bad layer 422s the whole extraction. A prototype passes 9/9. |
| 4 | What does a candidate pull cost public Overpass? | **Not what A23 says.** A candidate pull is *lighter* than a graph build (×0.43 time, ×0.78 bytes). The real cost is **variance — up to 21× run to run on the identical query**. |
| 5 | Does enlarging re-extract only the added area? | **Correct, but not faster.** The partition is exact (873 = 873 candidates, 0 missing, 0 extra); splitting one query into two made it **7× slower** on public Overpass. |

**What FR121 should be rewritten around:** the honest wait at trip initiation
is *extraction*, its length is unpredictable rather than long, and the
capability that stays not-ready longest is *routing* — for reasons that have
nothing to do with elevation.

---

## Substrate

`regions.TRIP` — the Grandfather Mountain / Linville Gorge window, 28.8 × 24.4 km,
**704 km²**. Not a CI fixture: it is the box PRD §5.4a walks its worked review
pass against ("An Author planning a Blue Ridge tour draws a bbox…"), and it is
SPIKE-B's `WORKED_PASS`, so the two spikes' numbers compose — SPIKE-B measured
what co-location costs *over* a candidate set, SPIKE-D measures what it costs
to *get* one.

Two further extents: **`ENLARGED`** (1,799 km², TRIP grown north-east to take
in Boone — FR120's enlargement, chosen so the added area is an L rather than a
strip) and **`TOUR`** (8,815 km², the Asheville–Boone Parkway corridor; ARCH
§4.4's "200 km multi-day extent", identical to SPIKE-B's `brp`).

Everything measured runs the product's own code: `OsmLayerProvider.fetch`,
`score_notability`, `regions.ensure_graph`, and the real `create_app`.

**Two stand-ins, both load-bearing on how the numbers should be read.**

1. **Elevation source.** D20/FR85 pin production elevation to GEDTM30 via
   OpenTopography, whose acquisition pipeline is gated on FR87 (#148) and does
   not exist to time. This uses AWS Terrain Tiles (Terrarium) at z12 — ~30 m/px
   at this latitude, the same ground resolution as GEDTM30, and keyless. It
   measures the shape and scale of enrichment cost without introducing a second
   production source, which D20 forbids. **§1's inversion does not depend on
   the substitution being exact** — it would survive GEDTM30 being 5× slower —
   but the specific 8.8 s does.
2. **Plugin layers.** N5's real plugin datasets do not exist, so §3 uses a
   slow one, an unlicensed one, and one whose upstream times out. What point 3
   asks to exercise is the contract, and the contract has to hold before any
   real plugin is written.

---

## §1 — D34: the reorder is not cheap, and it is pointed the wrong way

`probe.py --phase extract --phase graph --phase elevation`

### Extraction to authorable

`fetch_s` is `OsmLayerProvider.fetch` (network + osmnx's GeoDataFrame build +
conversion to `RawFeature`). `index_s` is `score_notability`. They are reported
separately because only one of them is a function of the Overpass commons' mood.

| extent | km² | fetch | index | **total** | candidates |
|---|---:|---:|---:|---:|---:|
| trip / default 3 layers | 704 | 2.69 s | 0.002 s | **2.69 s** | 175 |
| trip / all 6 layers | 704 | 15.80 s | 0.002 s | **15.80 s** | 288 |
| trip / all — warm cache | 704 | 1.75 s | 0.002 s | **1.75 s** | 288 |
| enlarged / all 6 layers | 1,799 | 13.89 s | 0.007 s | **13.90 s** | 873 |
| tour / default 3 layers | 8,815 | 33.21 s | 0.020 s | **33.23 s** | 1,258 |
| tour / all 6 layers | 8,815 | 73.51 s | 0.034 s | **73.55 s** | 2,979 |

Fastest of two samples per row; the spread is §2's subject.

**POI indexing is free, everywhere.** 2 ms at trip scale, 34 ms at the largest
extent FR120 permits. Independently: `tour_scale.py` runs `score_notability`
over SPIKE-B's committed 8,815 km² pull — **31,818 features → 2,968 candidates
in 51 ms**, no query issued. So "layer extraction **and POI indexing**" is one
phrase covering two costs with nothing in common, and only one of them exists.
**Every second of FR121's first phase is network.**

### Enrichment, and what actually gates routing

| stage | time |
|---|---:|
| DEM acquire (fetch + mosaic + reproject + write, 4.2 MB GeoTIFF) | 8.73 s |
| node sampling (4,538 nodes, all populated, 381.6–1,548.4 m) | 0.10 s |
| edge grades (10,602 edges) | 0.01 s |
| **enrichment total** | **8.84 s** |
| graph build, TRIP (4,538 nodes / 10,602 edges, 7.1 MB wire, 352 MB peak) | **36.72 s** |
| graph build, ENLARGED (19,238 / 44,389, 25.0 MB wire, **1,164 MB peak**) | **116.59 s** |

Enrichment at trip-bbox scale is **9 seconds**, and 99% of it is acquiring the
DEM. The sampling and grade computation FR91 calls "blocking, minutes-long"
are **110 ms combined**. Nothing in this repository has ever measured the claim
FR91 makes; this is the first attempt, and it does not reproduce it.

**Two consequences the build should take:**

- **The long pole for routing is the graph, not elevation** — 36.7 s at trip
  scale, 116.6 s at 1,799 km². The shipped sidecar already has this right
  (`RegionState.graph_state` gates `routing`; `elevation` is a fixed
  not-ready). D34's *prose* is what disagrees with the code.
- **ENLARGED's graph build peaked at 1,164 MB.** SPIKE-14 put the client's
  budget near 1 GB. A 1,799 km² bbox is not an extreme request under FR120, and
  the sidecar transiently doubles the app's footprint building its graph. Not
  measured further here; flagged.

### Verdict on D34

Judged against a ceiling of **20 s**, declared in `analyze.py` before the run:

- extraction within ceiling, best sample — **true** (15.8 s)
- extraction within ceiling, worst sample — **false** (178.5 s)
- enrichment is the longer half — **false** (8.8 s vs 15.8 s)
- **D34 confirmed — false**

The failure is not that extraction is slow. It is that extraction is
*unpredictable*, and that the operation FR121 hides behind it is the cheap one.

---

## §2 — A23: right to worry, wrong about why

`probe.py --phase extract` (two samples), `overpass_meter.py`

A23: *"Candidate extraction overloads public Overpass. It is a heavier query
than graph building, which SPIKE-04 §8 already could not complete without
tiling and retries."*

### The comparison A23 asserts, finally made

| extent | graph build | candidate pull | ratio |
|---|---|---|---|
| trip, 704 km² | 36.72 s / 7.06 MB | 15.80 s / 5.48 MB | **×0.43 time, ×0.78 bytes** |
| enlarged, 1,799 km² | 116.59 s / 24.96 MB | 13.89 s / 6.11 MB | **×0.12 time, ×0.24 bytes** |

**A candidate pull is the lighter query, and the gap widens with area.** A
graph pull asks for every way in the bbox with its full node geometry; a
candidate pull asks for a handful of tag families with `out center`. A23's
premise is measurably backwards, and the mitigation it prescribes was written
to defend against the wrong thing.

### What is actually expensive: variance

Same query, same endpoint, two runs an hour apart:

| run | n | min | max | **spread** | retries per sample |
|---|---:|---:|---:|---:|---|
| sweep 176 km² | 2 | 8.79 s | 185.86 s | **×21.1** | 0, 2 |
| trip / all 6 layers | 2 | 15.80 s | 178.52 s | **×11.3** | 2, 0 |
| tour / default 3 layers | 2 | 33.23 s | 191.08 s | ×5.8 | 1, 0 |
| tour / all 6 layers | 2 | 73.55 s | 317.81 s | ×4.3 | 2, 0 |
| sweep 70 km² | 2 | 3.05 s | 12.55 s | ×4.1 | 0, 0 |
| enlarged / all 6 layers | 2 | 13.90 s | 19.58 s | ×1.4 | 0, 0 |
| trip / all — warm cache | 2 | 1.75 s | 1.83 s | ×1.0 | 0, 0 |

**A 176 km² box took 8.8 s once and 185.9 s the next time.** Every large
number here is a 429/504 throttle and osmnx's 55-second retry sleep, not query
work. The one row with no spread is the cached one.

So the design constraint is not *how large a bbox may be*. It is that **any
uncached extraction may take three minutes for reasons entirely outside the
product**, and the UI has to be honest about a number it cannot predict.

### Area scaling is sub-linear — bigger boxes are *cheaper* per km²

| extent | km² | total | **s / 1,000 km²** | candidates / 1,000 km² |
|---|---:|---:|---:|---:|
| sweep | 70 | 3.05 s | 43.3 | 411.9 |
| sweep | 176 | 8.79 s | 49.9 | 369.1 |
| sweep | 352 | 11.94 s | 33.9 | 400.5 |
| trip | 704 | 15.80 s | 22.4 | 409.0 |
| enlarged | 1,799 | 13.90 s | 7.7 | 485.3 |
| tour | 8,815 | 73.55 s | 8.3 | 338.0 |

Per-query overhead dominates below ~1,000 km². **This is the argument against
aggressive tiling**, and it is measured rather than assumed.

### Whole versus tiled — tiling is not a speed-up

| | requests | total | features | tile failures |
|---|---:|---:|---:|---:|
| TRIP whole | 1 | **15.80 s** | 429 | — |
| TRIP tiled 2×2, run 1 | 4 | 166.62 s | 435 | 0 |
| TRIP tiled 2×2, run 2 | 4 | 34.39 s | 435 | 0 |

Tiling was slower in both runs. It multiplies exposure to the throttle that
causes the variance: in run 1 three tiles took 16–18 s and one took **114.7 s**.
The 435-vs-429 feature difference is duplicates across tile edges, which a
tiled path must dedupe.

**But the multi-day extent is already tiled, one level down.** osmnx splits any
bbox above `settings.max_query_area_size` (2,500 km²) on its own: TOUR became
**6 requests** without anyone asking. So the question "should we tile?" is
partly already answered inside the dependency, and the answer for the range
FR120 permits is *only above 2,500 km²*.

### Recommended access pattern (revising A23)

1. **Do not tile below ~2,500 km².** Sub-linear scaling makes it a
   pessimisation, and osmnx already splits above that threshold.
2. **Retry-with-backoff is the load-bearing mitigation, not tiling.** Every
   slow observation here is a throttle.
3. **Cache aggressively, bbox-scoped** (ARCH §4.2, FR94). A warm re-read is
   **1.75 s against 15.8 s**, and it is the only measurement with no variance
   (×1.0 across samples). The cost is modest: the trip bbox's all-layer
   response is 5.5 MB of JSON on disk, the multi-day extent's six 28.5 MB.
4. **Multiple endpoints, and coverage-checked.** See below.
5. **Prefer local extracts for repeatedly-used regions** — *not confirmed
   here*; see Left open.

### Two dependency defects this spike hit, both inherited by the product

Both live in `osmnx`, which `OsmLayerProvider.fetch` calls, so the product has
them today.

1. **The rate limiter recurses forever against an instance with no slot
   limit.** `_get_overpass_pause` does not parse the status page; it takes
   **line index 4** and branches on its first word. On an instance reporting
   `Rate limit: 0` that line is the header `"Currently running queries (pid,
   …)"`, which osmnx reads as *the server is busy with my query* — so it
   sleeps 5 s and calls itself, against a header that never changes. Observed:
   20 minutes in `hrtimer_nanosleep`, 3 s of CPU, **no query ever sent**.
   `common._osmnx_can_pace` detects it; the product has no equivalent.
2. **The 429/504 retry has no attempt limit.** `_overpass_request` sleeps 55 s
   and recurses indefinitely. A pull against a busy instance does not fail, it
   spins. Every timed run here is wrapped in `common.Deadline` for that reason.

Together these mean **A23's mitigation cannot be implemented as a URL swap.**
`osmnx.features_from_bbox` reads a single `settings.overpass_url`; there is no
failover, and adding one requires handling both defects above.

And the failover must be **coverage-checked, not liveness-checked**:
`overpass.osm.ch` answers HTTP 200 promptly and holds only Switzerland, so a
North Carolina query returns `{"elements": []}`. A list ordered by liveness
would silently tell an Author their trip area contains nothing — a worse
failure than an error, and exactly the class of silent substitution issue #154
was filed over on the routing side.

### The evening this ran is itself the evidence

The first measurement attempt issued one uncached whole-extent TOUR pull
against `overpass-api.de`. It ran **past 30 minutes without returning**, and
from that point the host **refused TCP on 443 from this machine** and stayed
that way for the remaining hours of the session. `overpass.kumi.systems` and
`overpass.private.coffee` returned 500/502 throughout; Geofabrik returned
502/503. Every number in this document was ultimately collected against
`maps.mail.ru/osm/tools/overpass`.

A23 rates the risk **Medium**. One spike's measurement run exhausted the
primary public endpoint's tolerance in a single query. A product doing this on
every trip initiation should not plan to use it at all.

---

## §3 — The `/health` contract: shipped 3 of 8, prototype 9 of 9

`health.py --json` · offline, no network

Nine clauses drawn from N2's AC and §8.3's four rules, one assertion each, run
against **the real `create_app`** (post-#154) and against a prototype carrying
`plugin_layers.LayerRegistry` behind `capabilities.layers`.

| clause | source | shipped | prototype |
|---|---|:--:|:--:|
| C1 layers ready immediately | §8.3, N2 | ✅ | ✅ |
| C2 `per_layer` present | N2, §8.3 | ✅ | ✅ |
| C3 slow plugin layer shows `loading` while built-ins are ready | N2 AC | ❌ | ✅ |
| C4 failure names the layer **and** the reason | N2 AC, §8.3 | ❌ | ✅ |
| C5 a failed layer does not gate the capability | N2 AC | ❌ | ✅ |
| C6 extraction survives one bad layer | N2 AC | ❌ | ✅ |
| C7 response names the unavailable layers | N2 AC, M13 | ❌ | ✅ |
| C8 a failed *region* leaves layers ready | §8.3 B1 | ✅ | ✅ |
| C9 a `loading` layer settles to `ready` | N2 AC, FR121 | — | ✅ |

**#154 built the right thing and stopped one level short.** Per-capability
readiness is correct; per-*region* routing readiness is correct; B1's rule that
one capability's failure never blocks another holds (C8 passes on a region that
settles to `failed:` with layers still ready). What does not exist is the
per-*layer* half, and it does not exist because at the time there was nothing
for it to describe: every layer is built-in, synchronous, and served by **one**
provider covering all six.

That single-provider shape is the actual defect, and it is bigger than a
reporting gap:

- **`per_layer` is a constant.** `{layer: "ready" for layer in sorted(LAYERS)}`.
  Today the constant is *true*. There is no seam at which a plugin layer could
  ever report `loading` or `failed:licence_missing` — the two values §8.3's own
  example prints.
- **One bad layer takes the other five with it.** `GET /candidates` wraps one
  provider call in one `try` and raises **422 for the whole request**. Measured:
  a live set of six built-in layers plus one failing plugin returned **HTTP 422
  and zero candidates**, where the prototype returned **200 with the built-in
  candidates and `layers_unavailable: {"plugin_crags": "failed:TimeoutError"}`**.
  N2's AC — *"one plugin layer failing to load never blocks the others or the
  workspace"* — is currently false in the strongest possible way.
- **The provider's return type has no room for the answer.** `fetch` returns a
  bare `list[RawFeature]`. "Which layers did I actually get?" has nowhere to
  live, so the only available signal is an exception, which is why the whole
  request dies. The prototype returns `(features, per_layer_error)`; that
  signature change is the finding, not the state machine around it.
- **Licence must be checked at registration, not at fetch** (ARCH §12.2/D45).
  The prototype registers an unlicensed provider straight to
  `failed:licence_missing` and never queries it, so the Author sees why in the
  picker rather than discovering it as an empty result.

`plugin_layers.py` is deliberately a spike artifact rather than a patch to
`core/`. **N2 is the story that builds this**; what SPIKE-D owes it is a
demonstrated shape and the two findings above.

One design note the prototype forced: `capabilities.layers.ready` is
`any(ready)`, not `all(ready)`. An `all()` would let one slow plugin re-impose
the global flag B1 exists to remove.

---

## §4 — Concurrency: extraction is not starved; the ETA is

`concurrency.py --extra-samples 500000 --requests 300 --index-passes 20`

Real `create_app` served by **real uvicorn** on loopback (not `TestClient`,
which runs the app in a portal thread and would confound the scheduling this
measures), with enrichment on a **daemon thread** — where `RegionState.build`
already puts region work. Substrate: the TRIP graph and DEM built above.
Measurements are **interleaved**, each round doing one index pass plus a burst
of requests, so every metric sees the same mixture of enrichment's phases.

| | solo | under enrichment | |
|---|---:|---:|---|
| `score_notability` (429 features) | 0.9 ms | 1.0 ms | **×1.15** |
| `GET /health` p50 / p95 / max | 1.0 / 1.5 ms | 30.5 / 63.5 / 113.0 ms | ×30 |
| `GET /layers` p50 / p95 | 1.0 ms | 29.8 / 59.4 ms | ×30 |
| `POST /candidates/score` p50 / p95 | 4.9 ms | 52.9 / 102.0 ms | ×11 |
| one enrichment pass | 7.86 s | 23.30 s | **×2.96** |

**The concurrency premise holds.** Enrichment does not starve extraction —
notability scoring on the main thread is unaffected at ×1.15. The Author's
surfaces take a real but bounded tax: p50 ~30 ms, p95 ~64 ms, worst observed
113 ms. Under 100 ms at the median is not felt.

The contention is asymmetric, and the asymmetry is the useful part. Tight
main-thread Python holds the GIL in long stretches and sails through; **uvicorn's
event loop needs frequent short acquisitions and is repeatedly preempted**. So
the cost of background enrichment lands on *request latency*, not on
computation — which is invisible to any benchmark that measures the computation.

**And the finding with a build consequence: enrichment takes ×2.96 longer while
the Author is working.** FR121's indicator promises *"terrain data loading —
routing available in about 3 minutes."* That estimate will be wrong in the
direction that matters, and wrong **precisely when the Author is busiest**,
because their own activity is what inflates it. `app.py:55` already says
`GRAPH_ESTIMATED_S` is a heuristic and that *"SPIKE-D is where that would come
from"* — this is that answer: **a fixed constant cannot be honest here.** The
estimate has to be derived from observed progress under actual load, or the
indicator should state a range rather than a number.

---

## §5 — FR120/N1: enlargement is exact, and slower

`probe.py --phase enlarge`

`regions.rect_difference` decomposes the enlargement into disjoint rectangles —
north strip, south strip, then west/east strips of what remains, so no corner
is double-counted. TRIP → ENLARGED adds **1,095 km² in 2 rectangles, 61% of the
new extent**.

**Correctness — exact, twice over.**

| check | result |
|---|---|
| offline partition of the cached full-extent pull | 288 + 585 = **873**, 0 missing, 0 extra, 0 features in two rectangles |
| live incremental extraction, union vs full re-extract | **873 = 873**, 0 missing, 0 extra |

The offline check isolates the geometry from Overpass; the live run confirms
the server agrees. N1's *"enlarging re-extracts only the added area"* is
buildable and returns exactly the right candidate set.

**Speed — the opposite of the intent.**

| | queries | time |
|---|---:|---:|
| incremental (added area only) | 2 | **113.9 s** (north strip 105.0 s, east strip 8.9 s) |
| full re-extract of the new extent | 1 | **13.9 s** |

Seven times slower. Two causes, both already established above: per-query
overhead dominates below ~1,000 km² (§2's scaling table — the added area is
1,095 km² split into 699 and 396), and **two queries is two chances to be
throttled**, which is what the 105-second north strip was.

**So N1's AC should be read as a correctness requirement, not a performance
one.** The reason not to re-extract the whole enlarged bbox is that it is
wasteful of the commons and discards a cached result — both good reasons. It is
not that it is faster for the Author, and a build that promises it will be is
promising something the network does not deliver.

---

## Left open, deliberately

- **Local extracts.** A23's third mitigation — *"prefer local extracts for
  repeatedly-used regions"* — is **not measured**. It needs a PBF source and a
  `LayerProvider` over it; Geofabrik returned 502/503 throughout this session,
  and no OSM extract tooling is in either project environment. Given §2, this
  is the mitigation most worth measuring next: it is the only one that removes
  the variance rather than working around it.
- **GEDTM30 via OpenTopography.** §1's enrichment number is a Terrarium
  stand-in at matched resolution. The 50 calls/24 h free-tier limit (FR85–FR91)
  is a *different* cost shape from tile mosaicking and is unmeasured. The
  inversion §1 reports has ~4× of headroom before it would reverse, but the
  8.8 s itself should be re-measured when #148 lands.
- **Memory at the top of FR120's range.** The 1,799 km² graph build peaked at
  1,164 MB against SPIKE-14's ~1 GB client budget. Noted, not investigated.
- **A second machine and a second network.** Every number here is one host on
  one connection; §2's variance is a property of the public commons as seen
  from here.
- **`plugin_layers.LayerRegistry` is not shipped.** It is the demonstrated
  shape for N2, not a patch to `core/`.
- **No Windows pass.** Nothing measured here is platform-specific — one
  process, one GIL, one HTTP client — but it was not checked.

---

## Reproducing

See [`../README.md`](../README.md). Use `service/.venv`. The committed
`raw/*.json.gz` and `results/*.json` let `analyze.py`, `tour_scale.py`,
`health.py` and `concurrency.py` reproduce every number offline; only
`probe.py` needs the network.
