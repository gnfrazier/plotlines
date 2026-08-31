# SPIKE-E — results

**Run:** 2026-08-31 · **Issue:** [#171](https://github.com/gnfrazier/plotlines/issues/171) ·
**Covers:** PRD **FR29** (amended), **FR29a**, FR10 · stories **C13**, **C13a** `[P1]` ·
ARCH §7.4, **Q14** ★

**Reproduce:** `core/.venv/bin/python spikes/SPIKE-E/run.py --dry-run` — 21 clauses,
offline, from the committed pulls. Every figure below is one of them or comes out of
`results/*.json`.

---

## Verdict

**Driving ships on the existing *solver* and not on the existing *graph*, and the
difference is one line of configuration rather than a model.** `multimodal/modes.py`
gives driving `network_type="drive"`, which is not a routing choice — it is an **OSMnx
download filter**, and that filter excludes `highway=track` **and** `highway=service`
before a single way reaches the graph. Both of the trailhead access roads in this set
that are not `unclassified` are exactly those two classes, so the shipped configuration
cannot see the last mile it was added to route.

**The engine is fine and the weights are decoration.** Cold solves are 2.8–14.5 ms
(warm 1.4–3.9 ms) on graphs of 722–12,702 edges; nothing about driving costs more than
cycling. But at driving's shipped `directness=0.95`, `edge_cost` scales the entire rest
of the profile by `1 − directness` = 0.05, and sweeping `surface_paved` from −1 to +1
leaves the route **byte-identical in three of the four approaches**.

**FR29a's advisory is buildable, honest, and was about to be set to the wrong
threshold.** The prototype flags without ever rerouting (demonstrated on all four
approaches: identical edge walk before and after assessment). But at the coverage floor
this spike started with — the pre-registered `opportunistic` band, 20% — a real approach
in a shared fixture region, 35% surveyed and gravel for the rest, comes back **"no
signal on this route exceeds 2WD"**. The thinning model agrees from the other side. The
floor for that sentence is the **`read` band, 70%**; below it the only honest state is
*unsurveyed*.

**Q14 closes with a bill of four items, none of which is a second scorer** — so
FR130's "a mode is a row of data, never a branch of code" survives. The row just needs
more columns than `network_type`.

---

## 1 · The routing half (ARCH Q14)

### 1.1 The graph does not contain the last mile, and says nothing about it

`network_type="drive"` resolves to an Overpass filter whose `highway` exclusion list
contains both `service` and `track` (`filters.py` carries osmnx 2.1.1's string
verbatim; `tests/test_filters.py` asserts it still matches the installed package).
Measured, per approach, against the same pull:

| approach | `drive` | `drive_service` | `drive_track` | what the shipped filter drops |
|---|---:|---:|---:|---|
| **boulder** | route ends **265 m short** | 11 m | 11 m | Gregory Canyon Road is `highway=service` |
| **viroqua** | 1 m | 1 m | 1 m | nothing that matters — the landing is on a town road |
| **bigsandy** | 98 m | 98 m | 98 m | 57% of the approach corridor (below) |
| **middlefork** | 98 m | 56 m | 56 m | Boundary Creek Campground Road (NFSR 549) is `highway=service` |

**The Boulder failure is silent, which is the part that matters.** The solve succeeds,
returns a route, reports a distance, and never raises: the destination snaps 265 m to
the nearest surviving node and `nearest_node`'s 3 km `OutsideGraphExtent` guard —
added by issue #154 for exactly this class of quiet substitution — is nowhere near
tripping. An Author gets a cue sheet that stops at the canyon mouth and no indication
that the road they asked about is not in the map they were given.

**Within 15 km driving distance of the trailhead** — the *approach corridor*, grown
along the road rather than as a straight-line ball — the shipped filter keeps:

| approach | corridor on `drive` | on `drive_track` | kept |
|---|---:|---:|---:|
| boulder | 700.5 km | 982.3 km | 71.3% |
| viroqua | 556.1 km | 721.5 km | 77.1% |
| **bigsandy** | **32.5 km** | **76.3 km** | **42.6%** |
| middlefork | 33.0 km | 34.2 km | 96.3% |

At the one approach in the set that is genuinely remote, **the shipped configuration
discards 57% of the road network around the trailhead**. The through-route survives
because a single `unclassified` road happens to run the whole way in; nothing else
does.

The reconstruction is not taken on trust: a live `network_type="drive"` pull of the
Boulder bbox agrees with the offline `drive` variant on **99.61% of way ids** (12
live-only, 2 rebuilt-only, of ~3,000 — boundary effects of `truncate_by_edge`).

### 1.2 The solver does not flee to pavement — and that is structural, not a compliment

Big Sandy's solved approach is 40.3 km gravel, 18.5 km paved, 13.0 km untagged, of
71.8 km. The solver takes the dirt because there is no alternative to take: on a remote
approach the route is **forced**, and the fear the issue names ("does the cost model
produce a sane route on them rather than fleeing to the paved network") cannot arise
where it was worried about. It could only arise in the network-rich part of the drive,
and there —

### 1.3 Driving's weights change nothing

`edge_cost` collapses every penalty toward pure distance with
`penalty = 1 + (penalty − 1) × (1 − directness)`. Driving ships `directness=0.95`, so
its `quiet=0.1`, `scenic=0.2` and `surface_paved=0.4` are applied at **one twentieth
strength**. Sweeping the one non-default surface dial:

| case | boulder | viroqua | bigsandy | middlefork |
|---|---|---|---|---|
| `surface_paved` −1 → +1 | identical | 31.3% → 35.2% paved (86–100% edge overlap) | identical | identical |
| `directness=0.5` | identical | 38.0% paved | identical | 97.8% overlap |
| `directness=0.0, surface_paved=+1` | 24.2% overlap | 82.8% overlap | identical | 97.8% overlap |

The dial is not broken — at `directness=0.0` it moves routes decisively — it is
**switched off by the profile it ships in**. A weight that changes no route is worse
than an absent one, because it invites tuning that cannot have an effect.

**What driving actually wants is a time cost, not a distance cost**, which is the next
finding.

### 1.4 The reported time is wrong on exactly the leg FR29 was written for

FR29 requires *"a real route with distance, time, and a cue sheet"*. Time today is
`base_speed_kmh=60.0`, flat, for every driving edge. Against a surface-aware estimate
built from tags **already on the edge** (`route.SPEED_KMH`, pre-registered; the ratios
are the point, not the absolute values):

| approach | km | reported (flat 60) | surface-aware | error |
|---|---:|---:|---:|---:|
| boulder | 3.05 | 3.0 min | 3.0 min | +0.0% |
| viroqua | 7.64 | 7.6 min | 7.6 min | +0.0% |
| **bigsandy** | **71.77** | **71.8 min** | **129.6 min** | **−44.6%** |
| middlefork | 66.73 | 66.7 min | 55.7 min | +19.7% |

Nearly an hour short on the canonical approach, and 20% long on the one that is mostly
paved highway. The flat speed is not conservative in one direction; it is wrong in
both, and it is worst on the drive whose length is the reason the requirement exists.

### 1.5 Two shipped defects this spike walked into

**(a) `trips/cues.py:route_polyline` — edge spans do not tile the route.** *(Filed as [#205](https://github.com/gnfrazier/plotlines/issues/205).)*
`start_index = len(coords)` is taken *before* the edge's own points are appended, so
every edge after the first reports `start_m` at its **second** geometry vertex and its
first sub-segment belongs to no edge at all. Measured on the four solved approaches:

| approach | polyline | covered by spans | unattributed |
|---|---:|---:|---:|
| boulder | 3,045.6 m | 2,240.1 m | **26.4%** |
| viroqua | 7,636.1 m | 6,199.5 m | 18.8% |
| bigsandy | 71,774.0 m | 55,634.7 m | 22.5% |
| middlefork | 66,734.8 m | 57,458.1 m | 13.9% |

Anything that integrates over spans under-counts by that much. `surface_cues` computes
run lengths from `edge.start_m`/`end_m` and suppresses runs below
`surface_min_run_m = 150 m`, so a genuine 160 m surface run can be silently dropped,
and every surface cue is placed one sub-segment late. No test asserts the current
behaviour. The correction is `start_index = max(0, len(coords) - 1)`.

**(b) `graph/regions.py` cannot download half of what `routing/access.py` reads.** *(Filed as [#206](https://github.com/gnfrazier/plotlines/issues/206).)*
The product extends osmnx's `useful_tags_way` with `surface`, `tracktype`, `smoothness`,
`maxspeed`, `lanes`, `bicycle` — and stops. Not requested: **`4wd_only`,
`motor_vehicle`, `motorcar`, `ford`**. And `barrier` is worse than unrequested — OSM
tags it on the *node*, and `useful_tags_node` (untouched, `["highway", "junction",
"railway", "ref"]`) carries none of it either. Consequences on a graph the product
builds today:

* **two of FR29a's six signals are unreadable** (`4wd_only`, `motor_vehicle`);
* driving's legality row keys on `access_key="motor_vehicle"`, which is never present,
  so `MODE_CONSTRAINTS["driving"]` silently degrades to the generic `access=*` rule —
  a way tagged `access=private; motor_vehicle=yes` is wrongly excluded and one tagged
  `motor_vehicle=no` wrongly admitted (53 ways carry `motor_vehicle` in these pulls);
* `ford_passable=False` never fires (5 ways carry `ford`);
* `_BARRIER_DEFAULTS` is unreachable **for every mode**, including driving's own
  `gate`/`bollard` row — which ARCH §7.4 cites as the reason a driving leg is a route
  at all: *"a bollard or gate across a forest road is the whole reason FR29's driving
  leg exists as a route rather than a note."*

This is punch-list §5.3's dependency, measured. The gap is not only in the markdown.

### 1.6 One legality value is wrong for this mode

`MODE_CONSTRAINTS["driving"].excluded_values` includes **`destination`**, carried over
from cycling's row where `bicycle=destination` means area-restricted access. For a
driving *access leg* the destination is the trailhead: `motor_vehicle=destination` is a
road the Character is explicitly entitled to drive. Six edges are excluded on this
ground in Boulder alone. It belongs in the advisory's `access_notes` — "local/
destination traffic only" — not in the hard-exclusion set. (The prototype in
`advisory.py` already treats it that way.)

---

## 2 · The advisory half (FR29a)

### 2.1 Coverage, four denominators, ways % (km %)

Widest to narrowest, SPIKE-C's discipline. `*` marks a cell with under 30 eligible
ways: **n/a, not absent** — an unmeasurable cell and an empty one are different
findings.

| approach | scope | ways | km | `surface` | `smoothness` | `tracktype` | `4wd_only` | `motor_vehicle` | **any signal** |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| boulder | network | 7,434 | 578.8 | 79.9 (84.9) | 1.2 (1.0) | 38.5 (32.4)* | 0.0 | 0.6 (1.1) | **80.0 (84.9)** |
| | corridor | 7,251 | 565.0 | 80.4 (85.3) | 1.2 (1.0) | 40.0 (37.5)* | 0.0 | 0.2 (0.5) | 80.4 (85.3) |
| | route | 33 | 3.0 | 97.0 (91.3) | 3.0 (3.8) | — | 0.0 | 0.0 | 97.0 (91.3) |
| | last mile | 33 | 2.2 | 97.0 (88.6) | 3.0 (4.7) | — | 0.0 | 0.0 | 97.0 (88.6) |
| viroqua | network | 2,521 | 517.5 | 24.8 (33.0) | 1.5 (2.2) | —* | 0.0 | 0.0 | **25.0 (33.3)** |
| | corridor | 1,983 | 368.6 | 22.0 (27.7) | 1.4 (2.1) | —* | 0.0 | 0.0 | 22.3 (28.2) |
| | route | 29* | 7.6 | 44.8 (35.2)* | 0.0* | —* | 0.0* | 0.0* | 44.8 (35.2) |
| | last mile | 11* | 4.6 | 27.3 (37.9)* | 0.0* | —* | 0.0* | 0.0* | 27.3 (37.9) |
| bigsandy | network | 1,033 | 654.8 | 22.6 (24.3) | 4.3 (3.3) | 0.0 | 0.0 | 0.0 | **61.0 (62.8)** |
| | corridor | 143 | 38.4 | 25.9 (40.6) | 21.7 (37.9) | 0.0 | 0.0 | 0.0 | 93.0 (95.9) |
| | route | 92 | 71.8 | 82.6 (81.9) | **33.7 (19.6)** | —* | 0.0 | 0.0 | 87.0 (85.1) |
| | last mile | 15* | 3.4 | **100.0 (100.0)*** | **100.0 (100.0)*** | —* | 0.0* | 0.0* | **100.0 (100.0)** |
| middlefork | network | 1,081 | 668.3 | 33.6 (31.3) | 0.3 (0.5) | 11.5 (17.0) | 0.0 | 0.0 | **68.5 (81.4)** |
| | corridor | 17* | 17.1 | 35.3 (3.7)* | 0.0* | —* | 0.0* | 0.0* | 35.3 (3.7) |
| | route | 93 | 66.7 | 78.5 (51.3) | 0.0 | —* | 0.0 | 0.0 | 78.5 (51.3) |
| | last mile | 7* | 4.9 | 28.6 (0.6)* | 0.0* | —* | 0.0* | 0.0* | **28.6 (0.6)** |

### 2.2 `4wd_only` is not a signal; it is a wish

**Zero tagged ways in 12,069 ways / 2,419 km across four regions**, including two
National Forests whose approach roads are the archetype for the tag. FR29a names it
first among the road's own signals and C13a's AC requires reading it. It can stay in
the code as an opportunistic read — it costs nothing and it is unambiguous where it
appears — but no requirement should rest on it and no coverage statement should count
it.

### 2.3 `smoothness` is absent as a network fact and present exactly where the road is bad

At network scale it is `absent` in all four regions (0.3–4.3%), which is the figure a
naive coverage pass would report and would be the wrong figure to act on. On the Big
Sandy **route** it is 33.7% of ways, and on the **last 3.4 km** it is **100%** — 31 ways
tagged `smoothness=bad`, the stretch every trip report warns about. ARCH §7.4 calls it
*"the strongest single indicator"* and that survives, with the denominator corrected:
it is the strongest indicator **on the roads that need one**, not on the network.

### 2.4 The narrowing goes both ways, and the reason is the same fact

The issue's premise was that *"the network average will be flattering and the approaches
are the whole point."* Half right, and the exception is instructive:

* **Big Sandy inverts it.** Route 85.1% of km surveyed against 62.8% for the network;
  the last mile is 100%. The people who tag a remote forest road are the people who
  drove it, so coverage concentrates on the roads someone cared enough to record.
* **Middle Fork confirms it absolutely.** The last 5 km is **0.6% surveyed by km** — the
  put-in road is a `highway=service` with a single `surface=gravel` stub, on the very
  approach FR29's sentence describes.

Both are the same mechanism (coverage tracks who drove and edited, not the road), which
is why the advisory has to compute and state coverage **for the last mile separately**.
A leg-level figure of 51.3% would have described the Middle Fork approach as
half-surveyed when the part that matters is not surveyed at all.

### 2.5 The advisory flags, and never reroutes

Demonstrated rather than asserted: for each approach the route is solved, assessed at
all four declared capabilities, and solved again — the edge walk is **identical before
and after** in all four (`run.py` clause; `tests/test_advisory.py` adds that `assess`
does not mutate its input at all). The `Advisory` type carries **no `passable`, `ok` or
`clear` field**: there is no value a template could render as a clean bill of health,
the same trick SPIKE-C used for `CoverageNote`.

Real output, Big Sandy, declared 2WD:

> **1 section(s), 42.6 of 71.8 km, exceed the declared 2WD — up to AWD. Read on 85% of
> this leg's kilometres; the rest is unsurveyed.**
>
> cue @ 29.13 km — *surface=unpaved; smoothness=bad (robust wheels); highway=track, no
> surface or grade tagged for 42.6 km on Big Sandy Elkhorn Road / Lander Cutoff Road /
> Big Sandy Opening Road — needs AWD, you declared 2WD*

**Per-edge flagging is unreadable and merging is not optional.** The same route
produces **65 raw flagged runs**, because condition tagging is fragmented along one
continuous road — a mapper tags the stretch they drove. `advisory.py` merges runs at
the same requirement across **unsurveyed** gaps up to 500 m and never across a stretch
tagged clear, taking 65 → 1. Without that rule C13a's "flags the sections" produces a
cue sheet nobody reads, and an advisory nobody reads does not warn.

### 2.6 The finding that changes the requirement: the honesty floor is 70%, not 20%

The spike pre-registered SPIKE-C's three bands and started with the `opportunistic`
floor (20%) gating the "no contrary signal" sentence. On real data that is wrong, and
it is wrong in the dangerous direction:

**Live, in a shared fixture region.** Viroqua's approach to Sidie Hollow is 35.2%
surveyed by km, and the unsurveyed remainder is Driftless coulee gravel. At floor 20
the advisory reports *"No signal on this route exceeds 2WD"*. At floor 70 it reports
*"Not enough of this route is surveyed to advise"*. The second is true.

**And from the harm model.** Thinning tags per way (deterministic, 400 trials per
retention step, seeded) and asking how often the **confidently-clear** state appears on
a route that truly has a flag:

| floor | worst false-clear | ceiling | breached up to |
|---|---:|---:|---:|
| `opportunistic` (20%) — middlefork | **18.8%** | 10% | 60% retention |
| `read` (70%) — middlefork | 0.0% | 10% | never |
| either floor — bigsandy | 0.0% | 10% | never |

The pre-declared ceiling — the share of genuinely rough approaches that may come back
*"no contrary signal"* rather than *"unsurveyed"* — is 10%, SPIKE-C's number for the
same class of question. At the opportunistic floor Middle Fork breaches it at every
retention level at or below 60%. At the read floor nothing breaches it anywhere.

**Why the two approaches differ is the finding underneath the finding.** Big Sandy
never falsely clears because the same tags that raise the flag are the tags that count
as coverage: thin them and the honesty statement degrades in lockstep with the warning.
Middle Fork does falsely clear because its coverage lives somewhere *else* — 34 km of
well-tagged paved highway — while the rough part is a short unsurveyed tail. **That
shape is exactly FR29's own sentence**: a long ordinary drive with a harrowing last
mile. The advisory is at its least reliable on precisely the trip the requirement was
written for, unless the coverage that gates it is measured on the last mile.

This is independent corroboration of the pre-declared 70% band, arrived at from the
damage rather than from precedent — the same shape as SPIKE-C's harm-derived ≈32–38%
floor, landing on the opposite side because an any-of advisory fails differently from a
worst-of grade.

---

## 3 · What this decides

**ARCH Q14 → closed.** Driving ships on the existing solver. It does **not** ship on
the existing graph configuration, and the bill is four items, none of them a scorer:

1. **A driving download filter that includes `track` and `service`.** `network_type`
   is a `TraversalMode` column today; it needs to be able to carry a custom filter, or
   driving needs its own named network type. Without it the mode cannot see the roads
   it was added for.
2. **The tag list extended** — `4wd_only`, `motor_vehicle`, `motorcar`, `ford` on ways,
   and a decision about node-tagged `barrier` (fold onto incident edges at graph build,
   which `routing/access.py`'s docstring already names as graph-construction's job).
3. **`destination` out of driving's `excluded_values`**, surfaced as an access note.
4. **A time model that reads the edge**, not a flat mode speed. B7/FR16 owns this; FR29
   cannot claim "a real route with distance and time" until it lands.

**FR29a → ships, with the honesty floor at the `read` band.** `no_contrary_signal`
requires ≥70% of the leg's kilometres surveyed; below that the state is
`insufficient_signal` and there is no phrasing in common between them. Coverage is
computed and stated **per last mile as well as per leg**.

**C13a's AC narrows** on the evidence: `4wd_only` is an opportunistic read rather than
a required signal; `motor_vehicle` produces an access note, not a capability flag; the
"specific signal that triggered the flag" must be reported on a **merged section**, not
per edge.

**C13's AC** keeps its shape but its "time" clause is blocked on item 4 above.

---

## 4 · Left open, deliberately

* **Elevation is not in the model.** The rebuilt graphs carry no DEM, so `grade_abs` is
  0.0 everywhere and driving's `peaks` weight is 0.0 — the route choice measured here
  is elevation-independent by construction, which is correct for the routing question
  and **not** correct for a time estimate on a mountain road. A grade-aware speed model
  would widen the Big Sandy error, not narrow it.
* **`route.SPEED_KMH` is a straw man on purpose.** It exists to price the flat 60 km/h
  against *something that reads the tags*, not to be the model. B7/FR16 owns the real
  one.
* **Four approaches, four regions, one continent.** The `smoothness` result in
  particular is a North American measurement; SPIKE-C found European tagging cultures
  differ by two orders of magnitude on a comparable schema, and nothing here rules that
  out for condition tags.
* **One snapshot, not a trend.** Whether approach-road condition tagging is *growing*
  is unmeasured, and the two remote regions are exactly the places where one dedicated
  mapper moves the figure.
* **The advisory is not wired to a cue sheet in product code.** `advisory_cues` emits
  `trips.cues.Cue`-shaped dicts under a new `kind="advisory"` — deliberately not
  `hazard`, because a hazard is unconditional and unsuppressible (FR115,
  `cues._SAFETY_CRITICAL`) while this is a comparison against a declaration the Author
  can change. Filing it as a hazard would make an advisory unhideable and a hazard
  arguable, and both of those are worse.
