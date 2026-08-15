# SPIKE-05 results — Mode/terrain travel-speed calibration

**Run:** 2026-08-15 · **Verdict: moving time is predictable well enough to show a
Character. Elapsed time is not, and the gap between them is the finding.** Against real
activity files, a personal-pace model predicts **moving time to 7–8% MAPE** — but the same
model predicts **elapsed time only to 13–24%**, because stops are a decision, not a
terrain property. FR16 is deliverable; FR31's "elapsed time (incl. stops)" needs a
different treatment from a speed model.

**The result that shapes the build:** FR16's three pace options are **not
interchangeable, and which one you need depends on the mode.** Hiking has a usable
published default and needs no personal data at all. Cycling's default is off by 31% and
personal data cuts that to 7.5% — a 4× improvement. So the Character-upload feature is
not a nicety for cycling; it is the difference between a trustworthy ETA and a misleading
one.

**No location data appears in this document or in `results/`.** Activities are relabelled
`cycling-01` … `paddling-01` by mode and sequence. The raw files are git-ignored, and
`run.py` re-reads what it wrote and fails the run if a source filename or a
coordinate-shaped number survives into the output. Two of the supplied files carry place
names in their filenames; that check is why they are not in here.

---

## 1. The corpus

Twelve real activities, supplied as an unsorted folder — the same shape a Character would
upload. **All twelve parsed on the first attempt**, which is itself a result: no format
surprises, no vendor dialect problems.

| | Files | Format |
|---|---:|---|
| Cycling | 7 | 5 FIT, 2 GPX |
| Hiking | 4 | 4 FIT |
| Paddling | 1 | 1 FIT |

| Activity | Terrain | Distance | Moving | Elapsed | Ascent | Moving speed |
|---|---|---:|---:|---:|---:|---:|
| cycling-01 | road | 88.19 km | 240.0 min | 296.1 min | 1,315 m | 22.05 km/h |
| cycling-02 | road | 82.79 km | 184.5 min | 195.9 min | 598 m | 26.92 km/h |
| cycling-03 | road | 99.92 km | 284.4 min | 310.6 min | 596 m | 21.08 km/h |
| **cycling-04** | **offroad** | 18.16 km | 79.5 min | 88.2 min | 241 m | **13.71 km/h** |
| cycling-05 | road | 41.63 km | 109.9 min | 145.2 min | 393 m | 22.73 km/h |
| cycling-06 | road | 38.46 km | 94.5 min | 103.7 min | 175 m | 24.43 km/h |
| cycling-07 | road | 90.72 km | 228.2 min | 274.9 min | 996 m | 23.85 km/h |
| hiking-01 | trail | 11.59 km | 184.6 min | 235.0 min | 435 m | 3.77 km/h |
| hiking-02 | trail | 10.69 km | 153.9 min | 239.2 min | 451 m | 4.17 km/h |
| hiking-03 | trail | 14.67 km | 195.4 min | 225.3 min | 325 m | 4.50 km/h |
| hiking-04 | trail | 5.07 km | 72.8 min | 77.4 min | 81 m | 4.18 km/h |
| paddling-01 | water | 9.34 km | 133.1 min | 148.3 min | 36 m | 4.21 km/h |

---

## 2. "Not well labelled" — what the devices do and don't know

The corpus was supplied as a deliberate test of messy input, and it split the problem
cleanly in two.

**Mode is a solved problem.** Every FIT file carries `sport = cycling | walking |
paddling`; both GPX files carry `type = Ride`. Building a mode classifier here would have
been solving a problem the metadata already solved, so the module takes the device's word
and only infers when the file says nothing. Worth stating because it is *load-bearing for
the feature*: a Character's upload arrives self-labelled by mode, so the app does not need
to ask.

**Terrain is not, and no device will ever supply it.** All five cycling FIT files say
`cycling / generic`. **One of them is a mountain-bike ride**, and the device has no idea —
which matters because pavement-versus-singletrack is exactly the distinction FR16 asks the
ETA model to make.

`cycling-04` separates from its six road siblings on three independent signals at once:

| Signal | cycling-04 | road rides |
|---|---:|---|
| Moving speed | **13.71 km/h** | 21.08 – 26.92 |
| Stops per km | **1.54** | 0.08 – 0.65 |
| Speed variability (CV) | **0.41** | 0.22 – 0.53 |

Each has an innocent explanation alone — slow could be loaded touring, stoppy could be
traffic lights, ragged could be a hilly road route (note cycling-01's CV of 0.53 is the
highest in the corpus, and it is a road ride). Requiring **two of three to agree** is what
makes the call worth anything, and it identified the off-road ride correctly.

**This is one positive example.** The thresholds are a hypothesis drawn from a single
labelled MTB ride, not a validated classifier, and the write-up should not be read as
claiming otherwise. What can be claimed is that the signals separate widely enough to be
worth collecting labelled data for — and §4 quantifies what getting it wrong costs.

### One data-quality trap worth building for

Three files report `total_timer_time == total_elapsed_time` exactly. That means the device
did **no pause detection at all** — so its "timer time" is elapsed time under a
moving-time name. Validating a moving-time model against that field would score the model
on a quantity it is not predicting.

(My first reading of this was backwards: it looks like auto-pause and it is the *opposite*
of auto-pause. On `cycling-01` the device reports 296.0 min of timer time while the speed
trace shows 240.0 min of actual movement — a 23% gap, and 56 minutes of stops the device
simply never noticed.)

Stops are therefore recovered from the speed trace, not taken from the device. Flagged as
`device_no_pause_detection` at ingest and excluded from stop-ratio fitting.

---

## 3. Does the ETA model work?

Three models, mapped onto FR16's three pace options. **Every number is leave-one-out
cross-validated** — the activity being predicted is never in the data the model was fitted
on, and only same-mode activities are used for fitting.

### Moving time — MAPE by mode

| Model | FR16 option | Cycling | Hiking | Paddling |
|---|---|---:|---:|---:|
| Flat average, grade ignored | *(baseline)* | 8.2% | **6.7%** | n/a |
| Literature constants | **system default** | 31.4% | 9.6% | 6.4% |
| Personal grade-binned | **custom / aggregated pace** | **7.5%** | 9.7% | n/a |

### Elapsed time — MAPE by mode

| Model | Cycling | Hiking | Paddling |
|---|---:|---:|---:|
| Flat average | 13.7% | 23.2% | n/a |
| Literature constants | 30.8% | 14.7% | 16.0% |
| Personal grade-binned | **13.1%** | 23.9% | n/a |

### What these say

**1. Moving time clears the bar; elapsed time does not.** 7–8% on moving time is inside
what you would show someone. Elapsed time is roughly **twice as bad** in the same models,
and that is not a tuning problem — a lunch stop is a decision, and no amount of terrain
data predicts it. **FR31 should present moving time as the estimate and stops as a
separate, Author-set allowance**, rather than blending them into one number whose error
the Character cannot attribute.

**2. The system default works for hiking and fails for cycling.** Tobler's hiking function
— published, zero personal data — gets **9.6%** on hiking, within a point of the fitted
personal model. The cycling constant gets **31.4%**. The asymmetry is real rather than an
artifact of my constants: walking speed is bounded by human gait and varies little between
people, while cycling speed depends on fitness, equipment and terrain and ranges over a
factor of two. **A guessed cycling constant cannot be rescued by picking a better guess.**

**3. So the Character-upload feature is load-bearing, for cycling.** Personal data takes
cycling from 31.4% to 7.5% — a **4× improvement**, and the difference between an ETA worth
showing and one that misleads. For hiking it buys nothing measurable. That is a concrete,
mode-dependent answer to whether FR16's three options are worth building: **yes, and
cycling is the reason.**

**4. Grade-awareness is not earned at this scale.** The grade-binned model beats the flat
average on cycling (7.5% vs 8.2%) and *loses* on hiking (9.7% vs 6.7%). With six and four
activities those gaps are well inside the noise. The honest statement is **no evidence that
modelling speed-by-grade beats a single average speed per mode and terrain** — not that it
cannot. Ship the simple thing; revisit with more data.

---

## 4. What getting the terrain wrong costs

`cycling-04` is the only off-road ride, so under leave-one-out there is nothing of its kind
to learn from and the model must fall back to the rider's road pace. That fallback is
exactly what would happen in production if the terrain went unclassified — and it is
**41.0% wrong**: 79.5 minutes of actual riding predicted as 46.9.

That number is the argument for §2's terrain classifier. A ride mislabelled as road is not
slightly off; it is wrong by more than the entire error budget of every other result in
this document.

*(An earlier version of this figure was 37.1%, which turned out to measure a hardcoded
10 km/h fallback constant rather than the model. The fallback now uses the rider's own
mode average, and 41.0% is the honest number.)*

---

## 5. Paddling: one file, and what that does and doesn't allow

With a single paddling activity, leave-one-out has nothing to fit on, so **both personal
models correctly report it as unpredictable** rather than inventing a figure. Only the
zero-data literature model can say anything at all, and it happens to land at 6.4% on
moving time — which is one sample against a round constant and should be read as
encouraging, not as evidence.

This is a real gap, and after SPIKE-04 it is a more important one than it looks: with
FR13 retired and B4/B5 removed, **flatwater/moving-water pace is one of the few
paddling-specific capabilities still standing in the PRD**. B7 is carrying more of that
mode than it was designed to. Three or four more paddling files would settle it.

---

## 6. Derived-metrics schema — the artifact that outlives the spike

This is the contract the Character-upload feature needs, and the reason to agree it now:
it is what crosses the device boundary, gets shared under FR78's per-field consent, and
syncs. It contains **no coordinates, no timestamps, and no filename**.

This is `cycling-04`'s **actual record**, copied from `results/activities.json` rather than
written by hand:

```jsonc
{
  "label": "cycling-04",           // assigned; never the source filename
  "source_format": "fit",
  "declared_sport": "cycling",     // what the device claimed, verbatim
  "declared_sub_sport": "generic", // ...and how little that says (see §2)
  "mode": "cycling",               // resolved: device label, or inferred
  "distance_km": 18.16,
  "moving_s": 4769.0,              // from the speed trace, not the device timer
  "elapsed_s": 5292.0,
  "device_timer_s": 5164.3,        // kept for comparison; not trusted (see §2)
  "ascent_m": 241, "descent_m": 228,
  "avg_moving_speed_kmh": 13.71,
  "speed_cv": 0.409,
  "speed_by_grade": {              // the grade profile, per bin (7 bins; one shown)
    "-1%..1%": {"samples": 450, "distance_km": 5.21,
                "mean_kmh": 12.16, "median_kmh": 8.87}
  },
  "stop_count": 28, "stopped_s": 523.0,
  "has_power": false, "has_cadence": false, "has_hr": true,
  "quality_flags": [],             // this one is clean; 3 of 12 carry a flag
  "classification": {
    "mode": "cycling", "mode_source": "device", "mode_confidence": "high",
    "terrain": "offroad", "terrain_confidence": "medium",
    "evidence": {"avg_moving_speed_kmh": 13.71, "stops_per_km": 1.54,
                 "speed_cv": 0.409, "ascent_per_km": 13.3, "has_power": false,
                 "signals": {"slow_for_a_bike": true,
                             "frequent_stops": true, "ragged_pace": true}}
  }
}
```

One detail visible in that single bin and worth carrying into the UI: on flat ground this
ride's **mean** speed is 12.16 km/h and its **median** is 8.87. A third of the gap between
"what an average says" and "what it felt like" is in that spread, which is why the schema
keeps both rather than collapsing to a mean.

Three deliberate properties:

- **`quality_flags` and `evidence` travel with the number.** An Author looking at an
  aggregated pace can see it rests on a device that never detected a stop, or on a terrain
  call made from two of three signals. Aggregating away the caveats is how a
  confident-looking wrong ETA gets built.
- **`speed_by_grade` is retained even though §3 found no evidence it helps.** It is small,
  it is the input any future model would need, and re-deriving it means re-uploading files
  a privacy-preserving design has already discarded.
- **No timestamps.** Recency stamping is a *feature* requirement (an FR66-style age label
  on a pace derived from three-year-old rides), but the spike does not need dates and
  including them would put identifying data in a committed file for no analytical gain.

---

## 7. Confirmed for the feature: derivation needs almost no location data

The strongest architectural result is one the spike question did not ask for.

**The FIT path never reads a position field at all.** Cumulative distance and altitude are
recorded fields, so every number in this document — distances, durations, ascent, speed
distributions — was derived from FIT files without the parser ever touching a coordinate.

**The GPX path does read positions**, purely to sum segment lengths, discards them inside
the function, and lets nothing positional reach the output. GPX has no recorded-distance
field. Integrating the `speed` extension instead was tried and rejected: it came in
**2.7% and 8.0% short** on the two files here, and an 8% distance error would swamp the
entire 7–8% error budget the model achieves.

For the product this means a Character's device can derive and share a pace profile
**without a location history ever leaving it** — and for FIT, without one ever being read.
That is what makes FR78's per-field consent meaningful: the shared "field" is
`avg_moving_speed_kmh: 13.71`, not a map of someone's week.

---

## 8. What this does *not* prove

- **One person.** Every activity is from a single athlete, so "custom Author pace" and
  "aggregated participant pace" are the same model fitted on the same data here. The
  spike cannot distinguish them, and FR16 treats them as different options. **Aggregation
  across people is untested.**
- **Twelve activities, and thin in the corners.** Six road rides, four hikes, one off-road
  ride, one paddle. The cycling and hiking numbers are worth something; the off-road and
  paddling figures are single points.
- **No surface data.** FR16 names "pavement vs. gravel vs. singletrack", and this spike
  distinguishes road from off-road by *behaviour*, never by surface. True surface
  attribution needs map-matching the trace to OSM — which needs the coordinates §7 is
  built to avoid. **That tension is unresolved and is the most interesting open question
  here.**
- **Predicting a ride is not predicting a route.** Every prediction used the held-out
  activity's own grade profile, which a planned route does supply. It does not test
  whether a *planned* route's profile matches what gets ridden.
- **Fitness and conditions are ignored.** No weather, no load, no fatigue, no
  time-of-year. Some of the residual error is certainly these.
- **Self-selection.** These are the files an athlete kept. A "capability" aggregated from
  them will skew toward good days — the caution in §6 about carrying caveats forward is
  the mitigation, not a fix.

---

## Outstanding

1. **More paddling and off-road files** — three or four each would move both from
   single-point observations to measurements. The off-road number in particular is what
   justifies the terrain classifier.
2. **Decide FR31's elapsed-time presentation.** §3 says a single blended ETA hides which
   half is wrong. Recommend moving time as the estimate, stops as an explicit allowance.
3. **Resolve the surface-versus-privacy tension in §8.** Either accept behavioural terrain
   inference, or design a map-matching step that runs on-device and emits only surface
   fractions.
4. **Test aggregation across people** once more than one participant's files exist — the
   FR16 option this corpus structurally cannot evaluate.
5. **Promote the ingest layer.** `ingest.py` and the schema in §6 are unconditional; the
   models in `eta.py` are what was under test. Move the former to
   `core/plotlines_core/activities/` when the feature is built, and run the new
   `fitdecode`/`gpxpy` dependencies through `spikes/SPIKE-00/harness/lifecycle.py` against
   a fresh frozen build first, per `packaging/README.md`.
