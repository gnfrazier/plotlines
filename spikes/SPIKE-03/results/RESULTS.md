# SPIKE-03 — Min/max weight-band convergence

**Covers:** FR6 (Story A5) · **Priority:** Implementation-informing · **Run:** 2026-08-14, Linux x86_64, Python 3.12

> **Spike question.** Run realistic competing bands (e.g. high climbing-min + low
> traffic-max) across varied geographies; measure how often a valid route exists and
> whether it's good.
>
> **Done when.** Band behaviour is characterised well enough to set sensible default
> ranges and know how often A6's conflict path will fire.

---

## Verdict

**Bands converge fine. Absolute band *defaults* are what over-constrain.**

The same search, on the same three graphs, at the same 20 km target:

| Band defaults | Feasible |
|---|---|
| Fixed absolute values (climbing 100–400 m × traffic ≤ 15/25/35%) | **8 / 36 — 22.2%** |
| Derived from each region's attainable envelope | **3 / 3 — 100%** |

Nothing about the solver changed between those two rows. The 77.8% failure rate is
manufactured entirely by asking for numbers the place cannot produce — and it would
have been read as "min/max bands don't work" if the envelope had not been measured
separately.

**So: band sliders must open on the range the region can actually deliver.** That one
decision is the difference between A6 firing on four requests in five and firing
almost never.

---

## 1. What each region can actually deliver (20 km loop)

Measured by running the 10 weight archetypes and recording the range of each realised
metric. This is the number a UI needs *before* it draws a slider.

| Metric | Boulder, CO | Davis, CA | Viroqua, WI |
|---|---|---|---|
| climbing | **154–354 m** | **13–25 m** | **175–288 m** |
| traffic exposure | 17–44% | 18–42% | **35–48%** |
| scenic share | 33–60% | 10–62% | 9–19% |
| unpaved share | 0–3.5% | 0–0% | 0.5–7.8% |
| distance (20 km ask) | 16.1–23.6 km | 17.3–22.9 km | 17.0–22.9 km |

Two entries explain most of the grid failures below:

- **Davis tops out at 25 m of climbing.** Every `climb_min ≥ 100 m` cell fails there,
  and no weight can fix it. This is the correct answer — it is a flat town.
- **Viroqua's traffic exposure has a *floor* of 35%.** Rural roads are tagged
  `tertiary`/`secondary`, and the traffic model reads highway class. Only the single
  `climb ≥ 100 m, traffic ≤ 35%` cell squeaks through. See §5 — this one is a
  modelling artifact, not a fact about Wisconsin.

## 2. The grid: how often does A6 fire?

Climbing-min × traffic-max, 12 cells per region. `Y` = a route satisfying both bands
was found.

```
                        climb_min: 100  200  300  400
  boulder  traffic ≤15%             Y    .    .    .
           traffic ≤25%             Y    Y    Y    .
           traffic ≤35%             Y    Y    Y    .
  davis    traffic ≤15%             .    .    .    .
           traffic ≤25%             .    .    .    .
           traffic ≤35%             .    .    .    .
  viroqua  traffic ≤15%             .    .    .    .
           traffic ≤25%             .    .    .    .
           traffic ≤35%             Y    .    .    .
```

| Region | Feasible | Median solves | Slowest cell |
|---|---|---:|---:|
| boulder | **7/12 (58.3%)** | 14 | 6.0 s |
| davis | 0/12 | 28 | 3.9 s |
| viroqua | 1/12 (8.3%) | 23 | 0.7 s |
| **all** | **8/36 (22.2%)** | | |

Boulder's pattern is the one that shows the bands working *as intended*: climbing 300 m
is reachable at traffic ≤25% but not at ≤15%, and 400 m is unreachable at any traffic
level. That is a genuine trade-off surface, and it is exactly what A5 promises to
navigate.

Note the cost asymmetry: **feasible cells are cheap (often 1 solve — the first
archetype lands inside), infeasible cells are expensive (up to 30, the full budget).**
Failure is where the time goes, which reinforces SPIKE-02's asynchronous-diagnosis
conclusion.

## 3. How narrow can a two-sided band be?

Two-sided bands centred on each region's climbing midpoint, shrinking half-width:

| Half-width | Boulder | Davis | Viroqua |
|---|---|---|---|
| ±40% | ✅ 1 solve | ✅ 1 solve | ✅ 1 solve |
| ±20% | ✅ 1 solve | ✅ 1 solve | ✅ 1 solve |
| ±10% | ✅ 15 solves | ✅ 1 solve | ✅ 3 solves |
| ±5% | ✅ 15 solves (241–266 m) | ✅ 1 solve (18–20 m) | ❌ 27 solves (220–243 m) |

**Bands hold down to ±5% in two regions of three**, and the solve count is the early
warning: Viroqua climbs from 3 solves to the full 27-solve budget as it fails, while
the regions that succeed stay flat. A UI can use that signal to warn before a
tightening band actually breaks.

Davis passing ±5% deserves a caveat rather than credit: ±5% of 19 m is a **±0.95 m**
window on total climbing, and it succeeds only because nearly every route in a flat
town lands in that window. No routing engine should *promise* that resolution. **Band
precision should be floored in absolute units** (say, 25 m of climbing), not just
percentages, or the control implies a precision the data cannot support.

## 4. Are the routes any good?

With envelope-relative bands (climbing above the midpoint, traffic in the lower 40% of
its range), all three regions found a route:

| Region | Feasible | Distance error | Overlap | Max grade |
|---|---|---:|---:|---:|
| boulder | ✅ | **+14.8%** | 2.6% | 41.9% ⚠ |
| davis | ✅ | −4.0% | 0.8% | 8.6% |
| viroqua | ✅ | **+14.3%** | 3.4% | 12.1% |

Loops are clean — overlap under 3% everywhere. But **distance drifts up to +14.8%**,
because distance was not itself banded and the search happily spent mileage to satisfy
climbing and traffic. That is the A6-forbidden silent compromise arriving through the
back door: the Author asked for 20 km and got 23 km without being told.

**Distance must be a band like any other, not a soft target.** It is already supported;
it simply has to be included by default.

The 41.9% max grade in Boulder is a data-quality flag, not a route: a short edge where
OSM geometry and the 30 m DEM disagree (a switchback, a bridge, a stair). Grades want
sanity clamping before they drive anything user-visible.

## 5. Two weight-shape findings that bound what bands can do

**FR4's surface weight is unipolar and cannot seek gravel.** `surface` runs 0.0
(indifferent) → 1.0 (prefer paved). There is no value meaning *prefer unpaved*, so an
`unpaved ≥ 30%` band is unsatisfiable everywhere — Viroqua's whole envelope is
0.5–7.8% even though it is gravel country, and Davis's is a flat 0%. FR4 says the weight sets "relative preference across
paved / gravel / singletrack", which needs a **bipolar weight like FR2's `peaks`**
(−1 avoid … 0 indifferent … +1 seek). This is the cause of SPIKE-02's `gravel_minimum`
verdict.

**Traffic stress is inferred from highway class alone**, which overstates rural traffic
badly — hence Viroqua's 35% floor on empty county roads. The fixtures now retain
`maxspeed` and `lanes` for a better model; nothing here uses them yet.

**And one from the fixtures:** osmnx's default `useful_tags_way` **does not include
`surface`**. The first fixture build reported surface tagged on 0.0% of edges in all
three regions — which reads as "OSM has no surface data" and actually meant "we never
asked for it". With it requested: **Boulder 81.7%, Davis 34.4%, Viroqua 24.5%.** Any
surface-based band inherits that coverage as a ceiling on how well it can work.

## 6. The FR6 ambiguity this spike had to resolve

FR6 says Authors set "a min and max on any **weight**". A5's AC says the engine
"returns a route **within all bands** where one exists; where none exists, A6 governs."

Those two readings cannot both hold. A band on a *weight value* can never be infeasible
— any number inside the band is a legal weight — which makes A5's "where none exists"
clause unreachable and A6 dead code. Everything above therefore treats a band as an
acceptance range on the **realised route attribute**: not "climbing weight between 3
and 4" but "between 400 and 600 m of climbing". Only that reading makes A5's own AC
meaningful, and it is what an Author means anyway.

Consequence: FR6's wording should say *attribute*, or A5's AC should be reworded. As
written they disagree.

---

## 7. What this changes

1. **Derive band defaults from `probe_envelope`, never from constants.** 19.4% → 100%
   feasible on the same solver. Probing costs 10 solves (0.4–3.5 s) and can be cached
   per region and distance.
2. **Always band the distance.** Otherwise the compromise quietly eats the target
   mileage (+14.8% measured).
3. **Floor band precision in absolute units**, not just percentages (±5% of 23 m is
   ±1.15 m).
4. **Warn on tightening at ~±10% of the envelope**, using solve count as the signal.
5. **Make FR4's surface weight bipolar**, matching FR2's `peaks`. Until then, no
   unpaved-minimum band can be honoured.
6. **Improve the traffic model beyond highway class** — `maxspeed`/`lanes` are now in
   the fixtures for it.
7. **Set `useful_tags_way` explicitly** wherever graphs are built, or FR4 is inert.
8. **Resolve the FR6/A5 wording disagreement** in favour of realised attributes.

## 8. What this does not prove

- **One target distance (20 km), one start point per region.** Band behaviour at 5 km
  and 150 km is unmeasured, and the envelope is certainly distance-dependent.
- **Three regions, all US, all in-network.** European and non-grid networks untested.
- **Two banded metrics at a time in the grid** (climbing, traffic); real requests may
  band four or five at once, which is strictly harder and slower.
- **The search is incomplete** (archetypes + coordinate descent). Every "infeasible"
  here means "not found in ≤30 solves". A cell marked `.` could in principle have a
  route a better search would find — the envelope measurements in §1 are the sound
  part, the grid is not.
- **`scenic_frac` is a proxy** built from way names and highway class, not FR5's
  Author-set POI types, which need `content/`.
- **Route *quality* is measured structurally** — overlap, distance error, grade. Not
  whether anyone enjoys the ride.

## Reproducing

```bash
.venv/bin/python spikes/shared/regions.py          # build fixtures (network needed)
.venv/bin/python spikes/run_routing_spikes.py 03   # -> results/results.json
```

Figures here were re-measured after SPIKE-01 changed loop generation (locality-aware
re-ride penalty, shaping-anchor search, strongly-connected graphs). The envelopes moved
by a few percent and Viroqua gained one feasible grid cell; every conclusion held.

Raw data: [`results.json`](results.json) — full 36-cell grid, envelopes, width sweep,
and quality rows.
