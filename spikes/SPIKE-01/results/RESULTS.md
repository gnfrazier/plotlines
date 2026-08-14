# SPIKE-01 — Via-node loop routing

**Covers:** FR8a (Story A9) · **Priority:** Scope-shaping · **Run:** 2026-08-14, Linux x86_64, Python 3.12

> **Spike question.** Generate loops through 1, 2, and 3 forced via-nodes on a real
> graph; measure solve time and route quality vs. an unconstrained themed loop.
>
> **Decides.** Whether A9 is promotable to MVP. *"If via-node and start/destination
> turn out to be the same constraint primitive, A9 is nearly free and should land in
> MVP; if not, it stays P1."*

---

## Verdict

**Promote A9 to MVP, for one or two via-nodes.** The condition A9's own priority note
sets is met literally: via-node, start, destination, loop, and out-and-back are all the
same call with a different anchor list. There is no via-node code path.

The cost is not merely acceptable, it is **negative** — a 1-via loop solves in **48 ms
against the unconstrained loop's 295 ms**, because a via-node *replaces* a synthesised
shaping anchor the engine would otherwise have to place and tune. Constraining the
route makes the search smaller, not larger.

**Three or more via-nodes is a different feature and should stay P1.** At three vias
the target distance stops being honourable — error jumps from under ±14% to **+30.7%
(Boulder) and +81.9% (Viroqua)** — because the vias themselves determine the loop's
length and leave the distance search nothing to move. That is a real limit, and it is
exactly the case A9 hands to A6.

**Retracing is solved by *where* the re-ride penalty applies, not how big it is** — see
§3. A single flat penalty cannot distinguish "don't ride the corridor back" from "you
may ride the café's dead-end lane back"; splitting it by locality drops corridor
doubling from 41.7% to 6.0% while *improving* distance conformance.

---

## 1. Are via-node and start/destination the same primitive?

Yes. Every shape below was produced by one function, `solve_circuit(graph, anchors,
profile, close=)`, with no shape-specific branch anywhere:

| Shape | Anchors | `close` | Solver | Legs | Distance | Returns to start |
|---|---|---|---|---|---|---|
| point-to-point | `[start, dest]` | `False` | `solve_circuit` | 1 | 5,087 m | no |
| out-and-back | `[start, far]` | `True` | `solve_circuit` | 2 | 10,726 m | yes |
| loop | `[start, a, b]` | `True` | `solve_circuit` | 3 | 18,661 m | yes |
| **loop via 1 node** | `[start, via]` | `True` | `solve_circuit` | 2 | 8,541 m | yes |
| **loop via 2 nodes** | `[start, via, via]` | `True` | `solve_circuit` | 3 | 15,481 m | yes |

Note rows 2 and 4 — out-and-back and a 1-via loop are *the same anchor list*. They
differ only in whether the second anchor was chosen by the engine or by the Author.
FR8a is not a feature built on top of routing; it is the thing routing already does.

## 2. Cost and quality vs. an unconstrained themed loop

20 km target, `reuse_penalty=4.0`, two themes, three regions. `cost/base` is mean edge
cost per metre relative to the same theme's 0-via loop — a theme-adherence check, where
1.00 means the constrained loop honours the weights exactly as well as the free one.

| Region | Vias | Distance | Dist. error | Overlap far | Overlap near | Solve | cost/base |
|---|---:|---:|---:|---:|---:|---:|---:|
| boulder | 0 | 20,349 m | +1.8% | 0.2% | 1.1% | 295 ms | — |
| boulder | 1 | 18,107 m | −9.5% | 0.3% | 2.8% | **48 ms** | 0.976 |
| boulder | 2 | 18,582 m | −7.1% | 0.3% | 4.0% | **48 ms** | 0.978 |
| boulder | 3 | 26,132 m | **+30.7%** | 0.2% | 3.4% | 871 ms | 1.003 |
| davis | 0 | 20,624 m | +3.1% | 5.3% | 0.2% | 232 ms | — |
| davis | 1 | 17,309 m | −13.5% | 1.7% | 0.3% | 130 ms | 0.991 |
| davis | 2 | 21,417 m | +7.1% | 0.0% | 9.2% | 227 ms | 0.997 |
| davis | 3 | 24,312 m | **+21.6%** | 0.0% | 8.4% | 498 ms | 0.995 |
| viroqua | 0 | 22,681 m | +13.4% | 2.3% | 0.7% | 37 ms | — |
| viroqua | 1 | 19,215 m | −3.9% | 6.0% | 7.3% | **6 ms** | 0.993 |
| viroqua | 2 | 20,874 m | +4.4% | 3.7% | 12.6% | **5 ms** | 0.992 |
| viroqua | 3 | 36,376 m | **+81.9%** | 2.1% | 5.4% | 125 ms | 1.014 |

*(`quiet_scenic` rows and the full 24-row matrix are in `results.json`. Distances and
overlaps are deterministic and reproduce exactly; solve times vary ~±10% run to run.)*

**Weights are still honoured.** `cost/base` stays within **0.976–1.014** on every
constrained run — mean edge cost per metre relative to the same theme's unconstrained
loop. Forcing a route through a node does not quietly abandon the theme.

**Solve time falls, then cliffs.** 1–2 vias: 5–227 ms. 3 vias: 125–871 ms, because the
distance search exhausts its budget without ever converging.

**Every via-node was hit and every loop closed** — 24/24 runs, asserted in the harness.

## 3. Retracing: the penalty's *location* matters more than its size

A naive chained shortest path rides start → via → start over the same road twice. The
fix is to re-price road already ridden — but a single flat multiplier has to answer two
different questions with one number:

- *Don't ride the corridor back* — out between anchors there is nearly always another
  way round, and taking the same road is the out-and-back failure.
- *You may ride the café's lane back* — a via-node on a dead-end spur can **only** be
  reached by riding that spur both ways. This is a lollipop, and it is a legitimate
  loop.

So the penalty is now split by locality: edges wholly inside a ball around an
**Author-designated** point (the start, or a via) are charged a near-neutral ×1.25;
everything else is charged the full penalty. Ball radius is a fraction of the target
distance. Shaping anchors get no relief — they are arbitrary artefacts of hitting a
distance, and exempting road near them would just re-open the failure.

Overlap is now reported split the same way: **far** (corridor — the failure) and
**near** (spur — the lollipop stick). Sweeping both knobs across 3 regions × 0/1/2 vias:

| Penalty | Relief radius | Far overlap max | Far overlap mean | Total max | mean \|dist err\| |
|---:|---:|---:|---:|---:|---:|
| ×1 (none) | 0% | **41.7%** | 24.9% | 41.7% | 0.077 |
| ×4 | 0% | 15.2% | 7.4% | 15.2% | 0.080 |
| ×4 | 5% | 11.3% | 3.7% | 16.3% | 0.079 |
| **×8** | 0% | 10.9% | 4.9% | 10.9% | 0.093 |
| **×8** | **5%** | **6.0%** | **2.2%** | 16.3% | **0.071** |
| ×12 | 5% | 5.7% | 1.9% | 12.2% | 0.101 |
| ×20 | 3% | 5.5% | 1.5% | 8.5% | 0.111 |
| ×20 | 8% | 7.8% | 1.1% | 16.3% | 0.100 |

*(Full 24-config sweep in `results.json`.)*

Three things fall out:

**Relief reduces corridor overlap at every penalty level** — it is not a substitute for
the penalty, it is an independent axis. At ×4 it takes far-overlap from 15.2% to 11.3%;
at ×20, from 8.5% to 5.5%.

**Raising the penalty alone stalls and costs distance.** Going ×8 → ×20 with no relief
buys nothing on overlap (10.9% → 8.5%) while distance error degrades badly
(0.093 → 0.127): the solver starts distorting the loop to avoid road it should simply
reuse.

**×8 with 5% relief is the chosen default**, and it is strictly better than the old ×4
flat penalty on *both* axes — far-overlap **15.2% → 6.0%**, mean distance error
**0.080 → 0.071**. It also has the lowest distance error of all 24 configurations.

**Relief radius has a ceiling.** At 8–10% the balls grow until they cover most of a
small loop, near-overlap reaches 38%, and the zone stops licensing a spur and starts
concealing the out-and-back. 5% of the target (1 km on a 20 km loop) is the sweet spot;
this is a knob that fails quietly when set too high, so it should not be user-facing.

### What relief actually buys — 2 via-nodes, off vs on

| Region | Relief | Distance | Dist. error | Far | Near | Total |
|---|---:|---:|---:|---:|---:|---:|
| boulder | off | 18,661 m | −6.7% | 1.8% | 0.0% | 1.8% |
| boulder | **on** | 18,582 m | −7.1% | **0.3%** | 4.0% | 4.3% |
| davis | off | 21,209 m | +6.0% | 8.5% | 0.0% | 8.5% |
| davis | **on** | 21,417 m | +7.1% | **0.0%** | 9.2% | 9.2% |
| viroqua | off | 25,168 m | **+25.8%** | 7.7% | 0.0% | 7.7% |
| viroqua | **on** | 20,874 m | **+4.4%** | 3.7% | 12.6% | 16.3% |

Davis is the clean demonstration: **total overlap barely moves (8.5% → 9.2%) but all of
it relocates** from the corridor to the anchor locality. The engine rides the same
amount of road twice either way — the difference is that it is now the right road.

Viroqua is the stronger result. Without relief the solver contorted the loop to avoid
retracing near the vias and overshot the target by **25.8%**; with relief it accepts a
12.6% spur and lands at **+4.4%**. On a sparse rural network, refusing to allow a spur
does not produce a better loop, it produces a worse one that is also the wrong length.

## 4. The infeasible via — does A9's hand-off to A6 work?

A9: *"if a via-node makes the loop infeasible within the distance envelope, A6's
conflict-explanation path governs."* Forced with a via-node 8 km out on a 10 km loop
(distance band 8–11 km):

```
kind:            combination          via_implicated: true
explanation:     The via-node conflict with distance between 8,000 m and 11,000 m:
                 the same request routes without it. Drop or move the via-node,
                 or widen the band.
relaxation:      drop_via_nodes (1)   verified_routes: true
```

This required a fix during the spike. The first implementation reported
`kind: unattainable` and explained *"this is a limit of the terrain"* — which is false
and actively harmful, sending the Author to loosen a setting that was never the
problem. A via-node is a constraint, so when the same request succeeds with the vias
removed, the vias are named as the conflict. **A6 conformance is not just detecting
infeasibility; it is blaming the right thing.**

---

## 5. What this changes

1. **Promote A9 (FR8a) to MVP at 1–2 via-nodes.** Its priority note's condition is
   satisfied, and the measured cost is lower than the unconstrained case.
2. **Cap via-nodes at 2 for MVP**, or accept that target distance becomes advisory
   beyond that. 3+ vias belongs in P1 with a distance-relaxation UI.
3. **Loop generation must always carry a distance band.** `generate_loop` returns its
   best effort — at 3 vias, a 26.8 km loop for a 20 km ask. Returning that without
   comment is precisely the "silent compromise" FR9 forbids. Wrapping the call in a
   `Band("distance_m", ...)` and letting `diagnose` fire is what makes FR8 honest.
4. **Report overlap in the API.** Some networks cannot give a clean loop. Measured and
   surfaced beats silently retraced.
5. **Re-ride defaults: penalty ×8.0, relief radius 5% of target, relief ×1.25.**
   Chosen by sweep; strictly better than a flat ×4 on both overlap and distance.
6. **Split overlap reporting into far/near** in the API. A single overlap number
   cannot distinguish a lollipop from an out-and-back, and the two mean opposite
   things to an Author.
7. **Search the shaping-anchor count, not just the ring radius.** A circuit needs
   three anchors to enclose area at all; with too few, no radius reaches the target.
   Davis sat at −22.6% with one shaping anchor and +7.1% with two, and the regions
   disagree about which is right — so the engine tries both and keeps the better,
   exiting early when the first lands inside the envelope.
8. **Build routing graphs strongly connected.** osmnx's default keeps the largest
   *weakly* connected component, which is not a routability guarantee: a synthesised
   anchor landed on a node nothing could route out of and killed the whole request
   with `NetworkXNoPath`. Taking the largest strongly connected component dropped only
   27/31/2 nodes across the three regions and removed the failure class. Shaping
   anchors are additionally droppable if unreachable; via-nodes never are.

## 6. What this does not prove

- **One target distance (20 km) and one via-node placement rule.** Vias sit at fixed
  bearings 3.5 km out; real vias are wherever the café is. Very near or very far vias
  are unmeasured.
- **No POI-derived via-nodes.** FR8a names "rest stop, landmark, café" — those come
  from `content/`, which does not exist yet. Vias here are coordinates.
- **Three regions, all US.** Non-grid European road networks may behave differently,
  particularly for the overlap findings.
- **The relief radius was tuned on one target distance.** It is expressed as a
  fraction of target, but whether 5% holds at 5 km and 150 km is untested — and the
  38%-near-overlap failure at 8–10% shows the knob has a real cliff.
- **No via-node was actually on a dead-end spur.** Via-points sit at fixed bearings on
  the road network, so the lollipop case is inferred from overlap attribution rather
  than from a genuine cul-de-sac café. That is the obvious next test.
- **`nx.shortest_path` with a Python weight callable** is the solver. It is fast enough
  here (4–400 ms on 2k–9.5k-node graphs) but was not tested at metro scale, and A9's
  cost profile at 100k+ nodes is unknown.
- **Route quality is measured as theme-cost per metre and overlap.** Whether the
  resulting loops are *pleasant* is not something this spike can answer.

## Reproducing

```bash
.venv/bin/python spikes/shared/regions.py          # build fixtures (network needed)
.venv/bin/python spikes/run_routing_spikes.py 01   # -> results/results.json
```

Raw data: [`results.json`](results.json). Shared fixtures and harness:
[`spikes/shared/`](../../shared/). The runner exits non-zero if any via-node is
skipped or any loop fails to close, so it works as a CI gate.
