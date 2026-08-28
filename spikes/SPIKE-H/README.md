# SPIKE-H — LayerProvider contract validation at Leg 2.5

Tests whether ARCH §14.2's `LayerProvider` — licence, taxonomy,
`fetch_candidates(bbox)`, `load_state()` — absorbs both the built-in OSM
layers and a real, unlike third-party source with no core code changes; per
issue #160. **Verdict and full write-up: [`results/RESULTS.md`](results/RESULTS.md).**

```bash
# everything (built-in OSM read from SPIKE-D's committed cache; three real
# ArcGIS REST sources fetched live on first run, then cached under raw/)
core/.venv/bin/python spikes/SPIKE-H/run_spike.py
#   -> results/run_spike.json
```

Use `core/.venv`, not the repo-root `.venv` — this spike imports
`plotlines_core` and needs `shapely`/`requests`, which only that environment
has (same convention as SPIKE-A/B/D).

`osm_layer_provider.py`, `nc_markers_provider.py`, `nps_pois_provider.py` and
`scenic_byways_provider.py` call the *real* `OsmLayerProvider.fetch`,
`taxonomy.TAXONOMY`, `notability.weight_for` and `colocate.analyze_colocation`
— the same discipline SPIKE-A/B/D use: this spike measures whether the
product's own pieces can be assembled behind the real interface, not whether
a parallel implementation can be made to work.

## Files

| File | What |
|---|---|
| `contract.py` | ARCH §14.2's `LayerProvider` protocol, unreduced — `LayerLicence`, `LayerLoadState`, `TypeTaxonomy` (= `taxonomy.TypeRule` tuples, no new shape needed), and `score_with_taxonomy` — `score_notability`'s matching logic parameterised on a taxonomy instead of closed over the global one |
| `osm_layer_provider.py` | the built-in OSM sightseeing/amenity/natural/historic/leisure/man_made layers, expressed as real `LayerProvider`s wrapping core's real `OsmLayerProvider`/`TAXONOMY`; reads SPIKE-D's committed TRIP extraction rather than re-querying Overpass |
| `arcgis_common.py` | generic ArcGIS MapServer/FeatureServer REST query + gzip-JSON disk cache (same convention as SPIKE-A/B/D's `cache.py`) |
| `nc_markers_provider.py` | NC Highway Historical Markers (`gis2.ncdcr.gov`) — real, point geometry, **licence-blocked** (verified live: no credit/licence anywhere in the service's own metadata) |
| `nps_pois_provider.py` | NPS Public Points of Interest (`mapservices.nps.gov`) — real, point geometry, keyless, federal, **loadable** — the co-location and affinity exhibit |
| `scenic_byways_provider.py` | US Scenic Byways, NC layer (`geo.dot.gov`) — real, polyline geometry, federal, **loadable** — the area/route geometry exhibit (deliberately the negative case: see RESULTS §3) |
| `registry.py` | per-layer registry against the real protocol — licence gate at registration (D45), per-layer load state (D48), a failed layer subtracts rather than aborting (N2) — adapted from `spikes/SPIKE-D/plugin_layers.py` |
| `run_spike.py` | runs every point of issue #160 end to end and writes `results/run_spike.json` |
| `raw/*.json.gz` | committed, real ArcGIS REST responses, so a re-run never re-queries the three live services |
| `results/RESULTS.md` | the write-up |
| `results/run_spike.json` | full dump |

## What is real, and what stands in

**Every external data point is real**, fetched live against the three URLs
issue #160 names or finds (2026-08-28), and cached to `raw/` rather than
resimulated. Nothing here is a synthetic stub provider — SPIKE-D's
`plugin_layers.py` already covers that ground (slow/unlicensed/broken stub
providers), and this spike's job was to test the contract against sources
that were not built to fit it.

**The built-in OSM extraction itself is not re-run.** SPIKE-D (#159) already
measured `OsmLayerProvider.fetch` against the TRIP bbox and committed its
output; re-querying the same public Overpass commons for the same bbox days
later would repeat exactly the throttling risk (A23) that spike's results
warn about. `osm_layer_provider.py` reads `spikes/SPIKE-D/raw/trip-all.json.gz`.

**The NPS Data API (keyed REST+JSON) was not exercised** — no API key was
available in this environment; see RESULTS "Left open" §1. The three sources
tested (all ArcGIS REST) are keyless.
