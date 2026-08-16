# SPIKE-21 — Cue derivation from a routed polyline

**Question:** how does a solved route become a cue sheet a rider can read at a glance —
turns collapsed to real decision points, surface shifts that survive thin OSM tagging,
Author content interleaved in route order, and a retraced spur that does not read as
fresh road?

**Answer:** [`results/RESULTS.md`](results/RESULTS.md). The algorithm lives in
[`core/plotlines_core/trips/cues.py`](../../core/plotlines_core/trips/cues.py) — in the
core, not the client (ARCH D31).

## Running it

```bash
PYTHONPATH=core .venv/bin/python spikes/SPIKE-21/run.py            # all three regions
PYTHONPATH=core .venv/bin/python spikes/SPIKE-21/run.py --regions boulder
```

Exits non-zero if any self-check fails. Needs the SPIKE-01/02/03 shared graph fixtures
(`.venv/bin/python spikes/shared/regions.py` rebuilds them) and `jsonschema`. The Dart
leg reuses SPIKE-20's harness; if the Dart SDK is absent the run records that and
carries on, because deriving a cue does not need it.

## What is here

| Path | What it is |
|---|---|
| `run.py` | Nine routes over three regions: derive, measure against the naive baselines, sweep the thresholds, validate against the payload schema, and push one payload through SPIKE-20's Dart harness. |
| `results/RESULTS.md` | The write-up. |
| `results/results.json` | Every number in it. |
| `results/samples/*.md` | The nine cue sheets, rendered as a rider reads them — the legibility evidence, since a density figure can look fine while the document is unreadable. |
| `results/payloads/*.json` | The schema-validated trip payloads the sheets live in. |

The algorithm itself is **not** in this directory. It is product code in
`plotlines-core`, following the same precedent as SPIKE-00/01/02/03 and SPIKE-20: the
spike measures, the core carries what it measured.
