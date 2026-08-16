# SPIKE-21 — Cue derivation from a routed polyline

**Covers:** PRD F1 `[MVP]` / FR46 (per-day cue sheets), FR20 (alternates), FR27
(hazards), FR15 (portages), FR28 (scheduled events); ARCH §5.2/§5.3 (the Field
Runtime consumes a precomputed cue list — this is what produces it), §6.1 (`trips/`);
depends on **SPIKE-20** for where derived output is written · **Priority:** gated
desktop MVP — F1 is `[MVP]` and no document specified the algorithm · **Run:**
2026-08-16, Linux x86_64 · Python 3.12.12

> **Spike question.** Build a cue-derivation pass over the real solved routes from
> SPIKE-01/02/03's shared fixtures. Derive turn cues collapsed to real decision points,
> surface-shift cues with an explicit unknown-tag rule, node-highlight interleaving with
> a minimum-spacing rule, and a labelling rule for a retraced via-node spur. Measure cue
> count per km on all three fixture geometries against a legibility ceiling.
>
> **Done when.** A generated cue sheet for each of the three fixture routes is legible
> at a glance — bounded cues per km, no per-vertex spam, no duplicate cues on a retraced
> spur — surface shifts and node highlights are correctly interleaved in route order,
> and the output conforms to SPIKE-20's trip-payload schema.

---

## Verdict

**The algorithm exists, it is in `plotlines-core`, and it lands inside the ceiling on
every fixture route.** Nine routes across three regions — 132.3 km, 5,235 polyline
vertices, 1,314 junctions — produce **367 cues**, of which 266 are derived turns and 6
are surface shifts. Derived density runs **0.87–2.86 cues/km** against a stated ceiling
of 4.0, and no single kilometre anywhere carries more than 8 cues.

The ceiling was declared before the measurement, and the first implementation
**failed it**: 4.2–7.3 cues/km in Boulder and Davis, with four cues inside twenty
metres at one path/road interchange. Two rules fixed that, and neither is a threshold:

1. **Staying on the same way is not a turn.** A named greenway that swings 60° at a
   bridge and keeps its own name is "continue". This removed **199 of the 509** candidates that
   survived the 30° test — 39%, by far the largest single reduction.
2. **Turns inside 40 m are one manoeuvre.** A staggered crossing or a path-to-road ramp
   reads as three or four turns and is one decision. This removed a further 31.

The threshold sweep is the counter-evidence that matters: **the parameters an
implementer would tune first barely move the result.** Across a 3×3 grid of smoothing
window (10/25/50 m) × straight-through angle (20/30/45°), the Boulder via-loop's turn
count moves only 30→39, and Viroqua's does not move at all (27→28). Tuning angles was
never going to produce a readable sheet; the two structural rules did.

Three results that change what F1 can promise, all in §5.

---

## 1. The funnel

Every candidate, and where it went. Totals across all nine routes:

| Stage | Count | Per km |
|---|---:|---:|
| Polyline vertices (the strawman: one cue each) | 5,235 | 39.6 |
| Junctions the routes pass through | 1,314 | 9.9 |
| … bend below 30° — "continue" | −805 | |
| … same way continues under its own name | −199 | |
| … bend with no alternative (road just curves) | −9 | |
| … coalesced into a neighbouring manoeuvre | −31 | |
| **Turn cues** | **266** | 2.0 |
| Surface shifts | 6 | 0.05 |
| Author nodes, hazards, portages, alternates, start/finish | 95 | |
| **Cue sheet** | **367** | **2.8** |

Per route, with the naive baselines beside the result:

| Region | Shape | Length | Vertices/km | Junctions/km | **Cues** | **/km** | derived/km | Peak/km |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| Boulder | point-to-point | 3.9 km | 56.6 | 15.3 | 22 | 5.71 | 2.86 | 8 |
| Boulder | 20 km loop | 20.6 km | 54.8 | 12.9 | 69 | 3.36 | 2.82 | 7 |
| Boulder | loop, 2 via | 18.6 km | 54.7 | 9.5 | 48 | 2.58 | 1.99 | 6 |
| Davis | point-to-point | 4.3 km | 36.9 | 10.4 | 17 | 3.92 | 1.62 | 6 |
| Davis | 20 km loop | 17.5 km | 48.4 | 12.8 | 60 | 3.44 | 2.81 | 6 |
| Davis | loop, 2 via | 22.4 km | 40.1 | 13.6 | 63 | 2.81 | 2.32 | 6 |
| Viroqua | point-to-point | 5.8 km | 12.8 | 4.2 | 16 | 2.77 | 0.87 | 6 |
| Viroqua | 20 km loop | 18.4 km | 23.7 | 5.5 | 33 | 1.79 | 1.20 | 5 |
| Viroqua | loop, 2 via | 20.9 km | 22.0 | 5.3 | 39 | 1.86 | 1.34 | 5 |

Sample sheets for all nine are in [`samples/`](samples/) — the legibility judgement is
a document you read, not a number, and those are the documents.

---

## 2. Why density has to be judged on the derived half

Boulder's point-to-point shows 5.71 cues/km, above the ceiling, and **that is the right
answer, not a failure.** Its derived density is 2.86/km. The rest is the Author's own
content: two hazards, a portage, a transition, an alternate, four nodes, start and
finish — **eleven cues that do not scale with distance.** On a 3.9 km route they are
2.8 cues/km on their own; on a 20 km route, 0.5.

So the ceiling applies to what the algorithm chooses to emit, and the derivation has no
business thinning an Author's hazard to hit a density target. `derive_cue_sheet`
reports `derived_cues_per_km` and `cues_per_km` separately for exactly this reason, and
the spike's self-check judges the first.

---

## 3. Surface shifts: the rule works, the data mostly is not there

**Six surface cues in 132 km**, and the distribution is the finding:

| Region | `surface` tagged | Known runs on route | Raw transitions | Suppressed as short | **Emitted** |
|---|---:|---:|---:|---:|---:|
| Boulder | 81.7% | 7 | 4 | 0 | **4** |
| Davis | 34.4% | 3 | 0 | 0 | **0** |
| Viroqua | 24.5% | 10 | 7 | 5 | **2** |

The unknown-tag rule does what it was written to do — an absent tag never opens or
closes a cue, so thin coverage produces silence rather than noise. But silence is what
it produces: **Davis emitted no surface cue on any route**, because its routes never
crossed two *known* and *different* surface runs; and **Viroqua — actual gravel
country — emitted two**, five having been suppressed as runs shorter than 150 m.

This is the same measurement SPIKE-03 hit from the other side, where Viroqua's
attainable unpaved share topped out at 7.8% on a network that is genuinely gravel. The
cue sheet cannot be better informed than the map.

**Consequence for F1's AC**, which promises cue sheets "including surface shifts":
surface shifts are **best-effort and coverage-dependent**, and in the thinnest region
they are close to absent. That belongs in the story, not in a support ticket.

**And FR4's third surface class has no source at all here.** No `surface` value means
"singletrack"; it needs `highway` + `tracktype`/`mtb:scale`. `surface_class()`
deliberately refuses to infer surface from highway class — that is the overreach ARCH
**A17** already records for traffic stress, where highway class alone gave rural
Viroqua a 35% traffic floor.

---

## 4. Nodes, hazards, and the retraced spur

**The corridor rule fires and is counted.** Of 54 Author-placed nodes across the nine
routes, **9 fell outside the 150 m corridor** — one deliberately planted per route — and
each was recorded as `off_route` rather than silently dropped. A node the Author placed
and the sheet never mentions is a support question later; a counted one is a UI message.

**Safety cues never merge.** Every route carried two hazards (`high` and
`mandatory_reroute`) and a mandatory portage placed deliberately close to other
content; all survived every crowding rule, in all nine routes. Only **4 advisory cues in
total** merged away across the whole run — the crowding rule is a backstop, not a
workhorse, because the upstream rules had already removed the crowding.

**Retrace marking works and is per-cue.** Six of the nine routes ride some road twice
(46 m to 2.7 km of it), which is SPIKE-01's lollipop appearing exactly where it said it
would:

| Route | Retraced | Cues marked |
|---|---:|---:|
| Boulder 20 km loop | 213 m | 4 |
| Boulder loop, 2 via | 521 m | 4 |
| Davis 20 km loop | 46 m | 0 |
| Davis loop, 2 via | 1,494 m | 4 |
| Viroqua 20 km loop | 1,209 m | 3 |
| Viroqua loop, 2 via | 2,724 m | 9 |

Davis's 46 m of retraced road carries no cue, so nothing is marked — correct, and worth
stating: the flag marks *cues standing on* re-ridden road, not the road itself. On the
sheet it reads as `Turn left onto Table Mesa Drive _(retrace)_`, which is the
difference between a rider trusting the instruction and wondering why they are being
sent down a road they just came up.

Two refinements came out of reading the sheets rather than the numbers: consecutive
`Turn back` cues twenty metres apart are one turnaround, not two; and a loop's finish
cue is not marked `retrace` merely because a loop ends where it began.

---

## 5. What this changes

### 5.1 Cue derivation runs in the core (ARCH D31)

It reads junction degree, `surface`, `name` and `osmid` — graph attributes only the
routing side holds — so a client implementation would need the graph shipped to it, and
sidecar and hosted deployments would drift apart on the same route (P1). It is also
cheap: **1.1–9.2 ms** per route for 74–1,127 vertices, which extrapolates to well under
a second for the 45,912-vertex week-scale payload SPIKE-20 measured. It runs per solve,
in `plotlines-core/trips/cues.py`, beside `compose_day`.

### 5.2 The removed turn weight shows up here first

The PRD deliberately dropped "fewest turns" from the scoring model (§4.3, ARCH **D6**),
so nothing in the solver discourages a zig-zag. That decision is invisible until a cue
sheet exists — and then it is a Boulder loop with a derived turn every 360 m. Nothing
in this spike argues for reversing D6; what it establishes is that **cue density is the
place a route's turniness becomes visible to an Author**, and D1's dashboard is where
it should be surfaced (a cues-per-km readout costs nothing now that the derivation is
cheap).

### 5.3 F1's acceptance criteria need two qualifications

F1 promises per-day cue sheets "with turns, distances, surface shifts, node highlights,
portages, hazards, and scheduled events". Everything on that list is produced and
ordered. Two of them are narrower than the sentence implies:

* **Surface shifts are coverage-dependent** (§3) — best-effort, absent where OSM is
  quiet, and never inferred from road class.
* **Turn cues name a way where OSM names one.** 46% of Boulder's edges carry a `name`;
  the rest cue as "the bike path", "the service road", "the unnamed residential
  street". A rider gets a manoeuvre and a road *type*, not always a road name.

### 5.4 `cue.retrace` — a schema patch, as predicted

SPIKE-20 closed with the claim that adding a field to `cue` would be "a schema patch;
discovering there was nowhere to put the output would have been a rewrite". This spike
needed exactly one new field, and that is what it cost: `retrace` added to
`docs/schemas/trip_payload.schema.json`, to the Python dataclass, and to the Dart
domain class, with the payload schema version going **1.0.0 → 1.1.0** (additive,
backward compatible).

**Verified across the client boundary**, not asserted: the Boulder cue payload went
through SPIKE-20's Dart harness — 3 cue sheets, **139 cues in, 139 out, 8 retrace flags
preserved**, byte-identical output, and drift returned the same bytes it was given.

---

## 6. The algorithm, stated

For anyone implementing against this rather than reading the code:

1. **Trace the drawn polyline**, not the junction path — shape lives on edge geometry,
   and cueing against the junction path puts every distance short.
2. **At each junction**, take the bearing over 25 m of route before and after. Below
   30° of change, emit nothing.
3. **Suppress** where the way continues under the same name (or shares an OSM way id
   when unnamed) and the change is under 120°.
4. **Suppress** where the node's undirected degree is under 3 — a bend with no
   alternative. Reversals are always cued, whatever the degree; that is a spur's
   turnaround, and a dead end has degree 1.
5. **Coalesce** turns within 40 m into one manoeuvre; opposite directions become a
   jog, and consecutive reversals become one turnaround.
6. **Surface**: emit only on a change between two *known* classes, each persisting
   150 m or more. Unknown is never a value.
7. **Project** Author nodes, hazards, portages and alternates onto the route; drop —
   and count — anything beyond a 150 m corridor.
8. **Merge** advisory cues within 25 m into their higher-priority neighbour. Hazard,
   portage, transition, start and finish never merge and never drop.
9. **Mark** every cue standing on road already ridden as `retrace`.

Thresholds are `CueSettings` fields, not constants, and the sweep in `results.json`
shows what moving them costs.

---

## 7. Limits — what this spike did not establish

* **No paddling or hiking route was cued.** All nine routes are on the cycling graph;
  the paddling graph is Leg 3 (SPIKE-19) and has no `surface`, `name` or junction
  semantics to speak of. A water cue sheet is portages, hazards and gauge notes — the
  authored half, which works here — plus nothing derived, which is untested.
* **No scheduled-event cue was exercised end to end.** The `event` kind exists, the
  node carries `scheduled`, and the interleaving is the same path as any node, but the
  timeline-conflict half of FR28/C12 is P1 work and no event node was placed.
* **Turn instructions are not localized.** English strings are built in the core. FR83
  (language selection) will want them as structured data the client renders — the cue
  carries `kind`, `modifier`, `bearing_deg` and `ref_id` alongside the text, so the
  raw material is there, but nothing has been done with it.
* **Legibility is judged by one reader.** The ceiling (4 derived cues/km, peak 8) was
  declared in advance and is defensible, but it is not a user study.
* **Elevation is not cued.** No "steep descent ahead" cue exists, though the data does
  (FR89's per-edge gain). Whether a grade cue belongs on a sheet is a product call this
  spike did not take.

---

## Reproducing

```bash
PYTHONPATH=core .venv/bin/python spikes/SPIKE-21/run.py
```

Needs the shared graph fixtures (`.venv/bin/python spikes/shared/regions.py`) and
`jsonschema`. The Dart leg reuses SPIKE-20's harness and is skipped, with a reason
recorded, if the Dart SDK is absent. `results.json` holds every number here;
`samples/*.md` are the nine sheets; `payloads/*.json` are the schema-validated trip
payloads the sheets live in.
