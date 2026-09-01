# SPIKE-17 — results

**Run 2026-09-01, issue [#176](https://github.com/gnfrazier/plotlines/issues/176).
Verdict: positive with two required interface revisions.**

An edge data-input plugin works against ARCH §14.2 with **zero core changes**,
and the fetch-and-annotate step is cheap enough that it is not a design
constraint — **0.6–2.3 s against graph builds of 17–91 s**. Normalisation does
**not** need a server tier, so **no P3 design event is required**. But §14.2's
annotation Protocols are missing two members a real provider cannot work
without, and the interface as published would let an unlicensed source reach
an Author's screen. Both are named in §7.

Everything below is from `run_spike.json` unless marked otherwise.

---

## 1. The source this spike named is gone — and that is a finding

Issue #176 names **NC TIMS**. Probed at the start of the run:

| | |
|---|---|
| `https://eapps.ncdot.gov/services/traffic-prod/v1/incidents` | **200**, body: `{"message":"As of May 27, 2026, information about API data can be found at https://drivenc.gov/help/endpoint/event"}` |
| `https://www.drivenc.gov/api/v2/get/event` | **400** `<Error><Message>Invalid Key</Message></Error>` |

The feed **relocated and became keyed** between this spike being written
(2026-08-27) and being run (2026-09-01) — five days. It answers `200` with a
message body rather than a redirect or a `410`, so a naive client does not
error; it silently receives zero events, and an advisory layer that silently
receives zero events reads as *"no work zones here"*.

**This is P7 with a date on it.** External resources are borrowed. Three
consequences carry into the contributor story (§6): a provider must be able to
report `failed` rather than empty, a plugin's own version must be visible so a
stale adapter is diagnosable, and "your source will move" belongs in the
contributor documentation as a first-class expectation rather than a footnote.

**Substituted sources, all keyless and all real:**

| Arm | Source | Spec | Events | Bytes |
|---|---|---|---|---|
| Standardised | 511 WI WZDx `511wi.gov/api/wzdx` | WZDx **4.2** | 4,424 | 10.2 MB |
| Same standard, other publisher | 511 NY WZDx `511ny.org/api/wzdx` | WZDx **4.1** | 5,857 | 7.2 MB |
| Bespoke | NWS alerts `api.weather.gov/alerts/active?area=WI` | CAP/GeoJSON | 5 | 3.5 KB |

---

## 2. The contract holds — with two members missing

`WzdxEdgeProvider` and `NwsAlertEdgeProvider` both satisfy
`plotlines_core.providers.EdgeDataProvider` (`isinstance` — structural, no base
class), and **no core file was changed to make either work**. The protocol's
one method, `annotate_edges(graph, bbox) -> graph`, absorbed a standardised
GeoJSON work-zone feed and a bespoke weather-alert feed without bending.

**But writing a real provider needed four members the Protocol does not
declare** — `licence`, `load_state()`, `fetch()` and per-run `stats` — and two
of them are load-bearing rather than convenient:

### Bend 1 — an annotation provider cannot be licence-gated

`LayerProvider` declares `licence -> LayerLicence`, and
`curation/registry.py` refuses a layer whose licence metadata is absent or
unsatisfiable **at registration, not at render** (D45, ARCH §12.2).
`EdgeDataProvider` declares no licence at all. Yet a work-zone advisory on an
Author's map is displayed third-party data exactly as a candidate layer is,
and owes exactly the same credit.

This is not hypothetical. Running the input side's own gate over the three
real sources:

| Source | Loads? | Why |
|---|---|---|
| `wzdx-wi` | **yes** | `feed_info.license` = `https://creativecommons.org/publicdomain/zero/1.0/` (CC0) |
| `wzdx-ny` | **no** | *"licence unsatisfiable (feed_info carries no `license` field)"* |
| `nws-alerts-wi` | **yes** | no licence field either; US federal public domain **asserted by the integrator** and recorded as such, the same shape as `OSM_LICENCE` |

**Two conformant WZDx feeds, and one of them cannot legally be loaded under
D45.** Under §14.2 as published there is nowhere to put that refusal, so the
5,857 New York events would reach the Author's screen with no attribution.

### Bend 2 — an annotation provider cannot report readiness

`LayerProvider.load_state()` exists so a slow or broken remote source never
blocks the workspace (§8.3, D48, story N2). `EdgeDataProvider` returns a graph
or raises. A source that is unreachable, throttled, or — per §1 — quietly
returning a message instead of a feed has exactly two ways to express that
through the published contract: return the graph unchanged (indistinguishable
from *"no work zones here"*), or raise (which takes the annotation pass down
with it). Neither is acceptable for a source whose absence is a safety-adjacent
silence.

### Bend 3 — `licence` cannot be a pre-fetch property

`LayerProvider.licence` is a property answerable before any network call. A
feed declares its terms **inside the document** (`feed_info.license`), so a
feed-shaped provider must fetch before it can answer. `registry.py` here calls
`fetch()` first and then reads `licence`; a revised contract should make the
licence read explicitly post-load, or accept that a provider may answer
`unsatisfiable` until it has loaded.

---

## 3. Annotating a real graph

Both graphs built live through the shipped `graph.regions.ensure_graph`.

| | driftless-lacrosse | milwaukee |
|---|---|---|
| bbox | 777 km², rural Driftless WI | 270 km², dense urban |
| nodes / edges | 16,456 / 42,450 | 51,790 / 138,979 |
| GraphML | 22.4 MB | 68.3 MB |
| **cold graph build** | **17.3 s** (89.9 s and 91.2 s on two earlier runs) | **51.5 s** (46.4 s, 62.0 s earlier) |
| edge index (R-tree, once) | 0.65 s | 1.90 s |
| **WZDx fetch + match + annotate** | **0.67 s** | **2.25 s** |
| events in bbox / matched | 21 / 19 (**90.5%**) | 101 / 87 (**86.1%**) |
| edges annotated | 535 (**1.26%** of the graph) | 3,340 (**2.40%**) |
| P6 — core edge keys mutated | **0** | **0** |

**The timing question is settled and it is not close.** Annotation is
**0.7–2.3 s** against a graph build of **17–91 s** — between ×0.013 and ×0.13
of the build it must not block. ARCH §7.5's rule (nothing blocks a solve) is
satisfied by simply doing the annotation on the same startup pass as the graph;
it needs no separate readiness gate of its own. The build times themselves vary
×5 run to run on the same bbox, which is A23's public-Overpass throttling
variance showing up again, and it dwarfs the annotation cost entirely.

**P6 holds, asserted on the bytes.** Every edge's `highway`, `access`,
`bicycle`, `foot`, `motor_vehicle`, `surface`, `maxspeed`, `lanes`, `length`,
`name`, `ref`, `oneway`, `barrier`, `geometry`, `grade_abs`,
`interest_salience`, `_pl_access_flags` and `_pl_feat` was fingerprinted before
and after both providers ran. Zero changed. Annotations live under an
`advisory:` namespace, and nothing in core reads them — which is exactly right:
**an advisory warns, it never excludes** (FR14, FR29a). Promoting a DOT feed to
a routing constraint would be a one-line change here and it must not be made.

### Road names are not an identity — measured

Name agreement between the DOT's `road_names` and OSM's `name`/`ref`, using
loose token overlap (`"WIS 142 WB"` ↔ `"State Highway 142"` counts as
agreement):

- **rural: 49.2%** (449 comparisons)
- **urban: 16.5%** (3,710 comparisons)

A matcher that required name agreement would discard half of rural matches and
**five out of six urban ones**. Geometry plus a bearing check is the load-bearing
mechanism; names are worth reporting and worth nothing as a filter.

### Publishing a linear event as a point costs 87% of it

Both WZDx publishers are conformant. Wisconsin publishes `LineString`
geometry for every event; **New York publishes `MultiPoint` with a single
coordinate for all 5,857**. To measure that difference without confounding it
with a different road network, the same 21 Wisconsin events were re-matched
with their geometry degraded to their own first point — same graph, same
events, only the publication shape differs:

| | as published (line) | degraded to a point |
|---|---|---|
| events matched | 19 / 21 | 17 / 21 |
| edges claimed | 535 | 129 |
| edges agreeing with the line match | — | 69 |
| **recall of the line match's edges** | — | **12.9%** |
| **edges claimed that the line match rejected** | — | **46.5%** |

A point match cannot be bearing-checked — there is no heading — so it takes
every edge within tolerance, cross streets included. **Nearly half of what a
point-published feed flags is the wrong road, and it finds one edge in eight of
the right one.** For an Author this is worse than no data: it is a warning on a
street the work zone is not on.

**This is a per-publisher property, not a per-standard one**, which means a
plugin registry cannot judge a source by its declared spec version. A source's
*published geometry kind* is a quality signal a contributor should have to
declare, and a consumer should be able to weight.

---

## 4. Volatility, TTL, and what a stale annotation should say

### The declared update frequency describes the pipeline, not the data

`feed_info.update_frequency` is **60 seconds**, and `feed_info.update_date`
moved on most polls. The events did not:

| poll (60 s apart) | events | added | removed | changed | churn |
|---|---|---|---|---|---|
| 1 | 4,424 | 0 | 0 | 0 | **0.0%** |
| 2 | 4,424 | 0 | 0 | 0 | **0.0%** |
| 3 | 4,424 | 0 | 0 | 0 | **0.0%** |

Across the polls the feed re-served 10.2 MB each time (773–1,153 ms) and said
nothing new. The events' own `update_date` distribution is the larger sample
and agrees: **p10 117 h, p50 427 h (17.8 days), p90 2,518 h (105 days), max
4,313 h (180 days)**, n = 4,424. Half of this feed has not been touched in over
two weeks.

**Honest scope:** three polls over three minutes on one afternoon is a small
window, and WZDx publishes *planned* work. An incident feed (crashes,
closures) would churn far faster — and the one this spike was aimed at is now
keyed (§1), so that half is unmeasured.

**Recommended TTL for planned-work sources: 6 hours**, with the feed's own
`update_frequency` explicitly *not* used as the TTL. Justification: measured
churn is zero at the minute scale and the median event is 17.8 days old, so a
60-second TTL would re-download 10.2 MB 360 times to learn nothing; 6 hours
bounds the worst case (an emergency closure added mid-morning is visible by
afternoon) at a cost of four fetches a day. A future incident-shaped source
should carry its own TTL rather than inherit this one.

### Conditional GET does not work on any of the three

| source | ETag | `If-None-Match` result | gzip |
|---|---|---|---|
| 511 WI | strong | **200 + full body** | none |
| 511 NY | weak | **200 + full body** | yes |
| NWS | weak | **200 + full body** | yes |

All three serve an `ETag` and none of them honours it, and the WI feed serves
10.2 MB **uncompressed** with `Cache-Control: private`. So a poll costs the
whole document every time. This makes the TTL argument stronger, not weaker,
and it is a concrete thing a contributor's documentation must warn about.

### Two clocks, and collapsing them is the natural bug

An annotation carries `advisory:observed_at`, `advisory:stale_after`
(observed + TTL) and `advisory:event_ends_at` (the event's own end date).
Measured on the driftless run at 15 minutes with a deliberately short 15-minute
demo TTL: **0 of 535 annotations are still fresh, and 535 of 535 are still
happening.** At 24 h, 525 of 535 events are still under way.

Collapsing these into one `expires_at` is wrong in both directions: a five-day
work zone looks stale after the TTL, and a reading taken yesterday about a
work zone ending next week looks fresh. **What the Author sees must say which
clock ran out**, and the two need different words:

- information stale → *"work-zone data last checked <when>"*, refreshable, and
  it does **not** invalidate the route;
- subject expired → the advisory simply stops being shown.

Neither is an error surface. A stale advisory is not a failure, and routing it
through M13 would teach the Author that ordinary use produces errors (D53, the
same reasoning that keeps compose-distance deviation and the stale list out of
it). The right shape is the age stamp beside the advisory, which is FR66's
weather age-stamping generalised — exactly as issue #176 anticipated.

**And the silent case is the dangerous one.** An unflagged edge means *"no
contrary signal found"*, never *"confirmed clear"* (FR14). With the source
unreachable — §1's exact failure — every edge is unflagged. That is why bend 2
(`load_state()`) is not cosmetic: without it there is no way to render the
difference between "checked, nothing found" and "never checked".

---

## 5. Does normalisation need a server? **No.**

The evidence, counted rather than argued. Lines of real, non-comment code:

| | LOC |
|---|---|
| shared helpers (timestamp parsing, GeoJSON flattening) | 42 |
| **WZDx adapter** (serves *both* publishers, no per-publisher branch) | **27** |
| **NWS adapter** (a wholly unlike schema) | **33** |
| matcher (shared by every source; the actual work) | 90 |

**A new source costs ~30 lines.** The expensive part — map-matching — is
shared, source-independent, and belongs in the client either way. A proxy
would host the cheap half.

The bespoke source is the strongest case for a proxy and it still does not
make one:

- an NWS alert usually carries `geometry: null` and names `affectedZones` by
  URL. Placing **5 alerts required 62 additional requests**, 11.3 s cold
  (0.18 s each), all cacheable and none keyed;
- once placed, those 62 zone polygons annotated **all 42,450 edges** of the
  driftless graph — 100% of it. A county-scale weather polygon is not an edge
  annotation; it is a region-level advisory wearing an edge annotation's
  clothes. **`EdgeDataProvider` is the wrong seam for area-scale sources**, and
  `ShapeDataProvider` already exists for them.

So the one arm that argues loudest for a proxy turns out to argue instead for
using the right Protocol. **No P3 design event is required**: P3's list of five
things the hosted service does stays as it is, the desktop MVP keeps its "no
hosted tier at all" property, and key handling stays on the device where a
plugin's own credentials belong.

**What would reverse this**: a source that is keyed *and* whose terms forbid
redistributing the key to end users, or one whose rate limit is per-key rather
than per-client. NC TIMS's replacement is now keyed (§1) and is the obvious
first test of that. Neither condition is met by anything measured here, and
either would be a P3 decision, not a library choice.

---

## 6. What a third-party contributor must know

Packaging and registration have a working answer on the input side already —
`curation/plugins.py` discovers `LayerProvider`s through an
`importlib.metadata` entry point in an ordinary installable package, never a
URL the app downloads and imports at runtime. **Nothing found here argues for a
different mechanism for annotation providers**, so ARCH **Q8** can be closed
for the Python half by reusing it: one entry-point group per direction.

What the documentation has to say that the input side's does not:

1. **Declare your licence, or you will not load.** The gate is at registration
   (D45). One of the two real WZDx feeds tested fails it today.
2. **Declare your geometry kind.** Line-published and point-published feeds
   differ by 87% recall and a 46.5% wrong-road rate (§3). A contributor who
   publishes points should say so.
3. **Your source will move.** Answer `failed` with a reason rather than an
   empty result — an advisory layer that silently returns nothing reads as
   "all clear" (§1).
4. **Do not annotate anything core reads.** Namespace your keys. Your data is
   an advisory; promoting it to a constraint is a product decision, not a
   plugin's.
5. **State a TTL, and do not copy your feed's `update_frequency` into it**
   (§4).
6. **Expect no bbox on the wire.** All three sources publish one statewide
   document with no query interface; the client filters. Budget for the whole
   document on every refresh, because conditional GET does not work (§4).

Keys: nothing measured here needs one, and the one keyed source found
(DriveNC v2) would keep its key on the device in the same `SecureStore` the
output half uses (§14.3), never in the service.

---

## 7. What §14.2 should change before Leg 7 publishes it

Two revisions, both from bends that a real provider hit immediately:

1. **Annotation providers declare a licence and a load state.** Give
   `EdgeDataProvider`, `NodeDataProvider`, `ShapeDataProvider` and
   `WaterwayDataProvider` the `licence -> LayerLicence` and `load_state() ->
   LayerLoadState` members `LayerProvider` already has, and put the
   registration-time refusal (D45) in front of all of them. Without this, an
   unlicensed source's data reaches an Author's screen and an unreachable
   source is indistinguishable from a clear road.
2. **Say that annotation is advisory, in the contract.** `annotate_edges`
   returning the graph invites writing to any key on it. The namespace rule
   (`advisory:*`, never a key core reads) is what keeps FR14/FR29a's advisory
   category from quietly becoming FR128's constraint category, and it should be
   stated where an implementer will read it.

A third, smaller: **`annotate_edges` has nowhere to report what it did.** The
match rate, the events it could not place, and the count outside the bbox are
all things an Author-facing "12 of 14 work zones located" line needs, and a
`-> Graph` return has no room for them. Either the provider keeps per-run stats
(what this spike did) or the signature returns a result object, as
`LayerProvider.fetch_candidates` effectively does.

**Not changed here.** SPIKE-H set the precedent: a spike hands the next story
its target shape rather than editing the contract itself. These belong to
whichever story picks up Leg 7's annotation half; `spikes/SPIKE-17/` carries a
working implementation of all three against real upstreams.

---

## 8. Left open

1. **The volatile half.** Every source measured publishes planned work. An
   incident feed's churn — and therefore an incident TTL — is unmeasured, and
   the source the issue named for it is now keyed.
2. **A keyed source end to end.** No key was available; the redistribution
   question that would make normalisation a P3 event (§5) is therefore
   argued, not tested.
3. **`WaterwayDataProvider` against live USGS.** SPIKE-19 measured the join
   keys; nothing here exercised the Protocol that carries them.
4. **Annotation on the *solve*.** This spike proves the annotation lands on the
   right edges cheaply. It does not measure what happens when a scoring profile
   actually reads `advisory:impact` — including whether an Author can tell an
   advisory-influenced route from a plain one, which is FR3/D33's open half.
