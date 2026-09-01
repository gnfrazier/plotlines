# SPIKE-17 — Community edge-data extensions and API normalisation

Does an **edge** data-input plugin work against ARCH §14.2's interfaces with
no core code change, what does the fetch-and-annotate step cost against a real
graph build, what TTL does the data's own volatility justify, and does
normalisation need a server tier (a **P3 design event** if it does)? Per issue
[#176](https://github.com/gnfrazier/plotlines/issues/176).

**Verdict and full write-up: [`results/RESULTS.md`](results/RESULTS.md).**

```bash
# everything — three real feeds, two real graph builds, a live volatility poll
core/.venv/bin/python spikes/SPIKE-17/run_spike.py
#   -> results/run_spike.json

core/.venv/bin/python spikes/SPIKE-17/run_spike.py --polls 0   # skip the poll
core/.venv/bin/python spikes/SPIKE-17/run_spike.py --force-fetch  # re-capture raw/

cd spikes/SPIKE-17 && ../../core/.venv/bin/python -m pytest tests -q
```

Use `core/.venv`, not the repo-root `.venv` — this spike imports
`plotlines_core` and needs `osmnx`/`shapely`/`requests` (same convention as
SPIKE-A/B/D/E/H).

## Files

| File | What |
|---|---|
| `providers.py` | `WzdxEdgeProvider` and `NwsAlertEdgeProvider` — real `EdgeDataProvider` implementations against the **shipped** `plotlines_core.providers` Protocol, zero core changes |
| `normalize.py` | the one `RoadEvent` record and one adapter per source shape. This module *is* the normalisation-proxy question: its size and its dependencies are the evidence |
| `matching.py` | event geometry → `(u, v, k)` edge keys. Map-matching with a bearing check, which is the work `annotate_edges(graph, bbox) -> graph` hides behind one signature |
| `registry.py` | registration-time licence gate over annotation providers — the gate `curation/registry.py` already has for layers and that §14.2's annotation Protocols cannot express |
| `graphs.py` | real region graphs through the product's own `graph.regions.ensure_graph` |
| `http_cache.py` | keyless GET + gzip disk cache, so a re-run never re-hits a public government endpoint (P7) |
| `run_spike.py` | every arm of issue #176 end to end → `results/run_spike.json` |
| `tests/` | 17 tests — the adapters against the committed real responses, the matcher against a hand-built graph where the answer is known |
| `raw/*.json.gz` | committed, real feed responses (2026-09-01) |
| `cache/` | region graphs, **not committed** (125 MB; `.gitignore`'s `cache/` rule) |

## What is real, and what stands in

**Every external data point is real**, fetched live on 2026-09-01 and cached
to `raw/` rather than resimulated: 4,424 Wisconsin work-zone events, 5,857 New
York ones, 5 NWS alerts and the 62 forecast-zone polygons they refer to.
**Both graphs are real builds** through the shipped `ensure_graph` — 42,450
and 138,979 edges — not fixtures, because the spike question is explicitly
"measure the fetch-and-annotate step *against a real graph build*".

**The edge source issue #176 names is not one of the three.** NC TIMS moved
and became keyed between the spike being written and being run; that is
recorded as arm 1 rather than quietly worked around, because it is the most
transferable finding in the run. See RESULTS §1.

**The volatile half of "realtime" is unmeasured.** WZDx publishes *planned*
work; an incident feed (crashes, weather closures) would churn far faster, and
the one this spike was pointed at is now behind a key. The TTL recommendation
in RESULTS §4 is scoped to planned work and says so.
