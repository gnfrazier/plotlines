# SPIKE-E — Driving-mode routing and the vehicle-access advisory

**Issue:** [#171](https://github.com/gnfrazier/plotlines/issues/171) ·
**Covers:** PRD **FR29** (amended), **FR29a**, FR10 · stories **C13**, **C13a** `[P1]` ·
ARCH §7.4, **Q14** ·
**Run before:** C13 ·
**Result:** [`results/RESULTS.md`](results/RESULTS.md)

```bash
# network — one Overpass pull per approach, committed to raw/ (idempotent)
core/.venv/bin/python spikes/SPIKE-E/probe.py

# offline — every published figure, from raw/ -> results/*.json
core/.venv/bin/python spikes/SPIKE-E/analyze.py

# offline — the CI-safe gate: 21 verdict clauses re-derived and asserted
core/.venv/bin/python spikes/SPIKE-E/run.py --dry-run

# tests
core/.venv/bin/python -m pytest spikes/SPIKE-E/tests -q
```

`analyze.py` and `run.py` touch no network and no clock. Everything they need is
committed under `raw/` (1.8 MB), so every number here reproduces without querying the
Overpass commons (ARCH §14 P7) and without moving under the next reader — SPIKE-C's
rule, for SPIKE-D's reason.

## Why this spike exists

ARCH §7.4 calls driving *"the cheapest new mode in the list (the OSM road graph is
already built; the weights are near-trivial)"* — and then says in the same paragraph
that it is **unmeasured**. Cheap-looking and unverified is the exact shape SPIKE-14
punished: its summary table named `maplibre_gl` as the vector-mapping choice and
running it found that package has no Flutter desktop support at all.

The second half is a data question. FR29a's advisory is only as honest as the tagging
behind it, and the requirement says so itself — *"tag coverage is stated plainly rather
than implying completeness"*.

## The approaches

Four, defined in `regions.py` and fixed before anything was measured. Two sit **inside
the shared fixture bboxes** (`spikes/shared/regions.py`, imported rather than copied),
so this spike composes with SPIKE-01/02/03 the way SPIKE-D composed with SPIKE-B. Two
are genuinely remote, because a last mile inside a city is not the case FR29 is worried
about.

| key | approach | why it is here | destination (real OSM element) |
|---|---|---|---|
| `boulder` | downtown Boulder → Gregory Canyon Trailhead | shared fixture; the trailhead road is `highway=service` | `way/417243786` |
| `viroqua` | Viroqua → Sidie Hollow boat landing | shared fixture; Driftless gravel, thinly tagged | `node/2618977896` (`leisure=slipway`) |
| `bigsandy` | Boulder WY → Big Sandy Trailhead | the canonical case: ~50 km of dirt to the Wind River crest | `node/1042137527` (`highway=trailhead`) |
| `middlefork` | Stanley ID → Boundary Creek put-in | FR29's own example — the last mile to the **put-in** | `way/13983172` (NFSR 549) |

Every destination was resolved against live Overpass before the file was written and is
cited by id, so a seed coordinate a few hundred metres out cannot be read back as a
routing finding.

## Files

| file | what it is |
|---|---|
| `regions.py` | **Pre-registered**: the four approaches, FR29a's signal list, the coverage bands, the harm ceiling. Change with a written reason. |
| `filters.py` | osmnx 2.1.1's `drive` / `drive_service` filter strings **verbatim**, plus the two wider variants, and the clause parser that applies them offline. |
| `probe.py` | The only file that touches the network. One pull per approach + one live `network_type="drive"` control. |
| `graphs.py` | `raw/*.json.gz` → a `plotlines_core`-shaped graph; the product's own strong-component truncation; the driving-distance corridor. |
| `route.py` | The routing half, through the shipped solver, legality layer and cue derivation. Nothing here re-implements a scoring decision. |
| `coverage.py` | The four denominators (`network` / `corridor` / `route` / `last_mile`) and per-signal coverage in ways **and** kilometres. |
| `advisory.py` | The FR29a prototype: the capability ladder, the value→capability rules from the OSM wiki, gap-tolerant sections, and a three-state honesty payload with no `passable` field. |
| `analyze.py` | Everything offline → `results/{routing,coverage,advisory}.json`. |
| `run.py` | `--dry-run` gate: 21 clauses from `RESULTS.md`, turned back into assertions. |
| `tests/` | pytest over the filters, the rebuild, the denominators and the advisory's invariants. |

## No product code changed

Same discipline as SPIKE-A / SPIKE-C / SPIKE-D / SPIKE-G / SPIKE-H: nothing here edits
`plotlines-core` or `plotlines-service`. This spike found **one shipped defect**
(`trips/cues.py`'s `route_polyline` edge spans do not tile the route) and **one shipped
gap** (`graph/regions.py` never downloads `4wd_only`, `motor_vehicle`, `ford`, and
cannot carry `barrier` at all); both are written up in `results/RESULTS.md` for the
story that owns them rather than patched here.
