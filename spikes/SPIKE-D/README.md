# SPIKE-D — Layer extraction and POI indexing timing

Measures how long a real trip bbox takes to become *authorable* against how
long elevation enrichment takes, proves the two run concurrently, exercises the
per-capability / per-layer `/health` contract including a failing layer, and
settles the Overpass access pattern with numbers — per issue #159.
**Verdict and full write-up: [`results/RESULTS.md`](results/RESULTS.md).**

```bash
# 1. everything that needs the network (cached + committed after)
service/.venv/bin/python spikes/SPIKE-D/probe.py --phase extract
service/.venv/bin/python spikes/SPIKE-D/probe.py --phase graph
service/.venv/bin/python spikes/SPIKE-D/probe.py --phase elevation
service/.venv/bin/python spikes/SPIKE-D/probe.py --phase enlarge
#    -> results/probe.json, raw/*.json.gz

# 2. the /health contract, shipped app vs a per-layer prototype (offline)
service/.venv/bin/python spikes/SPIKE-D/health.py --json

# 3. does enrichment starve extraction? real uvicorn, real graph, real DEM
service/.venv/bin/python spikes/SPIKE-D/concurrency.py --json

# 4. the D34 verdict, computed from the above (offline)
service/.venv/bin/python spikes/SPIKE-D/analyze.py --json
```

Use `service/.venv`, not the repo-root `.venv` — `health.py` and
`concurrency.py` import `plotlines_service` and need `fastapi.testclient` and
`uvicorn`, which only that environment has.

`probe.py`, `concurrency.py` and `analyze.py` call `OsmLayerProvider.fetch`,
`score_notability`, `regions.ensure_graph` and the real `create_app` directly —
the same discipline as SPIKE-A and SPIKE-B: the spike measures the product's
own code, never a spike-local reimplementation of it.

## Files

| File | What |
|---|---|
| `regions.py` | the three extents — `TRIP` (704 km², PRD §5.4a's worked-pass box), `TOUR` (8,815 km², ARCH §4.4's multi-day extent), `ENLARGED` (FR120's enlargement); the area sweep, the tiling grid, and `rect_difference` for N1's added-area-only re-extract |
| `overpass_meter.py` | wraps osmnx's own `_overpass_request` / `_get_overpass_pause` so request count, retries, bytes and — separately — **slot-queue time** come from the calls the product already makes, with no second query issued at the commons |
| `cache.py` | gzipped on-disk cache of `RawFeature` lists (shape shared with SPIKE-A/B) |
| `common.py` | `extract_stage` — the bbox → candidates path timed in its two halves (`fetch_s` network+parse, `index_s` pure-CPU scoring); the `Meter`; cold/warm cache control |
| `probe.py` | the four live phases: `extract`, `graph`, `elevation`, `enlarge` |
| `plugin_layers.py` | `LayerRegistry` — the per-layer state machine ARCH §8.3's `/health` example prints and no code produces; plus stub plugin providers (slow, unlicensed, failing) |
| `health.py` | nine N2/§8.3 clauses run against **both** the shipped `create_app` and the per-layer prototype |
| `concurrency.py` | real uvicorn + enrichment on a daemon thread; latency percentiles for the Author's surfaces idle vs. under enrichment, and the two-way starvation check |
| `analyze.py` | the D34 verdict and the A23 access-pattern table, computed offline from `results/*.json` |
| `raw/*.json.gz` | committed extraction output, so every offline script reproduces without re-hitting Overpass |
| `results/RESULTS.md` | the write-up |
| `results/*.json` | full dumps |

## What is a stand-in, and why

**Elevation.** D20/FR85 pin production elevation to GEDTM30 via OpenTopography,
and that acquisition pipeline is gated on FR87 (#148) — there is nothing to
time. `probe.py --phase elevation` uses AWS Terrain Tiles (Terrarium) at z12,
which is ~30 m/px at this latitude, the same ground resolution as GEDTM30, and
keyless. It measures the *shape and scale* of enrichment cost — tile fetch,
mosaic, reproject, then a raster sample per graph node — without introducing a
second production source, which D20 forbids. Where a number depends on that
substitution, RESULTS says so.

**Plugin layers.** N5's real plugin datasets do not exist. `plugin_layers.py`
provides a slow one, an unlicensed one, and one whose upstream times out,
because what point 3 asks to exercise is the *contract*, and the contract has
to hold before any real plugin is written.
