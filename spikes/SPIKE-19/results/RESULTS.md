# SPIKE-19 results — Waterway routing on USGS 3DHP, and binding live gauges to reaches

**Run:** 2026-08-16 · **Verdict: the succession is safe, the data has not moved yet, and
one documented design decision is wrong.** Every capability SPIKE-04's paddling verdict
rests on survives in 3DHP — three attributes under new names, one relocated to a different
layer, **none lost**. A real 148.2 km downstream paddling route comes out of 3DHP geometry
between the same access points SPIKE-04 used, and five live USGS gauges bind to it by
identifier with no spatial guessing. The elevation question answers itself.

**What must change:** ARCH §13.2 requires `reachcode` on every `WaterwayGraph` edge.
**3DHP flowlines do not carry `reachcode`** — it has moved to a separate point layer, and
a new, coarser key (`mainstemid`) has appeared beside it. Neither key alone binds every
gauge: mainstem reaches **77.8%** of resolved sites, reachcode **80.6%**, and the two
together **94.4%**. The edge needs **both**.

**What has *not* changed, and is the strategic finding:** every flowline in all three
regions carries `workunitid = "NHD"` and `featuredate = 2023-09-14`. **3DHP in the
product's regions is the converted NHD snapshot, not new elevation-derived hydrography.**
Migrating now costs almost nothing and gains almost nothing in data terms — it buys a
maintained product instead of an archived one, which is the entire reason to do it.

---

## The regression check

SPIKE-04 chose NHDPlus HR over OSM on four declared attributes (its §3.2). USGS retired
the NHD on 1 October 2023 and stopped maintaining NHDPlus HR, so the first question is
whether the successor still supports that verdict. Read from the service's own schema
rather than inferred from a query returning nothing:

| SPIKE-04 attribute | Verdict | Carried in 3DHP by | What it settles |
|---|---|---|---|
| `fromnode` / `tonode` | **RENAMED** | `hydrosequence` + `dnhydrosequence` | Topology still **declared**, not inferred from shared vertices |
| `flowdir` | **RENAMED** | `flowdirection` | Which way the water goes — **100%** populated in all three regions |
| `streamorde` | **RENAMED** | `streamorder` | Objective "big enough to float a boat" |
| `reachcode` | **MOVED** | layer 40 `universalreferenceid` | No longer an edge attribute — see §4 |

**Zero capabilities lost.** The topology rename is the one with a consequence: NHDPlus HR
gave from/to node identifiers, which build a graph directly. 3DHP gives a *downstream
pointer* per flowline, so the graph is built by **inverting** `dnhydrosequence`. The
inverse is one-to-many at confluences and divergences, which is why the provider must
invert rather than read `uphydrosequence` — that field names only the **main** upstream
path and would silently drop every tributary at a confluence.

The pointer resolves on **99.6% / 96.5% / 97.8%** of flowlines (WNC / SW WI / SoCal, order
≥ 4). The remainder are termini and flowlines whose downstream neighbour lies outside the
bbox or below the order threshold — a clipped network has edges to the outside world, and
that count is reported rather than swallowed because a high rate would mean the threshold
was severing the network instead of filtering it.

### One service detail that costs an hour if you don't know it

**The flowlines are layer 50**, not layer 1. Asking `usgs_3dhp_all/FeatureServer/1` returns
**HTTP 500 with the body `json`**, which reads like a transport failure rather than a wrong
layer id. The service's layers are 20/30/40 (hydrolocations), **50 (Flowline)**, 60
(Waterbody), 80 (Catchment).

---

## 1. The network, against SPIKE-04's own numbers

Same three bboxes — imported from `spikes/SPIKE-04/regions.py` rather than copied, so the
comparison cannot drift on a decimal point. Order ≥ 4, the "paddleable-scale" threshold
SPIKE-04 used:

| | OSM km (SPIKE-04) | NHDPlus HR km (SPIKE-04) | **3DHP km** | NHD largest comp. | **3DHP largest comp.** |
|---|---:|---:|---:|---:|---:|
| Western NC | 1,783 | 4,050 | **4,056** | 44.0% | **43.9%** |
| Southwest WI | 889 | 1,331 | **1,352** | 90.6% | **87.7%** |
| Southern CA | 865 | 3,075 | **3,683** | 14.6% | **17.8%** |

Western NC lands within **0.1%** and Wisconsin within **1.6%** of SPIKE-04's NHDPlus HR
figures. That is the `workunitid = NHD` finding showing up as arithmetic: it is the same
hydrography. Southern California is the outlier at **+19.8%**, which is worth noting and
not worth theorising about from one measurement.

**Longest continuous downstream run: 176 / 197 / 136 km.** This is computed strictly
downstream — a longest-path over the DAG that flow direction defines — so it is not
directly comparable to SPIKE-04's 215 / 254 / 92 km, which were undirected. The directed
number is the one a boat can use.

---

## 2. A real route, from geometry

SPIKE-04 was explicit about what it had not done (§10): topology came from attributes,
**no NHD geometry was ever fetched, and the route it published was solved over OSM**. That
gap is closed here. Everything below is 3DHP geometry and 3DHP topology, routed between
the same OSM access points SPIKE-04 used — reusing the endpoints so the comparison is the
network and not the put-ins.

| | SPIKE-04 (OSM) | **SPIKE-19 (3DHP)** |
|---|---|---|
| Western NC | 151.1 km, 2,486 nodes, undirected | **148.2 km downstream**, 821 flowlines, 9,558 vertices, solved in **0.01 s** |
| | Champion Park Access → Redmon Dam River Access | Champion Park Access → **Blannahassett Island River Access** |
| Southwest WI | 203.3 km between two unnamed nodes | **103.8 km downstream** (undirected: 207.3 km) |
| Southern CA | **No route** | **No route** — 1 access point on the largest component |

The Western NC route is **the French Broad River end to end**, 148.2 km on a single
mainstem, from the same put-in SPIKE-04 started from. It is 2% shorter than the OSM route
and it is *directed*, which is a different and better claim: a boat can actually do it.

**Southwest Wisconsin is where directedness stops being pedantry.** Undirected, the best
route is **207.3 km**; downstream-only it is **103.8 km**. The undirected figure is a real
path through a real network and it is not paddleable — it goes up one river and down
another. Any paddling distance quoted from an undirected solve is inflated by an unknown
amount, and SPIKE-04's 151.1 km was an undirected solve. In Western NC it happened not to
matter (undirected and downstream both return 148.2 km); in Wisconsin it is a **2× error**.

**Access points behave almost identically to SPIKE-04's OSM measurement**, which is worth
saying because it means the access-point problem is a property of the access data, not of
the network:

| | within 50 m (OSM / **3DHP**) | median snap (OSM / **3DHP**) |
|---|---|---|
| Western NC | 50 / **48** | 33 m / **39.5 m** |
| Southwest WI | 7 / **8** | 277 m / **269 m** |
| Southern CA | 2 / **1** | 2,294 m / **750.6 m** |

Southern California's median snap improves 3× because 3DHP carries far more channel than
OSM there — and it still produces no route, for the reason SPIKE-04 gave: the access points
are lake and reservoir ramps that do not sit on the river network at all.

---

## 3. The trap: `featuretypelabel` is anti-correlated with paddleability

This is the finding most likely to be built wrong, because the obvious filter is exactly
backwards.

3DHP types every flowline. The intuitive reading of `Channel Line` versus
`Waterbody Connector` is "real river" versus "artificial line through a lake" — the NHD
`ftype=558` artificial paths SPIKE-04 §3.2 credited for making lake ramps reachable. A
provider that filtered to `Channel Line` to avoid routing across reservoirs would look
careful.

It would delete the French Broad.

| Stream order (WNC) | Flowlines | `Waterbody Connector` share |
|---:|---:|---:|
| 4 | 8,774 | 12.5% |
| 5 | 4,561 | 22.2% |
| 6 | 2,366 | 69.1% |
| 7 | 1,431 | **99.7%** |
| 8 | 654 | **100.0%** |

And by river — every major paddling water in both riverine regions:

| River | Flowlines | km | Typed |
|---|---:|---:|---|
| French Broad | 880 | 156 | **100% Waterbody Connector** |
| Little Tennessee | 314 | 153 | 99% Waterbody Connector |
| Pigeon | 347 | 75 | 99% Waterbody Connector |
| Tuckasegee | 253 | 98 | 99% Waterbody Connector |
| Nantahala | 138 | 74 | 80% Waterbody Connector |
| Wisconsin | 156 | 165 | **100% Waterbody Connector** |
| Kickapoo | 80 | 87 | **100% Waterbody Connector** |
| Mississippi | 57 | 64 | **100% Waterbody Connector** |

The cause is ordinary cartography: a river wide enough to be drawn with two banks is an
areal waterbody, and the flowline through it is a connector. The consequence is not
ordinary — **the bigger the river, the more likely it is typed as a connector**, so
`featuretypelabel` runs opposite to paddleability across the entire range that matters.
**Filter on `streamorder`, never on `featuretypelabel`.**

---

## 4. Binding gauges — the join key changes

SPIKE-04's strongest result was that gauge-to-reach association is a **lookup, not a
spatial guess**: 58 of 59 sampled sites resolved through NLDI, and because NHDPlus HR
carried `reachcode` on every flowline the two layers joined without a spatial match. That
matters precisely where a guess is worst — a gauge below a confluence reads two rivers, a
gauge above a dam reads a pool rather than a release.

3DHP flowlines carry no `reachcode`. Measured across **every** real-time site SPIKE-04
found in the three regions (112 sites — not a sample, because a join that works for 80% of
gauges is a different product than one that works for all of them):

| | Sites | NLDI-resolved | Bound by `mainstemid` | Bound by reachcode | **Either** |
|---|---:|---:|---:|---:|---:|
| Western NC | 43 | 43 | 40 | 39 | **42** |
| Southwest WI | 9 | 9 | 7 | 7 | **9** |
| Southern CA | 60 | 56 | 37 | 41 | **51** |
| **Total** | **112** | **108 (96.4%)** | **84 (77.8%)** | **87 (80.6%)** | **102 (94.4%)** |

**Neither key is sufficient and they fail on different sites.** `WaterwayGraph` edges need
`mainstemid` *and* a reachcode, tried in that order — which contradicts ARCH §13.2 as
written.

### The namespace trap, measured

3DHP's `mainstemid` values are geoconnex.us URIs in **two namespaces** —
`geoconnex.us/usgs/mainstems/N` and `geoconnex.us/ref/mainstems/N`. NLDI answers with
`ref` for **100%** of sites that have a mainstem at all. Most *flowlines* are `usgs`
(841 of 933 distinct mainstems in WNC order ≥ 4).

The tempting fix is to normalise the prefix away and match on the number. **Do not.** Of
933 distinct numeric ids in WNC, **zero appear under both prefixes** — they are disjoint
registries, not aliases, and normalising them would manufacture false joins. Match the
full URI as a string. The split turns out to be benign for this purpose because gauged
rivers are the big named ones, which live in the `ref` namespace NLDI answers in.

### End to end, on the real route

Five gauges bind to the 148.2 km French Broad segment by identifier — no geometry
involved — and read correctly downstream:

| Site | Station | Discharge | Age | Against an illustrative 300–3,000 cfs band |
|---|---|---:|---:|---|
| 03439000 | French Broad at Rosman | 130 ft³/s | 47.5 min | `below_author_band` |
| 03443000 | French Broad at Blantyre | 512 ft³/s | 32.5 min | `within_author_band` |
| 03447687 | French Broad near Fletcher | 840 ft³/s | 32.5 min | `within_author_band` |
| 03451500 | French Broad at Asheville | 1,240 ft³/s | 32.5 min | `within_author_band` |
| 03453500 | French Broad at Marshall | 1,370 ft³/s | 62.5 min | `within_author_band` |

Discharge increases monotonically downstream, which is the physical sanity check this
result should be judged on. Readings came from `api.waterdata.usgs.gov` — the OGC API -
Features successor — not the `waterservices.usgs.gov` endpoint being decommissioned in
Q1 2027. All five are `approval_status: Provisional`, which the payload carries.

**A product finding fell out of it: one gauge band cannot govern a 148 km segment.** The
headwater gauge reads below the band while four downstream gauges read inside it, and all
five are the same river on the same day. FR14's band has to attach to a **day or a reach**,
not to a multi-day paddle segment — otherwise the warning is either permanently on or
meaningless.

### The payload carries a reading, never a verdict

Emitted schema (`gauge_binding.json`): station id and name, `bound_by`, mainstem, reach
code, discharge and stage each with unit / observation time / approval status,
`retrieved_at`, `age_minutes`, the **Author's** band, and `band_state` ∈
{`within_author_band`, `below_author_band`, `above_author_band`, `unknown`}.

There is no `status: "runnable"` field and there must never be one. That is a difficulty
grade — the capability ARCH **D19** removed after SPIKE-04 found no licensable class-rating
source — and no discharge number supports it. `unknown` is first-class because FR14a
requires the app to say plainly when a segment has no gauge, and silence is
indistinguishable from "fine".

---

## 5. The elevation question answers itself

The spike was told to decide where a river's gradient comes from, because 3DHP is built
from lidar and its flowlines are Z-aware — which makes stream slope look free and puts it
in conflict with **D20** (GEDTM30 via OpenTopography, single source, no fallback).

The layer advertises `hasZ: true`. The geometry carries a third ordinate. **It is 0.0 on
all 40,938 vertices sampled across all three regions** (12,517 WNC / 20,622 SW WI /
7,799 SoCal; min 0, max 0).

**Decision: D20 holds unchanged. Ignore flowline Z.** There is nothing to weigh — the
elevation is not there. This is a consequence of the `workunitid = NHD` finding: these are
converted NHD geometries in a 3D-capable schema, and the third ordinate is a placeholder
waiting for elevation-derived hydrography to arrive. **Re-test when a region's
`workunitid` stops saying `NHD`** — at that point the trade-off becomes real and this
decision should be revisited rather than inherited.

---

## 6. Corridor clip — the other half of FR64's budget

SPIKE-14 sized the basemap at ~3.5 MB per 1,000 km². The waterway network is the half
nobody had measured. A **true geodesic distance buffer** around the 176 km Western NC run,
gzipped, carrying only what a provider needs to rebuild the graph and bind a gauge
(geometry, id, length, order, direction, topology, mainstem, name):

| Region | Buffer | Flowlines | km | Routing payload (gz) |
|---|---:|---:|---:|---:|
| Western NC | 2 km | 2,392 | 410 | **392 KB** |
| Western NC | 5 km | 4,443 | 737 | 786 KB |
| Southwest WI | 2 km | 461 | 384 | 143 KB |
| Southern CA | 2 km | 400 | 337 | 63 KB |

**The water is roughly a sixth of the basemap.** A 2 km corridor along 176 km covers about
700 km², which SPIKE-14's figure prices at ~2.5 MB of tiles against 392 KB of flowlines.
Offline paddling data is not a package-size problem.

*Method note, because the first version of this measurement was wrong:* it originally
expanded the route's **bounding box**, and the giveaway was that 2 km and 5 km "buffers"
differed by 10%. A 176 km sinuous river has a bbox many times its own corridor, and the box
was doing all the work. The numbers above are per-vertex geodesic distances.

---

## 7. The threshold decision (SPIKE-04 outstanding item 2)

SPIKE-04 measured order ≥ 4 and order ≥ 3 and left the choice open as a product decision.

| | order ≥ 4 km | order ≥ 3 km | Ratio | Largest component, ≥4 → ≥3 |
|---|---:|---:|---:|---|
| Western NC | 4,056 | 7,960 | 1.96× | 43.9% → 43.0% |
| Southwest WI | 1,352 | 2,415 | 1.79× | 87.7% → 82.3% |
| Southern CA | 3,683 | 7,007 | 1.90× | 17.8% → 15.4% |

**Recommend order ≥ 4 as the shipped default, with order ≥ 3 available per region.**
Dropping to 3 roughly doubles the network, and the longest downstream run barely moves
(176 → 177 km in WNC, 197 → 201 in SW WI, 136 → 136 in SoCal) while the largest component's
share *falls* in all three regions. The extra water is headwater creeks that hang off the
network rather than extending it — runnable at high water, dry in August, and exactly the
kind of edge an advisory gauge band cannot speak to. This is a **default**, not a truth;
§10 of SPIKE-04 was right that mean annual flow would be the better criterion, and 3DHP
does not carry it.

---

## 8. Licensing

Unchanged from SPIKE-04, and clean.

| Source | Used for | Licence |
|---|---|---|
| USGS 3DHP (`3dhp.nationalmap.gov`) | waterway network + geometry | US public domain (17 U.S.C. §105); credit requested |
| USGS NLDI (`api.water.usgs.gov/nldi`) | gauge → reach/mainstem linkage | US public domain |
| USGS Water Data OGC API (`api.waterdata.usgs.gov`) | live discharge / stage | US public domain |
| OSM (via SPIKE-04's cache) | access points only | ODbL — attribution, share-alike |

No key, no quota, no rate limiting encountered. **This is a markedly better operational
story than SPIKE-04 §8's Overpass experience** — that spike could not complete a single
region's pull without tiling, caching and pacing queries 20 s apart. Every 3DHP pull here
ran straight through, paginating at 2,000 features. The provider should still read from a
local extract (ARCH §14.1, §6.5), but for correctness and offline behaviour rather than to
avoid punishing a public server.

---

## 9. What this means for the build

| | Recommendation |
|---|---|
| **Source** | **Migrate `WaterwayDataProvider` to 3DHP.** Nothing is lost, the data is the same hydrography today, and it is the maintained product. Update ARCH §11's waterway row. |
| **ARCH §13.2** | **Wrong as written.** `WaterwayGraph` edges carry `mainstemid` **and** a reach code, not `reachcode` alone. Either key alone loses ~20% of gauges. |
| **Topology** | Build the graph by **inverting `dnhydrosequence`**. Never use `uphydrosequence` — it names only the main upstream path and drops tributaries at confluences. |
| **Filtering** | Filter on `streamorder` (default ≥ 4). **Never filter on `featuretypelabel`** — it is anti-correlated with paddleability above order 6. |
| **Routing** | Paddling routes are **downstream-directed**. An undirected solve overstated Wisconsin's best route by 2×. |
| **Elevation** | **D20 holds.** Flowline Z is 0.0 everywhere. Revisit when `workunitid` stops reading `NHD`. |
| **Gauge band** | FR14's band must attach to a **day or reach**, not a whole segment. Five gauges disagreed across one 148 km river. |
| **Package size** | Not a constraint. A 2 km corridor is ~0.4 MB against ~2.5 MB of basemap. |
| **Endpoint** | `api.waterdata.usgs.gov` only. `waterservices.usgs.gov` is decommissioned Q1 2027. |

---

## 10. What this does *not* prove

- **The data has not actually been remapped yet.** Every flowline in all three regions is
  `workunitid = NHD`, `featuredate = 2023-09-14`. This spike verifies the **migration path**
  is safe; it says nothing about elevation-derived hydrography, because none is present
  here. When EDH arrives, geometry, Z, and possibly topology all change, and §1's
  "within 0.1% of SPIKE-04" reassurance expires with it.
- **No route was scored.** Same limit SPIKE-04 recorded: a connected directed graph and a
  shortest path across it are not a *good* paddling route. Weighting, portage insertion,
  put-in/take-out pairing and flow-gated feasibility are the build.
- **The provider is a spike harness, not `plotlines-core` code.** It reads a local cached
  extract and builds a graph, which is the shape ARCH §13.2 describes, but nothing here has
  been written against the real `WaterwayDataProvider` protocol or wired into scoring.
- **Access points are still OSM's**, with all of SPIKE-04 §4's problems intact. Nothing in
  3DHP addresses put-ins, take-outs, portages, or class.
- **Three US regions.** Everything load-bearing is a US federal dataset. SPIKE-04's item 3
  — assess a non-US region before calling paddling a general capability — is untouched.
- **One day's readings.** The gauge values are provisional and were read on 2026-08-16.
  `raw/` holds the network pulls so the arithmetic stays checkable; the live readings will
  not reproduce.
- **The 19.8% Southern California difference is unexplained.** It is reported, not
  theorised about.

---

## Outstanding

1. **Amend ARCH §13.2** to require both join keys on `WaterwayGraph` edges, and §11's
   waterway row to name 3DHP. This spike's evidence is sufficient; the edit is a decision.
2. **Re-test when a product region's `workunitid` stops reading `NHD`** — that is when the
   elevation decision in §5 genuinely reopens.
3. **Confirm the American Whitewater position** (SPIKE-04 item 1) — untouched here, still
   the only route back to class ratings.
4. **Assess a non-US region** (SPIKE-04 item 3) — untouched here.
