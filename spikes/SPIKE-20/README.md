# SPIKE-20 — The trip payload schema

**Question:** can one document serve as `plotlines-core`'s output type (ARCH §6.1),
drift's stored `trip.payload` blob (§10.3 / §10.1), and the Flutter domain layer's
source (§9.1) — without an adapter at two of the three boundaries?

**Answer:** yes. See [`results/RESULTS.md`](results/RESULTS.md).

The deliverable is **[`docs/schemas/trip_payload.schema.json`](../../docs/schemas/trip_payload.schema.json)**.
Everything in this directory exists to prove that file is implementable three times
over a real trip rather than a plausible one.

## Running it

```bash
PYTHONPATH=core .venv/bin/python spikes/SPIKE-20/run.py            # all three regions
PYTHONPATH=core .venv/bin/python spikes/SPIKE-20/run.py --regions boulder
```

Exits non-zero if any self-check fails, so it works as a CI gate. Needs:

* the SPIKE-01/02/03 shared graph fixtures — rebuild with
  `.venv/bin/python spikes/shared/regions.py` if `spikes/shared/fixtures/` is empty
* `jsonschema` in the venv (`uv pip install --python .venv/bin/python jsonschema`)
* the Dart SDK, and one-time setup in `dart/`:

```bash
cd spikes/SPIKE-20/dart
dart pub get
dart run build_runner build        # generates lib/database.g.dart (drift)
```

## What is here

| Path | What it is |
|---|---|
| `run.py` | The spike. Builds, validates, drives the Dart leg, diffs, probes, measures. |
| `build_fixture.py` | The fixture trip: four days, real solved routes on the shared graphs. |
| `fr_map.py` | Every MVP-scope FR that describes trip-shaped data → a schema pointer, or an honest reason there isn't one. `run.py` fails if a pointer does not resolve. |
| `dart/lib/domain.dart` | ARCH §9.1's domain classes, pure Dart. Reads are exhaustive — an unconsumed field throws. |
| `dart/lib/database.dart` | ARCH §10.3's drift schema, verbatim. |
| `dart/bin/roundtrip.dart` | JSON → domain → drift → domain → JSON, plus the simulated Author edit and four coercion probes. |
| `results/` | `RESULTS.md`, `results.json`, the three fixture payloads, and the Dart reports. |

Two pieces of this spike are **not** spike code and were written into the core on
purpose, following the SPIKE-01/02/03 precedent: `core/plotlines_core/trips/payload.py`
(the dataclasses and their serialization rules) and `core/plotlines_core/trips/compose.py`
(`compose_day` / `split_trip`, the two functions ARCH §6.1 sketches). The spike
imports them rather than reimplementing them, which is what makes the claim "this is
the core's actual return type" literally true.
