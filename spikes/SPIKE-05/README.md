# SPIKE-05 — Mode/terrain travel-speed calibration

Time-boxed spike answering `docs/Plotlines_Research_Spikes.md` SPIKE-05: **can believable
moving-time/ETA figures be produced across pavement/gravel/singletrack and
flatwater/moving-water?** Run as a proof of concept for the ETA module against 12 real
activity files.

**Results and the FR16/FR31 call: [`results/RESULTS.md`](results/RESULTS.md).**

**Headline:** moving time predicts to 7–8% with personal data; elapsed time only to
13–24%, because stops are a decision rather than a terrain property. FR16's *system
default* is fine for hiking (Tobler, no data needed) and **31% wrong for cycling**, which
is what makes the Character-upload feature load-bearing rather than a nicety.

## The privacy rule this spike is built around

**The activity files are real personal GPS traces and are never committed.**
`spikes/fit_files/` is git-ignored, as are `*.fit` / `*.gpx` / `*.tcx` anywhere in the
repo. What *is* committed is the derived metrics — durations, distances, ascent, speed
distributions — which is exactly the split the product needs (derive locally, share
numbers, not tracks).

Three mechanisms, in increasing order of how much they'd catch a mistake:

| | |
|---|---|
| **Relabelling** | Activities become `cycling-01` … `paddling-01` by mode and sequence. Two of the supplied files carry place names in their filenames; the label is the only channel those could have reached the output through. |
| **Structural avoidance** | The FIT reader never requests a position field — distance and altitude are recorded fields, so it doesn't need one. The GPX reader *does* read positions (GPX has no distance field), sums segment lengths, and discards them inside the function. That asymmetry is stated, not glossed. |
| **A check that fails the run** | `run.py::assert_clean` re-reads everything it wrote and raises if a source filename or a coordinate-shaped decimal appears. It runs on every output file, every run. |

The consequence, stated plainly in the results: **this spike is not reproducible by a third
party** the way SPIKE-00 and SPIKE-04 are. That is the deliberate trade.

## Layout

| Path | What it is |
|---|---|
| `ingest.py` | **Layer A** — files in, derived metrics out. The only module that opens an activity file. |
| `classify.py` | Mode (device says it) and terrain (device has no idea) — the "not well labelled" problem. |
| `eta.py` | **The module under test** — three models mapped onto FR16's three pace options, plus leave-one-out evaluation. |
| `run.py` | Driver; relabelling, the leak check, and the results files. |
| `results/` | `RESULTS.md`, plus `activities.json` and `eta_evaluation.json`. |

`ingest.py` and its schema are **unconditional** — correct regardless of how the models
scored — and are the part intended to move to `core/plotlines_core/activities/` when the
feature is built. `eta.py` is the part that was on trial. That split follows SPIKE-00,
where the build script became real packaging infrastructure and the harness stayed a
harness.

## Reproducing

```bash
VIRTUAL_ENV=.venv uv pip install fitdecode gpxpy
python spikes/SPIKE-05/run.py --files spikes/fit_files
```

Needs no network. Runs in a few seconds. You will need your own activity files — see the
privacy rule above for why mine aren't here.

## Two things to know before changing the evaluation

- **Leave-one-out is not optional.** A model fitted on twelve activities and scored on the
  same twelve reports a flattering number that means nothing. Every fitted figure here
  refits from scratch with the target activity removed, using same-mode activities only.
- **A model with nothing to fit on must say so.** `eta.Unpredictable` is raised rather than
  falling back to a constant. An earlier version returned a hardcoded 10 km/h, and the
  resulting "37.1% error" was measuring the constant, not the model. With one paddling
  file in the corpus this is not a hypothetical case.

## Scope

This is a **calibration** spike. It does not implement FR16's UI, the Character upload
flow, or FR78's sharing negotiation. It answers whether the numbers underneath them are
trustworthy — and reports where they are not, which is elapsed time, off-road cycling, and
paddling.
