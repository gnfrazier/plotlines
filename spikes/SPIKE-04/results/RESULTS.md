# SPIKE-04 results — Paddling network & difficulty data availability

**Run:** 2026-08-14 · **Verdict: paddling data exists, but not the part the PRD leans
hardest on, and not from the source the spike assumed.** The waterway network and live
gauge readings are solid, public-domain and better than expected — from **USGS, not OSM**.
Access points are thin and inconsistently attached. **Class ratings are absent**: one
graded feature across all three regions, and it is an artificial channel in urban Anaheim.
Portages are absent in two regions of three.

**This did not kill paddling. It killed two stories.** B4's "never routes toward water
that exceeds the stated ability band" and B5's class-based exclusion cannot be enforced
from open data, because there is no per-edge class to compare the band against.
**Decided 2026-08-14: FR13 retired and stories B4 and B5 removed** (ARCH D19, PRD §8);
FR14 narrowed to an advisory gauge band as new story **B8** in Leg 3 beside weather, and
FR15/B6 portages made Author-drawn. Paddling remains a first-class mode, and the paddling
graph is intact.

**Answer to Q2 (ARCH §17):** OSM is **not** sufficient. `WaterwayDataProvider` needs a real
implementation, backed by USGS. ARCH's decision to isolate this behind a provider (§6.4,
risk A2) was correct and is now load-bearing.

---

## Verdict per data element

The spike's "done when" bar is a clear yes/no per element with a source and licensing
note. Here it is; the rest of the document is the evidence.

| Element | Verdict | Source that works | Licence |
|---|---|---|---|
| **Waterway network** | **Yes** — via NHDPlus HR, not OSM | USGS NHDPlus High Resolution | US public domain |
| **Access points** | **Partial** — usable in one region of three, never complete | OSM + state agency GIS | ODbL + per-state, mostly *unlicensed* |
| **Class ratings** | **No** | none available on acceptable terms | American Whitewater prohibits reuse |
| **Gauge readings** | **Yes** — including which reach a gauge governs | USGS Water Data APIs + NLDI | US public domain |
| **Portages** | **No** — 13 features, all in one region | OSM | ODbL |

---

## 1. Method

Three regions, chosen because the product already names them (`docs/osm_reference.md`
open items) and because they disagree with each other:

| Region | Area | Why it is here |
|---|---|---|
| Western North Carolina | 13,707 km² | French Broad, Nantahala, Tuckasegee, Pigeon. Steep whitewater with a large, active paddling community — the **best case**, not the average one. |
| Southwest Wisconsin | 7,229 km² | Lower Wisconsin State Riverway. A designated flatwater water trail: class rating is irrelevant, access and portages are everything. |
| Southern California | 21,001 km² | LA / Orange / western Riverside. Paddling is coastal and reservoir; the rivers are largely concrete flood channels. Included because it *should* come back thin. |

Two design choices make the numbers mean something:

- **Every paddling count is reported against a cycling or hiking control from the same
  bbox and the same source.** "31 put-ins in Western North Carolina" is not interpretable;
  "31 put-ins where the same query finds 13,406 path and footway ways" is.
- **Counts are normalised per 1,000 km².** The bboxes follow river systems rather than a
  grid and differ in area by 3×, so raw counts would manufacture regional differences out
  of bbox drafting.

Raw pulls are cached and committed under [`../raw/`](../raw) (gzipped, ~4 MB), so every
number here is reproducible offline.

---

## 2. Class ratings — the finding that decides the scope

This is the one that matters, so it goes first.

| Probe | WNC | SW WI | SoCal |
|---|---:|---:|---:|
| `whitewater:section_grade` | 0 | 0 | 0 |
| `whitewater:rapid_grade` | 0 | 0 | 0 |
| `rapids=*` | 0 | 0 | **1** |
| `whitewater=rapid` | 0 | 0 | 0 |

**One graded feature in 41,937 km².** And it is not a river run: it is a 
`route=canoe` + `oneway=yes` + `rapids=1` way in urban Anaheim at 33.8127, −117.9216 —
an artificial channel. Whatever it is, no Character is planning a trip around it.

Zero in Western North Carolina is the striking one. That bbox contains the Nantahala, the
French Broad, the Tuckasegee and the Pigeon — some of the most heavily paddled whitewater
in the eastern United States — and OSM carries not one graded section or rapid in it.

### It is not that the schema is broken

The obvious reading is "OSM has no whitewater schema", and that reading is wrong. Global
usage from taginfo, and the continental split from the Geofabrik regional instances:

| Tag | Worldwide | Europe | North America |
|---|---:|---:|---:|
| `whitewater:section_grade` | 2,338 | 2,046 | **58** |
| `whitewater` (any) | 4,613 | 3,949 | **339** |
| `canoe` (any) | 91,161 | 31,093 | **51,929** |
| `portage` (any) | 10,788 | 1,708 | **8,841** |
| *control:* `waterway` | 39,849,301 | — | — |
| *control:* `highway` | 299,736,830 | — | — |

The schema works and is actively used — in the Alps. North America has **58 graded
sections on the entire continent**. Meanwhile North American mappers use `canoe=*` and
`portage=*` *more* than European ones do, so this is not a continent that declines to map
paddling; it is a continent that maps paddling **access** and does not map paddling
**difficulty**. That is consistent with what we found on the ground: Western NC has 237
waterways carrying `canoe=*` access tags and zero carrying a grade.

Difficulty grading in the US is culturally owned by American Whitewater, and it has not
migrated into OSM.

### And the authoritative source is closed

American Whitewater's National Whitewater Inventory is the real class-rating database for
US rivers. Its terms prohibit exactly the use this feature would need: *"all reproduction,
including mass reproduction, data harvesting, crawling, indexing, use of automated
retrieval systems, or commercial or personal reproduction of content"*, and AW states it
**does not provide an API for its river data and does not intend to add one**.

Two caveats on how that was established, because they change what to do next:

- AW's site returned 403 to every automated fetch and its published terms URL now 404s
  after a site rebuild, so the quoted terms come from search-index copies rather than a
  page this spike retrieved directly. The prohibition is consistent across independent
  sources and is not ambiguous, but **it should be confirmed with AW directly** before
  anyone treats "no" as final.
- **No AW data was collected.** Their terms forbid automated retrieval, so the correct
  response to finding those terms is to stop, which is what happened.

That leaves a **licensing conversation**, not a technical problem. AW is a non-profit
advocacy organisation; a data agreement is a plausible route, and it is a
business-development task with a lead time, not something a sprint can engineer around.

### What this costs, precisely

FR13/FR14 are written as *Author-set* parameters, and that half is unaffected — an Author
can type "Class III" onto a segment today. What breaks is the **enforcement** half:

> **B4 AC:** "routing respects the setting; **never routes toward water that exceeds the
> stated ability band**"
> **B5 AC:** "options outside the band are **excluded or flagged**"

To exclude an edge for exceeding a class band, the engine needs that edge's class. **0.00%
of the network in all three regions carries one.** The band is un-enforceable against open
data, and the AC as written cannot be met.

---

## 3. The waterway network

### 3.1 OSM has less water, worse connected, with the wrong things in it

Both datasets, same bboxes, restricted to paddleable-scale water — OSM `waterway=river`
+ `canal` + `tidal_channel`, NHDPlus HR at Strahler stream order ≥ 4:

| | OSM km | NHD km | OSM largest component | NHD largest component | OSM longest run | NHD longest run |
|---|---:|---:|---:|---:|---:|---:|
| Western NC | 1,783 | **4,050** | 21.7% | **44.0%** | 180 km | **215 km** |
| Southwest WI | 889 | **1,331** | 75.8% | **90.6%** | 228 km | **254 km** |
| Southern CA | 865 | **3,075** | 26.8% | 14.6% | 143 km | 92 km |

OSM carries **44%, 67% and 28%** of NHD's paddleable-scale river length, and its largest
connected component holds a smaller share of it in the two regions where paddling is real.

**Southern California is the exception that proves the point, in the wrong direction.**
OSM appears to win on longest run there — 143 km against NHD's 92 km — until you look at
what the network is made of. Of the 670 ways in that pull, **431 are `waterway=canal`**:
the concrete flood-control channels and aqueducts that Southern California's "rivers"
have been turned into. They chain into long, beautifully connected lines that no one can
paddle. A naive OSM-backed provider would route a Character down the Los Angeles River
flood channel with complete confidence. NHD's stream-order filter excludes them.

Read the largest-component column with care in general — **much of it is geography, not
data quality.** Southwest Wisconsin scores high because the bbox is essentially one river
system draining to the Mississippi. Western NC is lower because the bbox straddles a
continental divide: the French Broad drains north to the Ohio, the Little Tennessee west,
the Savannah south, and no dataset will connect them. What survives that caveat is the
**longest continuous run**, and on that measure NHD wins everywhere the water is real.

### 3.2 What NHDPlus gives that OSM structurally cannot

NHDPlus High Resolution is not a prettier river map; it is a *network product*, and it
ships the four things a router needs as first-class attributes:

| Attribute | What it settles |
|---|---|
| `fromnode` / `tonode` | Topology is **declared**, not inferred from whether two drawn lines happen to share a vertex. |
| `flowdir` | Which way the water goes — **set on 100% of flowlines in all three regions**. A paddling router without this will route a Character up a rapid. |
| `streamorde` | Strahler order: a uniform, objective proxy for "big enough to float a boat", instead of a mapper's river-versus-stream judgement that varies by county — and the thing that keeps the LA flood channels out. |
| `reachcode` | The same identifier space USGS gauges are indexed in, which makes §5's gauge association a lookup rather than a spatial guess. |

It also carries the connector OSM simply does not have. 33% of Western NC's NHD flowlines
are `ftype=558`, *artificial paths* — the routed lines through lakes and reservoirs that
make a boat ramp on a lake reachable from the river above it. OSM has no equivalent, which
is exactly why §4's access points fail to attach.

Lowering the threshold to order ≥ 3 roughly doubles the network (WNC 7,949 km, SW WI
2,388 km, SoCal 6,203 km). Both thresholds are measured because the choice is a **product
decision** — order 3 includes creeks that are runnable at high water and dry in August —
and every downstream number moves with it.

### 3.3 A real route came out of it

The analysis routes between the two most distant access points sitting on the largest
component — the paddling equivalent of what SPIKE-00's harness demanded of the cycling
graph. Not "does the data parse" but "does a solver get a route out of it":

| Region | Result |
|---|---|
| Western NC | **151.1 km on water**, Champion Park Access → Redmon Dam River Access, 2,486 nodes, 25 access points on the component |
| Southwest WI | **203.3 km on water** — but between two *unnamed* nodes, because the access points there have no names |
| Southern CA | **No route.** Zero access points sit within 200 m of the largest component |

So the network half of the answer is genuinely yes: real, long, connected paddling routes
come out of open data in two regions of three, before any weighting is applied.

---

## 4. Access points

This is where OSM degrades fastest, and where the regional spread is widest.

| | Total | Named | Paddling-native | Generic slipways | Within 50 m of the network | Median snap |
|---|---:|---:|---:|---:|---:|---:|
| Western NC | 81 | 34 | 36 | 45 | **50** | 33 m |
| Southwest WI | 59 | 18 | 3 | 56 | **7** | 277 m |
| Southern CA | 66 | 9 | **0** | 66 | **2** | 2,294 m |

`canoe=put_in` — the tag `docs/osm_reference.md` lists first as "the paddling equivalent of
a trailhead" — returned **0 in all three regions**. Every paddling-native access record in
this spike came from `whitewater=put_in/egress` (31, all in Western NC) or
`waterway=access_point` (5 and 3).

**The snap distances are the real finding.** In Western NC, all 36 paddling-native access
points snap to the network within 50 m; every one of the 31 that don't is a
`leisure=slipway`, up to 3 km from any river centreline. Those are lake and reservoir
ramps, and they cannot attach because OSM has no artificial path across a waterbody
(§3.2). In Wisconsin and Southern California, where nearly all access is lake ramps, that
failure becomes the whole picture: **7 of 59 and 2 of 66 attach at all.**

Fewer than half the access points anywhere carry a name — 34, 18 and 9. A put-in a
Character is told to meet at needs one.

### State agency GIS is denser, and differently shaped

| Source | Statewide | In the spike bbox | Paddling-relevant detail |
|---|---:|---:|---|
| NC Wildlife Resources Commission boating access | 267 | 26 | None — trailer parking, launch lanes, dock counts |
| Wisconsin DNR public boat access | 3,136 | 79 | **Yes** — `LANDING_TYPE_CODE` splits 54 RAMP / 25 CARRY-IN |

Wisconsin can tell you which access points a canoe can actually use; North Carolina
cannot. Both datasets are built for **boat ramps** — trailers, docks, parking surfaces —
and neither carries what a paddling segment needs: river left or right, whether a site is
the take-out for a specific run, or carry distance from the parking area.

**The structural problem is not density, it is fragmentation.** Two agencies, two schemas,
two portals, and 48 more states. There is no national access-point dataset, so a paddling
feature resting on state GIS rests on 50 integrations with 50 schemas and 50 licences.

---

## 5. Gauges — the strongest result in the spike

| Region | Real-time discharge sites | Gauge-height sites | Reporting when sampled |
|---|---:|---:|---:|
| Western NC | 43 | 43 | 43 / 43 |
| Southwest WI | 8 | 8 | 9 / 9 |
| Southern CA | 55 | 60 | 60 / 60 |

Every sampled gauge returned a current reading. Both quantities are available, which
matters because paddlers quote **cubic feet per second** while FR14's wording asks the
Author for **gauge height** — the data supports either, so **FR14 should let the Author
choose the unit** rather than assume stage height.

### The part that was not in the brief: which reach does a gauge govern?

A gauge reading is a number attached to a point. FR14 needs it attached to *a stretch of
river someone will paddle*. Guessing that spatially is wrong in exactly the cases that
matter — a gauge below a confluence reads two rivers, a gauge above a dam reads a pool
rather than the release — and this spike measured how badly it fails even mechanically:
snapping gauges to OSM's network attaches only **27 of 43, 1 of 9, and 19 of 60**.

USGS NLDI makes it a lookup instead. Every NWIS site resolves to an NHD `comid`,
`reachcode` and mainstem, and the navigation endpoints walk the network from that point:

| Region | Gauges resolved to an NHD reach |
|---|---|
| Western NC | 25 / 25 |
| Southwest WI | 9 / 9 |
| Southern CA | 24 / 25 |

**58 of 59 sampled gauges resolved.** Because that `reachcode` is the same identifier space
§3's network arrives in, the gauge layer joins the network layer **without a spatial match
at all**. Walking 40 km downstream from the French Broad gauge at Asheville returned 22
distinct reaches in 0.7 s — that traversal *is* "the water this gauge governs".

### One thing to schedule, not to discover later

**The API this was measured on is being retired.** USGS WaterServices
(`waterservices.usgs.gov`) is scheduled for decommissioning in **Q1 2027**, with
intentional degradation possible from the second half of 2026 — that is, now. The
replacement is an OGC API - Features service at `api.waterdata.usgs.gov`.

The successor was probed alongside the legacy one, and it works. It also cross-validates
the legacy numbers: filtering its `latest-continuous` collection to series reporting since
2026-01-01 gives 43 / 6 / 54, against the legacy API's 43 / 8 / 55 active real-time
discharge sites. (The recency filter is not optional — the raw collection returns each
series' last value *ever*, including one that stopped in 2004. Counting rows would report
long-dead gauges as live coverage.)

Any implementation should target `api.waterdata.usgs.gov` from day one.

---

## 6. Portages and hazards

**Portages: 13 features, all in one region.**

| Probe | WNC | SW WI | SoCal |
|---|---:|---:|---:|
| `canoe=portage` | 0 | 0 | 0 |
| `whitewater=portage_way` | 0 | 0 | 0 |
| `portage=*` | 0 | **13** | 0 |

Southwest Wisconsin's 13 are the only portage records in 41,937 km², and Western NC — with
435 mapped dams — has none at all. This is a regional absence rather than a global one:
North America has 8,841 `portage=*` uses, five times Europe's 1,708, almost certainly
concentrated in the Boundary Waters and Quetico canoe country where portage-to-portage
travel *is* the sport. The tag is alive; it is not applied where this product's regions
are.

**Hazards: present, and the useful half is missing.**

| | WNC | SW WI | SoCal |
|---|---:|---:|---:|
| `waterway=waterfall\|weir\|dam\|lock_gate` | 1,262 | 69 | 509 |
| `waterway=canoe_pass` (a marked bypass) | **0** | **0** | **0** |

Western NC's hazards break down — from the geometry pull, which returned 1,284 features to
the census's 1,262 because the two were fetched an hour apart — as 825 waterfalls, 435
dams, 21 weirs and 3 lock gates. Genuinely dense hazard data. But zero bypasses anywhere.
**OSM can tell a paddler a dam is there and cannot tell them how to get around it.**

Southwest Wisconsin's 82 features are 63 dams, 2 waterfalls, 2 weirs, 2 lock gates — and
the 13 portages, all tagged `portage=permissive`.

For FR15 that means the hazard *flag* is grounded in data and the portage *route* — exit
bank, carry distance, surface, elevation change — is not. B6's AC assumes both.

---

## 7. Controls — what "thin" actually looks like

The same bboxes, the same server, the modes the PRD already calls proven:

| | Paddling: access points | Paddling: `route=canoe` | Cycling: `highway=cycleway` | Cycling: `route=bicycle` | Hiking: `route=hiking` | Hiking: path/footway |
|---|---:|---:|---:|---:|---:|---:|
| Western NC | 81 | 1 | 368 | 30 | 270 | 13,406 |
| Southwest WI | 59 | 2 | 253 | 11 | 24 | 3,002 |
| Southern CA | 66 | 0 | 8,418 | 192 | 72 | **354,791** |

Southern California is the sharpest version of the finding. It is one of the most
intensively mapped places on Earth — 354,791 path and footway ways, 58,487 highways with
an explicit `bicycle=*` tag — and it has **zero paddling-native access points, zero canoe
routes, and four `canoe=*` features in total**. The absence of paddling data is not an
absence of mappers.

---

## 8. Licensing summary

| Source | Used for | Licence | Practical constraint |
|---|---|---|---|
| OSM (Overpass) | access points, hazards, `canoe=*` legality | ODbL | Attribution; share-alike on derived databases. Already an ARCH §11.1 source. |
| USGS NHDPlus HR | waterway network | US public domain (17 U.S.C. §105) | None. Credit requested, not required. |
| USGS Water Data APIs / NLDI | gauge readings, gauge→reach | US public domain | None. **Endpoint migration due before Q1 2027.** |
| State agency GIS (NC, WI, …) | access points | **No explicit grant** — disclaimers only | Per-state review; some states forbid commercial use outright (North Dakota's service states it explicitly). |
| American Whitewater | class ratings | **Reuse prohibited**, no API | Requires a licensing conversation. Do not scrape. |

Public availability is not permission. The NC and WI datasets carry "informational
purposes only" *liability* disclaimers, which say nothing about reuse rights either way.

### An operational constraint that behaves like a licence

**The public Overpass instance could not complete this spike's pulls without being worked
around.** It returned 429s and 504s throughout, and getting a single region's network
required tiling each bbox into quarters, caching per tile, pacing successful queries 20 s
apart, and — the actual root cause — cutting the *server-side* `[timeout:]` from 300 s to
90 s, because a query the gateway had already 504'd kept running on the instance and kept
holding one of the client's two slots. The retry loop had been feeding the rate limiting
it was retrying against.

That is acceptable for a spike and unacceptable for a user-facing feature. **Any
production `WaterwayDataProvider` reads from a local extract or a self-hosted instance,
not the shared commons** — consistent with ARCH §14.1's existing "graph fixtures are
committed, not fetched" stance, and with P7.

---

## 9. What this means for paddling-in-MVP

The spike's job is to feed a go/no-go. The honest call is neither.

**Recommend: keep paddling in MVP, and cut one acceptance criterion.**

| Keep as written | Change |
|---|---|
| FR10 paddling as a first-class mode | — |
| FR12 transition nodes (put-in/take-out) | Author-placed, as already written |
| FR13/FR14 Author-set class and water-type weighting | **Drop automatic class-band enforcement** (B4/B5 AC). The Author declares a segment's class; the engine surfaces and warns, but cannot exclude edges it has no class for. |
| FR14 gauge thresholds | Fully supported — and let the Author choose cfs or stage height |
| FR15 portages | **Author-drawn**, not derived. B6's computed carry distance, surface and elevation stay; the portage *line* comes from the Author, not a lookup. Mandatory-hazard flags can be data-driven (1,262 hazards in Western NC alone). |

That is a smaller change than it sounds. Re-reading B4 and B5, the Author was always the
one *setting* the class; only the enforcement clause assumed a graded network existed. And
`WeightProfile`'s class term (ARCH §6.3) stays meaningful over Author-declared segments —
it just cannot filter candidate edges mid-solve.

**Two regional caveats the PRD should absorb:**

- **Paddling quality varies more by region than cycling does.** Western NC supports a real
  151 km route with named access points. Southern California produced no route at all.
  Whatever "paddling is first-class" means in the product, it cannot mean "works the same
  everywhere" — the data does not.
- **The answer is US-shaped.** Everything load-bearing here (NHDPlus, NLDI, the Water Data
  APIs, the reachcode join) is a US federal dataset with no international equivalent.

**What would change this call:** a data agreement with American Whitewater, or the
whitewater grading schema gaining North American adoption. Both are worth revisiting. The
second is also something this project could *contribute to* — a product collecting
Author-declared class ratings is sitting on exactly the data OSM lacks — but that is a
licensing and ethics question of its own, not a free win.

---

## 10. What this does *not* prove

- **Three regions, all in the United States.** See above; a non-US region needs its own
  source assessment and would likely find OSM is all there is.
- **No route was *scored*.** §3.3 proves a connected, directed graph exists and that a path
  can be found across it. It does not prove a *good* paddling route comes out of it:
  weighting, portage insertion, put-in/take-out pairing and flow-gated feasibility are the
  build, not the spike.
- **The NHD network was analysed from attributes, not geometry.** Topology came from
  declared `fromnode`/`tonode`, which is the right source for connectivity but means no
  NHD geometry was fetched and no NHD-based route was computed. The route in §3.3 is over
  OSM. Building the provider will need the geometry pull this spike skipped.
- **Access-point completeness is unmeasured.** The counts show what each source has; none
  was checked against a paddler's knowledge of what is actually there. "26 state access
  sites in Western NC" may be most of them or a third of them.
- **The stream-order threshold is a judgement.** Order ≥ 4 was used for "paddleable" and
  order ≥ 3 measured alongside it. Neither is a hydrological truth about floatability, and
  a real implementation should refine it with mean annual flow — which NHDPlus also
  carries and this spike did not pull.
- **Licences were read, not cleared.** The American Whitewater terms were established from
  search-index copies after the site returned 403 and its terms URL 404'd, and the state
  datasets carry disclaimers rather than grants. Anything that ships needs a real review.
- **A snapshot, on one day.** OSM and the state services change under you. [`../raw/`](../raw)
  holds what they said on 2026-08-14 so the arithmetic stays checkable; re-running the
  probes will not reproduce it exactly.

---

## Outstanding

> ~~2. **Take the PRD scope call** in §9.~~ **Taken 2026-08-14.** FR13 retired, stories
> **B4 and B5 removed**, FR14 narrowed to an advisory gauge band (new story B8, Leg 3,
> alongside weather), FR15/B6 portages made Author-drawn. Recorded as ARCH decision **D19**
> and in PRD §8. This spike is **closed**.

1. **Confirm the American Whitewater position directly** and open a licensing conversation
   if class ratings are wanted. This is the single item that could bring back the removed
   B4/B5 capability, and it has a lead time no sprint can absorb.
2. **Decide the paddleable-water threshold** (stream order, mean annual flow, or both) as a
   product decision, and re-measure §3 against it.
3. **Assess a fourth region outside the United States** before paddling is described as a
   general capability rather than a US one.
4. **Implement `WaterwayDataProvider` against NHDPlus + NLDI** — carrying `reachcode` on
   every edge (ARCH §13.2) and reading from a local extract rather than a live service
   (§8).
