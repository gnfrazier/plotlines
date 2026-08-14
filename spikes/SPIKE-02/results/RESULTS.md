# SPIKE-02 — Conflict detection & relaxation

**Covers:** FR9 (Story A6) · **Priority:** Implementation-informing · **Run:** 2026-08-14, Linux x86_64, Python 3.12

> **Spike question.** Construct several deliberately-infeasible weight/constraint
> combinations; determine whether the engine can identify the binding constraints and
> compute a minimal relaxation.
>
> **Done when.** The engine names a real conflict and a valid relaxation for the test
> cases, or the limitation is documented so A6's AC can be adjusted.

---

## Verdict

**Yes — A6's acceptance criteria are achievable as written, and no adjustment to them
is needed.** Across 8 scenarios:

| | Result |
|---|---|
| Classified correctly (`unattainable` / `combination` / feasible) | **8 / 8** |
| Named exactly the right constraints | **8 / 8** |
| **False conflicts on satisfiable requests** | **0 / 3** |
| Conflicts whose offered relaxation was **applied and verified to route** | **5 / 5** |
| Median cost | 44 solves |
| Worst case | 15.0 s |

The last row is the one with a design consequence: **diagnosis costs seconds, not
milliseconds**, and that shapes the UI more than any other finding here.

---

## 1. The distinction that makes A6 useful

A6 says "name the conflicting constraints." The spike found that answer splits in two,
and that collapsing them produces confidently wrong advice:

**Unattainable alone** — the band is outside what this graph can produce at this
distance under *any* weights. Nothing else is at fault; loosening another constraint
cannot help.

> `climbing at least 300 m` in Davis, CA — *"This is a limit of the terrain, not of the
> other settings: nothing reachable from here at this distance goes beyond 29 m (range
> seen 17 m–29 m)."*

**Conflicting in combination** — each band is individually reachable, but not together.

> `climbing at least 280 m` + `traffic exposure at most 14%` in Boulder — *"Each of
> these is reachable on its own, but no route was found meeting them together. Loosen
> one."* Envelope: climbing 154–354 m, traffic 17–44%. Both asks are inside the
> envelope; the problem is that the climbing is up the busy road.

Reporting the second as the first would tell an Author their mountain town is flat.

## 2. Scenario results

| Scenario | Region | Bands | Expected | Got | Named right? |
|---|---|---|---|---|---|
| flat_town_wants_mountains | davis | climb ≥ 300 m | unattainable | ✅ unattainable | ✅ |
| nowhere_climbs_this_much | boulder | climb ≥ 1500 m; traffic ≤ 40% | unattainable | ✅ unattainable | ✅ climb only |
| climb_without_traffic | boulder | climb ≥ 280 m; traffic ≤ 14% | combination | ✅ combination | ✅ both |
| gravel_minimum | viroqua | unpaved ≥ 30% | unattainable | ✅ unattainable | ✅ |
| three_way | boulder | climb ≥ 260 m; traffic ≤ 15%; scenic ≥ 45% | combination | ✅ combination | ✅ **2 of 3** |
| scenic_and_silent | boulder | scenic ≥ 55%; traffic ≤ 12% | *(control)* | ✅ feasible | ✅ |
| control_easy | boulder | climb ≥ 100 m; traffic ≤ 45% | feasible | ✅ feasible | ✅ |
| control_snug | viroqua | climb ≥ 200 m; traffic ≤ 45% | feasible | ✅ feasible | ✅ |

Two rows deserve comment.

**`nowhere_climbs_this_much` — the slack band was not blamed.** An impossible climbing
ask sat next to a comfortable traffic band. The engine named climbing alone. Naming
both would be the common failure: technically "these constraints are unsatisfiable
together" is true, and useless.

**`three_way` — the deletion filter dropped the non-binding band.** Three bands went
in; the conflict came back as *climbing + traffic*, with scenic correctly excluded.
Naming all three would send the Author to loosen something that binds nothing. The
filter costs O(n) searches rather than the 2ⁿ subset sweep.

**`scenic_and_silent` was my wrong prediction, not the engine's wrong answer.** It was
built to be a conflict — two soft preferences pulling apart — and the engine routed it
in 26 solves. On this graph scenic and quiet *correlate*: the scenic ways are bike
paths, and bike paths carry no cars. It is kept in the suite as a control, because a
conflict-detector that agrees with a plausible-but-wrong human guess is exactly the
failure mode worth guarding against.

## 3. Relaxations were applied, not just offered

A6 requires relaxations "applyable in one action." An offer that does not work is the
silent compromise A6 forbids, so **every proposed relaxation was applied to the band
set and re-solved.** 5 of 5 produced a route.

| Scenario | Offered relaxation | Trade-off stated | Routes? |
|---|---|---|---|
| flat_town_wants_mountains | climbing ≥ 300 m → **≥ 21 m** | no other band affected | ✅ |
| nowhere_climbs_this_much | climbing ≥ 1500 m → **≥ 338 m** | traffic 26% (still inside its band) | ✅ |
| climb_without_traffic | traffic ≤ 14% → **≤ 19%** | climbing 302 m (still inside its band) | ✅ |
| gravel_minimum | unpaved ≥ 30% → **≥ 7%** | no other band affected | ✅ |
| three_way | traffic ≤ 15% → **≤ 19%** | climbing 302 m (still inside its band) | ✅ |

Each relaxation is near-minimal — the smallest widening that admits a route already
seen — and names what it costs on the other axes.

**An offer pinned to the observed limit is not a safe offer.** The first implementation
widened to *exactly* the best value seen, and this check caught it failing: Davis's
climbing band was relaxed to "≥ 26 m", the observed maximum, and re-solving under the
relaxed band took a slightly different descent and landed a hair under. The offer was
correct to within a metre and still did not route. Relaxations now carry a 5% margin,
which is why the numbers above sit just outside the observed extremes (≥ 21 m, not
≥ 26 m). **Verifying the offer is what surfaced this** — the bug is invisible if you
only produce relaxations and never apply them.

## 4. Cost, and what it means for the UI

| | Solves | Wall |
|---|---:|---:|
| Feasible request (control) | 1 | **27–218 ms** |
| Single unattainable band | 42–46 | 1.3–8.7 s |
| Two-band combination | 44 | 8.3 s |
| Three-band combination | 78 | **15.0 s** |

**A satisfiable request is nearly free — the first archetype often wins outright.**
Diagnosis is what costs, and it costs seconds because each answer requires re-searching
the graph several times over.

These figures roughly doubled after SPIKE-01's loop changes: searching the
shaping-anchor count as well as the ring radius makes each individual solve more
expensive. That is a deliberate trade — better loops, slower diagnosis — and it
strengthens rather than weakens the conclusion below.

That is a UI constraint, not a bug: **A6's explanation cannot be produced synchronously
inside a route request.** Return the best-effort route with its violations immediately
(that data is already in hand), then produce the named conflict and relaxations as a
follow-up. Note also that diagnosis cost scales with the *number of bands*, so a UI
exposing five weights with min/max on each should expect the three-band figure to be
the floor, not the ceiling.

## 5. The honesty boundary

**The search underneath is incomplete, and the reporting says so.** `search_bands` is
archetype probing plus coordinate descent over a continuous weight space — failing to
find a satisfying route proves only that none was found within budget.

This is why the two-way split above matters beyond message wording. The *unattainable*
verdict rests on the observed attainable envelope, which is a measurement. The
*combination* verdict rests on search failure, which is not a proof — so it is phrased
"no route was found meeting them together", never "impossible". An engine that claimed
proof here would eventually tell an Author something false.

---

## 6. What this changes

1. **A6's AC needs no adjustment** — it is deliverable as written.
2. **Split the verdict** into terrain-limit vs. constraint-conflict in the API and the
   UI. They warrant different words and different offers.
3. **Diagnosis is asynchronous.** Return best-effort + violations synchronously;
   stream the conflict explanation after.
4. **Verify relaxations before offering them, and give them margin.** Verification is
   cheap relative to producing them, and it is the only thing that catches an offer
   pinned to the observed limit — correct to a metre, and still not routable.
5. **A via-node is a constraint** and must be named as one — see
   [SPIKE-01 §4](../../SPIKE-01/results/RESULTS.md), where the first implementation
   blamed the terrain for a conflict the via-node caused.
6. **Never claim proof of infeasibility.** Word it as "not found".

## 7. What this does not prove

- **One target distance (20 km), one start point per region, three regions, all US.**
- **Bands over five metrics only** (distance, climbing, traffic, unpaved, scenic).
  FR5's POI-density weight has no real implementation yet — `scenic_frac` is a proxy
  built from way names and highway class, not from `content/` POIs.
- **At most three simultaneous bands.** The deletion filter is O(n) searches, so five
  or six bands will be slower than anything measured here.
- **No Author in the loop.** Whether these explanations are *understood* is a design
  question this spike cannot answer — it only shows the engine can produce them.
- **`gravel_minimum` is not a terrain result.** It reports `unattainable` because the
  surface weight cannot *seek* unpaved road, only tolerate it — see
  [SPIKE-03 §5](../../SPIKE-03/results/RESULTS.md). The verdict is correct; the cause
  is the weight's shape, not Viroqua's gravel.

## Reproducing

```bash
.venv/bin/python spikes/shared/regions.py          # build fixtures (network needed)
.venv/bin/python spikes/run_routing_spikes.py 02   # -> results/results.json
```

Raw data: [`results.json`](results.json). The runner exits non-zero on any false
positive or misclassification, so it works as a CI gate.
